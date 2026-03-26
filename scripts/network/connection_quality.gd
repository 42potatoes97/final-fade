class_name ConnectionQuality
extends RefCounted

# Connection quality tracker for Final Fade online play
# Measures ping, jitter, and packet loss via ping/pong packets

const HISTORY_SIZE: int = 10
const PING_MARKER: int = 0xAA  # 0xPP -> using 0xAA
const PONG_MARKER: int = 0xBB  # 0xPO -> using 0xBB

var current_ping_ms: float = 0.0
var jitter_ms: float = 0.0
var packet_loss_pct: float = 0.0
var recommended_delay: int = 1

var ping_history: Array = []
var _sent_pings: Dictionary = {}
var _next_seq: int = 0
var _received_count: int = 0
var _expected_count: int = 0


# --- Packet Creation ---

func create_ping_packet() -> PackedByteArray:
	var seq: int = _next_seq
	_next_seq = (_next_seq + 1) % 65536
	_expected_count += 1

	var timestamp_ms: int = Time.get_ticks_msec()
	_sent_pings[seq] = timestamp_ms

	# Format: [1B marker][2B seq_num][4B timestamp_ms]
	var packet: PackedByteArray = PackedByteArray()
	packet.resize(7)
	packet[0] = PING_MARKER
	packet.encode_u16(1, seq)
	packet.encode_u32(3, timestamp_ms)
	return packet


func create_pong_packet(ping_data: PackedByteArray) -> PackedByteArray:
	if ping_data.size() < 7 or ping_data[0] != PING_MARKER:
		return PackedByteArray()

	# Echo back with pong marker: [1B marker][2B original_seq][4B original_timestamp]
	var packet: PackedByteArray = ping_data.duplicate()
	packet[0] = PONG_MARKER
	return packet


# --- Packet Processing ---

func process_pong(pong_data: PackedByteArray) -> void:
	if pong_data.size() < 7 or pong_data[0] != PONG_MARKER:
		return

	var seq: int = pong_data.decode_u16(1)
	var original_timestamp: int = pong_data.decode_u32(3)

	if not _sent_pings.has(seq):
		return

	_sent_pings.erase(seq)
	_received_count += 1

	var now: int = Time.get_ticks_msec()
	var rtt: float = float(now - original_timestamp)

	ping_history.append(rtt)
	if ping_history.size() > HISTORY_SIZE:
		ping_history.pop_front()

	update_metrics()


# --- Metrics ---

func update_metrics() -> void:
	if ping_history.is_empty():
		current_ping_ms = 0.0
		jitter_ms = 0.0
		packet_loss_pct = 0.0
		recommended_delay = 1
		return

	# Average ping
	var sum: float = 0.0
	for sample in ping_history:
		sum += sample
	current_ping_ms = sum / ping_history.size()

	# Jitter (standard deviation)
	var variance_sum: float = 0.0
	for sample in ping_history:
		var diff: float = sample - current_ping_ms
		variance_sum += diff * diff
	jitter_ms = sqrt(variance_sum / ping_history.size())

	# Packet loss
	if _expected_count > 0:
		packet_loss_pct = (1.0 - float(_received_count) / float(_expected_count)) * 100.0
	else:
		packet_loss_pct = 0.0

	# Recommended rollback delay in frames (16.67ms per frame at 60fps)
	recommended_delay = get_recommended_delay()


func get_recommended_delay() -> int:
	return clampi(ceili(current_ping_ms / 16.67), 1, 5)


# --- Packet Identification ---

func is_ping_packet(data: PackedByteArray) -> bool:
	return data.size() >= 7 and data[0] == PING_MARKER


func is_pong_packet(data: PackedByteArray) -> bool:
	return data.size() >= 7 and data[0] == PONG_MARKER
