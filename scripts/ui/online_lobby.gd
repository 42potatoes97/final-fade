extends Control

# Online lobby — tabbed interface for online play
# Profile must be set before accessing other tabs.
# Tab 1: Profile (required first — set username to unlock other tabs)
# Tab 2: Direct Connect (host/join via room code, transport selection)
# Tab 3: Browse Lobbies (discover and join rooms via MQTT broker)
# Tab 4: Ranked (matchmaking queue, rating display)
# Tab 5: Leaderboard (sync & view global rankings)

# --- State ---
enum LobbyState { IDLE, HOSTING, JOINING, CONNECTED }
var _state: LobbyState = LobbyState.IDLE
var _profile_set: bool = false
var _lobby_browsing: bool = false

# --- Tab panels ---
var profile_panel: VBoxContainer
var direct_panel: VBoxContainer
var lobbies_panel: VBoxContainer
var ranked_panel: VBoxContainer
var leaderboard_panel: VBoxContainer

# --- Tab buttons ---
var tab_profile_btn: Button
var tab_direct_btn: Button
var tab_lobbies_btn: Button
var tab_ranked_btn: Button
var tab_leaderboard_btn: Button

# --- Direct Connect widgets ---
var transport_enet_btn: Button
var transport_webrtc_btn: Button
var host_btn: Button
var join_btn: Button
var cancel_btn: Button
var code_display: Label
var copy_btn: Button
var code_field: LineEdit
var port_field: LineEdit
var delay_label: Label
var status_label: Label
var start_btn: Button

# --- Browse Lobbies widgets ---
var lobby_status_label: Label
var room_list_container: VBoxContainer
var lobby_connect_btn: Button
var lobby_create_btn: Button
var lobby_refresh_btn: Button
var _room_rows: Dictionary = {}

# --- Profile widgets ---
var username_field: LineEdit
var profile_id_label: Label
var stats_label: Label
var profile_save_btn: Button
var profile_status_label: Label
var export_btn: Button
var import_btn: Button
var clear_data_btn: Button

# --- Ranked widgets ---
var ranked_rating_label: Label
var ranked_status_label: Label
var ranked_find_btn: Button
var ranked_cancel_btn: Button
var ranked_region_btn: OptionButton
var ranked_range_label: Label

# --- Leaderboard widgets ---
var lb_list_container: VBoxContainer
var lb_status_label: Label
var lb_sync_btn: Button
var lb_refresh_btn: Button

# --- Ranked system references ---
var _matchmaking: MatchmakingQueue = null
var _leaderboard_mgr: LeaderboardManager = null
var _ranked_config: RankedConfig = null
var _lobby: LobbyDiscovery = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_profile_set = ProfileManager.username.length() > 0
	_build_ui()
	UIFocusHelper.setup_focus(self)

	# Start on profile if not set, otherwise direct
	if _profile_set:
		_switch_tab("direct")
	else:
		_switch_tab("profile")

	# Network signals
	NetworkManager.connected_to_peer.connect(_on_connected)
	NetworkManager.disconnected.connect(_on_disconnected)
	NetworkManager.connection_failed.connect(_on_failed)
	NetworkManager.auth_completed.connect(_on_auth_completed)
	NetworkManager.auth_failed.connect(_on_auth_failed)
	NetworkManager.public_ip_fetched.connect(_on_public_ip)
	NetworkManager.room_code_ready.connect(_on_room_code_ready)

	_ranked_config = RankedConfig.new()
	_ranked_config.load_config()


# =============================================================================
#  UI CONSTRUCTION
# =============================================================================

