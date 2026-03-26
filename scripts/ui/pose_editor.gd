extends Control

# Runtime pose editor — tweak joint rotations with sliders
# Press F2 to toggle on/off
# Adjust sliders, see changes live on P1 fighter
# Press "Save" to print the current pose values to console

var fighter_model: Node = null
var joint_sliders: Dictionary = {}  # joint_name -> {x: HSlider, y: HSlider, z: HSlider}
var root_offset_sliders: Dictionary = {}  # axis -> HSlider

var joint_names = [
	"root", "abdomen",
	"arm_l", "forearm_l", "arm_r", "forearm_r",
	"torso", "head",
	"leg_l", "shin_l", "foot_l",
	"leg_r", "shin_r", "foot_r",
]

# Display names showing viewer perspective (L=scene left=viewer RIGHT due to 180 flip)
var display_names = {
	"root": "ROOT", "abdomen": "ABDOMEN (waist)",
	"arm_l": "arm_l (VIEW RIGHT)", "forearm_l": "forearm_l (VIEW RIGHT)",
	"arm_r": "arm_r (VIEW LEFT)", "forearm_r": "forearm_r (VIEW LEFT)",
	"torso": "TORSO (chest)", "head": "HEAD",
	"leg_l": "leg_l (VIEW RIGHT)", "shin_l": "shin_l (VIEW RIGHT)", "foot_l": "foot_l (VIEW RIGHT)",
	"leg_r": "leg_r (VIEW LEFT)", "shin_r": "shin_r (VIEW LEFT)", "foot_r": "foot_r (VIEW LEFT)",
}

# Direct mapping: L=SceneL (viewer RIGHT), R=SceneR (viewer LEFT) due to 180 flip
# UI labels show viewer perspective below
const J = {
	"root": "Root",
	"abdomen": "Root/Abdomen",
	"torso": "Root/Abdomen/Torso",
	"head": "Root/Abdomen/Torso/Head",
	"arm_l": "Root/Abdomen/Torso/ShoulderL/UpperArmL",
	"forearm_l": "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL",
	"hand_l": "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL/HandL",
	"arm_r": "Root/Abdomen/Torso/ShoulderR/UpperArmR",
	"forearm_r": "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR",
	"hand_r": "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR/HandR",
	"leg_l": "Root/HipL/UpperLegL", "shin_l": "Root/HipL/UpperLegL/LowerLegL",
	"foot_l": "Root/HipL/UpperLegL/LowerLegL/FootL",
	"leg_r": "Root/HipR/UpperLegR", "shin_r": "Root/HipR/UpperLegR/LowerLegR",
	"foot_r": "Root/HipR/UpperLegR/LowerLegR/FootR",
}

var is_active: bool = false
var camera: Camera3D = null

# --- BATCH WORKFLOW ---
var move_dropdown: OptionButton = null
var keyframe_list: ItemList = null
var progress_slider: HSlider = null
var progress_label: Label = null
var keyframes: Dictionary = {}  # {move_name: [{progress: float, pose: Dictionary, root_y: float}]}
var current_move: String = ""
var is_playing_preview: bool = false
var preview_time: float = 0.0
var preview_speed: float = 1.0

const MOVE_LIST = [
	"fight_stance", "jab", "jab_2", "power_straight", "high_crush",
	"low_kick", "high_kick", "d_low_kick", "d_mid_punch",
	"outward_backfist", "df_mid_check",
	"walk_forward", "walk_backward", "dash_forward", "backdash",
	"sidestep", "crouch", "crouch_dash", "hop", "backsway",
	"knockdown", "getup",
]
var cam_original_transform: Transform3D
var cam_orbit_angle: float = 0.0  # Horizontal orbit in degrees
var cam_pitch: float = 20.0       # Vertical angle in degrees
var cam_distance: float = 4.0     # Distance from target
var cam_target: Vector3 = Vector3.ZERO  # Look-at target
var cam_dragging: bool = false
var cam_drag_start: Vector2 = Vector2.ZERO
var cam_orbit_start: float = 0.0
var cam_pitch_start: float = 0.0


