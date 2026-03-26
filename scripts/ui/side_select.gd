extends Control

# Side Select — devices pick sides by moving left/right
# Each device has an icon in the center, press LEFT to join P1, RIGHT to join P2
# Press button 1 (U key / Square) to confirm side
# Both confirmed → auto-progress to character select

var devices: Array = []  # [{type, id, name, side, confirmed}]
# side: 0 = center (unassigned), 1 = P1 (left), 2 = P2 (right)

var device_icons: Array = []  # UI references per device
var p1_slot_label: Label
var p2_slot_label: Label
var info_label: Label

var input_cooldown: Dictionary = {}  # device_key -> frames remaining
const COOLDOWN_FRAMES: int = 10
var proceeding: bool = false

# AI difficulty selection
var ai_difficulty_phase: bool = false  # True when picking CPU difficulty
var ai_difficulty_idx: int = 1         # Current selected difficulty
var ai_human_dev_idx: int = -1         # Which device the human is using
var ai_difficulty_label: Label = null
const AI_DIFFICULTIES = [
	{"name": "EASY", "difficulty": "EASY"},
	{"name": "NORMAL", "difficulty": "NORMAL"},
	{"name": "HARD", "difficulty": "HARD"},
	{"name": "BRUTAL", "difficulty": "BRUTAL"},
]


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_detect_devices()
	_build_ui()


func _detect_devices() -> void:
	devices.clear()
	devices.append({"type": InputManager.DeviceType.KEYBOARD, "id": -1, "name": "Keyboard (WASD)", "side": 0, "confirmed": false})
	devices.append({"type": InputManager.DeviceType.KEYBOARD, "id": -2, "name": "Keyboard (Arrows)", "side": 0, "confirmed": false})
	for pad_id in Input.get_connected_joypads():
		var pad_name = Input.get_joy_name(pad_id)
		if pad_name == "":
			pad_name = "Gamepad " + str(pad_id)
		devices.append({"type": InputManager.DeviceType.GAMEPAD, "id": pad_id, "name": pad_name, "side": 0, "confirmed": false})
	# In AI mode, add a CPU device
	if GameManager.ai_mode:
		devices.append({"type": InputManager.DeviceType.AI, "id": -1, "name": "CPU", "side": 0, "confirmed": false})


