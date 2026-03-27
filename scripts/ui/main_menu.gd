extends Control

# Main menu — entry point for the game

@onready var versus_submenu: VBoxContainer = $VBox/VersusSubmenu
@onready var ai_submenu: VBoxContainer = $VBox/AISubmenu


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	UIFocusHelper.setup_focus(self, false)
	$VBox/VersusBtn.grab_focus()


func _on_versus_pressed() -> void:
	# Toggle versus submenu
	versus_submenu.visible = not versus_submenu.visible
	ai_submenu.visible = false
	if versus_submenu.visible:
		$VBox/VersusSubmenu/LocalBtn.grab_focus()
	else:
		$VBox/VersusBtn.grab_focus()


func _on_local_pressed() -> void:
	GameManager.training_mode = false
	GameManager.ai_mode = false
	GameManager.online_mode = false
	get_tree().change_scene_to_file("res://scenes/ui/side_select.tscn")


func _on_online_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/online_lobby.tscn")


func _on_training_pressed() -> void:
	GameManager.training_mode = true
	GameManager.ai_mode = false
	GameManager.online_mode = false
	get_tree().change_scene_to_file("res://scenes/ui/side_select.tscn")


func _on_ai_pressed() -> void:
	# Toggle AI submenu
	ai_submenu.visible = not ai_submenu.visible
	versus_submenu.visible = false
	if ai_submenu.visible:
		$VBox/AISubmenu/ScriptedBtn.grab_focus()
	else:
		$VBox/AIBtn.grab_focus()


func _on_scripted_ai_pressed() -> void:
	GameManager.training_mode = false
	GameManager.ai_mode = true
	GameManager.online_mode = false
	get_tree().change_scene_to_file("res://scenes/ui/side_select.tscn")


func _on_pose_editor_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main/pose_editor_scene.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
