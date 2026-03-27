class_name CrouchDashState
extends FighterState

# Crouch dash: f,n,d,df — low-profile forward movement while crouching
# Foundation of wavedash: cancel into standing, then immediately do another crouch dash
# Can also cancel into attacks later

const DASH_SPEED: float = 7.5  # Slightly faster for better wavedash chains
const DASH_DURATION: int = 12  # Tighter for snappier wavedash
const CANCELABLE_AFTER: int = 4  # Cancel earlier — wavedash chains feel responsive
const MIN_NEUTRAL_BEFORE_RECHAIN: int = 2  # Must be in neutral/forward for 2 frames before next CD

var frame_counter: int = 0


func save_state() -> Dictionary:
	return {"fc": frame_counter}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.is_crouching = true


func exit() -> void:
	fighter.is_crouching = false


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	if frame_counter < CANCELABLE_AFTER:
		return ""

	# Wavedash cancel: release to standing (neutral or forward)
	# Goes to IDLE — player must do the full f,n,d,df again for next crouch dash
	# No free dash forward — you must earn each crouch dash with proper input
	var holding_down = IM.has_flag(input_bits, IM.INPUT_DOWN)
	var holding_fwd = IM.has_flag(input_bits, IM.INPUT_FORWARD)
	var holding_back = IM.has_flag(input_bits, IM.INPUT_BACK)

	# Release down = stand up (cancel point for wavedash chain)
	if not holding_down and not holding_back:
		return "Idle"  # Must go through Idle — no shortcuts

	# Cancel into full crouch (hold down without forward)
	if holding_down and not holding_fwd:
		return "Crouch"

	# Cancel into backdash
	if buf.detect_double_tap(IM.INPUT_BACK):
		return "Backdash"

	# Attack cancel from crouch dash
	var attack_result = try_attack(input_bits)
	if attack_result != "":
		return attack_result

	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	if frame_counter >= DASH_DURATION:
		return "Crouch"

	var progress = float(frame_counter) / DASH_DURATION
	var m = get_model()
	if m:
		m.set_pose_crouch_dash(progress)

	var forward_dir = fighter.get_forward_direction()
	# Sharp deceleration — fast start, quick stop
	var speed_factor = max(0.0, 1.0 - progress * progress * 2.0)
	fighter.velocity = forward_dir * DASH_SPEED * speed_factor
	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
