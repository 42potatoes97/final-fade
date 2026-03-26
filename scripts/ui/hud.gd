extends CanvasLayer

# Fighting game HUD — health bars, timer, round counter

var p1_health_display: float = 1.0
var p2_health_display: float = 1.0
var p1_bar: ColorRect
var p2_bar: ColorRect
var p1_bar_bg: ColorRect
var p2_bar_bg: ColorRect
var p1_damage_bar: ColorRect
var p2_damage_bar: ColorRect
var timer_label: Label
var round_label: Label
var p1_wins_label: Label
var p2_wins_label: Label

const BAR_WIDTH: float = 450.0
const BAR_HEIGHT: float = 28.0
const BAR_Y: float = 30.0
const BAR_MARGIN: float = 30.0
const P1_COLOR = Color(0.15, 0.45, 0.85)
const P2_COLOR = Color(0.85, 0.2, 0.2)
const WARN_COLOR = Color(0.9, 0.75, 0.1)
const CRIT_COLOR = Color(0.9, 0.15, 0.15)
const BG_COLOR = Color(0.12, 0.12, 0.15)
const DAMAGE_COLOR = Color(0.95, 0.95, 0.3, 0.7)
const LERP_SPEED: float = 8.0
const DAMAGE_LERP_SPEED: float = 2.0

var p1_target: float = 1.0
var p2_target: float = 1.0
var p1_damage_display: float = 1.0
var p2_damage_display: float = 1.0


func _ready() -> void:
	layer = 10
	_build_hud()
	GameManager.health_changed.connect(_on_health_changed)
	GameManager.timer_updated.connect(_on_timer_updated)
	GameManager.round_ended.connect(_on_round_ended)


func _build_hud() -> void:
	var vp_w = get_viewport().get_visible_rect().size.x

	# P1 health bar background
	p1_bar_bg = _make_rect(BAR_MARGIN, BAR_Y, BAR_WIDTH, BAR_HEIGHT, BG_COLOR)
	# P1 damage trail
	p1_damage_bar = _make_rect(BAR_MARGIN, BAR_Y, BAR_WIDTH, BAR_HEIGHT, DAMAGE_COLOR)
	# P1 health bar fill
	p1_bar = _make_rect(BAR_MARGIN, BAR_Y, BAR_WIDTH, BAR_HEIGHT, P1_COLOR)

	# P2 health bar background (right-aligned)
	var p2_x = vp_w - BAR_MARGIN - BAR_WIDTH
	p2_bar_bg = _make_rect(p2_x, BAR_Y, BAR_WIDTH, BAR_HEIGHT, BG_COLOR)
	# P2 damage trail
	p2_damage_bar = _make_rect(p2_x, BAR_Y, BAR_WIDTH, BAR_HEIGHT, DAMAGE_COLOR)
	# P2 health bar fill
	p2_bar = _make_rect(p2_x, BAR_Y, BAR_WIDTH, BAR_HEIGHT, P2_COLOR)

	# P1 name
	var p1_name = Label.new()
	p1_name.text = "P1"
	p1_name.position = Vector2(BAR_MARGIN, BAR_Y - 22)
	p1_name.add_theme_font_size_override("font_size", 16)
	add_child(p1_name)

	# P2 name
	var p2_name = Label.new()
	p2_name.text = "P2"
	p2_name.position = Vector2(p2_x + BAR_WIDTH - 20, BAR_Y - 22)
	p2_name.add_theme_font_size_override("font_size", 16)
	add_child(p2_name)

	# Timer
	timer_label = Label.new()
	timer_label.text = "60"
	timer_label.position = Vector2(vp_w / 2 - 20, BAR_Y - 10)
	timer_label.add_theme_font_size_override("font_size", 36)
	add_child(timer_label)

	# Round label
	round_label = Label.new()
	round_label.text = "Round 1"
	round_label.position = Vector2(vp_w / 2 - 35, BAR_Y + BAR_HEIGHT + 5)
	round_label.add_theme_font_size_override("font_size", 14)
	add_child(round_label)

	# Win counters
	p1_wins_label = Label.new()
	p1_wins_label.text = ""
	p1_wins_label.position = Vector2(BAR_MARGIN + BAR_WIDTH + 10, BAR_Y + 2)
	p1_wins_label.add_theme_font_size_override("font_size", 18)
	add_child(p1_wins_label)

	p2_wins_label = Label.new()
	p2_wins_label.text = ""
	p2_wins_label.position = Vector2(p2_x - 40, BAR_Y + 2)
	p2_wins_label.add_theme_font_size_override("font_size", 18)
	add_child(p2_wins_label)


func _make_rect(x: float, y: float, w: float, h: float, col: Color) -> ColorRect:
	var r = ColorRect.new()
	r.position = Vector2(x, y)
	r.size = Vector2(w, h)
	r.color = col
	add_child(r)
	return r


func _process(delta: float) -> void:
	# Smooth health bar lerp
	p1_health_display = lerp(p1_health_display, p1_target, LERP_SPEED * delta)
	p2_health_display = lerp(p2_health_display, p2_target, LERP_SPEED * delta)
	# Damage trail follows slower
	p1_damage_display = lerp(p1_damage_display, p1_target, DAMAGE_LERP_SPEED * delta)
	p2_damage_display = lerp(p2_damage_display, p2_target, DAMAGE_LERP_SPEED * delta)

	# P1: fills left to right
	p1_bar.size.x = BAR_WIDTH * p1_health_display
	p1_damage_bar.size.x = BAR_WIDTH * p1_damage_display
	p1_bar.color = _health_color(p1_health_display, P1_COLOR)

	# P2: fills right to left (bar grows from right edge)
	var vp_w = get_viewport().get_visible_rect().size.x
	var p2_x = vp_w - BAR_MARGIN - BAR_WIDTH
	var p2_fill = BAR_WIDTH * p2_health_display
	var p2_dmg_fill = BAR_WIDTH * p2_damage_display
	p2_bar.position.x = p2_x + BAR_WIDTH - p2_fill
	p2_bar.size.x = p2_fill
	p2_damage_bar.position.x = p2_x + BAR_WIDTH - p2_dmg_fill
	p2_damage_bar.size.x = p2_dmg_fill
	p2_bar.color = _health_color(p2_health_display, P2_COLOR)


func _health_color(ratio: float, base: Color) -> Color:
	if ratio < 0.15:
		return CRIT_COLOR
	elif ratio < 0.30:
		return WARN_COLOR
	return base


func _on_health_changed(player_id: int, new_health: int) -> void:
	var ratio = float(new_health) / float(GameManager.MAX_HEALTH)
	if player_id == 1:
		p1_target = ratio
	else:
		p2_target = ratio


func _on_timer_updated(time_remaining: float) -> void:
	timer_label.text = str(int(ceil(time_remaining)))


func _on_round_ended(winner_id: int) -> void:
	round_label.text = "Round " + str(GameManager.current_round)
	_update_wins()


func _update_wins() -> void:
	# Show win dots
	p1_wins_label.text = "O".repeat(GameManager.p1_round_wins)
	p2_wins_label.text = "O".repeat(GameManager.p2_round_wins)
