extends SceneTree

# Lightweight test runner — run with:
#   Godot --path final_fade --headless -s tests/test_runner.gd
#
# Runs all test_*.gd files in the tests/ directory.
# Each test file should have functions starting with "test_".
# Tests assert conditions; failures print the line and stop.

var _pass_count: int = 0
var _fail_count: int = 0
var _skip_count: int = 0


func _init():
	# Let autoloads initialize
	call_deferred("_run_all_tests")


func _run_all_tests() -> void:
	print("\n" + "============================================================")
	print("  FINAL FADE — TEST SUITE")
	print("============================================================" + "\n")

	var test_files: Array = [
		"res://tests/test_crypto.gd",
		"res://tests/test_combat.gd",
		"res://tests/test_rollback.gd",
		"res://tests/test_input.gd",
		"res://tests/test_profile.gd",
		"res://tests/test_network.gd",
	]

	for path in test_files:
		if not FileAccess.file_exists(path):
			print("⚠ SKIP %s (not found)" % path)
			_skip_count += 1
			continue
		_run_test_file(path)

	print("\n" + "============================================================")
	if _fail_count == 0:
		print("  ✅ ALL PASSED: %d tests, %d skipped" % [_pass_count, _skip_count])
	else:
		print("  ❌ FAILURES: %d passed, %d failed, %d skipped" % [_pass_count, _fail_count, _skip_count])
	print("============================================================" + "\n")

	quit(1 if _fail_count > 0 else 0)


func _run_test_file(path: String) -> void:
	var script = load(path)
	if script == null:
		print("❌ FAIL: Could not load %s" % path)
		_fail_count += 1
		return

	var instance = script.new()
	var file_name: String = path.get_file().replace(".gd", "")
	print("━━ %s ━━" % file_name)

	# Find and run all test_ methods
	var methods: Array = instance.get_method_list()
	for m in methods:
		var method_name: String = m["name"]
		if not method_name.begins_with("test_"):
			continue

		# Setup
		if instance.has_method("setup"):
			instance.call("setup")

		var result = instance.call(method_name)
		if result is String and result == "":
			print("  ✅ %s" % method_name)
			_pass_count += 1
		elif result == null:
			print("  ❌ %s — returned null (runtime error)" % method_name)
			_fail_count += 1
		else:
			print("  ❌ %s — %s" % [method_name, str(result)])
			_fail_count += 1

		# Teardown
		if instance.has_method("teardown"):
			instance.call("teardown")

	print("")