func _ready() -> void:
	visible = false
	_build_ui()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F2:
		if not GameManager.training_mode:
			return  # Only in training mode
		is_active = !is_active
		visible = is_active
		if is_active:
			_find_fighter()
			if fighter_model:
				fighter_model.editor_active = true
			_find_camera()
			_load_current_pose()
		else:
			if fighter_model:
				fighter_model.editor_active = false
			_restore_camera()

	# Camera orbit with middle mouse or right mouse when editor is active
	if is_active and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE or event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				cam_dragging = true
				cam_drag_start = event.position
				cam_orbit_start = cam_orbit_angle
				cam_pitch_start = cam_pitch
			else:
				cam_dragging = false
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = max(1.5, cam_distance - 0.3)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = min(12.0, cam_distance + 0.3)
			_update_camera()

	if is_active and cam_dragging and event is InputEventMouseMotion:
		var delta = event.position - cam_drag_start
		cam_orbit_angle = cam_orbit_start + delta.x * 0.5
		cam_pitch = clamp(cam_pitch_start - delta.y * 0.3, -10, 80)
		_update_camera()


func _find_camera() -> void:
	var fight_scene = get_tree().current_scene
	if fight_scene and fight_scene.has_node("FightCamera"):
		camera = fight_scene.get_node("FightCamera")
		cam_original_transform = camera.global_transform
		# Set initial orbit from fighter1 position
		if fight_scene.has_node("Fighter1"):
			cam_target = fight_scene.get_node("Fighter1").global_position + Vector3(0, 1.0, 0)
		_update_camera()


func _restore_camera() -> void:
	if camera:
		camera.global_transform = cam_original_transform
		camera = null


func _update_camera() -> void:
	if camera == null:
		return
	var h_rad = deg_to_rad(cam_orbit_angle)
	var v_rad = deg_to_rad(cam_pitch)
	var offset = Vector3(
		sin(h_rad) * cos(v_rad) * cam_distance,
		sin(v_rad) * cam_distance,
		cos(h_rad) * cos(v_rad) * cam_distance
	)
	camera.global_position = cam_target + offset
	camera.look_at(cam_target, Vector3.UP)


func _find_fighter() -> void:
	# Find P1 fighter's model
	var fight_scene = get_tree().current_scene
	if fight_scene and fight_scene.has_node("Fighter1"):
		var f1 = fight_scene.get_node("Fighter1")
		if f1.has_node("Model"):
			fighter_model = f1.get_node("Model")


