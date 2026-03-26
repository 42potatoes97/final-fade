class_name TransportWebRTC
extends RefCounted

# WebRTC transport with STUN servers and MQTT signaling for Final Fade
# Enables NAT traversal for true peer-to-peer connections

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal connection_established
signal connection_failed
signal signaling_ready(room_id: String)

const STUN_CONFIG: Dictionary = {
	"iceServers": [
		{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]}
	]
}

const ROOM_ID_LENGTH: int = 16
const ROOM_ID_CHARS: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

var signaling: SignalingClient
var rtc_peer: WebRTCPeerConnection
var rtc_multiplayer: WebRTCMultiplayerPeer
var room_id: String = ""
var is_host: bool = false


func init(signal_client: SignalingClient) -> void:
	signaling = signal_client
	signaling.message_received.connect(_on_signaling_message)


func create_host() -> WebRTCMultiplayerPeer:
	is_host = true
	room_id = _generate_room_id()

	rtc_peer = WebRTCPeerConnection.new()
	rtc_peer.initialize(STUN_CONFIG)
	rtc_peer.session_description_created.connect(_on_session_description_created)
	rtc_peer.ice_candidate_created.connect(_on_ice_candidate)

	# Create unreliable-ordered data channel for game data
	var channel_config := {
		"ordered": false,
		"maxRetransmits": 2,
	}
	rtc_peer.create_data_channel("game", channel_config)

	# Set up multiplayer peer as server (id 1)
	rtc_multiplayer = WebRTCMultiplayerPeer.new()
	rtc_multiplayer.create_server()
	rtc_multiplayer.add_peer(rtc_peer, 2)

	# Create SDP offer
	rtc_peer.create_offer()

	# Subscribe for answer from joiner
	var answer_topic := "finalfade/room/%s/answer" % room_id
	var ice_topic := "finalfade/room/%s/ice/client" % room_id
	signaling.subscribe(answer_topic)
	signaling.subscribe(ice_topic)

	signaling_ready.emit(room_id)
	return rtc_multiplayer


func create_client(code: String) -> WebRTCMultiplayerPeer:
	is_host = false
	room_id = code

	rtc_peer = WebRTCPeerConnection.new()
	rtc_peer.initialize(STUN_CONFIG)
	rtc_peer.session_description_created.connect(_on_session_description_created)
	rtc_peer.ice_candidate_created.connect(_on_ice_candidate)

	# Set up multiplayer peer as client
	rtc_multiplayer = WebRTCMultiplayerPeer.new()
	rtc_multiplayer.create_client(2)
	rtc_multiplayer.add_peer(rtc_peer, 1)

	# Subscribe to offer topic and host ICE candidates
	var offer_topic := "finalfade/room/%s/offer" % room_id
	var ice_topic := "finalfade/room/%s/ice/host" % room_id
	signaling.subscribe(offer_topic)
	signaling.subscribe(ice_topic)

	return rtc_multiplayer


func get_transport_name() -> String:
	return "WebRTC"


func get_room_id() -> String:
	return room_id


# --- Signaling Callbacks ---

func _on_session_description_created(type: String, sdp: String) -> void:
	rtc_peer.set_local_description(type, sdp)

	var payload := JSON.stringify({"type": type, "sdp": sdp})

	if is_host:
		var topic := "finalfade/room/%s/offer" % room_id
		signaling.publish(topic, payload)
	else:
		var topic := "finalfade/room/%s/answer" % room_id
		signaling.publish(topic, payload)


func _on_ice_candidate(media: String, index: int, sdp_name: String) -> void:
	var payload := JSON.stringify({
		"media": media,
		"index": index,
		"sdp": sdp_name,
	})

	var role := "host" if is_host else "client"
	var topic := "finalfade/room/%s/ice/%s" % [room_id, role]
	signaling.publish(topic, payload)


func _on_signaling_message(topic: String, payload: String) -> void:
	if room_id.is_empty():
		return

	var parsed = JSON.parse_string(payload)
	if parsed == null:
		push_warning("TransportWebRTC: Failed to parse signaling message")
		return

	# Handle SDP offer/answer
	if topic.ends_with("/offer") and not is_host:
		var type: String = parsed.get("type", "")
		var sdp: String = parsed.get("sdp", "")
		if type == "offer" and not sdp.is_empty():
			rtc_peer.set_remote_description(type, sdp)
			rtc_peer.create_answer()

	elif topic.ends_with("/answer") and is_host:
		var type: String = parsed.get("type", "")
		var sdp: String = parsed.get("sdp", "")
		if type == "answer" and not sdp.is_empty():
			rtc_peer.set_remote_description(type, sdp)

	# Handle ICE candidates
	elif "/ice/" in topic:
		var media: String = parsed.get("media", "")
		var index: int = parsed.get("index", 0)
		var sdp: String = parsed.get("sdp", "")
		if not media.is_empty() and not sdp.is_empty():
			rtc_peer.add_ice_candidate(media, index, sdp)


# --- Utility ---

func _generate_room_id() -> String:
	var result := ""
	for i in ROOM_ID_LENGTH:
		result += ROOM_ID_CHARS[randi() % ROOM_ID_CHARS.length()]
	return result
