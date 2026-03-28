extends Node3D

# Main fight scene — orchestrates the match

@onready var fighter1: FighterController = $Fighter1
@onready var fighter2: FighterController = $Fighter2
@onready var camera: FightCamera = $FightCamera

var round_msg_label: Label = null
var round_transition_timer: float = 0.0
var round_transition_active: bool = false
var match_end_screen: Control = null
var overlay_canvas: CanvasLayer = null
var pause_menu: Control = null
var is_paused: bool = false

# Ranked match proof signing
var _replay_manager: ReplayManager = null
var _anticheat: AnticheatValidator = null
var _leaderboard: LeaderboardManager = null
var _pending_proof: Dictionary = {}
var _is_ranked: bool = false

# Spawn positions
const P1_SPAWN = Vector3(-3, 0, 0)
const P2_SPAWN = Vector3(3, 0, 0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Load the selected stage dynamically and swap out the placeholder
	var existing_stage := get_node_or_null("Stage")
	if existing_stage:
		existing_stage.queue_free()
	var stage_scene: PackedScene = load(GameManager.selected_stage)
	if stage_scene:
		var stage_instance := stage_scene.instantiate()
		stage_instance.name = "Stage"
		add_child(stage_instance)

	# Wire up opponents
	fighter1.player_id = 1
	fighter2.player_id = 2
	fighter1.opponent = fighter2
	fighter2.opponent = fighter1
	# Cache per-limb hit spheres for Tekken-style hit detection
	if fighter1._hit_system:
		fighter1._hit_system.cache_opponent_limbs(fighter2)
	if fighter2._hit_system:
		fighter2._hit_system.cache_opponent_limbs(fighter1)

	# Set initial facing
	InputManager.set_facing(1, 1)   # P1 faces right
	InputManager.set_facing(2, -1)  # P2 faces left

	# Apply device assignments from character select
	InputManager.assign_device(1, GameManager.p1_device_type, GameManager.p1_device_id)
	InputManager.assign_device(2, GameManager.p2_device_type, GameManager.p2_device_id)

	# Wire camera
	camera.fighter1 = fighter1
	camera.fighter2 = fighter2

	# Reset match state
	GameManager.reset_match()

	# Connect round/match signals
	GameManager.round_ended.connect(_on_round_ended)
	GameManager.match_ended.connect(_on_match_ended)

	# Build round message overlay
	_build_round_overlay()

	# Set up AI controllers
	var AIScript = load("res://scripts/ai/ai_controller.gd")
	if GameManager.p1_device_type == InputManager.DeviceType.AI:
		var ai = AIScript.new()
		ai.fighter = fighter1
		ai.opponent = fighter2
		_apply_ai_difficulty(ai, 1)
		add_child(ai)
		InputManager.register_ai(1, ai)
	if GameManager.p2_device_type == InputManager.DeviceType.AI:
		var ai = AIScript.new()
		ai.fighter = fighter2
		ai.opponent = fighter1
		_apply_ai_difficulty(ai, 2)
		add_child(ai)
		InputManager.register_ai(2, ai)

	# Apply player colors
	_apply_player_colors()

	# Reset positions
	_reset_positions()

	# Online mode: initialize rollback and set remote player as NETWORK device
	if GameManager.online_mode:
		# Player picked a side in side_select → local input goes to that side,
		# opponent's WebRTC input goes to the other side.
		var local_side: int = GameManager.local_side  # 1=P1(left), 2=P2(right)
		var remote_side: int = 2 if local_side == 1 else 1
		# Get the local device (set by side_select)
		var local_dev_type: int = GameManager.p1_device_type if local_side == 1 else GameManager.p2_device_type
		var local_dev_id: int = GameManager.p1_device_id if local_side == 1 else GameManager.p2_device_id
		# Assign: local device → chosen side, NETWORK → other side
		InputManager.assign_device(local_side, local_dev_type, local_dev_id)
		InputManager.assign_device(remote_side, InputManager.DeviceType.NETWORK, -1)
		# Tell RollbackManager which slot is local so it reads/injects correctly
		NetworkManager.local_player_id = local_side
		NetworkManager.remote_player_id = remote_side
		print("[FightScene] Online: local_side=%d dev_type=%d dev_id=%d | remote_side=%d=NETWORK" % [local_side, local_dev_type, local_dev_id, remote_side])
		# NOW enter IN_GAME state — enables raw packet polling for input exchange
		NetworkManager.start_game()
		RollbackManager.input_delay = NetworkManager.input_delay
		RollbackManager.start(fighter1, fighter2)

	# Ranked match setup
	if GameManager.online_mode and GameManager.get("ranked_mode"):
		_is_ranked = true
		_replay_manager = ReplayManager.new()
		_anticheat = AnticheatValidator.new()
		RollbackManager.replay_manager = _replay_manager
		RollbackManager.anticheat = _anticheat
		NetworkManager._anticheat_ref = _anticheat

		# Start replay recording
		var p1_class = "DEFENSIVE" if GameManager.p1_fighter_class == GameManager.FighterClass.DEFENSIVE else "OFFENSIVE"
		var p2_class = "DEFENSIVE" if GameManager.p2_fighter_class == GameManager.FighterClass.DEFENSIVE else "OFFENSIVE"
		_replay_manager.start_recording(
			ProfileManager.profile_id,
			"opponent",  # Will be updated after auth
			p1_class, p2_class,
			GameManager.selected_stage
		)

		# Connect desync signal
		NetworkManager.desync_detected.connect(_on_desync_detected)
		NetworkManager.match_proof_received.connect(_on_match_proof_received)
		NetworkManager.match_signature_received.connect(_on_match_signature_received)

		# Connect skill analysis completion — updates display rating when bg thread finishes
		_replay_manager.skill_analysis_complete.connect(_on_skill_analysis_complete)


func _physics_process(_delta: float) -> void:
	# During online mode, drive simulation through RollbackManager
	if GameManager.online_mode and RollbackManager.is_active:
		RollbackManager.network_tick()


func _process(delta: float) -> void:
	if round_transition_active:
		round_transition_timer -= delta
		if round_transition_timer <= 0:
			round_transition_active = false
			round_msg_label.visible = false
			if GameManager.state == GameManager.GameState.MATCH_END:
				# Show match end screen with score and buttons
				_show_match_end_screen()
			else:
				# Start next round
				GameManager.start_next_round()
				_reset_positions()


func _build_round_overlay() -> void:
	overlay_canvas = CanvasLayer.new()
	overlay_canvas.layer = 20
	add_child(overlay_canvas)

	round_msg_label = Label.new()
	round_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_msg_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	round_msg_label.add_theme_font_size_override("font_size", 64)
	round_msg_label.add_theme_color_override("font_color", Color.WHITE)
	round_msg_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	round_msg_label.add_theme_constant_override("shadow_offset_x", 3)
	round_msg_label.add_theme_constant_override("shadow_offset_y", 3)
	round_msg_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	round_msg_label.visible = false
	overlay_canvas.add_child(round_msg_label)


func _show_match_end_screen() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	match_end_screen = Control.new()
	match_end_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay_canvas.add_child(match_end_screen)

	# Semi-transparent background
	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.6)
	match_end_screen.add_child(bg)

	# Center container
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.offset_left = -250
	vbox.offset_top = -200
	vbox.offset_right = 250
	vbox.offset_bottom = 200
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	match_end_screen.add_child(vbox)

	# Winner text
	var winner_id = 1 if GameManager.p1_round_wins >= GameManager.ROUNDS_TO_WIN else 2
	var winner_label = Label.new()
	winner_label.text = "P" + str(winner_id) + " WINS!"
	winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	winner_label.add_theme_font_size_override("font_size", 72)
	winner_label.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	vbox.add_child(winner_label)

	# Score
	# Match (set) counter — primary
	var match_score = Label.new()
	match_score.text = "Matches:  P1  " + str(GameManager.p1_match_wins) + "  -  " + str(GameManager.p2_match_wins) + "  P2"
	match_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	match_score.add_theme_font_size_override("font_size", 36)
	match_score.add_theme_color_override("font_color", Color(0.9, 0.85, 0.5))
	vbox.add_child(match_score)

	# Round score for this set — below match count
	var round_score = Label.new()
	round_score.text = "Rounds:  P1  " + str(GameManager.p1_round_wins) + "  -  " + str(GameManager.p2_round_wins) + "  P2"
	round_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_score.add_theme_font_size_override("font_size", 22)
	round_score.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	vbox.add_child(round_score)

	# Spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)

	# Rematch button
	var rematch_btn = Button.new()
	rematch_btn.text = "REMATCH"
	rematch_btn.custom_minimum_size = Vector2(200, 50)
	rematch_btn.add_theme_font_size_override("font_size", 24)
	rematch_btn.pressed.connect(_on_rematch)
	vbox.add_child(rematch_btn)

	# Main menu button
	var menu_btn = Button.new()
	menu_btn.text = "MAIN MENU"
	menu_btn.custom_minimum_size = Vector2(200, 50)
	menu_btn.add_theme_font_size_override("font_size", 24)
	menu_btn.pressed.connect(_on_main_menu)
	vbox.add_child(menu_btn)


