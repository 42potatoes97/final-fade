extends Node3D

# Limb-based hit detection system
# During active frames, checks the actual position of the attacking limb
# against the opponent's body collision (capsule approximation)
# Tight hitboxes — attacks only land when the model visually connects

# Which limb each attack uses and its hit properties
var attack_data: Dictionary = {
	# Shared moves — tight hitboxes, must connect visually
	"jab": {"limb": "hand_r", "hit_level": "high", "damage": 8, "hit_radius": 0.4, "max_range": 1.8},
	"high_crush": {"limb": "hand_l", "hit_level": "mid", "damage": 35, "hit_radius": 0.75, "max_range": 2.2},
	"low_kick": {"limb": "foot_l", "hit_level": "low", "damage": 12, "hit_radius": 0.35, "max_range": 1.8},
	"high_kick": {"limb": "foot_l", "hit_level": "high", "damage": 18, "hit_radius": 0.4, "max_range": 2.0},
	"d_low_kick": {"limb": "foot_l", "hit_level": "low", "damage": 14, "hit_radius": 0.35, "max_range": 1.8},
	# Defensive exclusive
	"jab_2": {"limb": "hand_l", "hit_level": "high", "damage": 8, "hit_radius": 0.35, "max_range": 1.8},
	"power_straight": {"limb": "hand_r", "hit_level": "high", "damage": 22, "hit_radius": 0.4, "max_range": 2.0},
	"df1_check": {"limb": "hand_r", "hit_level": "mid", "damage": 12, "hit_radius": 0.4, "max_range": 1.8},
	"d_mid_punch": {"limb": "hand_r", "hit_level": "mid", "damage": 12, "hit_radius": 0.4, "max_range": 1.8},
	# Offensive exclusive
	"d4_kick": {"limb": "foot_r", "hit_level": "low", "damage": 12, "hit_radius": 0.35, "max_range": 1.8},
	"d4_4_power": {"limb": "foot_l", "hit_level": "high", "damage": 22, "hit_radius": 0.4, "max_range": 2.0},
	"d3_3_rising": {"limb": "foot_r", "hit_level": "low", "damage": 20, "hit_radius": 0.4, "max_range": 2.0},
	"high_kick_2": {"limb": "foot_r", "hit_level": "high", "damage": 20, "hit_radius": 0.4, "max_range": 2.0},
}

# Opponent hurtbox — capsule approximation (tight)
const HURTBOX_RADIUS: float = 0.35
const HURTBOX_HEIGHT_STAND: float = 1.8
const HURTBOX_HEIGHT_CROUCH: float = 1.2

var fighter: CharacterBody3D = null
var active_attack: String = ""
var has_hit: bool = false
var _cached_model: Node3D = null
var _cached_limbs: Dictionary = {}

# Joint path mapping (must match fighter_model.gd J dict)
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

	# Opponent body center
	var opp_pos = opponent.global_position
	var opp_height = HURTBOX_HEIGHT_CROUCH if opponent.is_crouching else HURTBOX_HEIGHT_STAND
	if opp_is_grounded:
		opp_height = 0.3  # Very low hurtbox when on the ground

	# Check if opponent is in front of fighter (prevent hitting behind)
	# Homing moves have wider tracking angle — can hit sidestepped opponents
	var to_opp = opp_pos - fighter.global_position
	to_opp.y = 0
	var fighter_dist = to_opp.length()
	var fwd = fighter.get_forward_direction()
	var facing_dot = to_opp.normalized().dot(fwd)

	if move_is_homing:
		# Homing: only miss if opponent is completely behind (>135 degrees off)
		if facing_dot < -0.7:
			return {}
	else:
		# Linear: miss if opponent is to the side or behind
		if facing_dot < -0.1:
			return {}

	# Max range fallback — if fighters are close enough, always check for hit
	var max_range = data.get("max_range", 2.0)
	if fighter_dist > max_range:
		return {}  # Too far away, no need for limb check

	# Try limb-based check first (tighter, more accurate)
	var limb_name = data.get("limb", "hand_r")
	var limb_global_pos = _get_limb_global_position(limb_name)
	var limb_hit = false

	if limb_global_pos != Vector3.INF:
		var limb_horiz = Vector3(limb_global_pos.x, 0, limb_global_pos.z)
		var opp_horiz = Vector3(opp_pos.x, 0, opp_pos.z)
		var horiz_dist = limb_horiz.distance_to(opp_horiz)
		var hit_radius = data.get("hit_radius", 0.5)
		var total_radius = hit_radius + HURTBOX_RADIUS

		if horiz_dist <= total_radius:
			# Vertical check with generous margin
			var limb_y = limb_global_pos.y
			var opp_base_y = opp_pos.y
			if limb_y >= opp_base_y - 0.5 and limb_y <= opp_base_y + opp_height + 0.5:
				limb_hit = true

	# No fallback — limb must actually connect
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
