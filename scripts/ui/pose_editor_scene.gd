extends Node3D

# Dedicated Pose Editor Scene
# - Single fighter model on a small stage
# - Clean UI with labeled joint sliders grouped by body part
# - Preset loading (fight stance, crouch, etc.)
# - Copy/paste pose output for code integration
# - Orbit camera (right-click drag)
# - ESC to return to main menu

@onready var model: Node3D = $Fighter/Model
@onready var ui: Control = $UI

# Joint path mapping (matches fighter_model.gd)
const J = {
	"root": "Root",
	"abdomen": "Root/Abdomen",
	"torso": "Root/Abdomen/Torso",
	"head": "Root/Abdomen/Torso/Head",
	"arm_l": "Root/Abdomen/Torso/ShoulderL/UpperArmL",
	"forearm_l": "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL",
	"arm_r": "Root/Abdomen/Torso/ShoulderR/UpperArmR",
	"forearm_r": "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR",
	"leg_l": "Root/HipL/UpperLegL",
	"shin_l": "Root/HipL/UpperLegL/LowerLegL",
	"foot_l": "Root/HipL/UpperLegL/LowerLegL/FootL",
	"leg_r": "Root/HipR/UpperLegR",
	"shin_r": "Root/HipR/UpperLegR/LowerLegR",
	"foot_r": "Root/HipR/UpperLegR/LowerLegR/FootR",
}

# Groups for UI layout
const JOINT_GROUPS = [
	{"name": "CORE", "joints": ["root", "abdomen", "torso", "head"]},
	{"name": "LEFT ARM (Viewer Right)", "joints": ["arm_l", "forearm_l"]},
	{"name": "RIGHT ARM (Viewer Left)", "joints": ["arm_r", "forearm_r"]},
	{"name": "LEFT LEG (Viewer Right)", "joints": ["leg_l", "shin_l", "foot_l"]},
	{"name": "RIGHT LEG (Viewer Left)", "joints": ["leg_r", "shin_r", "foot_r"]},
]

const FRIENDLY_NAMES = {
	"root": "Root Offset",
	"abdomen": "Abdomen (Waist)",
	"torso": "Torso (Chest)",
	"head": "Head",
	"arm_l": "Upper Arm",
	"forearm_l": "Forearm",
	"arm_r": "Upper Arm",
	"forearm_r": "Forearm",
	"leg_l": "Upper Leg",
	"shin_l": "Shin",
	"foot_l": "Foot",
	"leg_r": "Upper Leg",
	"shin_r": "Shin",
	"foot_r": "Foot",
}

var sliders: Dictionary = {}  # "joint_axis" -> HSlider
var value_labels: Dictionary = {}  # "joint_axis" -> Label
var rest_rotations: Dictionary = {}
var joints: Dictionary = {}
var root_node: Node3D
var root_rest_pos: Vector3

# Root offset sliders
var root_offset_sliders: Dictionary = {}

# --- BATCH ANIMATION WORKFLOW ---
var move_dropdown: OptionButton = null
var keyframe_list: ItemList = null
var progress_slider: HSlider = null
var progress_label: Label = null
var kf_data: Dictionary = {}  # {move_name: [{progress: float, pose: Dictionary, root_y: float}]}
var current_move: String = ""
var is_previewing: bool = false
var preview_time: float = 0.0
var preview_speed: float = 1.0
var preview_btn: Button = null

const MOVE_LIST = [
	"fight_stance", "jab", "jab_2", "power_straight", "high_crush",
	"low_kick", "high_kick", "d_low_kick", "d_mid_punch",
	"outward_backfist", "df_mid_check", "d4_kick", "d3_3_rising",
	"walk_forward", "walk_backward", "dash_forward", "backdash",
	"sidestep", "crouch", "crouch_dash", "hop", "backsway",
	"knockdown", "getup", "getup_kick", "side_roll",
]

# Map move names to their set_pose_* function names (if different)
const MOVE_POSE_FUNC = {
	"fight_stance": "set_pose_fight_stance",
	"jab": "set_pose_jab",
	"jab_2": "set_pose_jab_2",
	"power_straight": "set_pose_power_straight",
	"high_crush": "set_pose_high_crush",
	"low_kick": "set_pose_low_kick",
	"high_kick": "set_pose_high_kick",
	"d_low_kick": "set_pose_d_low_kick",
	"d_mid_punch": "set_pose_d_mid_punch",
	"outward_backfist": "set_pose_outward_backfist",
	"df_mid_check": "set_pose_df_mid_check",
	"d4_kick": "set_pose_d4_kick",
	"d3_3_rising": "set_pose_d3_3_rising",
	"walk_forward": "set_pose_walk_forward",
	"walk_backward": "set_pose_walk_backward",
	"dash_forward": "set_pose_dash_forward",
	"backdash": "set_pose_backdash",
	"sidestep": "set_pose_sidestep",
	"crouch": "set_pose_crouch",
	"crouch_dash": "set_pose_crouch_dash",
	"hop": "set_pose_hop",
	"backsway": "set_pose_backsway",
	"knockdown": "set_pose_knockdown",
	"getup": "set_pose_getup",
	"getup_kick": "set_pose_getup_kick",
	"side_roll": "set_pose_side_roll",
}

const KF_SAVE_PATH = "user://pose_keyframes.json"

