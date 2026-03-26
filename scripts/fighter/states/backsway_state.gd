class_name BackswayState
extends FighterState

# Backsway: backward lean that evades linear attacks
# Entered from backdash cancel (d/b during backdash recovery) or specific input
# Upper body leans back — can evade highs and some mids
# Has recovery before returning to neutral
# Can cancel into attacks or backdash

const SWAY_DURATION: int = 20  # Total frames
const EVASION_START: int = 2  # Frame evasion begins
const EVASION_END: int = 12  # Frame evasion ends
const CANCELABLE_AFTER: int = 8  # Can cancel into actions
const SWAY_SPEED: float = 2.0  # Slight backward drift during sway

var frame_counter: int = 0
var is_evading: bool = false  # Used by combat resolver later


func save_state() -> Dictionary:
	return {"fc": frame_counter, "ev": is_evading}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	is_evading = s.get("ev", false)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	is_evading = false
	fighter.is_crouching = false


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	if frame_counter < CANCELABLE_AFTER:
		return ""

	# Cancel into backdash
	if buf.detect_double_tap(IM.INPUT_BACK):
		return "Backdash"

	# Cancel into crouch
	if IM.has_flag(input_bits, IM.INPUT_DOWN):
		return "Crouch"

	# Cancel into forward dash (aggressive option)
	if buf.detect_double_tap(IM.INPUT_FORWARD):
		return "DashForward"

	# Cancel into sidestep
	if buf.just_pressed(IM.INPUT_UP):
		return "SidestepUp"
	if buf.just_pressed(IM.INPUT_DOWN) and not IM.has_flag(input_bits, IM.INPUT_BACK):
		return "SidestepDown"

	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	is_evading = frame_counter >= EVASION_START and frame_counter <= EVASION_END

	if frame_counter >= SWAY_DURATION:
		return "Idle"

	var progress = float(frame_counter) / SWAY_DURATION
	var m = get_model()
	if m:
		m.set_pose_backsway(progress)

	# Slight backward drift during sway
	var backward_dir = -fighter.get_forward_direction()
	var drift = 0.0
	if frame_counter <= EVASION_END:
		drift = SWAY_SPEED * (1.0 - float(frame_counter) / EVASION_END)
	fighter.velocity = backward_dir * drift
	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
