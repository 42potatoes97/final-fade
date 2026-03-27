extends Node3D
class_name OctagonStage

# Procedural regular-octagon arena.
# Export vars are set per-stage via the .tscn file before _ready() runs.
@export var apothem: float = 8.0          # Distance from center to flat wall face (meters)
@export var wall_height: float = 3.0
@export var wall_thickness: float = 0.4
@export var floor_color: Color = Color(0.25, 0.25, 0.3)
@export var wall_color: Color = Color(0.5, 0.15, 0.15)
@export var bg_color: Color = Color(0.15, 0.15, 0.2)
@export var ambient_color: Color = Color(0.4, 0.4, 0.5)
@export var light_color: Color = Color(1.0, 1.0, 1.0)
@export var light_energy: float = 1.2
@export var infinite_floor: bool = false   # Training room — no walls, huge floor

const NUM_SIDES: int = 8  # Regular octagon

func _ready() -> void:
	_build_floor()
	if not infinite_floor:
		_build_walls()
	_build_lighting()


func _build_floor() -> void:
	var floor_size: float
	if infinite_floor:
		floor_size = 100.0
	else:
		floor_size = apothem * 2.0

	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	add_child(floor_body)

	var col := CollisionShape3D.new()
	var box_col := BoxShape3D.new()
	box_col.size = Vector3(floor_size, 0.2, floor_size)
	col.shape = box_col
	col.position = Vector3(0.0, -0.1, 0.0)
	floor_body.add_child(col)

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(floor_size, 0.2, floor_size)
	mesh_inst.mesh = box_mesh
	mesh_inst.position = Vector3(0.0, -0.1, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = floor_color
	mesh_inst.material_override = mat
	floor_body.add_child(mesh_inst)


func _build_walls() -> void:
	# side_length for a regular octagon: 2 * apothem * tan(PI/8)
	var side_length: float = 2.0 * apothem * tan(PI / 8.0)

	var wall_mat := StandardMaterial3D.new()
	# Fully opaque by default — the camera fades walls dynamically via raycasting
	# when they occlude the fighters (see fight_camera.gd _update_wall_transparency).
	wall_mat.albedo_color = wall_color
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # Visible from both sides

	for i in range(NUM_SIDES):
		var angle_rad: float = deg_to_rad(float(i) * 45.0)

		# Wall center: apothem out from origin, at mid-height
		var py: float = wall_height * 0.5
		var wall_pos := Vector3(sin(angle_rad) * apothem, py, cos(angle_rad) * apothem)

		var wall_body := StaticBody3D.new()
		wall_body.name = "Wall%d" % i
		wall_body.collision_layer = 1
		wall_body.collision_mask = 0
		wall_body.position = wall_pos
		add_child(wall_body)  # Must be in tree before look_at (uses global_position)
		# look_at the stage center at the same height — correctly orients wide X axis
		# tangentially and thin Z axis radially, for every octant.
		wall_body.look_at(Vector3(0.0, py, 0.0), Vector3.UP)

		var col := CollisionShape3D.new()
		var box_col := BoxShape3D.new()
		box_col.size = Vector3(side_length, wall_height, wall_thickness)
		col.shape = box_col
		wall_body.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(side_length, wall_height, wall_thickness)
		mesh_inst.mesh = box_mesh
		mesh_inst.material_override = wall_mat
		wall_body.add_child(mesh_inst)


func _build_lighting() -> void:
	var light := DirectionalLight3D.new()
	light.name = "DirectionalLight"
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	light.light_color = light_color
	light.light_energy = light_energy
	light.shadow_enabled = true
	add_child(light)

	var env_node := WorldEnvironment.new()
	env_node.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = 0.55
	env_node.environment = env
	add_child(env_node)
