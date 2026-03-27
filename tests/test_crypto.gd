extends RefCounted

# Tests for CryptoUtils — room code encoding/decoding, HMAC, encryption


func test_room_code_roundtrip() -> String:
	# Generate a room code from a known IP:port, decode it, verify it matches
	var ip := "192.168.1.100"
	var port := 7000
	var result := CryptoUtils.generate_room_code(ip, port)

	if not result.has("code"):
		return "generate_room_code returned no 'code' key"
	if not result.has("session_key"):
		return "generate_room_code returned no 'session_key' key"

	var code: String = result["code"]
	if code.length() < 10:
		return "Room code too short: '%s'" % code

	# Decode
	var decoded := CryptoUtils.decode_room_code(code)
	if not decoded.get("valid", false):
		return "decode_room_code returned invalid for valid code"
	if decoded.get("ip", "") != ip:
		return "IP mismatch: expected '%s', got '%s'" % [ip, decoded.get("ip", "")]
	if decoded.get("port", 0) != port:
		return "Port mismatch: expected %d, got %d" % [port, decoded.get("port", 0)]

	return ""


func test_room_code_invalid_input() -> String:
	# Garbage code should return invalid
	var decoded := CryptoUtils.decode_room_code("INVALIDGARBAGECODE123")
	if decoded.get("valid", false):
		return "Expected invalid result for garbage code"
	return ""


func test_room_code_empty() -> String:
	var decoded := CryptoUtils.decode_room_code("")
	if decoded.get("valid", false):
		return "Expected invalid result for empty code"
	return ""


func test_hmac_sha256_consistency() -> String:
	var key := "test_key".to_utf8_buffer()
	var data := "hello world".to_utf8_buffer()

	var hmac1 := CryptoUtils.hmac_sha256(key, data)
	var hmac2 := CryptoUtils.hmac_sha256(key, data)

	if hmac1 != hmac2:
		return "HMAC-SHA256 not deterministic"
	if hmac1.size() != 32:
		return "HMAC-SHA256 output should be 32 bytes, got %d" % hmac1.size()

	return ""


func test_hmac_sha256_different_keys() -> String:
	var data := "same data".to_utf8_buffer()
	var hmac1 := CryptoUtils.hmac_sha256("key1".to_utf8_buffer(), data)
	var hmac2 := CryptoUtils.hmac_sha256("key2".to_utf8_buffer(), data)

	if hmac1 == hmac2:
		return "Different keys produced same HMAC"

	return ""


func test_room_code_different_ports() -> String:
	# Same IP, different ports should produce different codes
	var r1 := CryptoUtils.generate_room_code("10.0.0.1", 7000)
	var r2 := CryptoUtils.generate_room_code("10.0.0.1", 7001)

	if r1["code"] == r2["code"]:
		return "Different ports produced same room code"
	return ""


func test_session_key_generation() -> String:
	var r1 := CryptoUtils.generate_room_code("1.2.3.4", 7000)
	var r2 := CryptoUtils.generate_room_code("1.2.3.4", 7000)

	# Session keys should be different (random)
	if r1["session_key"] == r2["session_key"]:
		return "Two generate calls produced same session key (should be random)"
	if r1["session_key"].size() != 32:
		return "Session key should be 32 bytes, got %d" % r1["session_key"].size()
	return ""
