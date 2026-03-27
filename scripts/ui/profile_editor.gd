extends Control

# Standalone profile editor for Final Fade
# View and edit username, profile ID, stats, fighter preference
# Can be navigated to from main menu

var username_field: LineEdit
var profile_id_label: Label
var stats_wins_label: Label
var stats_losses_label: Label
var stats_total_label: Label
var preference_btn: OptionButton
var export_btn: Button
var import_btn: Button
var status_label: Label


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()
	_populate_fields()
	UIFocusHelper.setup_focus(self)


# =============================================================================
#  UI CONSTRUCTION
# =============================================================================

func _build_ui() -> void:
	# Background
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var main_vbox: VBoxContainer = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 20)
	main_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(main_vbox)

	# Title
	var title: Label = Label.new()
	title.text = "PLAYER PROFILE"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(title)

	# --- Username ---
	var user_hbox: HBoxContainer = HBoxContainer.new()
	user_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	user_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(user_hbox)

	var user_prompt: Label = Label.new()
	user_prompt.text = "Username:"
	user_prompt.add_theme_font_size_override("font_size", 22)
	user_hbox.add_child(user_prompt)

	username_field = LineEdit.new()
	username_field.custom_minimum_size = Vector2(250, 44)
	username_field.add_theme_font_size_override("font_size", 22)
	username_field.max_length = 24
	user_hbox.add_child(username_field)

	var save_btn: Button = Button.new()
	save_btn.text = "SAVE"
	save_btn.custom_minimum_size = Vector2(90, 44)
	save_btn.add_theme_font_size_override("font_size", 20)
	save_btn.pressed.connect(_on_save_pressed)
	user_hbox.add_child(save_btn)

	# --- Profile ID ---
	var id_hbox: HBoxContainer = HBoxContainer.new()
	id_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	id_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(id_hbox)

	var id_prompt: Label = Label.new()
	id_prompt.text = "Profile ID:"
	id_prompt.add_theme_font_size_override("font_size", 18)
	id_prompt.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	id_hbox.add_child(id_prompt)

	profile_id_label = Label.new()
	profile_id_label.add_theme_font_size_override("font_size", 18)
	profile_id_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	id_hbox.add_child(profile_id_label)

	var copy_id_btn: Button = Button.new()
	copy_id_btn.text = "COPY FULL"
	copy_id_btn.custom_minimum_size = Vector2(110, 34)
	copy_id_btn.add_theme_font_size_override("font_size", 14)
	copy_id_btn.pressed.connect(_on_copy_id_pressed)
	id_hbox.add_child(copy_id_btn)

	# --- Stats row ---
	var stats_hbox: HBoxContainer = HBoxContainer.new()
	stats_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_hbox.add_theme_constant_override("separation", 30)
	main_vbox.add_child(stats_hbox)

	# Wins
	var wins_vbox: VBoxContainer = VBoxContainer.new()
	wins_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_hbox.add_child(wins_vbox)

	var wins_title: Label = Label.new()
	wins_title.text = "WINS"
	wins_title.add_theme_font_size_override("font_size", 16)
	wins_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	wins_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wins_vbox.add_child(wins_title)

	stats_wins_label = Label.new()
	stats_wins_label.add_theme_font_size_override("font_size", 28)
	stats_wins_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	stats_wins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wins_vbox.add_child(stats_wins_label)

	# Losses
	var losses_vbox: VBoxContainer = VBoxContainer.new()
	losses_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_hbox.add_child(losses_vbox)

	var losses_title: Label = Label.new()
	losses_title.text = "LOSSES"
	losses_title.add_theme_font_size_override("font_size", 16)
	losses_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	losses_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	losses_vbox.add_child(losses_title)

	stats_losses_label = Label.new()
	stats_losses_label.add_theme_font_size_override("font_size", 28)
	stats_losses_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	stats_losses_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	losses_vbox.add_child(stats_losses_label)

	# Total
	var total_vbox: VBoxContainer = VBoxContainer.new()
	total_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_hbox.add_child(total_vbox)

	var total_title: Label = Label.new()
	total_title.text = "TOTAL"
	total_title.add_theme_font_size_override("font_size", 16)
	total_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	total_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	total_vbox.add_child(total_title)

	stats_total_label = Label.new()
	stats_total_label.add_theme_font_size_override("font_size", 28)
	stats_total_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	stats_total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	total_vbox.add_child(stats_total_label)

	# --- Fighter preference ---
	var pref_hbox: HBoxContainer = HBoxContainer.new()
	pref_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	pref_hbox.add_theme_constant_override("separation", 10)
	main_vbox.add_child(pref_hbox)

	var pref_prompt: Label = Label.new()
	pref_prompt.text = "Fighter Style:"
	pref_prompt.add_theme_font_size_override("font_size", 20)
	pref_hbox.add_child(pref_prompt)

	preference_btn = OptionButton.new()
	preference_btn.custom_minimum_size = Vector2(200, 40)
	preference_btn.add_theme_font_size_override("font_size", 18)
	preference_btn.add_item("Defensive", 0)
	preference_btn.add_item("Offensive", 1)
	pref_hbox.add_child(preference_btn)

	# --- Export / Import ---
	var ei_hbox: HBoxContainer = HBoxContainer.new()
	ei_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	ei_hbox.add_theme_constant_override("separation", 12)
	main_vbox.add_child(ei_hbox)

	export_btn = Button.new()
	export_btn.text = "EXPORT PROFILE"
	export_btn.custom_minimum_size = Vector2(190, 44)
	export_btn.add_theme_font_size_override("font_size", 18)
	export_btn.pressed.connect(_on_export_pressed)
	ei_hbox.add_child(export_btn)

	import_btn = Button.new()
	import_btn.text = "IMPORT PROFILE"
	import_btn.custom_minimum_size = Vector2(190, 44)
	import_btn.add_theme_font_size_override("font_size", 18)
	import_btn.pressed.connect(_on_import_pressed)
	ei_hbox.add_child(import_btn)

	# --- Status ---
	status_label = Label.new()
	status_label.text = ""
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(status_label)

	# --- Back button ---
	var back_btn: Button = Button.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(150, 40)
	back_btn.add_theme_font_size_override("font_size", 18)
	back_btn.pressed.connect(_on_back_pressed)
	main_vbox.add_child(back_btn)