func _build_ui() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root_vbox: VBoxContainer = VBoxContainer.new()
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vbox.add_theme_constant_override("separation", 16)
	root_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(root_vbox)

	# Title
	var title: Label = Label.new()
	title.text = "ONLINE PLAY"
	title.add_theme_font_size_override("font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_vbox.add_child(title)

	# Tab bar
	var tab_bar: HBoxContainer = HBoxContainer.new()
	tab_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	tab_bar.add_theme_constant_override("separation", 12)
	root_vbox.add_child(tab_bar)

	tab_profile_btn = _make_tab_button("PROFILE")
	tab_profile_btn.pressed.connect(func(): _switch_tab("profile"))
	tab_bar.add_child(tab_profile_btn)

	tab_direct_btn = _make_tab_button("DIRECT")
	tab_direct_btn.pressed.connect(func(): _try_switch_tab("direct"))
	tab_bar.add_child(tab_direct_btn)

	tab_lobbies_btn = _make_tab_button("LOBBIES")
	tab_lobbies_btn.pressed.connect(func(): _try_switch_tab("lobbies"))
	tab_bar.add_child(tab_lobbies_btn)

	tab_ranked_btn = _make_tab_button("RANKED")
	tab_ranked_btn.pressed.connect(func(): _try_switch_tab("ranked"))
	tab_bar.add_child(tab_ranked_btn)

	tab_leaderboard_btn = _make_tab_button("BOARD")
	tab_leaderboard_btn.pressed.connect(func(): _try_switch_tab("leaderboard"))
	tab_bar.add_child(tab_leaderboard_btn)

	var sep: HSeparator = HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	root_vbox.add_child(sep)

	# Tab panels
	profile_panel = _build_profile_panel()
	root_vbox.add_child(profile_panel)

	direct_panel = _build_direct_panel()
	root_vbox.add_child(direct_panel)

	lobbies_panel = _build_lobbies_panel()
	root_vbox.add_child(lobbies_panel)

	ranked_panel = _build_ranked_panel()
	root_vbox.add_child(ranked_panel)

	leaderboard_panel = _build_leaderboard_panel()
	root_vbox.add_child(leaderboard_panel)

	# Back button
	var back_btn: Button = Button.new()
	back_btn.text = "← BACK"
	back_btn.custom_minimum_size = Vector2(150, 40)
	back_btn.add_theme_font_size_override("font_size", 18)
	back_btn.pressed.connect(_on_back_pressed)
	root_vbox.add_child(back_btn)

	_update_tab_availability()


func _make_tab_button(label_text: String) -> Button:
	var btn: Button = Button.new()
	btn.text = label_text
	btn.custom_minimum_size = Vector2(140, 42)
	btn.add_theme_font_size_override("font_size", 20)
	return btn


func _try_switch_tab(tab_name: String) -> void:
	if not _profile_set and tab_name != "profile":
		# Auto-generate a guest username so players can test immediately
		ProfileManager.username = "Player_%d" % (randi() % 9999)
		ProfileManager.save_profile()
		_profile_set = true
		_update_tab_availability()
	_switch_tab(tab_name)


func _switch_tab(tab_name: String) -> void:
	profile_panel.visible = (tab_name == "profile")
	direct_panel.visible = (tab_name == "direct")
	lobbies_panel.visible = (tab_name == "lobbies")
	ranked_panel.visible = (tab_name == "ranked")
	leaderboard_panel.visible = (tab_name == "leaderboard")

	var gold: Color = Color(1.0, 0.85, 0.2)
	var dim: Color = Color(0.6, 0.6, 0.7)
	var locked: Color = Color(0.3, 0.3, 0.4)

	tab_profile_btn.add_theme_color_override("font_color", gold if tab_name == "profile" else dim)
	tab_direct_btn.add_theme_color_override("font_color", gold if tab_name == "direct" else (dim if _profile_set else locked))
	tab_lobbies_btn.add_theme_color_override("font_color", gold if tab_name == "lobbies" else (dim if _profile_set else locked))
	tab_ranked_btn.add_theme_color_override("font_color", gold if tab_name == "ranked" else (dim if _profile_set else locked))
	tab_leaderboard_btn.add_theme_color_override("font_color", gold if tab_name == "leaderboard" else (dim if _profile_set else locked))

	if tab_name == "profile":
		_populate_profile()
	if tab_name == "ranked":
		ranked_rating_label.text = "Your Rating: %d" % _get_local_rating()
	if tab_name == "leaderboard" and _leaderboard_mgr:
		var cached = _leaderboard_mgr.get_cached_entries()
		if cached and cached.size() > 0:
			_on_leaderboard_updated(cached)


func _update_tab_availability() -> void:
	var locked: Color = Color(0.3, 0.3, 0.4)
	var dim: Color = Color(0.6, 0.6, 0.7)
	tab_direct_btn.add_theme_color_override("font_color", dim if _profile_set else locked)
	tab_lobbies_btn.add_theme_color_override("font_color", dim if _profile_set else locked)
	tab_ranked_btn.add_theme_color_override("font_color", dim if _profile_set else locked)
	tab_leaderboard_btn.add_theme_color_override("font_color", dim if _profile_set else locked)


# =============================================================================
#  TAB 1 — PROFILE (entry gate)
# =============================================================================

func _build_profile_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 14)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER

	# Gate message
	var gate_label: Label = Label.new()
	gate_label.text = "Set your username to access online features"
	gate_label.add_theme_font_size_override("font_size", 18)
	gate_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	gate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(gate_label)

	# Username
	var user_hbox: HBoxContainer = HBoxContainer.new()
	user_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	user_hbox.add_theme_constant_override("separation", 10)
	panel.add_child(user_hbox)

	var user_prompt: Label = Label.new()
	user_prompt.text = "Username:"
	user_prompt.add_theme_font_size_override("font_size", 20)
	user_hbox.add_child(user_prompt)

	username_field = LineEdit.new()
	username_field.custom_minimum_size = Vector2(220, 40)
	username_field.add_theme_font_size_override("font_size", 20)
	username_field.max_length = 24
	user_hbox.add_child(username_field)

	profile_save_btn = Button.new()
	profile_save_btn.text = "SAVE"
	profile_save_btn.custom_minimum_size = Vector2(80, 40)
	profile_save_btn.add_theme_font_size_override("font_size", 18)
	profile_save_btn.pressed.connect(_on_profile_save_pressed)
	user_hbox.add_child(profile_save_btn)

	# Profile status
	profile_status_label = Label.new()
	profile_status_label.text = ""
	profile_status_label.add_theme_font_size_override("font_size", 18)
	profile_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(profile_status_label)

	# Profile ID
	var id_hbox: HBoxContainer = HBoxContainer.new()
	id_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	id_hbox.add_theme_constant_override("separation", 10)
	panel.add_child(id_hbox)

	var id_prompt: Label = Label.new()
	id_prompt.text = "Profile ID:"
	id_prompt.add_theme_font_size_override("font_size", 18)
	id_prompt.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	id_hbox.add_child(id_prompt)

	profile_id_label = Label.new()
	profile_id_label.add_theme_font_size_override("font_size", 18)
	profile_id_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	id_hbox.add_child(profile_id_label)

	var copy_id_btn: Button = Button.new()
	copy_id_btn.text = "COPY"
	copy_id_btn.custom_minimum_size = Vector2(80, 34)
	copy_id_btn.add_theme_font_size_override("font_size", 14)
	copy_id_btn.pressed.connect(func(): DisplayServer.clipboard_set(ProfileManager.profile_id))
	id_hbox.add_child(copy_id_btn)

	# Stats
	stats_label = Label.new()
	stats_label.add_theme_font_size_override("font_size", 20)
	stats_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(stats_label)

	# Export / Import / Clear
	var ei_hbox: HBoxContainer = HBoxContainer.new()
	ei_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	ei_hbox.add_theme_constant_override("separation", 12)
	panel.add_child(ei_hbox)

	export_btn = Button.new()
	export_btn.text = "EXPORT"
	export_btn.custom_minimum_size = Vector2(120, 40)
	export_btn.add_theme_font_size_override("font_size", 18)
	export_btn.pressed.connect(_on_export_pressed)
	ei_hbox.add_child(export_btn)

	import_btn = Button.new()
	import_btn.text = "IMPORT"
	import_btn.custom_minimum_size = Vector2(120, 40)
	import_btn.add_theme_font_size_override("font_size", 18)
	import_btn.pressed.connect(_on_import_pressed)
	ei_hbox.add_child(import_btn)

	clear_data_btn = Button.new()
	clear_data_btn.text = "CLEAR DATA"
	clear_data_btn.custom_minimum_size = Vector2(140, 40)
	clear_data_btn.add_theme_font_size_override("font_size", 18)
	clear_data_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	clear_data_btn.pressed.connect(_on_clear_data_pressed)
	ei_hbox.add_child(clear_data_btn)

	return panel


