extends Node3D

# Limb-based hit detection system
# During active frames, checks the actual position of the attacking limb
# against the opponent's body collision (capsule approximation)
# Tight hitboxes — attacks only land when the model visually connects

# Which limb each attack uses and its hit properties
var attack_data: Dictionary = {
	# Shared moves — per-limb sphere radii (compensated for smaller defender targets)
	"jab": {"limb": "hand_r", "hit_level": "high", "damage": 8, "hit_radius": 0.5, "max_range": 1.8},
	"high_crush": {"limb": "hand_l", "hit_level": "mid", "damage": 35, "hit_radius": 0.85, "max_range": 2.2},
	"low_kick": {"limbs": ["foot_l", "shin_l"], "hit_level": "low", "damage": 12, "hit_radius": 0.45, "max_range": 1.8},
	"high_kick": {"limbs": ["foot_l", "shin_l"], "hit_level": "high", "damage": 18, "hit_radius": 0.5, "max_range": 2.0},
	"d_low_kick": {"limbs": ["foot_l", "shin_l"], "hit_level": "low", "damage": 14, "hit_radius": 0.45, "max_range": 1.8},
	# Defensive exclusive
	"jab_2": {"limb": "hand_l", "hit_level": "high", "damage": 8, "hit_radius": 0.45, "max_range": 1.8},
	"power_straight": {"limbs": ["hand_r", "forearm_r"], "hit_level": "high", "damage": 22, "hit_radius": 0.5, "max_range": 2.0},
	"df1_check": {"limb": "hand_r", "hit_level": "mid", "damage": 12, "hit_radius": 0.5, "max_range": 1.8},
	"d_mid_punch": {"limb": "hand_r", "hit_level": "mid", "damage": 12, "hit_radius": 0.5, "max_range": 1.8},
	# Offensive exclusive
	"d4_kick": {"limbs": ["foot_r", "shin_r"], "hit_level": "low", "damage": 12, "hit_radius": 0.45, "max_range": 1.8},
	"d4_4_power": {"limbs": ["foot_l", "shin_l"], "hit_level": "high", "damage": 22, "hit_radius": 0.5, "max_range": 2.0},
	"d3_3_rising": {"limbs": ["foot_r", "shin_r"], "hit_level": "low", "damage": 20, "hit_radius": 0.5, "max_range": 2.0},
	"high_kick_2": {"limbs": ["foot_r", "shin_r"], "hit_level": "high", "damage": 20, "hit_radius": 0.5, "max_range": 2.0},
}

# Per-body-part sphere radii (Tekken-style hurtboxes)
const BODY_PART_SPHERES: Dictionary = {
	"head":       {"joint": "Root/Abdomen/Torso/Head", "radius": 0.15},
	"torso":      {"joint": "Root/Abdomen/Torso", "radius": 0.25},
	"abdomen":    {"joint": "Root/Abdomen", "radius": 0.22},
	"arm_l":      {"joint": "Root/Abdomen/Torso/ShoulderL/UpperArmL", "radius": 0.08},
	"forearm_l":  {"joint": "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL", "radius": 0.07},
	"hand_l":     {"joint": "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL/HandL", "radius": 0.06},
	"arm_r":      {"joint": "Root/Abdomen/Torso/ShoulderR/UpperArmR", "radius": 0.08},
	"forearm_r":  {"joint": "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR", "radius": 0.07},
	"hand_r":     {"joint": "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR/HandR", "radius": 0.06},
	"leg_l":      {"joint": "Root/HipL/UpperLegL", "radius": 0.10},
	"shin_l":     {"joint": "Root/HipL/UpperLegL/LowerLegL", "radius": 0.08},
	"foot_l":     {"joint": "Root/HipL/UpperLegL/LowerLegL/FootL", "radius": 0.07},
	"leg_r":      {"joint": "Root/HipR/UpperLegR", "radius": 0.10},
	"shin_r":     {"joint": "Root/HipR/UpperLegR/LowerLegR", "radius": 0.08},
	"foot_r":     {"joint": "Root/HipR/UpperLegR/LowerLegR/FootR", "radius": 0.07},
}

# Which defender parts each hit level can connect with
const HIT_LEVEL_TARGETS: Dictionary = {
	"high": ["head", "torso", "arm_l", "arm_r", "forearm_l", "forearm_r", "hand_l", "hand_r"],
	"mid":  ["torso", "abdomen", "arm_l", "arm_r", "forearm_l", "forearm_r"],
	"low":  ["abdomen", "leg_l", "leg_r", "shin_l", "shin_r", "foot_l", "foot_r"],
}

var fighter: CharacterBody3D = null
var active_attack: String = ""
var has_hit: bool = false
var _cached_model: Node3D = null
var _cached_limbs: Dictionary = {}  # Attacker limbs
var _cached_opponent_limbs: Dictionary = {}  # Defender body part joints

