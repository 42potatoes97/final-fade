extends Control

# Character Select — each player controls their own options with their assigned device
# Navigation: UP/DOWN to move between options, LEFT/RIGHT to cycle values
# Both players ready → auto-progress to stage select

const SKIN_TONES = [
	{"name": "Light", "color": Color(0.95, 0.82, 0.68)},
	{"name": "Fair", "color": Color(0.87, 0.72, 0.58)},
	{"name": "Medium", "color": Color(0.76, 0.58, 0.42)},
	{"name": "Olive", "color": Color(0.67, 0.52, 0.38)},
	{"name": "Brown", "color": Color(0.55, 0.38, 0.26)},
	{"name": "Dark", "color": Color(0.40, 0.26, 0.18)},
	{"name": "Deep", "color": Color(0.30, 0.20, 0.14)},
]

const TORSO_COLORS = [
	{"name": "Blue", "color": Color(0.2, 0.2, 0.6)},
	{"name": "Red", "color": Color(0.6, 0.15, 0.15)},
	{"name": "Green", "color": Color(0.15, 0.5, 0.2)},
	{"name": "Yellow", "color": Color(0.6, 0.55, 0.1)},
	{"name": "Pink", "color": Color(0.7, 0.2, 0.5)},
	{"name": "White", "color": Color(0.85, 0.85, 0.85)},
	{"name": "Black", "color": Color(0.12, 0.12, 0.12)},
	{"name": "Purple", "color": Color(0.4, 0.15, 0.6)},
]

const FIGHTER_CLASSES = [
	{"name": "DEFENSIVE", "desc": "Punch strings, mid checks"},
	{"name": "OFFENSIVE", "desc": "Kick strings, low pressure"},
]

# Per-player state
var player_data = [
	{"skin": 1, "torso": 0, "class_idx": 0, "cursor": 0, "ready": false},  # P1
	{"skin": 1, "torso": 1, "class_idx": 0, "cursor": 0, "ready": false},  # P2
]

# 3D preview
var preview_viewports: Array = [null, null]
var preview_models: Array = [null, null]
var model_scene = preload("res://scenes/characters/fighter_model.tscn")

# Option names for cursor navigation
const OPTIONS = ["Skin Tone", "Torso Color", "Fighter Class", "READY"]
const OPTION_COUNT = 4

# UI references per player
var player_ui = [{}, {}]  # [{option_labels, value_labels, cursor_indicator, ready_label}]

# Input cooldown per player to prevent rapid cycling
var input_cooldown = [0, 0]
const INPUT_COOLDOWN_FRAMES = 8

var proceeding: bool = false

# Online sync
var _online_local_ready_char: bool = false
var _online_opp_ready_char: bool = false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()
	# Defer focus setup until UI is built
	call_deferred("_setup_gamepad_focus")
	# Auto-ready AI player (no human to control character select)
	if GameManager.p1_device_type == InputManager.DeviceType.AI:
		player_data[0].ready = true
		_update_player_display(0)
	if GameManager.p2_device_type == InputManager.DeviceType.AI:
		player_data[1].ready = true
		_update_player_display(1)
	# Online mode: connect sync, listen for opponent ready
	if GameManager.online_mode:
		_online_local_ready_char = false
		_online_opp_ready_char = false
		NetworkManager.menu_sync_received.connect(_on_char_menu_sync)


