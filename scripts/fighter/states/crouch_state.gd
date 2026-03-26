class_name CrouchState
extends FighterState

# Crouching state — entered via d/b or hold down
# Has a transition period (crouch_frames) before fully crouched
# While crouching: high attacks whiff, can crouch block with back held

const CROUCH_TRANSITION_FRAMES: int = 4  # Frames to reach full crouch

var frame_counter: int = 0
var fully_crouched: bool = false
var from_backdash: bool = false  # Track if we entered from backdash (for KBD)


func save_state() -> Dictionary:
	return {"fc": frame_counter, "full": fully_crouched, "fbd": from_backdash}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	fully_crouched = s.get("full", false)
	from_backdash = s.get("fbd", false)


func enter(prev_state: String) -> void:
	frame_counter = 0
	fully_crouched = false
	fighter.velocity = Vector3.ZERO
	fighter.is_crouching = true
	from_backdash = (prev_state == "Backdash")
	var m = get_model()
	if m:
		m.set_pose_crouch()


func exit() -> void:
	fighter.is_crouching = false


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer

	var holding_down = IM.has_flag(input_bits, IM.INPUT_DOWN)
	var holding_back = IM.has_flag(input_bits, IM.INPUT_BACK)

	# Release down — stand up
	if not holding_down and not holding_back:
		return "Idle"

	# KBD shortcut: if entered from backdash, back press = new backdash
	# Flow: backdash → d/b (crouch) → b (new backdash)
	if from_backdash:
		if buf.just_pressed(IM.INPUT_BACK):
			return "Backdash"
		# Released down while holding back = backdash
		if holding_back and not holding_down:
			return "Backdash"

	# Back+Down = crouch block (stay in crouch, don't exit)
	if holding_back and holding_down:
		return ""

	# Just back (no down) — stand block / walk backward
	if holding_back and not holding_down:
		return "WalkBackward"

	# Forward from crouch — only crouch dash via proper f,n,d,df sequence
	# Just pressing forward while crouching stands up to walk forward
	if IM.has_flag(input_bits, IM.INPUT_FORWARD) and not holding_down:
		return "WalkForward"
	# df while crouching = stay crouching (vulnerable, for df+moves)
	if IM.has_flag(input_bits, IM.INPUT_FORWARD) and holding_down:
		return ""  # Stay in crouch
	# Only actual crouch dash motion triggers wavedash
	if buf.detect_crouch_dash_input():
		return "CrouchDash"

	# Backdash from crouch (double-tap back always works)
	if buf.detect_double_tap(IM.INPUT_BACK):
		return "Backdash"

	# Sidestep from crouch
	if buf.detect_double_tap(IM.INPUT_UP):
		return "SidestepUp"
	if buf.detect_double_tap(IM.INPUT_DOWN):
		return "SidestepDown"

	# Attack from crouch
	var attack_result = try_attack(input_bits)
	if attack_result != "":
		return attack_result

	return ""


func tick(_delta: float) -> String:
	frame_counter += 1
	if frame_counter >= CROUCH_TRANSITION_FRAMES:
		fully_crouched = true

	fighter.velocity = Vector3.ZERO
	fighter.move_and_slide()
	return ""
