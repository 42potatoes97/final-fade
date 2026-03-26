class_name BackdashState
extends FighterState

# Backdash: quick backward burst (b, b input)
# Korean Backdash Cancel (KBD): cancel recovery into another backdash
# Input: b,b -> during recovery, b,n,b (or d/b,b) to cancel into new backdash

const DASH_SPEED: float = 8.5  # Fast burst
const DASH_DURATION: int = 24  # Shorter total
const ACTIVE_FRAMES: int = 8   # Quick burst then recovery
const KBD_WINDOW_START: int = 10  # Earliest frame to cancel with d/b
const KBD_WINDOW_END: int = 18  # Latest frame to cancel — miss this and you eat full recovery
const RECOVERY_START: int = 10  # Recovery begins here
const INVULN_START: int = 3    # Invulnerability begins
const INVULN_END: int = 8      # Invulnerability ends

var frame_counter: int = 0
var saw_down_alone: bool = false  # d without back = backsway path
var saw_db: bool = false  # d/b pressed = KBD path
var db_released_to_neutral: bool = false  # Released d/b to neutral = "free back" input


func enter(_prev_state: String) -> void:
	frame_counter = 0
	saw_down_alone = false
	saw_db = false
	db_released_to_neutral = false
	fighter.is_crouching = false
	fighter.is_invulnerable = false


func exit() -> void:
	fighter.is_invulnerable = false


func save_state() -> Dictionary:
	return {"fc": frame_counter, "sd": saw_down_alone, "sdb": saw_db, "dbr": db_released_to_neutral}

func load_state(s: Dictionary) -> void:
	frame_counter = s.get("fc", 0)
	saw_down_alone = s.get("sd", false)
	saw_db = s.get("sdb", false)
	db_released_to_neutral = s.get("dbr", false)


func handle_input(input_bits: int) -> String:
	var IM = InputManager
	var buf = fighter.input_buffer
	var holding_down = IM.has_flag(input_bits, IM.INPUT_DOWN)
	var holding_back = IM.has_flag(input_bits, IM.INPUT_BACK)

	# During active frames (burst movement) — no cancels, commit to the dash
	if frame_counter < KBD_WINDOW_START:
		return ""

	# Track input sequence for KBD vs Backsway
	# KBD (old Tekken style):  b,b → d/b → release to neutral/b → new backdash
	# Backsway:                b,b → d (alone) → d/b → b  (QCB motion)

	if holding_down and not holding_back:
		saw_down_alone = true  # d alone = backsway path

	if holding_down and holding_back:
		saw_db = true  # d/b = KBD cancel
		fighter.is_crouching = true

	# Detect d/b released to neutral (the "free back" input in Tekken)
	if saw_db and not holding_down and not holding_back:
		db_released_to_neutral = true

	# --- Backsway: d alone at any point = sloppy KBD, punish with backsway ---
	# Like Nina in old Tekken — pressing d instead of d/b gives backsway
	if saw_down_alone and (holding_back and not holding_down):
		return "Backsway"
	if saw_down_alone and saw_db and holding_back and not holding_down:
		return "Backsway"

	# --- KBD: d/b during cancel window, then release ---
	var in_kbd_window = frame_counter >= KBD_WINDOW_START and frame_counter <= KBD_WINDOW_END

	if saw_db and not saw_down_alone and in_kbd_window:
		# Option 1: Released d/b to neutral — "free back" triggers new backdash
		if db_released_to_neutral:
			return "Backdash"
		# Option 2: Released down while holding back (d/b → b transition)
		if holding_back and not holding_down:
			return "Backdash"

	# No raw b,b during backdash — must use proper KBD cancel

	# Cancel into sidestep (both directions)
	if buf.just_pressed(IM.INPUT_UP):
		return "SidestepUp"
	if buf.just_pressed(IM.INPUT_DOWN):
		return "SidestepDown"

	# Cancel into forward dash
	if buf.detect_double_tap(IM.INPUT_FORWARD):
		return "DashForward"

	# Cancel into attack
	var attack_result = try_attack(input_bits)
	if attack_result != "":
		return attack_result

	return ""


func tick(_delta: float) -> String:
	frame_counter += 1

	# Invulnerability during active burst (frames 3-8)
	fighter.is_invulnerable = frame_counter >= INVULN_START and frame_counter <= INVULN_END

	if frame_counter >= DASH_DURATION:
		# Set cooldown — can't raw backdash again immediately, must KBD
		fighter.backdash_cooldown = fighter.BACKDASH_COOLDOWN_FRAMES
		return "Idle"

	var progress = float(frame_counter) / DASH_DURATION
	var m = get_model()
	if m:
		m.set_pose_backdash(progress)

	var backward_dir = -fighter.get_forward_direction()

	if frame_counter <= ACTIVE_FRAMES:
		# Fast backward burst
		var speed_factor = 1.0 - (float(frame_counter) / ACTIVE_FRAMES) * 0.3
		fighter.velocity = backward_dir * DASH_SPEED * speed_factor
	else:
		# Recovery — slowing down significantly
		var recovery_progress = float(frame_counter - ACTIVE_FRAMES) / (DASH_DURATION - ACTIVE_FRAMES)
		fighter.velocity = backward_dir * DASH_SPEED * 0.2 * (1.0 - recovery_progress)

	fighter.velocity.y = 0
	fighter.move_and_slide()
	return ""
