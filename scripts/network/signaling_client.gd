class_name SignalingClient
extends Node

# Minimal MQTT 3.1.1 client over WebSocket for WebRTC signaling
# Implements just enough of the MQTT binary protocol for pub/sub over HiveMQ

signal connected
signal disconnected
signal message_received(topic: String, payload: String)

# EMQX public broker — fastest free MQTT broker, WSS on port 8084
const BROKER_URL: String = "wss://broker.emqx.io:8084/mqtt"
const KEEPALIVE_SEC: float = 30.0

var _ws: WebSocketPeer
var _connected: bool = false
var _connecting: bool = false     # True while WebSocket handshake + MQTT CONNECT is in flight
var _connect_sent: bool = false  # Prevent re-sending MQTT CONNECT every frame
var _subscriptions: Dictionary = {}
var _keepalive_timer: float = 0.0
var _packet_id_counter: int = 1
var _auto_reconnect: bool = true   # Reconnect automatically when dropped
var _reconnect_timer: float = 0.0
const RECONNECT_DELAY: float = 1.0  # Seconds before reconnect attempt


func connect_to_broker() -> void:
	if _connected or _connecting:
		return  # Already connected or in-flight — don't orphan the first attempt
	_auto_reconnect = true  # Re-enable auto-reconnect on any explicit connect call
	_reconnect_timer = 0.0
	_connecting = true
	_connect_sent = false
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray(["mqtt"])
	var err: int
	if BROKER_URL.begins_with("wss://"):
		err = _ws.connect_to_url(BROKER_URL, TLSOptions.client_unsafe())
	else:
		err = _ws.connect_to_url(BROKER_URL)
	if err != OK:
		push_error("SignalingClient: WebSocket connect failed (error %d)" % err)
	else:
		print("[SignalingClient] Connecting to %s..." % BROKER_URL)


func is_connected_to_broker() -> bool:
	return _connected


func disconnect_from_broker() -> void:
	_auto_reconnect = false  # Intentional disconnect — don't auto-reconnect
	_reconnect_timer = 0.0
	if _ws == null:
		return
	if _connected:
		_ws.put_packet(_build_disconnect_packet())
		_connected = false
		disconnected.emit()
	_connecting = false
	_ws.close()


func subscribe(topic: String) -> void:
	_subscriptions[topic] = true  # Always store — replayed on reconnect
	if not _connected:
		push_warning("SignalingClient: Cannot subscribe yet, not connected — will retry on reconnect")
		return
	var pkt := _build_subscribe_packet(topic, _next_packet_id())
	_ws.put_packet(pkt)


func publish(topic: String, payload: String, retain: bool = false) -> void:
	if not _connected:
		push_warning("SignalingClient: Cannot publish, not connected")
		return
	var pkt := _build_publish_packet(topic, payload, retain)
	_ws.put_packet(pkt)


func _process(delta: float) -> void:
	# Auto-reconnect after a drop
	if _ws == null:
		if _auto_reconnect and _reconnect_timer > 0.0:
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				print("[SignalingClient] Auto-reconnecting...")
				connect_to_broker()
		return

	_ws.poll()

	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _connected and not _connect_sent:
			# WebSocket just opened, send MQTT CONNECT (once)
			_connect_sent = true
			_ws.put_packet(_build_connect_packet())
			print("[SignalingClient] WebSocket open, MQTT CONNECT sent")

		# Read all available packets
		while _ws.get_available_packet_count() > 0:
			var data := _ws.get_packet()
			_parse_incoming(data)

		# Keepalive
		if _connected:
			_keepalive_timer += delta
			if _keepalive_timer >= KEEPALIVE_SEC:
				_keepalive_timer = 0.0
				_ws.put_packet(_build_pingreq_packet())

	elif state == WebSocketPeer.STATE_CLOSED:
		var close_code := _ws.get_close_code()
		var close_reason := _ws.get_close_reason()
		print("[SignalingClient] WebSocket closed (code=%d, reason='%s')" % [close_code, close_reason])
		if _connected:
			_connected = false
			disconnected.emit()
		_connecting = false
		_connect_sent = false
		_ws = null
		if _auto_reconnect:
			_reconnect_timer = RECONNECT_DELAY  # Start countdown

	elif state == WebSocketPeer.STATE_CONNECTING:
		pass  # Still connecting, wait


# --- MQTT Packet Builders ---

func _build_connect_packet() -> PackedByteArray:
	var client_id := "ff_" + _random_string(8)

	# Variable header
	var var_header := PackedByteArray()
	# Protocol name "MQTT"
	var_header.append_array(_encode_utf8_string("MQTT"))
	# Protocol level 4 (MQTT 3.1.1)
	var_header.append(4)
	# Connect flags: clean session (bit 1)
	var_header.append(0x02)
	# Keepalive (60 seconds)
	var_header.append(0)
	var_header.append(60)

	# Payload: client ID
	var payload := _encode_utf8_string(client_id)

	# Fixed header
	var remaining := var_header.size() + payload.size()
	var packet := PackedByteArray()
	# CONNECT = type 1, no flags -> 0x10
	packet.append(0x10)
	packet.append_array(_encode_remaining_length(remaining))
	packet.append_array(var_header)
	packet.append_array(payload)

	return packet