func _build_ui() -> void:
	var bg = ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 15)
	add_child(main_vbox)

	# Title
	var title = Label.new()
	title.text = "CHARACTER SELECT"
	title.add_theme_font_size_override("font_size", 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(title)

	var hint = Label.new()
	hint.text = "↑↓ Navigate  •  ←→ Change  •  Confirm on READY  •  ESC Back"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(hint)

	# Top row: options side by side
	var options_hbox = HBoxContainer.new()
	options_hbox.add_theme_constant_override("separation", 120)
	options_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	main_vbox.add_child(options_hbox)

	_build_player_panel(options_hbox, 0, "PLAYER 1", Color(0.3, 0.5, 1.0))
	_build_player_panel(options_hbox, 1, "PLAYER 2", Color(1.0, 0.3, 0.3))

	# Bottom row: [P1 Model] [VS] [P2 Model] — spread apart
	var model_hbox = HBoxContainer.new()
	model_hbox.custom_minimum_size = Vector2(0, 400)
	model_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	model_hbox.add_theme_constant_override("separation", 20)
	model_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	main_vbox.add_child(model_hbox)

	_build_preview_viewport(model_hbox, 0)

	var vs = Label.new()
	vs.text = "VS"
	vs.add_theme_font_size_override("font_size", 48)
	vs.add_theme_color_override("font_color", Color(0.6, 0.3, 0.3))
	vs.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	model_hbox.add_child(vs)

	_build_preview_viewport(model_hbox, 1)

	# Initial model update
	_update_model_colors(0)
	_update_model_colors(1)


func _build_player_panel(parent: Control, pid: int, title_text: String, color: Color) -> void:
	var panel = VBoxContainer.new()
	panel.custom_minimum_size = Vector2(350, 0)
	panel.add_theme_constant_override("separation", 8)
	parent.add_child(panel)

	var title = Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", color)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)

	var ui = {"option_rows": [], "value_labels": [], "preview_rects": [], "ready_label": null}

	for i in range(OPTION_COUNT):
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		panel.add_child(row)

		# Cursor indicator
		var cursor = Label.new()
		cursor.text = "▸ " if i == 0 else "  "
		cursor.add_theme_font_size_override("font_size", 20)
		cursor.add_theme_color_override("font_color", color)
		cursor.custom_minimum_size = Vector2(25, 0)
		row.add_child(cursor)

		if i < 3:
			# Option label
			var opt_label = Label.new()
			opt_label.text = OPTIONS[i]
			opt_label.add_theme_font_size_override("font_size", 16)
			opt_label.custom_minimum_size = Vector2(110, 0)
			row.add_child(opt_label)

			# Left arrow
			var left_hint = Label.new()
			left_hint.text = "◀"
			left_hint.add_theme_font_size_override("font_size", 16)
			left_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(left_hint)

			# Value display
			var val_label = Label.new()
			val_label.add_theme_font_size_override("font_size", 18)
			val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			val_label.custom_minimum_size = Vector2(120, 0)
			row.add_child(val_label)
			ui.value_labels.append(val_label)

			# Right arrow
			var right_hint = Label.new()
			right_hint.text = "▶"
			right_hint.add_theme_font_size_override("font_size", 16)
			right_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(right_hint)

			# Color preview for skin/torso
			if i < 2:
				var preview = ColorRect.new()
				preview.custom_minimum_size = Vector2(30, 25)
				row.add_child(preview)
				ui.preview_rects.append(preview)
		else:
			# READY row
			var ready_label = Label.new()
			ready_label.text = "[ READY ]"
			ready_label.add_theme_font_size_override("font_size", 22)
			ready_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			ready_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ready_label.custom_minimum_size = Vector2(280, 0)
			row.add_child(ready_label)
			ui.ready_label = ready_label

		ui.option_rows.append({"container": row, "cursor": cursor})

	player_ui[pid] = ui
	_update_player_display(pid)


func _build_preview_viewport(parent: Control, pid: int) -> void:
	var vp_container = SubViewportContainer.new()
	vp_container.custom_minimum_size = Vector2(700, 500)
	vp_container.size = Vector2(700, 500)
	vp_container.stretch = true
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(vp_container)

	var vp = SubViewport.new()
	vp.size = Vector2i(700, 500)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	vp_container.add_child(vp)

	# Camera — wide FOV to show full body with room to spare
	# Offset X so the fighter's stance is centered (arms extend sideways)
	var x_offset = -0.3 if pid == 0 else 0.3
	var cam = Camera3D.new()
	cam.position = Vector3(x_offset, 0.7, 4.0)
	cam.look_at(Vector3(x_offset, 0.5, 0))
	cam.fov = 40
	cam.current = true
	vp.add_child(cam)

	# Light
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-25, 20, 0)
	light.light_energy = 1.3
	vp.add_child(light)

	var ambient = WorldEnvironment.new()
	var env = Environment.new()
	env.ambient_light_color = Color(0.45, 0.45, 0.55)
	env.ambient_light_energy = 0.6
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.08, 0.12)
	ambient.environment = env
	vp.add_child(ambient)

	# Fighter model — each viewport gets its own fully independent instance
	var model_instance = model_scene.instantiate()
	model_instance.position = Vector3(0, 0, 0)
	model_instance.rotation_degrees.y = 330 if pid == 0 else 30

	# Duplicate ALL materials so instances don't share them
	_duplicate_all_materials(model_instance)

	vp.add_child(model_instance)

	preview_viewports[pid] = vp
	preview_models[pid] = model_instance

	# Force fight stance pose immediately (high blend speed for instant snap)
	if model_instance.has_method("set_pose_fight_stance"):
		model_instance.set_pose_fight_stance()
		model_instance.blend_speed = 100.0  # Instant snap — set AFTER, since set_pose resets to 15
		model_instance.idle_bob_active = true


func _duplicate_all_materials(node: Node) -> void:
	if node is MeshInstance3D and node.material_override is StandardMaterial3D:
		node.material_override = node.material_override.duplicate()
	for child in node.get_children():
		_duplicate_all_materials(child)