func _populate_profile() -> void:
	username_field.text = ProfileManager.username
	# Lock username once set
	username_field.editable = not _profile_set
	profile_save_btn.visible = not _profile_set
	profile_id_label.text = ProfileManager.profile_id.substr(0, 8) + "..."
	var s: Dictionary = ProfileManager.stats
	stats_label.text = "W: %d  /  L: %d  /  Total: %d" % [
		s.get("wins", 0), s.get("losses", 0), s.get("total_matches", 0)
	]


func _on_profile_save_pressed() -> void:
	var new_name: String = username_field.text.strip_edges()
	if new_name.length() < 2:
		profile_status_label.text = "Username must be at least 2 characters!"
		profile_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return
	ProfileManager.username = new_name
	ProfileManager.save_profile()
	_profile_set = true
	_populate_profile()
	_update_tab_availability()
	profile_status_label.text = "Username saved! Online features unlocked."
	profile_status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))


func _on_clear_data_pressed() -> void:
	ProfileManager.username = ""
	ProfileManager.save_profile()
	_profile_set = false
	username_field.text = ""
	username_field.editable = true
	profile_save_btn.visible = true
	_update_tab_availability()
	_populate_profile()
	profile_status_label.text = "Data cleared. Set a new username."
	profile_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	_switch_tab("profile")


func _on_export_pressed() -> void:
	var data: String = ProfileManager.export_profile()
	DisplayServer.clipboard_set(data)
	export_btn.text = "COPIED!"
	get_tree().create_timer(1.5).timeout.connect(func(): export_btn.text = "EXPORT")


func _on_import_pressed() -> void:
	var clipboard: String = DisplayServer.clipboard_get().strip_edges()
	if clipboard.length() == 0:
		profile_status_label.text = "Clipboard is empty!"
		profile_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return
	var success: bool = ProfileManager.import_profile(clipboard)
	if success:
		_profile_set = ProfileManager.username.length() > 0
		_populate_profile()
		_update_tab_availability()
		profile_status_label.text = "Profile imported!"
		profile_status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	else:
		profile_status_label.text = "Invalid profile data!"
		profile_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))


# =============================================================================
#  TAB 2 — DIRECT CONNECT
# =============================================================================

