class_name AnticheatValidator
extends RefCounted

## Anti-cheat validation for Final Fade ranked matches.
## Periodic state hash exchange, input plausibility checks, and replay signing.

const STATE_HASH_INTERVAL: int = 30
const MAX_DESYNC_COUNT: int = 3
const MAX_INPUT_RATE: int = 4
const INPUT_CHECK_WINDOW: int = 10

# Input bit flags (mirror InputManager constants)
const INPUT_FORWARD: int = 1
const INPUT_BACK: int = 2
const INPUT_UP: int = 4
const INPUT_DOWN: int = 8

var desync_count: int = 0
var _last_local_hash: PackedByteArray = PackedByteArray()
var _flagged: bool = false


func should_exchange_hash(frame: int) -> bool:
	return frame % STATE_HASH_INTERVAL == 0


func compute_state_hash(game_state: Dictionary, f1_state: Dictionary, f2_state: Dictionary) -> PackedByteArray:
	var combined: Dictionary = {
		"game": game_state,
		"f1": f1_state,
		"f2": f2_state,
	}
	var json_text: String = _sorted_json(combined)

	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(json_text.to_utf8_buffer())
	var hash_result: PackedByteArray = ctx.finish()

	_last_local_hash = hash_result
	return hash_result


func compare_hashes(local_hash: PackedByteArray, remote_hash: PackedByteArray) -> bool:
	if local_hash.size() != remote_hash.size():
		desync_count += 1
		return false

	# Constant-time byte comparison
	var diff: int = 0
	for i in range(local_hash.size()):
		diff = diff | (local_hash[i] ^ remote_hash[i])

	if diff != 0:
		desync_count += 1
		return false

	desync_count = 0
	return true


func is_desynced() -> bool:
	return desync_count >= MAX_DESYNC_COUNT


func validate_input_sequence(input_history: Dictionary, frame: int) -> bool:
	# Check for impossible simultaneous forward + back
	for f_key in input_history:
		var f: int = f_key if f_key is int else int(str(f_key))
		if f < frame - INPUT_CHECK_WINDOW or f > frame:
			continue
		var bits: int = input_history[f_key]
		if (bits & INPUT_FORWARD) and (bits & INPUT_BACK):
			flag_match("Simultaneous forward+back at frame %d" % f)
			return false
		if (bits & INPUT_UP) and (bits & INPUT_DOWN):
			flag_match("Simultaneous up+down at frame %d" % f)
			return false

	# Count direction changes in the check window
	var direction_changes: int = 0
	var prev_h: int = -1  # horizontal: 0=none, 1=forward, 2=back
	var prev_v: int = -1  # vertical: 0=none, 1=up, 2=down

	var frames_in_window: Array = []
	for f_key in input_history:
		var f: int = f_key if f_key is int else int(str(f_key))
		if f >= frame - INPUT_CHECK_WINDOW and f <= frame:
			frames_in_window.append(f_key)
	frames_in_window.sort()

	for f_key in frames_in_window:
		var bits: int = input_history[f_key]

		var cur_h: int = 0
		if bits & INPUT_FORWARD:
			cur_h = 1
		elif bits & INPUT_BACK:
			cur_h = 2

		var cur_v: int = 0
		if bits & INPUT_UP:
			cur_v = 1
		elif bits & INPUT_DOWN:
			cur_v = 2

		if prev_h >= 0:
			if cur_h != prev_h and cur_h != 0 and prev_h != 0:
				direction_changes += 1
			if cur_v != prev_v and cur_v != 0 and prev_v != 0:
				direction_changes += 1

		prev_h = cur_h
		prev_v = cur_v

	if direction_changes > MAX_INPUT_RATE:
		flag_match("Excessive direction changes (%d) in %d-frame window at frame %d" % [direction_changes, INPUT_CHECK_WINDOW, frame])
		return false

	return true


func sign_replay(replay_hash: String, signing_key: PackedByteArray) -> String:
	var mac: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, replay_hash.to_utf8_buffer())
	return Marshalls.raw_to_base64(mac)


func verify_replay_signature(replay_hash: String, sig_b64: String, signing_key: PackedByteArray) -> bool:
	var expected_mac: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, replay_hash.to_utf8_buffer())
	var received_mac: PackedByteArray = Marshalls.base64_to_raw(sig_b64)

	if expected_mac.size() != received_mac.size():
		return false

	# Constant-time compare
	var diff: int = 0
	for i in range(expected_mac.size()):
		diff = diff | (expected_mac[i] ^ received_mac[i])
	return diff == 0


func is_flagged() -> bool:
	return _flagged


func flag_match(reason: String) -> void:
	_flagged = true
	push_warning("AnticheatValidator: Match flagged — %s" % reason)


func reset() -> void:
	desync_count = 0
	_flagged = false
	_last_local_hash = PackedByteArray()


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
