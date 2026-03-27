class_name ReplayManager
extends RefCounted

## Replay recording, storage, and IPFS sync for Final Fade ranked matches.
## Stores sparse input data per frame and supports skill analysis for rating.

const REPLAY_DIR: String = "user://replays/"
const MAX_LOCAL_REPLAYS: int = 50
const FIREBASE_DB_URL: String = "https://final-fade-default-rtdb.firebaseio.com/"
const IPFS_GATEWAY: String = "https://final-fade-default-rtdb.firebaseio.com/"  # Using Firebase instead of IPFS
const WEB3_STORAGE_URL: String = "https://final-fade-default-rtdb.firebaseio.com/"  # Using Firebase instead of web3.storage

# Input bit flags (mirror InputManager constants)
const INPUT_FORWARD: int = 1
const INPUT_BACK: int = 2
const INPUT_UP: int = 4
const INPUT_DOWN: int = 8

signal ipfs_upload_complete(cid: String)
signal ipfs_fetch_complete(data: Dictionary)

# Recording state
var _recording: bool = false
var _match_id: String = ""
var _timestamp: String = ""
var _p1_id: String = ""
var _p2_id: String = ""
var _p1_class: String = ""
var _p2_class: String = ""
var _stage: String = ""

var _rounds: Array = []
var _current_round_inputs_p1: Dictionary = {}  # frame -> input_bits (sparse)
var _current_round_inputs_p2: Dictionary = {}
var _current_round: int = 0
var _round_start_frame: int = 0


func start_recording(p1_id: String, p2_id: String, p1_class: String, p2_class: String, stage: String) -> void:
	_recording = true
	_p1_id = p1_id
	_p2_id = p2_id
	_p1_class = p1_class
	_p2_class = p2_class
	_stage = stage
	_rounds.clear()
	_current_round_inputs_p1.clear()
	_current_round_inputs_p2.clear()
	_current_round = 0
	_round_start_frame = 0

	# Generate UUID from 16 random bytes
	var crypto: Crypto = Crypto.new()
	var bytes: PackedByteArray = crypto.generate_random_bytes(16)
	_match_id = bytes.hex_encode()

	_timestamp = Time.get_datetime_string_from_system(true)


func record_input(frame: int, player_id: String, input_bits: int) -> void:
	if not _recording:
		return
	if input_bits == 0:
		return  # Sparse — only store non-zero inputs

	if player_id == _p1_id:
		_current_round_inputs_p1[frame] = input_bits
	elif player_id == _p2_id:
		_current_round_inputs_p2[frame] = input_bits


func end_round(round_num: int, winner_id: String, p1_health: int, p2_health: int, duration_frames: int) -> void:
	if not _recording:
		return

	var round_data: Dictionary = {
		"round": round_num,
		"winner_id": winner_id,
		"p1_health": p1_health,
		"p2_health": p2_health,
		"duration_frames": duration_frames,
		"inputs_p1": _current_round_inputs_p1.duplicate(),
		"inputs_p2": _current_round_inputs_p2.duplicate(),
	}
	_rounds.append(round_data)

	_current_round_inputs_p1.clear()
	_current_round_inputs_p2.clear()
	_current_round = round_num + 1
	_round_start_frame += duration_frames


func finalize_replay(winner_id: String, p1_round_wins: int, p2_round_wins: int) -> Dictionary:
	_recording = false

	var replay: Dictionary = {
		"match_id": _match_id,
		"timestamp": _timestamp,
		"p1_id": _p1_id,
		"p2_id": _p2_id,
		"p1_class": _p1_class,
		"p2_class": _p2_class,
		"stage": _stage,
		"winner_id": winner_id,
		"p1_round_wins": p1_round_wins,
		"p2_round_wins": p2_round_wins,
		"rounds": _rounds.duplicate(true),
	}

	replay["replay_hash"] = compute_replay_hash(replay)
	return replay