func _build_direct_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 14)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER

	# Transport selector
	var transport_label: Label = Label.new()
	transport_label.text = "Transport"
	transport_label.add_theme_font_size_override("font_size", 18)
	transport_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	transport_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(transport_label)

	var transport_hbox: HBoxContainer = HBoxContainer.new()
	transport_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	transport_hbox.add_theme_constant_override("separation", 12)
	panel.add_child(transport_hbox)

	transport_enet_btn = Button.new()
	transport_enet_btn.text = "ENet (LAN)"
	transport_enet_btn.custom_minimum_size = Vector2(180, 40)
	transport_enet_btn.add_theme_font_size_override("font_size", 18)
	transport_enet_btn.pressed.connect(func(): _select_transport("enet"))
	transport_hbox.add_child(transport_enet_btn)

	transport_webrtc_btn = Button.new()
	transport_webrtc_btn.text = "WebRTC (Internet)"
	transport_webrtc_btn.custom_minimum_size = Vector2(200, 40)
	transport_webrtc_btn.add_theme_font_size_override("font_size", 18)
	transport_webrtc_btn.pressed.connect(func(): _select_transport("webrtc"))
	transport_hbox.add_child(transport_webrtc_btn)

	_select_transport("enet")

	# Host / Join / Cancel buttons
	var action_hbox: HBoxContainer = HBoxContainer.new()
	action_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	action_hbox.add_theme_constant_override("separation", 20)
	panel.add_child(action_hbox)

	host_btn = Button.new()
	host_btn.text = "HOST GAME"
	host_btn.custom_minimum_size = Vector2(200, 50)
	host_btn.add_theme_font_size_override("font_size", 22)
	host_btn.pressed.connect(_on_host_pressed)
	action_hbox.add_child(host_btn)

	join_btn = Button.new()
	join_btn.text = "JOIN GAME"
	join_btn.custom_minimum_size = Vector2(200, 50)
	join_btn.add_theme_font_size_override("font_size", 22)
	join_btn.pressed.connect(_on_join_pressed)
	action_hbox.add_child(join_btn)

	cancel_btn = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(200, 50)
	cancel_btn.add_theme_font_size_override("font_size", 22)
	cancel_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	cancel_btn.pressed.connect(_on_cancel_connection)
	cancel_btn.visible = false
	action_hbox.add_child(cancel_btn)

	# Room code display (shown after hosting)
	code_display = Label.new()
	code_display.text = ""
	code_display.add_theme_font_size_override("font_size", 20)
	code_display.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	code_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_display.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	code_display.custom_minimum_size = Vector2(600, 0)
	code_display.visible = false
	panel.add_child(code_display)

	copy_btn = Button.new()
	copy_btn.text = "COPY CODE"
	copy_btn.custom_minimum_size = Vector2(160, 40)
	copy_btn.add_theme_font_size_override("font_size", 16)
	copy_btn.pressed.connect(_on_copy_pressed)
	copy_btn.visible = false
	panel.add_child(copy_btn)

	# Code input (for joining)
	var code_hbox: HBoxContainer = HBoxContainer.new()
	code_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	code_hbox.add_theme_constant_override("separation", 10)
	panel.add_child(code_hbox)

	var code_prompt: Label = Label.new()
	code_prompt.text = "Room Code:"
	code_prompt.add_theme_font_size_override("font_size", 20)
	code_hbox.add_child(code_prompt)

	code_field = LineEdit.new()
	code_field.placeholder_text = "Enter code..."
	code_field.custom_minimum_size = Vector2(400, 45)
	code_field.add_theme_font_size_override("font_size", 18)
	code_field.max_length = 200  # ENet codes can be ~130 chars
	code_hbox.add_child(code_field)

	# Port field (ENet only)
	var port_hbox: HBoxContainer = HBoxContainer.new()
	port_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	port_hbox.add_theme_constant_override("separation", 10)
	panel.add_child(port_hbox)

	var port_prompt: Label = Label.new()
	port_prompt.text = "Port:"
	port_prompt.add_theme_font_size_override("font_size", 16)
	port_prompt.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	port_hbox.add_child(port_prompt)

	port_field = LineEdit.new()
	port_field.text = "7000"
	port_field.custom_minimum_size = Vector2(100, 35)
	port_field.add_theme_font_size_override("font_size", 16)
	port_hbox.add_child(port_field)

	# Input delay slider
	var delay_hbox: HBoxContainer = HBoxContainer.new()
	delay_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	delay_hbox.add_theme_constant_override("separation", 15)
	panel.add_child(delay_hbox)

	var delay_prompt: Label = Label.new()
	delay_prompt.text = "Input Delay:"
	delay_prompt.add_theme_font_size_override("font_size", 20)
	delay_hbox.add_child(delay_prompt)

	var slider: HSlider = HSlider.new()
	slider.min_value = 1
	slider.max_value = 5
	slider.value = 2
	slider.step = 1
	slider.custom_minimum_size = Vector2(200, 30)
	slider.value_changed.connect(_on_delay_changed)
	delay_hbox.add_child(slider)

	delay_label = Label.new()
	delay_label.text = "2 frames"
	delay_label.add_theme_font_size_override("font_size", 18)
	delay_hbox.add_child(delay_label)

	# Status
	status_label = Label.new()
	status_label.text = ""
	status_label.add_theme_font_size_override("font_size", 22)
	status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(status_label)

	# Start match button (host only, hidden until connected)
	start_btn = Button.new()
	start_btn.text = "START MATCH"
	start_btn.custom_minimum_size = Vector2(250, 50)
	start_btn.add_theme_font_size_override("font_size", 24)
	start_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	start_btn.pressed.connect(_on_start_pressed)
	start_btn.visible = false
	panel.add_child(start_btn)

	return panel


func _select_transport(transport_name: String) -> void:
	NetworkManager.set_transport(transport_name)
	var active_color: Color = Color(0.2, 1.0, 0.5)
	var inactive_color: Color = Color(0.6, 0.6, 0.7)
	transport_enet_btn.add_theme_color_override("font_color", active_color if transport_name == "enet" else inactive_color)
	transport_webrtc_btn.add_theme_color_override("font_color", active_color if transport_name == "webrtc" else inactive_color)


# =============================================================================
#  TAB 3 — BROWSE LOBBIES
# =============================================================================