func _build_ui() -> void:
	# Dark background panel
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.custom_minimum_size = Vector2(320, 0)
	add_child(panel)

	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Title
	var title = Label.new()
	title.text = "POSE EDITOR (F2 toggle)"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	# Root offset sliders
	var root_label = Label.new()
	root_label.text = "--- Root Offset ---"
	vbox.add_child(root_label)
	for axis in ["y"]:
		_add_slider_row(vbox, "root_" + axis, -1.0, 0.5, 0.0, true)

	# Joint sliders
	for jname in joint_names:
		var sep = Label.new()
		sep.text = "--- " + display_names.get(jname, jname) + " ---"
		vbox.add_child(sep)

		for axis in ["x", "y", "z"]:
			var key = jname + "_" + axis
			_add_slider_row(vbox, key, -180, 180, 0.0, false)

	# ====== BATCH ANIMATION WORKFLOW ======
	var batch_title = Label.new()
	batch_title.text = "═══ ANIMATION BATCH TOOL ═══"
	batch_title.add_theme_font_size_override("font_size", 14)
	batch_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	vbox.add_child(batch_title)

	# Move selector
	var move_label = Label.new()
	move_label.text = "Select Move:"
	vbox.add_child(move_label)

	move_dropdown = OptionButton.new()
	for m in MOVE_LIST:
		move_dropdown.add_item(m)
	move_dropdown.item_selected.connect(_on_move_selected)
	vbox.add_child(move_dropdown)

	# Progress scrubber
	var prog_label = Label.new()
	prog_label.text = "Timeline (0.0 → 1.0):"
	vbox.add_child(prog_label)

	var prog_hbox = HBoxContainer.new()
	vbox.add_child(prog_hbox)

	progress_slider = HSlider.new()
	progress_slider.min_value = 0.0
	progress_slider.max_value = 1.0
	progress_slider.step = 0.01
	progress_slider.value = 0.0
	progress_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prog_hbox.add_child(progress_slider)

	progress_label = Label.new()
	progress_label.text = "0.00"
	progress_label.custom_minimum_size = Vector2(40, 0)
	prog_hbox.add_child(progress_label)

	progress_slider.value_changed.connect(func(val):
		progress_label.text = "%.2f" % val
	)

	# Keyframe buttons
	var kf_hbox = HBoxContainer.new()
	vbox.add_child(kf_hbox)

	var capture_btn = Button.new()
	capture_btn.text = "📌 Capture Keyframe"
	capture_btn.pressed.connect(_capture_keyframe)
	capture_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kf_hbox.add_child(capture_btn)

	var del_kf_btn = Button.new()
	del_kf_btn.text = "🗑 Delete"
	del_kf_btn.pressed.connect(_delete_selected_keyframe)
	kf_hbox.add_child(del_kf_btn)

	# Keyframe list
	var kf_label = Label.new()
	kf_label.text = "Keyframes:"
	vbox.add_child(kf_label)

	keyframe_list = ItemList.new()
	keyframe_list.custom_minimum_size = Vector2(0, 100)
	keyframe_list.item_selected.connect(_on_keyframe_selected)
	vbox.add_child(keyframe_list)

	# Preview playback
	var preview_hbox = HBoxContainer.new()
	vbox.add_child(preview_hbox)

	var play_btn = Button.new()
	play_btn.text = "▶ Preview"
	play_btn.pressed.connect(_toggle_preview)
	play_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_hbox.add_child(play_btn)

	var speed_label = Label.new()
	speed_label.text = "Speed:"
	preview_hbox.add_child(speed_label)

	var speed_options = OptionButton.new()
	speed_options.add_item("0.25x")
	speed_options.add_item("0.5x")
	speed_options.add_item("1.0x")
	speed_options.add_item("2.0x")
	speed_options.select(2)  # Default 1.0x
	speed_options.item_selected.connect(func(idx):
		preview_speed = [0.25, 0.5, 1.0, 2.0][idx]
	)
	preview_hbox.add_child(speed_options)

	# Generate code
	var gen_hbox = HBoxContainer.new()
	vbox.add_child(gen_hbox)

	var gen_btn = Button.new()
	gen_btn.text = "📋 Generate Code for Move"
	gen_btn.pressed.connect(_generate_move_code)
	gen_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gen_hbox.add_child(gen_btn)

	var gen_all_btn = Button.new()
	gen_all_btn.text = "📋 All Moves"
	gen_all_btn.pressed.connect(_generate_all_code)
	gen_hbox.add_child(gen_all_btn)

	# ====== PRESETS & TOOLS ======
	var tools_title = Label.new()
	tools_title.text = "═══ TOOLS ═══"
	tools_title.add_theme_font_size_override("font_size", 14)
	tools_title.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	vbox.add_child(tools_title)

	var stance_btn = Button.new()
	stance_btn.text = "Load Fight Stance"
	stance_btn.pressed.connect(_load_fight_stance)
	vbox.add_child(stance_btn)

	var crouch_btn = Button.new()
	crouch_btn.text = "Load Crouch"
	crouch_btn.pressed.connect(_load_crouch)
	vbox.add_child(crouch_btn)

	var save_btn = Button.new()
	save_btn.text = "Print Pose to Console"
	save_btn.pressed.connect(_print_pose)
	vbox.add_child(save_btn)

	var reset_btn = Button.new()
	reset_btn.text = "Reset to Zero (T-Pose)"
	reset_btn.pressed.connect(_reset_all)
	vbox.add_child(reset_btn)


