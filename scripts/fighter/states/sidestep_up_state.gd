class_name SidestepUpState
extends FighterState

# Quick lateral dodge toward +Z (into screen from default camera)
# Cancelable after CANCEL_FROM into: backdash, attack, sidestep, crouch dash, crouch

const STEP_SPEED: float = 8.0
const STEP_DURATION: int = 10
const SIDEWALK_TRANSITION: int = 8
const CANCEL_FROM: int = 3  # Can cancel after 3 frames (snappy)

var frame_counter: int = 0


func save_state() -> Dictionary:
	return {"fc": frame_counter}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.is_crouching = false
	var m = get_model()
	if m:
		m.set_pose_sidestep(1.0)


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	# Sidewalk transition if holding up
	if frame_counter >= SIDEWALK_TRANSITION and IM.has_flag(input_bits, IM.INPUT_UP):
		return "SidewalkUp"

	# Cancel options after CANCEL_FROM frames
	if frame_counter >= CANCEL_FROM:
		# Backdash (double-tap back) — most important cancel
		if buf.detect_double_tap(IM.INPUT_BACK):
			return "Backdash"
		# Forward dash
		if buf.detect_double_tap(IM.INPUT_FORWARD):
			return "DashForward"
		# Crouch dash
		if buf.detect_crouch_dash_input():
			return "CrouchDash"
		# Opposite sidestep
		if buf.detect_double_tap(IM.INPUT_DOWN):
			return "SidestepDown"
		# Re-sidestep
		if buf.detect_double_tap(IM.INPUT_UP):
			return "SidestepUp"
		# Crouch
		if IM.has_flag(input_bits, IM.INPUT_DOWN) and IM.has_flag(input_bits, IM.INPUT_BACK):
			return "Crouch"
		# Walk forward (forward held, UP not held)
		if IM.has_flag(input_bits, IM.INPUT_FORWARD) and not IM.has_flag(input_bits, IM.INPUT_UP):
			return "WalkForward"
		# Walk backward (back held, UP not held)
		if IM.has_flag(input_bits, IM.INPUT_BACK) and not IM.has_flag(input_bits, IM.INPUT_UP):
			return "WalkBackward"
		# Hop (u/f)
		if IM.has_flag(input_bits, IM.INPUT_UP) and IM.has_flag(input_bits, IM.INPUT_FORWARD):
			return "Hop"
		# Attack cancel
		var attack_result = try_attack(input_bits)
		if attack_result != "":
			return attack_result

	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	if frame_counter >= STEP_DURATION:
		# Delay opponent's realignment — gives sidestepper advantage
		if fighter.opponent:
			fighter.opponent.trigger_realignment_delay()
		return "Idle"

	var side_dir = -fighter.get_side_direction()
	var speed_factor = 1.0 - (float(frame_counter) / STEP_DURATION) * 0.5
	fighter.velocity = side_dir * STEP_SPEED * speed_factor
	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
