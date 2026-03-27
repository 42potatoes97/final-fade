extends RefCounted

# Tests for networking — signaling client, transport setup, room codes, connection flow


func test_signaling_client_creation() -> String:
	var sig = SignalingClient.new()
	if sig == null:
		return "Failed to create SignalingClient"
	if sig.is_connected_to_broker():
		return "Should not be connected immediately after creation"
	return ""


func test_signaling_client_broker_url() -> String:
	# Verify the broker URL is a valid WSS endpoint
	var url: String = SignalingClient.BROKER_URL
	if not url.begins_with("wss://"):
		return "Broker URL should start with wss://, got: %s" % url
	if "hivemq" not in url and "mqtt" not in url.to_lower():
		return "Broker URL doesn't look like an MQTT broker: %s" % url
	return ""


func test_signaling_packet_builders() -> String:
	var sig = SignalingClient.new()

	# Test CONNECT packet
	var connect_pkt: PackedByteArray = sig._build_connect_packet()
	if connect_pkt.size() < 10:
		return "CONNECT packet too small: %d bytes" % connect_pkt.size()
	if connect_pkt[0] != 0x10:
		return "CONNECT packet type should be 0x10, got 0x%02X" % connect_pkt[0]

	# Test PINGREQ packet
	var ping_pkt: PackedByteArray = sig._build_pingreq_packet()
	if ping_pkt.size() != 2:
		return "PINGREQ should be 2 bytes, got %d" % ping_pkt.size()
	if ping_pkt[0] != 0xC0 or ping_pkt[1] != 0x00:
		return "PINGREQ should be [0xC0, 0x00]"

	# Test DISCONNECT packet
	var disc_pkt: PackedByteArray = sig._build_disconnect_packet()
	if disc_pkt.size() != 2:
		return "DISCONNECT should be 2 bytes"
	if disc_pkt[0] != 0xE0:
		return "DISCONNECT type should be 0xE0"

	return ""


func test_signaling_subscribe_packet() -> String:
	var sig = SignalingClient.new()
	var sub_pkt: PackedByteArray = sig._build_subscribe_packet("finalfade/test/topic", 1)

	if sub_pkt.size() < 5:
		return "SUBSCRIBE packet too small: %d bytes" % sub_pkt.size()
	# SUBSCRIBE fixed header: type 8, flags 0x02 = 0x82
	if sub_pkt[0] != 0x82:
		return "SUBSCRIBE packet type should be 0x82, got 0x%02X" % sub_pkt[0]

	return ""


func test_signaling_publish_packet() -> String:
	var sig = SignalingClient.new()
	var pub_pkt: PackedByteArray = sig._build_publish_packet("finalfade/test", "hello world", false)

	if pub_pkt.size() < 5:
		return "PUBLISH packet too small"
	# PUBLISH = type 3, QoS 0, no retain = 0x30
	if pub_pkt[0] != 0x30:
		return "PUBLISH no-retain should be 0x30, got 0x%02X" % pub_pkt[0]

	# With retain
	var pub_retain: PackedByteArray = sig._build_publish_packet("finalfade/test", "hello", true)
	if pub_retain[0] != 0x31:
		return "PUBLISH with retain should be 0x31, got 0x%02X" % pub_retain[0]

	return ""


func test_signaling_remaining_length_encoding() -> String:
	var sig = SignalingClient.new()

	# Small value (< 128) = 1 byte
	var small: PackedByteArray = sig._encode_remaining_length(50)
	if small.size() != 1:
		return "Length 50 should encode to 1 byte, got %d" % small.size()
	if small[0] != 50:
		return "Length 50 should encode as 50, got %d" % small[0]

	# Medium value (128-16383) = 2 bytes
	var medium: PackedByteArray = sig._encode_remaining_length(200)
	if medium.size() != 2:
		return "Length 200 should encode to 2 bytes, got %d" % medium.size()
	# Decode: (200 % 128) | 0x80 = 72 | 128 = 200, then 200/128 = 1
	var decoded: int = (medium[0] & 0x7F) + (medium[1] & 0x7F) * 128
	if decoded != 200:
		return "Length 200 decoded as %d" % decoded

	return ""


func test_signaling_utf8_encoding() -> String:
	var sig = SignalingClient.new()
	var encoded: PackedByteArray = sig._encode_utf8_string("hello")

	# Should be: 2-byte length prefix (0, 5) + "hello" (5 bytes) = 7 bytes
	if encoded.size() != 7:
		return "Encoded 'hello' should be 7 bytes, got %d" % encoded.size()
	if encoded[0] != 0 or encoded[1] != 5:
		return "Length prefix should be [0, 5], got [%d, %d]" % [encoded[0], encoded[1]]

	var decoded: String = encoded.slice(2).get_string_from_utf8()
	if decoded != "hello":
		return "Decoded string mismatch: '%s'" % decoded

	return ""


