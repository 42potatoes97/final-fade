extends Node

# Local user profile manager for Final Fade
# Stores identity, signing key, and match stats at user://profile.json

var profile_id: String = ""
var username: String = ""
var signing_key: PackedByteArray = PackedByteArray()
var stats: Dictionary = {"wins": 0, "losses": 0, "total_matches": 0}
var created_at: String = ""

const PROFILE_PATH: String = "user://profile.json"


func _ready() -> void:
	load_profile()


func load_profile() -> void:
	if not FileAccess.file_exists(PROFILE_PATH):
		generate_new_profile()
		return

	var file: FileAccess = FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if file == null:
		generate_new_profile()
		return

	var text: String = file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	var err: Error = json.parse(text)
	if err != OK:
		generate_new_profile()
		return

	var data: Dictionary = json.data
	if not _validate_profile_data(data):
		push_warning("ProfileManager: Invalid profile data on disk, regenerating")
		generate_new_profile()
		return

	profile_id = data["profile_id"]
	username = data["username"]
	signing_key = Marshalls.base64_to_raw(data["signing_key"])
	stats = {
		"wins": int(data["stats"]["wins"]),
		"losses": int(data["stats"]["losses"]),
		"total_matches": int(data["stats"]["total_matches"]),
	}
	created_at = data["created_at"]


func save_profile() -> void:
	var data: Dictionary = {
		"profile_id": profile_id,
		"username": username,
		"signing_key": Marshalls.raw_to_base64(signing_key),
		"stats": stats,
		"created_at": created_at,
	}

	var json_string: String = JSON.stringify(data, "\t")
	var file: FileAccess = FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("ProfileManager: Failed to save profile")
		return
	file.store_string(json_string)
	file.close()


func generate_new_profile() -> void:
	profile_id = _generate_uuid_v4()
	username = "Fighter"
	var crypto: Crypto = Crypto.new()
	signing_key = crypto.generate_random_bytes(32)
	stats = {"wins": 0, "losses": 0, "total_matches": 0}
	created_at = Time.get_datetime_string_from_system(true)
	save_profile()


func export_profile() -> String:
	var data: Dictionary = {
		"profile_id": profile_id,
		"username": username,
		"signing_key": Marshalls.raw_to_base64(signing_key),
		"stats": stats,
		"created_at": created_at,
	}
	var json_string: String = JSON.stringify(data)
	return Marshalls.raw_to_base64(json_string.to_utf8_buffer())


func import_profile(data: String) -> bool:
	var decoded_bytes: PackedByteArray = Marshalls.base64_to_raw(data)
	if decoded_bytes.is_empty():
		return false

	var json_string: String = decoded_bytes.get_string_from_utf8()
	var json: JSON = JSON.new()
	var err: Error = json.parse(json_string)
	if err != OK:
		return false

	var parsed: Dictionary = json.data
	if not _validate_profile_data(parsed):
		return false

	profile_id = parsed["profile_id"]
	username = parsed["username"]
	signing_key = Marshalls.base64_to_raw(parsed["signing_key"])
	stats = {
		"wins": int(parsed["stats"]["wins"]),
		"losses": int(parsed["stats"]["losses"]),
		"total_matches": int(parsed["stats"]["total_matches"]),
	}
	created_at = parsed["created_at"]
	save_profile()
	return true


func get_display_identity() -> Dictionary:
	return {"username": username, "profile_id": profile_id}


func record_win() -> void:
	stats["wins"] = stats.get("wins", 0) + 1
	stats["total_matches"] = stats.get("total_matches", 0) + 1
	save_profile()


func record_loss() -> void:
	stats["losses"] = stats.get("losses", 0) + 1
	stats["total_matches"] = stats.get("total_matches", 0) + 1
	save_profile()


func _validate_profile_data(data: Dictionary) -> bool:
	# profile_id: String, max 64 chars, UUID format (contains dashes)
	if not data.has("profile_id") or not data["profile_id"] is String:
		return false
	var pid: String = data["profile_id"]
	if pid.is_empty() or pid.length() > 64 or pid.find("-") == -1:
		return false

	# username: String, max 32 chars, non-empty
	if not data.has("username") or not data["username"] is String:
		return false
	var uname: String = data["username"]
	if uname.is_empty() or uname.length() > 32:
		return false

	# signing_key: String (base64), decoded must be exactly 32 bytes
	if not data.has("signing_key") or not data["signing_key"] is String:
		return false
	var sk_str: String = data["signing_key"]
	if sk_str.is_empty():
		return false
	var sk_bytes: PackedByteArray = Marshalls.base64_to_raw(sk_str)
	if sk_bytes.size() != 32:
		return false

	# stats: Dictionary with int values for wins/losses/total_matches
	if not data.has("stats") or not data["stats"] is Dictionary:
		return false
	var s: Dictionary = data["stats"]
	for key in ["wins", "losses", "total_matches"]:
		if not s.has(key):
			return false
		if not (s[key] is int or s[key] is float):
			return false

	# created_at: String
	if not data.has("created_at") or not data["created_at"] is String:
		return false

	return true


func _generate_uuid_v4() -> String:
	var crypto: Crypto = Crypto.new()
	var bytes: PackedByteArray = crypto.generate_random_bytes(16)

	# Set version to 4 (bits 12-15 of time_hi_and_version)
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	# Set variant to RFC 4122 (bits 6-7 of clock_seq_hi_and_reserved)
	bytes[8] = (bytes[8] & 0x3F) | 0x80

	var hex: String = bytes.hex_encode()
	# Format: 8-4-4-4-12
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]
