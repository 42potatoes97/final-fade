extends Node

# Network manager for Final Fade online play
# Transport-agnostic: supports ENet (LAN/direct) and WebRTC (internet)
# Handles encrypted room codes, auth handshake, input exchange with CRC32

signal connected_to_peer
signal disconnected
signal connection_failed
signal remote_input_received(frame: int, input_bits: int)
signal auth_completed(remote_profile: Dictionary)
signal auth_failed(reason: String)
signal room_code_ready(code: String)
signal transport_changed(transport_name: String)
signal desync_detected(frame: int)
signal match_proof_received(proof_data: Dictionary)
signal match_signature_received(sig_data: String)

enum ConnectionState { DISCONNECTED, HOSTING, JOINING, AUTHENTICATING, CONNECTED, IN_GAME }

var connection_state: ConnectionState = ConnectionState.DISCONNECTED
var is_host: bool = false
var local_player_id: int = 1
var remote_player_id: int = 2
var remote_peer_id: int = -1
var input_delay: int = 2
var active_transport: String = "enet"  # "enet" or "webrtc"

# Input exchange
const INPUT_REDUNDANCY: int = 10
var _sent_inputs: Dictionary = {}

# Security
var _session_key: PackedByteArray = PackedByteArray()
var _packet_key: PackedByteArray = PackedByteArray()  # Derived from session key for HMAC
var _auth_nonce: PackedByteArray = PackedByteArray()
var _auth_timer: float = 0.0
var _pending_webrtc_code: String = ""
var _connect_timer: float = 0.0
const CONNECT_TIMEOUT_SEC: float = 30.0  # Give ICE negotiation time to complete
var _auth_pending: bool = false

# Transport instances
var _enet_transport: TransportENet = null
var _signaling: SignalingClient = null
var _webrtc_transport = null  # TransportWebRTC — loaded dynamically
var _lobby: LobbyDiscovery = null
var _quality: ConnectionQuality = ConnectionQuality.new()
var _anticheat_ref = null  # Set by fight_scene, used for hash comparison

# Public IP
signal public_ip_fetched(ip: String)
var public_ip: String = ""


func _ready() -> void:
	_enet_transport = TransportENet.new()
	_enet_transport.init(get_tree())
	_enet_transport.peer_connected.connect(_on_transport_peer_connected)
	_enet_transport.peer_disconnected.connect(_on_transport_peer_disconnected)
	_enet_transport.connection_established.connect(_on_transport_connected)
	_enet_transport.connection_failed.connect(_on_transport_failed)

	# Listen for Godot's built-in multiplayer peer signals (works for both ENet and WebRTC)
	multiplayer.peer_connected.connect(_on_multiplayer_peer_connected)
	multiplayer.peer_disconnected.connect(_on_multiplayer_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_multiplayer_connected_to_server)
	multiplayer.connection_failed.connect(_on_multiplayer_connection_failed)


func get_signaling() -> SignalingClient:
	if _signaling == null:
		_signaling = SignalingClient.new()
		_signaling.name = "SignalingClient"
		add_child(_signaling)
	return _signaling


func get_lobby() -> LobbyDiscovery:
	if _lobby == null:
		_lobby = LobbyDiscovery.new()
		_lobby.init(get_signaling())
	return _lobby


# --- Transport Selection ---

func set_transport(name: String) -> void:
	active_transport = name
	transport_changed.emit(name)


# --- Host / Join ---

func host_game(port: int = 7000) -> void:
	_connect_timer = 0.0
	if active_transport == "enet":
		var peer: ENetMultiplayerPeer = _enet_transport.create_host(port)
		if peer == null:
			connection_failed.emit()
			return
		multiplayer.multiplayer_peer = peer
		is_host = true
		local_player_id = 1
		remote_player_id = 2
		connection_state = ConnectionState.HOSTING
		# Fetch public IP for room code
		fetch_public_ip()
	elif active_transport == "webrtc":
		_init_webrtc_transport()
		is_host = true
		local_player_id = 1
		remote_player_id = 2
		connection_state = ConnectionState.HOSTING
		# Must connect to signaling broker before creating offer
		var sig := get_signaling()
		if sig.is_connected_to_broker():
			_webrtc_create_host_room()
		else:
			if not sig.connected.is_connected(_webrtc_create_host_room):
				sig.connected.connect(_webrtc_create_host_room, CONNECT_ONE_SHOT)
			sig.connect_to_broker()


