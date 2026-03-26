extends FighterState

# Generic attack state — parameterized by MoveData
# Counts through startup -> active -> recovery frames
# During active frames, the attack can hit
# During recovery, fighter cannot act (punishable)
# After recovery, check for string followup window

var current_move: Resource = null
var frame_counter: int = 0
var phase: String = "startup"  # "startup", "active", "recovery", "string_window"
var hit_confirmed: bool = false
var whiff_played: bool = false

# Sound effects
var sfx_hit_light: AudioStream = preload("res://assets/audio/sfx/hit_light.wav")
var sfx_hit_heavy: AudioStream = preload("res://assets/audio/sfx/hit_heavy.wav")
var sfx_hit_counter: AudioStream = preload("res://assets/audio/sfx/hit_counter.wav")
var sfx_block: AudioStream = preload("res://assets/audio/sfx/block.wav")
var sfx_whiff: AudioStream = preload("res://assets/audio/sfx/whiff.wav")


func enter(_prev_state: String) -> void:
	frame_counter = 0
	phase = "startup"
	hit_confirmed = false
	whiff_played = false

	if current_move:
		# Set crouching for d+moves
		var cmd = current_move.input_command if current_move else ""
		fighter.is_crouching = cmd.begins_with("d+")
		# Activate hitbox
		if fighter.has_node("HitSystem"):
			fighter.get_node("HitSystem").activate(current_move.pose_name)


func exit() -> void:
	fighter.is_crouching = false
	if fighter.has_node("HitSystem"):
		fighter.get_node("HitSystem").deactivate()


func start_move(move: Resource) -> void:
	current_move = move
	frame_counter = 0
	phase = "startup"
	hit_confirmed = false
	whiff_played = false
	# Re-activate hit system for the new move (resets has_hit)
	if fighter.has_node("HitSystem"):
		fighter.get_node("HitSystem").activate(move.pose_name)
	# Update crouching state for d+ moves
	var cmd = move.input_command if move else ""
	fighter.is_crouching = cmd.begins_with("d+")


func handle_input(input_bits: int) -> String:
	if current_move == null:
		return "Idle"

	# During string window, check for followup
	if phase == "string_window":
		var registry = fighter.move_registry
		if registry:
			var followup = registry.get_string_followup(current_move, input_bits, fighter.input_buffer)
			if followup:
				start_move(followup)
				return ""

	return ""


func tick(_delta: float) -> String:
	if current_move == null:
		return "Idle"

	frame_counter += 1

	# Determine phase
	var total = current_move.get_total_frames()
	var recovery_start = current_move.startup_frames + current_move.active_frames
	var string_overlap = 4  # String window starts this many frames before recovery ends

	if frame_counter <= current_move.startup_frames:
		phase = "startup"
	elif frame_counter <= recovery_start:
		phase = "active"
		# Play whiff swoosh on first active frame (overridden by hit sound if it connects)
		if not whiff_played:
			whiff_played = true
			_play_sfx(sfx_whiff)
	elif frame_counter <= total:
		phase = "recovery"
		# String window overlaps with late recovery (only for string moves)
		if current_move.string_followup_command != "" and frame_counter >= total - string_overlap:
			phase = "string_window"
		# Standard buffer: accept inputs during last ACTION_BUFFER_WINDOW frames of recovery
		# These execute AFTER recovery ends (no cancel), unlike string followups
		if frame_counter >= total - fighter.input_buffer.ACTION_BUFFER_WINDOW:
			_try_buffer_action()
	elif current_move.string_followup_command != "" and frame_counter <= total + current_move.string_window_frames:
		phase = "string_window"
		_try_buffer_action()
	else:
		return "Idle"

	# Drive animation — linear progress, pose functions handle their own phasing
	var progress: float = clampf(float(frame_counter) / total, 0.0, 1.0)
	var m = get_model()
	if m:
		match current_move.pose_name:
			"jab":
				m.set_pose_jab(progress)
			"jab_2":
				m.set_pose_jab_2(progress)
			"power_straight":
				m.set_pose_power_straight(progress)
			"high_crush":
				m.set_pose_high_crush(progress)
			"low_kick":
				m.set_pose_low_kick(progress)
			"high_kick":
				m.set_pose_high_kick(progress)
			"d_low_kick":
				m.set_pose_d_low_kick(progress)
			"d_mid_punch":
				m.set_pose_d_mid_punch(progress)
			"df1_check":
				m.set_pose_df_mid_check(progress)
			"d4_kick":
				m.set_pose_d4_kick(progress)
			"d3_3_rising":
				m.set_pose_d3_3_rising(progress)

	# Hit detection during active frames
	if phase == "active" and not hit_confirmed:
		if fighter.has_node("HitSystem"):
			var hit = fighter.get_node("HitSystem").check_hit()
			if not hit.is_empty():
				hit_confirmed = true
				_apply_hit(hit)

	# No forward lunge — spacing is controlled by movement only
	# Only apply forward_lunge if explicitly set > 0 on the move
	if current_move.forward_lunge > 0 and (phase == "startup" or phase == "active"):
		var fwd = fighter.get_forward_direction()
		fighter.velocity = fwd * current_move.forward_lunge * 60.0
	else:
		fighter.velocity.x = 0
		fighter.velocity.z = 0

	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""