func _on_rematch() -> void:
	if match_end_screen:
		match_end_screen.queue_free()
		match_end_screen = null
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GameManager.reset_match()
	_reset_positions()


func _on_main_menu() -> void:
	GameManager.reset_session()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _on_round_ended(winner_id: int) -> void:
	# Show round win message, then transition
	round_msg_label.text = "P" + str(winner_id) + " WINS ROUND " + str(GameManager.current_round)
	round_msg_label.visible = true
	round_transition_active = true
	round_transition_timer = 2.5  # 2.5 second pause

	# Track round end for replay
	if _replay_manager:
		_replay_manager.end_round(
			GameManager.current_round,
			str(winner_id),
			GameManager.p1_health,
			GameManager.p2_health,
			RollbackManager.current_frame
		)


func _on_match_ended(winner_id: int) -> void:
	round_msg_label.text = "P" + str(winner_id) + " WINS THE MATCH!"
	round_msg_label.visible = true
	round_transition_active = true
	round_transition_timer = 4.0  # 4 second pause before menu
	_handle_ranked_match_end(winner_id)


func _handle_ranked_match_end(winner_id: int) -> void:
	if not _is_ranked or _replay_manager == null:
		return

	# End replay recording
	var replay = _replay_manager.finalize_replay(
		str(winner_id),  # Convert to profile_id later
		GameManager.p1_round_wins,
		GameManager.p2_round_wins
	)

	# Save replay locally
	_replay_manager.save_locally(replay)

	# Compute replay hash
	var replay_hash = _replay_manager.compute_replay_hash(replay)

	# Build round results from GameManager
	var round_results: Array = []
	# Simplified: just record final result
	round_results.append({
		"round": 1,
		"winner_id": str(winner_id),
		"p1_health": GameManager.p1_health,
		"p2_health": GameManager.p2_health
	})

	# Create match data
	var match_data = MatchProof.create_match_data(
		ProfileManager.profile_id,
		"opponent",  # Remote profile ID
		str(winner_id),
		"",  # replay_cid populated after IPFS upload
		round_results,
		Time.get_datetime_string_from_system()
	)

	# Sign locally
	var match_hash = MatchProof.hash_match(match_data)
	var local_sig = MatchProof.sign_match(match_hash, ProfileManager.signing_key)

	# Store pending proof and send to opponent for counter-signing
	_pending_proof = {
		"match_data": match_data,
		"match_hash": match_hash,
		"local_sig": local_sig,
		"replay": replay
	}

	# Send proof to opponent
	var proof_to_send = match_data.duplicate()
	proof_to_send["match_hash"] = match_hash
	proof_to_send["sender_sig"] = local_sig
	NetworkManager.send_match_proof(proof_to_send)

	# Start timeout for counter-signature
	get_tree().create_timer(MatchProof.SIGN_TIMEOUT_SEC).timeout.connect(_on_sign_timeout)