func _build_lobbies_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 14)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER

	# Top bar: Connect / Create / Refresh
	var top_hbox: HBoxContainer = HBoxContainer.new()
	top_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	top_hbox.add_theme_constant_override("separation", 12)
	panel.add_child(top_hbox)

	lobby_connect_btn = Button.new()
	lobby_connect_btn.text = "CONNECT TO LOBBY"
	lobby_connect_btn.custom_minimum_size = Vector2(200, 44)
	lobby_connect_btn.add_theme_font_size_override("font_size", 18)
	lobby_connect_btn.pressed.connect(_on_lobby_connect_pressed)
	top_hbox.add_child(lobby_connect_btn)

	lobby_create_btn = Button.new()
	lobby_create_btn.text = "CREATE LOBBY"
	lobby_create_btn.custom_minimum_size = Vector2(180, 44)
	lobby_create_btn.add_theme_font_size_override("font_size", 18)
	lobby_create_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	lobby_create_btn.pressed.connect(_on_lobby_create_pressed)
	lobby_create_btn.visible = true  # Always visible — auto-connects if needed
	top_hbox.add_child(lobby_create_btn)

	lobby_refresh_btn = Button.new()
	lobby_refresh_btn.text = "REFRESH"
	lobby_refresh_btn.custom_minimum_size = Vector2(120, 44)
	lobby_refresh_btn.add_theme_font_size_override("font_size", 18)
	lobby_refresh_btn.pressed.connect(_on_lobby_refresh_pressed)
	top_hbox.add_child(lobby_refresh_btn)

	# Status
	lobby_status_label = Label.new()
	lobby_status_label.text = "Not connected to lobby"
	lobby_status_label.add_theme_font_size_override("font_size", 18)
	lobby_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	lobby_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(lobby_status_label)

	# Room list (scrollable)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(700, 200)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	room_list_container = VBoxContainer.new()
	room_list_container.add_theme_constant_override("separation", 6)
	room_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(room_list_container)

	return panel


func _on_lobby_connect_pressed() -> void:
	lobby_status_label.text = "Connecting to lobby..."
	lobby_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))

	_lobby = NetworkManager.get_lobby()
	_lobby_browsing = true

	if not _lobby.room_added.is_connected(_on_room_added):
		_lobby.room_added.connect(_on_room_added)
	if not _lobby.room_updated.is_connected(_on_room_updated):
		_lobby.room_updated.connect(_on_room_updated)
	if not _lobby.room_removed.is_connected(_on_room_removed):
		_lobby.room_removed.connect(_on_room_removed)
	if not _lobby.lobby_connected.is_connected(_on_lobby_connected):
		_lobby.lobby_connected.connect(_on_lobby_connected)
	if not _lobby.lobby_disconnected.is_connected(_on_lobby_disconnected):
		_lobby.lobby_disconnected.connect(_on_lobby_disconnected)

	# Must wait for broker connection before subscribing
	var signaling: SignalingClient = NetworkManager.get_signaling()
	if signaling.is_connected_to_broker():
		_lobby.start_browsing()
	else:
		signaling.connected.connect(_on_broker_connected_for_lobby, CONNECT_ONE_SHOT)
		signaling.connect_to_broker()


func _on_broker_connected_for_lobby() -> void:
	if _lobby:
		_lobby.start_browsing()


func _on_lobby_create_pressed() -> void:
	# Auto-connect to broker if not already browsing
	if not _lobby_browsing:
		_on_lobby_connect_pressed()

	# Lobby always uses WebRTC (internet play)
	_select_transport("webrtc")

	# Wait for room code, then announce to lobby
	if not NetworkManager.room_code_ready.is_connected(_on_lobby_room_code_ready):
		NetworkManager.room_code_ready.connect(_on_lobby_room_code_ready, CONNECT_ONE_SHOT)
	_switch_tab("direct")
	_on_host_pressed()


func _on_lobby_room_code_ready(code: String) -> void:
	# Announce the room to the lobby with the room code
	if _lobby == null:
		return
	var room: Dictionary = {
		"room_id": code.left(16) if code.length() > 16 else code,
		"host_name": ProfileManager.username if ProfileManager.username.length() > 0 else "Player",
		"transport": NetworkManager.active_transport,
		"region": "NA",
		"status": "waiting",
		"input_delay": 2,
		"room_code": code,
	}
	_lobby.announce_room(room)


func _on_lobby_refresh_pressed() -> void:
	_clear_room_list()
	if _lobby:
		_lobby.start_browsing()
	lobby_status_label.text = "Refreshing..."
	lobby_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))


func _on_lobby_connected() -> void:
	_update_lobby_status()
	lobby_create_btn.visible = true
	lobby_connect_btn.text = "CONNECTED"
	lobby_connect_btn.disabled = true


func _on_lobby_disconnected() -> void:
	lobby_status_label.text = "Lobby unavailable"
	lobby_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	lobby_create_btn.visible = false
	lobby_connect_btn.text = "CONNECT TO LOBBY"
	lobby_connect_btn.disabled = false
	_lobby_browsing = false


func _on_room_added(room: Dictionary) -> void:
	var rid: String = room.get("room_id", "")
	if rid.is_empty() or _room_rows.has(rid):
		return

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var host_label: Label = Label.new()
	host_label.text = room.get("host_name", "Unknown")
	host_label.add_theme_font_size_override("font_size", 18)
	host_label.custom_minimum_size = Vector2(150, 0)
	row.add_child(host_label)

	var transport_lbl: Label = Label.new()
	transport_lbl.text = room.get("transport", "enet").to_upper()
	transport_lbl.add_theme_font_size_override("font_size", 16)
	transport_lbl.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	transport_lbl.custom_minimum_size = Vector2(80, 0)
	row.add_child(transport_lbl)

	var region_lbl: Label = Label.new()
	region_lbl.text = room.get("region", "—")
	region_lbl.add_theme_font_size_override("font_size", 16)
	region_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	region_lbl.custom_minimum_size = Vector2(60, 0)
	row.add_child(region_lbl)

	var join_room_btn: Button = Button.new()
	join_room_btn.text = "JOIN"
	join_room_btn.custom_minimum_size = Vector2(80, 36)
	join_room_btn.add_theme_font_size_override("font_size", 16)
	join_room_btn.pressed.connect(_on_room_join_pressed.bind(room))
	row.add_child(join_room_btn)

	room_list_container.add_child(row)
	_room_rows[rid] = row
	_update_lobby_status()


