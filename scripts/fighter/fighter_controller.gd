class_name FighterController
extends CharacterBody3D

# Main fighter script — wires input to state machine, handles facing

const InputBufferClass = preload("res://scripts/fighter/input_buffer.gd")

@export var player_id: int = 1

var opponent: FighterController = null
var state_machine: FighterStateMachine = null
var model: Node3D = null
var input_buffer = InputBufferClass.new()
var move_registry  # Initialized in _ready
var facing: int = 1  # 1 = facing +X, -1 = facing -X
var hitstop_remaining: int = 0  # Freeze frames on hit
var pending_knockback: Vector3 = Vector3.ZERO  # Applied after hitstop ends
var is_crouching: bool = false:
	set(value):
		is_crouching = value
		if model and model.has_method("set_crouching"):
			model.set_crouching(value)
var is_blocking_on_getup: bool = false
var is_invulnerable: bool = false  # Brief invulnerability during backdash
var is_misaligned: bool = false  # True when sidestepped — must actively realign
var _cached_camera: Camera3D = null
var backdash_cooldown: int = 0  # Frames before another raw dash (f,f or b,b) is allowed
const BACKDASH_COOLDOWN_FRAMES: int = 12  # Must KBD or wavedash — no raw backdash spam
var misalign_timer: int = 0  # Frames since misaligned (for training mode auto-realign)
var realign_frames: int = 0  # Frames since defender started turning (0 = not started yet)
const REALIGN_TURN_SPEED: float = 8.0  # How fast we turn when realigning (radians/sec)
const REALIGN_GUARD_FRAMES: int = 3  # Frames of active turning before guard restores

const MIN_DISTANCE: float = 1.0
const GRAVITY: float = 20.0  # Stronger gravity to keep grounded


var sfx_player: AudioStreamPlayer = null
var _hit_system: Node = null  # Cached reference for rollback perf

func _ready() -> void:
	state_machine = $StateMachine as FighterStateMachine
	state_machine.initialize(self)
	model = $Model if has_node("Model") else null
	_hit_system = get_node_or_null("HitSystem")
	var RegistryScript = load("res://scripts/fighter/move_registry.gd")
	move_registry = RegistryScript.new()
	_register_moves()
	# Audio player for hit/block/whiff sounds
	sfx_player = AudioStreamPlayer.new()
	sfx_player.name = "SFXPlayer"
	sfx_player.bus = "Master"
	add_child(sfx_player)


