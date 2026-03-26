class_name HopState
extends FighterState

# Small low-evading hop: tap UP
# Quick upward motion that evades lows (legs leave the ground briefly)
# Cannot block during hop — commitment move for reading low attacks
# Low profile evasion is during the rising frames

const HOP_DURATION: int = 18  # Total frames
const RISE_FRAMES: int = 6  # Frames going up
const PEAK_FRAMES: int = 4  # Frames at peak
const FALL_FRAMES: int = 8  # Frames coming down
const HOP_HEIGHT: float = 0.6  # Subtle hop, not a full jump
const EVASION_START: int = 2  # Frame low evasion begins
const EVASION_END: int = 12  # Frame low evasion ends

var frame_counter: int = 0
var base_y: float = 0.0
var is_evading_lows: bool = false  # Used by combat resolver later


func save_state() -> Dictionary:
	return {"fc": frame_counter, "by": base_y, "ev": is_evading_lows}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	base_y = s.get("by", 0.0)
	is_evading_lows = s.get("ev", false)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	base_y = fighter.global_position.y
	is_evading_lows = false
	fighter.is_crouching = false


func handle_input(_input_bits: int) -> String:
	# Buffer actions during late hop for immediate action on landing
	var buf = fighter.input_buffer
	var remaining = HOP_DURATION - frame_counter
	if remaining <= buf.ACTION_BUFFER_WINDOW:
		var input_bits = buf.get_current()
		var move = fighter.move_registry.get_move_for_input(input_bits, buf)
		if move:
			buf.buffer_action("attack", move)
	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	is_evading_lows = frame_counter >= EVASION_START and frame_counter <= EVASION_END

	if frame_counter >= HOP_DURATION:
		fighter.global_position.y = base_y
		return "Idle"

	var progress = float(frame_counter) / HOP_DURATION
	var m = get_model()
	if m:
		m.set_pose_hop(progress)

	# Calculate Y offset based on phase
	var y_offset: float = 0.0
	if frame_counter <= RISE_FRAMES:
		# Rising
		var t = float(frame_counter) / RISE_FRAMES
		y_offset = HOP_HEIGHT * sin(t * PI * 0.5)  # Ease-out rise
	elif frame_counter <= RISE_FRAMES + PEAK_FRAMES:
		# Peak
		y_offset = HOP_HEIGHT
	else:
		# Falling
		var fall_frame = frame_counter - RISE_FRAMES - PEAK_FRAMES
		var t = float(fall_frame) / FALL_FRAMES
		y_offset = HOP_HEIGHT * cos(t * PI * 0.5)  # Ease-in fall

	fighter.global_position.y = base_y + y_offset

	# Slight forward drift during hop
	var forward_dir = fighter.get_forward_direction()
	fighter.velocity = forward_dir * 1.0
	fighter.velocity.y = 0
	fighter.move_and_slide()
	# Restore Y (move_and_slide may affect it)
	fighter.global_position.y = base_y + y_offset

	return ""
