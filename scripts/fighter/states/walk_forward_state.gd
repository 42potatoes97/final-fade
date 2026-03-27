class_name WalkForwardState
extends FighterState

const WALK_SPEED: float = 5.5
var walk_phase: float = 0.0


func save_state() -> Dictionary:
	return {"wp": walk_phase}

func load_state(s: Dictionary) -> void:
	walk_phase = s.get("wp", 0.0)


func enter(_prev_state: String) -> void:
	walk_phase = 0.0


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	if not IM.has_flag(input_bits, IM.INPUT_FORWARD):
		return "Idle"

	if buf.detect_double_tap(IM.INPUT_FORWARD):
		return "DashForward"
	if buf.detect_double_tap(IM.INPUT_BACK):
		return "Backdash"
	if buf.detect_crouch_dash_input():
		return "CrouchDash"
	if buf.detect_double_tap(IM.INPUT_UP):
		return "SidestepUp"
	if buf.detect_double_tap(IM.INPUT_DOWN):
		return "SidestepDown"
	# u/f = hop (already holding forward, just press UP to complete u/f)
	if IM.has_flag(input_bits, IM.INPUT_UP):
		return "Hop"
	if IM.has_flag(input_bits, IM.INPUT_DOWN):
		return "Crouch"

	# Attack cancel — can attack out of walk
	var attack_result = try_attack(input_bits)
	if attack_result != "":
		return attack_result

	return ""


func tick(delta: float) -> String:
	walk_phase += delta * 8.0  # Walk cycle speed
	var m = get_model()
	if m:
		m.set_pose_walk_forward(walk_phase)

	var forward_dir = fighter.get_forward_direction()
	fighter.velocity = forward_dir * WALK_SPEED
	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