func _register_moves() -> void:
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var fighter_class = GameManager.p1_fighter_class if player_id == 1 else GameManager.p2_fighter_class
	var is_offensive = (fighter_class == GameManager.FighterClass.OFFENSIVE)

	# === SHARED MOVES (both classes) ===

	# 1: Jab — i10 HIGH, +4 on hit, -1 on block
	# DEF only: chains to 1,1
	var jab = MoveScript.new()
	jab.move_name = "Jab"
	jab.input_command = "1"
	jab.startup_frames = 8
	jab.active_frames = 3
	jab.recovery_frames = 8
	jab.damage = 8
	jab.hit_level = "high"
	jab.hitstun_frames = 12
	jab.blockstun_frames = 7
	jab.hitstop_frames = 4        # Jab/poke hitstop
	jab.knockback = 0.4
	jab.pushback_block = 0.5
	jab.forward_lunge = 0.0
	jab.pose_name = "jab"
	if not is_offensive:
		jab.string_followup_command = "1"
		jab.string_window_frames = 10
	move_registry.register_move("1", jab)

	# 2: Overhead Slam — i16 MID, high crush, wall splat, knockdown
	# On block: blockstun=4, recovery=20 -> -16 on block (launch punishable)
	# Low pushback on block so defender stays point-blank for free punish
	var hcb = MoveScript.new()
	hcb.move_name = "Overhead Slam"
	hcb.input_command = "2"
	hcb.startup_frames = 16
	hcb.active_frames = 4
	hcb.recovery_frames = 20
	hcb.damage = 35
	hcb.hit_level = "mid"
	hcb.high_crush = true
	hcb.hitstun_frames = 0       # Knockdown, no hitstun
	hcb.blockstun_frames = 4
	hcb.hitstop_frames = 8       # KD move hitstop
	hcb.knockback = 2.5
	hcb.pushback_block = 0.3     # Near-zero pushback — punishable means punishable
	hcb.wall_splat = true
	hcb.causes_knockdown = true
	hcb.forward_lunge = 0.10  # Forward rush for whiff punish range (tracks better vs backdash)
	hcb.pose_name = "high_crush"
	move_registry.register_move("2", hcb)

	# 3: Low Kick — i12 LOW, +2 on hit (hitstun=12 - recovery=10), -6 on block
	var lk = MoveScript.new()
	lk.move_name = "Low Kick"
	lk.input_command = "3"
	lk.startup_frames = 10
	lk.active_frames = 3
	lk.recovery_frames = 10
	lk.damage = 12
	lk.hit_level = "low"
	lk.hitstun_frames = 12
	lk.blockstun_frames = 4
	lk.hitstop_frames = 4        # Poke hitstop
	lk.knockback = 1.0
	lk.pushback_block = 1.0
	lk.forward_lunge = 0.0
	lk.pose_name = "low_kick"
	move_registry.register_move("3", lk)

	# 4: Roundhouse — i14 HIGH, homing
	# Solo: knockdown on hit. OFF: chains to 4,4 (natural combo — stagger first, KD second)
	var hk = MoveScript.new()
	hk.move_name = "Roundhouse"
	hk.input_command = "4"
	hk.startup_frames = 14
	hk.active_frames = 4
	hk.recovery_frames = 13
	hk.damage = 18
	hk.hit_level = "high"
	hk.is_homing = true
	hk.knockback = 2.0
	hk.pushback_block = 1.2
	hk.forward_lunge = 0.0
	hk.pose_name = "high_kick"
	if is_offensive:
		# In string context: first hit staggers (no KD), second hit KDs
		hk.hitstun_frames = 18       # Long stagger hitstun — guarantees second hit
		hk.blockstun_frames = 4      # -14 on block — punishable, opponent can duck 2nd
		hk.hitstop_frames = 6
		hk.causes_knockdown = false   # Stagger, not KD
		hk.string_followup_command = "4"
		hk.string_window_frames = 10
	else:
		# DEF class: solo knockdown
		hk.hitstun_frames = 0
		hk.blockstun_frames = 4      # -14 on block
		hk.hitstop_frames = 8
		hk.causes_knockdown = true
	move_registry.register_move("4", hk)

	# d+3: Leg Sweep — i15 LOW
	# Solo: soft knockdown. OFF string: stagger into guaranteed d+3,3
	var dlk = MoveScript.new()
	dlk.move_name = "Leg Sweep"
	dlk.input_command = "d+3"
	dlk.startup_frames = 15
	dlk.active_frames = 4
	dlk.recovery_frames = 14
	dlk.damage = 14
	dlk.hit_level = "low"
	dlk.knockback = 1.5
	dlk.pushback_block = 1.8
	dlk.forward_lunge = 0.09  # Forward slide into sweep range
	dlk.pose_name = "d_low_kick"
	dlk.blockstun_frames = 2        # -20 on block
	dlk.hitstop_frames = 8
	dlk.hitstun_frames = 0          # KD, no hitstun
	dlk.causes_knockdown = true
	dlk.soft_knockdown = true         # Fast recovery — opponent gets up quickly, no oki
	if is_offensive:
		dlk.string_followup_command = "3"
		dlk.string_window_frames = 14  # d+3,3 second hit catches grounded
	move_registry.register_move("d+3", dlk)

	# === CLASS-EXCLUSIVE MOVES ===

	if is_offensive:
		_register_offensive_exclusive(MoveScript)
	else:
		_register_defensive_exclusive(MoveScript)


