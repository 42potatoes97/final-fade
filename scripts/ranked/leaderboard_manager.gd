class_name LeaderboardManager
extends RefCounted

## Leaderboard for Final Fade ranked play backed by Firebase Realtime Database.
## Players upload proof chains to Firebase; the leaderboard is rebuilt from
## all stored chains. Free Spark plan: 1GB storage, 10GB/month transfer.

signal leaderboard_updated(entries: Array)
signal sync_complete(success: bool)

const LEADERBOARD_TOPIC: String = "finalfade/ranked/leaderboard"
const MAX_KNOWN_PLAYERS: int = 500
const TOP_N: int = 10

var _signaling: SignalingClient
var _leaderboard: Array = []
var _local_proof_chain: Dictionary = {}
var CACHE_PATH: String = "user://leaderboard_cache.json"
var PROOF_CHAIN_PATH: String = "user://proof_chain.json"


func init(signaling: SignalingClient) -> void:
	_signaling = signaling


func load_local_data() -> void:
	_leaderboard = load_leaderboard_cache()

	if FileAccess.file_exists(PROOF_CHAIN_PATH):
		var file: FileAccess = FileAccess.open(PROOF_CHAIN_PATH, FileAccess.READ)
		if file != null:
			var text: String = file.get_as_text()
			file.close()
			var json: JSON = JSON.new()
			if json.parse(text) == OK and json.data is Dictionary:
				_local_proof_chain = json.data
			else:
				_local_proof_chain = {}
	else:
		_local_proof_chain = {}

	# Ensure structure
	if not _local_proof_chain.has("player_id"):
		var pm = Engine.get_main_loop().root.get_node_or_null("ProfileManager")
		_local_proof_chain["player_id"] = pm.profile_id if pm else ""
	if not _local_proof_chain.has("proofs"):
		_local_proof_chain["proofs"] = []
	if not _local_proof_chain.has("chain_hash"):
		_local_proof_chain["chain_hash"] = ""


func save_local_data() -> void:
	save_leaderboard_cache()

	var json_string: String = JSON.stringify(_local_proof_chain, "\t")
	var file: FileAccess = FileAccess.open(PROOF_CHAIN_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(json_string)
		file.close()


func add_proof(proof: Dictionary) -> void:
	if not _local_proof_chain.has("proofs"):
		_local_proof_chain["proofs"] = []

	# Set prev_hash linking
	var existing_proofs: Array = _local_proof_chain["proofs"]
	if existing_proofs.size() > 0:
		proof["prev_hash"] = existing_proofs[existing_proofs.size() - 1].get("match_hash", "")
	else:
		proof["prev_hash"] = ""

	_local_proof_chain["proofs"].append(proof)

	# Recompute chain hash
	var hash_data: String = ""
	for p in _local_proof_chain["proofs"]:
		hash_data += p.get("prev_hash", "")
		hash_data += p.get("match_hash", "")

	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(hash_data.to_utf8_buffer())
	_local_proof_chain["chain_hash"] = ctx.finish().hex_encode()

	save_local_data()


# --- Firebase Upload ---

func publish_proof_chain(_unused_token: String = "", http_node: Node = null) -> void:
	if http_node == null:
		push_warning("LeaderboardManager: No http_node provided for publish")
		return

	var pm = Engine.get_main_loop().root.get_node_or_null("ProfileManager")
	var pid: String = pm.profile_id if pm else _local_proof_chain.get("player_id", "unknown")
	var uname: String = pm.username if pm else "Unknown"

	# Build the entry to upload
	var db_entry: Dictionary = {
		"player_id": pid,
		"username": uname,
		"chain": _local_proof_chain,
		"timestamp": Time.get_unix_time_from_system(),
	}

	var json_bytes: PackedByteArray = JSON.stringify(db_entry).to_utf8_buffer()
	var db_url: String = RankedConfig.FIREBASE_DB_URL

	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
			http.queue_free()
			if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
				sync_complete.emit(true)
				# Also announce on MQTT for real-time discovery
				if _signaling:
					var announcement: Dictionary = {
						"profile_id": pid,
						"username": uname,
						"timestamp": Time.get_unix_time_from_system(),
					}
					_signaling.publish(LEADERBOARD_TOPIC, JSON.stringify(announcement))
			else:
				push_warning("LeaderboardManager: Firebase upload failed (result=%d, code=%d)" % [result, code])
				sync_complete.emit(false)
	)

	# PUT to Firebase: /players/{player_id}.json
	# Firebase REST API: PUT replaces the node entirely
	var url: String = db_url + "/players/" + pid + ".json"
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	http.request_raw(url, headers, HTTPClient.METHOD_PUT, json_bytes)


