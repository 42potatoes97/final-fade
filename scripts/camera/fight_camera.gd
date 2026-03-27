class_name FightCamera
extends Camera3D

# 3D Fighting Game Camera (Tekken-style)
# Based on GatitoMimoso00's perpendicular vector approach
# + wall avoidance via raycasts and wall transparency

@export var fighter1: CharacterBody3D
@export var fighter2: CharacterBody3D

# Camera positioning
@export var min_cam_distance: float = 3.2
@export var max_cam_distance: float = 5.5
@export var min_cam_height: float = 1.4
@export var max_cam_height: float = 2.4
@export var look_height: float = 0.8
@export var min_distance_threshold: float = 1.0
@export var max_distance_threshold: float = 8.0

# Camera angles
@export var min_topdown_deg: float = -12.0  # Slight downward look
@export var max_topdown_deg: float = -8.0

# Interpolation weights (higher = faster)
@export var rot_weight: float = 8.0
@export var pos_weight: float = 8.0
@export var vertical_weight: float = 10.0

# Wall avoidance
@export var wall_margin: float = 0.8
const WALL_FADE_ALPHA: float = 0.05  # 5% opacity when any wall occludes the fighters

# Screen shake
var _shake_intensity: float = 0.0
var _shake_decay: float = 10.0

# Internal state
var _cam_y_target_rot: float = 0.0
var _cam_virtual_direction: Vector2 = Vector2(0.0, 1.0)
var _current_sides: String = "P1_P2"
var _space_state: PhysicsDirectSpaceState3D = null
var _exclude_rids: Array[RID] = []
var _faded_walls: Dictionary = {}


func _ready() -> void:
	await get_tree().physics_frame
	_space_state = get_world_3d().direct_space_state