func _register_defensive_exclusive(MoveScript) -> void:
	# --- DEFENSIVE CLASS EXCLUSIVE (punch-focused) ---

	# 1,1: Cross Punch — i8 HIGH, chains to 1,1,1
	var jab2 = MoveScript.new()
	jab2.move_name = "Cross Punch"
	jab2.input_command = "1,1"
	jab2.startup_frames = 6
	jab2.active_frames = 3
	jab2.recovery_frames = 9
	jab2.damage = 8
	jab2.hit_level = "high"
	jab2.hitstun_frames = 12
	jab2.blockstun_frames = 8
	jab2.hitstop_frames = 4      # Jab hitstop
	jab2.knockback = 0.2
	jab2.pushback_block = 0.4
	jab2.forward_lunge = 0.0
	jab2.pose_name = "jab_2"
	jab2.string_followup_command = "1"
	jab2.string_window_frames = 10
	move_registry.register_move("1,1", jab2)

	# 1,1,1: Hook — i12 HIGH, knockdown, punishable on block
	var jab3 = MoveScript.new()
	jab3.move_name = "Hook"
	jab3.input_command = "1,1,1"
	jab3.startup_frames = 10
	jab3.active_frames = 4
	jab3.recovery_frames = 14
	jab3.damage = 22
	jab3.hit_level = "high"
	jab3.hitstun_frames = 0      # Knockdown
	jab3.blockstun_frames = 6
	jab3.hitstop_frames = 8      # KD move hitstop
	jab3.knockback = 3.0
	jab3.pushback_block = 1.5
	jab3.causes_knockdown = true
	jab3.forward_lunge = 0.0
	jab3.pose_name = "power_straight"
	move_registry.register_move("1,1,1", jab3)

	# df+1: Mid Check — i13 MID, slight tracking (not homing)
	var df1 = MoveScript.new()
	df1.move_name = "Mid Check"
	df1.input_command = "df+1"
	df1.startup_frames = 11
	df1.active_frames = 3
	df1.recovery_frames = 11
	df1.damage = 12
	df1.hit_level = "mid"
	df1.is_homing = false
	df1.hitstun_frames = 14
	df1.blockstun_frames = 11
	df1.hitstop_frames = 6       # Mid-tier hitstop
	df1.knockback = 1.0
	df1.pushback_block = 0.6
	df1.forward_lunge = 0.0
	df1.pose_name = "df1_check"
	move_registry.register_move("df+1", df1)

	# d+1: Track Mid — i14 MID, homing
	var dmp = MoveScript.new()
	dmp.move_name = "Track Mid"
	dmp.input_command = "d+1"
	dmp.startup_frames = 12
	dmp.active_frames = 3
	dmp.recovery_frames = 11
	dmp.damage = 12
	dmp.hit_level = "mid"
	dmp.is_homing = true
	dmp.hitstun_frames = 14
	dmp.blockstun_frames = 9
	dmp.hitstop_frames = 6       # Mid-tier hitstop
	dmp.knockback = 1.2
	dmp.pushback_block = 0.4
	dmp.forward_lunge = 0.0
	dmp.pose_name = "d_mid_punch"
	move_registry.register_move("d+1", dmp)


func _register_offensive_exclusive(MoveScript) -> void:
	# --- OFFENSIVE CLASS EXCLUSIVE (kick-focused) ---

	# 4,4: Power Roundhouse — i14 HIGH, knockdown, homing
	var hk2 = MoveScript.new()
	hk2.move_name = "Power Roundhouse"
	hk2.input_command = "4,4"
	hk2.startup_frames = 11
	hk2.active_frames = 4
	hk2.recovery_frames = 14
	hk2.damage = 20
	hk2.hit_level = "high"
	hk2.is_homing = true
	hk2.hitstun_frames = 0       # Knockdown
	hk2.blockstun_frames = 6
	hk2.hitstop_frames = 8       # KD move hitstop
	hk2.knockback = 3.5
	hk2.pushback_block = 1.5
	hk2.causes_knockdown = true
	hk2.forward_lunge = 0.0
	hk2.pose_name = "high_kick"
	move_registry.register_move("4,4", hk2)

	# d+4: Crouch Low Kick — i13 LOW, chains to d+4,4
	var d4 = MoveScript.new()
	d4.move_name = "Crouch Low Kick"
	d4.input_command = "d+4"
	d4.startup_frames = 11
	d4.active_frames = 3
	d4.recovery_frames = 11
	d4.damage = 12
	d4.hit_level = "low"
	d4.hitstun_frames = 13
	d4.blockstun_frames = 5
	d4.hitstop_frames = 4        # Poke hitstop
	d4.knockback = 0.8
	d4.pushback_block = 0.8
	d4.forward_lunge = 0.0
	d4.pose_name = "d4_kick"
	d4.string_followup_command = "4"
	d4.string_window_frames = 10
	move_registry.register_move("d+4", d4)

	# d+4,4: Power RH Follow — i14 HIGH, knockdown
	var d44 = MoveScript.new()
	d44.move_name = "Power RH Follow"
	d44.input_command = "d+4,4"
	d44.startup_frames = 11
	d44.active_frames = 4
	d44.recovery_frames = 14
	d44.damage = 22
	d44.hit_level = "high"
	d44.hitstun_frames = 0       # Knockdown
	d44.blockstun_frames = 4
	d44.hitstop_frames = 8       # KD move hitstop
	d44.knockback = 3.0
	d44.pushback_block = 1.5
	d44.causes_knockdown = true
	d44.forward_lunge = 0.0
	d44.pose_name = "high_kick"
	move_registry.register_move("d+4,4", d44)

	# d+3,3: Double Slide — fast natural low string, second sweep KDs
	var dlk3 = MoveScript.new()
	dlk3.move_name = "Double Slide"
	dlk3.input_command = "d+3,3"
	dlk3.startup_frames = 6        # Very fast natural followup
	dlk3.active_frames = 4
	dlk3.recovery_frames = 14
	dlk3.damage = 20
	dlk3.hit_level = "low"          # Both hits are low
	dlk3.hitstun_frames = 0        # Hard KD on second hit
	dlk3.blockstun_frames = 2      # -18 on block
	dlk3.hitstop_frames = 8
	dlk3.knockback = 2.0
	dlk3.pushback_block = 1.5
	dlk3.causes_knockdown = true    # Hard KD
	dlk3.hits_grounded = true       # Catches grounded opponents after first sweep
	dlk3.forward_lunge = 0.0
	dlk3.pose_name = "d_low_kick"   # Same sweep animation — double slide
	move_registry.register_move("d+3,3", dlk3)