# Joint path mapping for attacker limbs
var limb_paths: Dictionary = {
	"hand_l": "Root/Abdomen/Torso/ShoulderL/UpperArmL/ForearmL/HandL",
	"hand_r": "Root/Abdomen/Torso/ShoulderR/UpperArmR/ForearmR/HandR",
	"foot_l": "Root/HipL/UpperLegL/LowerLegL/FootL",
	"foot_r": "Root/HipR/UpperLegR/LowerLegR/FootR",
}


func _ready() -> void:
	fighter = get_parent() as CharacterBody3D
	_cache_model_and_limbs()


func _cache_model_and_limbs() -> void:
	_cached_model = fighter.get_node_or_null("Model") if fighter else null
	if _cached_model:
		for limb_name in limb_paths:
			var path = limb_paths[limb_name]
			var limb = _cached_model.get_node_or_null(path)
			if limb:
				_cached_limbs[limb_name] = limb


func cache_opponent_limbs(opponent: CharacterBody3D) -> void:
	_cached_opponent_limbs.clear()
	var opp_model = opponent.get_node_or_null("Model")
	if opp_model == null:
		return
	for part_name in BODY_PART_SPHERES:
		var joint_path: String = BODY_PART_SPHERES[part_name]["joint"]
		var joint = opp_model.get_node_or_null(joint_path)
		if joint:
			_cached_opponent_limbs[part_name] = joint


# --- Rollback serialization ---
func save_state() -> Dictionary:
	return {"aa": active_attack, "hh": has_hit}

func load_state(s: Dictionary) -> void:
	active_attack = s.get("aa", "")
	has_hit = s.get("hh", false)


func activate(attack_name: String) -> void:
	active_attack = attack_name
	has_hit = false


func deactivate() -> void:
	active_attack = ""
	has_hit = false


func check_hit() -> Dictionary:
	if active_attack == "" or has_hit:
		return {}

	var data = attack_data.get(active_attack, {})
	if data.is_empty():
		return {}

	var opponent = fighter.opponent
	if opponent == null:
		return {}

	# Attacker must still be in Attack state to land a hit
	# Prevents hitting while in hitstun/blockstun (trade race condition)
	if fighter.state_machine:
		var my_state: String = fighter.state_machine.current_state_name()
		if my_state != "Attack":
			return {}

	# Invulnerability check (backdash i-frames)
	if opponent.is_invulnerable:
		return {}

	# Check if opponent is knocked down — only lows can hit grounded opponents
	var hit_level = data["hit_level"]
	var opp_is_grounded = false
	if opponent.state_machine:
		var opp_state = opponent.state_machine.current_state_name()
		opp_is_grounded = opp_state == "Knockdown" or opp_state == "Getup"

	# Get attacker's current move for property checks
	var current_move = null
	if fighter.state_machine:
		var atk_state = fighter.state_machine.states.get("Attack")
		if atk_state and "current_move" in atk_state:
			current_move = atk_state.current_move

	var move_hits_grounded = current_move.hits_grounded if current_move else false
	var move_is_homing = current_move.is_homing if current_move else false
	var move_high_crush = current_move.high_crush if current_move else false

	# Grounded check — only moves explicitly tagged hits_grounded connect on downed opponents
	if opp_is_grounded and not move_hits_grounded:
		return {}

	# HIGH CRUSH — if attacker is in a high crush move, high attacks from opponent whiff
	# (This is checked on the DEFENDER side when we check_hit from attacker)
	# Actually high_crush means the attacker ducks highs — handled separately

	# EVASION — check if opponent is evading this hit level
	# Hop evades lows
	var opp_state_name = ""
	if opponent.state_machine:
		opp_state_name = opponent.state_machine.current_state_name()

	if opp_state_name == "Hop" and hit_level == "low":
		return {}  # Hop evades lows

	# Backsway evades highs during evasion frames
	if opp_state_name == "Backsway" and hit_level == "high":
		var sway_state = opponent.state_machine.states.get("Backsway")
		if sway_state and sway_state.is_evading:
			return {}  # Backsway leans back under highs

	# Check if OPPONENT is high crushing (their move ducks our high)
	var opp_is_high_crushing = false
	if opponent.state_machine:
		var opp_atk = opponent.state_machine.states.get("Attack")
		if opp_atk and "current_move" in opp_atk and opp_atk.current_move:
			opp_is_high_crushing = opp_atk.current_move.high_crush
	if opp_is_high_crushing and hit_level == "high":
		return {}  # Opponent is high crushing, our high whiffs

	# Crouching evades highs (standard Tekken)
	if opponent.is_crouching and hit_level == "high":
		return {}  # Highs whiff on crouching opponents

	# Opponent body center (for facing/range checks)
	var opp_pos = opponent.global_position

	# Check if opponent is in front of fighter (prevent hitting behind)
	var to_opp = opp_pos - fighter.global_position
	to_opp.y = 0
	var fighter_dist = to_opp.length()
	var fwd = fighter.get_forward_direction()
	var facing_dot = to_opp.normalized().dot(fwd)

	if move_is_homing:
		if facing_dot < -0.7:
			return {}
	else:
		if facing_dot < -0.1:
			return {}

	# Max range early-out
	var max_range = data.get("max_range", 2.0)
	if fighter_dist > max_range:
		return {}

	# --- Per-limb sphere-vs-sphere hit detection ---
	# Get attacker's attacking limb(s) position
	var attack_limbs: Array = data.get("limbs", [data.get("limb", "hand_r")])
	var hit_radius: float = data.get("hit_radius", 0.5)
	var target_parts: Array = HIT_LEVEL_TARGETS.get(hit_level, [])
	var limb_hit: bool = false

	for atk_limb_name in attack_limbs:
		var atk_pos: Vector3 = _get_limb_global_position(atk_limb_name)
		if atk_pos == Vector3.INF:
			continue

		# Check against each eligible defender body part sphere
		for part_name in target_parts:
			var part_joint = _cached_opponent_limbs.get(part_name)
			if part_joint == null:
				continue
			var part_pos: Vector3 = part_joint.global_position
			var part_radius: float = BODY_PART_SPHERES[part_name]["radius"]
			var combined_radius: float = hit_radius + part_radius
			var dist: float = atk_pos.distance_to(part_pos)

			if dist <= combined_radius:
				limb_hit = true
				break

		if limb_hit:
			break

	if not limb_hit:
		return {}

	# HIT! Check if blocked (hit_level already set above)
	var blocked = _check_blocked(opponent, hit_level)

	has_hit = true

	# Counter hit detection — defender is in attack startup (committed to a move)
	var counter_hit = false
	if not blocked and opponent.state_machine:
		var opp_state_name2 = opponent.state_machine.current_state_name()
		if opp_state_name2 == "Attack":
			var opp_atk = opponent.state_machine.states.get("Attack")
			if opp_atk and opp_atk.phase == "startup":
				counter_hit = true

	# Wall bonus damage — extra damage when hit lands near a wall (no wall splat)
	var base_damage = data["damage"]
	var wall_bonus = 0
	if not blocked:
		wall_bonus = _check_wall_bonus(opponent)

	return {
		"damage": base_damage + wall_bonus,
		"hit_level": hit_level,
		"blocked": blocked,
		"counter_hit": counter_hit,
		"attacker": fighter,
		"defender": opponent,
		"wall_bonus": wall_bonus,
	}