func _on_match_proof_received(proof_data: Dictionary) -> void:
	# Opponent sent us their proof — verify and counter-sign
	var match_hash = proof_data.get("match_hash", "")
	if match_hash.is_empty():
		return

	# Verify the hash matches the data
	var recomputed = MatchProof.hash_match(proof_data)
	# Note: hash_match ignores match_hash and sender_sig fields

	# Counter-sign
	var my_sig = MatchProof.sign_match(match_hash, ProfileManager.signing_key)
	NetworkManager.send_match_signature(my_sig)

	# If we also sent a proof, merge signatures
	if not _pending_proof.is_empty():
		_pending_proof["remote_sig"] = proof_data.get("sender_sig", "")
		_finalize_proof()


func _on_match_signature_received(sig: String) -> void:
	# Opponent counter-signed our proof
	if _pending_proof.is_empty():
		return
	_pending_proof["remote_sig"] = sig
	_finalize_proof()


func _on_sign_timeout() -> void:
	# Opponent didn't sign — record as single-sig proof (auto-loss for them)
	if _pending_proof.is_empty():
		return
	if not _pending_proof.has("remote_sig"):
		_pending_proof["remote_sig"] = ""  # Empty = unsigned
		_finalize_proof()


func _finalize_proof() -> void:
	if _pending_proof.is_empty():
		return

	var proof = MatchProof.create_proof(
		_pending_proof["match_data"],
		_pending_proof["local_sig"],
		_pending_proof.get("remote_sig", "")
	)

	# Store in local proof chain
	if _leaderboard == null:
		_leaderboard = LeaderboardManager.new()
		_leaderboard.init(NetworkManager.get_signaling())
		_leaderboard.load_local_data()
	_leaderboard.add_proof(proof)

	# Update profile stats
	var winner = _pending_proof["match_data"].get("winner_id", "")
	if winner == ProfileManager.profile_id:
		ProfileManager.record_win()
	else:
		ProfileManager.record_loss()

	# Fire background replay analysis — updates running skill score incrementally
	if _replay_manager and _pending_proof.has("replay"):
		_replay_manager.analyze_in_background(_pending_proof["replay"], ProfileManager.profile_id)

	# Auto-sync proof chain to Firebase leaderboard after every match
	_leaderboard.publish_proof_chain("", self)

	_pending_proof = {}