# Impact progress for each move — the frame where the hit connects
const MOVE_IMPACT_PROGRESS = {
	"fight_stance": 0.0,
	"jab": 0.5,
	"jab_2": 0.5,
	"power_straight": 0.5,
	"high_crush": 0.5,
	"low_kick": 0.4,
	"high_kick": 0.35,
	"d_low_kick": 0.45,
	"d_mid_punch": 0.45,
	"outward_backfist": 0.5,
	"df_mid_check": 0.5,
	"d4_kick": 0.5,
	"d3_3_rising": 0.5,
	"walk_forward": 0.25,
	"walk_backward": 0.25,
	"dash_forward": 0.5,
	"backdash": 0.3,
	"sidestep": 0.5,
	"crouch": 0.0,
	"crouch_dash": 0.5,
	"hop": 0.5,
	"backsway": 0.4,
	"knockdown": 0.0,
	"getup": 0.5,
	"getup_kick": 0.5,
	"side_roll": 0.5,
}

var preset_dropdown: OptionButton = null

# Dummy opponent
var dummy_node: Node3D
var dummy_model: Node3D
var hurtbox_mesh: MeshInstance3D
var range_indicator: MeshInstance3D
var hitbox_info_label: Label

# Hitbox constants (must match hit_system.gd)
const HURTBOX_RADIUS: float = 0.55
const DEFAULT_MAX_RANGE: float = 2.0

# Camera orbit
var cam: Camera3D
var cam_distance: float = 3.5
var cam_yaw: float = 0.0
var cam_pitch: float = 20.0
var cam_target: Vector3 = Vector3(0, 1.0, 0)
var is_orbiting: bool = false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	cam = $Camera3D

	# Initialize joints
	root_node = model.get_node("Root")
	root_rest_pos = root_node.position
	for jname in J:
		var path = J[jname]
		if model.has_node(path):
			joints[jname] = model.get_node(path)
			rest_rotations[jname] = joints[jname].rotation_degrees

	# Disable the model's own pose system so our sliders take effect
	model.editor_active = true

	# Setup dummy opponent
	dummy_node = $Dummy
	dummy_model = $Dummy/DummyModel
	dummy_model.editor_active = true
	# Load fight stance on dummy
	hurtbox_mesh = $Dummy/Hurtbox
	range_indicator = $RangeIndicator

	_build_ui()
	_update_camera()
	# Load fight stance as default
	_load_preset("Fight Stance")
	# Position dummy at default max range
	_update_dummy_position(DEFAULT_MAX_RANGE)


func _update_dummy_position(distance: float) -> void:
	# Fighter faces -Z (due to 180 flip), so dummy goes at -Z
	dummy_node.position = Vector3(0, 0, -distance)
	# Update range indicator radius
	if range_indicator and range_indicator.mesh is CylinderMesh:
		range_indicator.mesh.top_radius = distance
		range_indicator.mesh.bottom_radius = distance


func _process(delta: float) -> void:
	_update_hitbox_info()

	# Preview playback
	if is_previewing and current_move != "" and kf_data.has(current_move) and kf_data[current_move].size() >= 2:
		preview_time += delta * preview_speed
		if preview_time > 1.0:
			preview_time = 0.0
		progress_slider.value = preview_time
		var interp = _interpolate_kfs(kf_data[current_move], preview_time)
		if interp.has("pose"):
			# Apply interpolated pose to sliders
			for key in sliders:
				sliders[key].value = 0
			var iro = interp.get("root_offset", Vector3.ZERO)
			if root_offset_sliders.has("root_x"): root_offset_sliders["root_x"].value = iro.x
			if root_offset_sliders.has("root_y"): root_offset_sliders["root_y"].value = iro.y
			if root_offset_sliders.has("root_z"): root_offset_sliders["root_z"].value = iro.z
			for jname in interp.pose:
				var v = interp.pose[jname]
				if sliders.has(jname + "_x"): sliders[jname + "_x"].value = v.x
				if sliders.has(jname + "_y"): sliders[jname + "_y"].value = v.y
				if sliders.has(jname + "_z"): sliders[jname + "_z"].value = v.z
			_apply_pose()


func _update_hitbox_info() -> void:
	if hitbox_info_label == null:
		return
	# Calculate distances from each limb to dummy center
	var dummy_pos = dummy_node.global_position
	var info_lines = []
	var limbs = {"hand_l": "Hand L (View R)", "hand_r": "Hand R (View L)", "foot_l": "Foot L (View R)", "foot_r": "Foot R (View R)"}
	for limb_key in limbs:
		var path = J.get(limb_key.replace("hand_l", "arm_l").replace("hand_r", "arm_r"), "")
		# Get actual limb path
		var limb_path = ""
		match limb_key:
			"hand_l": limb_path = "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL/HandL"
			"hand_r": limb_path = "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR/HandR"
			"foot_l": limb_path = "Root/HipL/UpperLegL/LowerLegL/FootL"
			"foot_r": limb_path = "Root/HipR/UpperLegR/LowerLegR/FootR"
		if model.has_node(limb_path):
			var limb_node = model.get_node(limb_path)
			var limb_pos = limb_node.global_position
			var h_dist = Vector3(limb_pos.x, 0, limb_pos.z).distance_to(Vector3(dummy_pos.x, 0, dummy_pos.z))
			var in_range = h_dist <= (0.55 + HURTBOX_RADIUS)  # hit_radius + hurtbox
			var status = "✅" if in_range else "❌"
			info_lines.append("%s %s: %.2f %s" % [status, limbs[limb_key], h_dist, "(HIT)" if in_range else ""])

	var fighter_dist = Vector3(0, 0, 0).distance_to(Vector3(dummy_pos.x, 0, dummy_pos.z))
	info_lines.insert(0, "Fighter Distance: %.2f" % fighter_dist)
	info_lines.insert(1, "Hurtbox Radius: %.2f" % HURTBOX_RADIUS)
	info_lines.insert(2, "---")
	hitbox_info_label.text = "\n".join(info_lines)


