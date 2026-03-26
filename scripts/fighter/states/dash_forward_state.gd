class_name DashForwardState
extends FighterState

# Forward dash: quick burst of forward movement (f, f input)
# Can be canceled into crouch dash for wavedash

const DASH_SPEED: float = 7.5
const DASH_DURATION: int = 16  # frames — slight hop feel
const CANCELABLE_AFTER: int = 6  # frames before cancel is allowed

var frame_counter: int = 0


func save_state() -> Dictionary:
	return {"fc": frame_counter}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.is_crouching = false


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	# Cancels after cancelable window
	if frame_counter >= CANCELABLE_AFTER:
		if buf.detect_crouch_dash_input():
			return "CrouchDash"
		if IM.has_flag(input_bits, IM.INPUT_DOWN):
			return "Crouch"
		# Backdash cancel
		if buf.detect_double_tap(IM.INPUT_BACK):
			return "Backdash"
		# Sidestep cancels
		if buf.detect_double_tap(IM.INPUT_UP):
			return "SidestepUp"
		if buf.detect_double_tap(IM.INPUT_DOWN):
			return "SidestepDown"
		# Attack cancel (dash attacks)
		var attack_result = try_attack(input_bits)
		if attack_result != "":
			return attack_result

	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	if frame_counter >= DASH_DURATION:
		fighter.backdash_cooldown = fighter.BACKDASH_COOLDOWN_FRAMES  # Reuse cooldown for forward dash too
		return "Idle"

	var progress = float(frame_counter) / DASH_DURATION
	var m = get_model()
	if m:
		m.set_pose_dash_forward(progress)

	var forward_dir = fighter.get_forward_direction()
	var speed_factor = 1.0 - progress * 0.4
	fighter.velocity = forward_dir * DASH_SPEED * speed_factor
	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
