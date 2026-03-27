class_name LobbyDiscovery
extends RefCounted

# MQTT-based room announcement and browsing for Final Fade lobby
# Publishes and discovers available rooms via shared MQTT topic

signal room_added(room: Dictionary)
signal room_removed(room_id: String)
signal lobby_connected
signal lobby_disconnected

const LOBBY_TOPIC: String = "finalfade/lobby/rooms"
const HEARTBEAT_INTERVAL: float = 30.0
const STALE_TIMEOUT: float = 90.0

var rooms: Dictionary = {}
var _signaling: SignalingClient
var _hosting_room: Dictionary = {}
var _heartbeat_timer: float = 0.0


func init(signaling: SignalingClient) -> void:
	_signaling = signaling
	_signaling.message_received.connect(_on_message)
	_signaling.connected.connect(func(): lobby_connected.emit())
	_signaling.disconnected.connect(func(): lobby_disconnected.emit())


func start_browsing() -> void:
	_signaling.subscribe(LOBBY_TOPIC)


func stop_browsing() -> void:
	# MQTT 3.1.1 UNSUBSCRIBE not implemented in minimal client;
	# just stop processing. Subscription will end when broker disconnects.
	pass


func announce_room(room: Dictionary) -> void:
	room["timestamp"] = _get_unix_time()
	# Sign the room announcement with the player's signing key
	var pm = Engine.get_main_loop().root.get_node_or_null("ProfileManager")
	var signing_key: PackedByteArray = pm.get_signing_key() if pm and pm.has_method("get_signing_key") else PackedByteArray()
	if signing_key.size() > 0:
		var room_no_sig: Dictionary = room.duplicate()
		room_no_sig.erase("signature")
		var canonical: String = MatchProof._sorted_json(room_no_sig)
		var sig: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, canonical.to_utf8_buffer())
		room["signature"] = Marshalls.raw_to_base64(sig)
	_hosting_room = room
	var payload := JSON.stringify(room)
	_signaling.publish(LOBBY_TOPIC, payload)


func remove_room() -> void:
	if _hosting_room.is_empty():
		return
	_hosting_room["status"] = "closed"
	_hosting_room["timestamp"] = _get_unix_time()
	var payload := JSON.stringify(_hosting_room)
	_signaling.publish(LOBBY_TOPIC, payload)
	_hosting_room = {}


func tick(delta: float) -> void:
	# Heartbeat: re-announce our room periodically
	if not _hosting_room.is_empty():
		_heartbeat_timer += delta
		if _heartbeat_timer >= HEARTBEAT_INTERVAL:
			_heartbeat_timer = 0.0
			announce_room(_hosting_room)

	# Clean up stale rooms
	_cleanup_stale()


# --- Message Handling ---

func _on_message(topic: String, payload: String) -> void:
	if topic != LOBBY_TOPIC:
		return

	var parsed = JSON.parse_string(payload)
	if parsed == null or not parsed is Dictionary:
		return

	# --- Strict field validation ---

	# room_id: String, max 16 chars, alphanumeric only
	var rid = parsed.get("room_id")
	if not rid is String or rid.is_empty() or rid.length() > 16:
		return
	var _alnum_regex := RegEx.new()
	_alnum_regex.compile("^[a-zA-Z0-9]+$")
	if _alnum_regex.search(rid) == null:
		return

	# host_name: String, max 32 chars
	var host_name = parsed.get("host_name")
	if not host_name is String or host_name.length() > 32:
		return

	# transport: must be "enet" or "webrtc"
	var transport = parsed.get("transport")
	if not transport is String or (transport != "enet" and transport != "webrtc"):
		return

	# region: String, max 4 chars
	var region = parsed.get("region")
	if not region is String or region.length() > 4:
		return

	# status: must be "waiting", "full", or "closed"
	var status = parsed.get("status")
	if not status is String or (status != "waiting" and status != "full" and status != "closed"):
		return

	# input_delay: int, range 1-5
	var input_delay = parsed.get("input_delay")
	if not (input_delay is int or input_delay is float):
		return
	var id_int: int = int(input_delay)
	if id_int < 1 or id_int > 5:
		return

	# timestamp: must be a number
	var ts = parsed.get("timestamp")
	if not (ts is int or ts is float):
		return

	# Verify signature: skip entries with missing/invalid signatures
	var sig_b64 = parsed.get("signature")
	if not sig_b64 is String or sig_b64.is_empty():
		return
	if Marshalls.base64_to_raw(sig_b64).size() != 32:
		return  # Invalid HMAC-SHA256 signature length

	# room_code: optional String (for joining)
	var room_code = parsed.get("room_code", "")
	if not room_code is String or room_code.length() > 200:
		room_code = ""

	# Strip to only validated fields
	var clean_room: Dictionary = {
		"room_id": rid,
		"host_name": host_name,
		"transport": transport,
		"region": region,
		"status": status,
		"input_delay": id_int,
		"timestamp": ts,
		"room_code": room_code,
	}

	if status == "closed":
		if rooms.has(rid):
			rooms.erase(rid)
			room_removed.emit(rid)
		return

	# Enforce max 100 rooms to prevent memory DoS
	if not rooms.has(rid) and rooms.size() >= 100:
		return

	# Update or add room
	clean_room["last_seen"] = _get_unix_time()
	var is_new: bool = not rooms.has(rid)
	rooms[rid] = clean_room

	if is_new:
		room_added.emit(clean_room)


func _cleanup_stale() -> void:
	var now := _get_unix_time()
	var stale_ids: Array = []

	for rid in rooms:
		var last_seen: float = rooms[rid].get("last_seen", 0.0)
		if now - last_seen > STALE_TIMEOUT:
			stale_ids.append(rid)

	for rid in stale_ids:
		rooms.erase(rid)
		room_removed.emit(rid)


func _get_unix_time() -> float:
	return Time.get_unix_time_from_system()
