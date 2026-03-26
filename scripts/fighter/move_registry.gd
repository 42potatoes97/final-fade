extends RefCounted

# Maps input commands to move data resources
# Priority: directional moves > raw buttons

var moves: Dictionary = {}


func register_move(command: String, data: Resource) -> void:
	moves[command] = data


func get_move_for_input(input_bits: int, input_buffer) -> Resource:
	var IM = InputManager
	var holding_down = IM.has_flag(input_bits, IM.INPUT_DOWN)

	var holding_forward = IM.has_flag(input_bits, IM.INPUT_FORWARD)

	# Directional + button combos first (most specific first)
	# df+button (down+forward+button)
	if holding_down and holding_forward:
		if IM.has_flag(input_bits, IM.INPUT_BUTTON1) and moves.has("df+1"):
			return moves["df+1"]

	# d+button (down+button, no forward)
	if holding_down:
		if IM.has_flag(input_bits, IM.INPUT_BUTTON3) and moves.has("d+3"):
			return moves["d+3"]
		if IM.has_flag(input_bits, IM.INPUT_BUTTON4) and not holding_forward and moves.has("d+4"):
			return moves["d+4"]
		if IM.has_flag(input_bits, IM.INPUT_BUTTON1) and not holding_forward and moves.has("d+1"):
			return moves["d+1"]

	# Raw button presses (only on just_pressed to avoid repeat)
	if input_buffer.just_pressed(IM.INPUT_BUTTON1) and not holding_down and moves.has("1"):
		return moves["1"]
	if input_buffer.just_pressed(IM.INPUT_BUTTON2) and not holding_down and moves.has("2"):
		return moves["2"]
	if input_buffer.just_pressed(IM.INPUT_BUTTON3) and not holding_down and moves.has("3"):
		return moves["3"]
	if input_buffer.just_pressed(IM.INPUT_BUTTON4) and not holding_down and moves.has("4"):
		return moves["4"]

	return null


func get_string_followup(current_move: Resource, input_bits: int, input_buffer) -> Resource:
	if current_move.string_followup_command == "":
		return null

	var IM = InputManager
	# Support multiple followup commands separated by "|"
	var cmds = current_move.string_followup_command.split("|")

	for cmd in cmds:
		cmd = cmd.strip_edges()
		# Accept just_pressed OR currently held (for d+3,3 where 3 is held from first input)
		var button_pressed = false
		# Accept just_pressed OR currently held — allows natural strings where button stays held
		match cmd:
			"1":
				button_pressed = input_buffer.just_pressed(IM.INPUT_BUTTON1) or IM.has_flag(input_bits, IM.INPUT_BUTTON1)
			"2":
				button_pressed = input_buffer.just_pressed(IM.INPUT_BUTTON2) or IM.has_flag(input_bits, IM.INPUT_BUTTON2)
			"3":
				button_pressed = input_buffer.just_pressed(IM.INPUT_BUTTON3) or IM.has_flag(input_bits, IM.INPUT_BUTTON3)
			"4":
				button_pressed = input_buffer.just_pressed(IM.INPUT_BUTTON4) or IM.has_flag(input_bits, IM.INPUT_BUTTON4)

		if button_pressed:
			var full_cmd = current_move.input_command + "," + cmd
			if moves.has(full_cmd):
				return moves[full_cmd]

	return null