func _webrtc_create_host_room() -> void:
	print("[NetworkManager] Creating WebRTC host room...")
	var peer = _webrtc_transport.create_host()
	if peer:
		multiplayer.multiplayer_peer = peer
		print("[NetworkManager] WebRTC host room created, room_id: %s" % _webrtc_transport.get_room_id())
	else:
		print("[NetworkManager] WebRTC create_host returned null peer")


func _webrtc_join_room() -> void:
	print("[NetworkManager] Joining WebRTC room: %s" % _pending_webrtc_code)
	var peer = _webrtc_transport.create_client(_pending_webrtc_code)
	if peer:
		multiplayer.multiplayer_peer = peer
		print("[NetworkManager] WebRTC client peer created, waiting for offer...")
	else:
		print("[NetworkManager] WebRTC create_client returned null peer")
	_pending_webrtc_code = ""


func join_game(ip: String, port: int = 7000) -> void:
	if active_transport == "enet":
		var peer: ENetMultiplayerPeer = _enet_transport.create_client(ip, port)
		if peer == null:
			connection_failed.emit()
			return
		multiplayer.multiplayer_peer = peer
		is_host = false
		local_player_id = 2
		remote_player_id = 1
		connection_state = ConnectionState.JOINING
	elif active_transport == "webrtc":
		pass  # WebRTC uses join_with_code


func join_with_code(code: String) -> bool:
	if active_transport == "enet":
		var decoded: Dictionary = CryptoUtils.decode_room_code(code)
		if not decoded.get("valid", false):
			return false
		_session_key = decoded["session_key"]
		join_game(decoded["ip"], decoded["port"])
		return true
	elif active_transport == "webrtc":
		_init_webrtc_transport()
		is_host = false
		local_player_id = 2
		remote_player_id = 1
		connection_state = ConnectionState.JOINING
		_pending_webrtc_code = code
		# Must connect to signaling broker before subscribing
		var sig := get_signaling()
		if sig.is_connected_to_broker():
			_webrtc_join_room()
		else:
			if not sig.connected.is_connected(_webrtc_join_room):
				sig.connected.connect(_webrtc_join_room, CONNECT_ONE_SHOT)
			sig.connect_to_broker()
		return true
	return false


func host_with_code(port: int = 7000) -> void:
	host_game(port)


func disconnect_peer() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	connection_state = ConnectionState.DISCONNECTED
	remote_peer_id = -1
	_sent_inputs.clear()
	_session_key = PackedByteArray()
	_packet_key = PackedByteArray()
	_auth_pending = false
	# Reset WebRTC transport for next match
	if _webrtc_transport != null:
		_webrtc_transport.reset()
	# Remove lobby listing
	if _lobby:
		_lobby.remove_room()
	_anticheat_ref = null
	disconnected.emit()


func start_game() -> void:
	connection_state = ConnectionState.IN_GAME
	_sent_inputs.clear()


func notify_game_start() -> void:
	_rpc_sync_start.rpc()


# --- Input Exchange via RPC (unreliable_ordered for low latency) ---

func send_input(frame: int, input_bits: int) -> void:
	_sent_inputs[frame] = input_bits

	# Build redundancy: pack last N frames as a flat array [f0, i0, f1, i1, ...]
	var count: int = mini(INPUT_REDUNDANCY, _sent_inputs.size())
	var redundant: Array = []
	for i in range(count):
		var f: int = frame - count + 1 + i
		redundant.append(f)
		redundant.append(_sent_inputs.get(f, 0))

	if remote_peer_id > 0:
		_rpc_input.rpc_id(remote_peer_id, frame, input_bits, redundant)

	# Prune old inputs
	var cutoff: int = frame - INPUT_REDUNDANCY
	var to_erase: Array = []
	for f in _sent_inputs:
		if f < cutoff:
			to_erase.append(f)
	for f in to_erase:
		_sent_inputs.erase(f)


@rpc("any_peer", "unreliable_ordered")
func _rpc_input(frame: int, input_bits: int, redundant: Array) -> void:
	# Process redundant frames first (older frames we may have missed)
	var i: int = 0
	while i + 1 < redundant.size():
		var rf: int = int(redundant[i])
		var ri: int = int(redundant[i + 1])
		remote_input_received.emit(rf, ri)
		i += 2
	# Process the current frame
	remote_input_received.emit(frame, input_bits)


# --- Room Code (Encrypted) ---

func generate_room_code(ip: String, port: int) -> Dictionary:
	return CryptoUtils.generate_room_code(ip, port)


