class_name RankedConfig
extends RefCounted

## Ranked system configuration stored at user://ranked_config.json.
## Auto-sync is always on. Shared app token for IPFS uploads (no user setup).

const CONFIG_PATH: String = "user://ranked_config.json"

# Firebase Realtime Database URL (free Spark plan: 1GB storage, 10GB/month)
# Create project at https://console.firebase.google.com
# Enable Realtime Database, set rules to allow read/write
const FIREBASE_DB_URL: String = "https://final-fade-default-rtdb.firebaseio.com/"

var region: String = "NA"
var w3name_key: String = ""  # Base64-encoded 32-byte key for IPNS


func load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		_generate_defaults()
		save_config()
		return

	var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		push_warning("RankedConfig: Failed to open config — %s" % error_string(FileAccess.get_open_error()))
		_generate_defaults()
		save_config()
		return

	var json_text: String = file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	var err: Error = json.parse(json_text)
	if err != OK:
		push_warning("RankedConfig: Parse error — %s" % json.get_error_message())
		_generate_defaults()
		save_config()
		return

	var data: Variant = json.data
	if data is Dictionary:
		region = data.get("region", "NA")
		w3name_key = data.get("w3name_key", "")
	else:
		_generate_defaults()
		save_config()
		return

	# Safety: if key is missing, regenerate
	if w3name_key.is_empty():
		var crypto: Crypto = Crypto.new()
		w3name_key = Marshalls.raw_to_base64(crypto.generate_random_bytes(32))
		save_config()


func save_config() -> void:
	var data: Dictionary = {
		"region": region,
		"w3name_key": w3name_key,
	}
	var json_text: String = JSON.stringify(data, "\t")

	var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_error("RankedConfig: Failed to write config — %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(json_text)
	file.close()


func get_db_url() -> String:
	return FIREBASE_DB_URL


func get_region() -> String:
	return region


func _generate_defaults() -> void:
	region = "NA"
	var crypto: Crypto = Crypto.new()
	w3name_key = Marshalls.raw_to_base64(crypto.generate_random_bytes(32))
