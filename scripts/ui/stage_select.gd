extends Control

# Stage Select Screen — each non-CPU player picks a stage,
# then the game randomly selects one of their picks.
# If both pick the same stage, it's guaranteed.
# CPU players get a random pick automatically.

const STAGES = [
	{
		"name": "Training Room",
		"desc": "Infinite flat stage — no walls",
		"path": "res://scenes/stages/stage_infinite.tscn",
		"color": Color(0.28, 0.28, 0.32),
	},
	{
		"name": "The Pit",
		"desc": "Small octagon arena (10m across)",
		"path": "res://scenes/stages/stage_small.tscn",
		"color": Color(0.35, 0.2, 0.15),
	},
	{
		"name": "The Ring",
		"desc": "Medium octagon arena (24m across)",
		"path": "res://scenes/stages/stage_medium.tscn",
		"color": Color(0.25, 0.25, 0.3),
	},
	{
		"name": "The Arena",
		"desc": "Large octagon arena (36m across)",
		"path": "res://scenes/stages/stage_large.tscn",
		"color": Color(0.18, 0.22, 0.35),
	},
]

# Per-player selection state
var p1_selected: int = 0
var p2_selected: int = 0
var p1_confirmed: bool = false
var p2_confirmed: bool = false

# Device mappings from side_select
var p1_device: int = -1
var p2_device: int = -1

# UI references
var p1_label: Label
var p2_label: Label
var p1_stage_label: Label
var p2_stage_label: Label
var p1_preview: ColorRect
var p2_preview: ColorRect
var p1_status: Label
var p2_status: Label
var result_label: Label
var countdown_timer: float = -1.0
var chosen_stage: int = -1

# Online sync
var _online_local_stage_ready: bool = false
var _online_opp_stage_ready: bool = false
var _online_opp_stage_pick: int = -1


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	p1_device = InputManager.p1_device_id
	p2_device = InputManager.p2_device_id
	_build_ui()
	UIFocusHelper.setup_focus(self)

	# Auto-pick for CPU
	if GameManager.ai_mode:
		p2_selected = randi() % STAGES.size()
		p2_confirmed = true
		_update_display()

	# Online mode: sync stage picks via RPC
	if GameManager.online_mode:
		_online_local_stage_ready = false
		_online_opp_stage_ready = false
		_online_opp_stage_pick = -1
		NetworkManager.menu_sync_received.connect(_on_stage_menu_sync)


func _build_ui() -> void:
	# Background
	var bg = ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 15)
	add_child(main_vbox)

	# Top spacer
	var top_spacer = Control.new()
	top_spacer.custom_minimum_size = Vector2(0, 20)
	main_vbox.add_child(top_spacer)

	# Title
	var title = Label.new()
	title.text = "STAGE SELECT"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(title)

	# Instructions
	var instructions = Label.new()
	instructions.text = "↑↓ Navigate  •  Attack to Confirm  •  ESC Back"
	instructions.add_theme_font_size_override("font_size", 14)
	instructions.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	instructions.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(instructions)

	# Two-column layout for P1 and P2
	var columns = HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_theme_constant_override("separation", 80)
	main_vbox.add_child(columns)

	# P1 column
	var p1_col = _build_player_column("PLAYER 1", Color(0.3, 0.5, 1.0))
	columns.add_child(p1_col)
	p1_label = p1_col.get_meta("title_label")
	p1_stage_label = p1_col.get_meta("stage_label")
	p1_preview = p1_col.get_meta("preview")
	p1_status = p1_col.get_meta("status_label")

	# VS divider
	var vs_label = Label.new()
	vs_label.text = "VS"
	vs_label.add_theme_font_size_override("font_size", 36)
	vs_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.2))
	vs_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	columns.add_child(vs_label)

	# P2 column
	var p2_title_text = "CPU" if GameManager.ai_mode else "PLAYER 2"
	var p2_col = _build_player_column(p2_title_text, Color(1.0, 0.3, 0.2))
	columns.add_child(p2_col)
	p2_label = p2_col.get_meta("title_label")
	p2_stage_label = p2_col.get_meta("stage_label")
	p2_preview = p2_col.get_meta("preview")
	p2_status = p2_col.get_meta("status_label")

	# Result label (shows after both confirm)
	result_label = Label.new()
	result_label.text = ""
	result_label.add_theme_font_size_override("font_size", 28)
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	main_vbox.add_child(result_label)

	# Bottom spacer
	var bot_spacer = Control.new()
	bot_spacer.custom_minimum_size = Vector2(0, 30)
	main_vbox.add_child(bot_spacer)

	_update_display()


