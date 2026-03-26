extends FighterState

# Side roll — lateral dodge from knockdown
# Rolls sideways to avoid ground attacks and oki pressure
# Vulnerable during roll (can be hit by tracking moves)

const ROLL_DURATION: int = 20  # Total frames for the roll
const ROLL_SPEED: float = 4.0  # Lateral movement speed
const GETUP_FRAMES: int = 10  # Frames to stand up after roll

var frame_counter: int = 0
var roll_direction: int = 1  # 1 = roll toward camera, -1 = away


func save_state() -> Dictionary:
	return {"fc": frame_counter, "rd": roll_direction}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	roll_direction = s.get("rd", 1)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.velocity = Vector3.ZERO
	fighter.is_crouching = false
	fighter.is_blocking_on_getup = false  # Vulnerable during roll

	# Determine roll direction based on last input
	var input_bits = fighter.input_buffer.get_current()
	var IM = InputManager
	if IM.has_flag(input_bits, IM.INPUT_DOWN):
		roll_direction = 1
	else:
		roll_direction = -1


func handle_input(_input_bits: int) -> String:
	return ""


func tick(_delta: float) -> String:
	frame_counter += 1
	var total = ROLL_DURATION + GETUP_FRAMES

	if frame_counter > total:
		return "Idle"

	var m = get_model()

	if frame_counter <= ROLL_DURATION:
		# Rolling phase — lateral movement
		var progress = float(frame_counter) / ROLL_DURATION
		var speed_factor = sin(progress * PI)  # Peak speed in middle of roll

		var side_dir = fighter.get_side_direction() * roll_direction
		fighter.velocity = side_dir * ROLL_SPEED * speed_factor
		fighter.velocity.y = 0

		# Roll animation — rotate the model
		if m:
			m.set_pose_side_roll(progress, roll_direction)
	else:
		# Standing up after roll
		var getup_progress = float(frame_counter - ROLL_DURATION) / GETUP_FRAMES
		fighter.velocity.x = 0
		fighter.velocity.z = 0

		if m:
			m.set_pose_getup(getup_progress)

		# Auto block during getup portion
		if not fighter.is_blocking_on_getup:
			fighter.is_blocking_on_getup = true

	fighter.move_and_slide()
	return ""


func exit() -> void:
	fighter.is_blocking_on_getup = false
