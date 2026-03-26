class_name AuthHandshake
extends RefCounted

# Challenge-response authentication for Final Fade peer connections
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


# --- Host Side ---

func create_challenge() -> PackedByteArray:
	var nonce: PackedByteArray = CryptoUtils.generate_nonce()
	var payload: Dictionary = {
		"nonce": Marshalls.raw_to_base64(nonce),
		"protocol_version": PROTOCOL_VERSION,
	}
	return _pack_packet(HandshakeMsg.CHALLENGE, payload)


func verify_response(response_data: PackedByteArray, session_key: PackedByteArray, expected_nonce: PackedByteArray) -> bool:
	var parsed: Dictionary = parse_packet(response_data)
	if parsed.is_empty() or parsed["type"] != HandshakeMsg.RESPONSE:
		return false

	var received_hmac: PackedByteArray = Marshalls.base64_to_raw(parsed["payload"].get("hmac", ""))
	var expected_hmac: PackedByteArray = CryptoUtils.hmac_sha256(session_key, expected_nonce)

	if received_hmac.size() != expected_hmac.size():
		return false

	# Constant-time comparison
	var diff: int = 0
	for i in range(received_hmac.size()):
		diff |= received_hmac[i] ^ expected_hmac[i]
	return diff == 0


func create_auth_ok(host_profile: Dictionary) -> PackedByteArray:
	var payload: Dictionary = {
		"username": host_profile.get("username", ""),
		"profile_id": host_profile.get("profile_id", ""),
	}
	return _pack_packet(HandshakeMsg.AUTH_OK, payload)


func create_auth_fail(reason: String) -> PackedByteArray:
	var payload: Dictionary = {
		"reason": reason,
	}
	return _pack_packet(HandshakeMsg.AUTH_FAIL, payload)


# --- Joiner Side ---

func create_hello(profile: Dictionary, session_token: PackedByteArray) -> PackedByteArray:
	var payload: Dictionary = {
		"username": profile.get("username", ""),
		"profile_id": profile.get("profile_id", ""),
		"session_token": Marshalls.raw_to_base64(session_token),
		"protocol_version": PROTOCOL_VERSION,
	}
	return _pack_packet(HandshakeMsg.HELLO, payload)


func create_response(nonce: PackedByteArray, session_key: PackedByteArray) -> PackedByteArray:
	var hmac: PackedByteArray = CryptoUtils.hmac_sha256(session_key, nonce)
	var payload: Dictionary = {
		"hmac": Marshalls.raw_to_base64(hmac),
	}
	return _pack_packet(HandshakeMsg.RESPONSE, payload)


# --- Parsing ---

func parse_packet(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {}

	var msg_type: int = data[0]
	if msg_type < HandshakeMsg.HELLO or msg_type > HandshakeMsg.AUTH_FAIL:
		return {}

	var json_bytes: PackedByteArray = data.slice(1)
	var json_string: String = json_bytes.get_string_from_utf8()

	var json: JSON = JSON.new()
	var err: Error = json.parse(json_string)
	if err != OK:
		return {}

	return {"type": msg_type, "payload": json.data}


# --- Internal ---

func _pack_packet(msg_type: HandshakeMsg, payload: Dictionary) -> PackedByteArray:
	var json_string: String = JSON.stringify(payload)
	var json_bytes: PackedByteArray = json_string.to_utf8_buffer()

	var packet: PackedByteArray = PackedByteArray()
	packet.resize(1)
	packet[0] = msg_type
	packet.append_array(json_bytes)
	return packet