# =============================================================================
#  DATA POPULATION
# =============================================================================

func _populate_fields() -> void:
	username_field.text = ProfileManager.username
	profile_id_label.text = ProfileManager.profile_id.substr(0, 8) + "..."

	var s: Dictionary = ProfileManager.stats
	stats_wins_label.text = str(s.get("wins", 0))
	stats_losses_label.text = str(s.get("losses", 0))
	stats_total_label.text = str(s.get("total_matches", 0))


# =============================================================================
#  ACTIONS
# =============================================================================

func _on_save_pressed() -> void:
	var new_name: String = username_field.text.strip_edges()
	if new_name.length() == 0:
		status_label.text = "Username cannot be empty!"
		status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return
	ProfileManager.username = new_name
	ProfileManager.save_profile()
	status_label.text = "Username saved!"
	status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))


func _on_copy_id_pressed() -> void:
	DisplayServer.clipboard_set(ProfileManager.profile_id)
	status_label.text = "Profile ID copied!"
	status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))


func _on_export_pressed() -> void:
	var data: String = ProfileManager.export_profile()
	DisplayServer.clipboard_set(data)
	export_btn.text = "COPIED!"
	status_label.text = "Profile exported to clipboard"
	status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	get_tree().create_timer(1.5).timeout.connect(func(): export_btn.text = "EXPORT PROFILE")


func _on_import_pressed() -> void:
	var clipboard: String = DisplayServer.clipboard_get().strip_edges()
	if clipboard.length() == 0:
		status_label.text = "Clipboard is empty!"
		status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return
	var success: bool = ProfileManager.import_profile(clipboard)
	if success:
		_populate_fields()
		status_label.text = "Profile imported successfully!"
		status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	else:
		status_label.text = "Invalid profile data!"
		status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _input(event: InputEvent) -> void:
	if InputManager.is_back_event(event):
		_on_back_pressed()
