class_name InputBuffer
extends RefCounted

# Stores N frames of input for command detection
# Used for double-taps (dash), sequences (wavedash), and tap vs hold

const BUFFER_SIZE: int = 20  # Frames of history
const DOUBLE_TAP_WINDOW: int = 12  # Frames to detect f,f or b,b (200ms at 60fps)
const TAP_THRESHOLD: int = 6  # Max frames held to count as a tap (vs hold)
const ACTION_BUFFER_WINDOW: int = 8  # Frames before state exit where buffering activates
const ACTION_BUFFER_EXPIRY: int = 10  # Max frames a buffered action stays valid

var buffer: Array[int] = []
var frame_count: int = 0

# Action buffer — stores queued action during recovery/hitstun/blockstun
# {type: "attack"/"movement", data: Resource/String, frame: int}
var buffered_action: Dictionary = {}


func push(input_bits: int) -> void:
	buffer.push_back(input_bits)
	if buffer.size() > BUFFER_SIZE:
		buffer.pop_front()
	frame_count += 1


func get_current() -> int:
	if buffer.is_empty():
		return 0
	return buffer.back()


func get_previous(frames_ago: int = 1) -> int:
	var idx = buffer.size() - 1 - frames_ago
	if idx < 0 or idx >= buffer.size():
		return 0
	return buffer[idx]


# Check if a flag was just pressed this frame (wasn't pressed last frame)
func just_pressed(flag: int) -> bool:
	if buffer.size() < 2:
		return _has(get_current(), flag)
	return _has(get_current(), flag) and not _has(get_previous(), flag)


# Check if a flag was just released this frame
func just_released(flag: int) -> bool:
	if buffer.size() < 2:
		return false
	return not _has(get_current(), flag) and _has(get_previous(), flag)


# Detect double-tap: flag pressed, released, pressed again within window
func detect_double_tap(flag: int) -> bool:
	if buffer.size() < 3:
		return false
	if not just_pressed(flag):
		return false

	# Look back through buffer for a previous press-release of same flag
	var found_release = false
	var found_first_press = false
	var search_limit = mini(buffer.size() - 1, DOUBLE_TAP_WINDOW)

	for i in range(1, search_limit):
		var prev = get_previous(i)
		if not found_release:
			if not _has(prev, flag):
				found_release = true
		else:
			if _has(prev, flag):
				found_first_press = true
				break

	return found_first_press


# Detect if a flag was tapped (pressed and released quickly)
func was_tapped(flag: int) -> bool:
	if not just_released(flag):
		return false

	# Count how many frames it was held
	var held_frames = 0
	for i in range(1, mini(buffer.size(), TAP_THRESHOLD + 2)):
		if _has(get_previous(i), flag):
			held_frames += 1
		else:
			break

	return held_frames <= TAP_THRESHOLD


# Detect wavedash input: forward, neutral, down, down+forward (f, n, d, df)
# In terms of our bitfield: FORWARD pressed, then nothing, then DOWN, then FORWARD+DOWN
var _crouch_dash_cooldown: int = 0

func detect_crouch_dash_input() -> bool:
	# f, n, d, df — Tekken crouch dash / wavedash input
	# Loosened: just needs forward, then down, then df within window
	# The df check in idle/crouch states prevents false triggers from holding df
	if _crouch_dash_cooldown > 0:
		_crouch_dash_cooldown -= 1
		return false

	if buffer.size() < 3:
		return false

	var IM = InputManager
	var curr = get_current()

	# Current frame must have df (down+forward)
	if not (_has(curr, IM.INPUT_DOWN) and _has(curr, IM.INPUT_FORWARD)):
		return false

	# Look back for forward input within 10 frames
	# Sequence: somewhere we had forward, then at some point down, now df
	var found_down = false
	var found_forward = false
	var window = mini(buffer.size() - 1, 10)

	for i in range(1, window):
		var prev = get_previous(i)
		var has_fwd = _has(prev, IM.INPUT_FORWARD)
		var has_down = _has(prev, IM.INPUT_DOWN)

		if not found_down:
			# Looking for down (with or without forward)
			if has_down:
				found_down = true
		elif not found_forward:
			# Looking for forward without down (the initial f tap)
			if has_fwd and not has_down:
				found_forward = true
				break

	if found_forward:
		_crouch_dash_cooldown = 6  # Short cooldown — allows fast chains if inputs are clean
	return found_forward


# Detect QCB input: down, down+back, back (d, db, b)
# This is the "bad KBD" input — backsway comes out when you mess up the cancel
func detect_qcb_input() -> bool:
	if buffer.size() < 3:
		return false

	var IM = InputManager
	var curr = get_current()

	# Current frame should have BACK (no down)
	if not _has(curr, IM.INPUT_BACK):
		return false
	if _has(curr, IM.INPUT_DOWN):
		return false  # Still in db, not pure back yet

	# Look back for db then d within a window
	var found_db = false
	var found_down = false
	var window = mini(buffer.size() - 1, 12)

	for i in range(1, window):
		var prev = get_previous(i)
		if not found_db:
			# Looking for down+back
			if _has(prev, IM.INPUT_DOWN) and _has(prev, IM.INPUT_BACK):
				found_db = true
		elif not found_down:
			# Looking for pure down (before the db)
			if _has(prev, IM.INPUT_DOWN) and not _has(prev, IM.INPUT_BACK):
				found_down = true
				break

	return found_down


# Check how many frames a flag has been held continuously
func held_duration(flag: int) -> int:
	var count = 0
	for i in range(buffer.size()):
		var idx = buffer.size() - 1 - i
		if _has(buffer[idx], flag):
			count += 1
		else:
			break
	return count


func clear() -> void:
	buffer.clear()
	frame_count = 0
	buffered_action = {}


# --- Action Buffer ---
# Called by states during "can't act" windows to queue the next action

func buffer_action(type: String, data) -> void:
	buffered_action = {"type": type, "data": data, "frame": frame_count}


func consume_buffered_action() -> Dictionary:
	if buffered_action.is_empty():
		return {}
	# Check expiry
	if frame_count - buffered_action.get("frame", 0) > ACTION_BUFFER_EXPIRY:
		buffered_action = {}
		return {}
	var action = buffered_action
	buffered_action = {}
	return action


func has_buffered_action() -> bool:
	if buffered_action.is_empty():
		return false
	return frame_count - buffered_action.get("frame", 0) <= ACTION_BUFFER_EXPIRY


# --- Rollback serialization ---
func save_state() -> Dictionary:
	var ba = buffered_action.duplicate() if not buffered_action.is_empty() else {}
	if ba.has("data") and ba.data != null and ba.data is Resource:
		ba["data_cmd"] = ba.data.input_command
		ba.erase("data")
	return {
		"buf": buffer.duplicate(),
		"fc": frame_count,
		"ba": ba,
		"cdc": _crouch_dash_cooldown,
	}

func load_state(s: Dictionary, move_registry = null) -> void:
	buffer = s.get("buf", []).duplicate()
	frame_count = s.get("fc", 0)
	_crouch_dash_cooldown = s.get("cdc", 0)
	var ba = s.get("ba", {})
	if ba.has("data_cmd") and move_registry:
		ba["data"] = move_registry.moves.get(ba["data_cmd"])
		ba.erase("data_cmd")
	buffered_action = ba


static func _has(bits: int, flag: int) -> bool:
	return (bits & flag) != 0
