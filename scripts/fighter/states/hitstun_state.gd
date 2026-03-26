extends FighterState

# Hitstun — fighter got hit, cannot act for stun_frames

var stun_frames: int = 12
var frame_counter: int = 0


func enter(_prev_state: String) -> void:
	frame_counter = 0
	fighter.is_blocking_on_getup = false
	var m = get_model()
	if m:
		m.idle_bob_active = false
		m.blend_speed = 25.0


func handle_input(_input_bits: int) -> String:
	# Buffer inputs during late hitstun
	var buf = fighter.input_buffer
	var remaining = stun_frames - frame_counter
	if remaining <= buf.ACTION_BUFFER_WINDOW:
		var input_bits = buf.get_current()
		var move = fighter.move_registry.get_move_for_input(input_bits, buf)
		if move:
			buf.buffer_action("attack", move)
	return ""


func save_state() -> Dictionary:
	return {"sf": stun_frames, "fc": frame_counter}

func load_state(s: Dictionary) -> void:
	stun_frames = s.get("sf", 12)
	frame_counter = s.get("fc", 0)


func tick(_delta: float) -> String:
	frame_counter += 1

	# Reel-back animation
	var m = get_model()
	if m:
		var p = sin(float(frame_counter) / stun_frames * PI)
		m._set_pose({
			"torso": Vector3(p * -8, p * 5, 0),
			"head": Vector3(p * -10, p * 8, 0),
		})

	# Decelerate knockback — fast deceleration keeps defender closer for strings
	fighter.velocity.x *= 0.8
	fighter.velocity.z *= 0.8
	fighter.velocity.y = 0
	fighter.move_and_slide()

	if frame_counter >= stun_frames:
		return "Idle"
	return ""
