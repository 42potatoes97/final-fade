extends RefCounted

# Tests for profile system — identity, export/import, stats


func test_profile_id_generated() -> String:
	# ProfileManager should always have a profile_id
	if ProfileManager.profile_id.length() == 0:
		return "profile_id should not be empty"
	if ProfileManager.profile_id.length() < 16:
		return "profile_id should be at least 16 chars, got %d" % ProfileManager.profile_id.length()
	return ""


func test_profile_id_stable() -> String:
	# Profile ID should not change between accesses
	var id1: String = ProfileManager.profile_id
	var id2: String = ProfileManager.profile_id
	if id1 != id2:
		return "profile_id changed between accesses"
	return ""


func test_profile_export_import_roundtrip() -> String:
	# Save current state
	var original_name: String = ProfileManager.username

	# Set test data
	ProfileManager.username = "TestPlayer123"
	var exported: String = ProfileManager.export_profile()

	if exported.length() == 0:
		ProfileManager.username = original_name
		return "export_profile returned empty string"

	# Export is base64-encoded JSON — decode and verify
	var decoded_bytes: PackedByteArray = Marshalls.base64_to_raw(exported)
	if decoded_bytes.is_empty():
		ProfileManager.username = original_name
		return "export_profile should return valid base64"

	var json_str: String = decoded_bytes.get_string_from_utf8()
	var parsed = JSON.parse_string(json_str)
	if parsed == null:
		ProfileManager.username = original_name
		return "Decoded export should be valid JSON"

	if not parsed.has("username"):
		ProfileManager.username = original_name
		return "Exported profile missing 'username'"
	if parsed["username"] != "TestPlayer123":
		ProfileManager.username = original_name
		return "Exported username mismatch"

	# Restore
	ProfileManager.username = original_name
	return ""


func test_stats_structure() -> String:
	var stats: Dictionary = ProfileManager.stats
	if not stats.has("wins"):
		return "Stats missing 'wins'"
	if not stats.has("losses"):
		return "Stats missing 'losses'"
	if not stats.has("total_matches"):
		return "Stats missing 'total_matches'"
	return ""


func test_stats_wins_not_negative() -> String:
	var stats: Dictionary = ProfileManager.stats
	if stats.get("wins", 0) < 0:
		return "Wins should not be negative"
	if stats.get("losses", 0) < 0:
		return "Losses should not be negative"
	if stats.get("total_matches", 0) < 0:
		return "Total matches should not be negative"
	return ""


func test_rating_calculator_defaults() -> String:
	if RatingCalculator.DEFAULT_RATING != 1000.0:
		return "Default rating should be 1000, got %.0f" % RatingCalculator.DEFAULT_RATING
	if RatingCalculator.K_FACTOR_BASE <= 0:
		return "K factor should be positive"
	return ""


func test_elo_calculation() -> String:
	# Use calculate_ratings_from_chain with a single proof
	var proofs: Array = [{
		"p1_id": "player_a",
		"p2_id": "player_b",
		"winner_id": "player_a",
	}]
	var ratings: Dictionary = RatingCalculator.calculate_ratings_from_chain(proofs)

	var a_rating: float = ratings["player_a"]["rating"]
	var b_rating: float = ratings["player_b"]["rating"]

	# Winner should gain, loser should lose
	if a_rating <= 1000.0:
		return "Winner rating should increase above 1000, got %.0f" % a_rating
	if b_rating >= 1000.0:
		return "Loser rating should decrease below 1000, got %.0f" % b_rating

	return ""


func test_elo_upset_bonus() -> String:
	# Low-rated player beating high-rated should gain more
	# Simulate: A has 800, B has 1200, A wins
	# First give B some wins to raise rating, then A beats B
	var proofs: Array = []
	# Give B 5 wins to raise rating
	for i in range(5):
		proofs.append({"p1_id": "player_b", "p2_id": "dummy_%d" % i, "winner_id": "player_b"})
	# Now A beats B
	proofs.append({"p1_id": "player_a", "p2_id": "player_b", "winner_id": "player_a"})

	var ratings: Dictionary = RatingCalculator.calculate_ratings_from_chain(proofs)
	var a_delta: float = ratings["player_a"]["rating"] - 1000.0

	# Even match comparison
	var even_proofs: Array = [{"p1_id": "p_even_a", "p2_id": "p_even_b", "winner_id": "p_even_a"}]
	var even_ratings: Dictionary = RatingCalculator.calculate_ratings_from_chain(even_proofs)
	var even_delta: float = even_ratings["p_even_a"]["rating"] - 1000.0

	if a_delta <= even_delta:
		return "Upset win should gain more Elo (%.0f) than even match (%.0f)" % [a_delta, even_delta]

	return ""
