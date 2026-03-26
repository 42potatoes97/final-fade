extends Node

# Input abstraction layer for Final Fade
# Supports keyboard AND gamepad per player
# Same interface used by keyboard, gamepad, netcode, and future RL agents

# Input bitfield flags
const INPUT_FORWARD  = 1 << 0
const INPUT_BACK     = 1 << 1
const INPUT_UP       = 1 << 2  # Sidestep into screen
const INPUT_DOWN     = 1 << 3  # Crouch / sidestep out of screen
const INPUT_BUTTON1  = 1 << 4  # Left punch (jab)
const INPUT_BUTTON2  = 1 << 5  # Right punch (high crush blow)
const INPUT_BUTTON3  = 1 << 6  # Left kick
const INPUT_BUTTON4  = 1 << 7  # Right kick

# Device types
enum DeviceType { KEYBOARD, GAMEPAD, AI, NETWORK }

# Per-player device assignment
# device_type: KEYBOARD or GAMEPAD
# device_id: -1 for keyboard, 0+ for gamepad index
var p1_device_type: DeviceType = DeviceType.KEYBOARD
var p1_device_id: int = -1  # -1 = keyboard
var p2_device_type: DeviceType = DeviceType.KEYBOARD
var p2_device_id: int = -1  # -1 = keyboard (uses numpad)

# Per-player input state (updated each physics tick)
var p1_input: int = 0
var p2_input: int = 0

# Player facing directions: 1 = facing right, -1 = facing left
var p1_facing: int = 1
var p2_facing: int = -1

# Gamepad deadzone
const STICK_DEADZONE: float = 0.3

# Connected gamepads cache
var connected_pads: Array = []

# AI controller registry
var _ai_controllers: Dictionary = {}

signal controller_connected(device_id: int, device_name: String)
signal controller_disconnected(device_id: int)


func _ready() -> void:
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	# Cache initially connected gamepads
	connected_pads = Input.get_connected_joypads()


func _on_joy_connection_changed(device_id: int, connected: bool) -> void:
	connected_pads = Input.get_connected_joypads()
	if connected:
		var pad_name = Input.get_joy_name(device_id)
		print("Controller connected: ", device_id, " — ", pad_name)
		controller_connected.emit(device_id, pad_name)
	else:
		print("Controller disconnected: ", device_id)
		controller_disconnected.emit(device_id)


func get_connected_gamepads() -> Array:
	return Input.get_connected_joypads()


func get_gamepad_name(device_id: int) -> String:
	return Input.get_joy_name(device_id)


func assign_device(player_id: int, device_type: DeviceType, device_id: int) -> void:
	if player_id == 1:
		p1_device_type = device_type
		p1_device_id = device_id
	else:
		p2_device_type = device_type
		p2_device_id = device_id


func _physics_process(_delta: float) -> void:
	# During online rollback, RollbackManager handles input injection
	if GameManager.online_mode:
		return
	p1_input = _read_player_input(1)
	p2_input = _read_player_input(2)


func _read_player_input(player_id: int) -> int:
	var device_type = p1_device_type if player_id == 1 else p2_device_type
	var device_id = p1_device_id if player_id == 1 else p2_device_id
	var facing = p1_facing if player_id == 1 else p2_facing

	match device_type:
		DeviceType.KEYBOARD:
			# device_id: -1 = P1 keyboard keys, -2 = P2 keyboard keys
			var kb_player = 1 if device_id == -1 else 2
			return _read_keyboard_input(kb_player, facing)
		DeviceType.GAMEPAD:
			return _read_gamepad_input(device_id, facing)
		DeviceType.AI:
			if _ai_controllers.has(player_id):
				return _ai_controllers[player_id].get_input()
			return 0
		DeviceType.NETWORK:
			# Network input is injected by RollbackManager
			return 0
	return 0