# --- Rollback serialization ---
func save_state() -> Dictionary:
	var s = {
		"pos": [global_position.x, global_position.y, global_position.z],
		"vel": [velocity.x, velocity.y, velocity.z],
		"facing": facing,
		"crouch": is_crouching,
		"block_gu": is_blocking_on_getup,
		"invuln": is_invulnerable,
		"misalign": is_misaligned,
		"misalign_t": misalign_timer,
		"realign_f": realign_frames,
		"hitstop": hitstop_remaining,
		"pend_kb": [pending_knockback.x, pending_knockback.y, pending_knockback.z],
		"bd_cd": backdash_cooldown,
		"sm": state_machine.save_state() if state_machine else {},
		"ib": input_buffer.save_state(),
	}
	if _hit_system:
		s["hs"] = _hit_system.save_state()
	return s

func load_state(s: Dictionary) -> void:
	var p = s.get("pos", [0, 0, 0])
	global_position = Vector3(p[0], p[1], p[2])
	var v = s.get("vel", [0, 0, 0])
	velocity = Vector3(v[0], v[1], v[2])
	facing = s.get("facing", 1)
	is_crouching = s.get("crouch", false)
	is_blocking_on_getup = s.get("block_gu", false)
	is_invulnerable = s.get("invuln", false)
	is_misaligned = s.get("misalign", false)
	misalign_timer = s.get("misalign_t", 0)
	realign_frames = s.get("realign_f", 0)
	hitstop_remaining = s.get("hitstop", 0)
	var kb = s.get("pend_kb", [0, 0, 0])
	pending_knockback = Vector3(kb[0], kb[1], kb[2])
	backdash_cooldown = s.get("bd_cd", 0)
	if state_machine:
		state_machine.load_state(s.get("sm", {}))
	input_buffer.load_state(s.get("ib", {}), move_registry)
	if _hit_system:
		_hit_system.load_state(s.get("hs", {}))


func manual_tick(delta: float) -> void:
	if opponent == null:
		return

	# Freeze fighters during round end / match end
	if GameManager.state == GameManager.GameState.ROUND_END or GameManager.state == GameManager.GameState.MATCH_END:
		velocity = Vector3.ZERO
		return

	# HITSTOP: freeze all processing, just decrement counter
	if hitstop_remaining > 0:
		hitstop_remaining -= 1
		velocity = Vector3.ZERO
		# Small shake on defender during hitstop (skip during rollback resim — non-deterministic)
		if model and not RollbackManager.is_resimulating:
			if hitstop_remaining > 0:
				var shake = Vector3(randf_range(-0.02, 0.02), 0, randf_range(-0.02, 0.02))
				model.position = shake
			else:
				model.position = Vector3.ZERO  # Reset shake on last frame
		# Apply pending knockback when hitstop ends
		if hitstop_remaining == 0 and pending_knockback != Vector3.ZERO:
			velocity = pending_knockback
			pending_knockback = Vector3.ZERO
		return

	_update_facing()

	if backdash_cooldown > 0:
		backdash_cooldown -= 1

	var input_bits = InputManager.get_input(player_id)
	input_buffer.push(input_bits)

	# Apply gravity before state processing
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0

	state_machine.process_tick(input_bits, delta)

	_enforce_min_distance()