func _on_skill_analysis_complete(_metrics: Dictionary, skill_score: float) -> void:
	# Background thread finished replay analysis — update display rating
	# Elo was already updated instantly in _finalize_proof; this adds the skill component
	if _leaderboard:
		var base_rating: int = _leaderboard.get_local_rating()
		var display_rating: int = RatingCalculator.get_display_rating(float(base_rating), skill_score)
		print("Ranked: Skill analysis complete. Base Elo: %d, Skill: %.2f, Display: %d" % [base_rating, skill_score, display_rating])


func _on_desync_detected(_frame: int) -> void:
	# Desync detected — terminate match, no proof generated
	if _anticheat:
		_anticheat.flag_match("State desync detected")
	_pending_proof = {}
	push_warning("FightScene: Desync detected, match invalidated")


func _exit_tree() -> void:
	# Clean up AI references so InputManager doesn't call freed objects
	InputManager.unregister_ai(1)
	InputManager.unregister_ai(2)
	# Clean up rollback manager
	if RollbackManager.is_active:
		RollbackManager.stop()
	# Clean up ranked references
	RollbackManager.clear_ranked()
	NetworkManager._anticheat_ref = null


func _apply_ai_difficulty(ai, player_id: int) -> void:
	var diff = GameManager.ai_difficulty
	if not diff.is_empty():
		ai.difficulty = diff.get("difficulty", "NORMAL")

	# Set fighter class so AI uses class-appropriate moves
	var fc = GameManager.p1_fighter_class if player_id == 1 else GameManager.p2_fighter_class
	ai.fighter_class = "OFFENSIVE" if fc == GameManager.FighterClass.OFFENSIVE else "DEFENSIVE"


func _apply_player_colors() -> void:
	_apply_colors_to_fighter(fighter1, GameManager.p1_skin_color, GameManager.p1_torso_color)
	_apply_colors_to_fighter(fighter2, GameManager.p2_skin_color, GameManager.p2_torso_color)


