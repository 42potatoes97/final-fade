extends Node

# AI opponent with difficulty-driven behaviors
# Each tier adds new capabilities on top of the previous:
#   EASY    — punching bag, rarely acts
#   NORMAL  — sparring partner, basic blocking/poking
#   HARD    — competitor, punishes mistakes, uses movement
#   BRUTAL  — frame trap machine, wavedash/KBD, near-optimal play

var fighter: Node = null
var opponent: Node = null
var difficulty: String = "NORMAL"
var fighter_class: String = ""  # "DEFENSIVE" or "OFFENSIVE"

# --- Tier parameters (configured in _configure_difficulty) ---
var block_rate: float = 0.5
var crouch_block_rate: float = 0.0    # Chance to crouch-block incoming lows
var attack_rate: float = 0.04         # Per-frame chance to attack at close range
var punish_rate: float = 0.5
var punish_optimal: bool = false      # Use best punish vs just jab
var use_backdash: bool = false
var use_sidestep: bool = false
var use_wavedash: bool = false
var use_frame_traps: bool = false
var use_oki: bool = false
var vary_wakeup: bool = false
var decision_delay: int = 15          # Min frames between decisions (reaction speed)

# --- Internal state ---
var _current_action: int = 0
var _action_duration: int = 0
var _decision_cooldown: int = 0
var _blocking: bool = false
var _post_block_frames: int = 0
var _last_blocked_move: Resource = null
var _input_sequence: Array = []       # [{bits: int, frames: int}] for multi-frame inputs
var _post_hit_frames: int = 0         # Frames since landing a KD (for oki)
var _landed_knockdown: bool = false
var _frame_trap_queued: bool = false   # After + on block move, queue a follow-up


func _ready() -> void:
	_configure_difficulty()


func _configure_difficulty() -> void:
	match difficulty:
		"EASY":
			block_rate = 0.15
			crouch_block_rate = 0.0
			attack_rate = 0.015
			punish_rate = 0.0
			punish_optimal = false
			use_backdash = false
			use_sidestep = false
			use_wavedash = false
			use_frame_traps = false
			use_oki = false
			vary_wakeup = false
			decision_delay = 25
		"NORMAL":
			block_rate = 0.5
			crouch_block_rate = 0.1
			attack_rate = 0.035
			punish_rate = 0.4
			punish_optimal = false
			use_backdash = false
			use_sidestep = true
			use_wavedash = false
			use_frame_traps = false
			use_oki = false
			vary_wakeup = false
			decision_delay = 15
		"HARD":
			block_rate = 0.8
			crouch_block_rate = 0.5
			attack_rate = 0.05
			punish_rate = 0.8
			punish_optimal = true
			use_backdash = true
			use_sidestep = true
			use_wavedash = false
			use_frame_traps = false
			use_oki = true
			vary_wakeup = true
			decision_delay = 8
		"BRUTAL":
			block_rate = 0.95
			crouch_block_rate = 0.85
			attack_rate = 0.06
			punish_rate = 1.0
			punish_optimal = true
			use_backdash = true
			use_sidestep = true
			use_wavedash = true
			use_frame_traps = true
			use_oki = true
			vary_wakeup = true
			decision_delay = 4


