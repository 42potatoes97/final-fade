extends Node

# Core rollback netcode engine for Final Fade
# Manages state snapshots, input prediction, and rollback re-simulation
#
# Snapshot convention: snapshot[N] holds the game state BEFORE frame N is simulated.
# To re-simulate from frame N, load snapshot[N], then simulate frames N..current.
#
# Dynamic rollback budget: adjusts max_rollback_frames based on measured frame time
# to stay within 60fps on weaker hardware (integrated graphics laptops).

var is_active: bool = false
var is_resimulating: bool = false

# Frame tracking
var current_frame: int = 0
var input_delay: int = 2  # Frames of input delay (reduces rollbacks)
var max_rollback_frames: int = 8  # Max frames we can roll back (adjusted dynamically)

# Dynamic budget
const MIN_ROLLBACK_FRAMES: int = 2  # Never go below 2
const MAX_ROLLBACK_FRAMES_CAP: int = 8  # Never exceed 8
const TARGET_FRAME_MS: float = 16.67  # 60fps target
const ROLLBACK_BUDGET_RATIO: float = 0.35  # Max 35% of frame for rollback
var _frame_time_avg_ms: float = 8.0  # Rolling average of non-rollback frame time
var _frame_time_samples: int = 0
const FRAME_TIME_WINDOW: int = 60  # Average over last 60 frames

# State snapshots (ring buffer)
const BUFFER_SIZE: int = 64
var state_buffer: Array = []  # Array of {frame, f1, f2, gm} dicts

# Input history
var local_input_history: Dictionary = {}   # frame -> input_bits
var remote_input_history: Dictionary = {}  # frame -> input_bits (confirmed)
var remote_input_predicted: Dictionary = {} # frame -> input_bits (what we guessed)
var last_confirmed_remote_frame: int = -1
var _needs_mismatch_check: bool = false  # Set when new remote inputs arrive
var auto_delay_enabled: bool = true  # Auto-adjust input_delay from ping
var _ping_timer: float = 0.0
const PING_INTERVAL: float = 0.5  # Send ping every 500ms

# Debug / adaptive-delay metrics (read by fight_scene debug HUD)
var rollback_count: int = 0   # Total rollbacks this match
var stall_count: int = 0      # Total stall (freeze) frames this match
var _rollback_window_count: int = 0   # Rollbacks in the last ROLLBACK_WINDOW_SEC
var _rollback_window_timer: float = 0.0
const ROLLBACK_WINDOW_SEC: float = 1.0
var replay_manager = null  # ReplayManager, set by fight_scene for ranked
var anticheat = null  # AnticheatValidator, set by fight_scene for ranked

# Cached references
var fighter1: CharacterBody3D = null
var fighter2: CharacterBody3D = null
var _network: Node = null
var _local_id: int = 1  # Cached local player ID


func _ready() -> void:
	# Pre-allocate snapshot buffer with empty dicts
	state_buffer.resize(BUFFER_SIZE)
	for i in range(BUFFER_SIZE):
		state_buffer[i] = {"frame": -1, "f1": {}, "f2": {}, "gm": {}}


func start(f1: CharacterBody3D, f2: CharacterBody3D) -> void:
	fighter1 = f1
	fighter2 = f2
	is_active = true
	current_frame = 0
	last_confirmed_remote_frame = -1
	_needs_mismatch_check = false
	_frame_time_avg_ms = 8.0
	_frame_time_samples = 0
	local_input_history.clear()
	remote_input_history.clear()
	remote_input_predicted.clear()

	_network = get_node_or_null("/root/NetworkManager")
	if _network:
		_network.remote_input_received.connect(_on_remote_input)
		_local_id = _network.local_player_id
	else:
		_local_id = 1

	# Reset debug/adaptive counters
	rollback_count = 0
	stall_count = 0
	_rollback_window_count = 0
	_rollback_window_timer = 0.0

	# Take initial snapshot
	_save_snapshot(0)


func stop() -> void:
	is_active = false
	fighter1 = null
	fighter2 = null
	if _network and _network.remote_input_received.is_connected(_on_remote_input):
		_network.remote_input_received.disconnect(_on_remote_input)