func save_locally(replay: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(REPLAY_DIR)

	var file_path: String = REPLAY_DIR + replay.get("match_id", "unknown") + ".json"
	var json_text: String = JSON.stringify(replay, "\t")

	var file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		push_warning("ReplayManager: Failed to save replay — %s" % error_string(FileAccess.get_open_error()))
		return ""
	file.store_string(json_text)
	file.close()

	# Prune old replays if over limit
	_prune_replays()

	return file_path


func _prune_replays() -> void:
	var dir: DirAccess = DirAccess.open(REPLAY_DIR)
	if dir == null:
		return

	var files: Array = []
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	if files.size() <= MAX_LOCAL_REPLAYS:
		return

	# Load timestamps for sorting
	var file_entries: Array = []
	for f in files:
		var path: String = REPLAY_DIR + f
		var fa: FileAccess = FileAccess.open(path, FileAccess.READ)
		if fa == null:
			continue
		var json: JSON = JSON.new()
		var err: Error = json.parse(fa.get_as_text())
		fa.close()
		if err == OK and json.data is Dictionary:
			file_entries.append({"file": f, "timestamp": json.data.get("timestamp", "")})
		else:
			file_entries.append({"file": f, "timestamp": ""})

	# Sort by timestamp ascending (oldest first)
	file_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["timestamp"] < b["timestamp"]
	)

	# Delete oldest until at limit
	var to_delete: int = file_entries.size() - MAX_LOCAL_REPLAYS
	for i in range(to_delete):
		DirAccess.remove_absolute(REPLAY_DIR + file_entries[i]["file"])


func upload_to_ipfs(replay: Dictionary, api_token: String, http_node: Node) -> void:
	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(_on_upload_complete.bind(http))

	var json_text: String = JSON.stringify(replay)
	var headers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer %s" % api_token,
		"Content-Type: application/json",
	])

	var err: Error = http.request(WEB3_STORAGE_URL + "/upload", headers, HTTPClient.METHOD_POST, json_text)
	if err != OK:
		push_warning("ReplayManager: IPFS upload request failed — %s" % error_string(err))
		http.queue_free()