func _update_model_colors(pid: int) -> void:
	var model = preview_models[pid]
	if model == null:
		return

	var skin_color = SKIN_TONES[player_data[pid].skin].color
	var torso_color = TORSO_COLORS[player_data[pid].torso].color

	# Materials are already duplicated per instance — just set colors directly
	_set_colors_recursive(model, skin_color, torso_color)


func _set_colors_recursive(node: Node, skin_color: Color, torso_color: Color) -> void:
	if node is MeshInstance3D and node.material_override is StandardMaterial3D:
		var pname = node.get_parent().name if node.get_parent() else ""
		if pname.contains("Head") or pname.contains("Arm") or pname.contains("Hand") or pname.contains("Shoulder"):
			node.material_override.albedo_color = skin_color
		elif pname.contains("Torso") or pname.contains("Abdomen"):
			node.material_override.albedo_color = torso_color
	for child in node.get_children():
		_set_colors_recursive(child, skin_color, torso_color)


func _update_player_display(pid: int) -> void:
	var data = player_data[pid]
	var ui = player_ui[pid]

	# Update cursor indicators
	for i in range(OPTION_COUNT):
		var row = ui.option_rows[i]
		if i == data.cursor:
			row.cursor.text = "▸ "
		else:
			row.cursor.text = "  "

	# Update values
	if ui.value_labels.size() >= 3:
		ui.value_labels[0].text = SKIN_TONES[data.skin].name
		ui.value_labels[1].text = TORSO_COLORS[data.torso].name
		ui.value_labels[2].text = FIGHTER_CLASSES[data.class_idx].name
		ui.value_labels[2].add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))

	# Update previews
	if ui.preview_rects.size() >= 2:
		ui.preview_rects[0].color = SKIN_TONES[data.skin].color
		ui.preview_rects[1].color = TORSO_COLORS[data.torso].color

	# Update ready label
	if ui.ready_label:
		if data.ready:
			ui.ready_label.text = "★ READY ★"
			ui.ready_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
		else:
			ui.ready_label.text = "[ READY ]"
			ui.ready_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))


func _physics_process(_delta: float) -> void:
	if proceeding:
		return

	for pid in range(2):
		# Online mode: skip the remote player's side entirely
		if GameManager.online_mode:
			var local_idx: int = GameManager.local_side - 1
			if pid != local_idx:
				continue

		if input_cooldown[pid] > 0:
			input_cooldown[pid] -= 1
			continue

		var input = _read_device_input(pid)
		if input.is_empty():
			continue

		var data = player_data[pid]

		if data.ready:
			# Only allow un-ready
			if input.confirm or input.up or input.down:
				data.ready = false
				_update_player_display(pid)
				_update_player_display(1 - pid)  # Refresh other player — color now unlocked
				input_cooldown[pid] = INPUT_COOLDOWN_FRAMES
			continue

		var changed = false

		if input.up:
			data.cursor = wrapi(data.cursor - 1, 0, OPTION_COUNT)
			changed = true
		elif input.down:
			data.cursor = wrapi(data.cursor + 1, 0, OPTION_COUNT)
			changed = true
		elif input.left:
			_cycle_value(pid, -1)
			changed = true
		elif input.right:
			_cycle_value(pid, 1)
			changed = true
		elif input.confirm:
			if data.cursor == 3:  # READY row
				# Check if torso color conflicts with other ready player
				var other = player_data[1 - pid]
				if other.ready and data.torso == other.torso:
					# Same torso color — bump to next available
					var new_idx = wrapi(data.torso + 1, 0, TORSO_COLORS.size())
					while new_idx == other.torso:
						new_idx = wrapi(new_idx + 1, 0, TORSO_COLORS.size())
					data.torso = new_idx
					_update_model_colors(pid)
				data.ready = true
				changed = true

		if changed:
			input_cooldown[pid] = INPUT_COOLDOWN_FRAMES
			_update_player_display(pid)
			_check_both_ready()


func _cycle_value(pid: int, direction: int) -> void:
	var data = player_data[pid]
	var other_pid = 1 - pid
	var other_data = player_data[other_pid]

	match data.cursor:
		0:  # Skin — no restrictions
			data.skin = wrapi(data.skin + direction, 0, SKIN_TONES.size())
		1:  # Torso — skip colors locked by the other player if they're ready
			var new_idx = wrapi(data.torso + direction, 0, TORSO_COLORS.size())
			# If other player is ready and has this color, skip it
			var attempts = 0
			while other_data.ready and new_idx == other_data.torso and attempts < TORSO_COLORS.size():
				new_idx = wrapi(new_idx + direction, 0, TORSO_COLORS.size())
				attempts += 1
			data.torso = new_idx
		2:  # Class
			data.class_idx = wrapi(data.class_idx + direction, 0, FIGHTER_CLASSES.size())

	# Update 3D preview
	_update_model_colors(pid)


