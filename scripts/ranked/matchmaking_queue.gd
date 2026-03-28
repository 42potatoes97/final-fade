class_name MatchmakingQueue
extends RefCounted

## MQTT-based matchmaking queue for Final Fade ranked play.
## Publishes player entries to per-player subtopics (retained) and evaluates
## candidates using expanding rating/latency ranges over time.
## match_found signal is emitted when a candidate is found — the UI handles
## accept/decline before calling start_match_connection().

signal match_found(opponent: Dictionary)
signal queue_status_changed(status: String)

const RANKED_QUEUE_TOPIC: String = "finalfade/ranked/queue"
const QUICK_QUEUE_TOPIC: String = "finalfade/quick/queue"
const MATCH_TOPIC_PREFIX: String = "finalfade/match/"
const RATING_RANGE_INITIAL: int = 100
const RATING_RANGE_EXPANSION: float = 50.0
const RATING_RANGE_MAX: int = 500
const ANNOUNCE_INTERVAL: float = 5.0
const ENTRY_TIMEOUT: float = 15.0
const MAX_CANDIDATES: int = 200

# Region latency matrix (approximate RTT in ms based on real-world data)
const REGIONS: Array = ["USW", "USC", "USE", "SA", "EUW", "EUE", "AW", "ASEA", "EA", "OCEW", "OCEE"]

const LATENCY_MS: Dictionary = {
	"USW":  {"USW": 0, "USC": 35, "USE": 65, "SA": 120, "EUW": 140, "EUE": 160, "AW": 220, "ASEA": 170, "EA": 110, "OCEW": 160, "OCEE": 180},
	"USC":  {"USW": 35, "USC": 0, "USE": 30, "SA": 100, "EUW": 110, "EUE": 130, "AW": 200, "ASEA": 190, "EA": 140, "OCEW": 180, "OCEE": 200},
	"USE":  {"USW": 65, "USC": 30, "USE": 0, "SA": 80, "EUW": 75, "EUE": 95, "AW": 180, "ASEA": 210, "EA": 170, "OCEW": 200, "OCEE": 220},
	"SA":   {"USW": 120, "USC": 100, "USE": 80, "SA": 0, "EUW": 140, "EUE": 170, "AW": 250, "ASEA": 280, "EA": 260, "OCEW": 220, "OCEE": 240},
	"EUW":  {"USW": 140, "USC": 110, "USE": 75, "SA": 140, "EUW": 0, "EUE": 30, "AW": 80, "ASEA": 160, "EA": 180, "OCEW": 250, "OCEE": 270},
	"EUE":  {"USW": 160, "USC": 130, "USE": 95, "SA": 170, "EUE": 0, "EUW": 30, "AW": 60, "ASEA": 130, "EA": 150, "OCEW": 230, "OCEE": 250},
	"AW":   {"USW": 220, "USC": 200, "USE": 180, "SA": 250, "EUW": 80, "EUE": 60, "AW": 0, "ASEA": 70, "EA": 110, "OCEW": 170, "OCEE": 190},
	"ASEA": {"USW": 170, "USC": 190, "USE": 210, "SA": 280, "EUW": 160, "EUE": 130, "AW": 70, "ASEA": 0, "EA": 50, "OCEW": 100, "OCEE": 120},
	"EA":   {"USW": 110, "USC": 140, "USE": 170, "SA": 260, "EUW": 180, "EUE": 150, "AW": 110, "ASEA": 50, "EA": 0, "OCEW": 110, "OCEE": 130},
	"OCEW": {"USW": 160, "USC": 180, "USE": 200, "SA": 220, "EUW": 250, "EUE": 230, "AW": 170, "ASEA": 100, "EA": 110, "OCEW": 0, "OCEE": 30},
	"OCEE": {"USW": 180, "USC": 200, "USE": 220, "SA": 240, "EUW": 270, "EUE": 250, "AW": 190, "ASEA": 120, "EA": 130, "OCEW": 30, "OCEE": 0},
}

# Max latency thresholds that expand over time (ms)
const LATENCY_TIER_GOOD: int = 80
const LATENCY_TIER_OK: int = 150
const LATENCY_TIER_ROUGH: int = 220
const REGION_EXPAND_INTERVAL: float = 20.0

