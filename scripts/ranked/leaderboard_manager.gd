class_name LeaderboardManager
extends RefCounted

## Decentralized leaderboard for Final Fade ranked play.
## Players publish proof chain CIDs via MQTT; peers fetch chains from IPFS,
## verify proofs, and compute ratings to build a shared leaderboard.

signal leaderboard_updated(entries: Array)
signal sync_complete(success: bool)

const LEADERBOARD_TOPIC: String = "finalfade/ranked/leaderboard"
const MAX_KNOWN_PLAYERS: int = 500
const TOP_N: int = 10
const WEB3_STORAGE_URL: String = "https://api.web3.storage"
const IPFS_GATEWAY: String = "https://w3s.link"
const W3NAME_URL: String = "https://name.web3.storage"

var _signaling: SignalingClient
var _known_chain_cids: Dictionary = {}
var _leaderboard: Array = []
var _local_proof_chain: Dictionary = {}
var CACHE_PATH: String = "user://leaderboard_cache.json"
var PROOF_CHAIN_PATH: String = "user://proof_chain.json"


func init(signaling: SignalingClient) -> void:
	_signaling = signaling
	_signaling.message_received.connect(_on_leaderboard_message)


func load_local_data() -> void:
	_leaderboard = load_leaderboard_cache()

	if FileAccess.file_exists(PROOF_CHAIN_PATH):
		var file: FileAccess = FileAccess.open(PROOF_CHAIN_PATH, FileAccess.READ)
		if file != null:
			var text: String = file.get_as_text()
			file.close()
			var json: JSON = JSON.new()
			var err: Error = json.parse(text)
			if err == OK and json.data is Dictionary:
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

	# Set prev_hash linking to the last proof in the chain
	var existing_proofs: Array = _local_proof_chain["proofs"]
	if existing_proofs.size() > 0:
		proof["prev_hash"] = existing_proofs[existing_proofs.size() - 1].get("match_hash", "")
	else:
		proof["prev_hash"] = ""

	_local_proof_chain["proofs"].append(proof)

	# Recompute chain hash using the same pattern as MatchProof.build_proof_chain
	# (includes prev_hash links)
	var hash_data: String = ""
	for p in _local_proof_chain["proofs"]:
		hash_data += p.get("prev_hash", "")
		hash_data += p.get("match_hash", "")

	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(hash_data.to_utf8_buffer())
	_local_proof_chain["chain_hash"] = ctx.finish().hex_encode()

	save_local_data()


func publish_proof_chain(api_token: String, http_node: Node) -> void:
	var json_string: String = JSON.stringify(_local_proof_chain)
	var json_bytes: PackedByteArray = json_string.to_utf8_buffer()

	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
				push_error("LeaderboardManager: IPFS upload failed (result=%d, code=%d)" % [result, code])
				return

			var json: JSON = JSON.new()
			var err: Error = json.parse(body.get_string_from_utf8())
			if err != OK or not json.data is Dictionary:
				push_error("LeaderboardManager: Failed to parse upload response")
				return

			var cid: String = json.data.get("cid", "")
			if cid.is_empty():
				push_error("LeaderboardManager: No CID in upload response")
				return

			announce_chain_cid(cid)
	)

	var upload_headers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer " + api_token,
		"Content-Type: application/json",
	])
	http.request_raw(WEB3_STORAGE_URL + "/upload", upload_headers, HTTPClient.METHOD_POST, json_bytes)


func announce_chain_cid(cid: String) -> void:
	var pm = Engine.get_main_loop().root.get_node_or_null("ProfileManager")
	var pid: String = pm.profile_id if pm else ""
	var uname: String = pm.username if pm else ""

	var announcement: Dictionary = {
		"profile_id": pid,
		"username": uname,
		"cid": cid,
		"timestamp": Time.get_unix_time_from_system(),
	}
	_signaling.publish(LEADERBOARD_TOPIC, JSON.stringify(announcement))


func start_listening() -> void:
	_signaling.subscribe(LEADERBOARD_TOPIC)


func stop_listening() -> void:
	# MQTT 3.1.1 UNSUBSCRIBE not implemented in minimal client;
	# just stop processing. Subscription ends when broker disconnects.
	pass


func rebuild_leaderboard(http_node: Node) -> void:
	var cids_to_fetch: Array = []
	for pid in _known_chain_cids:
		var entry: Dictionary = _known_chain_cids[pid]
		var cid: String = entry.get("cid", "")
		if not cid.is_empty():
			cids_to_fetch.append({"pid": pid, "cid": cid, "username": entry.get("username", "")})

	if cids_to_fetch.is_empty():
		sync_complete.emit(true)
		return

	# Fetch chains sequentially, then compute ratings
	var all_proofs: Array = []
	_fetch_chains_sequential(cids_to_fetch, 0, all_proofs, http_node)