func _build_ui() -> void:
	var bg = ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 25)
	main_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(main_vbox)

	# Title
	var title = Label.new()
	title.text = "SELECT YOUR SIDE"
	title.add_theme_font_size_override("font_size", 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(title)

	var hint = Label.new()
	hint.text = "← Move to P1  •  → Move to P2  •  Confirm with attack button"
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(hint)

	# Three columns: P1 | Center | P2
	var columns = HBoxContainer.new()
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_theme_constant_override("separation", 0)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(columns)

	# P1 column
	var p1_col = VBoxContainer.new()
	p1_col.custom_minimum_size = Vector2(250, 0)
	p1_col.alignment = BoxContainer.ALIGNMENT_CENTER
	p1_col.add_theme_constant_override("separation", 10)
	columns.add_child(p1_col)

	var p1_title = Label.new()
	p1_title.text = "PLAYER 1"
	p1_title.add_theme_font_size_override("font_size", 28)
	p1_title.add_theme_color_override("font_color", Color(0.3, 0.5, 1.0))
	p1_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p1_col.add_child(p1_title)

	p1_slot_label = Label.new()
	p1_slot_label.text = "—"
	p1_slot_label.add_theme_font_size_override("font_size", 18)
	p1_slot_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	p1_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p1_col.add_child(p1_slot_label)

	# Center column — device icons live here initially
	var center_col = VBoxContainer.new()
	center_col.custom_minimum_size = Vector2(300, 0)
	center_col.alignment = BoxContainer.ALIGNMENT_CENTER
	center_col.add_theme_constant_override("separation", 12)
	columns.add_child(center_col)

	# P2 column
	var p2_col = VBoxContainer.new()
	p2_col.custom_minimum_size = Vector2(250, 0)
	p2_col.alignment = BoxContainer.ALIGNMENT_CENTER
	p2_col.add_theme_constant_override("separation", 10)
	columns.add_child(p2_col)

	var p2_title = Label.new()
	p2_title.text = "PLAYER 2"
	p2_title.add_theme_font_size_override("font_size", 28)
	p2_title.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	p2_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p2_col.add_child(p2_title)

	p2_slot_label = Label.new()
	p2_slot_label.text = "—"
	p2_slot_label.add_theme_font_size_override("font_size", 18)
	p2_slot_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	p2_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p2_col.add_child(p2_slot_label)

	# Build device icons in center
	device_icons.clear()
	for i in range(devices.size()):
		var icon = _build_device_icon(i)
		center_col.add_child(icon.container)
		device_icons.append(icon)

	# Info
	info_label = Label.new()
	info_label.text = ""
	info_label.add_theme_font_size_override("font_size", 20)
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(info_label)

	# Back
	var back = Label.new()
	back.text = "ESC — Back"
	back.add_theme_font_size_override("font_size", 14)
	back.add_theme_color_override("font_color", Color(0.35, 0.35, 0.45))
	back.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(back)


func _build_device_icon(idx: int) -> Dictionary:
	var dev = devices[idx]

	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 10)

	# Side indicator (arrow or checkmark)
	var side_label = Label.new()
	side_label.text = "●"
	side_label.add_theme_font_size_override("font_size", 20)
	side_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	side_label.custom_minimum_size = Vector2(30, 0)
	side_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(side_label)

	# Device name
	var name_label = Label.new()
	name_label.text = dev.name
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.custom_minimum_size = Vector2(200, 0)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(name_label)

	# Status
	var status_label = Label.new()
	status_label.text = ""
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.custom_minimum_size = Vector2(30, 0)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(status_label)

	return {"container": hbox, "side_label": side_label, "name_label": name_label, "status_label": status_label}


func _physics_process(_delta: float) -> void:
	if proceeding:
		return

	# Decrement cooldowns
	for key in input_cooldown.keys():
		if input_cooldown[key] > 0:
			input_cooldown[key] -= 1

	# AI difficulty selection phase — human device picks difficulty
	if ai_difficulty_phase and ai_human_dev_idx >= 0:
		var hdev = devices[ai_human_dev_idx]
		var hkey = str(hdev.type) + "_" + str(hdev.id)
		if input_cooldown.get(hkey, 0) <= 0:
			var hinput = _read_device_nav(hdev.type, hdev.id)
			if hinput.left:
				ai_difficulty_idx = wrapi(ai_difficulty_idx - 1, 0, AI_DIFFICULTIES.size())
				_update_difficulty_display()
				input_cooldown[hkey] = COOLDOWN_FRAMES
			elif hinput.right:
				ai_difficulty_idx = wrapi(ai_difficulty_idx + 1, 0, AI_DIFFICULTIES.size())
				_update_difficulty_display()
				input_cooldown[hkey] = COOLDOWN_FRAMES
			elif hinput.confirm:
				# Confirm CPU with selected difficulty
				var cpu_idx = -1
				for i in range(devices.size()):
					if devices[i].type == InputManager.DeviceType.AI:
						cpu_idx = i
						break
				if cpu_idx >= 0:
					devices[cpu_idx].confirmed = true
					GameManager.ai_difficulty = AI_DIFFICULTIES[ai_difficulty_idx]
					_update_all_display()
					_check_ready()
				input_cooldown[hkey] = COOLDOWN_FRAMES
		return

	# Read input from each device
	for i in range(devices.size()):
		var dev = devices[i]
		var dev_key = str(dev.type) + "_" + str(dev.id)

		if input_cooldown.get(dev_key, 0) > 0:
			continue

		var input = _read_device_nav(dev.type, dev.id)
		if input.is_empty():
			continue

		var changed = false

		if dev.confirmed:
			# Already confirmed — only allow un-confirm with confirm button
			if input.confirm:
				dev.confirmed = false
				changed = true
		else:
			if input.left and dev.side != 1:
				# Move to P1 side — only if not occupied
				if not _side_occupied(1):
					dev.side = 1
					changed = true
			elif input.right and dev.side != 2:
				# Move to P2 side — only if not occupied
				if not _side_occupied(2):
					dev.side = 2
					changed = true
			elif (input.left and dev.side == 1) or (input.right and dev.side == 2):
				# Already on this side, pressing same direction = go back to center
				pass
			elif input.confirm and dev.side != 0:
				# Confirm side
				dev.confirmed = true
				changed = true
			# Allow moving back to center by pressing opposite of current side
			if not changed and dev.side == 1 and input.right and _side_occupied(2):
				# Can't go to P2 (occupied), go to center instead
				dev.side = 0
				changed = true
			elif not changed and dev.side == 2 and input.left and _side_occupied(1):
				# Can't go to P1 (occupied), go to center instead
				dev.side = 0
				changed = true

		if changed:
			input_cooldown[dev_key] = COOLDOWN_FRAMES
			_update_all_display()
			_check_ready()


