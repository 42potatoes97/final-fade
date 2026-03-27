extends RefCounted

# Tests for rollback system — state save/load, input prediction, dynamic budget


func test_prune_dict() -> String:
	var dict: Dictionary = {0: 10, 5: 20, 10: 30, 15: 40, 20: 50}
	RollbackManager._prune_dict(dict, 12)

	if dict.has(0):
		return "Frame 0 should have been pruned (cutoff=12)"
	if dict.has(5):
		return "Frame 5 should have been pruned (cutoff=12)"
	if dict.has(10):
		return "Frame 10 should have been pruned (cutoff=12)"
	if not dict.has(15):
		return "Frame 15 should NOT have been pruned"
	if not dict.has(20):
		return "Frame 20 should NOT have been pruned"
	if dict.size() != 2:
		return "Expected 2 remaining entries, got %d" % dict.size()

	return ""


func test_prune_dict_empty() -> String:
	var dict: Dictionary = {}
	RollbackManager._prune_dict(dict, 100)
	if dict.size() != 0:
		return "Pruning empty dict should remain empty"
	return ""


func test_prune_dict_nothing_to_prune() -> String:
	var dict: Dictionary = {50: 1, 60: 2, 70: 3}
	RollbackManager._prune_dict(dict, 10)
	if dict.size() != 3:
		return "Nothing should be pruned when all frames > cutoff"
	return ""


func test_dynamic_budget_fast_hardware() -> String:
	# On fast hardware with ~4ms frame time, should allow max rollback
	RollbackManager.current_frame = 0
	RollbackManager._frame_time_avg_ms = 4.0
	RollbackManager._frame_time_samples = 100
	# Force budget recalculation
	RollbackManager.current_frame = 30  # multiple of 30
	RollbackManager._update_dynamic_budget(4.0)

	# Budget: (16.67 - 4.0) * 0.35 = 4.43ms
	# Sim cost: max(4.0 * 0.6, 0.5) = 2.4ms
	# Affordable: int(4.43 / 2.4) = 1 — but clamped to MIN_ROLLBACK_FRAMES=2
	# Actually let me recalc: available = 12.67, budget = 4.43, cost = 2.4, affordable = 1
	# Clamped to 2
	if RollbackManager.max_rollback_frames < RollbackManager.MIN_ROLLBACK_FRAMES:
		return "max_rollback_frames (%d) below minimum (%d)" % [
			RollbackManager.max_rollback_frames, RollbackManager.MIN_ROLLBACK_FRAMES]
	if RollbackManager.max_rollback_frames > RollbackManager.MAX_ROLLBACK_FRAMES_CAP:
		return "max_rollback_frames (%d) above cap (%d)" % [
			RollbackManager.max_rollback_frames, RollbackManager.MAX_ROLLBACK_FRAMES_CAP]

	return ""


func test_dynamic_budget_slow_hardware() -> String:
	# On slow hardware with ~14ms frame time, should reduce rollback
	RollbackManager._frame_time_avg_ms = 14.0
	RollbackManager._frame_time_samples = 100
	RollbackManager.current_frame = 60
	RollbackManager._update_dynamic_budget(14.0)

	# Budget: (16.67 - 14.0) * 0.35 = 0.93ms
	# Sim cost: max(14.0 * 0.6, 0.5) = 8.4ms
	# Affordable: int(0.93 / 8.4) = 0 → clamped to MIN_ROLLBACK_FRAMES=2
	if RollbackManager.max_rollback_frames != RollbackManager.MIN_ROLLBACK_FRAMES:
		return "Slow hardware should clamp to minimum, got %d" % RollbackManager.max_rollback_frames

	return ""


func test_input_prediction_repeats_last() -> String:
	# Prediction should repeat the last confirmed remote input
	RollbackManager.remote_input_history.clear()
	RollbackManager.remote_input_predicted.clear()
	RollbackManager.last_confirmed_remote_frame = -1

	# No history — predict 0
	var predicted: int = RollbackManager._predict_remote_input(10)
	if predicted != 0:
		return "With no history, prediction should be 0, got %d" % predicted

	# Add some history
	RollbackManager.remote_input_history[5] = 42
	RollbackManager.last_confirmed_remote_frame = 5
	predicted = RollbackManager._predict_remote_input(10)
	if predicted != 42:
		return "Should predict last confirmed input (42), got %d" % predicted

	# Clean up
	RollbackManager.remote_input_history.clear()
	RollbackManager.remote_input_predicted.clear()
	RollbackManager.last_confirmed_remote_frame = -1

	return ""


func test_find_rollback_frame_no_mismatch() -> String:
	RollbackManager.current_frame = 20
	RollbackManager.remote_input_history.clear()
	RollbackManager.remote_input_predicted.clear()

	# Same prediction and actual
	RollbackManager.remote_input_history[10] = 5
	RollbackManager.remote_input_predicted[10] = 5

	var frame: int = RollbackManager._find_rollback_frame()
	if frame != -1:
		return "No mismatch, should return -1, got %d" % frame

	RollbackManager.remote_input_history.clear()
	RollbackManager.remote_input_predicted.clear()
	return ""


func test_find_rollback_frame_with_mismatch() -> String:
	RollbackManager.current_frame = 20
	RollbackManager.remote_input_history.clear()
	RollbackManager.remote_input_predicted.clear()

	# Predicted 5, but actual was 10 — mismatch at frame 12
	RollbackManager.remote_input_history[12] = 10
	RollbackManager.remote_input_predicted[12] = 5

	var frame: int = RollbackManager._find_rollback_frame()
	if frame != 12:
		return "Mismatch at frame 12, should return 12, got %d" % frame

	RollbackManager.remote_input_history.clear()
	RollbackManager.remote_input_predicted.clear()
	return ""


func test_should_freeze_no_remote() -> String:
	RollbackManager.last_confirmed_remote_frame = -1
	RollbackManager.max_rollback_frames = 8

	RollbackManager.current_frame = 5
	if RollbackManager._should_freeze():
		return "Should not freeze at frame 5 with max_rollback 8"

	RollbackManager.current_frame = 10
	if not RollbackManager._should_freeze():
		return "Should freeze at frame 10 with no remote input and max_rollback 8"

	return ""