func _on_upload_complete(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		push_warning("ReplayManager: IPFS upload failed — HTTP %d" % response_code)
		return

	var json: JSON = JSON.new()
	var err: Error = json.parse(body.get_string_from_utf8())
	if err != OK:
		push_warning("ReplayManager: Failed to parse IPFS upload response")
		return

	if json.data is Dictionary:
		var cid: String = json.data.get("cid", "")
		if not cid.is_empty():
			ipfs_upload_complete.emit(cid)


func fetch_from_ipfs(cid: String, http_node: Node) -> void:
	var http: HTTPRequest = HTTPRequest.new()
	http_node.add_child(http)
	http.request_completed.connect(_on_fetch_complete.bind(http))

	var url: String = "%s/ipfs/%s" % [IPFS_GATEWAY, cid]
	var err: Error = http.request(url, PackedStringArray(), HTTPClient.METHOD_GET)
	if err != OK:
		push_warning("ReplayManager: IPFS fetch request failed — %s" % error_string(err))
		http.queue_free()


func _on_fetch_complete(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		push_warning("ReplayManager: IPFS fetch failed — HTTP %d" % response_code)
		return

	var json: JSON = JSON.new()
	var err: Error = json.parse(body.get_string_from_utf8())
	if err != OK:
		push_warning("ReplayManager: Failed to parse IPFS fetch response")
		return

	if json.data is Dictionary:
		ipfs_fetch_complete.emit(json.data)


func compute_replay_hash(replay: Dictionary) -> String:
	# Hash replay data excluding signatures and replay_hash fields
	var data: Dictionary = replay.duplicate(true)
	data.erase("replay_hash")
	data.erase("signatures")

	var json_text: String = _sorted_json(data)
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(json_text.to_utf8_buffer())
	return ctx.finish().hex_encode()


func get_local_replays() -> Array:
	var dir: DirAccess = DirAccess.open(REPLAY_DIR)
	if dir == null:
		return []

	var replays: Array = []
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var path: String = REPLAY_DIR + fname
			var fa: FileAccess = FileAccess.open(path, FileAccess.READ)
			if fa != null:
				var json: JSON = JSON.new()
				var err: Error = json.parse(fa.get_as_text())
				fa.close()
				if err == OK and json.data is Dictionary:
					var d: Dictionary = json.data
					replays.append({
						"match_id": d.get("match_id", ""),
						"timestamp": d.get("timestamp", ""),
						"p1_id": d.get("p1_id", ""),
						"p2_id": d.get("p2_id", ""),
						"winner_id": d.get("winner_id", ""),
					})
		fname = dir.get_next()
	dir.list_dir_end()

	return replays


func analyze_for_skill(replay: Dictionary, player_id: String) -> Dictionary:
	var is_p1: bool = replay.get("p1_id", "") == player_id
	var player_key: String = "inputs_p1" if is_p1 else "inputs_p2"
	var opponent_key: String = "inputs_p2" if is_p1 else "inputs_p1"

	var all_unique_inputs: Dictionary = {}
	var all_movement_patterns: Dictionary = {}
	var reaction_frame_totals: Array = []

	var rounds: Array = replay.get("rounds", [])
	for round_data in rounds:
		if not round_data is Dictionary:
			continue

		var player_inputs: Dictionary = round_data.get(player_key, {})
		var opponent_inputs: Dictionary = round_data.get(opponent_key, {})

		# Collect unique input values
		for frame_key in player_inputs:
			var bits: int = player_inputs[frame_key]
			all_unique_inputs[bits] = true

			# Track movement patterns (lower 4 bits)
			var movement: int = bits & 0x0F
			if movement != 0:
				all_movement_patterns[movement] = true

		# Compute reaction frames: for each opponent attack (button bits),
		# find how many frames until player responds with block/movement
		var opp_frames: Array = opponent_inputs.keys()
		opp_frames.sort()
		for opp_frame in opp_frames:
			var opp_bits: int = opponent_inputs[opp_frame]
			# Check if opponent pressed a button (bits above movement nibble)
			if (opp_bits & 0xF0) == 0:
				continue

			# Find next player input after this frame
			var best_reaction: int = -1
			for p_frame_key in player_inputs:
				var p_frame: int = p_frame_key if p_frame_key is int else int(str(p_frame_key))
				var o_frame: int = opp_frame if opp_frame is int else int(str(opp_frame))
				if p_frame > o_frame:
					var delta: int = p_frame - o_frame
					if best_reaction < 0 or delta < best_reaction:
						best_reaction = delta
			if best_reaction > 0:
				reaction_frame_totals.append(best_reaction)

	# Input diversity: unique input values / 255 (8-bit input space)
	var input_diversity: float = float(all_unique_inputs.size()) / 255.0

	# Average reaction frames
	var avg_reaction_frames: float = 15.0
	if reaction_frame_totals.size() > 0:
		var total: float = 0.0
		for r in reaction_frame_totals:
			total += float(r)
		avg_reaction_frames = total / float(reaction_frame_totals.size())

	# Punishment rate: placeholder (needs move frame data for proper computation)
	var punishment_rate: float = 0.5

	# Movement variety: unique movement patterns / 8 (8 movement types)
	var movement_variety: float = float(all_movement_patterns.size()) / 8.0

	return {
		"input_diversity": input_diversity,
		"avg_reaction_frames": avg_reaction_frames,
		"punishment_rate": punishment_rate,
		"movement_variety": movement_variety,
	}


## Run replay analysis on a background thread (zero frame impact).
## Automatically fires after each match — no batch processing needed.
## Updates a running average skill score incrementally.
signal skill_analysis_complete(metrics: Dictionary, skill_score: float)

# Running average state — persists across matches in a session
var _skill_sample_count: int = 0
var _running_metrics: Dictionary = {
	"input_diversity": 0.0,
	"avg_reaction_frames": 15.0,
	"punishment_rate": 0.5,
	"movement_variety": 0.0,
}
var current_skill_score: float = 0.5  # Updated incrementally


func analyze_in_background(replay: Dictionary, player_id: String) -> void:
	# Use WorkerThreadPool to offload analysis — pure data, no Node access
	WorkerThreadPool.add_task(func():
		var metrics: Dictionary = analyze_for_skill(replay, player_id)
		var score: float = RatingCalculator.calculate_skill_score(metrics)
		# Update running average and emit on main thread
		_update_running_average.call_deferred(metrics, score)
	)


func _update_running_average(metrics: Dictionary, score: float) -> void:
	_skill_sample_count += 1
	var n: float = float(_skill_sample_count)

	# Incremental mean: new_avg = old_avg + (new_value - old_avg) / n
	for key in _running_metrics:
		if metrics.has(key):
			_running_metrics[key] += (metrics[key] - _running_metrics[key]) / n

	current_skill_score += (score - current_skill_score) / n

	skill_analysis_complete.emit(_running_metrics, current_skill_score)


func get_current_skill_score() -> float:
	return current_skill_score


func get_running_metrics() -> Dictionary:
	return _running_metrics.duplicate()


## Deterministic JSON with recursively sorted dictionary keys.
static func _sorted_json(data: Variant) -> String:
	if data is Dictionary:
		var keys: Array = data.keys()
		keys.sort()
		var parts: PackedStringArray = PackedStringArray()
		for key in keys:
			var key_json: String = JSON.stringify(str(key))
			var val_json: String = _sorted_json(data[key])
			parts.append("%s:%s" % [key_json, val_json])
		return "{%s}" % ",".join(parts)
	elif data is Array:
		var parts: PackedStringArray = PackedStringArray()
		for item in data:
			parts.append(_sorted_json(item))
		return "[%s]" % ",".join(parts)
	else:
		return JSON.stringify(data)