func get_input() -> int:
	if fighter == null or opponent == null:
		return 0

	# Execute queued input sequences (wavedash, KBD, etc.)
	if not _input_sequence.is_empty():
		var step = _input_sequence[0]
		step.frames -= 1
		if step.frames <= 0:
			_input_sequence.pop_front()
		return step.bits

	_action_duration -= 1
	_decision_cooldown -= 1

	var my_state = _get_my_state()

	# --- Track post-blockstun for punishing ---
	if my_state == "Blockstun":
		_blocking = true
		_post_block_frames = 0
		# Remember what move we blocked
		_last_blocked_move = _get_opponent_current_move()
	elif _blocking and my_state == "Idle":
		_blocking = false
		_post_block_frames = 1

	if _post_block_frames > 0 and _post_block_frames < 15:
		_post_block_frames += 1

	# --- Track post-KD for oki ---
	if _landed_knockdown:
		_post_hit_frames += 1
		var opp_state = _get_opponent_state()
		if opp_state != "Knockdown" and opp_state != "Getup" and opp_state != "SideRoll":
			_landed_knockdown = false
			_post_hit_frames = 0

	# --- Punish window (just exited blockstun) ---
	if _post_block_frames >= 1 and _post_block_frames <= 4 and my_state == "Idle":
		if _is_opponent_in_recovery() and randf() < punish_rate:
			_post_block_frames = 99
			return _get_punish_input()

	# --- Post-block sidestep (HARD+) ---
	if _post_block_frames >= 3 and _post_block_frames <= 6 and my_state == "Idle":
		if use_sidestep and not _is_opponent_in_recovery():
			var opp_move = _last_blocked_move
			if opp_move and not opp_move.is_homing and randf() < 0.4:
				_post_block_frames = 99
				_current_action = InputManager.INPUT_UP if randf() > 0.5 else InputManager.INPUT_DOWN
				_action_duration = 2
				_decision_cooldown = 12
				return _current_action

	# --- Post-block backdash (HARD+) ---
	if _post_block_frames >= 2 and _post_block_frames <= 5 and my_state == "Idle":
		if use_backdash and randf() < 0.25:
			_post_block_frames = 99
			_queue_backdash()
			return _input_sequence[0].bits if not _input_sequence.is_empty() else 0

	# --- Frame trap follow-up (BRUTAL) ---
	if _frame_trap_queued and my_state == "Idle":
		_frame_trap_queued = false
		return _get_frame_trap_followup()

	# Hold current action
	if _action_duration > 0:
		return _current_action

	# --- Can't act in these states ---
	if my_state in ["Hitstun", "Blockstun"]:
		_current_action = 0
		_action_duration = 3
		return 0

	# --- Wakeup decisions ---
	if my_state == "Knockdown":
		return _decide_wakeup()

	if my_state in ["Getup", "GetupKick", "SideRoll"]:
		return 0

	if _decision_cooldown > 0:
		_current_action = 0
		return 0

	# --- Oki pressure (HARD+) ---
	if use_oki and _landed_knockdown and _get_opponent_state() == "Knockdown":
		return _decide_oki()

	return _decide()


# ============================================================
# CORE DECISION (neutral game)
# ============================================================
func _decide() -> int:
	var dist = _get_distance()
	var opp_state = _get_opponent_state()
	var bits: int = 0

	# --- REACT: Block opponent's attack ---
	if opp_state == "Attack" and dist < 3.5:
		return _decide_block()

	# --- FAR RANGE (>4.0) ---
	if dist > 4.0:
		# BRUTAL: wavedash approach
		if use_wavedash and randf() < 0.3:
			_queue_wavedash()
			return _input_sequence[0].bits if not _input_sequence.is_empty() else 0
		# Walk forward
		if randf() < 0.35:
			bits = InputManager.INPUT_FORWARD
			_action_duration = randi_range(12, 35)
		else:
			bits = 0
			_action_duration = randi_range(8, 20)
		_current_action = bits
		return bits

	# --- MID RANGE (2.5-4.0) ---
	if dist > 2.5:
		var roll = randf()
		if roll < attack_rate * 2:
			bits = _pick_attack()
			_action_duration = 1
			_decision_cooldown = decision_delay
		elif use_wavedash and roll < attack_rate * 2 + 0.05:
			_queue_wavedash()
			return _input_sequence[0].bits if not _input_sequence.is_empty() else 0
		elif roll < attack_rate * 2 + 0.08:
			bits = InputManager.INPUT_FORWARD
			_action_duration = randi_range(8, 18)
		else:
			bits = 0
			_action_duration = randi_range(6, 15)
		_current_action = bits
		return bits

	# --- CLOSE RANGE (<2.5) ---
	var roll = randf()
	if roll < attack_rate:
		bits = _pick_attack()
		_action_duration = 1
		_decision_cooldown = decision_delay
	elif use_backdash and roll < attack_rate + 0.02:
		_queue_backdash()
		return _input_sequence[0].bits if not _input_sequence.is_empty() else 0
	elif use_sidestep and roll < attack_rate + 0.04:
		bits = InputManager.INPUT_UP if randf() > 0.5 else InputManager.INPUT_DOWN
		_action_duration = 2
		_decision_cooldown = 12
	elif roll < attack_rate + 0.06:
		bits = InputManager.INPUT_BACK
		_action_duration = randi_range(3, 8)
	else:
		bits = 0
		_action_duration = randi_range(5, 12)

	_current_action = bits
	return bits