func _add_slider_row(parent: Control, key: String, min_val: float, max_val: float, default: float, is_root: bool) -> void:
	var hbox = HBoxContainer.new()
	parent.add_child(hbox)

	var label = Label.new()
	label.text = key
	label.custom_minimum_size = Vector2(100, 0)
	hbox.add_child(label)

	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = default
	slider.step = 1.0 if not is_root else 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(120, 0)
	hbox.add_child(slider)

	var value_label = Label.new()
	value_label.text = str(default)
	value_label.custom_minimum_size = Vector2(50, 0)
	hbox.add_child(value_label)

	slider.value_changed.connect(func(val):
		value_label.text = str(snapped(val, 0.01 if is_root else 1.0))
		_apply_to_model()
	)

	if is_root:
		root_offset_sliders[key] = slider
	else:
		if not joint_sliders.has(key.get_slice("_", 0) + "_" + key.get_slice("_", 1) if key.count("_") == 2 else key.rsplit("_", true, 1)[0]):
			pass
		joint_sliders[key] = slider


func _apply_to_model() -> void:
	if fighter_model == null:
		return

	# Disable the normal pose system temporarily
	fighter_model.idle_bob_active = false

	for jname in joint_names:
		var path = J[jname] if J.has(jname) else ""
		if path == "" or not fighter_model.has_node(path):
			continue

		var node = fighter_model.get_node(path)
		var rest = fighter_model.rest_rotations.get(path, Vector3.ZERO)

		var x_key = jname + "_x"
		var y_key = jname + "_y"
		var z_key = jname + "_z"

		var x_val = joint_sliders[x_key].value if joint_sliders.has(x_key) else 0.0
		var y_val = joint_sliders[y_key].value if joint_sliders.has(y_key) else 0.0
		var z_val = joint_sliders[z_key].value if joint_sliders.has(z_key) else 0.0

		node.rotation_degrees = rest + Vector3(x_val, y_val, z_val)

	# Root offset
	if root_offset_sliders.has("root_y"):
		var root = fighter_model.get_node("Root")
		root.position = fighter_model.root_rest_pos + Vector3(0, root_offset_sliders["root_y"].value, 0)


func _load_current_pose() -> void:
	if fighter_model == null:
		return

	for jname in joint_names:
		var path = J[jname] if J.has(jname) else ""
		if path == "" or not fighter_model.has_node(path):
			continue

		var node = fighter_model.get_node(path)
		var rest = fighter_model.rest_rotations.get(path, Vector3.ZERO)
		var current = node.rotation_degrees - rest

		var x_key = jname + "_x"
		var y_key = jname + "_y"
		var z_key = jname + "_z"

		if joint_sliders.has(x_key):
			joint_sliders[x_key].value = current.x
		if joint_sliders.has(y_key):
			joint_sliders[y_key].value = current.y
		if joint_sliders.has(z_key):
			joint_sliders[z_key].value = current.z


func _print_pose() -> void:
	print("\n# --- POSE OUTPUT ---")
	print("_set_pose({")

	for jname in joint_names:
		var x_key = jname + "_x"
		var y_key = jname + "_y"
		var z_key = jname + "_z"

		var x_val = int(joint_sliders[x_key].value) if joint_sliders.has(x_key) else 0
		var y_val = int(joint_sliders[y_key].value) if joint_sliders.has(y_key) else 0
		var z_val = int(joint_sliders[z_key].value) if joint_sliders.has(z_key) else 0

		if x_val != 0 or y_val != 0 or z_val != 0:
			print('\t"%s": Vector3(%d, %d, %d),' % [jname, x_val, y_val, z_val])

	if root_offset_sliders.has("root_y"):
		var ry = snapped(root_offset_sliders["root_y"].value, 0.01)
		if ry != 0:
			print("}, Vector3(0, %s, 0))" % str(ry))
		else:
			print("})")
	else:
		print("})")
	print("# --- END POSE ---\n")