func network_tick() -> void:
	if not is_active or fighter1 == null or fighter2 == null:
		return

	var fixed_delta: float = 1.0 / 60.0
	var tick_start_ms: float = Time.get_ticks_msec()

	# 1. Read local input for this frame + input_delay
	var local_input: int = InputManager._read_player_input(_local_id)
	var input_frame: int = current_frame + input_delay
	local_input_history[input_frame] = local_input

	# 2. Send to remote
	if _network:
		_network.send_input(input_frame, local_input)

	# 3. Check if rollback is needed (only when new remote inputs arrived)
	if _needs_mismatch_check:
		_needs_mismatch_check = false
		var rollback_frame: int = _find_rollback_frame()

		if rollback_frame >= 0:
			# Clamp rollback to dynamic max range
			var min_frame: int = maxi(rollback_frame, current_frame - max_rollback_frames)
			# 4. ROLLBACK — load snapshot, skip if not available
			if _load_snapshot(min_frame):
				rollback_count += 1
				_rollback_window_count += 1
				# 5. Re-simulate from rollback_frame to current_frame
				is_resimulating = true
				for f in range(min_frame, current_frame):
					var p1_input: int = _get_input(1, f)
					var p2_input: int = _get_input(2, f)
					_simulate_frame(p1_input, p2_input, fixed_delta)
					_save_snapshot(f + 1)
				is_resimulating = false

	# 6. Check if we're too far ahead — freeze if necessary
	if _should_freeze():
		stall_count += 1
		return  # Don't advance, wait for remote

	# 7. Simulate current frame
	var p1_input: int = _get_input(1, current_frame)
	var p2_input: int = _get_input(2, current_frame)
	_simulate_frame(p1_input, p2_input, fixed_delta)

	# Record confirmed inputs for replay (ranked matches only)
	if replay_manager and not is_resimulating:
		replay_manager.record_input(current_frame, 1, p1_input)
		replay_manager.record_input(current_frame, 2, p2_input)

	# 8. Save snapshot and advance
	current_frame += 1
	_save_snapshot(current_frame)

	# Anti-cheat: periodic state hash exchange
	if anticheat and _network and anticheat.should_exchange_hash(current_frame):
		var snap: Dictionary = state_buffer[current_frame % BUFFER_SIZE]
		var local_hash: PackedByteArray = anticheat.compute_state_hash(
			snap.get("gm", {}), snap.get("f1", {}), snap.get("f2", {}))
		anticheat._last_local_hash = local_hash
		_network._rpc_state_hash.rpc(local_hash)

	# 9. Clean old history (infrequent — every 16 frames)
	if current_frame % 16 == 0:
		_cleanup_old_data()

	# 10. Periodic ping for connection quality + auto delay
	_ping_timer += fixed_delta
	_rollback_window_timer += fixed_delta

	if _ping_timer >= PING_INTERVAL:
		_ping_timer = 0.0
		if _network:
			_network.send_ping()
			if auto_delay_enabled:
				var quality: ConnectionQuality = _network.get_quality()

				# Adaptive pressure: if too many rollbacks in the past second, bump delay up.
				# This fires on the second PING_INTERVAL tick after the window fills (~1s).
				if _rollback_window_timer >= ROLLBACK_WINDOW_SEC:
					if _rollback_window_count > 3:
						var pressure: int = clampi(input_delay + 1, 1, max_rollback_frames - 2)
						if pressure != input_delay:
							input_delay = pressure
							if _network.is_host:
								_network.send_input_delay_sync(input_delay)
					_rollback_window_count = 0
					_rollback_window_timer = 0.0

				# Only auto-adjust delay once we have enough ping samples (prevents
				# premature reduction to delay=1 at match start before ping is known).
				if quality.ping_history.size() >= 3:
					var recommended: int = quality.get_recommended_delay()
					# Cap auto-delay so it doesn't exceed rollback budget
					recommended = clampi(recommended, 1, max_rollback_frames - 2)
					if recommended != input_delay:
						input_delay = recommended
						# Host is the authority on delay — broadcast to client
						if _network.is_host:
							_network.send_input_delay_sync(input_delay)

	# 11. Update dynamic rollback budget from measured frame time
	var tick_end_ms: float = Time.get_ticks_msec()
	_update_dynamic_budget(tick_end_ms - tick_start_ms)


func _simulate_frame(p1_input: int, p2_input: int, delta: float) -> void:
	InputManager.inject_input(1, p1_input)
	InputManager.inject_input(2, p2_input)
	GameManager.manual_tick(delta)
	fighter1.manual_tick(delta)
	fighter2.manual_tick(delta)


func _get_input(player_id: int, frame: int) -> int:
	if player_id == _local_id:
		return local_input_history.get(frame, 0)
	else:
		# Remote player — use confirmed if available, otherwise predict
		if remote_input_history.has(frame):
			return remote_input_history[frame]
		else:
			var predicted: int = _predict_remote_input(frame)
			remote_input_predicted[frame] = predicted
			return predicted


func _predict_remote_input(_frame: int) -> int:
	# Smart prediction: in states where no new input can take effect (hitstun,
	# knockdown, blockstun, getup recovery), predict neutral (0).  This is
	# almost always correct and avoids rollbacks during forced animation.
	var remote_fighter: CharacterBody3D = fighter2 if _local_id == 1 else fighter1
	if remote_fighter != null and remote_fighter.state_machine != null:
		var state_name: String = remote_fighter.state_machine.get_current_state_name()
		if state_name in ["Hitstun", "Blockstun", "Knockdown", "Getup", "GetupKick", "SideRoll"]:
			return 0  # Input buffered but no new move can start — predict neutral
	# Default: repeat last confirmed input (momentum prediction)
	if last_confirmed_remote_frame >= 0:
		return remote_input_history.get(last_confirmed_remote_frame, 0)
	return 0