func _read_keyboard_input(player_id: int, facing: int) -> int:
	var prefix = "p" + str(player_id) + "_"

	var raw_left = Input.is_action_pressed(prefix + "left")
	var raw_right = Input.is_action_pressed(prefix + "right")
	var raw_up = Input.is_action_pressed(prefix + "up")
	var raw_down = Input.is_action_pressed(prefix + "down")

	var input_bits: int = 0

	# Convert raw left/right to forward/back based on facing
	if facing == 1:
		if raw_right: input_bits |= INPUT_FORWARD
		if raw_left: input_bits |= INPUT_BACK
	else:
		if raw_left: input_bits |= INPUT_FORWARD
		if raw_right: input_bits |= INPUT_BACK

	if raw_up: input_bits |= INPUT_UP
	if raw_down: input_bits |= INPUT_DOWN

	if Input.is_action_pressed(prefix + "button1"): input_bits |= INPUT_BUTTON1
	if Input.is_action_pressed(prefix + "button2"): input_bits |= INPUT_BUTTON2
	if Input.is_action_pressed(prefix + "button3"): input_bits |= INPUT_BUTTON3
	if Input.is_action_pressed(prefix + "button4"): input_bits |= INPUT_BUTTON4

	return input_bits


func _read_gamepad_input(device_id: int, facing: int) -> int:
	var input_bits: int = 0

	# Left stick / D-pad for movement
	var stick_x = Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X)
	var stick_y = Input.get_joy_axis(device_id, JOY_AXIS_LEFT_Y)
	var dpad_left = Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_LEFT)
	var dpad_right = Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_RIGHT)
	var dpad_up = Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_UP)
	var dpad_down = Input.is_joy_button_pressed(device_id, JOY_BUTTON_DPAD_DOWN)

	var raw_left = dpad_left or stick_x < -STICK_DEADZONE
	var raw_right = dpad_right or stick_x > STICK_DEADZONE
	var raw_up = dpad_up or stick_y < -STICK_DEADZONE
	var raw_down = dpad_down or stick_y > STICK_DEADZONE

	# Convert to forward/back based on facing
	if facing == 1:
		if raw_right: input_bits |= INPUT_FORWARD
		if raw_left: input_bits |= INPUT_BACK
	else:
		if raw_left: input_bits |= INPUT_FORWARD
		if raw_right: input_bits |= INPUT_BACK

	if raw_up: input_bits |= INPUT_UP
	if raw_down: input_bits |= INPUT_DOWN

	# Face buttons — Tekken PlayStation layout:
	# Square/X = 1 (left punch)     Triangle/Y = 2 (right punch)
	# Cross/A = 3 (left kick)       Circle/B = 4 (right kick)
	if Input.is_joy_button_pressed(device_id, JOY_BUTTON_X): input_bits |= INPUT_BUTTON1      # 1 — Square
	if Input.is_joy_button_pressed(device_id, JOY_BUTTON_Y): input_bits |= INPUT_BUTTON2      # 2 — Triangle
	if Input.is_joy_button_pressed(device_id, JOY_BUTTON_A): input_bits |= INPUT_BUTTON3      # 3 — Cross
	if Input.is_joy_button_pressed(device_id, JOY_BUTTON_B): input_bits |= INPUT_BUTTON4      # 4 — Circle

	# Shoulder buttons as alternate inputs (optional)
	# LB = 1+2, RB = 3+4 (common Tekken shortcut binds)
	if Input.is_joy_button_pressed(device_id, JOY_BUTTON_LEFT_SHOULDER):
		input_bits |= INPUT_BUTTON1 | INPUT_BUTTON2
	if Input.is_joy_button_pressed(device_id, JOY_BUTTON_RIGHT_SHOULDER):
		input_bits |= INPUT_BUTTON3 | INPUT_BUTTON4

	return input_bits


func get_input(player_id: int) -> int:
	return p1_input if player_id == 1 else p2_input


func set_facing(player_id: int, facing: int) -> void:
	if player_id == 1:
		p1_facing = facing
	else:
		p2_facing = facing


func register_ai(player_id: int, controller) -> void:
	_ai_controllers[player_id] = controller


func unregister_ai(player_id: int) -> void:
	_ai_controllers.erase(player_id)


# Inject input directly (for RL agents / netcode replay)
func inject_input(player_id: int, input_bits: int) -> void:
	if player_id == 1:
		p1_input = input_bits
	else:
		p2_input = input_bits


# Helper: check if a specific flag is set
static func has_flag(input_bits: int, flag: int) -> bool:
	return (input_bits & flag) != 0