func _side_occupied(side: int) -> bool:
	for dev in devices:
		if dev.side == side:
			return true
	return false


func _update_all_display() -> void:
	var p1_name = ""
	var p2_name = ""

	for i in range(devices.size()):
		var dev = devices[i]
		var icon = device_icons[i]

		match dev.side:
			0:
				icon.side_label.text = "●"
				icon.side_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
				icon.name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
				icon.status_label.text = ""
			1:
				icon.side_label.text = "◀"
				icon.side_label.add_theme_color_override("font_color", Color(0.3, 0.5, 1.0))
				icon.name_label.add_theme_color_override("font_color", Color(0.3, 0.5, 1.0))
				p1_name = dev.name
				if dev.confirmed:
					icon.status_label.text = "✓"
					icon.status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
				else:
					icon.status_label.text = ""
			2:
				icon.side_label.text = "▶"
				icon.side_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
				icon.name_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
				p2_name = dev.name
				if dev.confirmed:
					icon.status_label.text = "✓"
					icon.status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
				else:
					icon.status_label.text = ""

	p1_slot_label.text = p1_name if p1_name != "" else "—"
	p1_slot_label.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0) if p1_name != "" else Color(0.4, 0.4, 0.5))
	p2_slot_label.text = p2_name if p2_name != "" else "—"
	p2_slot_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5) if p2_name != "" else Color(0.4, 0.4, 0.5))


func _check_ready() -> void:
	var p1_confirmed = false
	var p2_confirmed = false
	var p1_idx = -1
	var p2_idx = -1

	for i in range(devices.size()):
		if devices[i].side == 1 and devices[i].confirmed:
			p1_confirmed = true
			p1_idx = i
		if devices[i].side == 2 and devices[i].confirmed:
			p2_confirmed = true
			p2_idx = i

	# AI mode: when a human confirms a side, assign CPU to opposite and enter difficulty pick
	if GameManager.ai_mode and not ai_difficulty_phase:
		var cpu_idx = -1
		for i in range(devices.size()):
			if devices[i].type == InputManager.DeviceType.AI:
				cpu_idx = i
				break
		if cpu_idx >= 0:
			var human_confirmed_side = 0
			if p1_confirmed and not p2_confirmed:
				human_confirmed_side = 1
			elif p2_confirmed and not p1_confirmed:
				human_confirmed_side = 2

			if human_confirmed_side > 0:
				# Find which human device confirmed
				for i in range(devices.size()):
					if devices[i].side == human_confirmed_side and devices[i].confirmed:
						ai_human_dev_idx = i
						break
				# Assign CPU to opposite side (not confirmed yet)
				var cpu_side = 2 if human_confirmed_side == 1 else 1
				devices[cpu_idx].side = cpu_side
				ai_difficulty_phase = true
				ai_difficulty_idx = 1  # Default to NORMAL
				_update_all_display()
				_show_difficulty_picker()
				return

	if p1_confirmed and p2_confirmed:
		info_label.text = "Both confirmed!"
		info_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
		proceeding = true
		_save_and_proceed(p1_idx, p2_idx)
	elif p1_confirmed or p2_confirmed:
		var waiting = "P1" if not p1_confirmed else "P2"
		info_label.text = "Waiting for " + waiting + " to confirm..."
		info_label.add_theme_color_override("font_color", Color(0.8, 0.7, 0.3))
	else:
		info_label.text = ""