func _build_ui() -> void:
	var panel = PanelContainer.new()
	panel.name = "EditorPanel"
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -420
	panel.offset_right = 0
	ui.add_child(panel)

	var scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Title
	var title = Label.new()
	title.text = "🎨 POSE EDITOR"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Instructions
	var instr = Label.new()
	instr.text = "Right-click + drag = Orbit camera\nScroll = Zoom\nESC = Back to menu"
	instr.add_theme_font_size_override("font_size", 12)
	instr.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	instr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(instr)

	_add_separator(vbox)

	# ====== BATCH ANIMATION SECTION ======
	var batch_title = Label.new()
	batch_title.text = "━━━ ANIMATION BATCH TOOL ━━━"
	batch_title.add_theme_font_size_override("font_size", 16)
	batch_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	batch_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(batch_title)

	# Move selector
	var move_hbox = HBoxContainer.new()
	vbox.add_child(move_hbox)
	var move_lbl = Label.new()
	move_lbl.text = "Move:"
	move_lbl.custom_minimum_size = Vector2(45, 0)
	move_hbox.add_child(move_lbl)
	move_dropdown = OptionButton.new()
	move_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for m in MOVE_LIST:
		move_dropdown.add_item(m)
	move_dropdown.item_selected.connect(_on_move_selected)
	move_hbox.add_child(move_dropdown)

	# Timeline scrubber
	var timeline_hbox = HBoxContainer.new()
	vbox.add_child(timeline_hbox)
	var prog_lbl = Label.new()
	prog_lbl.text = "Time:"
	prog_lbl.custom_minimum_size = Vector2(45, 0)
	timeline_hbox.add_child(prog_lbl)
	progress_slider = HSlider.new()
	progress_slider.min_value = 0.0
	progress_slider.max_value = 1.0
	progress_slider.step = 0.01
	progress_slider.value = 0.0
	progress_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline_hbox.add_child(progress_slider)
	progress_label = Label.new()
	progress_label.text = "0.00"
	progress_label.custom_minimum_size = Vector2(40, 0)
	timeline_hbox.add_child(progress_label)
	progress_slider.value_changed.connect(func(v): progress_label.text = "%.2f" % v)

	# Keyframe capture/delete buttons
	var kf_btn_hbox = HBoxContainer.new()
	vbox.add_child(kf_btn_hbox)
	var capture_btn = Button.new()
	capture_btn.text = "📌 Capture KF"
	capture_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	capture_btn.custom_minimum_size = Vector2(0, 35)
	capture_btn.pressed.connect(_capture_keyframe)
	kf_btn_hbox.add_child(capture_btn)
	var del_kf_btn = Button.new()
	del_kf_btn.text = "🗑 Delete KF"
	del_kf_btn.custom_minimum_size = Vector2(90, 35)
	del_kf_btn.pressed.connect(_delete_selected_keyframe)
	kf_btn_hbox.add_child(del_kf_btn)

	# Keyframe list
	keyframe_list = ItemList.new()
	keyframe_list.custom_minimum_size = Vector2(0, 80)
	keyframe_list.item_selected.connect(_on_keyframe_selected)
	vbox.add_child(keyframe_list)

	# Preview + speed
	var preview_hbox = HBoxContainer.new()
	vbox.add_child(preview_hbox)
	preview_btn = Button.new()
	preview_btn.text = "▶ Preview"
	preview_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_btn.custom_minimum_size = Vector2(0, 35)
	preview_btn.pressed.connect(_toggle_preview)
	preview_hbox.add_child(preview_btn)
	var speed_opt = OptionButton.new()
	speed_opt.add_item("0.25x")
	speed_opt.add_item("0.5x")
	speed_opt.add_item("1.0x")
	speed_opt.add_item("2.0x")
	speed_opt.select(2)
	speed_opt.item_selected.connect(func(idx): preview_speed = [0.25, 0.5, 1.0, 2.0][idx])
	preview_hbox.add_child(speed_opt)

	# Generate code
	var gen_hbox = HBoxContainer.new()
	vbox.add_child(gen_hbox)
	var gen_btn = Button.new()
	gen_btn.text = "📋 Generate Code"
	gen_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gen_btn.custom_minimum_size = Vector2(0, 35)
	gen_btn.pressed.connect(_generate_move_code)
	gen_hbox.add_child(gen_btn)
	var gen_all_btn = Button.new()
	gen_all_btn.text = "📋 All Moves"
	gen_all_btn.custom_minimum_size = Vector2(90, 35)
	gen_all_btn.pressed.connect(_generate_all_code)
	gen_hbox.add_child(gen_all_btn)

	_add_separator(vbox)

	# Root offset Y slider
	var root_label = Label.new()
	root_label.text = "--- ROOT Y OFFSET ---"
	root_label.add_theme_font_size_override("font_size", 14)
	root_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(root_label)
	_add_slider(vbox, "root_x", "X Offset", -1.0, 1.0, 0.0, true)
	_add_slider(vbox, "root_y", "Y Offset", -0.5, 0.5, 0.0, true)
	_add_slider(vbox, "root_z", "Z Offset", -1.0, 1.0, 0.0, true)

	_add_separator(vbox)

	# Preset section — dropdown with all moves + Default/Impact buttons
	var preset_label = Label.new()
	preset_label.text = "━━━ POSE PRESETS ━━━"
	preset_label.add_theme_font_size_override("font_size", 15)
	preset_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	preset_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(preset_label)

	# Move preset dropdown
	preset_dropdown = OptionButton.new()
	preset_dropdown.custom_minimum_size = Vector2(0, 30)
	# Add base presets first
	preset_dropdown.add_item("T-Pose")
	preset_dropdown.add_item("Fight Stance")
	preset_dropdown.add_item("Crouch")
	preset_dropdown.add_separator("── Moves ──")
	for move_name in MOVE_LIST:
		preset_dropdown.add_item(move_name)
	vbox.add_child(preset_dropdown)

	# Default / Impact / At Progress buttons
	var preset_btn_grid = GridContainer.new()
	preset_btn_grid.columns = 3
	vbox.add_child(preset_btn_grid)

	var load_default_btn = Button.new()
	load_default_btn.text = "Default"
	load_default_btn.custom_minimum_size = Vector2(120, 35)
	load_default_btn.tooltip_text = "Load the move's starting pose (progress=0)"
	load_default_btn.pressed.connect(_load_preset_at_progress.bind(0.0))
	preset_btn_grid.add_child(load_default_btn)

	var load_impact_btn = Button.new()
	load_impact_btn.text = "Impact"
	load_impact_btn.custom_minimum_size = Vector2(120, 35)
	load_impact_btn.tooltip_text = "Load the move's impact/peak pose"
	load_impact_btn.pressed.connect(_load_preset_at_impact)
	preset_btn_grid.add_child(load_impact_btn)

	var load_progress_btn = Button.new()
	load_progress_btn.text = "At Progress"
	load_progress_btn.custom_minimum_size = Vector2(120, 35)
	load_progress_btn.tooltip_text = "Load the move at the current timeline progress"
	load_progress_btn.pressed.connect(_load_move_pose)
	preset_btn_grid.add_child(load_progress_btn)

	# Save/Load keyframes to disk
	var kf_io_grid = GridContainer.new()
	kf_io_grid.columns = 2
	vbox.add_child(kf_io_grid)
	var save_kf_btn = Button.new()
	save_kf_btn.text = "💾 Save Keyframes"
	save_kf_btn.custom_minimum_size = Vector2(190, 35)
	save_kf_btn.pressed.connect(_save_keyframes_to_disk)
	kf_io_grid.add_child(save_kf_btn)
	var load_kf_btn = Button.new()
	load_kf_btn.text = "📂 Load Keyframes"
	load_kf_btn.custom_minimum_size = Vector2(190, 35)
	load_kf_btn.pressed.connect(_load_keyframes_from_disk)
	kf_io_grid.add_child(load_kf_btn)

	_add_separator(vbox)

	# Dummy distance slider
	var dist_label = Label.new()
	dist_label.text = "━━━ OPPONENT DISTANCE ━━━"
	dist_label.add_theme_font_size_override("font_size", 15)
	dist_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
	dist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(dist_label)

	var dist_hbox = HBoxContainer.new()
	vbox.add_child(dist_hbox)
	var dist_lbl = Label.new()
	dist_lbl.text = "Range"
	dist_lbl.custom_minimum_size = Vector2(45, 0)
	dist_hbox.add_child(dist_lbl)
	var dist_slider = HSlider.new()
	dist_slider.min_value = 0.8
	dist_slider.max_value = 3.5
	dist_slider.value = DEFAULT_MAX_RANGE
	dist_slider.step = 0.05
	dist_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dist_hbox.add_child(dist_slider)
	var dist_val = Label.new()
	dist_val.text = "%.1f" % DEFAULT_MAX_RANGE
	dist_val.custom_minimum_size = Vector2(40, 0)
	dist_hbox.add_child(dist_val)
	dist_slider.value_changed.connect(func(v):
		dist_val.text = "%.1f" % v
		_update_dummy_position(v)
	)

	# Hitbox info display
	_add_separator(vbox)
	var hb_title = Label.new()
	hb_title.text = "━━━ HITBOX INFO (LIVE) ━━━"
	hb_title.add_theme_font_size_override("font_size", 15)
	hb_title.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	hb_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hb_title)

	hitbox_info_label = Label.new()
	hitbox_info_label.text = "Loading..."
	hitbox_info_label.add_theme_font_size_override("font_size", 13)
	hitbox_info_label.add_theme_color_override("font_color", Color(0.8, 0.9, 0.8))
	vbox.add_child(hitbox_info_label)

	_add_separator(vbox)

	# Action buttons
	var action_grid = GridContainer.new()
	action_grid.columns = 2
	vbox.add_child(action_grid)

	var copy_btn = Button.new()
	copy_btn.text = "📋 Copy Pose to Clipboard"
	copy_btn.custom_minimum_size = Vector2(190, 40)
	copy_btn.pressed.connect(_copy_pose)
	action_grid.add_child(copy_btn)

	var print_btn = Button.new()
	print_btn.text = "🖨️ Print to Console"
	print_btn.custom_minimum_size = Vector2(190, 40)
	print_btn.pressed.connect(_print_pose)
	action_grid.add_child(print_btn)

	_add_separator(vbox)

	# Joint groups
	for group in JOINT_GROUPS:
		var group_label = Label.new()
		group_label.text = "━━━ " + group.name + " ━━━"
		group_label.add_theme_font_size_override("font_size", 15)
		group_label.add_theme_color_override("font_color", Color(0.4, 0.7, 1.0))
		group_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(group_label)

		for jname in group.joints:
			var friendly = FRIENDLY_NAMES.get(jname, jname)
			var jlabel = Label.new()
			jlabel.text = friendly + " (" + jname + ")"
			jlabel.add_theme_font_size_override("font_size", 13)
			jlabel.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
			vbox.add_child(jlabel)

			for axis in ["x", "y", "z"]:
				_add_slider(vbox, jname + "_" + axis, axis.to_upper(), -180, 180, 0.0)

	# Back button at bottom
	_add_separator(vbox)
	var back_btn = Button.new()
	back_btn.text = "← BACK TO MENU"
	back_btn.custom_minimum_size = Vector2(0, 45)
	back_btn.pressed.connect(_go_back)
	vbox.add_child(back_btn)


