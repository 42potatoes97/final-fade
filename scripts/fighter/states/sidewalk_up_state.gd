class_name SidewalkUpState
extends FighterState

# Continuous lateral movement (hold up after sidestep)

const WALK_SPEED: float = 5.0


func enter(_prev_state: String) -> void:
	var m = get_model()
	if m:
		m.set_pose_sidestep(1.0)


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	if not IM.has_flag(input_bits, IM.INPUT_UP):
		return "Idle"
	if IM.has_flag(input_bits, IM.INPUT_FORWARD):
		return "WalkForward"
	if IM.has_flag(input_bits, IM.INPUT_BACK):
		return "WalkBackward"

	# Dash cancels
	if buf.detect_double_tap(IM.INPUT_BACK):
		return "Backdash"
	if buf.detect_double_tap(IM.INPUT_FORWARD):
		return "DashForward"

	# Attack cancel
	var attack_result = try_attack(input_bits)
	if attack_result != "":
		return attack_result

	return ""


func tick(_delta: float) -> String:
	var side_dir = -fighter.get_side_direction()
	fighter.velocity = side_dir * WALK_SPEED
	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