func _reset_all() -> void:
	for key in joint_sliders:
		joint_sliders[key].value = 0
	for key in root_offset_sliders:
		root_offset_sliders[key].value = 0
	_apply_to_model()


func _load_preset(pose: Dictionary, root_y: float = 0.0) -> void:
	# First reset everything
	for key in joint_sliders:
		joint_sliders[key].value = 0
	for key in root_offset_sliders:
		root_offset_sliders[key].value = 0

	# Apply preset values
	for jname in pose:
		var val = pose[jname]
		var x_key = jname + "_x"
		var y_key = jname + "_y"
		var z_key = jname + "_z"
		if joint_sliders.has(x_key):
			joint_sliders[x_key].value = val.x
		if joint_sliders.has(y_key):
			joint_sliders[y_key].value = val.y
		if joint_sliders.has(z_key):
			joint_sliders[z_key].value = val.z

	if root_offset_sliders.has("root_y"):
		root_offset_sliders["root_y"].value = root_y

	_apply_to_model()


func _load_fight_stance() -> void:
	# Swapped from original editor values: old arm_l -> now arm_r, old arm_r -> now arm_l
	_load_preset({
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": Vector3(-76, 20, 73),        # Viewer RIGHT (was editor arm_r)
		"forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-81, -32, -73),       # Viewer LEFT (was editor arm_l)
		"forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(21, 0, 0),            # Viewer RIGHT (was editor leg_r)
		"shin_l": Vector3(34, 13, -6),
		"leg_r": Vector3(-39, -1, 0),          # Viewer LEFT (was editor leg_l)
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	})


func _load_crouch() -> void:
	_load_preset({
		"torso": Vector3(12, 0, 0),
		"head": Vector3(-8, -1, -1),
		"arm_l": Vector3(-76, -27, -73),
		"forearm_l": Vector3(6, -61, 0),
		"arm_r": Vector3(-71, 15, 73),
		"forearm_r": Vector3(-10, 74, -1),
		"leg_l": Vector3(-65, -1, 0),
		"shin_l": Vector3(60, 0, 0),
		"foot_l": Vector3(-10, 0, 0),
		"leg_r": Vector3(-55, 0, 0),
		"shin_r": Vector3(55, 13, -6),
		"foot_r": Vector3(-10, 0, 0),
	}, -0.32)


# ====== BATCH ANIMATION WORKFLOW FUNCTIONS ======

func _on_move_selected(idx: int) -> void:
	current_move = MOVE_LIST[idx]
	_refresh_keyframe_list()
	# Load fight stance as starting point
	_load_fight_stance()
	progress_slider.value = 0.0


func _get_current_pose() -> Dictionary:
	var pose = {}
	for jname in joint_names:
		var x_key = jname + "_x"
		var y_key = jname + "_y"
		var z_key = jname + "_z"
		var x_val = int(joint_sliders[x_key].value) if joint_sliders.has(x_key) else 0
		var y_val = int(joint_sliders[y_key].value) if joint_sliders.has(y_key) else 0
		var z_val = int(joint_sliders[z_key].value) if joint_sliders.has(z_key) else 0
		if x_val != 0 or y_val != 0 or z_val != 0:
			pose[jname] = Vector3(x_val, y_val, z_val)
	return pose


func _get_current_root_y() -> float:
	if root_offset_sliders.has("root_y"):
		return snapped(root_offset_sliders["root_y"].value, 0.01)
	return 0.0