func _build_subscribe_packet(topic: String, packet_id: int) -> PackedByteArray:
	# Variable header: packet identifier
	var var_header := PackedByteArray()
	var_header.append((packet_id >> 8) & 0xFF)
	var_header.append(packet_id & 0xFF)

	# Payload: topic filter + QoS 0
	var payload := PackedByteArray()
	payload.append_array(_encode_utf8_string(topic))
	payload.append(0)  # QoS 0

	# Fixed header
	var remaining := var_header.size() + payload.size()
	var packet := PackedByteArray()
	# SUBSCRIBE = type 8, flags 0x02 -> 0x82
	packet.append(0x82)
	packet.append_array(_encode_remaining_length(remaining))
	packet.append_array(var_header)
	packet.append_array(payload)

	return packet


func _build_publish_packet(topic: String, payload: String, retain: bool) -> PackedByteArray:
	# Variable header: topic name (no packet ID for QoS 0)
	var var_header := _encode_utf8_string(topic)

	# Payload
	var payload_bytes := payload.to_utf8_buffer()

	# Fixed header
	var remaining := var_header.size() + payload_bytes.size()
	var packet := PackedByteArray()
	# PUBLISH = type 3, QoS 0, retain flag in bit 0 -> 0x30 or 0x31
	var flags: int = 0x30
	if retain:
		flags = 0x31
	packet.append(flags)
	packet.append_array(_encode_remaining_length(remaining))
	packet.append_array(var_header)
	packet.append_array(payload_bytes)

	return packet


func _build_pingreq_packet() -> PackedByteArray:
	return PackedByteArray([0xC0, 0x00])


func _build_disconnect_packet() -> PackedByteArray:
	return PackedByteArray([0xE0, 0x00])


# --- MQTT Packet Parser ---

func _parse_incoming(data: PackedByteArray) -> void:
	if data.size() < 2:
		return

	var offset: int = 0

	while offset < data.size():
		if offset + 1 >= data.size():
			break

		var packet_type: int = (data[offset] >> 4) & 0x0F
		var _flags: int = data[offset] & 0x0F
		offset += 1

		# Decode remaining length
		var remaining_length: int = 0
		var multiplier: int = 1
		var length_bytes: int = 0
		while offset < data.size():
			var encoded_byte: int = data[offset]
			offset += 1
			length_bytes += 1
			remaining_length += (encoded_byte & 0x7F) * multiplier
			multiplier *= 128
			if (encoded_byte & 0x80) == 0:
				break
			if length_bytes >= 4:
				break

		var packet_end: int = offset + remaining_length
		if packet_end > data.size():
			break

		match packet_type:
			2:  # CONNACK
				_connected = true
				_connecting = false
				_keepalive_timer = 0.0
				print("[SignalingClient] CONNACK received — connected to broker!")
				# Re-subscribe to all stored topics (handles reconnect after drop)
				for topic in _subscriptions:
					_ws.put_packet(_build_subscribe_packet(topic, _next_packet_id()))
				connected.emit()

			3:  # PUBLISH
				if offset + 2 <= packet_end:
					var topic_len: int = (data[offset] << 8) | data[offset + 1]
					offset += 2
					if offset + topic_len <= packet_end:
						var topic := data.slice(offset, offset + topic_len).get_string_from_utf8()
						offset += topic_len
						var payload_len: int = packet_end - offset
						var payload := ""
						if payload_len > 0:
							payload = data.slice(offset, packet_end).get_string_from_utf8()
						message_received.emit(topic, payload)

			9:  # SUBACK
				pass  # Subscription acknowledged, no action needed

			13:  # PINGRESP
				pass  # Keepalive acknowledged

		offset = packet_end


# --- Encoding Helpers ---

func _encode_remaining_length(length: int) -> PackedByteArray:
	var result := PackedByteArray()
	var value := length
	while true:
		var encoded_byte: int = value % 128
		value = value / 128
		if value > 0:
			encoded_byte = encoded_byte | 0x80
		result.append(encoded_byte)
		if value <= 0:
			break
	return result


func _encode_utf8_string(s: String) -> PackedByteArray:
	var utf8 := s.to_utf8_buffer()
	var result := PackedByteArray()
	result.append((utf8.size() >> 8) & 0xFF)
	result.append(utf8.size() & 0xFF)
	result.append_array(utf8)
	return result


func _next_packet_id() -> int:
	var id := _packet_id_counter
	_packet_id_counter = (_packet_id_counter % 65535) + 1
	return id


func _random_string(length: int) -> String:
	const CHARS := "abcdefghijklmnopqrstuvwxyz0123456789"
	var result := ""
	for i in length:
		result += CHARS[randi() % CHARS.length()]
	return result
