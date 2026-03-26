extends Node

# Game manager singleton — handles round logic, health, game state
# Will later handle serialization for rollback netcode and RL step()

enum GameState {
	MENU,
	ROUND_INTRO,
	FIGHTING,
	ROUND_END,
	MATCH_END
}

const MAX_HEALTH: int = 170
const ROUND_TIME: int = 60  # seconds
const ROUNDS_TO_WIN: int = 3

var state: GameState = GameState.FIGHTING  # Start in FIGHTING for prototype
var training_mode: bool = false
var ai_mode: bool = false
var online_mode: bool = false
var ai_difficulty: Dictionary = {}  # block_rate, attack_rate, punish_rate
var selected_stage: String = "res://scenes/stages/stage_medium.tscn"

# Fighter classes
enum FighterClass { DEFENSIVE, OFFENSIVE }

# Player customization
var p1_skin_color: Color = Color(0.85, 0.7, 0.55)
var p1_torso_color: Color = Color(0.2, 0.2, 0.6)
var p1_fighter_class: FighterClass = FighterClass.DEFENSIVE
var p2_skin_color: Color = Color(0.85, 0.7, 0.55)
var p2_torso_color: Color = Color(0.6, 0.2, 0.2)
var p2_fighter_class: FighterClass = FighterClass.DEFENSIVE

# Device assignments — set on character select
var p1_device_type: int = 0  # InputManager.DeviceType.KEYBOARD
var p1_device_id: int = -1
var p2_device_type: int = 0
var p2_device_id: int = -1

var p1_health: int = MAX_HEALTH
var p2_health: int = MAX_HEALTH
var p1_round_wins: int = 0
var p2_round_wins: int = 0
var p1_match_wins: int = 0
var p2_match_wins: int = 0
var current_round: int = 1
var round_timer: float = ROUND_TIME

signal health_changed(player_id: int, new_health: int)
signal round_ended(winner_id: int)
signal match_ended(winner_id: int)
signal timer_updated(time_remaining: float)
signal counter_hit_landed(attacker_id: int)


func _physics_process(delta: float) -> void:
	# During online rollback, RollbackManager drives timer via manual_tick
	if online_mode:
		return
	manual_tick(delta)


func manual_tick(delta: float) -> void:
	if state != GameState.FIGHTING:
		return

	if training_mode:
		# Infinite time, auto-heal in training
		round_timer = ROUND_TIME
		_training_regen()
		return

	round_timer -= delta
	timer_updated.emit(round_timer)

	if round_timer <= 0:
		round_timer = 0
		_time_over()


func _training_regen() -> void:
	# Slowly regenerate health in training mode
	if p1_health < MAX_HEALTH:
		p1_health = min(MAX_HEALTH, p1_health + 1)
		health_changed.emit(1, p1_health)
	if p2_health < MAX_HEALTH:
		p2_health = min(MAX_HEALTH, p2_health + 1)
		health_changed.emit(2, p2_health)


func apply_damage(player_id: int, damage: int) -> void:
	if state != GameState.FIGHTING:
		return

	if player_id == 1:
		p1_health = max(0, p1_health - damage)
		health_changed.emit(1, p1_health)
		if p1_health <= 0:
			_round_win(2)
	else:
		p2_health = max(0, p2_health - damage)
		health_changed.emit(2, p2_health)
		if p2_health <= 0:
			_round_win(1)


func _time_over() -> void:
	if p1_health > p2_health:
		_round_win(1)
	elif p2_health > p1_health:
		_round_win(2)
	else:
		# Draw — both players get a round win
		_round_draw()


func _round_win(winner_id: int) -> void:
	state = GameState.ROUND_END
	if winner_id == 1:
		p1_round_wins += 1
	else:
		p2_round_wins += 1
	round_ended.emit(winner_id)

	if p1_round_wins >= ROUNDS_TO_WIN:
		state = GameState.MATCH_END
		p1_match_wins += 1
		match_ended.emit(1)
	elif p2_round_wins >= ROUNDS_TO_WIN:
		state = GameState.MATCH_END
		p2_match_wins += 1
		match_ended.emit(2)
	else:
		# Brief delay then next round (handled by fight_scene)
		pass


func _round_draw() -> void:
	state = GameState.ROUND_END
	p1_round_wins += 1
	p2_round_wins += 1
	round_ended.emit(0)  # 0 = draw

	# Check if either (or both) hit the win threshold
	var p1_wins = p1_round_wins >= ROUNDS_TO_WIN
	var p2_wins = p2_round_wins >= ROUNDS_TO_WIN
	if p1_wins and p2_wins:
		# Both reach threshold on draw — both get match win
		state = GameState.MATCH_END
		p1_match_wins += 1
		p2_match_wins += 1
		match_ended.emit(0)  # 0 = draw match
	elif p1_wins:
		state = GameState.MATCH_END
		p1_match_wins += 1
		match_ended.emit(1)
	elif p2_wins:
		state = GameState.MATCH_END
		p2_match_wins += 1
		match_ended.emit(2)


func start_next_round() -> void:
	current_round += 1
	p1_health = MAX_HEALTH
	p2_health = MAX_HEALTH
	round_timer = ROUND_TIME
	state = GameState.FIGHTING
	health_changed.emit(1, p1_health)
	health_changed.emit(2, p2_health)


func reset_match() -> void:
	# Resets round state for a new FT3 set, preserves match wins
	p1_health = MAX_HEALTH
	p2_health = MAX_HEALTH
	p1_round_wins = 0
	p2_round_wins = 0
	current_round = 1
	round_timer = ROUND_TIME
	state = GameState.FIGHTING


func reset_session() -> void:
	# Full reset — clears everything including match wins (used on return to menu)
	reset_match()
	p1_match_wins = 0
	p2_match_wins = 0


# Serialization for future rollback netcode and RL
func get_game_state() -> Dictionary:
	return {
		"state": state,
		"p1_health": p1_health,
		"p2_health": p2_health,
		"p1_round_wins": p1_round_wins,
		"p2_round_wins": p2_round_wins,
		"current_round": current_round,
		"round_timer": round_timer,
	}


func set_game_state(s: Dictionary) -> void:
	state = s["state"]
	p1_health = s["p1_health"]
	p2_health = s["p2_health"]
	p1_round_wins = s["p1_round_wins"]
	p2_round_wins = s["p2_round_wins"]
	current_round = s["current_round"]
	round_timer = s["round_timer"]
