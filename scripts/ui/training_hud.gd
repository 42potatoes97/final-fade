extends CanvasLayer

# Training mode HUD — shows frame data, state info, input display
# Only visible in training mode

var state_label: Label
var frame_label: Label
var input_label: Label
var damage_label: Label
var mode_label: Label
var reset_hint: Label

var last_damage: int = 0
var damage_display_timer: float = 0.0
var combo_damage: int = 0
var combo_hits: int = 0
var ch_label: Label
var ch_display_timer: float = 0.0


func _ready() -> void:
	layer = 11
	if not GameManager.training_mode:
		visible = false
		set_process(false)
		return
	_build_ui()
	GameManager.health_changed.connect(_on_damage)
	GameManager.counter_hit_landed.connect(_on_counter_hit)


func _build_ui() -> void:
	# Training mode banner
	mode_label = Label.new()
	mode_label.text = "TRAINING MODE"
	mode_label.position = Vector2(20, 70)
	mode_label.add_theme_font_size_override("font_size", 20)
	mode_label.add_theme_color_override("font_color", Color(1, 0.8, 0.2))
	add_child(mode_label)

	# P1 state display (bottom left)
	state_label = Label.new()
	state_label.text = "State: Idle"
	state_label.position = Vector2(20, 900)
	state_label.add_theme_font_size_override("font_size", 16)
	add_child(state_label)

	# Frame data display
	frame_label = Label.new()
	frame_label.text = "Frame: 0"
	frame_label.position = Vector2(20, 925)
	frame_label.add_theme_font_size_override("font_size", 16)
	add_child(frame_label)

	# Input display
	input_label = Label.new()
	input_label.text = "Input: ---"
	input_label.position = Vector2(20, 950)
	input_label.add_theme_font_size_override("font_size", 16)
	add_child(input_label)

	# Damage display (center)
	damage_label = Label.new()
	damage_label.text = ""
	damage_label.position = Vector2(860, 500)
	damage_label.add_theme_font_size_override("font_size", 32)
	damage_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	add_child(damage_label)

	# Counter hit display (center, above damage)
	ch_label = Label.new()
	ch_label.text = ""
	ch_label.position = Vector2(810, 460)
	ch_label.add_theme_font_size_override("font_size", 36)
	ch_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
	add_child(ch_label)

	# Reset hint
	reset_hint = Label.new()
	reset_hint.text = "F4: Reset Position  |  ESC: Pause"
	reset_hint.position = Vector2(20, 1040)
	reset_hint.add_theme_font_size_override("font_size", 14)
	reset_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	add_child(reset_hint)


func _process(delta: float) -> void:
	if not GameManager.training_mode:
		return

	# Update state display
	var fight_scene = get_tree().current_scene
	if fight_scene and fight_scene.has_node("Fighter1"):
		var f1 = fight_scene.get_node("Fighter1")
		if f1.state_machine:
			state_label.text = "P1 State: " + f1.state_machine.get_current_state_name()
		# Show attack frame data
		var atk_state = f1.state_machine.states.get("Attack")
		if atk_state and f1.state_machine.current_state == atk_state and atk_state.current_move:
			var m = atk_state.current_move
			frame_label.text = "Frame: %d/%d  [%s] S:%d A:%d R:%d" % [
				atk_state.frame_counter, m.get_total_frames(), atk_state.phase,
				m.startup_frames, m.active_frames, m.recovery_frames
			]
		else:
			frame_label.text = ""

	# Input display
	var input = InputManager.get_input(1)
	var input_str = ""
	if input & InputManager.INPUT_FORWARD: input_str += "F "
	if input & InputManager.INPUT_BACK: input_str += "B "
	if input & InputManager.INPUT_UP: input_str += "U "
	if input & InputManager.INPUT_DOWN: input_str += "D "
	if input & InputManager.INPUT_BUTTON1: input_str += "1 "
	if input & InputManager.INPUT_BUTTON2: input_str += "2 "
	if input & InputManager.INPUT_BUTTON3: input_str += "3 "
	if input & InputManager.INPUT_BUTTON4: input_str += "4 "
	input_label.text = "Input: " + (input_str if input_str != "" else "---")

	# Damage display fade
	if damage_display_timer > 0:
		damage_display_timer -= delta
		if damage_display_timer <= 0:
			damage_label.text = ""
			combo_damage = 0
			combo_hits = 0

	# Counter hit display fade
	if ch_display_timer > 0:
		ch_display_timer -= delta
		if ch_display_timer <= 0:
			ch_label.text = ""


func _input(event: InputEvent) -> void:
	if not GameManager.training_mode:
		return
	# F4 to reset positions
	if event is InputEventKey and event.pressed and event.keycode == KEY_F4:
		_reset_positions()


func _reset_positions() -> void:
	var fight_scene = get_tree().current_scene
	if fight_scene:
		if fight_scene.has_node("Fighter1"):
			var f1 = fight_scene.get_node("Fighter1")
			f1.global_position = Vector3(-3, 0, 0)
			f1.velocity = Vector3.ZERO
			f1.state_machine.force_transition("Idle")
		if fight_scene.has_node("Fighter2"):
			var f2 = fight_scene.get_node("Fighter2")
			f2.global_position = Vector3(3, 0, 0)
			f2.velocity = Vector3.ZERO
			f2.state_machine.force_transition("Idle")
	GameManager.p1_health = GameManager.MAX_HEALTH
	GameManager.p2_health = GameManager.MAX_HEALTH
	GameManager.health_changed.emit(1, GameManager.MAX_HEALTH)
	GameManager.health_changed.emit(2, GameManager.MAX_HEALTH)


func _on_counter_hit(_attacker_id: int) -> void:
	ch_label.text = "COUNTER HIT"
	ch_display_timer = 1.5


func _on_damage(player_id: int, new_health: int) -> void:
	if player_id == 2:  # Show damage dealt to P2
		var dmg = GameManager.MAX_HEALTH - new_health
		if dmg > combo_damage:
			combo_hits += 1
			combo_damage = dmg
			if combo_hits > 1:
				damage_label.text = "%d DMG (%d hits)" % [combo_damage, combo_hits]
			else:
				damage_label.text = "%d DMG" % combo_damage
			damage_display_timer = 2.0
