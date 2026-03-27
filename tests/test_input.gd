extends RefCounted

# Tests for input system — buffer, flags, double-tap detection


func test_input_flags() -> String:
	var IM = InputManager

	# Test individual flags using bitwise OR (no set_flag method)
	var bits: int = 0
	bits = bits | IM.INPUT_UP
	if not IM.has_flag(bits, IM.INPUT_UP):
		return "INPUT_UP should be set"
	if IM.has_flag(bits, IM.INPUT_DOWN):
		return "INPUT_DOWN should NOT be set"

	# Add another flag
	bits = bits | IM.INPUT_BUTTON1
	if not IM.has_flag(bits, IM.INPUT_UP):
		return "INPUT_UP should still be set after adding ATTACK1"
	if not IM.has_flag(bits, IM.INPUT_BUTTON1):
		return "INPUT_BUTTON1 should be set"

	return ""


func test_input_flags_combined() -> String:
	var IM = InputManager
	var bits: int = 0
	bits = bits | IM.INPUT_DOWN | IM.INPUT_FORWARD

	if not IM.has_flag(bits, IM.INPUT_DOWN):
		return "INPUT_DOWN should be set in combined"
	if not IM.has_flag(bits, IM.INPUT_FORWARD):
		return "INPUT_FORWARD should be set in combined"
	if IM.has_flag(bits, IM.INPUT_BACK):
		return "INPUT_BACK should NOT be set in combined"

	return ""


func test_input_buffer_creation() -> String:
	var BufferScript = load("res://scripts/fighter/input_buffer.gd")
	var buf = BufferScript.new()

	if buf.BUFFER_SIZE <= 0:
		return "Buffer size should be positive"
	if buf.DOUBLE_TAP_WINDOW <= 0:
		return "Double tap window should be positive"

	return ""


func test_input_buffer_save_load_state() -> String:
	var BufferScript = load("res://scripts/fighter/input_buffer.gd")
	var buf = BufferScript.new()

	# Push some input frames using the correct method
	buf.push(1)
	buf.push(2)
	buf.push(3)

	var saved: Dictionary = buf.save_state()
	if saved.is_empty():
		return "save_state should return non-empty dict"

	# Verify it has expected keys
	if not saved.has("fc"):
		return "save_state should have 'fc' (frame_count)"

	return ""


func test_double_tap_window() -> String:
	# The double-tap window should be 12 frames (200ms at 60fps)
	var BufferScript = load("res://scripts/fighter/input_buffer.gd")
	var buf = BufferScript.new()

	if buf.DOUBLE_TAP_WINDOW != 12:
		return "DOUBLE_TAP_WINDOW should be 12, got %d" % buf.DOUBLE_TAP_WINDOW

	return ""
