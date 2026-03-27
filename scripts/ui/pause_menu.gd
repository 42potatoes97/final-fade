extends CanvasLayer

# Pause menu — ESC to toggle

var is_paused: bool = false
var panel: PanelContainer
var resume_btn: Button
var menu_btn: Button
var quit_btn: Button


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _input(event: InputEvent) -> void:
	if InputManager.is_back_event(event):
		if is_paused:
			_resume()
		else:
			_pause()


func _pause() -> void:
	is_paused = true
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resume() -> void:
	is_paused = false
	visible = false
	get_tree().paused = false


func _build_ui() -> void:
	# Dark overlay
	var overlay = ColorRect.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0, 0, 0, 0.6)
	add_child(overlay)

	# Center panel
	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(350, 300)
	center.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.set("theme_override_constants/separation", 20)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)

	resume_btn = Button.new()
	resume_btn.text = "Resume"
	resume_btn.custom_minimum_size = Vector2(0, 45)
	resume_btn.add_theme_font_size_override("font_size", 20)
	resume_btn.pressed.connect(_resume)
	vbox.add_child(resume_btn)

	menu_btn = Button.new()
	menu_btn.text = "Main Menu"
	menu_btn.custom_minimum_size = Vector2(0, 45)
	menu_btn.add_theme_font_size_override("font_size", 20)
	menu_btn.pressed.connect(_go_to_menu)
	vbox.add_child(menu_btn)

	quit_btn = Button.new()
	quit_btn.text = "Quit Game"
	quit_btn.custom_minimum_size = Vector2(0, 45)
	quit_btn.add_theme_font_size_override("font_size", 20)
	quit_btn.pressed.connect(func(): get_tree().quit())
	vbox.add_child(quit_btn)


func _go_to_menu() -> void:
	get_tree().paused = false
	is_paused = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