func _add_slider(parent: Node, key: String, label_text: String, min_val: float, max_val: float, default_val: float, is_root_offset: bool = false) -> void:
	var hbox = HBoxContainer.new()
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(25, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	hbox.add_child(lbl)

	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = default_val
	slider.step = 1.0 if not is_root_offset else 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(slider)

	var val_label = Label.new()
	val_label.text = str(int(default_val)) if not is_root_offset else "%.2f" % default_val
	val_label.custom_minimum_size = Vector2(45, 0)
	val_label.add_theme_font_size_override("font_size", 12)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(val_label)

	if is_root_offset:
		root_offset_sliders[key] = slider
		slider.value_changed.connect(func(v): val_label.text = "%.2f" % v; _apply_pose())
	else:
		sliders[key] = slider
		value_labels[key] = val_label
		slider.value_changed.connect(func(v): val_label.text = str(int(v)); _apply_pose())


func _add_separator(parent: Node) -> void:
	var sep = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 10)
	parent.add_child(sep)


func _apply_pose() -> void:
	for jname in J:
		if not joints.has(jname):
			continue
		var x_key = jname + "_x"
		var y_key = jname + "_y"
		var z_key = jname + "_z"
		var rot = rest_rotations.get(jname, Vector3.ZERO)
		if sliders.has(x_key):
			rot.x += sliders[x_key].value
		if sliders.has(y_key):
			rot.y += sliders[y_key].value
		if sliders.has(z_key):
			rot.z += sliders[z_key].value
		joints[jname].rotation_degrees = rot

	# Root offset (X, Y, Z)
	var rx = root_offset_sliders["root_x"].value if root_offset_sliders.has("root_x") else 0.0
	var ry = root_offset_sliders["root_y"].value if root_offset_sliders.has("root_y") else 0.0
	var rz = root_offset_sliders["root_z"].value if root_offset_sliders.has("root_z") else 0.0
	root_node.position = root_rest_pos + Vector3(rx, ry, rz)


