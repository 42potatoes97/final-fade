class_name TransportENet
extends RefCounted

# ENet transport wrapper for Final Fade peer-to-peer connections
# Wraps ENetMultiplayerPeer with unified transport signals

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal connection_established
signal connection_failed

var _tree: SceneTree


func init(tree: SceneTree) -> void:
	_tree = tree


func create_host(port: int) -> ENetMultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 1)
	if err != OK:
		push_error("TransportENet: Failed to create host on port %d (error %d)" % [port, err])
		return null

	_tree.get_multiplayer().multiplayer_peer = peer
	_connect_signals()
	return peer


func create_client(ip: String, port: int) -> ENetMultiplayerPeer:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		push_error("TransportENet: Failed to connect to %s:%d (error %d)" % [ip, port, err])
		return null

	_tree.get_multiplayer().multiplayer_peer = peer
	_connect_signals()
	return peer


func get_transport_name() -> String:
	return "ENet"


# --- Internal Signal Wiring ---

func _connect_signals() -> void:
	var mp := _tree.get_multiplayer()
	mp.peer_connected.connect(_on_peer_connected)
	mp.peer_disconnected.connect(_on_peer_disconnected)
	mp.connected_to_server.connect(_on_connected_to_server)
	mp.connection_failed.connect(_on_connection_failed)


func _on_peer_connected(id: int) -> void:
	peer_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	peer_disconnected.emit(id)


func _on_connected_to_server() -> void:
	connection_established.emit()


func _on_connection_failed() -> void:
	connection_failed.emit()