func _capture_keyframe() -> void:
	if current_move == "":
		print("⚠ Select a move first!")
		return

	var progress = snapped(progress_slider.value, 0.01)
	var pose = _get_current_pose()
	var root_y = _get_current_root_y()

	if not keyframes.has(current_move):
		keyframes[current_move] = []

	# Replace existing keyframe at same progress, or add new
	var found = false
	for i in range(keyframes[current_move].size()):
		if absf(keyframes[current_move][i].progress - progress) < 0.005:
			keyframes[current_move][i] = {"progress": progress, "pose": pose, "root_y": root_y}
			found = true
			break

	if not found:
		keyframes[current_move].append({"progress": progress, "pose": pose, "root_y": root_y})

	# Sort by progress
	keyframes[current_move].sort_custom(func(a, b): return a.progress < b.progress)

	_refresh_keyframe_list()
	print("✅ Captured keyframe at progress=%.2f for '%s'" % [progress, current_move])


func _delete_selected_keyframe() -> void:
	if current_move == "" or not keyframes.has(current_move):
		return
	var selected = keyframe_list.get_selected_items()
	if selected.is_empty():
		return
	var idx = selected[0]
	if idx < keyframes[current_move].size():
		keyframes[current_move].remove_at(idx)
		_refresh_keyframe_list()
		print("🗑 Deleted keyframe")


func _on_keyframe_selected(idx: int) -> void:
	if current_move == "" or not keyframes.has(current_move):
		return
	if idx >= keyframes[current_move].size():
		return
	var kf = keyframes[current_move][idx]
	# Load this keyframe into the sliders
	_load_preset(kf.pose, kf.root_y)
	progress_slider.value = kf.progress


func _refresh_keyframe_list() -> void:
	keyframe_list.clear()
	if current_move == "" or not keyframes.has(current_move):
		return
	for kf in keyframes[current_move]:
		var joint_count = kf.pose.size()
		keyframe_list.add_item("⏱ %.2f  (%d joints)" % [kf.progress, joint_count])


func _toggle_preview() -> void:
	is_playing_preview = !is_playing_preview
	if is_playing_preview:
		preview_time = 0.0
		print("▶ Playing preview for '%s'" % current_move)
	else:
		print("⏹ Preview stopped")


func _process(delta: float) -> void:
	if is_playing_preview and current_move != "" and keyframes.has(current_move):
		var kfs = keyframes[current_move]
		if kfs.size() < 2:
			is_playing_preview = false
			return

		preview_time += delta * preview_speed
		var total_time = 1.0  # Full animation = 1 second at 1x speed
		if preview_time > total_time:
			preview_time = 0.0  # Loop

		var progress = preview_time / total_time
		progress_slider.value = progress

		# Interpolate between keyframes
		var pose = _interpolate_keyframes(kfs, progress)
		if pose.has("_pose"):
			_load_preset(pose["_pose"], pose.get("_root_y", 0.0))


func _interpolate_keyframes(kfs: Array, progress: float) -> Dictionary:
	if kfs.is_empty():
		return {}

	# Find surrounding keyframes
	var prev_kf = kfs[0]
	var next_kf = kfs[kfs.size() - 1]

	for i in range(kfs.size()):
		if kfs[i].progress <= progress:
			prev_kf = kfs[i]
		if kfs[i].progress >= progress:
			next_kf = kfs[i]
			break

	if prev_kf.progress == next_kf.progress:
		return {"_pose": prev_kf.pose, "_root_y": prev_kf.root_y}

	# Lerp between prev and next
	var t = (progress - prev_kf.progress) / (next_kf.progress - prev_kf.progress)
	t = clampf(t, 0.0, 1.0)

	var result_pose = {}
	# Collect all joints from both keyframes
	var all_joints = {}
	for j in prev_kf.pose:
		all_joints[j] = true
	for j in next_kf.pose:
		all_joints[j] = true

	for j in all_joints:
		var prev_val = prev_kf.pose.get(j, Vector3.ZERO)
		var next_val = next_kf.pose.get(j, Vector3.ZERO)
		result_pose[j] = prev_val.lerp(next_val, t)

	var result_root_y = lerpf(prev_kf.root_y, next_kf.root_y, t)

	return {"_pose": result_pose, "_root_y": result_root_y}


