extends Node3D

# Mixamo character model facade
# Uses editor-imported FBX scene + AnimationLibrary resources
# Exposes the same set_pose_xxx() API as the original fighter_model.gd

var skeleton: Skeleton3D
var anim_player: AnimationPlayer
var character: Node
var idle_bob_active: bool = true
var blend_speed: float = 15.0

# Track current animation state
var current_anim: String = ""
var using_mixamo_anim: bool = false
var editor_active: bool = false

# Animation library paths (these are now imported as AnimationLibrary resources)
const ANIM_LIBS = {
	"jab": "res://assets/mixamo/jab.fbx",
	"cross_punch": "res://assets/mixamo/cross_punch.fbx",
	"hook_punch": "res://assets/mixamo/hook_punch.fbx",
	"hit_reaction": "res://assets/mixamo/hit_reaction.fbx",
}


func _ready() -> void:
	# Instance the base character (fighting_idle FBX has the mesh + skeleton + idle anim)
	var base_scene = load("res://assets/mixamo/fighting_idle.fbx") as PackedScene
	if base_scene == null:
		push_error("Failed to load Mixamo character FBX")
		return

	character = base_scene.instantiate()
	character.name = "MixamoCharacter"
	add_child(character)

	skeleton = _find_node_of_type(character, "Skeleton3D")
	anim_player = _find_node_of_type(character, "AnimationPlayer")

	if skeleton == null:
		push_error("No Skeleton3D found")
		return
	if anim_player == null:
		push_error("No AnimationPlayer found")
		return

	# Load animation libraries from separately imported FBX files
	for anim_key in ANIM_LIBS:
		var lib = load(ANIM_LIBS[anim_key])
		if lib is AnimationLibrary:
			anim_player.add_animation_library(anim_key, lib)
			print("Loaded AnimationLibrary: ", anim_key, " anims: ", lib.get_animation_list())
		else:
			print("Warning: ", ANIM_LIBS[anim_key], " is not AnimationLibrary, type=", typeof(lib))

	print("All animations: ", anim_player.get_animation_list())

	# Scale
	character.scale = Vector3(1.0, 1.0, 1.0)

	# Play idle - the base FBX's animation might have a generic name
	var anim_list = anim_player.get_animation_list()
	for a in anim_list:
		if "idle" in a.to_lower() or a == anim_list[0]:
			anim_player.play(a)
			current_anim = a
			print("Playing idle: ", a)
			break


func _find_node_of_type(root: Node, type_name: String) -> Node:
	if root.get_class() == type_name:
		return root
	for child in root.get_children():
		var found = _find_node_of_type(child, type_name)
		if found:
			return found
	return null


func _process(_delta: float) -> void:
	if editor_active:
		return


# ============================================================
# POSE API — same interface as fighter_model.gd
# ============================================================

func set_pose_fight_stance() -> void:
	_play_idle()

func set_pose_jab(progress: float) -> void:
	_play_anim_lib("jab")

func set_pose_jab_2(progress: float) -> void:
	_play_anim_lib("cross_punch")

func set_pose_power_straight(progress: float) -> void:
	_play_anim_lib("hook_punch")

func set_pose_high_crush(progress: float) -> void:
	_play_anim_lib("jab")  # placeholder

func set_pose_low_kick(progress: float) -> void:
	_play_idle()

func set_pose_high_kick(progress: float) -> void:
	_play_idle()

func set_pose_d_low_kick(progress: float) -> void:
	_play_idle()

func set_pose_d_mid_punch(progress: float) -> void:
	_play_anim_lib("jab")

func set_pose_outward_backfist(progress: float) -> void:
	_play_anim_lib("cross_punch")

func set_pose_df_mid_check(progress: float) -> void:
	_play_anim_lib("jab")

func set_pose_walk_forward(phase: float) -> void:
	_play_idle()

func set_pose_walk_backward(phase: float) -> void:
	_play_idle()

func set_pose_dash_forward(progress: float) -> void:
	_play_idle()

func set_pose_backdash(progress: float) -> void:
	_play_idle()

func set_pose_sidestep(direction: float) -> void:
	_play_idle()

func set_pose_crouch() -> void:
	_play_idle()

func set_pose_crouch_dash(progress: float) -> void:
	_play_idle()

func set_pose_hop(progress: float) -> void:
	_play_idle()

func set_pose_backsway(progress: float) -> void:
	_play_idle()

func set_pose_knockdown() -> void:
	_play_anim_lib("hit_reaction")

func set_pose_getup(progress: float) -> void:
	_play_idle()

func _set_pose(pose_dict: Dictionary, root_offset: Vector3 = Vector3.ZERO) -> void:
	_play_anim_lib("hit_reaction")


# ============================================================
# Internal
# ============================================================

func _play_idle() -> void:
	if anim_player == null:
		return
	# Find the idle animation name (from the base FBX library)
	if current_anim.contains("idle") or current_anim == "":
		return
	for a in anim_player.get_animation_list():
		if "idle" in a.to_lower():
			anim_player.play(a, 0.15)
			current_anim = a
			return


func _play_anim_lib(lib_name: String) -> void:
	if anim_player == null:
		return
	# AnimationLibrary animations are accessed as "library_name/anim_name"
	# Find the first animation in the named library
	for a in anim_player.get_animation_list():
		if a.begins_with(lib_name + "/"):
			if current_anim != a:
				anim_player.play(a, 0.1)
				current_anim = a
			return
	# Fallback: try playing the lib name directly
	if anim_player.has_animation(lib_name):
		if current_anim != lib_name:
			anim_player.play(lib_name, 0.1)
			current_anim = lib_name