func _apply_hit(hit: Dictionary) -> void:
	var defender = hit["defender"] as CharacterBody3D
	var damage = hit["damage"]
	var blocked = hit["blocked"]
	var is_counter_hit = hit.get("counter_hit", false)

	# Counter hit bonus damage
	if is_counter_hit:
		damage = int(damage * 1.3)

	# Play hit/block sound (overrides whiff swoosh)
	if blocked:
		_play_sfx(sfx_block)
	elif is_counter_hit:
		_play_sfx(sfx_hit_counter)
	elif current_move.causes_knockdown:
		_play_sfx(sfx_hit_heavy)
	else:
		_play_sfx(sfx_hit_light)

	# Apply hitstop to both fighters (freeze on hit for impact feel)
	var hitstop = current_move.hitstop_frames if not blocked else int(current_move.hitstop_frames * 0.6)
	if is_counter_hit:
		hitstop += 2
	fighter.hitstop_remaining = hitstop
	defender.hitstop_remaining = hitstop

	# Screen shake on hit (not on block)
	if not blocked:
		var shake_damage = int(damage * 1.5) if is_counter_hit else damage
		var cam = get_tree().current_scene.get_node_or_null("FightCamera")
		if cam and cam.has_method("apply_hit_shake"):
			cam.apply_hit_shake(shake_damage, current_move.causes_knockdown)

	if blocked:
		# No chip damage on block
		damage = 0
		# Apply blockstun to defender
		if defender.state_machine:
			defender.state_machine.enter_blockstun(current_move.blockstun_frames)
	else:
		# Full hit
		if defender.state_machine:
			if current_move.causes_knockdown:
				var is_soft = current_move.soft_knockdown if "soft_knockdown" in current_move else false
				defender.state_machine.enter_knockdown(is_soft)
			else:
				var bonus_hitstun = 5 if is_counter_hit else 0
				defender.state_machine.enter_hitstun(current_move.hitstun_frames + bonus_hitstun)

	# Emit counter hit signal for training HUD (suppress during rollback resim)
	if is_counter_hit and not RollbackManager.is_resimulating:
		GameManager.counter_hit_landed.emit(fighter.player_id)

	# Apply damage through GameManager
	GameManager.apply_damage(defender.player_id, damage)

	# Knockback on defender — store as pending so hitstop doesn't wipe it
	var kb_dir = fighter.get_forward_direction()
	var kb_force = current_move.pushback_block if blocked else current_move.knockback
	defender.pending_knockback = kb_dir * kb_force * 2.0

	# Attacker recoil on knockdown — push attacker back so they must re-approach
	if not blocked and current_move.causes_knockdown:
		fighter.pending_knockback = -kb_dir * kb_force * 0.8


func save_state() -> Dictionary:
	return {
		"fc": frame_counter,
		"phase": phase,
		"hit": hit_confirmed,
		"whiff": whiff_played,
		"move_cmd": current_move.input_command if current_move else "",
	}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	phase = s.get("phase", "startup")
	hit_confirmed = s.get("hit", false)
	whiff_played = s.get("whiff", false)
	var cmd = s.get("move_cmd", "")
	if cmd != "" and fighter and fighter.move_registry:
		current_move = fighter.move_registry.moves.get(cmd)


func _play_sfx(stream: AudioStream) -> void:
	# Suppress audio during rollback re-simulation
	if RollbackManager.is_resimulating:
		return
	if fighter.sfx_player:
		fighter.sfx_player.stream = stream
		fighter.sfx_player.play()


func _try_buffer_action() -> void:
	# Check if player is pressing an attack button during recovery
	var buf = fighter.input_buffer
	var input_bits = buf.get_current()
	var move = fighter.move_registry.get_move_for_input(input_bits, buf)
	if move:
		buf.buffer_action("attack", move)