func _on_room_updated(room: Dictionary) -> void:
	var rid: String = room.get("room_id", "")
	if not _room_rows.has(rid):
		return
	var status: String = room.get("status", "waiting")
	# Remove full or closed rooms from the list
	if status == "full" or status == "closed":
		_room_rows[rid].queue_free()
		_room_rows.erase(rid)
		_update_lobby_status()


func _on_room_removed(room_id: String) -> void:
	if _room_rows.has(room_id):
		_room_rows[room_id].queue_free()
		_room_rows.erase(room_id)
	_update_lobby_status()


func _on_room_join_pressed(room: Dictionary) -> void:
	var code: String = room.get("room_code", "")
	if code.is_empty():
		lobby_status_label.text = "Room has no connection code"
		lobby_status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return
	var transport: String = room.get("transport", "enet")
	_select_transport(transport)
	_switch_tab("direct")
	code_field.text = code
	_on_join_pressed()


func _clear_room_list() -> void:
	for rid in _room_rows:
		_room_rows[rid].queue_free()
	_room_rows.clear()


func _update_lobby_status() -> void:
	var count: int = _room_rows.size()
	if count == 0:
		lobby_status_label.text = "No rooms available"
		lobby_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	else:
		lobby_status_label.text = "%d room%s available" % [count, "s" if count != 1 else ""]
		lobby_status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))


# =============================================================================
#  TAB 4 — RANKED
# =============================================================================

func _build_ranked_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 14)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER

	ranked_rating_label = Label.new()
	ranked_rating_label.text = "Your Rating: %d" % _get_local_rating()
	ranked_rating_label.add_theme_font_size_override("font_size", 32)
	ranked_rating_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	ranked_rating_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(ranked_rating_label)

	ranked_find_btn = Button.new()
	ranked_find_btn.text = "FIND MATCH"
	ranked_find_btn.custom_minimum_size = Vector2(220, 50)
	ranked_find_btn.add_theme_font_size_override("font_size", 22)
	ranked_find_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	ranked_find_btn.pressed.connect(_on_ranked_find_pressed)
	panel.add_child(ranked_find_btn)

	ranked_cancel_btn = Button.new()
	ranked_cancel_btn.text = "CANCEL"
	ranked_cancel_btn.custom_minimum_size = Vector2(220, 50)
	ranked_cancel_btn.add_theme_font_size_override("font_size", 22)
	ranked_cancel_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	ranked_cancel_btn.pressed.connect(_on_ranked_cancel_pressed)
	ranked_cancel_btn.visible = false
	panel.add_child(ranked_cancel_btn)

	var region_hbox: HBoxContainer = HBoxContainer.new()
	region_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	region_hbox.add_theme_constant_override("separation", 10)
	panel.add_child(region_hbox)

	var region_prompt: Label = Label.new()
	region_prompt.text = "Region:"
	region_prompt.add_theme_font_size_override("font_size", 18)
	region_hbox.add_child(region_prompt)

	ranked_region_btn = OptionButton.new()
	ranked_region_btn.custom_minimum_size = Vector2(120, 40)
	ranked_region_btn.add_theme_font_size_override("font_size", 18)
	ranked_region_btn.add_item("USW")
	ranked_region_btn.add_item("USC")
	ranked_region_btn.add_item("USE")
	ranked_region_btn.add_item("SA")
	ranked_region_btn.add_item("EUW")
	ranked_region_btn.add_item("EUE")
	ranked_region_btn.add_item("AW")
	ranked_region_btn.add_item("ASEA")
	ranked_region_btn.add_item("EA")
	ranked_region_btn.add_item("OCEW")
	ranked_region_btn.add_item("OCEE")
	region_hbox.add_child(ranked_region_btn)

	ranked_range_label = Label.new()
	ranked_range_label.text = "Range: ---"
	ranked_range_label.add_theme_font_size_override("font_size", 18)
	ranked_range_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	ranked_range_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(ranked_range_label)

	ranked_status_label = Label.new()
	ranked_status_label.text = ""
	ranked_status_label.add_theme_font_size_override("font_size", 20)
	ranked_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	ranked_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(ranked_status_label)

	return panel


# =============================================================================
#  TAB 5 — LEADERBOARD
# =============================================================================