func _load_preset(preset_name: String) -> void:
	var values = {}
	var root_y = 0.0
	match preset_name:
		"T-Pose":
			pass  # All zeros
		"Fight Stance":
			values = {
				"abdomen_y": -38, "torso_x": 2,
				"head_y": 13, "head_z": -1,
				"arm_l_x": -54, "arm_l_y": 5, "arm_l_z": 73,
				"forearm_l_x": -4, "forearm_l_y": 92, "forearm_l_z": 51,
				"arm_r_x": -62, "arm_r_y": -12, "arm_r_z": -73,
				"forearm_r_x": -12, "forearm_r_y": -66,
				"leg_l_x": 5, "leg_l_y": -16,
				"shin_l_x": 32, "shin_l_y": 4, "shin_l_z": -6,
				"foot_l_x": -22, "foot_l_y": -51, "foot_l_z": 32,
				"leg_r_x": -36, "leg_r_y": -3, "shin_r_x": 34,
				"foot_r_x": -1,
			}
		"Crouch":
			values = {
				"abdomen_x": 5,
				"arm_l_x": -52, "arm_l_y": 20, "arm_l_z": 73,
				"forearm_l_x": -3, "forearm_l_y": 110, "forearm_l_z": -1,
				"arm_r_x": -65, "arm_r_y": -21, "arm_r_z": -73,
				"forearm_r_x": 5, "forearm_r_y": -109, "forearm_r_z": -1,
				"torso_x": 37, "head_y": -1, "head_z": -1,
				"leg_l_x": -42, "shin_l_x": 112, "shin_l_y": 13, "shin_l_z": -6,
				"foot_l_x": -26, "foot_l_y": 13,
				"leg_r_x": -80, "leg_r_y": -1, "shin_r_x": 78,
				"foot_r_x": -1,
			}
			root_y = -0.18

	# Reset all sliders first
	for key in sliders:
		sliders[key].value = 0
	for key in root_offset_sliders:
		root_offset_sliders[key].value = 0

	# Apply preset values
	for key in values:
		if sliders.has(key):
			sliders[key].value = values[key]

	_apply_pose()


func _copy_pose() -> void:
	var output = _generate_pose_output()
	DisplayServer.clipboard_set(output)
	print("Pose copied to clipboard!")
	print(output)


func _print_pose() -> void:
	var output = _generate_pose_output()
	print(output)


func _generate_pose_output() -> String:
	var lines = ["# --- POSE OUTPUT ---", "_set_pose({"]
	for group in JOINT_GROUPS:
		for jname in group.joints:
			var x = sliders.get(jname + "_x", null)
			var y = sliders.get(jname + "_y", null)
			var z = sliders.get(jname + "_z", null)
			if x == null:
				continue
			var xv = int(x.value) if x else 0
			var yv = int(y.value) if y else 0
			var zv = int(z.value) if z else 0
			if xv == 0 and yv == 0 and zv == 0:
				continue
			lines.append('\t"%s": Vector3(%d, %d, %d),' % [jname, xv, yv, zv])

	# Root offset
	var root_offset = _get_current_root_offset()
	if root_offset.length() > 0.005:
		lines.append("}, Vector3(%d, %d, %d))" % [int(root_offset.x), int(root_offset.y), int(root_offset.z)])
	else:
		lines.append("})")
	lines.append("# --- END POSE ---")
	return "\n".join(lines)


