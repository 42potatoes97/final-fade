class_name FighterModel
extends Node3D

# Joint-based pose system. Godot rotation order: YXZ
# Model is flipped 180 in fighter.tscn
# L/R mapping is swapped in J dict to match viewer perspective
#
# Pose values were tuned with the in-game pose editor (F2)

var joints: Dictionary = {}
var rest_rotations: Dictionary = {}
var current_rot: Dictionary = {}
var target_rot: Dictionary = {}
var blend_speed: float = 15.0

var root_node: Node3D
var root_rest_pos: Vector3
var current_root_offset: Vector3 = Vector3.ZERO
var target_root_offset: Vector3 = Vector3.ZERO

var idle_timer: float = 0.0
var idle_bob_active: bool = true
var editor_active: bool = false
var _cached_stance_pose: Dictionary = {}

const JOINT_NAMES = [
	"Root", "Root/Abdomen", "Root/Abdomen/Torso", "Root/Abdomen/Torso/Head",
	"Root/Abdomen/Torso/ShoulderL/UpperArmL", "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL",
	"Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL/HandL",
	"Root/Abdomen/Torso/ShoulderR/UpperArmR", "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR",
	"Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR/HandR",
	"Root/HipL/UpperLegL", "Root/HipL/UpperLegL/LowerLegL",
	"Root/HipL/UpperLegL/LowerLegL/FootL",
	"Root/HipR/UpperLegR", "Root/HipR/UpperLegR/LowerLegR",
	"Root/HipR/UpperLegR/LowerLegR/FootR",
]

# No swap: L=SceneL (viewer RIGHT due to 180 flip), R=SceneR (viewer LEFT)
# Hierarchy: Root -> Abdomen -> Torso (abdomen = waist pivot, torso = chest)
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

# Fight stance base values (from pose editor, remapped: editor arm_l was ShoulderR)
# arm_l = ShoulderL = viewer RIGHT, arm_r = ShoulderR = viewer LEFT
const STANCE_ARM_L = Vector3(-54, 5, 73)
const STANCE_FARM_L = Vector3(-4, 92, 51)
const STANCE_ARM_R = Vector3(-62, -12, -73)
const STANCE_FARM_R = Vector3(-12, -66, 0)
const STANCE_LEG_L = Vector3(5, -16, 0)
const STANCE_SHIN_L = Vector3(32, 4, -6)
const STANCE_LEG_R = Vector3(-36, -3, 0)
const STANCE_SHIN_R = Vector3(34, 0, 0)


func _ready() -> void:
	root_node = get_node("Root")
	root_rest_pos = root_node.position
	for path in JOINT_NAMES:
		if has_node(path):
			joints[path] = get_node(path)
			rest_rotations[path] = joints[path].rotation_degrees
			current_rot[path] = Vector3.ZERO
			target_rot[path] = Vector3.ZERO
	set_pose_fight_stance()


func _physics_process(delta: float) -> void:
	if editor_active:
		return
	for path in joints:
		current_rot[path] = current_rot[path].lerp(target_rot[path], blend_speed * delta)
		joints[path].rotation_degrees = rest_rotations[path] + current_rot[path]
	current_root_offset = current_root_offset.lerp(target_root_offset, blend_speed * delta)
	root_node.position = root_rest_pos + current_root_offset
	if idle_bob_active:
		idle_timer += delta
		# Breathing/bounce — slight vertical bob
		root_node.position.y += sin(idle_timer * 2.8) * 0.008
		# Subtle weight shift — knees bend slightly on rhythm
		var breath = sin(idle_timer * 2.8)
		var sway = sin(idle_timer * 1.4) * 0.3
		# Apply subtle rotation to torso and arms for life-like idle
		for path in joints:
			if path.ends_with("Torso"):
				joints[path].rotation_degrees.z += sway
			elif path.ends_with("UpperArmL") or path.ends_with("UpperArmR"):
				joints[path].rotation_degrees.x += breath * 1.5
	# Floor constraint — prevent feet from going below ground
	_apply_floor_constraint()


func _apply_floor_constraint() -> void:
	# Get the fighter's global Y (CharacterBody3D position)
	var fighter_node = get_parent()
	if fighter_node == null or not (fighter_node is Node3D):
		return
	var fighter_y = fighter_node.global_position.y

	# Check both feet's global position
	var foot_l_path = J.get("foot_l", "")
	var foot_r_path = J.get("foot_r", "")
	var lowest_foot_y = 999.0

	for fp in [foot_l_path, foot_r_path]:
		if fp != "" and has_node(fp):
			var foot = get_node(fp)
			var foot_global_y = foot.global_position.y
			# Foot mesh hangs below the joint, account for foot height (~0.06)
			var foot_bottom = foot_global_y - 0.06
			lowest_foot_y = min(lowest_foot_y, foot_bottom)

	# If lowest foot is below the floor plane (fighter's ground level)
	# Floor is at the fighter's Y position (CharacterBody3D sits on floor)
	var floor_y = fighter_y
	if lowest_foot_y < floor_y - 0.02:  # Small threshold
		var correction = floor_y - lowest_foot_y
		root_node.position.y += correction