func _build_leaderboard_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 14)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER

	var top_hbox: HBoxContainer = HBoxContainer.new()
	top_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	top_hbox.add_theme_constant_override("separation", 12)
	panel.add_child(top_hbox)

	lb_sync_btn = Button.new()
	lb_sync_btn.text = "SYNC MY RESULTS"
	lb_sync_btn.custom_minimum_size = Vector2(200, 44)
	lb_sync_btn.add_theme_font_size_override("font_size", 18)
	lb_sync_btn.pressed.connect(_on_lb_sync_pressed)
	top_hbox.add_child(lb_sync_btn)

	lb_refresh_btn = Button.new()
	lb_refresh_btn.text = "REFRESH"
	lb_refresh_btn.custom_minimum_size = Vector2(120, 44)
	lb_refresh_btn.add_theme_font_size_override("font_size", 18)
	lb_refresh_btn.pressed.connect(_on_lb_refresh_pressed)
	top_hbox.add_child(lb_refresh_btn)

	lb_status_label = Label.new()
	lb_status_label.text = ""
	lb_status_label.add_theme_font_size_override("font_size", 18)
	lb_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	lb_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(lb_status_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(700, 250)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	lb_list_container = VBoxContainer.new()
	lb_list_container.add_theme_constant_override("separation", 6)
	lb_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(lb_list_container)

	_add_lb_row("#", "Username", "Rating", "W/L", "Matches", true)

	return panel


# =============================================================================
#  RANKED LOGIC
# =============================================================================

func _on_ranked_find_pressed():
	# Ensure lobby broker is connected first
	var signaling: SignalingClient = NetworkManager.get_signaling()
	if not signaling.is_connected_to_broker():
		signaling.connect_to_broker()

	if _matchmaking == null:
		_matchmaking = MatchmakingQueue.new()
		_matchmaking.init(signaling)
		_matchmaking.match_found.connect(_on_ranked_match_found)
		_matchmaking.queue_status_changed.connect(_on_ranked_status_changed)

	var rating = _get_local_rating()
	var region = ranked_region_btn.get_item_text(ranked_region_btn.selected)
	# Ranked always uses WebRTC for internet play
	_matchmaking.join_queue(rating, region, "webrtc")
	ranked_find_btn.visible = false
	ranked_cancel_btn.visible = true


func _on_ranked_cancel_pressed():
	if _matchmaking:
		_matchmaking.leave_queue()
	ranked_find_btn.visible = true
	ranked_cancel_btn.visible = false
	ranked_status_label.text = ""


func _on_ranked_match_found(opponent: Dictionary):
	var opp_name: String = opponent.get("username", "Unknown")
	var opp_rating: int = opponent.get("rating", 0)
	var is_host: bool = opponent.get("is_host", false)

	ranked_find_btn.visible = false
	ranked_cancel_btn.visible = false

	GameManager.online_mode = true
	GameManager.ranked_mode = true
	GameManager.ai_mode = false
	GameManager.training_mode = false

	if is_host:
		ranked_status_label.text = "Match found: %s (%d) — Hosting..." % [opp_name, opp_rating]
	else:
		ranked_status_label.text = "Match found: %s (%d) — Connecting..." % [opp_name, opp_rating]

	# Connection is handled by matchmaking_queue._initiate_match_connection()
	# Listen for peer connection to transition to game
	if not NetworkManager.connected_to_peer.is_connected(_on_ranked_connected):
		NetworkManager.connected_to_peer.connect(_on_ranked_connected, CONNECT_ONE_SHOT)


func _on_ranked_connected():
	ranked_status_label.text = "Connected! Starting match..."
	ranked_status_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	# Brief delay then start match
	get_tree().create_timer(1.0).timeout.connect(func():
		NetworkManager.start_game()
		NetworkManager.notify_game_start()
		get_tree().change_scene_to_file("res://scenes/ui/side_select.tscn")
	)


func _on_ranked_status_changed(status: String):
	ranked_status_label.text = status.capitalize()
	if _matchmaking:
		ranked_range_label.text = "Range: ±%d" % _matchmaking.get_current_range()


func _get_local_rating() -> int:
	if _leaderboard_mgr:
		return _leaderboard_mgr.get_local_rating()
	return RatingCalculator.DEFAULT_RATING


# =============================================================================
#  LEADERBOARD LOGIC
# =============================================================================

func _on_lb_sync_pressed():
	if _leaderboard_mgr == null:
		_leaderboard_mgr = LeaderboardManager.new()
		_leaderboard_mgr.init(NetworkManager.get_signaling())
		_leaderboard_mgr.load_local_data()
		_leaderboard_mgr.leaderboard_updated.connect(_on_leaderboard_updated)
	_leaderboard_mgr.publish_proof_chain("", self)
	lb_status_label.text = "Syncing..."


func _on_lb_refresh_pressed():
	if _leaderboard_mgr == null:
		_leaderboard_mgr = LeaderboardManager.new()
		_leaderboard_mgr.init(NetworkManager.get_signaling())
		_leaderboard_mgr.load_local_data()
		_leaderboard_mgr.leaderboard_updated.connect(_on_leaderboard_updated)
	_leaderboard_mgr.start_listening()
	_leaderboard_mgr.rebuild_leaderboard(self)
	lb_status_label.text = "Rebuilding..."


func _on_leaderboard_updated(entries: Array):
	for child in lb_list_container.get_children():
		child.queue_free()
	_add_lb_row("#", "Username", "Rating", "W/L", "Matches", true)
	for i in range(entries.size()):
		var e = entries[i]
		_add_lb_row(
			str(i + 1),
			e.get("username", "???"),
			str(e.get("display_rating", 1000)),
			"%d/%d" % [e.get("wins", 0), e.get("losses", 0)],
			str(e.get("total_matches", 0)),
			false
		)
	lb_status_label.text = "%d players" % entries.size()


func _add_lb_row(rank, username, rating, wl, matches, is_header: bool):
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var color = Color(0.8, 0.8, 0.3) if is_header else Color(0.8, 0.8, 0.9)
	var font_size = 18 if is_header else 16
	for data in [{"text": rank, "width": 40}, {"text": username, "width": 160}, {"text": rating, "width": 80}, {"text": wl, "width": 80}, {"text": matches, "width": 80}]:
		var lbl = Label.new()
		lbl.text = str(data.text)
		lbl.add_theme_font_size_override("font_size", font_size)
		lbl.add_theme_color_override("font_color", color)
		lbl.custom_minimum_size = Vector2(data.width, 0)
		row.add_child(lbl)
	lb_list_container.add_child(row)


# =============================================================================
#  DIRECT CONNECT — HOST / JOIN / CANCEL LOGIC
# =============================================================================

func _on_host_pressed() -> void:
	var port: int = int(port_field.text)
	if NetworkManager.active_transport == "enet":
		NetworkManager.host_with_code(port)
		status_label.text = "Starting server... fetching room code"
	elif NetworkManager.active_transport == "webrtc":
		NetworkManager.host_game()
		status_label.text = "Connecting to signaling broker..."
	status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	_set_connection_state(LobbyState.HOSTING)


func _on_join_pressed() -> void:
	var code: String = code_field.text.strip_edges()
	if code.length() == 0:
		status_label.text = "Enter a room code first!"
		status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return

	var success: bool = NetworkManager.join_with_code(code)
	if not success:
		status_label.text = "Invalid room code!"
		status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
		return

	status_label.text = "Connecting..."
	status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	_set_connection_state(LobbyState.JOINING)


func _on_cancel_connection() -> void:
	# Remove room from lobby if we were hosting
	if _lobby and _state == LobbyState.HOSTING:
		_lobby.remove_room()
	NetworkManager.disconnect_peer()
	status_label.text = "Cancelled."
	status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_set_connection_state(LobbyState.IDLE)


func _set_connection_state(new_state: LobbyState) -> void:
	_state = new_state
	match new_state:
		LobbyState.IDLE:
			host_btn.visible = true
			host_btn.disabled = false
			join_btn.visible = true
			join_btn.disabled = false
			cancel_btn.visible = false
			start_btn.visible = false
			code_display.visible = false
			copy_btn.visible = false
		LobbyState.HOSTING, LobbyState.JOINING:
			host_btn.visible = false
			join_btn.visible = false
			cancel_btn.visible = true
			start_btn.visible = false
		LobbyState.CONNECTED:
			host_btn.visible = false
			join_btn.visible = false
			cancel_btn.visible = true


func _on_public_ip(ip: String) -> void:
	var port: int = int(port_field.text)
	var result: Dictionary = NetworkManager.generate_room_code(ip, port)
	var code: String = result.get("code", "")
	code_display.text = code
	code_display.visible = true
	copy_btn.visible = true
	status_label.text = "Waiting for opponent..."
	status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))