func announce_to_lobby(room_code: String) -> void:
	if _lobby == null:
		return
	var pm = get_node_or_null("/root/ProfileManager")
	_lobby.announce_room({
		"room_id": room_code.substr(0, 16) if room_code.length() > 16 else room_code,
		"room_code": room_code,
		"host_name": pm.username if pm else "Unknown",
		"transport": active_transport,
		"region": "",
		"input_delay": input_delay,
		"status": "waiting",
	})


# --- Auth Handshake ---

func _start_auth_as_host() -> void:
	_auth_pending = true
	_auth_timer = 0.0
	_auth_nonce = CryptoUtils.generate_nonce()
	# Wait for HELLO, then send CHALLENGE


func _start_auth_as_joiner() -> void:
	_auth_pending = true
	_auth_timer = 0.0
	# Send HELLO
	var profile: Dictionary = {}
	if Engine.has_singleton("ProfileManager") or has_node("/root/ProfileManager"):
		var pm = get_node_or_null("/root/ProfileManager")
		if pm:
			profile = pm.get_display_identity()
	var session_token = CryptoUtils.hmac_sha256(_session_key, "finalfade-session-token".to_utf8_buffer()).slice(0, 16)
	var hello: PackedByteArray = AuthHandshake.create_hello(profile, session_token)
	_send_reliable(hello)


func _process_auth_packet(data: PackedByteArray) -> void:
	var parsed: Dictionary = AuthHandshake.parse_packet(data)
	if parsed.is_empty():
		return

	var msg_type: int = parsed["type"]

	if is_host:
		if msg_type == AuthHandshake.HandshakeMsg.HELLO:
			# Send CHALLENGE with hashed nonce
			var challenge: PackedByteArray = AuthHandshake.create_challenge(_auth_nonce)
			_send_reliable(challenge)
		elif msg_type == AuthHandshake.HandshakeMsg.RESPONSE:
			# Verify HMAC — joiner computed HMAC(session_key, nonce_hash)
			# We compute the same: hash our nonce, then verify
			var nonce_hash: PackedByteArray = AuthHandshake._hash_for_challenge(_auth_nonce)
			var expected_hmac: PackedByteArray = CryptoUtils.hmac_sha256(_session_key, nonce_hash)
			var response_hmac: PackedByteArray = Marshalls.base64_to_raw(parsed.get("hmac", ""))
			if AuthHandshake.verify_response(response_hmac, _session_key, nonce_hash):
				# Auth success — derive packet signing key
				_derive_packet_key()
				var pm = get_node_or_null("/root/ProfileManager")
				var host_profile: Dictionary = pm.get_display_identity() if pm else {}
				var ok_packet: PackedByteArray = AuthHandshake.create_auth_ok(host_profile)
				_send_reliable(ok_packet)
				_auth_pending = false
				connection_state = ConnectionState.CONNECTED
				auth_completed.emit(parsed.get("profile", {}))
				connected_to_peer.emit()
			else:
				var fail_packet: PackedByteArray = AuthHandshake.create_auth_fail("Invalid credentials")
				_send_reliable(fail_packet)
				_auth_pending = false
				auth_failed.emit("Authentication failed")
				# Disconnect after short delay
				get_tree().create_timer(0.5).timeout.connect(disconnect_peer)
	else:
		# Joiner
		if msg_type == AuthHandshake.HandshakeMsg.CHALLENGE:
			var nonce_hash_b64: String = parsed.get("nonce_hash", "")
			var nonce_hash: PackedByteArray = Marshalls.base64_to_raw(nonce_hash_b64)
			var response: PackedByteArray = AuthHandshake.create_response(nonce_hash, _session_key)
			_send_reliable(response)
		elif msg_type == AuthHandshake.HandshakeMsg.AUTH_OK:
			_derive_packet_key()
			_auth_pending = false
			connection_state = ConnectionState.CONNECTED
			auth_completed.emit(parsed.get("profile", {}))
			connected_to_peer.emit()
		elif msg_type == AuthHandshake.HandshakeMsg.AUTH_FAIL:
			_auth_pending = false
			auth_failed.emit(parsed.get("reason", "Unknown"))


func _derive_packet_key() -> void:
	# Derive a separate key for packet HMAC from the session key
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(_session_key)
	ctx.update("finalfade-packet-hmac".to_utf8_buffer())
	_packet_key = ctx.finish()


func _send_reliable(data: PackedByteArray) -> void:
	if remote_peer_id > 0 and multiplayer.multiplayer_peer:
		# Use RPC for reliable delivery
		_rpc_auth_data.rpc_id(remote_peer_id, data)