func _process(delta: float) -> void:
	if fighter1 == null or fighter2 == null:
		return

	# Cache exclude list
	if _exclude_rids.is_empty():
		_exclude_rids.append(fighter1.get_rid())
		_exclude_rids.append(fighter2.get_rid())

	# --- POSITIONS ---
	var p1_pos = Vector2(fighter1.global_position.x, fighter1.global_position.z)
	var p2_pos = Vector2(fighter2.global_position.x, fighter2.global_position.z)
	var midpoint_2d = (p1_pos + p2_pos) / 2.0
	var midpoint_3d = (fighter1.global_position + fighter2.global_position) / 2.0

	var vector_pj = (p1_pos - p2_pos).normalized()
	var perp_vector = Vector2(-vector_pj.y, vector_pj.x).normalized()
	var distance_pj = p1_pos.distance_to(p2_pos)

	# Avoid zero vector
	if perp_vector == Vector2.ZERO:
		perp_vector = _cam_virtual_direction

	# --- PERPENDICULAR VECTOR TRACKING ---
	# Project current virtual direction onto new perpendicular
	var scalar_proj = _cam_virtual_direction.project(perp_vector)
	var ang_diff = _cam_virtual_direction.angle_to(scalar_proj)
	_cam_y_target_rot -= ang_diff
	_cam_virtual_direction = perp_vector

	# --- CAMERA DISTANCE BASED ON FIGHTER SEPARATION ---
	var t = clampf((distance_pj - min_distance_threshold) / (max_distance_threshold - min_distance_threshold), 0.0, 1.0)
	var cam_distance = lerpf(min_cam_distance, max_cam_distance, t)
	var cam_height = lerpf(min_cam_height, max_cam_height, t)
	var topdown_rad = deg_to_rad(lerpf(min_topdown_deg, max_topdown_deg, t))

	# --- VIRTUAL CAMERA POSITION ---
	var virtual_rot = Vector3(topdown_rad, _cam_y_target_rot, 0.0)
	var virtual_pos = Vector3(
		sin(virtual_rot.y) * cam_distance + midpoint_2d.x,
		cam_height,
		cos(virtual_rot.y) * cam_distance + midpoint_2d.y
	)

	# --- WALL AVOIDANCE ---
	# Check if virtual position is behind a wall
	var cam_dir_3d = Vector3(virtual_pos.x - midpoint_3d.x, 0, virtual_pos.z - midpoint_3d.z).normalized()
	var safe_dist = _get_safe_distance(midpoint_3d, cam_dir_3d, cam_distance)

	if safe_dist < cam_distance:
		virtual_pos = Vector3(
			sin(virtual_rot.y) * safe_dist + midpoint_2d.x,
			cam_height,
			cos(virtual_rot.y) * safe_dist + midpoint_2d.y
		)

	# --- INTERPOLATION ---
	var interp_pos = Vector3(
		lerpf(global_position.x, virtual_pos.x, delta * pos_weight),
		lerpf(global_position.y, virtual_pos.y, delta * vertical_weight),
		lerpf(global_position.z, virtual_pos.z, delta * pos_weight)
	)

	# Hard clamp interpolated position against walls too
	var interp_dir = Vector3(interp_pos.x - midpoint_3d.x, 0, interp_pos.z - midpoint_3d.z)
	var interp_dist = interp_dir.length()
	if interp_dist > 0.01:
		interp_dir = interp_dir.normalized()
		var clamp_dist = _get_safe_distance(midpoint_3d, interp_dir, interp_dist)
		if interp_dist > clamp_dist:
			interp_pos.x = midpoint_3d.x + interp_dir.x * clamp_dist
			interp_pos.z = midpoint_3d.z + interp_dir.z * clamp_dist

	global_position = interp_pos

	# Apply screen shake
	if _shake_intensity > 0:
		var shake_offset = Vector3(
			randf_range(-_shake_intensity, _shake_intensity),
			randf_range(-_shake_intensity * 0.5, _shake_intensity * 0.5),
			randf_range(-_shake_intensity, _shake_intensity)
		)
		global_position += shake_offset
		_shake_intensity = maxf(0, _shake_intensity - delta * _shake_decay)

	var look_target = midpoint_3d + Vector3(0, look_height, 0)
	look_at(look_target, Vector3.UP)

	# --- SIDE DETECTION ---
	var cam_to_center = Vector3(virtual_pos.x - midpoint_2d.x, 0.0, virtual_pos.z - midpoint_2d.y).normalized()
	var p1_to_center = Vector3(p1_pos.x - midpoint_2d.x, 0.0, p1_pos.y - midpoint_2d.y).normalized()
	var crossed = p1_to_center.cross(cam_to_center)

	var new_sides = "P1_P2" if crossed.y >= 0.0 else "P2_P1"
	if new_sides != _current_sides:
		_current_sides = new_sides
		# Update input facing when sides swap
		if _current_sides == "P1_P2":
			InputManager.set_facing(1, 1)
			InputManager.set_facing(2, -1)
		else:
			InputManager.set_facing(1, -1)
			InputManager.set_facing(2, 1)

	# --- WALL TRANSPARENCY ---
	_update_wall_transparency(look_target)


func reset_tracking() -> void:
	# Recalculate internal state from current fighter positions
	# Called after round reset to prevent camera inversion
	if fighter1 == null or fighter2 == null:
		return
	var p1_pos = Vector2(fighter1.global_position.x, fighter1.global_position.z)
	var p2_pos = Vector2(fighter2.global_position.x, fighter2.global_position.z)
	var vector_pj = (p1_pos - p2_pos).normalized()
	# Flip perpendicular so P1 (negative X) appears on the left side of screen
	_cam_virtual_direction = Vector2(vector_pj.y, -vector_pj.x).normalized()
	if _cam_virtual_direction == Vector2.ZERO:
		_cam_virtual_direction = Vector2(0.0, -1.0)
	# _cam_y_target_rot feeds sin/cos: sin(rot)*dist = x offset, cos(rot)*dist = z offset
	# Use atan2(x, z) of the perpendicular to match the camera's coordinate convention
	_cam_y_target_rot = atan2(_cam_virtual_direction.x, _cam_virtual_direction.y)
	_current_sides = "P1_P2"
	InputManager.set_facing(1, 1)
	InputManager.set_facing(2, -1)
	_shake_intensity = 0.0