func _read_device_input(pid: int) -> Dictionary:
	# Read input from the assigned device for this player
	var dev_type = GameManager.p1_device_type if pid == 0 else GameManager.p2_device_type
	var dev_id = GameManager.p1_device_id if pid == 0 else GameManager.p2_device_id

	var result = {"up": false, "down": false, "left": false, "right": false, "confirm": false}

	if dev_type == InputManager.DeviceType.KEYBOARD:
		if GameManager.online_mode:
			# Online: accept both WASD and arrows for the local player
			result.up = Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)
			result.down = Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)
			result.left = Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)
			result.right = Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)
			result.confirm = Input.is_key_pressed(KEY_U) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER) or Input.is_key_pressed(KEY_KP_5)
		else:
			# Keyboard input — check appropriate keys
			var kb_player = 1 if dev_id == -1 else 2
			if kb_player == 1:
				# WASD
				result.up = Input.is_key_pressed(KEY_W)
				result.down = Input.is_key_pressed(KEY_S)
				result.left = Input.is_key_pressed(KEY_A)
				result.right = Input.is_key_pressed(KEY_D)
				result.confirm = Input.is_key_pressed(KEY_U) or Input.is_key_pressed(KEY_SPACE)
			else:
				# Arrow keys / numpad
				result.up = Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_KP_8)
				result.down = Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_KP_2)
				result.left = Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_KP_4)
				result.right = Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_KP_6)
				result.confirm = Input.is_key_pressed(KEY_KP_5) or Input.is_key_pressed(KEY_ENTER)

	elif dev_type == InputManager.DeviceType.GAMEPAD:
		var stick_x = Input.get_joy_axis(dev_id, JOY_AXIS_LEFT_X)
		var stick_y = Input.get_joy_axis(dev_id, JOY_AXIS_LEFT_Y)
		result.up = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_DPAD_UP) or stick_y < -0.5
		result.down = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_DPAD_DOWN) or stick_y > 0.5
		result.left = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_DPAD_LEFT) or stick_x < -0.5
		result.right = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_DPAD_RIGHT) or stick_x > 0.5
		result.confirm = Input.is_joy_button_pressed(dev_id, JOY_BUTTON_X)  # Square/X = confirm

	return result


func _check_both_ready() -> void:
	if GameManager.online_mode:
		# Online: local player readied — send sync, wait for opponent
		var local_idx: int = GameManager.local_side - 1
		if player_data[local_idx].ready and not _online_local_ready_char:
			_online_local_ready_char = true
			var data: Dictionary = player_data[local_idx]
			NetworkManager.send_menu_sync({
				"screen": "char_select",
				"ready": true,
				"side": GameManager.local_side,
				"skin": data.skin,
				"torso": data.torso,
				"class_idx": data.class_idx,
			})
			if _online_opp_ready_char:
				proceeding = true
				_save_and_proceed()
		return

	if player_data[0].ready and player_data[1].ready:
		proceeding = true
		_save_and_proceed()


func _on_char_menu_sync(data: Dictionary) -> void:
	if data.get("screen", "") != "char_select":
		return
	_online_opp_ready_char = data.get("ready", false)
	# Always apply opponent's choices to OUR remote side (opposite of local)
	var remote_idx: int = 1 - (GameManager.local_side - 1)
	player_data[remote_idx].skin = int(data.get("skin", 0))
	player_data[remote_idx].torso = int(data.get("torso", 0))
	player_data[remote_idx].class_idx = int(data.get("class_idx", 0))
	player_data[remote_idx].ready = true
	_update_player_display(remote_idx)
	if _online_opp_ready_char and _online_local_ready_char and not proceeding:
		proceeding = true
		_save_and_proceed()


func _save_and_proceed() -> void:
	GameManager.p1_skin_color = SKIN_TONES[player_data[0].skin].color
	GameManager.p1_torso_color = TORSO_COLORS[player_data[0].torso].color
	GameManager.p1_fighter_class = GameManager.FighterClass.DEFENSIVE if player_data[0].class_idx == 0 else GameManager.FighterClass.OFFENSIVE
	GameManager.p2_skin_color = SKIN_TONES[player_data[1].skin].color
	GameManager.p2_torso_color = TORSO_COLORS[player_data[1].torso].color
	GameManager.p2_fighter_class = GameManager.FighterClass.DEFENSIVE if player_data[1].class_idx == 0 else GameManager.FighterClass.OFFENSIVE

	# Brief delay then proceed
	get_tree().create_timer(0.3).timeout.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/stage_select.tscn"))


func _setup_gamepad_focus() -> void:
	UIFocusHelper.setup_focus(self)


func _input(event: InputEvent) -> void:
	if InputManager.is_back_event(event):
		get_tree().change_scene_to_file("res://scenes/ui/side_select.tscn")