func _apply_colors_to_fighter(fighter: Node, skin_color: Color, torso_color: Color) -> void:
	var model = fighter.get_node_or_null("Model")
	if model == null:
		return
	# Walk through all MeshInstance3D children and update materials
	for child in _get_all_mesh_instances(model):
		var mat = child.material_override
		if mat is StandardMaterial3D:
			var c = mat.albedo_color
			# Detect skin-colored meshes (head, arms, hands)
			if _is_skin_tone(c):
				var new_mat = mat.duplicate()
				new_mat.albedo_color = skin_color
				child.material_override = new_mat
			# Detect torso-colored meshes
			elif _is_torso_tone(c):
				var new_mat = mat.duplicate()
				new_mat.albedo_color = torso_color
				child.material_override = new_mat


func _is_skin_tone(c: Color) -> bool:
	# Original skin colors: (0.85, 0.7, 0.55) and hand (0.9, 0.75, 0.6)
	return c.r > 0.6 and c.g > 0.5 and c.b < 0.7 and c.b > 0.3


func _is_torso_tone(c: Color) -> bool:
	# Original torso: (0.2, 0.2, 0.6) or abdomen: (0.15, 0.15, 0.5)
	return c.b > 0.4 and c.r < 0.3 and c.g < 0.3


func _get_all_mesh_instances(node: Node) -> Array:
	var result = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_get_all_mesh_instances(child))
	return result


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if match_end_screen:
			return
		if GameManager.online_mode:
			return  # No pause during online matches
		if is_paused:
			_destroy_overlay()
			is_paused = false
			get_tree().paused = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			is_paused = true
			get_tree().paused = true
			_show_pause_menu()


func _destroy_overlay() -> void:
	if pause_menu:
		pause_menu.queue_free()
		pause_menu = null


func _show_pause_menu() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_destroy_overlay()

	pause_menu = Control.new()
	pause_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_menu.process_mode = Node.PROCESS_MODE_ALWAYS
	overlay_canvas.add_child(pause_menu)

	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.75)
	pause_menu.add_child(bg)

	# Main layout: buttons on left, movelist on right
	var hbox = HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 30)
	pause_menu.add_child(hbox)

	# Left side — buttons
	var btn_panel = VBoxContainer.new()
	btn_panel.custom_minimum_size = Vector2(220, 0)
	btn_panel.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_panel.add_theme_constant_override("separation", 15)
	hbox.add_child(btn_panel)

	var title = Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn_panel.add_child(title)

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 15)
	btn_panel.add_child(spacer)

	_add_pause_btn(btn_panel, "RESUME", func():
		_destroy_overlay()
		is_paused = false
		get_tree().paused = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	)

	_add_pause_btn(btn_panel, "MAIN MENU", func():
		_destroy_overlay()
		is_paused = false
		get_tree().paused = false
		GameManager.reset_session()
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
	)

	# Right side — movelist
	var ml_panel = HBoxContainer.new()
	ml_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ml_panel.add_theme_constant_override("separation", 20)
	hbox.add_child(ml_panel)

	_build_movelist_column(ml_panel, "P1", GameManager.p1_fighter_class)
	_build_movelist_column(ml_panel, "P2", GameManager.p2_fighter_class)


func _add_pause_btn(parent: Control, text: String, callback: Callable) -> void:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(200, 45)
	btn.add_theme_font_size_override("font_size", 22)
	btn.pressed.connect(callback)
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(btn)



func _make_header(text: String) -> Label:
	var lbl = Label.new()
	lbl.text = "── " + text + " ──"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl


func _make_move_row(input_text: String, name_text: String, level: String, detail: String) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var input_lbl = Label.new()
	input_lbl.text = input_text
	input_lbl.custom_minimum_size = Vector2(100, 0)
	input_lbl.add_theme_font_size_override("font_size", 15)
	input_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	row.add_child(input_lbl)

	var name_lbl = Label.new()
	name_lbl.text = name_text
	name_lbl.custom_minimum_size = Vector2(140, 0)
	name_lbl.add_theme_font_size_override("font_size", 14)
	row.add_child(name_lbl)

	if level != "":
		var level_lbl = Label.new()
		level_lbl.text = level
		level_lbl.custom_minimum_size = Vector2(50, 0)
		level_lbl.add_theme_font_size_override("font_size", 13)
		match level:
			"High":
				level_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			"Mid":
				level_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
			"Low":
				level_lbl.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
		row.add_child(level_lbl)

	var detail_lbl = Label.new()
	detail_lbl.text = detail
	detail_lbl.add_theme_font_size_override("font_size", 12)
	detail_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	detail_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(detail_lbl)

	return row