func _save_and_proceed(p1_idx: int, p2_idx: int) -> void:
	var p1_dev = devices[p1_idx]
	var p2_dev = devices[p2_idx]

	GameManager.p1_device_type = p1_dev.type
	GameManager.p1_device_id = p1_dev.id
	InputManager.assign_device(1, p1_dev.type, p1_dev.id)

	GameManager.p2_device_type = p2_dev.type
	GameManager.p2_device_id = p2_dev.id
	InputManager.assign_device(2, p2_dev.type, p2_dev.id)

	get_tree().create_timer(0.5).timeout.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/character_select.tscn"))


func _read_device_nav(dev_type: int, dev_id: int) -> Dictionary:
	var result = {"left": false, "right": false, "confirm": false}

	if dev_type == InputManager.DeviceType.KEYBOARD:
		if dev_id == -1:  # WASD
			result.left = Input.is_key_pressed(KEY_A)
			result.right = Input.is_key_pressed(KEY_D)
			result.confirm = Input.is_key_pressed(KEY_U) or Input.is_key_pressed(KEY_SPACE)
		else:  # Arrows
			result.left = Input.is_key_pressed(KEY_LEFT)
			result.right = Input.is_key_pressed(KEY_RIGHT)
			result.confirm = Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_4)
	elif dev_type == InputManager.DeviceType.GAMEPAD:
		var stick_x = Input.get_joy_axis(dev_id, JOY_AXIS_LEFT_X)
		result.left = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_DPAD_LEFT) or stick_x < -0.5
		result.right = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_DPAD_RIGHT) or stick_x > 0.5
		# Confirm = Square (JOY_BUTTON_X) which is button 1 in our mapping
		result.confirm = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_X)

	return result


func _show_difficulty_picker() -> void:
	info_label.text = "◀  " + AI_DIFFICULTIES[ai_difficulty_idx].name + "  ▶"
	info_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	if ai_difficulty_label == null:
		ai_difficulty_label = Label.new()
		ai_difficulty_label.add_theme_font_size_override("font_size", 16)
		ai_difficulty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		ai_difficulty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Add below info_label — find parent and add after
		info_label.get_parent().add_child(ai_difficulty_label)
		info_label.get_parent().move_child(ai_difficulty_label, info_label.get_index() + 1)
	ai_difficulty_label.text = "← → Change Difficulty  •  Confirm to Ready CPU"


func _update_difficulty_display() -> void:
	info_label.text = "◀  " + AI_DIFFICULTIES[ai_difficulty_idx].name + "  ▶"


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if ai_difficulty_phase:
			# Back out of difficulty selection
			ai_difficulty_phase = false
			var cpu_idx = -1
			for i in range(devices.size()):
				if devices[i].type == InputManager.DeviceType.AI:
					cpu_idx = i
					break
			if cpu_idx >= 0:
				devices[cpu_idx].side = 0
				devices[cpu_idx].confirmed = false
			if ai_human_dev_idx >= 0:
				devices[ai_human_dev_idx].confirmed = false
			if ai_difficulty_label:
				ai_difficulty_label.queue_free()
				ai_difficulty_label = null
			info_label.text = ""
			_update_all_display()
			return
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
