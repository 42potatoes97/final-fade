class_name IdleState
extends FighterState

# Neutral standing state — hub for all movement transitions
#
# UP/DOWN have a brief wait window before committing to hop/duck
# so double-tap sidestep has time to register.

const UP_WAIT_FRAMES: int = 8  # Frames to wait after first UP before committing to hop
const DOWN_WAIT_FRAMES: int = 3  # Very responsive crouch — makes KBD harder, backsway comes out on sloppy input

var up_pending_frames: int = 0  # Counts up after first UP press
var down_pending_frames: int = 0  # Counts up after first DOWN press
var _pending_buffered_action: Dictionary = {}


func enter(_prev_state: String) -> void:
	fighter.velocity = Vector3.ZERO
	fighter.is_crouching = false
	up_pending_frames = 0
	down_pending_frames = 0
	var m = get_model()
	if m:
		m.set_pose_fight_stance()

	# Consume buffered action — will be executed on first handle_input call
	_pending_buffered_action = fighter.input_buffer.consume_buffered_action()


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	# --- Execute buffered action from previous state ---
	if not _pending_buffered_action.is_empty():
		var action = _pending_buffered_action
		_pending_buffered_action = {}
		if action.type == "attack" and action.data:
			var atk = state_machine.states.get("Attack")
			if atk and atk.has_method("start_move"):
				atk.start_move(action.data)
				return "Attack"

	# --- df = instant crouch (vulnerable, for df+moves) — HIGHEST PRIORITY ---
	# Must check BEFORE crouch dash to prevent df from triggering wavedash
	var df_down = IM.has_flag(input_bits, IM.INPUT_DOWN)
	var df_fwd = IM.has_flag(input_bits, IM.INPUT_FORWARD)
	if df_down and df_fwd:
		# Check for df+attack first
		var attack_result = try_attack(input_bits)
		if attack_result != "":
			return attack_result
		# No attack — just crouch (vulnerable, no block)
		return "Crouch"

	# --- Special movements ---

	if buf.detect_crouch_dash_input():
		return "CrouchDash"
	if buf.detect_qcb_input():
		return "Backsway"
	if buf.detect_double_tap(IM.INPUT_FORWARD) and fighter.backdash_cooldown <= 0:
		return "DashForward"
	if buf.detect_double_tap(IM.INPUT_BACK) and fighter.backdash_cooldown <= 0:
		return "Backdash"

	# Sidestep: double-tap up or down (cancels pending hop/duck)
	if buf.detect_double_tap(IM.INPUT_UP):
		up_pending_frames = 0
		return "SidestepUp"
	if buf.detect_double_tap(IM.INPUT_DOWN):
		down_pending_frames = 0
		return "SidestepDown"

	# --- Attack check ---
	var attack_result = try_attack(input_bits)
	if attack_result != "":
		return attack_result

	# --- UP handling: wait before hop ---
	# Must HOLD up for the full wait to get hop. Releasing early cancels (no hop).
	# This gives generous room for double-tap sidestep.
	if buf.just_pressed(IM.INPUT_UP):
		up_pending_frames = 1

	if up_pending_frames > 0:
		if IM.has_flag(input_bits, IM.INPUT_UP):
			up_pending_frames += 1
			if up_pending_frames >= UP_WAIT_FRAMES:
				# Held long enough — commit to hop
				up_pending_frames = 0
				return "Hop"
		else:
			# Released UP early — cancel, no hop (allows clean double-tap)
			up_pending_frames = 0

	# --- DOWN handling: wait before duck ---
	if buf.just_pressed(IM.INPUT_DOWN):
		down_pending_frames = 1

	if down_pending_frames > 0:
		if IM.has_flag(input_bits, IM.INPUT_DOWN) or down_pending_frames < DOWN_WAIT_FRAMES:
			down_pending_frames += 1
			if down_pending_frames >= DOWN_WAIT_FRAMES:
				# Waited long enough, no double-tap — commit to crouch
				down_pending_frames = 0
				return "Crouch"
		else:
			down_pending_frames = 0
			return "Crouch"

	# --- Walk (only if no pending up/down) ---
	if up_pending_frames == 0 and down_pending_frames == 0:
		var holding_fwd = IM.has_flag(input_bits, IM.INPUT_FORWARD)
		var holding_back = IM.has_flag(input_bits, IM.INPUT_BACK)

		if holding_fwd:
			return "WalkForward"
		if holding_back:
			return "WalkBackward"

	return ""


func save_state() -> Dictionary:
	var ba = _pending_buffered_action.duplicate() if not _pending_buffered_action.is_empty() else {}
	if ba.has("data") and ba.data != null and ba.data is Resource:
		ba["data_cmd"] = ba.data.input_command
		ba.erase("data")
	return {"up": up_pending_frames, "down": down_pending_frames, "ba": ba}

func load_state(s: Dictionary) -> void:
	up_pending_frames = s.get("up", 0)
	down_pending_frames = s.get("down", 0)
	var ba = s.get("ba", {})
	if ba.has("data_cmd") and fighter and fighter.move_registry:
		var cmd = ba["data_cmd"]
		ba["data"] = fighter.move_registry.moves.get(cmd)
		ba.erase("data_cmd")
	_pending_buffered_action = ba


func tick(_delta: float) -> String:
	fighter.velocity.x = 0
	fighter.velocity.z = 0
	fighter.move_and_slide()
	return ""