func apply_hit_shake(damage: int, is_knockdown: bool = false) -> void:
	# Suppress during rollback re-simulation
	if RollbackManager.is_resimulating:
		return
	if is_knockdown:
		_shake_intensity = 0.12
	elif damage >= 20:
		_shake_intensity = 0.08
	elif damage >= 10:
		_shake_intensity = 0.05
	else:
		_shake_intensity = 0.03


func _get_safe_distance(origin: Vector3, direction: Vector3, max_dist: float) -> float:
	if _space_state == null:
		_space_state = get_world_3d().direct_space_state
		if _space_state == null:
			return max_dist

	var min_safe = max_dist
	var up = Vector3.UP
	var right_vec = direction.cross(up).normalized()
	if right_vec.length() < 0.01:
		right_vec = Vector3(1, 0, 0)

	# Fan of rays to catch wall edges
	var ray_offsets = [
		Vector3.ZERO,
		right_vec * 0.6,
		-right_vec * 0.6,
		Vector3(0, 0.5, 0),
		Vector3(0, -0.3, 0),
	]

	for offset in ray_offsets:
		var from = origin + offset + Vector3(0, look_height, 0)
		var to = from + direction * max_dist + Vector3(0, min_cam_height - look_height, 0)

		var query = PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = 1
		query.exclude = _exclude_rids

		var result = _space_state.intersect_ray(query)
		if not result.is_empty():
			var hit_dist = from.distance_to(result.position)
			var safe = hit_dist - wall_margin
			if safe < min_safe:
				min_safe = safe

	return maxf(min_safe, min_cam_distance * 0.4)


func _update_wall_transparency(look_target: Vector3) -> void:
	if _space_state == null:
		return

	# Check if ANY wall is occluding the fighters or midpoint
	var any_wall_blocking := false
	var targets := [look_target]
	if fighter1:
		targets.append(fighter1.global_position + Vector3(0, 0.9, 0))
	if fighter2:
		targets.append(fighter2.global_position + Vector3(0, 0.9, 0))

	for target in targets:
		var query := PhysicsRayQueryParameters3D.create(global_position, target)
		query.collision_mask = 1
		query.exclude = _exclude_rids
		var result := _space_state.intersect_ray(query)
		if not result.is_empty() and result.collider and result.collider.name.begins_with("Wall"):
			any_wall_blocking = true
			break

	# Collect all stage walls (cached after first call)
	var all_walls := _get_all_walls()

	if any_wall_blocking:
		# Fade every wall so nothing blocks the view
		for wall in all_walls:
			if not _faded_walls.has(wall):
				_fade_wall(wall, true)
	else:
		# No occlusion — restore all walls to full opacity
		var to_restore := _faded_walls.keys()
		for wall in to_restore:
			_fade_wall(wall, false)


func _get_all_walls() -> Array:
	# Walk the scene to find all Wall* StaticBody3D nodes under the Stage node
	var stage := get_tree().get_root().find_child("Stage", true, false)
	if stage == null:
		return []
	var walls: Array = []
	for child in stage.get_children():
		if child.name.begins_with("Wall"):
			walls.append(child)
	return walls


func _fade_wall(wall_body: Node, fade: bool) -> void:
	var mesh_instance: MeshInstance3D = null
	for child in wall_body.get_children():
		if child is MeshInstance3D:
			mesh_instance = child
			break

	if mesh_instance == null:
		return

	if fade:
		var orig_mat = mesh_instance.material_override
		if orig_mat == null:
			return
		_faded_walls[wall_body] = orig_mat
		var fade_mat = orig_mat.duplicate() as StandardMaterial3D
		fade_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fade_mat.albedo_color.a = WALL_FADE_ALPHA
		fade_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh_instance.material_override = fade_mat
	else:
		if _faded_walls.has(wall_body):
			mesh_instance.material_override = _faded_walls[wall_body]
			_faded_walls.erase(wall_body)