var _signaling: SignalingClient
var _candidates: Dictionary = {}
var _in_queue: bool = false
var _is_quick_match: bool = false
var _queue_time: float = 0.0
var _announce_timer: float = 0.0
var _local_entry: Dictionary = {}
var _current_range: int = RATING_RANGE_INITIAL
var _active_topic: String = ""
var _publish_topic: String = ""
var _subscribe_topic: String = ""
var _subscribed: bool = false
var _match_pending: bool = false  # True while showing match found dialog


func init(signaling: SignalingClient) -> void:
	_signaling = signaling
	_signaling.message_received.connect(_on_queue_message)


func join_quick_match(region: String, transport: String) -> void:
	_is_quick_match = true
	_join_internal(0, region, transport, QUICK_QUEUE_TOPIC)


func join_queue(rating: int, region: String, transport: String) -> void:
	_is_quick_match = false
	_join_internal(rating, region, transport, RANKED_QUEUE_TOPIC)


func _join_internal(rating: int, region: String, transport: String, topic: String) -> void:
	var pm = Engine.get_main_loop().root.get_node_or_null("ProfileManager")
	var pid: String = pm.profile_id if pm else ""
	var uname: String = pm.username if pm else ""

	_local_entry = {
		"profile_id": pid,
		"username": uname,
		"rating": rating,
		"region": region,
		"transport": transport,
		"timestamp": Time.get_unix_time_from_system(),
	}

	# Sign the entry
	var signing_key: PackedByteArray = pm.signing_key if pm else PackedByteArray()
	if signing_key.size() > 0:
		var canonical: String = MatchProof._sorted_json(_local_entry)
		var sig: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, canonical.to_utf8_buffer())
		_local_entry["signature"] = Marshalls.raw_to_base64(sig)

	_active_topic = topic
	_publish_topic = topic + "/" + pid.left(16)
	_subscribe_topic = topic + "/+"
	_subscribed = false
	_match_pending = false

	if _signaling.is_connected_to_broker():
		_signaling.subscribe(_subscribe_topic)
		_signaling.publish(_publish_topic, JSON.stringify(_local_entry), true)
		_subscribed = true

	_in_queue = true
	_queue_time = 0.0
	_announce_timer = 0.0
	_current_range = RATING_RANGE_INITIAL
	_candidates.clear()
	queue_status_changed.emit("Searching...")


func leave_queue() -> void:
	if not _in_queue:
		return
	# Clear retained message
	if _publish_topic != "" and _signaling.is_connected_to_broker():
		_signaling.publish(_publish_topic, "", true)
	_candidates.clear()
	_in_queue = false
	_subscribed = false
	_match_pending = false
	_local_entry = {}
	queue_status_changed.emit("idle")


func tick(delta: float) -> void:
	if not _in_queue:
		return

	# Retry subscribe once broker is connected
	if not _subscribed and _signaling.is_connected_to_broker():
		_signaling.subscribe(_subscribe_topic)
		_signaling.publish(_publish_topic, JSON.stringify(_local_entry), true)
		_subscribed = true
		_announce_timer = 0.0

	_queue_time += delta
	_announce_timer += delta

	# Re-announce periodically
	if _announce_timer >= ANNOUNCE_INTERVAL:
		_announce_timer = 0.0
		_local_entry["timestamp"] = Time.get_unix_time_from_system()
		var pm = Engine.get_main_loop().root.get_node_or_null("ProfileManager")
		var signing_key: PackedByteArray = pm.signing_key if pm else PackedByteArray()
		if signing_key.size() > 0:
			var entry_no_sig: Dictionary = _local_entry.duplicate()
			entry_no_sig.erase("signature")
			var canonical: String = MatchProof._sorted_json(entry_no_sig)
			var sig: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, canonical.to_utf8_buffer())
			_local_entry["signature"] = Marshalls.raw_to_base64(sig)
		if _signaling.is_connected_to_broker():
			_signaling.publish(_publish_topic, JSON.stringify(_local_entry), true)

	# Expand rating range over time
	_current_range = mini(
		RATING_RANGE_INITIAL + int(_queue_time / 15.0 * RATING_RANGE_EXPANSION),
		RATING_RANGE_MAX,
	)

	# Don't evaluate while a match dialog is showing
	if not _match_pending:
		_evaluate_candidates()
	_cleanup_stale()

	# Update status
	if _subscribed:
		var t: int = int(_queue_time)
		var region: String = _local_entry.get("region", "?")
		queue_status_changed.emit("Searching... [%s] %ds" % [region, t])