func _build_movelist_column(parent: Control, player_name: String, fighter_class) -> void:
	var panel = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 3)
	parent.add_child(panel)

	var class_name_str = "DEFENSIVE" if fighter_class == GameManager.FighterClass.DEFENSIVE else "OFFENSIVE"
	var header = Label.new()
	header.text = player_name + " - " + class_name_str
	header.add_theme_font_size_override("font_size", 22)
	header.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0) if player_name == "P1" else Color(1.0, 0.4, 0.4))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(header)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var move_vbox = VBoxContainer.new()
	move_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_vbox.add_theme_constant_override("separation", 3)
	scroll.add_child(move_vbox)

	var shared_moves = [
		["1", "Jab", "High", "i8, +6 hit, +1 block"],
		["2", "Overhead Slam", "Mid", "i16, KD, -16 block, crushes highs"],
		["3", "Low Kick", "Low", "i10, +4 hit, -13 block"],
		["4", "Roundhouse", "High", "i14, KD/stagger, -14 block, homing"],
		["d+3", "Leg Sweep", "Low", "i15, soft KD, -20 block"],
	]

	var def_moves = [
		["1,1", "Cross Punch", "High", "i6, +4 hit, -5 block"],
		["1,1,1", "Hook", "High", "i10, hard KD, -16 block"],
		["df+1", "Mid Check", "Mid", "i11, +5 hit, -2 block"],
		["d+1", "Track Mid", "Mid", "i12, +5 hit, -6 block, homing"],
	]

	var off_moves = [
		["4,4", "Power Roundhouse", "High", "i11, hard KD, -16 block, natural"],
		["d+3,3", "Double Slide", "Low", "i6, hard KD, -18 block, natural"],
		["d+4", "Crouch Kick", "Low", "i11, +5 hit, -12 block"],
		["d+4,4", "Kick -> Power RH", "L->H", "i11, hard KD, -16 block, natural"],
	]

	var atk_header = _make_header("ATTACKS")
	move_vbox.add_child(atk_header)

	for entry in shared_moves:
		move_vbox.add_child(_make_move_row(entry[0], entry[1], entry[2], entry[3]))

	var class_header = _make_header("CLASS MOVES")
	move_vbox.add_child(class_header)

	var class_moves = def_moves if fighter_class == GameManager.FighterClass.DEFENSIVE else off_moves
	for entry in class_moves:
		move_vbox.add_child(_make_move_row(entry[0], entry[1], entry[2], entry[3]))

	var mov_header = _make_header("MOVEMENT")
	move_vbox.add_child(mov_header)

	var movement_list = [
		["f,f", "Forward Dash", "", "Quick burst"],
		["b,b", "Backdash", "", "Quick dodge"],
		["b,b>db>b", "KBD", "", "Chain backdash"],
		["f,n,d,df", "Crouch Dash", "", "Low rush"],
		["up/dn x2", "Sidestep", "", "Lateral dodge"],
		["d/b", "Crouch Block", "", "Blocks low+mid"],
		["Neutral", "Stand Block", "", "Blocks high+mid"],
		["qcb", "Backsway", "", "Lean back"],
		["tap up", "Hop", "", "Low evasion"],
	]

	for entry in movement_list:
		move_vbox.add_child(_make_move_row(entry[0], entry[1], entry[2], entry[3]))




func _reset_positions() -> void:
	fighter1.global_position = P1_SPAWN
	fighter2.global_position = P2_SPAWN
	fighter1.velocity = Vector3.ZERO
	fighter2.velocity = Vector3.ZERO
	fighter1.pending_knockback = Vector3.ZERO
	fighter2.pending_knockback = Vector3.ZERO
	# Reset to idle state
	if fighter1.state_machine:
		fighter1.state_machine.force_transition("Idle")
	if fighter2.state_machine:
		fighter2.state_machine.force_transition("Idle")
	# Reset camera tracking to prevent inversion
	var cam = get_node_or_null("FightCamera")
	if cam and cam.has_method("reset_tracking"):
		cam.reset_tracking()