func _get_limb_global_position(limb_name: String) -> Vector3:
	var limb = _cached_limbs.get(limb_name)
	if limb == null:
		return Vector3.INF
	return limb.global_position


func _check_wall_bonus(defender: CharacterBody3D) -> int:
	# Check if defender is close to a wall — raycast in knockback direction
	# Bonus damage: ~30% extra if within 1.5m of wall
	var space_state = defender.get_world_3d().direct_space_state
	if space_state == null:
		return 0

	var from = defender.global_position + Vector3(0, 0.5, 0)
	var kb_dir = fighter.get_forward_direction()

	# Cast ray in knockback direction (where they'd be pushed)
	var to = from + kb_dir * 1.5
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [fighter.get_rid(), defender.get_rid()]
	query.collision_mask = 1  # Stage collision layer

	var result = space_state.intersect_ray(query)
	if result:
		# Wall is close — bonus damage scales with proximity
		var wall_dist = from.distance_to(result.position)
		var bonus_factor = 1.0 - (wall_dist / 1.5)  # 1.0 at wall, 0.0 at 1.5m
		return int(5 * bonus_factor)  # Up to 5 bonus damage

	return 0


func _check_blocked(opponent: CharacterBody3D, hit_level: String) -> bool:
	var input = InputManager.get_input(opponent.player_id)
	var holding_back = (input & InputManager.INPUT_BACK) != 0
	var holding_down = (input & InputManager.INPUT_DOWN) != 0
	var is_crouching = opponent.is_crouching or holding_down

	# Neutral standing = auto standing block (blocks high + mid)
	# Getup = auto standing block (only lows connect as KD follow-up)
	var in_neutral = false
	if opponent.state_machine:
		var current_state = opponent.state_machine.current_state_name()
		in_neutral = current_state == "Idle"

	var holding_forward = (input & InputManager.INPUT_FORWARD) != 0

	# Tekken-standard blocking:
	# Neutral standing = auto standing block (high + mid)
	# Holding d or db = auto crouch block (low + mid)
	# Holding df = crouching but NOT blocking (vulnerable, for df+moves)
	# Holding f = NOT blocking (walking forward, open)
	# Holding b = standing block
	var crouch_blocking = is_crouching and not holding_forward  # d or db = crouch block, df = no block
	var stand_blocking = holding_back or in_neutral  # b or neutral = standing block
	var is_blocking = stand_blocking or crouch_blocking or opponent.is_blocking_on_getup

	if not is_blocking:
		return false

	# Getup block protects against ALL hit levels (prevents knockdown loops)
	if opponent.is_blocking_on_getup:
		return true

	if is_crouching:
		# Crouch block: blocks low + mid, NOT high
		return hit_level == "low" or hit_level == "mid"
	else:
		# Standing block: blocks high + mid, NOT low
		return hit_level == "high" or hit_level == "mid"
