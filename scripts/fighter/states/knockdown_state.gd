extends FighterState

# Knocked down on the ground — wake-up system
# Options after MIN_FLOOR_FRAMES:
#   1. Stay down (default) — vulnerable to ground hits
#   2. Quick getup (press 1, 2, f, or b) — fast stand with auto block
#   3. Getup kick (press 3 or 4) — rising attack, punishable
#   4. Side roll (press up or down) — dodge sideways

const MIN_FLOOR_FRAMES: int = 35  # Must stay down at least this long (hard KD, ~580ms)
const SOFT_MIN_FLOOR_FRAMES: int = 8  # Soft KD: wakeup options available quickly but not instant
const MAX_FLOOR_FRAMES: int = 90  # Auto-getup after this (prevent infinite stalling)
const KD_SLIDE_SPEED: float = 3.0  # Slide away from attacker on KD (prevents loops)
const KD_SLIDE_FRAMES: int = 10  # Frames of sliding

var frame_counter: int = 0
var is_soft: bool = false
var _slide_dir: Vector3 = Vector3.ZERO


func save_state() -> Dictionary:
	return {"fc": frame_counter, "soft": is_soft, "sd": [_slide_dir.x, _slide_dir.y, _slide_dir.z]}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	is_soft = s.get("soft", false)
	var sd = s.get("sd", [0, 0, 0])
	_slide_dir = Vector3(sd[0], sd[1], sd[2])


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.is_crouching = false
	# Slide away from opponent on knockdown to create spacing
	if fighter.opponent:
		_slide_dir = (fighter.global_position - fighter.opponent.global_position).normalized()
		_slide_dir.y = 0
		fighter.velocity = _slide_dir * KD_SLIDE_SPEED
	else:
		_slide_dir = Vector3.ZERO
		fighter.velocity = Vector3.ZERO
	var m = get_model()
	if m:
		m.set_pose_knockdown()


func handle_input(_input_bits: int) -> String:
	return ""


func tick(_delta: float) -> String:
	frame_counter += 1
	# Slide away from attacker during first KD_SLIDE_FRAMES
	if frame_counter <= KD_SLIDE_FRAMES and _slide_dir != Vector3.ZERO:
		var decay: float = 1.0 - float(frame_counter) / KD_SLIDE_FRAMES
		fighter.velocity = _slide_dir * KD_SLIDE_SPEED * decay
	else:
		fighter.velocity.x = 0
		fighter.velocity.z = 0
	fighter.velocity.y = 0
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