func _build_player_column(title_text: String, title_color: Color) -> VBoxContainer:
	var col = VBoxContainer.new()
	col.custom_minimum_size = Vector2(350, 0)
	col.add_theme_constant_override("separation", 10)
	col.alignment = BoxContainer.ALIGNMENT_CENTER

	# Player title
	var title_lbl = Label.new()
	title_lbl.text = title_text
	title_lbl.add_theme_font_size_override("font_size", 28)
	title_lbl.add_theme_color_override("font_color", title_color)
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title_lbl)
	col.set_meta("title_label", title_lbl)

	# Stage preview
	var preview = ColorRect.new()
	preview.custom_minimum_size = Vector2(320, 180)
	preview.color = STAGES[0].color
	col.add_child(preview)
	col.set_meta("preview", preview)

	# Stage name with arrows
	var nav_hbox = HBoxContainer.new()
	nav_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	nav_hbox.add_theme_constant_override("separation", 15)
	col.add_child(nav_hbox)

	var left_arrow = Label.new()
	left_arrow.text = "◄"
	left_arrow.add_theme_font_size_override("font_size", 24)
	left_arrow.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	nav_hbox.add_child(left_arrow)

	var stage_lbl = Label.new()
	stage_lbl.text = STAGES[0].name
	stage_lbl.add_theme_font_size_override("font_size", 22)
	stage_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stage_lbl.custom_minimum_size = Vector2(200, 0)
	nav_hbox.add_child(stage_lbl)
	col.set_meta("stage_label", stage_lbl)

	var right_arrow = Label.new()
	right_arrow.text = "►"
	right_arrow.add_theme_font_size_override("font_size", 24)
	right_arrow.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	nav_hbox.add_child(right_arrow)

	# Status
	var status_lbl = Label.new()
	status_lbl.text = "[ SELECT ]"
	status_lbl.add_theme_font_size_override("font_size", 18)
	status_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(status_lbl)
	col.set_meta("status_label", status_lbl)

	return col


func _update_display() -> void:
	# P1
	p1_preview.color = STAGES[p1_selected].color
	p1_stage_label.text = STAGES[p1_selected].name
	if p1_confirmed:
		p1_status.text = "[ LOCKED IN ]"
		p1_status.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	else:
		p1_status.text = "[ SELECT ]"
		p1_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))

	# P2
	p2_preview.color = STAGES[p2_selected].color
	p2_stage_label.text = STAGES[p2_selected].name
	if p2_confirmed:
		p2_status.text = "[ LOCKED IN ]"
		p2_status.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	else:
		p2_status.text = "[ SELECT ]"
		p2_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))


func _process(delta: float) -> void:
	if countdown_timer > 0:
		countdown_timer -= delta
		if countdown_timer <= 0:
			_start_fight()


func _input(event: InputEvent) -> void:
	if countdown_timer > 0:
		return  # Already resolving

	if InputManager.is_back_event(event):
		get_tree().change_scene_to_file("res://scenes/ui/character_select.tscn")
		return

	if not event.is_pressed():
		return

	# Online mode: all local input goes to the local player's side
	if GameManager.online_mode:
		var local_player: int = GameManager.local_side
		var is_confirmed: bool = (p1_confirmed if local_player == 1 else p2_confirmed)
		if not is_confirmed:
			_handle_player_input(event, local_player)
		return

	# Determine which player this event belongs to
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		var dev_id = event.device
		if dev_id == p1_device and InputManager.p1_device_type == InputManager.DeviceType.GAMEPAD:
			if not p1_confirmed:
				_handle_player_input(event, 1)
		elif dev_id == p2_device and InputManager.p2_device_type == InputManager.DeviceType.GAMEPAD and not GameManager.ai_mode:
			if not p2_confirmed:
				_handle_player_input(event, 2)
	elif event is InputEventKey:
		# Both players may be on keyboard — use key zones to distinguish
		var key = event.keycode
		var is_p1_key = key in [KEY_W, KEY_S, KEY_A, KEY_D, KEY_J, KEY_K, KEY_L, KEY_U]
		var is_p2_key = key in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_ENTER]

		if is_p1_key and InputManager.p1_device_type == InputManager.DeviceType.KEYBOARD and not p1_confirmed:
			_handle_player_input(event, 1)
		elif is_p2_key and InputManager.p2_device_type == InputManager.DeviceType.KEYBOARD and not GameManager.ai_mode and not p2_confirmed:
			_handle_player_input(event, 2)