func _evaluate_candidates() -> void:
	var local_pid: String = _local_entry.get("profile_id", "")
	var local_rating: int = _local_entry.get("rating", 0)
	var local_transport: String = _local_entry.get("transport", "")
	var local_region: String = _local_entry.get("region", "NA")

	var expand_steps: int = int(_queue_time / REGION_EXPAND_INTERVAL)
	var max_latency: int = LATENCY_TIER_GOOD
	if expand_steps >= 1:
		max_latency = LATENCY_TIER_OK
	if expand_steps >= 2:
		max_latency = LATENCY_TIER_ROUGH
	if expand_steps >= 3:
		max_latency = 999

	var best_pid: String = ""
	var best_latency: int = 999
	var best_rating_diff: int = 999999

	for pid in _candidates:
		if pid == local_pid:
			continue

		var candidate: Dictionary = _candidates[pid]
		var candidate_rating: int = int(candidate.get("rating", 0))
		var candidate_region: String = candidate.get("region", "")

		if not _is_quick_match and absi(candidate_rating - local_rating) > _current_range:
			continue
		if candidate.get("transport", "") != local_transport:
			continue

		var latency: int = _get_region_latency(local_region, candidate_region)
		if latency > max_latency:
			continue

		var rating_diff: int = absi(candidate_rating - local_rating)
		if latency < best_latency or (latency == best_latency and rating_diff < best_rating_diff):
			best_pid = pid
			best_latency = latency
			best_rating_diff = rating_diff

	if best_pid.is_empty():
		return

	var candidate: Dictionary = _candidates[best_pid]
	var is_host: bool = local_pid < best_pid

	var opponent: Dictionary = {
		"profile_id": best_pid,
		"username": candidate.get("username", ""),
		"rating": int(candidate.get("rating", 0)),
		"region": candidate.get("region", ""),
		"transport": candidate.get("transport", ""),
		"is_host": is_host,
		"latency": best_latency,
	}

	# Pause candidate evaluation while dialog is showing
	_match_pending = true
	match_found.emit(opponent)


func resume_search() -> void:
	# Called when user declines a match — resume candidate evaluation
	_match_pending = false


func get_local_entry() -> Dictionary:
	return _local_entry


func start_match_connection(opponent: Dictionary) -> void:
	# Called by the UI after both players accept.
	# Creates a deterministic match topic and initiates WebRTC connection.
	var local_pid: String = _local_entry.get("profile_id", "")
	var opp_pid: String = opponent["profile_id"]
	var sorted_pids: Array = [local_pid, opp_pid]
	sorted_pids.sort()
	var match_topic: String = MATCH_TOPIC_PREFIX + sorted_pids[0].left(16) + "_" + sorted_pids[1].left(16)

	print("[MM] Starting connection: host=%s topic=%s" % [str(opponent["is_host"]), match_topic])

	# Generate a unique match nonce to reject stale retained messages
	var match_nonce: String = "%d_%s" % [int(Time.get_unix_time_from_system()), local_pid.left(8)]

	if opponent["is_host"]:
		# We are the host — connect callback BEFORE host_game() because
		# create_host() emits signaling_ready → room_code_ready synchronously
		NetworkManager.active_transport = "webrtc"
		# First clear any stale retained room code on the match topic
		_signaling.publish(match_topic, "", true)
		NetworkManager.room_code_ready.connect(
			func(code: String):
				var payload: Dictionary = {
					"room_code": code,
					"host_pid": local_pid,
					"nonce": match_nonce,
					"ts": int(Time.get_unix_time_from_system()),
				}
				_signaling.publish(match_topic, JSON.stringify(payload), true)
				print("[MM] Room code published: %s (nonce=%s)" % [code, match_nonce])
		, CONNECT_ONE_SHOT)
		NetworkManager.host_game()
	else:
		# We are the joiner — wait for room code, reject stale retained messages
		_signaling.subscribe(match_topic)
		var _room_joined: bool = false
		var _room_cb: Callable
		_room_cb = func(topic: String, payload: String):
			if _room_joined:
				return
			if topic != match_topic:
				return
			if payload.is_empty():
				return  # Empty retained cleanup
			var parsed = JSON.parse_string(payload)
			if parsed == null or not parsed is Dictionary:
				return
			var code: String = parsed.get("room_code", "")
			if code.is_empty():
				return
			# Reject stale room codes — must be within last 30 seconds
			var msg_ts: int = int(parsed.get("ts", 0))
			var now_ts: int = int(Time.get_unix_time_from_system())
			if abs(now_ts - msg_ts) > 30:
				print("[MM] Ignoring stale room code: %s (age=%ds)" % [code, abs(now_ts - msg_ts)])
				return
			print("[MM] Received room code: %s" % code)
			_room_joined = true
			if _room_cb.is_valid() and _signaling.message_received.is_connected(_room_cb):
				_signaling.message_received.disconnect(_room_cb)
			NetworkManager.active_transport = "webrtc"
			NetworkManager.join_with_code(code)
		_signaling.message_received.connect(_room_cb)

	leave_queue()