func _find_rollback_frame() -> int:
	# Check if any predicted remote input was wrong
	var earliest_mismatch: int = -1

	for frame in remote_input_history:
		if frame > current_frame:
			continue
		if remote_input_predicted.has(frame):
			if remote_input_predicted[frame] != remote_input_history[frame]:
				if earliest_mismatch < 0 or frame < earliest_mismatch:
					earliest_mismatch = frame

	# Clear all predictions from mismatch onward (they'll be re-predicted)
	if earliest_mismatch >= 0:
		var to_clear: Array = []
		for f in remote_input_predicted:
			if f >= earliest_mismatch:
				to_clear.append(f)
		for f in to_clear:
			remote_input_predicted.erase(f)

	return earliest_mismatch


func _should_freeze() -> bool:
	if last_confirmed_remote_frame < 0 and current_frame > max_rollback_frames:
		return true
	if current_frame - last_confirmed_remote_frame > max_rollback_frames:
		return true
	return false


func _save_snapshot(frame: int) -> void:
	var idx: int = frame % BUFFER_SIZE
	var snap: Dictionary = state_buffer[idx]
	snap["frame"] = frame
	snap["f1"] = fighter1.save_state()
	snap["f2"] = fighter2.save_state()
	snap["gm"] = GameManager.get_game_state()


func _load_snapshot(frame: int) -> bool:
	var idx: int = frame % BUFFER_SIZE
	var snapshot: Dictionary = state_buffer[idx]
	if snapshot.get("frame", -1) != frame:
		push_warning("RollbackManager: No snapshot for frame %d (slot has frame %d)" % [frame, snapshot.get("frame", -1)])
		return false

	fighter1.load_state(snapshot["f1"])
	fighter2.load_state(snapshot["f2"])
	GameManager.set_game_state(snapshot["gm"])

	# Sync input buffer frame_count with rollback frame to prevent expiry bugs
	if fighter1.input_buffer:
		fighter1.input_buffer.frame_count = frame
	if fighter2.input_buffer:
		fighter2.input_buffer.frame_count = frame

	return true


func _on_remote_input(frame: int, input_bits: int) -> void:
	if not remote_input_history.has(frame):
		remote_input_history[frame] = input_bits
		if frame > last_confirmed_remote_frame:
			last_confirmed_remote_frame = frame
		_needs_mismatch_check = true


# --- Dynamic Rollback Budget ---
# Measures actual frame time and adjusts max_rollback_frames to fit hardware.
# On a ThinkPad with integrated graphics, rendering may take 8-10ms,
# leaving only ~6ms for game logic. We allocate ROLLBACK_BUDGET_RATIO (35%)
# of the remaining budget for rollback resimulation.

func _update_dynamic_budget(tick_ms: float) -> void:
	# Rolling average of frame time (excluding rollback cost)
	_frame_time_samples += 1
	if _frame_time_samples <= FRAME_TIME_WINDOW:
		_frame_time_avg_ms = (_frame_time_avg_ms * (_frame_time_samples - 1) + tick_ms) / _frame_time_samples
	else:
		# Exponential moving average after warmup
		var alpha: float = 2.0 / (FRAME_TIME_WINDOW + 1)
		_frame_time_avg_ms = alpha * tick_ms + (1.0 - alpha) * _frame_time_avg_ms

	# Only adjust every 30 frames to avoid thrashing
	if current_frame % 30 != 0:
		return

	# Available budget = target - avg frame time (rendering + physics)
	var available_ms: float = TARGET_FRAME_MS - _frame_time_avg_ms
	var rollback_budget_ms: float = available_ms * ROLLBACK_BUDGET_RATIO

	# Estimate cost per resim frame (~0.5ms on fast hardware, scale by ratio)
	# Use measured tick_ms as proxy for single-frame sim cost
	var sim_cost_ms: float = maxf(_frame_time_avg_ms * 0.6, 0.5)  # At least 0.5ms

	# How many frames can we afford?
	var affordable: int = int(rollback_budget_ms / sim_cost_ms) if sim_cost_ms > 0 else MAX_ROLLBACK_FRAMES_CAP

	# Clamp to range
	max_rollback_frames = clampi(affordable, MIN_ROLLBACK_FRAMES, MAX_ROLLBACK_FRAMES_CAP)


static func _prune_dict(dict: Dictionary, cutoff: int) -> void:
	var to_erase: Array = []
	for frame in dict:
		if frame < cutoff:
			to_erase.append(frame)
	for frame in to_erase:
		dict.erase(frame)


func _cleanup_old_data() -> void:
	var cutoff: int = current_frame - BUFFER_SIZE
	_prune_dict(local_input_history, cutoff)
	_prune_dict(remote_input_history, cutoff)
	_prune_dict(remote_input_predicted, cutoff)


func clear_ranked() -> void:
	replay_manager = null
	anticheat = null