func _on_room_code_ready(code: String) -> void:
	code_display.text = code
	code_display.visible = true
	copy_btn.visible = true
	status_label.text = "Waiting for opponent..."
	status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(code_display.text.strip_edges())
	copy_btn.text = "COPIED!"
	get_tree().create_timer(1.5).timeout.connect(func(): copy_btn.text = "COPY CODE")


func _on_delay_changed(value: float) -> void:
	delay_label.text = "%d frames" % int(value)
	NetworkManager.input_delay = int(value)
	RollbackManager.input_delay = int(value)


# =============================================================================
#  CONNECTION CALLBACKS
# =============================================================================

func _on_connected() -> void:
	status_label.text = "Connected!"
	status_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	_set_connection_state(LobbyState.CONNECTED)
	if NetworkManager.is_host:
		start_btn.visible = true
		# Update lobby to show room is full
		if _lobby and not _lobby._hosting_room.is_empty():
			_lobby._hosting_room["status"] = "full"
			_lobby.announce_room(_lobby._hosting_room)
	else:
		status_label.text = "Connected! Waiting for host to start..."


func _on_disconnected() -> void:
	status_label.text = "Disconnected."
	status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	_set_connection_state(LobbyState.IDLE)


func _on_failed() -> void:
	status_label.text = "Connection failed! Check code and try again."
	status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	_set_connection_state(LobbyState.IDLE)


func _on_auth_completed(_remote_profile: Dictionary) -> void:
	status_label.text = "Authenticated!"
	status_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))


func _on_auth_failed(reason: String) -> void:
	status_label.text = "Auth failed: " + reason
	status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2))
	_set_connection_state(LobbyState.IDLE)


# =============================================================================
#  START MATCH / NAVIGATION
# =============================================================================

func _on_start_pressed() -> void:
	GameManager.online_mode = true
	GameManager.ai_mode = false
	GameManager.training_mode = false
	NetworkManager.start_game()
	NetworkManager.notify_game_start()
	get_tree().change_scene_to_file("res://scenes/ui/side_select.tscn")


func _on_back_pressed() -> void:
	# If in connection state, cancel instead of leaving
	if _state != LobbyState.IDLE:
		_on_cancel_connection()
		return
	# Remove room from lobby before leaving
	if _lobby:
		_lobby.remove_room()
	NetworkManager.disconnect_peer()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _input(event: InputEvent) -> void:
	if InputManager.is_back_event(event):
		_on_back_pressed()


# =============================================================================
#  PROCESS (lobby tick + matchmaking tick)
# =============================================================================

var _lobby_refresh_timer: float = 0.0
const LOBBY_REFRESH_INTERVAL: float = 10.0  # Re-subscribe every 10s to catch missed rooms

func _process(delta):
	# Tick lobby discovery for heartbeats and stale cleanup
	if _lobby_browsing and _lobby:
		_lobby.tick(delta)
		# Periodic re-subscribe to ensure we catch all rooms
		_lobby_refresh_timer += delta
		if _lobby_refresh_timer >= LOBBY_REFRESH_INTERVAL:
			_lobby_refresh_timer = 0.0
			var sig: SignalingClient = NetworkManager.get_signaling()
			if sig.is_connected_to_broker():
				_lobby.start_browsing()

	# Tick matchmaking queue
	if _matchmaking and _matchmaking.is_in_queue():
		_matchmaking.tick(delta)