# ============================================================
# BLOCKING
# ============================================================
func _decide_block() -> int:
	if randf() > block_rate:
		# Failed to react — just stand there or keep doing current action
		_action_duration = randi_range(3, 8)
		return _current_action

	# Check if opponent's attack is low — crouch block if we can read it
	var opp_move = _get_opponent_current_move()
	if opp_move and opp_move.hit_level == "low" and randf() < crouch_block_rate:
		_current_action = InputManager.INPUT_DOWN | InputManager.INPUT_BACK
		_action_duration = randi_range(8, 16)
		_decision_cooldown = 4
		return _current_action

	# Standing block
	_current_action = InputManager.INPUT_BACK
	_action_duration = randi_range(8, 20)
	_decision_cooldown = 4
	return _current_action


# ============================================================
# PUNISHING
# ============================================================
func _get_punish_input() -> int:
	if not punish_optimal:
		# Basic: just jab
		_current_action = InputManager.INPUT_BUTTON1
		_action_duration = 1
		_decision_cooldown = decision_delay
		return _current_action

	# Optimal: pick best punish based on frame advantage
	# Check how unsafe the blocked move was
	var opp_move = _last_blocked_move
	if opp_move == null:
		_current_action = InputManager.INPUT_BUTTON1
		_action_duration = 1
		_decision_cooldown = decision_delay
		return _current_action

	var frame_disadvantage = opp_move.blockstun_frames - opp_move.recovery_frames
	# Very unsafe (-10 or worse): use slower, higher damage move
	if frame_disadvantage <= -10:
		if fighter_class == "DEFENSIVE":
			# df+1 mid check (i11) or d+1 (i12) for solid damage
			_current_action = InputManager.INPUT_DOWN | InputManager.INPUT_FORWARD | InputManager.INPUT_BUTTON1
		else:
			# d+4 low opener (i11) into string
			_current_action = InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON4
	else:
		# Mildly unsafe: jab punish
		_current_action = InputManager.INPUT_BUTTON1

	_action_duration = 1
	_decision_cooldown = decision_delay
	return _current_action


# ============================================================
# ATTACK SELECTION (class-aware)
# ============================================================
func _pick_attack() -> int:
	var attacks: Array = []

	if fighter_class == "DEFENSIVE":
		attacks = [
			InputManager.INPUT_BUTTON1,                                        # 1 jab (safe, chains)
			InputManager.INPUT_BUTTON1,                                        # weighted jab
			InputManager.INPUT_DOWN | InputManager.INPUT_FORWARD | InputManager.INPUT_BUTTON1,  # df+1 mid check
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON1,              # d+1 tracking mid
			InputManager.INPUT_BUTTON3,                                        # 3 low kick
			InputManager.INPUT_BUTTON4,                                        # 4 roundhouse (KD)
		]
	elif fighter_class == "OFFENSIVE":
		attacks = [
			InputManager.INPUT_BUTTON1,                                        # 1 jab
			InputManager.INPUT_BUTTON3,                                        # 3 low kick
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON4,              # d+4 low opener (chains)
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON4,              # weighted d+4
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON3,              # d+3 sweep
			InputManager.INPUT_BUTTON4,                                        # 4 roundhouse (chains to 4,4)
		]
	else:
		# Fallback: shared moves only
		attacks = [
			InputManager.INPUT_BUTTON1,
			InputManager.INPUT_BUTTON3,
			InputManager.INPUT_BUTTON4,
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON3,
		]

	# Occasionally throw overhead slam (risky but high reward)
	if randf() < 0.08:
		return InputManager.INPUT_BUTTON2

	# Frame trap: after landing this attack, queue a follow-up if it's + on block
	if use_frame_traps:
		_frame_trap_queued = true

	return attacks[randi() % attacks.size()]


# ============================================================
# FRAME TRAPS (BRUTAL)
# ============================================================
func _get_frame_trap_followup() -> int:
	# After a + on block move, press another attack to catch mashing
	_decision_cooldown = decision_delay
	_action_duration = 1

	if fighter_class == "DEFENSIVE":
		# After 1,1 (+4): df+1 (i11) catches anything slower than i7
		var options = [
			InputManager.INPUT_DOWN | InputManager.INPUT_FORWARD | InputManager.INPUT_BUTTON1,  # df+1
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON1,  # d+1 tracking
			InputManager.INPUT_BUTTON1,  # jab to continue pressure
		]
		_current_action = options[randi() % options.size()]
	else:
		# OFF: after jab, go low
		var options = [
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON4,  # d+4 low
			InputManager.INPUT_DOWN | InputManager.INPUT_BUTTON3,  # d+3 sweep
			InputManager.INPUT_BUTTON3,  # 3 low kick
		]
		_current_action = options[randi() % options.size()]

	return _current_action