@rpc("any_peer", "reliable")
func _rpc_auth_data(data: PackedByteArray) -> void:
	_process_auth_packet(data)


@rpc("any_peer", "reliable")
func _rpc_sync_start() -> void:
	connection_state = ConnectionState.IN_GAME


@rpc("any_peer", "reliable")
func _rpc_rematch_request() -> void:
	pass


# --- Menu Sync (side select, char select, stage select) ---

signal menu_sync_received(data: Dictionary)

func send_menu_sync(data: Dictionary) -> void:
	if remote_peer_id > 0:
		var bytes: PackedByteArray = JSON.stringify(data).to_utf8_buffer()
		_rpc_menu_sync.rpc_id(remote_peer_id, bytes)
		print("[MenuSync] Sent: %s" % str(data))


@rpc("any_peer", "reliable")
func _rpc_menu_sync(json_bytes: PackedByteArray) -> void:
	var parsed = JSON.parse_string(json_bytes.get_string_from_utf8())
	if parsed is Dictionary:
		print("[MenuSync] Received: %s" % str(parsed))
		menu_sync_received.emit(parsed)


@rpc("any_peer", "unreliable")
func _rpc_state_hash(hash_data: PackedByteArray) -> void:
	if _anticheat_ref == null:
		return
	var local_hash = _anticheat_ref._last_local_hash
	if local_hash.is_empty():
		return
	if not _anticheat_ref.compare_hashes(local_hash, hash_data):
		push_warning("NetworkManager: State hash mismatch (desync %d)" % _anticheat_ref.desync_count)
	if _anticheat_ref.is_desynced():
		desync_detected.emit(RollbackManager.current_frame)


@rpc("any_peer", "reliable")
func _rpc_match_proof(data: PackedByteArray) -> void:
	var json_str = data.get_string_from_utf8()
	var json = JSON.new()
	if json.parse(json_str) == OK and json.data is Dictionary:
		match_proof_received.emit(json.data)


@rpc("any_peer", "reliable")
func _rpc_match_signature(data: PackedByteArray) -> void:
	var sig_str = data.get_string_from_utf8()
	match_signature_received.emit(sig_str)


# --- Ping / Connection Quality ---

func send_ping() -> void:
	if remote_peer_id > 0 and multiplayer.multiplayer_peer:
		var ping_data: PackedByteArray = _quality.create_ping_packet()
		multiplayer.multiplayer_peer.put_packet(ping_data)


func get_quality() -> ConnectionQuality:
	return _quality


func send_match_proof(proof_data: Dictionary) -> void:
	if remote_peer_id > 0:
		var json_bytes = JSON.stringify(proof_data).to_utf8_buffer()
		_rpc_match_proof.rpc_id(remote_peer_id, json_bytes)


func send_match_signature(signature: String) -> void:
	if remote_peer_id > 0:
		_rpc_match_signature.rpc_id(remote_peer_id, signature.to_utf8_buffer())


# --- Transport Callbacks ---

# --- Godot SceneMultiplayer signals (primary for WebRTC) ---

func _on_multiplayer_peer_connected(id: int) -> void:
	print("[NetworkManager] Multiplayer peer connected! id=%d" % id)
	_on_transport_peer_connected(id)


func _on_multiplayer_peer_disconnected(id: int) -> void:
	print("[NetworkManager] Multiplayer peer disconnected! id=%d" % id)
	# During IN_GAME, don't reset — WebRTC may reconnect via ICE restart
	if connection_state == ConnectionState.IN_GAME:
		print("[NetworkManager] Peer lost during game — keeping state for reconnection")
		return
	disconnected.emit()


func _on_multiplayer_connected_to_server() -> void:
	print("[NetworkManager] Connected to server (as client)!")
	_on_transport_connected()


func _on_multiplayer_connection_failed() -> void:
	print("[NetworkManager] Multiplayer connection failed!")
	connection_failed.emit()


# --- Transport-level signals (backup, used by ENet transport) ---

func _on_transport_peer_connected(id: int) -> void:
	print("[NetworkManager] Peer connected! id=%d" % id)
	remote_peer_id = id
	if _session_key.size() > 0:
		# Auth handshake
		connection_state = ConnectionState.AUTHENTICATING
		if is_host:
			_start_auth_as_host()
		else:
			_start_auth_as_joiner()
	else:
		# No session key (e.g., WebRTC room code doesn't embed key) — skip auth
		connection_state = ConnectionState.CONNECTED
		connected_to_peer.emit()