# ====== BATCH ANIMATION FUNCTIONS ======

func _on_move_selected(idx: int) -> void:
	current_move = MOVE_LIST[idx]
	_refresh_keyframe_list()
	_load_preset("Fight Stance")
	progress_slider.value = 0.0


func _get_current_slider_pose() -> Dictionary:
	var pose = {}
	for group in JOINT_GROUPS:
		for jname in group.joints:
			var x = sliders.get(jname + "_x", null)
			var y = sliders.get(jname + "_y", null)
			var z = sliders.get(jname + "_z", null)
			var xv = int(x.value) if x else 0
			var yv = int(y.value) if y else 0
			var zv = int(z.value) if z else 0
			if xv != 0 or yv != 0 or zv != 0:
				pose[jname] = Vector3(xv, yv, zv)
	return pose


func _get_current_root_offset() -> Vector3:
	var rx = root_offset_sliders["root_x"].value if root_offset_sliders.has("root_x") else 0.0
	var ry = root_offset_sliders["root_y"].value if root_offset_sliders.has("root_y") else 0.0
	var rz = root_offset_sliders["root_z"].value if root_offset_sliders.has("root_z") else 0.0
	return Vector3(snapped(rx, 0.01), snapped(ry, 0.01), snapped(rz, 0.01))


func _capture_keyframe() -> void:
	if current_move == "":
		print("⚠ Select a move first!")
		return
	var progress = snapped(progress_slider.value, 0.01)
	var pose = _get_current_slider_pose()
	var root_off = _get_current_root_offset()

	if not kf_data.has(current_move):
		kf_data[current_move] = []

	# Replace or add
	var found = false
	for i in range(kf_data[current_move].size()):
		if absf(kf_data[current_move][i].progress - progress) < 0.005:
			kf_data[current_move][i] = {"progress": progress, "pose": pose, "root_offset": root_off}
			found = true
			break
	if not found:
		kf_data[current_move].append({"progress": progress, "pose": pose, "root_offset": root_off})

	kf_data[current_move].sort_custom(func(a, b): return a.progress < b.progress)
	_refresh_keyframe_list()
	print("✅ Captured KF at %.2f for '%s' (%d joints)" % [progress, current_move, pose.size()])


func _delete_selected_keyframe() -> void:
	if current_move == "" or not kf_data.has(current_move):
		return
	var selected = keyframe_list.get_selected_items()
	if selected.is_empty():
		return
	kf_data[current_move].remove_at(selected[0])
	_refresh_keyframe_list()


func _on_keyframe_selected(idx: int) -> void:
	if current_move == "" or not kf_data.has(current_move):
		return
	if idx >= kf_data[current_move].size():
		return
	var kf = kf_data[current_move][idx]
	# Load into sliders
	for key in sliders:
		sliders[key].value = 0
	var ro = kf.get("root_offset", Vector3(0, kf.get("root_y", 0), 0))
	if root_offset_sliders.has("root_x"): root_offset_sliders["root_x"].value = ro.x
	if root_offset_sliders.has("root_y"): root_offset_sliders["root_y"].value = ro.y
	if root_offset_sliders.has("root_z"): root_offset_sliders["root_z"].value = ro.z
	for jname in kf.pose:
		var v = kf.pose[jname]
		if sliders.has(jname + "_x"): sliders[jname + "_x"].value = v.x
		if sliders.has(jname + "_y"): sliders[jname + "_y"].value = v.y
		if sliders.has(jname + "_z"): sliders[jname + "_z"].value = v.z
	_apply_pose()
	progress_slider.value = kf.progress


func _refresh_keyframe_list() -> void:
	keyframe_list.clear()
	if current_move == "" or not kf_data.has(current_move):
		return
	for kf in kf_data[current_move]:
		var ro = kf.get("root_offset", Vector3(0, kf.get("root_y", 0), 0))
		keyframe_list.add_item("⏱ %.2f  (%d joints, root=%.1f,%.1f,%.1f)" % [kf.progress, kf.pose.size(), ro.x, ro.y, ro.z])


func _toggle_preview() -> void:
	is_previewing = !is_previewing
	if is_previewing:
		preview_time = 0.0
		preview_btn.text = "⏹ Stop"
	else:
		preview_btn.text = "▶ Preview"


func _interpolate_kfs(kfs: Array, progress: float) -> Dictionary:
	if kfs.is_empty():
		return {}
	var prev_kf = kfs[0]
	var next_kf = kfs[kfs.size() - 1]
	for i in range(kfs.size()):
		if kfs[i].progress <= progress:
			prev_kf = kfs[i]
		if kfs[i].progress >= progress:
			next_kf = kfs[i]
			break
	var prev_ro = prev_kf.get("root_offset", Vector3(0, prev_kf.get("root_y", 0), 0))
	var next_ro = next_kf.get("root_offset", Vector3(0, next_kf.get("root_y", 0), 0))
	if prev_kf.progress == next_kf.progress:
		return {"pose": prev_kf.pose, "root_offset": prev_ro}
	var t = clampf((progress - prev_kf.progress) / (next_kf.progress - prev_kf.progress), 0.0, 1.0)
	var result_pose = {}
	var all_j = {}
	for j in prev_kf.pose: all_j[j] = true
	for j in next_kf.pose: all_j[j] = true
	for j in all_j:
		result_pose[j] = prev_kf.pose.get(j, Vector3.ZERO).lerp(next_kf.pose.get(j, Vector3.ZERO), t)
	return {"pose": result_pose, "root_offset": prev_ro.lerp(next_ro, t)}