func _generate_move_code() -> void:
	if current_move == "" or not keyframes.has(current_move):
		print("⚠ No keyframes for '%s'" % current_move)
		return

	var kfs = keyframes[current_move]
	print("\n# ====== GENERATED CODE: %s ======" % current_move)
	print("func set_pose_%s(progress: float) -> void:" % current_move)
	print("\tidle_bob_active = false")
	print("\tblend_speed = 25.0")

	if kfs.size() == 1:
		# Single pose — simple sin-based
		print("\tvar p = sin(progress * PI)")
		_print_pose_lerp("STANCE", kfs[0].pose, "p", kfs[0].root_y)
	elif kfs.size() == 2:
		# Two keyframes: start → end
		print("\tvar p = sin(progress * PI)")
		_print_pose_lerp_two(kfs[0], kfs[1], "p")
	else:
		# Multi-phase
		print("\t# %d keyframes" % kfs.size())
		for i in range(kfs.size()):
			var kf = kfs[i]
			print("\t# KF%d at progress=%.2f" % [i, kf.progress])

		# Generate phase variables
		for i in range(1, kfs.size()):
			var prev_p = kfs[i-1].progress
			var curr_p = kfs[i].progress
			var duration = curr_p - prev_p
			print("\tvar phase%d = clampf((progress - %.2f) / %.2f, 0.0, 1.0)" % [i, prev_p, duration])
			print("\tvar t%d = sin(phase%d * PI * 0.5)" % [i, i])

		# Generate blended pose
		print("\t# Blend phases")
		print("\tvar pose = {}")

		# Collect all joints
		var all_joints = {}
		for kf in kfs:
			for j in kf.pose:
				all_joints[j] = true

		for j in all_joints:
			var values = []
			for kf in kfs:
				values.append(kf.pose.get(j, Vector3.ZERO))
			print("\t# %s: %s" % [j, str(values)])

		print("\t_set_pose(pose)")

	print("# ====== END %s ======\n" % current_move)


func _print_pose_lerp(label: String, pose: Dictionary, var_name: String, root_y: float) -> void:
	print("\t_set_pose({")
	for j in pose:
		var v = pose[j]
		print('\t\t"%s": STANCE_%s.lerp(Vector3(%d, %d, %d), %s),' % [
			j, j.to_upper().replace(" ", "_"), int(v.x), int(v.y), int(v.z), var_name])
	if root_y != 0:
		print("\t}, Vector3(0, %s * %s, 0))" % [var_name, str(root_y)])
	else:
		print("\t})")


func _print_pose_lerp_two(kf1: Dictionary, kf2: Dictionary, var_name: String) -> void:
	print("\t_set_pose({")
	var all_joints = {}
	for j in kf1.pose:
		all_joints[j] = true
	for j in kf2.pose:
		all_joints[j] = true

	for j in all_joints:
		var v1 = kf1.pose.get(j, Vector3.ZERO)
		var v2 = kf2.pose.get(j, Vector3.ZERO)
		print('\t\t"%s": Vector3(%d, %d, %d).lerp(Vector3(%d, %d, %d), %s),' % [
			j, int(v1.x), int(v1.y), int(v1.z), int(v2.x), int(v2.y), int(v2.z), var_name])

	var ry1 = kf1.root_y
	var ry2 = kf2.root_y
	if ry1 != 0 or ry2 != 0:
		print("\t}, Vector3(0, lerpf(%s, %s, %s), 0))" % [str(ry1), str(ry2), var_name])
	else:
		print("\t})")


func _generate_all_code() -> void:
	print("\n# ====== ALL MOVES CODE ======")
	for move_name in keyframes:
		if keyframes[move_name].size() > 0:
			current_move = move_name
			_generate_move_code()
	print("# ====== END ALL MOVES ======")
