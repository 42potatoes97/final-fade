extends FighterState

# Getting up from knockdown — brief invulnerability

const GETUP_DURATION: int = 24  # frames to stand up

var frame_counter: int = 0


func save_state() -> Dictionary:
	return {"fc": frame_counter}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.velocity = Vector3.ZERO
	# Getup defaults to standing block — only lows connect as follow-up
	fighter.is_crouching = false
	fighter.is_blocking_on_getup = true


func handle_input(_input_bits: int) -> String:
	# Buffer actions during late getup for immediate wakeup attack
	var buf = fighter.input_buffer
	var remaining = GETUP_DURATION - frame_counter
	if remaining <= buf.ACTION_BUFFER_WINDOW:
		var input_bits = buf.get_current()
		var move = fighter.move_registry.get_move_for_input(input_bits, buf)
		if move:
			buf.buffer_action("attack", move)
	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	var progress = float(frame_counter) / GETUP_DURATION
	var m = get_model()
	if m:
		m.set_pose_getup(progress)

	fighter.velocity.x = 0
	fighter.velocity.z = 0
	fighter.move_and_slide()

	if frame_counter >= GETUP_DURATION:
		fighter.is_blocking_on_getup = false
		return "Idle"
	return ""
