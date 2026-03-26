extends FighterState

# Knocked down on the ground — wake-up system
# Options after MIN_FLOOR_FRAMES:
#   1. Stay down (default) — vulnerable to ground hits
#   2. Quick getup (press 1, 2, f, or b) — fast stand with auto block
#   3. Getup kick (press 3 or 4) — rising attack, punishable
#   4. Side roll (press up or down) — dodge sideways

const MIN_FLOOR_FRAMES: int = 16  # Must stay down at least this long (hard KD)
const SOFT_MIN_FLOOR_FRAMES: int = 4  # Soft KD: wakeup options available almost immediately
const MAX_FLOOR_FRAMES: int = 90  # Auto-getup after this (prevent infinite stalling)

var frame_counter: int = 0
var is_soft: bool = false


func save_state() -> Dictionary:
	return {"fc": frame_counter, "soft": is_soft}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	is_soft = s.get("soft", false)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.velocity = Vector3.ZERO
	fighter.is_crouching = false
	var m = get_model()
	if m:
		m.set_pose_knockdown()


func handle_input(_input_bits: int) -> String:
	return ""


func tick(_delta: float) -> String:
	frame_counter += 1
	fighter.velocity.x = 0
	fighter.velocity.z = 0
	fighter.move_and_slide()

	# Training mode: auto-getup after minimum floor time + delay
	if GameManager.training_mode and frame_counter >= MIN_FLOOR_FRAMES + 20:
		return "Getup"

	# Force getup at max floor time
	if frame_counter >= MAX_FLOOR_FRAMES:
		return "Getup"

	# Wake-up options — soft KD lets you act much sooner
	var min_frames = SOFT_MIN_FLOOR_FRAMES if is_soft else MIN_FLOOR_FRAMES
	if frame_counter >= min_frames:
		var input_bits = fighter.input_buffer.get_current()
		var IM = InputManager

		# Getup kick — press 3 or 4 (rising attack)
		if fighter.input_buffer.just_pressed(IM.INPUT_BUTTON3) or fighter.input_buffer.just_pressed(IM.INPUT_BUTTON4):
			return "GetupKick"

		# Side roll — press up or down (lateral dodge)
		if fighter.input_buffer.just_pressed(IM.INPUT_UP):
			return "SideRoll"
		if fighter.input_buffer.just_pressed(IM.INPUT_DOWN):
			return "SideRoll"

		# Quick getup — press 1, 2, forward, or back (stand with auto block)
		var quick_getup = (input_bits & (IM.INPUT_BUTTON1 | IM.INPUT_BUTTON2 | IM.INPUT_FORWARD | IM.INPUT_BACK)) != 0
		if quick_getup:
			return "Getup"

	return ""
