extends Node

# Animation Controller — bridges our state machine to Mixamo animation clips
# Replaces the procedural pose system (fighter_model.gd) with actual animations
#
# How it works:
# 1. Each state calls play_anim("anim_name") instead of set_pose_xxx()
# 2. This script controls an AnimationPlayer with imported Mixamo clips
# 3. Supports blending between animations for smooth transitions
# 4. Attack animations play once, movement anims loop

# Animation name mapping: our state names → Mixamo clip names
# Update these after importing your Mixamo FBX files
const ANIM_MAP = {
	# Idle / Stance
	"fight_stance": "fighting_idle",

	# Movement
	"walk_forward": "walking",
	"walk_backward": "walking_backward",
	"dash_forward": "run_forward",
	"backdash": "dodge_back",
	"sidestep": "sidestep",
	"crouch": "crouch",
	"crouch_dash": "crouch",
	"hop": "fighting_idle",      # Fallback until we get a hop anim
	"backsway": "dodge_back",    # Reuse dodge back for backsway

	# Attacks — mapped to new button layout
	# 1 = jab, 1,1 = cross, 1,1,1 = hook
	"jab": "jab",
	"jab_2": "cross_punch",
	"power_straight": "hook_punch",
	# 2 = overhead slam (high crush)
	"high_crush": "overhead_strike",
	# 3 = low kick, 4 = roundhouse
	"low_kick": "low_kick",
	"high_kick": "roundhouse_kick",
	# Directional moves
	"d_low_kick": "low_kick",
	"d_mid_punch": "jab",        # Reuse jab for tracking mid
	"outward_backfist": "cross_punch",  # Reuse cross for backfist
	"df1_check": "jab",

	# Reactions
	"hit_high": "hit_reaction",
	"hit_mid": "hit_reaction",
	"hit_low": "hit_reaction",
	"knockdown": "knockdown",
	"getup": "getup",
	"block": "block",
}

# Animations that should loop vs play once
const LOOPING_ANIMS = [
	"fight_stance", "walk_forward", "walk_backward",
	"crouch", "block",
]

@export var blend_time: float = 0.15  # Cross-fade duration between animations
@export var attack_speed_scale: float = 1.0  # Speed multiplier for attack anims

var anim_player: AnimationPlayer = null
var current_anim: String = ""
var is_attack_playing: bool = false


func _ready() -> void:
	# Find AnimationPlayer in siblings or children
	anim_player = _find_anim_player(get_parent())
	if anim_player:
		anim_player.animation_finished.connect(_on_animation_finished)


func _find_anim_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found = _find_anim_player(child)
		if found:
			return found
	return null


func play_anim(anim_name: String, speed: float = 1.0, from_start: bool = false) -> void:
	if anim_player == null:
		return

	# Map our name to Mixamo clip name
	var clip_name = ANIM_MAP.get(anim_name, anim_name)

	# Check if the animation exists
	if not anim_player.has_animation(clip_name):
		# Try with "mixamo_com/" prefix (Godot sometimes imports with prefix)
		clip_name = "mixamo_com/" + clip_name
		if not anim_player.has_animation(clip_name):
			push_warning("Animation not found: " + anim_name + " (tried: " + clip_name + ")")
			return

	if current_anim == clip_name and not from_start:
		return  # Already playing

	current_anim = clip_name
	is_attack_playing = anim_name not in LOOPING_ANIMS

	# Set speed
	var final_speed = speed
	if is_attack_playing:
		final_speed *= attack_speed_scale

	anim_player.speed_scale = final_speed

	if from_start or is_attack_playing:
		anim_player.play(clip_name, blend_time)
	else:
		anim_player.play(clip_name, blend_time)


func play_attack(anim_name: String, total_frames: int) -> void:
	"""Play an attack animation, scaling speed to match our frame data."""
	if anim_player == null:
		return

	var clip_name = ANIM_MAP.get(anim_name, anim_name)
	if not anim_player.has_animation(clip_name):
		clip_name = "mixamo_com/" + clip_name
		if not anim_player.has_animation(clip_name):
			return

	# Scale animation speed to match our frame data
	# Our game runs at 60fps, so total_frames / 60 = desired duration
	var desired_duration = float(total_frames) / 60.0
	var clip_duration = anim_player.get_animation(clip_name).length
	var speed_scale = clip_duration / desired_duration if desired_duration > 0 else 1.0

	current_anim = clip_name
	is_attack_playing = true
	anim_player.speed_scale = speed_scale
	anim_player.play(clip_name, 0.08)  # Quick blend for attacks


func set_progress(progress: float) -> void:
	"""Manually set animation progress (0.0 to 1.0). Used for frame-synced attacks."""
	if anim_player == null or current_anim == "":
		return
	if anim_player.has_animation(current_anim):
		var length = anim_player.get_animation(current_anim).length
		anim_player.seek(progress * length, true)


func get_available_animations() -> PackedStringArray:
	if anim_player:
		return anim_player.get_animation_list()
	return PackedStringArray()


func _on_animation_finished(anim_name: String) -> void:
	is_attack_playing = false
	# Return to idle after one-shot animations
	if anim_name == current_anim:
		play_anim("fight_stance")