func _fetch_chains_sequential(
	cid_entries: Array, index: int, all_proofs: Array, http_node: Node
) -> void:
	if index >= cid_entries.size():
		# All fetched — compute ratings
		_compute_leaderboard_from_proofs(all_proofs)
		return

	var entry: Dictionary = cid_entries[index]
	var cid: String = entry["cid"]

	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
				var json: JSON = JSON.new()
				var err: Error = json.parse(body.get_string_from_utf8())
				if err == OK and json.data is Dictionary:
					var chain: Dictionary = json.data
					if MatchProof.verify_chain_integrity(chain):
						var proofs: Array = chain.get("proofs", [])
						var now: float = Time.get_unix_time_from_system()
						var max_age_sec: float = 90.0 * 24.0 * 3600.0  # 90 days
						var max_future_sec: float = 3600.0  # 1 hour
						for proof in proofs:
							# Verify proof structure (hash, fields, types)
							if not MatchProof.verify_proof_structure(proof):
								continue
							# Timestamp validation
							var md: Dictionary = proof.get("match_data", {})
							var ts_str: String = str(md.get("timestamp", ""))
							if not ts_str.is_empty():
								# Try to parse ISO timestamp to unix
								var ts_dict = Time.get_datetime_dict_from_datetime_string(ts_str, false)
								if not ts_dict.is_empty():
									var ts_unix: float = Time.get_unix_time_from_datetime_dict(ts_dict)
									if now - ts_unix > max_age_sec:
										continue  # Older than 90 days
									if ts_unix - now > max_future_sec:
										continue  # More than 1 hour in the future
							all_proofs.append(proof)

			# Continue to next CID regardless of success/failure
			_fetch_chains_sequential(cid_entries, index + 1, all_proofs, http_node)
	)

	var url: String = IPFS_GATEWAY + "/ipfs/" + cid
	http.request(url)


func _compute_leaderboard_from_proofs(all_proofs: Array) -> void:
	var ratings: Dictionary = RatingCalculator.calculate_ratings_from_chain(all_proofs)

	# Build leaderboard entries with display rating
	var entries: Array = []
	for pid in ratings:
		var r: Dictionary = ratings[pid]
		var base_rating: float = float(r.get("rating", 1000))
		# Use neutral skill score (0.5) — no replay analysis connected yet
		var display_rating: int = RatingCalculator.get_display_rating(base_rating, 0.5)

		var uname: String = ""
		if _known_chain_cids.has(pid):
			uname = _known_chain_cids[pid].get("username", "")

		entries.append({
			"profile_id": pid,
			"username": uname,
			"rating": display_rating,
			"matches": r.get("matches", 0),
			"wins": r.get("wins", 0),
			"losses": r.get("losses", 0),
		})

	# Sort descending by rating
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["rating"] > b["rating"]
	)

	# Take top N
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
	var err: Error = json.parse(text)
	if err != OK or not json.data is Array:
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


func get_local_skill_score() -> float:
	# Placeholder until replay analysis is connected
	return 0.5


func _on_leaderboard_message(topic: String, payload: String) -> void:
	if topic != LEADERBOARD_TOPIC:
		return

	var parsed = JSON.parse_string(payload)
	if parsed == null or not parsed is Dictionary:
		return

	# --- Strict field validation ---

	# profile_id: String, max 64 chars
	var pid = parsed.get("profile_id")
	if not pid is String or pid.is_empty() or pid.length() > 64:
		return

	# cid: String, non-empty (IPFS CID)
	var cid = parsed.get("cid")
	if not cid is String or cid.is_empty():
		return

	# username: String, max 32 chars
	var uname = parsed.get("username")
	if not uname is String or uname.length() > 32:
		return

	# timestamp: must be a number
	var ts = parsed.get("timestamp")
	if not (ts is int or ts is float):
		return

	# Cap known players to prevent memory exhaustion
	if not _known_chain_cids.has(pid) and _known_chain_cids.size() >= MAX_KNOWN_PLAYERS:
		return

	_known_chain_cids[pid] = {
		"cid": cid,
		"username": uname,
		"timestamp": ts,
	}


func _fetch_chain(cid: String, http_node: Node) -> void:
	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
				push_warning("LeaderboardManager: Failed to fetch chain CID=%s" % cid)
				return
			var json: JSON = JSON.new()
			var err: Error = json.parse(body.get_string_from_utf8())
			if err != OK or not json.data is Dictionary:
				push_warning("LeaderboardManager: Invalid chain data for CID=%s" % cid)
				return
	)

	var url: String = IPFS_GATEWAY + "/ipfs/" + cid
	http.request(url)