func _generate_move_code() -> void:
	if current_move == "" or not kf_data.has(current_move) or kf_data[current_move].is_empty():
		print("⚠ No keyframes for '%s'" % current_move)
		return
	var kfs = kf_data[current_move]
	print("\n# ====== GENERATED: set_pose_%s ======" % current_move)
	print("func set_pose_%s(progress: float) -> void:" % current_move)
	print("\tidle_bob_active = false")
	print("\tblend_speed = 25.0")

	if kfs.size() == 1:
		print("\tvar p = sin(progress * PI)")
		print("\t_set_pose({")
		for j in kfs[0].pose:
			var v = kfs[0].pose[j]
			print('\t\t"%s": Vector3(%d, %d, %d),' % [j, int(v.x), int(v.y), int(v.z)])
		var ry = kfs[0].root_y
		if abs(ry) > 0.005:
			print("\t}, Vector3(0, p * %.2f, 0))" % ry)
		else:
			print("\t})")
	else:
		# Multi-keyframe: generate phase variables
		for i in range(kfs.size()):
			print("\t# KF%d: progress=%.2f (%d joints)" % [i, kfs[i].progress, kfs[i].pose.size()])

		# For each phase transition
		for i in range(1, kfs.size()):
			var p0 = kfs[i-1].progress
			var p1 = kfs[i].progress
			var dur = p1 - p0
			if dur <= 0: dur = 0.01
			print("\tvar phase%d = clampf((progress - %.3f) / %.3f, 0.0, 1.0)" % [i, p0, dur])

		# Build the blended pose
		print("\t# Blend keyframes")
		var all_joints = {}
		for kf in kfs:
			for j in kf.pose: all_joints[j] = true

		print("\tvar pose = {}")
		for j in all_joints:
			var vals = []
			for kf in kfs:
				vals.append(kf.pose.get(j, Vector3.ZERO))
			# Chain lerps
			if kfs.size() == 2:
				print('\tpose["%s"] = Vector3(%d,%d,%d).lerp(Vector3(%d,%d,%d), phase1)' % [
					j, int(vals[0].x), int(vals[0].y), int(vals[0].z),
					int(vals[1].x), int(vals[1].y), int(vals[1].z)])
			elif kfs.size() == 3:
				print('\tpose["%s"] = Vector3(%d,%d,%d).lerp(Vector3(%d,%d,%d), phase1).lerp(Vector3(%d,%d,%d), phase2)' % [
					j, int(vals[0].x), int(vals[0].y), int(vals[0].z),
					int(vals[1].x), int(vals[1].y), int(vals[1].z),
					int(vals[2].x), int(vals[2].y), int(vals[2].z)])
			else:
				# For 4+ keyframes just output the values as comments
				print('\t# %s: %s' % [j, str(vals)])
				print('\tpose["%s"] = Vector3(%d,%d,%d)' % [j, int(vals[0].x), int(vals[0].y), int(vals[0].z)])

		# Root Y
		var ry_vals = []
		for kf in kfs: ry_vals.append(kf.root_y)
		var has_root = false
		for ry in ry_vals:
			if abs(ry) > 0.005: has_root = true

		if has_root:
			if kfs.size() == 2:
				print("\tvar ry = lerpf(%.2f, %.2f, phase1)" % [ry_vals[0], ry_vals[1]])
			elif kfs.size() == 3:
				print("\tvar ry = lerpf(lerpf(%.2f, %.2f, phase1), %.2f, phase2)" % [ry_vals[0], ry_vals[1], ry_vals[2]])
			print("\t_set_pose(pose, Vector3(0, ry, 0))")
		else:
			print("\t_set_pose(pose)")

	print("# ====== END %s ======\n" % current_move)


func _generate_all_code() -> void:
	for move_name in kf_data:
		if kf_data[move_name].size() > 0:
			var saved_move = current_move
			current_move = move_name
			_generate_move_code()
			current_move = saved_move


func _get_selected_preset_move() -> String:
	# Get the move name from the preset dropdown
	if preset_dropdown == null:
		return ""
	var idx = preset_dropdown.selected
	var text = preset_dropdown.get_item_text(idx)
	# Check if it's a base preset
	if text in ["T-Pose", "Fight Stance", "Crouch"]:
		return text
	return text


func _load_preset_at_progress(progress_val: float) -> void:
	var move_name = _get_selected_preset_move()
	if move_name in ["T-Pose", "Fight Stance", "Crouch"]:
		_load_preset(move_name)
		return
	if move_name == "":
		print("⚠ Select a move from the preset dropdown!")
		return
	_load_move_pose_at(move_name, progress_val)


func _load_preset_at_impact() -> void:
	var move_name = _get_selected_preset_move()
	if move_name in ["T-Pose", "Fight Stance", "Crouch"]:
		_load_preset(move_name)
		return
	if move_name == "":
		print("⚠ Select a move from the preset dropdown!")
		return
	var impact = MOVE_IMPACT_PROGRESS.get(move_name, 0.5)
	_load_move_pose_at(move_name, impact)


func _load_move_pose() -> void:
	# Load from preset dropdown at current timeline progress
	var move_name = _get_selected_preset_move()
	if move_name in ["T-Pose", "Fight Stance", "Crouch"]:
		_load_preset(move_name)
		return
	if move_name == "":
		# Fall back to batch move dropdown
		move_name = current_move
	if move_name == "":
		print("⚠ Select a move first!")
		return
	var progress_val = progress_slider.value if progress_slider else 0.0
	_load_move_pose_at(move_name, progress_val)


