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

	var rid: String = parsed.get("room_id", "")
	if rid.is_empty():
		return

	var status: String = parsed.get("status", "")

	if status == "closed":
		if rooms.has(rid):
			rooms.erase(rid)
			room_removed.emit(rid)
		return

	# Update or add room
	parsed["last_seen"] = _get_unix_time()
	var is_new: bool = not rooms.has(rid)
	rooms[rid] = parsed

	if is_new:
		room_added.emit(parsed)


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