# ============================================================
# WAKEUP DECISIONS
# ============================================================
func _decide_wakeup() -> int:
	if not vary_wakeup:
		# EASY/NORMAL: always quick getup
		_current_action = InputManager.INPUT_BACK
		_action_duration = 1
		return _current_action

	# HARD/BRUTAL: mix wakeup options based on attacker distance
	var dist = _get_distance()
	var roll = randf()

	if dist > 3.0:
		# Attacker is far — safe to quick getup
		_current_action = InputManager.INPUT_BACK
		_action_duration = 1
	elif roll < 0.5:
		# Quick getup (block on wakeup)
		_current_action = InputManager.INPUT_BACK
		_action_duration = 1
	elif roll < 0.7:
		# Getup kick (risky but beats oki pressure)
		_current_action = InputManager.INPUT_BUTTON3
		_action_duration = 1
	elif roll < 0.85:
		# Side roll (escape corner/pressure)
		_current_action = InputManager.INPUT_UP if randf() > 0.5 else InputManager.INPUT_DOWN
		_action_duration = 1
	else:
		# Stay down briefly (bait whiff)
		_current_action = 0
		_action_duration = randi_range(5, 15)

	return _current_action


# ============================================================
# OKI PRESSURE (HARD+)
# ============================================================
func _decide_oki() -> int:
	var dist = _get_distance()

	if dist > 3.5:
		# Too far for oki — walk forward
		_current_action = InputManager.INPUT_FORWARD
		_action_duration = randi_range(5, 12)
		return _current_action

	# At oki range — mix between meaty attack and bait
	var roll = randf()
	if roll < 0.4:
		# Meaty attack timed for wakeup
		_current_action = _pick_attack()
		_action_duration = 1
		_decision_cooldown = decision_delay
	elif roll < 0.6:
		# Walk forward and block (bait getup kick)
		_current_action = 0
		_action_duration = randi_range(8, 16)
	else:
		# Shimmy — walk back slightly then attack
		_current_action = InputManager.INPUT_BACK
		_action_duration = randi_range(3, 6)
		_decision_cooldown = 6

	return _current_action


# ============================================================
# MOVEMENT SEQUENCES (wavedash, backdash, KBD)
# ============================================================
func _queue_wavedash() -> void:
	# f, n, d, df sequence — crouch dash approach
	_input_sequence = [
		{"bits": InputManager.INPUT_FORWARD, "frames": 2},
		{"bits": 0, "frames": 1},
		{"bits": InputManager.INPUT_DOWN, "frames": 2},
		{"bits": InputManager.INPUT_DOWN | InputManager.INPUT_FORWARD, "frames": 3},
	]
	_action_duration = 0
	_decision_cooldown = 10


func _queue_backdash() -> void:
	# b, b — double tap back for backdash
	_input_sequence = [
		{"bits": InputManager.INPUT_BACK, "frames": 2},
		{"bits": 0, "frames": 2},
		{"bits": InputManager.INPUT_BACK, "frames": 2},
	]
	_action_duration = 0
	_decision_cooldown = 15


func _queue_kbd() -> void:
	# Backdash → d,b → backdash (Korean backdash cancel)
	_input_sequence = [
		{"bits": InputManager.INPUT_BACK, "frames": 2},
		{"bits": 0, "frames": 2},
		{"bits": InputManager.INPUT_BACK, "frames": 2},
		# KBD cancel window
		{"bits": InputManager.INPUT_DOWN, "frames": 2},
		{"bits": InputManager.INPUT_BACK, "frames": 2},
		{"bits": 0, "frames": 2},
		{"bits": InputManager.INPUT_BACK, "frames": 2},
	]
	_action_duration = 0
	_decision_cooldown = 20


# ============================================================
# STATE READERS
# ============================================================
func _get_distance() -> float:
	if fighter and opponent:
		return fighter.global_position.distance_to(opponent.global_position)
	return 5.0


func _get_my_state() -> String:
	if fighter and fighter.state_machine:
		return fighter.state_machine.current_state_name()
	return ""


func _get_opponent_state() -> String:
	if opponent and opponent.state_machine:
		return opponent.state_machine.current_state_name()
	return ""


func _get_opponent_current_move() -> Resource:
	if opponent and opponent.state_machine:
		var atk = opponent.state_machine.states.get("Attack")
		if atk and opponent.state_machine.current_state == atk:
			return atk.current_move
	return null


func _is_opponent_in_recovery() -> bool:
	if opponent and opponent.state_machine:
		var atk = opponent.state_machine.states.get("Attack")
		if atk and opponent.state_machine.current_state == atk:
			return atk.phase == "recovery"
	return false