# --- Firebase Fetch & Rebuild ---

func rebuild_leaderboard(http_node: Node) -> void:
	var db_url: String = RankedConfig.FIREBASE_DB_URL

	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
				push_warning("LeaderboardManager: Firebase fetch failed")
				sync_complete.emit(false)
				return

			var json: JSON = JSON.new()
			if json.parse(body.get_string_from_utf8()) != OK or not json.data is Dictionary:
				push_warning("LeaderboardManager: Invalid Firebase response")
				sync_complete.emit(false)
				return

			_rebuild_from_firebase_data(json.data)
	)

	# GET all players from Firebase
	var url: String = db_url + "/players.json"
	http.request(url)


func _rebuild_from_firebase_data(data: Dictionary) -> void:
	var all_proofs: Array = []
	var player_names: Dictionary = {}  # pid -> username

	var now: float = Time.get_unix_time_from_system()
	var max_age_sec: float = 90.0 * 24.0 * 3600.0  # 90 days

	for pid in data:
		var entry = data[pid]
		if not entry is Dictionary:
			continue

		var uname: String = str(entry.get("username", ""))
		player_names[pid] = uname

		var chain = entry.get("chain", {})
		if not chain is Dictionary:
			continue

		# Verify chain integrity
		if not MatchProof.verify_chain_integrity(chain):
			continue

		var proofs: Array = chain.get("proofs", [])
		for proof in proofs:
			if not MatchProof.verify_proof_structure(proof):
				continue
			all_proofs.append(proof)

	_compute_leaderboard_from_proofs(all_proofs, player_names)


func _compute_leaderboard_from_proofs(all_proofs: Array, player_names: Dictionary = {}) -> void:
	var ratings: Dictionary = RatingCalculator.calculate_ratings_from_chain(all_proofs)

	var entries: Array = []
	for pid in ratings:
		var r: Dictionary = ratings[pid]
		var base_rating: float = float(r.get("rating", 1000))
		var display_rating: int = RatingCalculator.get_display_rating(base_rating, 0.5)

		var uname: String = player_names.get(pid, "")

		entries.append({
			"profile_id": pid,
			"username": uname,
			"rating": display_rating,
			"matches": r.get("matches", 0),
			"wins": r.get("wins", 0),
			"losses": r.get("losses", 0),
		})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["rating"] > b["rating"]
	)

	_leaderboard = entries.slice(0, TOP_N)

	save_leaderboard_cache()
	leaderboard_updated.emit(_leaderboard)
	sync_complete.emit(true)


func get_top_n(n: int = TOP_N) -> Array:
	return _leaderboard.slice(0, n)


func save_leaderboard_cache() -> void:
	var json_string: String = JSON.stringify(_leaderboard, "\t")
	var file: FileAccess = FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(json_string)
		file.close()


func load_leaderboard_cache() -> Array:
	if not FileAccess.file_exists(CACHE_PATH):
		return []
	var file: FileAccess = FileAccess.open(CACHE_PATH, FileAccess.READ)
	if file == null:
		return []
	var text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	if json.parse(text) != OK or not json.data is Array:
		return []
	return json.data


func get_local_rating() -> int:
	if _local_proof_chain.is_empty() or not _local_proof_chain.has("proofs"):
		return roundi(RatingCalculator.DEFAULT_RATING)
	var proofs: Array = _local_proof_chain.get("proofs", [])
	if proofs.is_empty():
		return roundi(RatingCalculator.DEFAULT_RATING)
	var ratings: Dictionary = RatingCalculator.calculate_ratings_from_chain(proofs)
	var pid: String = _local_proof_chain.get("player_id", "")
	if ratings.has(pid):
		return int(ratings[pid].get("rating", RatingCalculator.DEFAULT_RATING))
	return roundi(RatingCalculator.DEFAULT_RATING)


func get_local_skill_score(replay_mgr = null) -> float:
	if replay_mgr and replay_mgr.has_method("get_current_skill_score"):
		return replay_mgr.get_current_skill_score()
	return 0.5
