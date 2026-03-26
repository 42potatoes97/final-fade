extends FighterState

# Getup kick — rising attack from the ground
# Uses roundhouse kick animation (same as button 4)
# Punishable on block (-16), rewards the attacker for not pressing buttons on oki

const STARTUP_FRAMES: int = 12  # Slower than standing — rising from ground
const ACTIVE_FRAMES: int = 4
const RECOVERY_FRAMES: int = 16  # Very punishable

var frame_counter: int = 0
var has_hit: bool = false


func save_state() -> Dictionary:
	return {"fc": frame_counter, "hh": has_hit}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	has_hit = s.get("hh", false)


func enter(_prev_state: String) -> void:
	frame_counter = 0
	has_hit = false
	fighter.velocity = Vector3.ZERO
	fighter.is_crouching = false
	fighter.is_blocking_on_getup = false  # Committed to attack, not blocking

	# Activate hit system
	if fighter.has_node("HitSystem"):
		fighter.get_node("HitSystem").activate("high_kick")


func exit() -> void:
	if fighter.has_node("HitSystem"):
		fighter.get_node("HitSystem").deactivate()


func handle_input(_input_bits: int) -> String:
	return ""


func tick(_delta: float) -> String:
	frame_counter += 1
	var total = STARTUP_FRAMES + ACTIVE_FRAMES + RECOVERY_FRAMES

	if frame_counter > total:
		return "Idle"

	# Animation — blend from knockdown pose to standing kick
	var progress = clampf(float(frame_counter) / total, 0.0, 1.0)
	var m = get_model()
	if m:
		m.set_pose_getup_kick(progress)

	# Hit detection during active frames
	if frame_counter > STARTUP_FRAMES and frame_counter <= STARTUP_FRAMES + ACTIVE_FRAMES and not has_hit:
		if fighter.has_node("HitSystem"):
			var hit = fighter.get_node("HitSystem").check_hit()
			if not hit.is_empty():
				has_hit = true
				# Apply hit manually — mid level, knockback
				var defender = hit["defender"] as CharacterBody3D
				var blocked = hit["blocked"]

				fighter.hitstop_remaining = 6
				defender.hitstop_remaining = 6

				if blocked:
					if defender.state_machine:
						defender.state_machine.enter_blockstun(12)
				else:
					GameManager.apply_damage(defender.player_id, 15)
					if defender.state_machine:
						defender.state_machine.enter_hitstun(18)
					# Knockback
					var kb_dir = fighter.get_forward_direction()
					defender.velocity = kb_dir * 2.0

	fighter.velocity.x = 0
	fighter.velocity.z = 0
	fighter.move_and_slide()
	return ""