func _on_transport_peer_disconnected(_id: int) -> void:
	remote_peer_id = -1
	connection_state = ConnectionState.DISCONNECTED
	disconnected.emit()


func _on_transport_connected() -> void:
	print("[NetworkManager] Transport connected! is_host=%s" % str(is_host))
	# Client connected to server
	if not is_host:
		remote_peer_id = 1
		if _session_key.size() > 0:
			connection_state = ConnectionState.AUTHENTICATING
			_start_auth_as_joiner()
		else:
			connection_state = ConnectionState.CONNECTED
			print("[NetworkManager] P2P connection established!")
			connected_to_peer.emit()


func _on_transport_failed() -> void:
	connection_state = ConnectionState.DISCONNECTED
	connection_failed.emit()


# --- WebRTC Init ---

func _init_webrtc_transport() -> void:
	if _webrtc_transport != null:
		return
	var WebRTCScript = load("res://scripts/network/transport_webrtc.gd")
	_webrtc_transport = WebRTCScript.new()
	_webrtc_transport.init(get_signaling())
	_webrtc_transport.peer_connected.connect(_on_transport_peer_connected)
	_webrtc_transport.peer_disconnected.connect(_on_transport_peer_disconnected)
	_webrtc_transport.connection_established.connect(_on_transport_connected)
	_webrtc_transport.connection_failed.connect(_on_transport_failed)
	if _webrtc_transport.has_signal("signaling_ready"):
		_webrtc_transport.signaling_ready.connect(func(room_id: String): room_code_ready.emit(room_id))


# --- Packet Processing ---

func _process(delta: float) -> void:
	# Connection timeout — only for ENet JOINING (WebRTC needs more time for ICE)
	if connection_state == ConnectionState.JOINING and active_transport == "enet":
		_connect_timer += delta
		if _connect_timer >= CONNECT_TIMEOUT_SEC:
			_connect_timer = 0.0
			connection_failed.emit()
			disconnect_peer()
			return

	# Auth timeout
	if _auth_pending:
		_auth_timer += delta
		if _auth_timer >= AuthHandshake.TIMEOUT_SEC:
			_auth_pending = false
			auth_failed.emit("Authentication timed out")
			disconnect_peer()
			return

	if connection_state < ConnectionState.CONNECTED:
		if connection_state == ConnectionState.AUTHENTICATING:
			# Still poll for auth packets during handshake
			_poll_packets()
		return
	if multiplayer.multiplayer_peer == null:
		return

	# Input exchange now uses RPC (_rpc_input) so no raw packet polling needed.
	# _poll_packets() is only used during auth handshake (above).

	# Periodic ping (handled by RollbackManager during gameplay)


func _poll_packets() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	while multiplayer.multiplayer_peer.get_available_packet_count() > 0:
		var data: PackedByteArray = multiplayer.multiplayer_peer.get_packet()
		# Check for ping/pong
		if _quality.is_ping_packet(data):
			var pong: PackedByteArray = _quality.create_pong_packet(data)
			multiplayer.multiplayer_peer.put_packet(pong)
			continue
		if _quality.is_pong_packet(data):
			_quality.process_pong(data)
			continue
		# Verify packet integrity (HMAC if key available, CRC32 fallback)
		if _packet_key.size() > 0:
			if not CryptoUtils.verify_packet(data, _packet_key):
				continue  # Drop forged/corrupted packet
			var payload: PackedByteArray = CryptoUtils.strip_mac(data)
			_parse_input_packet(payload)
			continue
		if not CryptoUtils.verify_crc32(data):
			continue
		var payload: PackedByteArray = CryptoUtils.strip_crc32(data)
		_parse_input_packet(payload)


func _parse_input_packet(data: PackedByteArray) -> void:
	if data.size() < 5:
		return
	var count: int = data[4]
	var offset: int = 5
	for i in range(count):
		if offset + 5 > data.size():
			break
		var frame: int = data.decode_u32(offset)
		var input_bits: int = data[offset + 4]
		offset += 5
		remote_input_received.emit(frame, input_bits)


# --- Public IP ---

func fetch_public_ip() -> void:
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_ip_fetched.bind(http))
	http.request("https://api.ipify.org")


func _on_ip_fetched(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS:
		public_ip = body.get_string_from_ascii().strip_edges()
	else:
		public_ip = get_local_ip()
	public_ip_fetched.emit(public_ip)


func get_local_ip() -> String:
	var addresses: PackedStringArray = IP.get_local_addresses()
	for addr in addresses:
		if "." in addr and not addr.begins_with("127."):
			return addr
	return "127.0.0.1"
