class_name FirebaseLobby
extends Node

# Firebase Realtime Database lobby for Final Fade
# Replaces MQTT-based discovery with reliable REST API polling
# Uses the same Firebase project as the ranked/leaderboard system

signal room_added(room: Dictionary)
signal room_updated(room: Dictionary)
signal room_removed(room_id: String)
signal lobby_connected
signal lobby_disconnected

const POLL_INTERVAL: float = 3.0       # Fetch room list every 3s
const HEARTBEAT_INTERVAL: float = 4.0  # Re-announce our room every 4s (before stale timeout)
const STALE_TIMEOUT: float = 12.0      # Remove rooms not updated in 12s

var rooms: Dictionary = {}
var _hosting_room: Dictionary = {}
var _heartbeat_timer: float = 0.0
var _poll_timer: float = 0.0
var _connected: bool = false
var _browsing: bool = false
var _db_url: String = ""


const FIREBASE_DB_URL: String = "https://final-fade-default-rtdb.firebaseio.com"

func init(_signaling = null) -> void:
	# Compatible with LobbyDiscovery interface (signaling not used)
	_db_url = FIREBASE_DB_URL
	if _db_url.is_empty():
		push_warning("FirebaseLobby: No Firebase URL configured")
		return
	_connected = true
	# Defer so signal handlers can be connected first
	call_deferred("_emit_connected")


func _emit_connected() -> void:
	lobby_connected.emit()


func start_browsing() -> void:
	_browsing = true
	_poll_timer = POLL_INTERVAL  # Trigger immediate poll on next tick


func stop_browsing() -> void:
	_browsing = false


func announce_room(room: Dictionary) -> void:
	if _db_url.is_empty():
		push_warning("FirebaseLobby: Cannot announce — no Firebase URL")
		return

	room["timestamp"] = Time.get_unix_time_from_system()
	_hosting_room = room

	var rid: String = room.get("room_id", "unknown")
	var url: String = _db_url + "/lobbies/" + rid + ".json"
	var payload: String = JSON.stringify(room)
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])

	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(
		func(_result: int, _code: int, _h: PackedStringArray, _body: PackedByteArray) -> void:
			http.queue_free()
	)
	http.request(url, headers, HTTPClient.METHOD_PUT, payload)
	print("[FirebaseLobby] Room announced: %s" % rid)


func remove_room() -> void:
	if _hosting_room.is_empty() or _db_url.is_empty():
		return
	var rid: String = _hosting_room.get("room_id", "unknown")
	var url: String = _db_url + "/lobbies/" + rid + ".json"

	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(
		func(_result: int, _code: int, _h: PackedStringArray, _body: PackedByteArray) -> void:
			http.queue_free()
	)
	http.request(url, [], HTTPClient.METHOD_DELETE)
	_hosting_room = {}
	print("[FirebaseLobby] Room removed: %s" % rid)


func tick(delta: float) -> void:
	# Heartbeat: re-announce our room so timestamp stays fresh
	if not _hosting_room.is_empty():
		_heartbeat_timer += delta
		if _heartbeat_timer >= HEARTBEAT_INTERVAL:
			_heartbeat_timer = 0.0
			announce_room(_hosting_room)

	# Poll for rooms
	if _browsing and not _db_url.is_empty():
		_poll_timer += delta
		if _poll_timer >= POLL_INTERVAL:
			_poll_timer = 0.0
			_poll_rooms()

	# Stale cleanup (fallback for rooms whose host crashed without DELETE)
	_cleanup_stale()


func _poll_rooms() -> void:
	var url: String = _db_url + "/lobbies.json"

	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_poll_completed.bind(http))
	http.request(url)


func _on_poll_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		return

	var text: String = body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	# Firebase returns null for empty paths
	if parsed == null:
		# No rooms at all — remove any we had cached
		var gone: Array = rooms.keys()
		for rid in gone:
			rooms.erase(rid)
			room_removed.emit(rid)
		return
	if not parsed is Dictionary:
		return

	var now: float = Time.get_unix_time_from_system()
	var seen_ids: Array = []

	for rid in parsed:
		var room_data = parsed[rid]
		if not room_data is Dictionary:
			continue

		seen_ids.append(rid)

		# Validate timestamp — skip stale rooms
		var ts = room_data.get("timestamp")
		if not (ts is int or ts is float):
			continue
		if now - float(ts) > STALE_TIMEOUT:
			# Stale room in Firebase — clean it up server-side too
			_delete_stale_room(rid)
			continue

		# Check status
		var status = str(room_data.get("status", ""))
		if status == "closed" or status == "full":
			if rooms.has(rid):
				rooms.erase(rid)
				room_removed.emit(rid)
			continue

		# Build clean room dict
		var clean_room: Dictionary = {
			"room_id": str(rid),
			"host_name": str(room_data.get("host_name", "Unknown")),
			"transport": str(room_data.get("transport", "webrtc")),
			"region": str(room_data.get("region", "")),
			"status": status,
			"input_delay": int(room_data.get("input_delay", 2)),
			"timestamp": ts,
			"room_code": str(room_data.get("room_code", "")),
			"last_seen": now,
		}

		var is_new: bool = not rooms.has(rid)
		rooms[rid] = clean_room

		if is_new:
			room_added.emit(clean_room)
		else:
			room_updated.emit(clean_room)

	# Remove rooms that disappeared from Firebase
	var gone_ids: Array = []
	for rid in rooms:
		if rid not in seen_ids:
			gone_ids.append(rid)
	for rid in gone_ids:
		rooms.erase(rid)
		room_removed.emit(rid)


func _delete_stale_room(rid: String) -> void:
	# Best-effort cleanup of stale rooms in Firebase
	var url: String = _db_url + "/lobbies/" + rid + ".json"
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(
		func(_r: int, _c: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
			http.queue_free()
	)
	http.request(url, [], HTTPClient.METHOD_DELETE)


func _cleanup_stale() -> void:
	var now: float = Time.get_unix_time_from_system()
	var stale_ids: Array = []
	for rid in rooms:
		var last_seen: float = rooms[rid].get("last_seen", 0.0)
		if now - last_seen > STALE_TIMEOUT:
			stale_ids.append(rid)
	for rid in stale_ids:
		rooms.erase(rid)
		room_removed.emit(rid)