func _lerp_pose(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	# Blend between two pose dictionaries
	var result = {}
	# Get all keys from both poses
	var keys = {}
	for k in a:
		keys[k] = true
	for k in b:
		keys[k] = true
	for k in keys:
		var va = a.get(k, Vector3.ZERO)
		var vb = b.get(k, Vector3.ZERO)
		result[k] = va.lerp(vb, t)
	return result


func _set_pose(pose: Dictionary, root_offset: Vector3 = Vector3.ZERO) -> void:
	for path in target_rot:
		target_rot[path] = Vector3.ZERO
	target_root_offset = root_offset
	for key in pose:
		var path = J[key] if J.has(key) else key
		if target_rot.has(path):
			target_rot[path] = pose[key]


func _lerp_poses(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var result = a.duplicate()
	for key in b:
		if a.has(key):
			result[key] = a[key].lerp(b[key], t)
		else:
			result[key] = b[key] * t
	return result


# ============================================================
# FIGHT STANCE (from pose editor)
# ============================================================
func _get_stance_pose() -> Dictionary:
	if _cached_stance_pose.is_empty():
		_cached_stance_pose = {
			"abdomen": Vector3(0, -38, 0),
			"torso": Vector3(2, 0, 0), "head": Vector3(0, 13, -1),
			"arm_l": STANCE_ARM_L, "forearm_l": STANCE_FARM_L,
			"arm_r": STANCE_ARM_R, "forearm_r": STANCE_FARM_R,
			"leg_l": STANCE_LEG_L, "shin_l": STANCE_SHIN_L,
			"foot_l": Vector3(-22, -51, 32),
			"leg_r": STANCE_LEG_R, "shin_r": STANCE_SHIN_R,
			"foot_r": Vector3(-1, 0, 0),
		}
	return _cached_stance_pose


func set_pose_fight_stance() -> void:
	idle_bob_active = true
	blend_speed = 25.0  # Snappy stance transitions (was 15)
	_set_pose({
		"abdomen": Vector3(0, -38, 0),
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, 13, -1),
		"arm_l": Vector3(-54, 5, 73),
		"forearm_l": Vector3(-4, 92, 51),
		"arm_r": Vector3(-62, -12, -73),
		"forearm_r": Vector3(-12, -66, 0),
		"leg_l": Vector3(5, -16, 0),
		"shin_l": Vector3(32, 4, -6),
		"foot_l": Vector3(-22, -51, 32),
		"leg_r": Vector3(-36, -3, 0),
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	})


# ============================================================
# MOVEMENT
# ============================================================
func set_pose_walk_forward(phase: float) -> void:
	idle_bob_active = false
	blend_speed = 27.0
	var s = sin(phase)
	var c = cos(phase)

	# Vertical bounce — peaks at foot contact, dips at mid-stride
	var bounce = abs(c) * 0.025 - 0.01

	# Hip/abdomen twist — drives the walk, counter to shoulders
	var hip_twist = s * 6

	# Torso lean and counter-twist
	var torso_lean = 5  # Slight forward lean
	var torso_twist = -s * 4  # Counter-rotate to hips

	# Leg stride — alternating, one forward one back
	var stride_l = -s * 30  # Left leg: negative = forward when s > 0
	var stride_r = s * 30   # Right leg: opposite phase
	# Knee bend — back leg bends more (pushing off), front leg straighter
	var knee_l = max(0, s) * 30   # Bends when leg is behind
	var knee_r = max(0, -s) * 30  # Bends when leg is behind

	# Arm counter-swing — opposite to same-side leg
	var arm_swing_l = s * 18   # Swings forward when left leg goes back
	var arm_swing_r = -s * 18  # Opposite

	# Shoulder dip — leading shoulder drops slightly
	var shoulder_dip = s * 3

	_set_pose({
		"abdomen": Vector3(3, hip_twist, 0),
		"torso": Vector3(torso_lean, torso_twist, shoulder_dip),
		"head": Vector3(-torso_lean + 2, 0, -1),
		"arm_l": STANCE_ARM_L + Vector3(arm_swing_l, 0, 0),
		"forearm_l": STANCE_FARM_L + Vector3(max(0, arm_swing_l) * 0.8, 0, 0),
		"arm_r": STANCE_ARM_R + Vector3(arm_swing_r, 0, 0),
		"forearm_r": STANCE_FARM_R + Vector3(max(0, -arm_swing_r) * 0.8, 0, 0),
		"leg_l": STANCE_LEG_L + Vector3(stride_l, 0, 0),
		"shin_l": STANCE_SHIN_L + Vector3(knee_l, 0, 0),
		"leg_r": STANCE_LEG_R + Vector3(stride_r, 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(knee_r, 0, 0),
	}, Vector3(0, bounce, 0))


func set_pose_walk_backward(phase: float) -> void:
	idle_bob_active = false
	blend_speed = 27.0
	var s = sin(phase)
	var c = cos(phase)

	# Backward walk — more guarded, smaller stride, leaning back slightly
	var bounce = abs(c) * 0.018 - 0.008
	var hip_twist = s * 4
	var torso_twist = -s * 3

	# Smaller stride than forward walk
	var stride_l = s * 22
	var stride_r = -s * 22
	var knee_l = max(0, -s) * 22  # Front leg bends when stepping back
	var knee_r = max(0, s) * 22

	# Arms stay tighter in guard, less swing
	var arm_swing_l = -s * 10
	var arm_swing_r = s * 10

	_set_pose({
		"abdomen": Vector3(-2, hip_twist, 0),
		"torso": Vector3(-3, torso_twist, 0),  # Slight backward lean
		"head": Vector3(3, 0, -1),
		"arm_l": STANCE_ARM_L + Vector3(arm_swing_l, 0, 0),
		"forearm_l": STANCE_FARM_L + Vector3(max(0, -arm_swing_l) * 0.5, 0, 0),
		"arm_r": STANCE_ARM_R + Vector3(arm_swing_r, 0, 0),
		"forearm_r": STANCE_FARM_R + Vector3(max(0, arm_swing_r) * 0.5, 0, 0),
		"leg_l": STANCE_LEG_L + Vector3(stride_l, 0, 0),
		"shin_l": STANCE_SHIN_L + Vector3(knee_l, 0, 0),
		"leg_r": STANCE_LEG_R + Vector3(stride_r, 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(knee_r, 0, 0),
	}, Vector3(0, bounce, 0))


func set_pose_dash_forward(progress: float) -> void:
	idle_bob_active = false
	blend_speed = 27.0

	# Three phases: launch (lean in), run (legs churn), settle (return to stance)
	var launch = clampf(progress / 0.25, 0.0, 1.0)
	var run_phase = clampf((progress - 0.1) / 0.6, 0.0, 1.0)
	var settle = clampf((progress - 0.7) / 0.3, 0.0, 1.0)

	var l = sin(launch * PI * 0.5)
	var r = sin(run_phase * PI * 2.5)  # Fast leg churn
	var e = sin(settle * PI * 0.5)

	# Strong forward lean on launch, gradually upright
	var lean = l * 22 * (1.0 - e * 0.7)
	# Landing dip
	var bounce = -l * 0.04 * (1.0 - e) + e * 0.01

	# Running legs — fast alternation during middle
	var run_intensity = sin(run_phase * PI)  # Peak at middle of dash
	var leg_stride = r * 35 * run_intensity * (1.0 - e)
	var knee_l_b = max(0, r) * 30 * run_intensity * (1.0 - e)
	var knee_r_b = max(0, -r) * 30 * run_intensity * (1.0 - e)

	# Arms pump opposite to legs
	var arm_pump = r * 20 * run_intensity * (1.0 - e)

	_set_pose({
		"abdomen": Vector3(l * 8 * (1.0 - e), 0, 0),
		"torso": Vector3(lean, r * 4 * run_intensity * (1.0 - e), 0),
		"head": Vector3(-lean * 0.5, 0, -1),
		"arm_l": STANCE_ARM_L + Vector3(arm_pump * (1.0 - e), l * 12 * (1.0 - e), 0),
		"forearm_l": STANCE_FARM_L + Vector3(max(0, arm_pump) * 0.6 * (1.0 - e), 0, 0),
		"arm_r": STANCE_ARM_R + Vector3(-arm_pump * (1.0 - e), -l * 12 * (1.0 - e), 0),
		"forearm_r": STANCE_FARM_R + Vector3(max(0, -arm_pump) * 0.6 * (1.0 - e), 0, 0),
		"leg_l": STANCE_LEG_L + Vector3(-leg_stride - l * 15 * (1.0 - e), 0, 0),
		"shin_l": STANCE_SHIN_L + Vector3(knee_l_b, 0, 0),
		"leg_r": STANCE_LEG_R + Vector3(leg_stride + l * 5 * (1.0 - e), 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(knee_r_b, 0, 0),
	}, Vector3(0, bounce, 0))


func set_pose_backdash(progress: float) -> void:
	idle_bob_active = false
	blend_speed = 27.0

	# Three phases: launch (0-0.3), peak/airborne (0.3-0.6), land (0.6-1.0)
	var launch = clampf(progress / 0.3, 0.0, 1.0)
	var peak = clampf((progress - 0.3) / 0.3, 0.0, 1.0)
	var land = clampf((progress - 0.6) / 0.4, 0.0, 1.0)

	var t_launch = sin(launch * PI * 0.5)
	var t_land = sin(land * PI * 0.5)

	# Slight bounce arc — up during dash, back down on land
	var root_y = 0.08 * sin(clampf(progress / 0.85, 0.0, 1.0) * PI)

	# Pose: lerp from stance to peak pose, then back to stance
	# Peak pose (your editor output at 0.6):
	var peak_pose = {
		"abdomen": Vector3(0, 1, 0),
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, -2, -1),
		"arm_l": Vector3(-58, 20, 73),
		"forearm_l": Vector3(-11, 79, -1),
		"arm_r": Vector3(-81, -32, -74),
		"forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(8, -1, -1),
		"shin_l": Vector3(14, 13, -6),
		"foot_l": Vector3(0, -1, 0),
		"leg_r": Vector3(-21, -1, 0),
		"shin_r": Vector3(19, 1, 0),
		"foot_r": Vector3(-1, 0, 0),
	}

	# Blend: stance → peak during launch, peak → stance during land
	var blend_in = t_launch * (1.0 - t_land)  # Ramps up then back down
	var pose = {}
	var stance = {
		"abdomen": Vector3(0, 0, 0),
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": STANCE_ARM_L, "forearm_l": STANCE_FARM_L,
		"arm_r": STANCE_ARM_R, "forearm_r": STANCE_FARM_R,
		"leg_l": STANCE_LEG_L, "shin_l": STANCE_SHIN_L, "foot_l": Vector3(0, 0, 0),
		"leg_r": STANCE_LEG_R, "shin_r": STANCE_SHIN_R, "foot_r": Vector3(-1, 0, 0),
	}

	for j in peak_pose:
		var s = stance.get(j, Vector3.ZERO)
		pose[j] = s.lerp(peak_pose[j], blend_in)

	_set_pose(pose, Vector3(0, root_y, 0))


func set_pose_sidestep(direction: float) -> void:
	idle_bob_active = false
	blend_speed = 21.0
	var d = direction
	_set_pose({
		"torso": Vector3(2, 0, d * 12),
		"head": Vector3(0, -1, -d * 6),
		"arm_l": STANCE_ARM_L,
		"forearm_l": STANCE_FARM_L,
		"arm_r": STANCE_ARM_R,
		"forearm_r": STANCE_FARM_R,
		"leg_l": STANCE_LEG_L + Vector3(d * 10, d * 12, 0),
		"shin_l": STANCE_SHIN_L,
		"leg_r": STANCE_LEG_R + Vector3(d * 10, d * 12, 0),
		"shin_r": STANCE_SHIN_R,
	})


func set_pose_crouch() -> void:
	# From pose editor — proper squat with guard up
	idle_bob_active = false
	blend_speed = 45.0  # Snap to crouch fast
	_set_pose({
		"abdomen": Vector3(5, 0, 0),
		"arm_l": Vector3(-52, 20, 73),
		"forearm_l": Vector3(-3, 110, -1),
		"arm_r": Vector3(-65, -21, -73),
		"forearm_r": Vector3(5, -109, -1),
		"torso": Vector3(37, 0, 0),
		"head": Vector3(0, -1, -1),
		"leg_l": Vector3(-42, 0, 0),
		"shin_l": Vector3(112, 13, -6),
		"foot_l": Vector3(-26, 13, 0),
		"leg_r": Vector3(-80, -1, 0),
		"shin_r": Vector3(78, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}, Vector3(0, -0.18, 0))


func set_pose_crouch_dash(progress: float) -> void:
	# Wavedash — crouch pose with aggressive forward lean
	idle_bob_active = false
	blend_speed = 40.0  # Fast transition
	var lean = sin(progress * PI) * 20
	_set_pose({
		"abdomen": Vector3(5 + lean, 0, 0),
		"arm_l": Vector3(-52, 20, 73),
		"forearm_l": Vector3(-3, 110, -1),
		"arm_r": Vector3(-65, -21, -73),
		"forearm_r": Vector3(5, -109, -1),
		"torso": Vector3(37 + lean * 0.5, 0, 0),
		"head": Vector3(-lean * 0.3, -1, -1),
		"leg_l": Vector3(-42, 0, 0),
		"shin_l": Vector3(112, 13, -6),
		"foot_l": Vector3(-26, 13, 0),
		"leg_r": Vector3(-80, -1, 0),
		"shin_r": Vector3(78, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}, Vector3(0, -0.18, 0))


func set_pose_hop(progress: float) -> void:
	idle_bob_active = false
	blend_speed = 27.0
	var tuck = sin(progress * PI)
	_set_pose({
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": STANCE_ARM_L,
		"forearm_l": STANCE_FARM_L,
		"arm_r": STANCE_ARM_R,
		"forearm_r": STANCE_FARM_R,
		"leg_l": STANCE_LEG_L + Vector3(-tuck * 30, 0, 0),
		"shin_l": STANCE_SHIN_L + Vector3(tuck * 25, 0, 0),
		"leg_r": STANCE_LEG_R + Vector3(-tuck * 25, 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(tuck * 20, 0, 0),
	})


func set_pose_backsway(progress: float) -> void:
	# Deep lean-back sway: stance → lean → deep → post-impact → stance
	idle_bob_active = false
	blend_speed = 45.0

	# Phase transitions
	var phase1 = clampf(progress / 0.3, 0.0, 1.0)              # 0→0.3: lean back
	var phase2 = clampf((progress - 0.3) / 0.3, 0.0, 1.0)      # 0.3→0.6: deep sway
	var phase3 = clampf((progress - 0.6) / 0.2, 0.0, 1.0)      # 0.6→0.8: post-impact
	var phase4 = clampf((progress - 0.8) / 0.2, 0.0, 1.0)      # 0.8→1.0: return to stance

	# Keyframe poses
	var kf_stance = {
		"abdomen": Vector3(0, 0, 0), "torso": Vector3(2, 0, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": STANCE_ARM_L, "forearm_l": STANCE_FARM_L,
		"arm_r": STANCE_ARM_R, "forearm_r": STANCE_FARM_R,
		"leg_l": STANCE_LEG_L, "shin_l": STANCE_SHIN_L, "foot_l": Vector3(0, 0, 0),
		"leg_r": STANCE_LEG_R, "shin_r": STANCE_SHIN_R, "foot_r": Vector3(-1, 0, 0),
	}
	var kf_lean = {
		"abdomen": Vector3(-25, 0, 0), "torso": Vector3(0, -16, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": Vector3(-76, 20, 73), "forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-81, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(2, 0, 0), "shin_l": Vector3(67, 13, -6), "foot_l": Vector3(0, 0, 0),
		"leg_r": Vector3(-50, -1, 0), "shin_r": Vector3(41, 0, 0), "foot_r": Vector3(-1, 0, 0),
	}
	var kf_deep = {
		"abdomen": Vector3(-50, 0, 0), "torso": Vector3(0, -16, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": Vector3(-76, 20, 73), "forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-81, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-41, 0, 0), "shin_l": Vector3(110, 13, -6), "foot_l": Vector3(-13, 0, 0),
		"leg_r": Vector3(-66, -1, 0), "shin_r": Vector3(58, 0, 0), "foot_r": Vector3(-1, 0, 0),
	}
	var kf_post = {
		"abdomen": Vector3(-30, 0, 0), "torso": Vector3(0, -16, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": Vector3(-76, 20, 73), "forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-81, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-41, 0, 0), "shin_l": Vector3(78, 13, -6), "foot_l": Vector3(-13, 0, 0),
		"leg_r": Vector3(-58, -1, 0), "shin_r": Vector3(40, 0, 0), "foot_r": Vector3(-1, 0, 0),
	}

	# Root Y offsets: 0 → -0.04 → -0.15 → -0.07 → 0
	var ry = lerpf(0.0, -0.04, phase1)
	ry = lerpf(ry, -0.15, phase2)
	ry = lerpf(ry, -0.07, phase3)
	ry = lerpf(ry, 0.0, phase4)

	# Blend poses through phases
	var pose = {}
	for j in kf_deep:
		var v = kf_stance.get(j, Vector3.ZERO)
		v = v.lerp(kf_lean.get(j, Vector3.ZERO), phase1)
		v = v.lerp(kf_deep.get(j, Vector3.ZERO), phase2)
		v = v.lerp(kf_post.get(j, Vector3.ZERO), phase3)
		v = v.lerp(kf_stance.get(j, Vector3.ZERO), phase4)
		pose[j] = v

	_set_pose(pose, Vector3(0, ry, 0))


# ============================================================
# ATTACKS
# ============================================================
func set_pose_jab(progress: float) -> void:
	# Jab — from pose editor
	idle_bob_active = false
	blend_speed = 45.0
	var extend = clampf(progress / 0.5, 0.0, 1.0)
	var retract = clampf((progress - 0.6) / 0.4, 0.0, 1.0)
	var p = sin(extend * PI * 0.5) * (1.0 - retract)
	var jab_end = {
		"abdomen": Vector3(8, -13, 0),
		"arm_l": Vector3(-23, 20, 73),
		"forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-89, 0, -73),
		"forearm_r": Vector3(8, -18, 0),
		"torso": Vector3(-8, -16, 0),
		"head": Vector3(0, -1, -1),
		"leg_l": Vector3(-8, 0, 0),
		"shin_l": Vector3(34, 13, -6),
		"foot_l": Vector3(8, 0, 0),
		"leg_r": Vector3(-29, -1, 0),
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var stance = _get_stance_pose()
	var pose = {}
	for key in jab_end:
		pose[key] = stance.get(key, Vector3.ZERO).lerp(jab_end[key], p)
	_set_pose(pose, Vector3(0, p * 0.05, 0))


func set_pose_jab_2(progress: float) -> void:
	# Second jab (1,1) — other hand, from pose editor
	idle_bob_active = false
	blend_speed = 45.0
	var extend = clampf(progress / 0.5, 0.0, 1.0)
	var retract = clampf((progress - 0.6) / 0.4, 0.0, 1.0)
	var p = sin(extend * PI * 0.5) * (1.0 - retract)
	var jab2_end = {
		"root": Vector3(0, 3, 0),
		"abdomen": Vector3(15, -10, 0),
		"arm_l": Vector3(-99, -3, 73),
		"forearm_l": Vector3(-10, 23, -1),
		"arm_r": Vector3(-26, -44, -73),
		"forearm_r": Vector3(-10, -66, 0),
		"torso": Vector3(-8, 39, 0),
		"head": Vector3(0, -1, -1),
		"leg_l": Vector3(-5, 0, 0),
		"shin_l": Vector3(34, 13, -6),
		"foot_l": Vector3(-1, 0, 0),
		"leg_r": Vector3(-34, -1, 0),
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var stance = _get_stance_pose()
	var pose = {}
	for key in jab2_end:
		pose[key] = stance.get(key, Vector3.ZERO).lerp(jab2_end[key], p)
	_set_pose(pose, Vector3(0, p * 0.04, 0))


func set_pose_power_straight(progress: float) -> void:
	# 1,1,1 finisher — powerful straight from pose editor
	idle_bob_active = false
	blend_speed = 38.0
	var windup = clampf(progress / 0.3, 0.0, 1.0)
	var strike = clampf((progress - 0.3) / 0.3, 0.0, 1.0)
	var recover = clampf((progress - 0.65) / 0.35, 0.0, 1.0)
	var w = sin(windup * PI * 0.5)
	var s = sin(strike * PI * 0.5)
	var r = sin(recover * PI * 0.5)
	var power_end = {
		"abdomen": Vector3(8, -13, 0),
		"arm_l": Vector3(-23, 20, 73),
		"forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-89, 23, -75),
		"forearm_r": Vector3(-7, -13, -45),
		"torso": Vector3(-8, -26, 0),
		"head": Vector3(0, -1, -1),
		"leg_l": Vector3(-8, 0, 0),
		"shin_l": Vector3(34, 13, -6),
		"foot_l": Vector3(8, 0, 0),
		"leg_r": Vector3(-29, -1, 0),
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var stance = _get_stance_pose()
	var blend = s * (1.0 - r)
	var pose = {}
	for key in power_end:
		pose[key] = stance.get(key, Vector3.ZERO).lerp(power_end[key], blend)
	# Slight windup torso pullback before strike
	pose["torso"] = pose.get("torso", Vector3.ZERO) + Vector3(0, w * 20 * (1.0 - s), 0)
	_set_pose(pose, Vector3(0, blend * 0.05, 0))


func set_pose_df_mid_check(progress: float) -> void:
	# df+1: Body cross mid check — quick level punch to the chest/gut
	# Like a boxer's body jab — compact, horizontal, slight crouch
	idle_bob_active = false
	blend_speed = 45.0

	var p = sin(progress * PI)
	# Deeper crouch — just barely still gets hit by highs
	var crouch = p * 1.0

	# Punching arm (arm_r = viewer LEFT) — straight forward at chest level
	# Key: arm stays LEVEL (not angled down), forearm extends straight out
	var punch_arm = STANCE_ARM_R.lerp(Vector3(-89, -38, -50), p)
	var punch_farm = STANCE_FARM_R.lerp(Vector3(-8, -15, 6), p)

	# Guard arm pulls in tighter
	var guard_arm = STANCE_ARM_L + Vector3(p * 8, 0, p * -5)
	var guard_farm = STANCE_FARM_L + Vector3(0, p * 10, 0)

	_set_pose({
		# Slight forward lean + torso rotation into the punch
		"abdomen": Vector3(crouch * 12, p * -10, 0),
		"torso": Vector3(2 + crouch * 8, p * -25, 0),
		"head": Vector3(0, p * -5, -1),
		# Arms
		"arm_l": guard_arm,
		"forearm_l": guard_farm,
		"arm_r": punch_arm,
		"forearm_r": punch_farm,
		# Legs — deep knee bend to get low
		"leg_l": STANCE_LEG_L + Vector3(crouch * -25, 0, 0),
		"shin_l": STANCE_SHIN_L + Vector3(crouch * 40, 0, 0),
		"foot_l": Vector3(crouch * -8, 0, 0),
		"leg_r": STANCE_LEG_R + Vector3(crouch * -20, 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(crouch * 30, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}, Vector3(0, crouch * -0.15, 0))


func set_pose_outward_backfist(progress: float) -> void:
	# d+1,1: Outward backfist with other hand (arm_l = viewer RIGHT)
	# After d+1 tracking mid, this goes outward the other way
	idle_bob_active = false
	blend_speed = 38.0
	var p = sin(progress * PI)
	# Arm swings outward — Y rotation goes positive (outward from body)
	var swing_arm = Vector3(-60, 70, 80)
	var swing_farm = Vector3(-5, 100, 10)
	_set_pose({
		"torso": Vector3(8, p * 35, p * -10),    # Torso opens up outward
		"head": Vector3(0, p * 10, -1),
		"arm_l": STANCE_ARM_L.lerp(swing_arm, p),
		"forearm_l": STANCE_FARM_L.lerp(swing_farm, p),
		"arm_r": STANCE_ARM_R + Vector3(0, 0, -p * 10),
		"forearm_r": STANCE_FARM_R,
		"leg_l": STANCE_LEG_L,
		"shin_l": STANCE_SHIN_L,
		"leg_r": STANCE_LEG_R + Vector3(p * 10, 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(p * 15, 0, 0),
	}, Vector3(0, -p * 0.03, 0))


func set_pose_high_crush(progress: float) -> void:
	# Overhead — from pose editor windup + final poses
	# 3 phases: long windup (0-0.5), fast strike (0.5-0.65), recovery (0.65-1.0)
	idle_bob_active = false
	blend_speed = 36.0
	var windup = clampf(progress / 0.5, 0.0, 1.0)
	var strike = clampf((progress - 0.5) / 0.15, 0.0, 1.0)
	var recover = clampf((progress - 0.65) / 0.35, 0.0, 1.0)
	var stance = _get_stance_pose()
	var windup_pose = {
		"abdomen": Vector3(-23, -50, 0),
		"arm_l": Vector3(-149, 20, 73),
		"forearm_l": Vector3(36, -26, 37),
		"arm_r": Vector3(0, -32, -73),
		"forearm_r": Vector3(-15, -105, 0),
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, -1, -1),
		"leg_l": Vector3(21, 0, 0),
		"shin_l": Vector3(34, 13, -6),
		"leg_r": Vector3(-39, -1, 0),
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var strike_pose = {
		"abdomen": Vector3(34, -5, 0),
		"arm_l": Vector3(-107, 5, 65),
		"forearm_l": Vector3(-10, 5, -1),
		"arm_r": Vector3(24, -32, -73),
		"forearm_r": Vector3(-128, -94, 0),
		"torso": Vector3(0, 33, 0),
		"head": Vector3(0, -1, -1),
		"leg_l": Vector3(21, 0, 0),
		"shin_l": Vector3(34, 13, -6),
		"leg_r": Vector3(-39, -1, 0),
		"shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	# Blend through phases
	var pose = {}
	var w = sin(windup * PI * 0.5)
	var s = sin(strike * PI * 0.5)
	var r = sin(recover * PI * 0.5)
	for key in windup_pose:
		var from_stance = stance.get(key, Vector3.ZERO)
		var at_windup = from_stance.lerp(windup_pose[key], w)
		var at_strike = windup_pose[key].lerp(strike_pose.get(key, windup_pose[key]), s)
		var at_recover = strike_pose.get(key, windup_pose[key]).lerp(from_stance, r)
		if strike > 0.01:
			if recover > 0.01:
				pose[key] = at_recover
			else:
				pose[key] = at_strike
		else:
			pose[key] = at_windup
	_set_pose(pose)


func set_pose_low_kick(progress: float) -> void:
	# Muay thai low hack — LEFT leg (viewer left = code leg_l)
	# Chamber knee, then chop down at low angle
	idle_bob_active = false
	blend_speed = 33.0
	var chamber = clampf(progress / 0.3, 0.0, 1.0)
	var swing = clampf((progress - 0.3) / 0.35, 0.0, 1.0)
	var recover = clampf((progress - 0.65) / 0.35, 0.0, 1.0)
	var ch = sin(chamber * PI * 0.5)
	var sw = sin(swing * PI * 0.5)
	var rc = sin(recover * PI * 0.5)
	# Chamber: knee lifts, shin tucks
	# Swing: leg extends out low, torso leans into it
	# Recover: back to stance
	var leg_l_chamber = STANCE_LEG_L + Vector3(-ch * 40, 0, 0)  # Hip flexion (knee up)
	var shin_l_chamber = STANCE_SHIN_L + Vector3(ch * 50, 0, 0)  # Knee bent (tucked)
	var leg_l_swing = Vector3(-60, sw * 20, 0)  # Leg extends forward-low
	var shin_l_swing = Vector3(15, 0, 0)  # Shin straightens for impact
	# Blend
	var final_leg_l = leg_l_chamber.lerp(leg_l_swing, sw).lerp(STANCE_LEG_L, rc)
	var final_shin_l = shin_l_chamber.lerp(shin_l_swing, sw).lerp(STANCE_SHIN_L, rc)
	_set_pose({
		"torso": Vector3(2 + sw * 8 * (1.0 - rc), sw * 20 * (1.0 - rc), sw * -8 * (1.0 - rc)),
		"head": Vector3(0, -1, -1),
		"arm_l": STANCE_ARM_L,
		"forearm_l": STANCE_FARM_L,
		"arm_r": STANCE_ARM_R,
		"forearm_r": STANCE_FARM_R,
		"leg_l": final_leg_l,
		"shin_l": final_shin_l,
		# Support leg bends slightly
		"leg_r": STANCE_LEG_R + Vector3(ch * 8 * (1.0 - rc), 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(ch * 12 * (1.0 - rc), 0, 0),
	})


func set_pose_high_kick(progress: float) -> void:
	# Roundhouse kick — 4 keyframes from pose editor
	# Phases: windup (0-0.25), impact (0.25-0.45), recovery1 (0.45-0.7), recovery2 (0.7-1.0)
	idle_bob_active = false
	blend_speed = 33.0

	var stance = _get_stance_pose()

	# Keyframe poses
	var windup_pose = {
		"abdomen": Vector3(0, 48, -38),
		"torso": Vector3(3, -1, -1),
		"head": Vector3(0, -4, -1),
		"arm_l": Vector3(-54, 6, 73), "forearm_l": Vector3(-4, 92, 51),
		"arm_r": Vector3(-62, -12, -73), "forearm_r": Vector3(-12, -66, 0),
		"leg_l": Vector3(-107, -27, -10), "shin_l": Vector3(72, 46, -6),
		"foot_l": Vector3(26, 8, 19),
		"leg_r": Vector3(-36, -3, 0), "shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var impact_pose = {
		"abdomen": Vector3(2, 50, -61),
		"torso": Vector3(3, -2, -1),
		"head": Vector3(0, -4, -1),
		"arm_l": Vector3(-54, 6, 73), "forearm_l": Vector3(-4, 92, 51),
		"arm_r": Vector3(-62, -12, -73), "forearm_r": Vector3(-12, -66, 0),
		"leg_l": Vector3(-125, -14, 9), "shin_l": Vector3(6, 60, -9),
		"foot_l": Vector3(46, 8, 19),
		"leg_r": Vector3(-36, 45, 0), "shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var recovery1_pose = {
		"abdomen": Vector3(32, 48, -56),
		"torso": Vector3(3, -3, -2),
		"head": Vector3(0, -4, -1),
		"arm_l": Vector3(-54, 6, 73), "forearm_l": Vector3(-4, 92, 51),
		"arm_r": Vector3(-62, -12, -73), "forearm_r": Vector3(-12, -66, 0),
		"leg_l": Vector3(-71, -22, 59), "shin_l": Vector3(73, 60, -9),
		"foot_l": Vector3(46, 8, 19),
		"leg_r": Vector3(-36, 45, 0), "shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var recovery2_pose = {
		"torso": Vector3(2, 0, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": Vector3(-11, 20, 73), "forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-54, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(21, 0, 0), "shin_l": Vector3(34, 13, -6),
		"leg_r": Vector3(-39, -1, 0), "shin_r": Vector3(34, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}

	var pose: Dictionary
	var root_offset = Vector3.ZERO

	if progress < 0.25:
		# Stance → Windup
		var t = sin(clampf(progress / 0.25, 0.0, 1.0) * PI * 0.5)
		pose = _lerp_poses(stance, windup_pose, t)
		root_offset = Vector3.ZERO.lerp(Vector3(1, 0, -1) * 0.01, t)
	elif progress < 0.45:
		# Windup → Impact
		var t = sin(clampf((progress - 0.25) / 0.2, 0.0, 1.0) * PI * 0.5)
		pose = _lerp_poses(windup_pose, impact_pose, t)
		root_offset = Vector3(1, 0, -1).lerp(Vector3(0, 12, 2), t) * 0.01
	elif progress < 0.7:
		# Impact → Recovery1
		var t = sin(clampf((progress - 0.45) / 0.25, 0.0, 1.0) * PI * 0.5)
		pose = _lerp_poses(impact_pose, recovery1_pose, t)
		root_offset = Vector3(0, 12, 2).lerp(Vector3(0, 42, 2), t) * 0.01
	else:
		# Recovery1 → Recovery2 → Stance
		var t = sin(clampf((progress - 0.7) / 0.3, 0.0, 1.0) * PI * 0.5)
		pose = _lerp_poses(recovery1_pose, recovery2_pose, t)
		root_offset = Vector3(0, 42, 2).lerp(Vector3.ZERO, t) * 0.01

	_set_pose(pose, root_offset)


func set_pose_d_low_kick(progress: float) -> void:
	# Leg sweep (d+3) — 4 keyframes from pose editor
	# Phases: enter (0-0.15), early sweep (0.15-0.35), impact (0.35-0.65), late sweep (0.65-0.85), recover (0.85-1.0)
	idle_bob_active = false
	blend_speed = 38.0

	# Shared sweep body pose (same for all 3 keyframes)
	var sweep_body = {
		"abdomen": Vector3(8, 40, -1),
		"torso": Vector3(37, 1, -1),
		"head": Vector3(-1, -1, -1),
		"arm_l": Vector3(-52, 20, 73),
		"forearm_l": Vector3(-3, 110, -1),
		"arm_r": Vector3(-65, -21, -74),
		"forearm_r": Vector3(5, -109, -1),
		"leg_l": Vector3(-76, -1, 0),
		"shin_l": Vector3(3, 13, -6),
		"foot_l": Vector3(76, 13, 0),
		"leg_r": Vector3(-80, 63, 0),
		"shin_r": Vector3(121, 0, 0),
		"foot_r": Vector3(19, 0, 0),
	}

	# Root Y rotation differs per keyframe (the sweep arc)
	var early_root_y = -15.0   # Earlier pose
	var impact_root_y = 9.0    # Impact pose
	var late_root_y = 26.0     # Later pose
	var root_offset = Vector3(0, -0.34, 0)

	var result = {}

	if progress < 0.15:
		# Enter: stance -> sweep body (early)
		var t = sin(clampf(progress / 0.15, 0.0, 1.0) * PI * 0.5)
		for key in sweep_body:
			var stance_val = _get_stance_value(key)
			result[key] = stance_val.lerp(sweep_body[key], t)
		var cur_root_y = lerpf(0.0, early_root_y, t)
		_set_pose(result, Vector3(0, lerpf(0.0, root_offset.y, t), 0))
		# Apply root rotation
		var root_node = get_node_or_null("Root")
		if root_node:
			root_node.rotation_degrees.y = cur_root_y
	elif progress < 0.35:
		# Early sweep -> impact
		var t = sin(clampf((progress - 0.15) / 0.2, 0.0, 1.0) * PI * 0.5)
		var cur_root_y = lerpf(early_root_y, impact_root_y, t)
		_set_pose(sweep_body, root_offset)
		var root_node = get_node_or_null("Root")
		if root_node:
			root_node.rotation_degrees.y = cur_root_y
	elif progress < 0.65:
		# Hold at impact (active frames)
		_set_pose(sweep_body, root_offset)
		var root_node = get_node_or_null("Root")
		if root_node:
			root_node.rotation_degrees.y = impact_root_y
	elif progress < 0.85:
		# Impact -> late sweep
		var t = sin(clampf((progress - 0.65) / 0.2, 0.0, 1.0) * PI * 0.5)
		var cur_root_y = lerpf(impact_root_y, late_root_y, t)
		_set_pose(sweep_body, root_offset)
		var root_node = get_node_or_null("Root")
		if root_node:
			root_node.rotation_degrees.y = cur_root_y
	else:
		# Recover: late sweep -> stance
		var t = sin(clampf((progress - 0.85) / 0.15, 0.0, 1.0) * PI * 0.5)
		for key in sweep_body:
			var stance_val = _get_stance_value(key)
			result[key] = sweep_body[key].lerp(stance_val, t)
		var cur_root_y = lerpf(late_root_y, 0.0, t)
		_set_pose(result, Vector3(0, lerpf(root_offset.y, 0.0, t), 0))
		var root_node = get_node_or_null("Root")
		if root_node:
			root_node.rotation_degrees.y = cur_root_y


func _get_stance_value(key: String) -> Vector3:
	match key:
		"arm_l": return STANCE_ARM_L
		"forearm_l": return STANCE_FARM_L
		"arm_r": return STANCE_ARM_R
		"forearm_r": return STANCE_FARM_R
		"leg_l": return STANCE_LEG_L
		"shin_l": return STANCE_SHIN_L
		"leg_r": return STANCE_LEG_R
		"shin_r": return STANCE_SHIN_R
		_: return Vector3.ZERO


func set_pose_d_mid_punch(progress: float) -> void:
	# d+1 tracking mid punch — 5 keyframes from pose editor
	idle_bob_active = false
	blend_speed = 45.0

	# Keyframe poses
	var inter1 = {
		"torso": Vector3(2, 0, 0), "head": Vector3(0, -1, -1),
		"arm_l": Vector3(-52, 20, 73), "forearm_l": Vector3(-10, 79, -1),
		"arm_r": Vector3(-59, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-13, 0, 0), "shin_l": Vector3(64, 13, -6),
		"leg_r": Vector3(-50, -1, 1), "shin_r": Vector3(44, 0, 0),
		"foot_r": Vector3(-1, 0, 0),
	}
	var inter1_root = Vector3(0, 0, 0)

	var inter2 = {
		"abdomen": Vector3(-19, 0, 0),
		"torso": Vector3(27, -18, 0), "head": Vector3(0, -1, -1),
		"arm_l": Vector3(-56, -14, 44), "forearm_l": Vector3(24, 107, 44),
		"arm_r": Vector3(-29, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-36, -3, 0), "shin_l": Vector3(83, 13, -6), "foot_l": Vector3(-30, 0, 0),
		"leg_r": Vector3(-53, 16, 1), "shin_r": Vector3(85, 11, 0), "foot_r": Vector3(-27, 0, 0),
	}
	var inter2_root = Vector3(0, -0.14, 0)

	var impact = {
		"abdomen": Vector3(-19, 0, 0),
		"torso": Vector3(27, 36, 0), "head": Vector3(0, -1, -1),
		"arm_l": Vector3(-56, -14, 44), "forearm_l": Vector3(24, 107, 44),
		"arm_r": Vector3(-29, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-19, -17, 0), "shin_l": Vector3(85, 46, 26), "foot_l": Vector3(-30, 0, 0),
		"leg_r": Vector3(-61, -7, 1), "shin_r": Vector3(78, 11, 0), "foot_r": Vector3(-27, 0, 0),
	}
	var impact_root = Vector3(0, -0.17, 0)

	var follow = {
		"abdomen": Vector3(-19, 0, 0),
		"torso": Vector3(27, 61, 0), "head": Vector3(0, -1, -1),
		"arm_l": Vector3(-56, -14, 44), "forearm_l": Vector3(24, 107, 44),
		"arm_r": Vector3(-29, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-19, -17, 0), "shin_l": Vector3(85, 46, 26), "foot_l": Vector3(-30, 0, 0),
		"leg_r": Vector3(-61, -7, 1), "shin_r": Vector3(78, 11, 0), "foot_r": Vector3(-27, 0, 0),
	}
	var follow_root = Vector3(0, -0.17, 0)

	var recovery = {
		"abdomen": Vector3(-10, -8, 0),
		"torso": Vector3(12, 13, 0), "head": Vector3(0, -1, -1),
		"arm_l": Vector3(-56, -14, 44), "forearm_l": Vector3(24, 107, 44),
		"arm_r": Vector3(-26, -32, -73), "forearm_r": Vector3(6, -66, 0),
		"leg_l": Vector3(-13, -17, 0), "shin_l": Vector3(70, 3, 4), "foot_l": Vector3(-17, 0, 0),
		"leg_r": Vector3(-45, -7, 1), "shin_r": Vector3(54, 11, 0), "foot_r": Vector3(-12, 0, 0),
	}
	var recovery_root = Vector3(0, -0.05, 0)

	var stance = _get_stance_pose()
	var stance_root = Vector3.ZERO

	# Blend between keyframes
	var pose: Dictionary
	var root_offset: Vector3
	if progress < 0.2:
		var t = progress / 0.2
		pose = _lerp_pose(stance, inter1, t)
		root_offset = stance_root.lerp(inter1_root, t)
	elif progress < 0.4:
		var t = (progress - 0.2) / 0.2
		pose = _lerp_pose(inter1, inter2, t)
		root_offset = inter1_root.lerp(inter2_root, t)
	elif progress < 0.6:
		var t = (progress - 0.4) / 0.2
		pose = _lerp_pose(inter2, impact, t)
		root_offset = inter2_root.lerp(impact_root, t)
	elif progress < 0.75:
		var t = (progress - 0.6) / 0.15
		pose = _lerp_pose(impact, follow, t)
		root_offset = impact_root.lerp(follow_root, t)
	elif progress < 0.9:
		var t = (progress - 0.75) / 0.15
		pose = _lerp_pose(follow, recovery, t)
		root_offset = follow_root.lerp(recovery_root, t)
	else:
		var t = (progress - 0.9) / 0.1
		pose = _lerp_pose(recovery, stance, t)
		root_offset = recovery_root.lerp(stance_root, t)

	_set_pose(pose, root_offset)


func set_pose_d4_kick(progress: float) -> void:
	# d+4: Quick crouching low kick — offensive class poke
	# Crouches slightly, quick kick at shin level from back leg
	idle_bob_active = false
	blend_speed = 45.0
	var stance = _get_stance_pose()

	# Keyframes: crouch → kick extend → recover
	var startup_t = clampf(progress / 0.3, 0.0, 1.0)
	var active_t = clampf((progress - 0.3) / 0.3, 0.0, 1.0)
	var recover_t = clampf((progress - 0.6) / 0.4, 0.0, 1.0)
	var s = sin(startup_t * PI * 0.5)
	var a = sin(active_t * PI * 0.5)
	var r = sin(recover_t * PI * 0.5)

	var crouch_pose = {
		"abdomen": Vector3(s * -10, 0, 0),
		"torso": Vector3(s * 15, s * -10, 0),
		"head": Vector3(0, -1, -1),
		"arm_l": stance.get("arm_l", STANCE_ARM_L) + Vector3(s * 10, 0, s * 5),
		"forearm_l": stance.get("forearm_l", STANCE_FARM_L),
		"arm_r": stance.get("arm_r", STANCE_ARM_R) + Vector3(s * 15, 0, s * -5),
		"forearm_r": stance.get("forearm_r", STANCE_FARM_R),
		# Plant leg bends (viewer right = leg_l)
		"leg_l": STANCE_LEG_L + Vector3(s * -20, 0, 0),
		"shin_l": STANCE_SHIN_L + Vector3(s * 30, 0, 0),
		# Kicking leg extends low (viewer left = leg_r)
		"leg_r": STANCE_LEG_R + Vector3(a * -15 * (1.0 - r), a * -30 * (1.0 - r), 0),
		"shin_r": STANCE_SHIN_R + Vector3(a * -20 * (1.0 - r), 0, 0),
		"foot_r": Vector3(a * -15 * (1.0 - r), 0, 0),
	}
	_set_pose(crouch_pose, Vector3(0, s * -0.1, 0))


func set_pose_d3_3_rising(progress: float) -> void:
	# d+3,3 second hit: Rising kick from sweep position
	# Character rises from low with a mid-level kick
	idle_bob_active = false
	blend_speed = 40.0

	var rise_t = clampf(progress / 0.4, 0.0, 1.0)
	var kick_t = clampf((progress - 0.3) / 0.3, 0.0, 1.0)
	var recover_t = clampf((progress - 0.6) / 0.4, 0.0, 1.0)
	var ri = sin(rise_t * PI * 0.5)
	var k = sin(kick_t * PI * 0.5)
	var rc = sin(recover_t * PI * 0.5)

	# Start from low sweep position, rise up with a kick
	var rise_pose = {
		"abdomen": Vector3(-15 * (1.0 - ri), ri * 5, 0),
		"torso": Vector3(20 * (1.0 - ri) + k * 10 * (1.0 - rc), k * -25 * (1.0 - rc), 0),
		"head": Vector3(0, -1, -1),
		"arm_l": STANCE_ARM_L + Vector3(ri * 15, ri * 10, ri * 5),
		"forearm_l": STANCE_FARM_L + Vector3(0, ri * 10, 0),
		"arm_r": STANCE_ARM_R + Vector3(ri * 20, ri * -10, ri * -5),
		"forearm_r": STANCE_FARM_R + Vector3(0, ri * -15, 0),
		# Plant leg (viewer left = leg_r) — supports the rise
		"leg_r": STANCE_LEG_R + Vector3(-25 * (1.0 - ri), 0, 0),
		"shin_r": STANCE_SHIN_R + Vector3(35 * (1.0 - ri), 0, 0),
		# Kicking leg (viewer right = leg_l) — rises from low to mid kick
		"leg_l": STANCE_LEG_L + Vector3(k * -40 * (1.0 - rc), k * -20 * (1.0 - rc), 0),
		"shin_l": Vector3(k * 5 * (1.0 - rc) + (1.0 - k) * STANCE_SHIN_L.x, 0, 0),
		"foot_l": Vector3(k * -10 * (1.0 - rc), 0, 0),
	}
	_set_pose(rise_pose, Vector3(0, -0.2 * (1.0 - ri), 0))


func set_pose_knockdown() -> void:
	idle_bob_active = false
	blend_speed = 38.0  # Fast snap to floor
	# Flat on the ground — body rotated ~90 degrees backward
	_set_pose({
		"root": Vector3(-90, 0, 0),  # Entire body rotated to horizontal
		"abdomen": Vector3(0, 0, 0),
		"torso": Vector3(0, 0, 0),
		"head": Vector3(10, 0, 0),
		"arm_l": Vector3(0, 30, 50),
		"forearm_l": Vector3(0, 20, 0),
		"arm_r": Vector3(0, -30, -50),
		"forearm_r": Vector3(0, -20, 0),
		"leg_l": Vector3(5, 0, 0),
		"shin_l": Vector3(10, 0, 0),
		"leg_r": Vector3(-5, 0, 0),
		"shin_r": Vector3(10, 0, 0),
	}, Vector3(0, -0.85, 0))


func set_pose_getup(progress: float) -> void:
	idle_bob_active = false
	blend_speed = 9.0
	var r = sin(progress * PI * 0.5)
	_set_pose({
		"torso": Vector3(-90 * (1.0 - r) + r * 2, 0, 0),
		"head": Vector3(10 * (1.0 - r), -r, -r),
		"arm_l": STANCE_ARM_L * r + Vector3(-30, -10, -30) * (1.0 - r),
		"forearm_l": STANCE_FARM_L * r + Vector3(0, -20, 0) * (1.0 - r),
		"arm_r": STANCE_ARM_R * r + Vector3(-30, 10, 30) * (1.0 - r),
		"forearm_r": STANCE_FARM_R * r + Vector3(0, 20, 0) * (1.0 - r),
		"leg_l": STANCE_LEG_L * r + Vector3(-10, 0, 0) * (1.0 - r),
		"shin_l": STANCE_SHIN_L * r + Vector3(20, 0, 0) * (1.0 - r),
		"leg_r": STANCE_LEG_R * r + Vector3(-15, 0, 0) * (1.0 - r),
		"shin_r": STANCE_SHIN_R * r + Vector3(25, 0, 0) * (1.0 - r),
	}, Vector3(0, -0.65 * (1.0 - r), -0.3 * (1.0 - r)))


func set_pose_getup_kick(progress: float) -> void:
	# Rising kick from the ground — starts from KD pose, rises into roundhouse
	idle_bob_active = false
	blend_speed = 30.0

	var rise_t = clampf(progress / 0.35, 0.0, 1.0)
	var kick_t = clampf((progress - 0.25) / 0.3, 0.0, 1.0)
	var recover_t = clampf((progress - 0.55) / 0.45, 0.0, 1.0)
	var ri = sin(rise_t * PI * 0.5)
	var k = sin(kick_t * PI * 0.5)
	var rc = sin(recover_t * PI * 0.5)

	# Rise from ground
	var root_x = -90.0 * (1.0 - ri)  # From flat to standing
	var root_y_offset = -0.65 * (1.0 - ri)

	# Kick phase — roundhouse from rising position
	var kick_torso_y = k * 71 * (1.0 - rc)  # Same as roundhouse
	var kick_leg_y = k * 122 * (1.0 - rc)

	_set_pose({
		"torso": Vector3(root_x + ri * 2, kick_torso_y, k * -39 * (1.0 - rc)),
		"head": Vector3(10 * (1.0 - ri), -ri, -ri),
		"arm_l": STANCE_ARM_L * ri + Vector3(-30, -10, -30) * (1.0 - ri),
		"forearm_l": STANCE_FARM_L * ri,
		"arm_r": STANCE_ARM_R * ri + Vector3(-30, 10, 30) * (1.0 - ri),
		"forearm_r": STANCE_FARM_R * ri,
		# Plant leg
		"leg_r": STANCE_LEG_R * ri + Vector3(k * 68 * (1.0 - rc), 0, 0),
		"shin_r": STANCE_SHIN_R * ri + Vector3(k * -30 * (1.0 - rc), 0, 0),
		# Kicking leg — rises and extends
		"leg_l": Vector3(-42 * ri, kick_leg_y, k * -138 * (1.0 - rc)),
		"shin_l": Vector3(3 * ri + k * 42 * (1.0 - rc), 0, k * -6 * (1.0 - rc)),
	}, Vector3(0, root_y_offset, 0))


func set_pose_side_roll(progress: float, direction: float = 1.0) -> void:
	# Rolling sideways on the ground
	idle_bob_active = false
	blend_speed = 20.0

	# Roll rotation — body rotates around forward axis
	var roll_angle = progress * 360.0 * direction

	_set_pose({
		"root": Vector3(-80, roll_angle, 0),  # Stay mostly flat, rotate around Z
		"torso": Vector3(0, 0, 0),
		"head": Vector3(10, 0, 0),
		"arm_l": Vector3(-30, -20, -40),
		"forearm_l": Vector3(0, -30, 0),
		"arm_r": Vector3(-30, 20, 40),
		"forearm_r": Vector3(0, 30, 0),
		"leg_l": Vector3(-5, 0, 0),
		"shin_l": Vector3(15, 0, 0),
		"leg_r": Vector3(5, 0, 0),
		"shin_r": Vector3(15, 0, 0),
	}, Vector3(0, -0.7, 0))


func set_crouching(is_crouching: bool) -> void:
	if is_crouching:
		set_pose_crouch()
	else:
		set_pose_fight_stance()