func _handle_player_input(event: InputEvent, player: int) -> void:
	var nav_left = false
	var nav_right = false
	var confirm = false

	if event is InputEventKey and event.pressed:
		if GameManager.online_mode:
			# Online: accept both WASD and arrow keys for the local player
			nav_left = event.keycode == KEY_A or event.keycode == KEY_LEFT
			nav_right = event.keycode == KEY_D or event.keycode == KEY_RIGHT
			confirm = event.keycode == KEY_J or event.keycode == KEY_U or event.keycode == KEY_KP_1 or event.keycode == KEY_ENTER or event.keycode == KEY_SPACE
		elif player == 1:
			nav_left = event.keycode == KEY_A
			nav_right = event.keycode == KEY_D
			confirm = event.keycode == KEY_J  # Attack 1
		else:
			nav_left = event.keycode == KEY_LEFT
			nav_right = event.keycode == KEY_RIGHT
			confirm = event.keycode == KEY_KP_1 or event.keycode == KEY_ENTER
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_DPAD_LEFT:
			nav_left = true
		elif event.button_index == JOY_BUTTON_DPAD_RIGHT:
			nav_right = true
		confirm = event.button_index == JOY_BUTTON_X  # Square/X = confirm
	elif event is InputEventJoypadMotion:
		if event.axis == JOY_AXIS_LEFT_X:
			if event.axis_value < -0.5:
				nav_left = true
			elif event.axis_value > 0.5:
				nav_right = true

	if player == 1:
		if nav_left:
			p1_selected = (p1_selected - 1 + STAGES.size()) % STAGES.size()
			_update_display()
		elif nav_right:
			p1_selected = (p1_selected + 1) % STAGES.size()
			_update_display()
		elif confirm:
			p1_confirmed = true
			_update_display()
			_check_both_confirmed()
	elif player == 2:
		if nav_left:
			p2_selected = (p2_selected - 1 + STAGES.size()) % STAGES.size()
			_update_display()
		elif nav_right:
			p2_selected = (p2_selected + 1) % STAGES.size()
			_update_display()
		elif confirm:
			p2_confirmed = true
			_update_display()
			_check_both_confirmed()


func _check_both_confirmed() -> void:
	if GameManager.online_mode:
		# Online: send our pick, wait for opponent
		var local_side: int = GameManager.local_side
		var local_pick: int = p1_selected if local_side == 1 else p2_selected
		var is_confirmed: bool = p1_confirmed if local_side == 1 else p2_confirmed
		if is_confirmed and not _online_local_stage_ready:
			_online_local_stage_ready = true
			NetworkManager.send_menu_sync({
				"screen": "stage_select",
				"ready": true,
				"stage_pick": local_pick,
			})
			if _online_opp_stage_ready:
				_resolve_online_stage(local_pick)
			else:
				result_label.text = "Waiting for opponent..."
				result_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
		return

	if not p1_confirmed or not p2_confirmed:
		return

	# Both locked in — resolve stage
	if p1_selected == p2_selected:
		chosen_stage = p1_selected
		result_label.text = "Stage: " + STAGES[chosen_stage].name + "!"
	else:
		# Random pick between the two selections
		var picks = [p1_selected, p2_selected]
		chosen_stage = picks[randi() % 2]
		result_label.text = STAGES[chosen_stage].name + " selected!"

	countdown_timer = 1.5  # Brief pause before fight


func _on_stage_menu_sync(data: Dictionary) -> void:
	if data.get("screen", "") != "stage_select":
		return
	_online_opp_stage_ready = data.get("ready", false)
	_online_opp_stage_pick = int(data.get("stage_pick", 0))
	if _online_opp_stage_ready and _online_local_stage_ready:
		var local_pick: int = p1_selected if GameManager.local_side == 1 else p2_selected
		_resolve_online_stage(local_pick)
	elif _online_opp_stage_ready and not _online_local_stage_ready:
		result_label.text = "Opponent ready — pick your stage!"
		result_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))


func _resolve_online_stage(local_pick: int) -> void:
	# Deterministic resolution: host's pick wins ties, else use lower-PID's pick
	if local_pick == _online_opp_stage_pick:
		chosen_stage = local_pick
	else:
		# Host (local_player_id was 1 before side remap) gets priority
		if NetworkManager.is_host:
			chosen_stage = local_pick
		else:
			chosen_stage = _online_opp_stage_pick
	result_label.text = STAGES[chosen_stage].name + " selected!"
	result_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	countdown_timer = 1.5


func _start_fight() -> void:
	GameManager.selected_stage = STAGES[chosen_stage].path
	GameManager.reset_match()
	get_tree().change_scene_to_file("res://scenes/main/fight_scene.tscn")
