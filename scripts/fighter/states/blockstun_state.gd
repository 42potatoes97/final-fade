extends FighterState

# Blockstun — fighter blocked an attack, visible block animation with recoil

var stun_frames: int = 6
var frame_counter: int = 0


func enter(_prev_state: String) -> void:
	frame_counter = 0
	# Clear getup block flag — committed to blockstun now
	fighter.is_blocking_on_getup = false
	var m = get_model()
	if m:
		m.idle_bob_active = false
		m.blend_speed = 30.0


func handle_input(_input_bits: int) -> String:
	# Buffer inputs during late blockstun
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
	stun_frames = s.get("sf", 6)
	frame_counter = s.get("fc", 0)


func tick(_delta: float) -> String:
	frame_counter += 1

	var m = get_model()
	if m:
		var total = max(stun_frames, 1)
		var progress = float(frame_counter) / total
		# Impact peaks at 0.2, then recovers
		var impact = sin(clampf(progress / 0.3, 0.0, 1.0) * PI * 0.5)
		var recover = clampf((progress - 0.3) / 0.7, 0.0, 1.0)
		var r = impact * (1.0 - recover)

		# Block pose: arms tighten to guard, torso recoils back, knees bend slightly
		m._set_pose({
			"abdomen": Vector3(r * -8, 0, 0),
			"torso": Vector3(2 + r * -12, 0, 0),
			"head": Vector3(r * 5, -1, -1),
			# Arms tighten inward — elbows pull in, forearms cross closer to face
			"arm_l": Vector3(-76 + r * 15, 20 + r * -10, 73 + r * -15),
			"forearm_l": Vector3(-10 + r * 5, 79 + r * 20, -1),
			"arm_r": Vector3(-81 + r * 15, -32 + r * 10, -73 + r * 15),
			"forearm_r": Vector3(6 + r * -5, -66 + r * -20, 0),
			# Knees bend slightly to absorb impact
			"leg_l": Vector3(21 + r * -15, 0, 0),
			"shin_l": Vector3(34 + r * 20, 13, -6),
			"leg_r": Vector3(-39 + r * -10, -1, 0),
			"shin_r": Vector3(34 + r * 15, 0, 0),
			"foot_r": Vector3(-1, 0, 0),
		}, Vector3(0, r * -0.05, 0))

	# Pushback — decelerating
	fighter.velocity.x *= 0.85
	fighter.velocity.z *= 0.85
	fighter.velocity.y = 0
	fighter.move_and_slide()

	if frame_counter >= stun_frames:
		return "Idle"
	return ""