func test_webrtc_transport_creation() -> String:
	var WebRTCScript = load("res://scripts/network/transport_webrtc.gd")
	var transport = WebRTCScript.new()

	if transport == null:
		return "Failed to create TransportWebRTC"
	if transport.room_id != "":
		return "Initial room_id should be empty"
	if transport.is_host:
		return "Initial is_host should be false"

	return ""


func test_webrtc_stun_config() -> String:
	var WebRTCScript = load("res://scripts/network/transport_webrtc.gd")
	var transport = WebRTCScript.new()

	var config: Dictionary = transport.STUN_CONFIG
	if not config.has("iceServers"):
		return "STUN config missing 'iceServers'"

	var servers: Array = config["iceServers"]
	if servers.size() == 0:
		return "No STUN servers configured"

	var urls: Array = servers[0].get("urls", [])
	if urls.size() == 0:
		return "No STUN URLs in first server entry"

	# Verify at least one Google STUN server
	var has_google_stun: bool = false
	for url in urls:
		if "stun.l.google.com" in url or "stun1.l.google.com" in url:
			has_google_stun = true
			break
	if not has_google_stun:
		return "Expected Google STUN servers in config"

	return ""


func test_webrtc_room_id_generation() -> String:
	var WebRTCScript = load("res://scripts/network/transport_webrtc.gd")
	var transport = WebRTCScript.new()

	var id1: String = transport._generate_room_id()
	var id2: String = transport._generate_room_id()

	if id1.length() != transport.ROOM_ID_LENGTH:
		return "Room ID should be %d chars, got %d" % [transport.ROOM_ID_LENGTH, id1.length()]
	if id1 == id2:
		return "Two generated room IDs should be different"

	# Verify only valid characters
	for c in id1:
		if c not in transport.ROOM_ID_CHARS:
			return "Invalid character '%s' in room ID" % c

	return ""


func test_enet_transport_creation() -> String:
	var ENetScript = load("res://scripts/network/transport_enet.gd")
	var transport = ENetScript.new()

	if transport == null:
		return "Failed to create TransportENet"

	return ""


func test_network_manager_state_initial() -> String:
	# NetworkManager autoload should be in disconnected state
	if NetworkManager.connection_state != NetworkManager.ConnectionState.DISCONNECTED:
		return "Initial state should be DISCONNECTED, got %d" % NetworkManager.connection_state
	return ""


func test_network_manager_transport_default() -> String:
	# Default transport should be set
	if NetworkManager.active_transport == "":
		return "active_transport should not be empty"
	if NetworkManager.active_transport not in ["enet", "webrtc"]:
		return "active_transport should be 'enet' or 'webrtc', got '%s'" % NetworkManager.active_transport
	return ""


func test_network_manager_connect_timeout_exists() -> String:
	if NetworkManager.CONNECT_TIMEOUT_SEC <= 0:
		return "CONNECT_TIMEOUT_SEC should be positive, got %.1f" % NetworkManager.CONNECT_TIMEOUT_SEC
	if NetworkManager.CONNECT_TIMEOUT_SEC > 60:
		return "CONNECT_TIMEOUT_SEC seems too high: %.1f" % NetworkManager.CONNECT_TIMEOUT_SEC
	return ""


func test_connection_quality_creation() -> String:
	var quality = ConnectionQuality.new()
	if quality == null:
		return "Failed to create ConnectionQuality"

	# Should have reasonable recommended delay
	var delay: int = quality.get_recommended_delay()
	if delay < 0:
		return "Recommended delay should not be negative"

	return ""


func test_auth_handshake_packet_types() -> String:
	# Verify handshake message types exist
	if AuthHandshake.HandshakeMsg.HELLO != 1:
		return "HELLO should be 1"
	if AuthHandshake.HandshakeMsg.CHALLENGE != 2:
		return "CHALLENGE should be 2"
	if AuthHandshake.HandshakeMsg.RESPONSE != 3:
		return "RESPONSE should be 3"
	if AuthHandshake.HandshakeMsg.AUTH_OK != 4:
		return "AUTH_OK should be 4"
	if AuthHandshake.HandshakeMsg.AUTH_FAIL != 5:
		return "AUTH_FAIL should be 5"
	return ""


func test_lobby_discovery_creation() -> String:
	var lobby = LobbyDiscovery.new()
	if lobby == null:
		return "Failed to create LobbyDiscovery"

	# rooms is a Dictionary var, not a method
	if lobby.rooms.size() != 0:
		return "Initial rooms should be empty"
	return ""