func _physics_process(delta: float) -> void:
	# During online rollback, RollbackManager drives simulation via manual_tick
	if GameManager.online_mode:
		return
	manual_tick(delta)


func _update_facing() -> void:
	if opponent == null:
		return

	var dir_to_opponent = opponent.global_position - global_position
	dir_to_opponent.y = 0

	# Update facing direction (for input mapping — left/right relative to opponent)
	if _cached_camera == null:
		_cached_camera = get_viewport().get_camera_3d()
	var cam = _cached_camera
	if cam:
		var cam_right = cam.global_transform.basis.x
		var dot = dir_to_opponent.dot(cam_right)
		var new_facing = 1 if dot >= 0 else -1
		if new_facing != facing:
			facing = new_facing
			InputManager.set_facing(player_id, facing)
	else:
		var new_facing = 1 if dir_to_opponent.x >= 0 else -1
		if new_facing != facing:
			facing = new_facing
			InputManager.set_facing(player_id, facing)

	# Misaligned state — after being sidestepped, can't block until realigned.
	# Defender must press a direction or attack to begin turning back.
	# Guard restores after REALIGN_GUARD_FRAMES of active turning — fair race
	# between stepper attacking and defender reacting.
	if is_misaligned:
		var input_bits = input_buffer.get_current()
		var has_directional = (input_bits & (InputManager.INPUT_FORWARD | InputManager.INPUT_BACK | InputManager.INPUT_UP | InputManager.INPUT_DOWN)) != 0
		var has_attack = (input_bits & (InputManager.INPUT_BUTTON1 | InputManager.INPUT_BUTTON2 | InputManager.INPUT_BUTTON3 | InputManager.INPUT_BUTTON4)) != 0

		# Training mode: auto-realign after a delay
		if GameManager.training_mode and not (has_directional or has_attack):
			misalign_timer += 1
			if misalign_timer >= 30:  # ~0.5 seconds
				has_directional = true

		# Once started, realignment continues even if input is released
		if realign_frames > 0:
			realign_frames += 1
		elif has_directional or has_attack:
			realign_frames = 1  # Begin realignment

		if realign_frames > 0:
			# Smooth turn toward opponent
			var look_target = Vector3(opponent.global_position.x, global_position.y, opponent.global_position.z)
			if global_position.distance_to(look_target) > 0.01:
				var target_transform = global_transform.looking_at(look_target, Vector3.UP)
				var delta = get_physics_process_delta_time()
				global_transform = global_transform.interpolate_with(target_transform, REALIGN_TURN_SPEED * delta)

				var angle_diff = global_transform.basis.z.angle_to(target_transform.basis.z)
				# Guard restores after brief turn commitment, or immediately if visually aligned
				if realign_frames >= REALIGN_GUARD_FRAMES or angle_diff < 0.1:
					is_misaligned = false
					misalign_timer = 0
					realign_frames = 0
					if angle_diff < 0.1:
						look_at(look_target, Vector3.UP)
		return  # Don't snap-face while misaligned

	# Normal facing — instant look_at
	var look_target = Vector3(opponent.global_position.x, global_position.y, opponent.global_position.z)
	if global_position.distance_to(look_target) > 0.01:
		look_at(look_target, Vector3.UP)


func trigger_realignment_delay() -> void:
	is_misaligned = true
	misalign_timer = 0
	realign_frames = 0


func _enforce_min_distance() -> void:
	if opponent == null:
		return

	var to_opponent = opponent.global_position - global_position
	to_opponent.y = 0
	var dist = to_opponent.length()

	if dist < MIN_DISTANCE and dist > 0.001:
		var push_dir = -to_opponent.normalized()
		var push_amount = (MIN_DISTANCE - dist) * 0.5
		global_position += push_dir * push_amount


func get_forward_direction() -> Vector3:
	if opponent == null:
		return Vector3(facing, 0, 0)
	var dir = opponent.global_position - global_position
	dir.y = 0
	if dir.length() < 0.001:
		return Vector3(facing, 0, 0)
	return dir.normalized()


func get_side_direction() -> Vector3:
	var fwd = get_forward_direction()
	return Vector3(-fwd.z, 0, fwd.x)