func get_region_latency(region_a: String, region_b: String) -> int:
	return _get_region_latency(region_a, region_b)


func _get_region_latency(region_a: String, region_b: String) -> int:
	if region_a == region_b:
		return 0
	var row: Dictionary = LATENCY_MS.get(region_a, {})
	return row.get(region_b, 999)


func _cleanup_stale() -> void:
	var now: float = Time.get_unix_time_from_system()
	var stale_ids: Array = []
	for pid in _candidates:
		var ts: float = float(_candidates[pid].get("timestamp", 0.0))
		if now - ts > ENTRY_TIMEOUT:
			stale_ids.append(pid)
	for pid in stale_ids:
		_candidates.erase(pid)


func _on_queue_message(topic: String, payload: String) -> void:
	if not topic.begins_with(_active_topic):
		return
	if payload.is_empty():
		return  # Empty retained message cleanup — ignore

	var parsed = JSON.parse_string(payload)
	if parsed == null or not parsed is Dictionary:
		return

	var pid = parsed.get("profile_id")
	if not pid is String or pid.is_empty() or pid.length() > 64:
		return
	var local_pid: String = _local_entry.get("profile_id", "")
	if pid == local_pid:
		return  # Own message

	var status = parsed.get("status")
	if status is String and status == "leaving":
		_candidates.erase(pid)
		return

	var uname = parsed.get("username")
	if not uname is String or uname.length() > 32:
		return

	var rating = parsed.get("rating")
	if not (rating is int or rating is float):
		return
	var rating_int: int = int(rating)
	if rating_int != 0 and (rating_int < 100 or rating_int > 9999):
		return

	var region = parsed.get("region")
	if not region is String or region.length() > 4:
		return

	var transport = parsed.get("transport")
	if not transport is String or (transport != "enet" and transport != "webrtc"):
		return

	var ts = parsed.get("timestamp")
	if not (ts is int or ts is float):
		return
	# Reject stale entries (older than ENTRY_TIMEOUT) — catches retained broker messages
	var now: float = Time.get_unix_time_from_system()
	if now - float(ts) > ENTRY_TIMEOUT:
		return

	var sig_b64 = parsed.get("signature")
	if not sig_b64 is String or sig_b64.is_empty():
		return
	if Marshalls.base64_to_raw(sig_b64).size() != 32:
		return

	if not _candidates.has(pid) and _candidates.size() >= MAX_CANDIDATES:
		return

	_candidates[pid] = {
		"profile_id": pid,
		"username": uname,
		"rating": rating_int,
		"region": region,
		"transport": transport,
		"timestamp": ts,
	}


func filter_lobbies(rooms: Dictionary, min_rating: int, max_rating: int) -> Array:
	var result: Array = []
	for rid in rooms:
		var room: Dictionary = rooms[rid]
		var room_rating: int = int(room.get("rating", 0))
		if room_rating >= min_rating and room_rating <= max_rating:
			result.append(room)
	return result


func is_in_queue() -> bool:
	return _in_queue


func get_queue_time() -> float:
	return _queue_time


func get_current_range() -> int:
	return _current_range
