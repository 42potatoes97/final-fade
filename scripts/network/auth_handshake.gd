class_name AuthHandshake
extends RefCounted

# Challenge-response authentication for Final Fade peer connections
# The nonce is hashed before transmission to prevent interception.
# Packet format: [1B msg_type][variable payload as JSON bytes]

enum HandshakeMsg {
	HELLO = 1,
	CHALLENGE = 2,
	RESPONSE = 3,
	AUTH_OK = 4,
	AUTH_FAIL = 5,
}

const PROTOCOL_VERSION: int = 1
const TIMEOUT_SEC: float = 5.0
const MAX_USERNAME_LEN: int = 32
const MAX_PROFILE_ID_LEN: int = 64


# --- Host Side ---

static func create_challenge(nonce: PackedByteArray) -> PackedByteArray:
	# Send a hashed version of the nonce (not the raw nonce)
	# The joiner must prove they can derive the same hash using the session key
	var nonce_hash: PackedByteArray = _hash_for_challenge(nonce)
	var payload: Dictionary = {
		"nonce_hash": Marshalls.raw_to_base64(nonce_hash),
		"protocol_version": PROTOCOL_VERSION,
	}
	return _pack_packet(HandshakeMsg.CHALLENGE, payload)


static func verify_response(received_hmac: PackedByteArray, session_key: PackedByteArray, nonce: PackedByteArray) -> bool:
	# Verify HMAC-SHA256(session_key, nonce) matches
	var expected_hmac: PackedByteArray = CryptoUtils.hmac_sha256(session_key, nonce)

	if received_hmac.size() != expected_hmac.size():
		return false

	# Constant-time comparison to prevent timing attacks
	var diff: int = 0
	for i in range(received_hmac.size()):
		diff = diff | (received_hmac[i] ^ expected_hmac[i])
	return diff == 0


static func create_auth_ok(host_profile: Dictionary) -> PackedByteArray:
	var payload: Dictionary = {
		"username": _sanitize_string(host_profile.get("username", ""), MAX_USERNAME_LEN),
		"profile_id": _sanitize_string(host_profile.get("profile_id", ""), MAX_PROFILE_ID_LEN),
	}
	return _pack_packet(HandshakeMsg.AUTH_OK, payload)


static func create_auth_fail(reason: String) -> PackedByteArray:
	var payload: Dictionary = {
		"reason": _sanitize_string(reason, 128),
	}
	return _pack_packet(HandshakeMsg.AUTH_FAIL, payload)


# --- Joiner Side ---

static func create_hello(profile: Dictionary, session_token: PackedByteArray) -> PackedByteArray:
	var payload: Dictionary = {
		"username": _sanitize_string(profile.get("username", ""), MAX_USERNAME_LEN),
		"profile_id": _sanitize_string(profile.get("profile_id", ""), MAX_PROFILE_ID_LEN),
		"session_token": Marshalls.raw_to_base64(session_token),
		"protocol_version": PROTOCOL_VERSION,
	}
	return _pack_packet(HandshakeMsg.HELLO, payload)


static func create_response(nonce_hash: PackedByteArray, session_key: PackedByteArray) -> PackedByteArray:
	# The joiner receives nonce_hash, but needs to prove knowledge of session_key
	# by computing HMAC(session_key, nonce_hash)
	# Both sides can compute this: host has raw nonce → hashes it → same nonce_hash
	var hmac: PackedByteArray = CryptoUtils.hmac_sha256(session_key, nonce_hash)
	var payload: Dictionary = {
		"hmac": Marshalls.raw_to_base64(hmac),
	}
	return _pack_packet(HandshakeMsg.RESPONSE, payload)


# --- Parsing ---

static func parse_packet(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {}

	var msg_type: int = data[0]
	if msg_type < HandshakeMsg.HELLO or msg_type > HandshakeMsg.AUTH_FAIL:
		return {}

	var json_bytes: PackedByteArray = data.slice(1)
	if json_bytes.size() > 4096:  # Reject oversized payloads
		return {}

	var json_string: String = json_bytes.get_string_from_utf8()
	var json: JSON = JSON.new()
	var err: Error = json.parse(json_string)
	if err != OK:
		return {}

	var parsed = json.data
	if not parsed is Dictionary:
		return {}

	# Return flattened result with type validation
	var result: Dictionary = {"type": msg_type}
	for key in parsed:
		if key is String and key.length() <= 64:
			result[key] = parsed[key]
	return result


# --- Internal ---

static func _pack_packet(msg_type: int, payload: Dictionary) -> PackedByteArray:
	var json_string: String = JSON.stringify(payload)
	var json_bytes: PackedByteArray = json_string.to_utf8_buffer()

	var packet: PackedByteArray = PackedByteArray()
	packet.resize(1)
	packet[0] = msg_type
	packet.append_array(json_bytes)
	return packet


static func _hash_for_challenge(nonce: PackedByteArray) -> PackedByteArray:
	# Hash the nonce before sending — prevents interception of raw nonce
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(nonce)
	ctx.update("finalfade-challenge".to_utf8_buffer())
	return ctx.finish()


static func _sanitize_string(s, max_len: int) -> String:
	if not s is String:
		return ""
	if s.length() > max_len:
		return s.substr(0, max_len)
	return s