func _load_move_pose_at(move_name: String, progress_val: float) -> void:
	# Call the move's set_pose_* function at the given progress,
	# then read joint rotations back into sliders.
	var func_name = MOVE_POSE_FUNC.get(move_name, "set_pose_" + move_name)

	# The model node is the fighter_model.gd script — call the pose function
	if not model.has_method(func_name):
		print("⚠ Model has no method: %s" % func_name)
		return

	# Temporarily enable the model's own pose application
	model.editor_active = false
	if func_name == "set_pose_fight_stance" or func_name == "set_pose_crouch" or func_name == "set_pose_knockdown":
		model.call(func_name)
	else:
		model.call(func_name, progress_val)

	# Force immediate blend (snap to target)
	for path in model.target_rot:
		if model.joints.has(path):
			model.joints[path].rotation_degrees = model.rest_rotations.get(path, Vector3.ZERO) + model.target_rot[path]
	model.root_node.position = model.root_rest_pos + model.current_root_offset

	# Now read the resulting joint rotations back into sliders
	for key in sliders:
		sliders[key].value = 0

	for jname in J:
		if not joints.has(jname):
			continue
		var current_rot = joints[jname].rotation_degrees
		var rest_rot = rest_rotations.get(jname, Vector3.ZERO)
		var offset = current_rot - rest_rot
		if sliders.has(jname + "_x"): sliders[jname + "_x"].value = snapped(offset.x, 1.0)
		if sliders.has(jname + "_y"): sliders[jname + "_y"].value = snapped(offset.y, 1.0)
		if sliders.has(jname + "_z"): sliders[jname + "_z"].value = snapped(offset.z, 1.0)

	# Read root offset
	var root_off = root_node.position - root_rest_pos
	if root_offset_sliders.has("root_x"): root_offset_sliders["root_x"].value = snapped(root_off.x, 0.01)
	if root_offset_sliders.has("root_y"): root_offset_sliders["root_y"].value = snapped(root_off.y, 0.01)
	if root_offset_sliders.has("root_z"): root_offset_sliders["root_z"].value = snapped(root_off.z, 0.01)

	model.editor_active = true
	print("✅ Loaded '%s' at progress %.2f into sliders" % [move_name, progress_val])


func _save_keyframes_to_disk() -> void:
	# Serialize all keyframe data to JSON
	var save_data = {}
	for move_name in kf_data:
		var kfs = []
		for kf in kf_data[move_name]:
			var kf_dict = {"progress": kf.progress}
			var pose_dict = {}
			for jname in kf.pose:
				var v = kf.pose[jname]
				pose_dict[jname] = [v.x, v.y, v.z]
			kf_dict["pose"] = pose_dict
			var ro = kf.get("root_offset", Vector3(0, kf.get("root_y", 0), 0))
			kf_dict["root_offset"] = [ro.x, ro.y, ro.z]
			kfs.append(kf_dict)
		save_data[move_name] = kfs

	var file = FileAccess.open(KF_SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(save_data, "\t"))
		file.close()
		print("✅ Keyframes saved to %s (%d moves)" % [KF_SAVE_PATH, save_data.size()])
	else:
		print("⚠ Failed to save keyframes")


func _load_keyframes_from_disk() -> void:
	if not FileAccess.file_exists(KF_SAVE_PATH):
		print("⚠ No saved keyframes found at %s" % KF_SAVE_PATH)
		return

	var file = FileAccess.open(KF_SAVE_PATH, FileAccess.READ)
	if not file:
		print("⚠ Failed to open keyframe file")
		return

	var json = JSON.new()
	var err = json.parse(file.get_as_text())
	file.close()
	if err != OK:
		print("⚠ Failed to parse keyframe JSON")
		return

	kf_data.clear()
	var data = json.data
	for move_name in data:
		kf_data[move_name] = []
		for kf_dict in data[move_name]:
			var pose = {}
			for jname in kf_dict.get("pose", {}):
				var arr = kf_dict["pose"][jname]
				pose[jname] = Vector3(arr[0], arr[1], arr[2])
			var ro_arr = kf_dict.get("root_offset", [0, 0, 0])
			var ro = Vector3(ro_arr[0], ro_arr[1], ro_arr[2])
			kf_data[move_name].append({
				"progress": kf_dict.get("progress", 0.0),
				"pose": pose,
				"root_offset": ro,
			})

	_refresh_keyframe_list()
	print("✅ Loaded keyframes from %s (%d moves)" % [KF_SAVE_PATH, kf_data.size()])


func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _input(event: InputEvent) -> void:
	# ESC to go back
	if InputManager.is_back_event(event):
		_go_back()

	# Camera orbit with right mouse
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			is_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = max(1.5, cam_distance - 0.3)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = min(8.0, cam_distance + 0.3)
			_update_camera()

	if event is InputEventMouseMotion and is_orbiting:
		cam_yaw -= event.relative.x * 0.3
		cam_pitch = clampf(cam_pitch - event.relative.y * 0.3, -60, 80)
		_update_camera()


func _update_camera() -> void:
	var yaw_rad = deg_to_rad(cam_yaw)
	var pitch_rad = deg_to_rad(cam_pitch)
	var offset = Vector3(
		sin(yaw_rad) * cos(pitch_rad) * cam_distance,
		sin(pitch_rad) * cam_distance,
		cos(yaw_rad) * cos(pitch_rad) * cam_distance
	)
	cam.global_position = cam_target + offset
	cam.look_at(cam_target)
