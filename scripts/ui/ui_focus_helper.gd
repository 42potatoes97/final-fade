class_name UIFocusHelper
extends RefCounted

# Shared utility for gamepad-friendly menu navigation.
# Call setup_focus(root_node) in _ready() of any menu screen
# to enable D-pad navigation + highlight styling on all buttons.


static func setup_focus(root: Node, grab_first: bool = true) -> void:
	var buttons: Array = _find_buttons(root)
	if buttons.is_empty():
		return

	# Focus style — gold border, bright text
	var focus_style = StyleBoxFlat.new()
	focus_style.bg_color = Color(0.25, 0.25, 0.4, 1.0)
	focus_style.border_color = Color(1.0, 0.8, 0.2, 1.0)
	focus_style.set_border_width_all(2)
	focus_style.set_corner_radius_all(4)
	focus_style.set_content_margin_all(8)

	var hover_style = StyleBoxFlat.new()
	hover_style.bg_color = Color(0.2, 0.2, 0.35, 1.0)
	hover_style.set_corner_radius_all(4)
	hover_style.set_content_margin_all(8)

	for btn in buttons:
		btn.focus_mode = Control.FOCUS_ALL
		btn.add_theme_stylebox_override("focus", focus_style)
		btn.add_theme_stylebox_override("hover", hover_style)
		btn.add_theme_color_override("font_focus_color", Color(1.0, 0.9, 0.3))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.85, 0.4))

	if grab_first and buttons.size() > 0:
		buttons[0].call_deferred("grab_focus")


static func _find_buttons(node: Node) -> Array:
	var buttons: Array = []
	if node is BaseButton and node.visible and not node.disabled:
		buttons.append(node)
	for child in node.get_children():
		if child.visible or child is BaseButton:
			buttons.append_array(_find_buttons(child))
	return buttons
