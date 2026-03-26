class_name RankedConfig
extends RefCounted

## Ranked system configuration stored at user://ranked_config.json.
## Generates a w3name signing key on first load.

const CONFIG_PATH: String = "user://ranked_config.json"

var web3_api_token: String = ""
var region: String = "NA"
var auto_sync: bool = true
var w3name_key: String = ""  # Base64-encoded 32-byte key


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
		web3_api_token = data.get("web3_api_token", "")
		region = data.get("region", "NA")
		auto_sync = data.get("auto_sync", true)
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
		"web3_api_token": web3_api_token,
		"region": region,
		"auto_sync": auto_sync,
		"w3name_key": w3name_key,
	}
	var json_text: String = JSON.stringify(data, "\t")

	var file: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_error("RankedConfig: Failed to write config — %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string(json_text)
	file.close()


func has_api_token() -> bool:
	return not web3_api_token.is_empty()


func get_region() -> String:
	return region


func _generate_defaults() -> void:
	web3_api_token = ""
	region = "NA"
	auto_sync = true
	var crypto: Crypto = Crypto.new()
	w3name_key = Marshalls.raw_to_base64(crypto.generate_random_bytes(32))
