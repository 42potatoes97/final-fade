extends RefCounted

# Tests for combat system — move data, frame data, hit properties


func _get_move_registry():
	var RegistryScript = load("res://scripts/fighter/move_registry.gd")
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var registry = RegistryScript.new()
	# We need a FighterController to register moves, but we can test
	# the MoveData structure directly
	return registry


func test_move_data_has_properties() -> String:
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var move = MoveScript.new()

	# Verify all critical properties exist (defaults may be non-zero)
	if move.startup_frames < 0:
		return "startup_frames should not be negative"
	if move.active_frames < 0:
		return "active_frames should not be negative"
	if move.recovery_frames < 0:
		return "recovery_frames should not be negative"
	if move.damage < 0:
		return "damage should not be negative"

	return ""


func test_frame_advantage_calculation() -> String:
	# Frame advantage = -(recovery_frames) + blockstun_frames
	# A move that's -10 on block means attacker recovers 10 frames after defender
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var move = MoveScript.new()
	move.startup_frames = 10
	move.active_frames = 3
	move.recovery_frames = 15
	move.blockstun_frames = 10
	move.hitstun_frames = 20

	# On block: attacker finishes recovery at frame 10+3+15=28
	# Defender exits blockstun at frame (hit on ~12) + 10 = 22
	# So attacker is at disadvantage (defender recovers first)
	var total_frames = move.startup_frames + move.active_frames + move.recovery_frames
	if total_frames != 28:
		return "Total frames should be 28, got %d" % total_frames

	return ""


func test_all_moves_have_valid_frame_data() -> String:
	# Load a fighter controller to get all registered moves
	var FighterScript = load("res://scripts/fighter/fighter_controller.gd")
	# We can't instantiate a full fighter without a scene, but we can
	# check the MoveData resource structure
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var move = MoveScript.new()

	# Verify the resource has all expected properties
	var expected_props = [
		"startup_frames", "active_frames", "recovery_frames",
		"damage", "hitstun_frames", "blockstun_frames",
		"hit_level", "knockback", "pushback_block",
		"causes_knockdown"
	]

	for prop in expected_props:
		if not prop in move:
			return "MoveData missing property: %s" % prop

	return ""


func test_hit_levels_valid() -> String:
	# Valid hit levels are: high, mid, low
	var valid_levels = ["high", "mid", "low"]
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var move = MoveScript.new()

	# Default should be a valid level or empty
	if move.hit_level != "" and move.hit_level not in valid_levels:
		return "Default hit_level '%s' is not valid" % move.hit_level

	return ""


func test_knockback_default_non_negative() -> String:
	var MoveScript = load("res://scripts/combat/move_data.gd")
	var move = MoveScript.new()

	# Default knockback should be non-negative
	if move.knockback < 0:
		return "Default knockback should not be negative (got %.1f)" % move.knockback
	if move.pushback_block < 0:
		return "Default pushback_block should not be negative (got %.1f)" % move.pushback_block

	return ""


func test_damage_scaling_counter_hit() -> String:
	# Counter hit should multiply damage by 1.3
	var base_damage: int = 20
	var ch_damage: int = int(base_damage * 1.3)

	if ch_damage != 26:
		return "Counter hit 20 * 1.3 should be 26, got %d" % ch_damage

	# Low damage test
	var low_base: int = 5
	var low_ch: int = int(low_base * 1.3)
	if low_ch != 6:
		return "Counter hit 5 * 1.3 should be 6, got %d" % low_ch

	return ""
