class_name RatingCalculator
extends RefCounted

## Elo-based rating calculator with skill score modifier for Final Fade ranked.

const DEFAULT_RATING: float = 1000.0
const K_FACTOR_BASE: float = 32.0
const K_FACTOR_PROVISIONAL: float = 48.0
const PROVISIONAL_THRESHOLD: int = 10
const SKILL_WEIGHT: float = 0.15


## Takes an array of verified match proof dicts, each with:
##   p1_id, p2_id, winner_id, timestamp
## Sorts chronologically then applies Elo updates.
## Returns {player_id: {rating: int, matches: int, wins: int, losses: int}}.
static func calculate_ratings_from_chain(proofs: Array) -> Dictionary:
	# Sort by timestamp ascending
	var sorted_proofs: Array = proofs.duplicate()
	sorted_proofs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.get("timestamp", "") < b.get("timestamp", "")
	)

	var ratings: Dictionary = {}  # player_id -> {rating, matches, wins, losses}

	for proof in sorted_proofs:
		var p1_id: String = str(proof.get("p1_id", ""))
		var p2_id: String = str(proof.get("p2_id", ""))
		var winner_id: String = str(proof.get("winner_id", ""))

		if p1_id.is_empty() or p2_id.is_empty() or winner_id.is_empty():
			continue

		# Initialize players if unseen
		if not ratings.has(p1_id):
			ratings[p1_id] = {"rating": DEFAULT_RATING, "matches": 0, "wins": 0, "losses": 0}
		if not ratings.has(p2_id):
			ratings[p2_id] = {"rating": DEFAULT_RATING, "matches": 0, "wins": 0, "losses": 0}

		var ra: float = float(ratings[p1_id]["rating"])
		var rb: float = float(ratings[p2_id]["rating"])

		var score_a: float = 1.0 if winner_id == p1_id else 0.0
		var score_b: float = 1.0 - score_a

		var k_a: float = K_FACTOR_PROVISIONAL if ratings[p1_id]["matches"] < PROVISIONAL_THRESHOLD else K_FACTOR_BASE
		var k_b: float = K_FACTOR_PROVISIONAL if ratings[p2_id]["matches"] < PROVISIONAL_THRESHOLD else K_FACTOR_BASE

		var new_ra: float = _elo_update(ra, rb, score_a, k_a)
		var new_rb: float = _elo_update(rb, ra, score_b, k_b)

		ratings[p1_id]["rating"] = new_ra
		ratings[p2_id]["rating"] = new_rb

		ratings[p1_id]["matches"] += 1
		ratings[p2_id]["matches"] += 1

		if winner_id == p1_id:
			ratings[p1_id]["wins"] += 1
			ratings[p2_id]["losses"] += 1
		else:
			ratings[p2_id]["wins"] += 1
			ratings[p1_id]["losses"] += 1

	# Round final ratings to int
	for player_id in ratings:
		ratings[player_id]["rating"] = roundi(ratings[player_id]["rating"])

	return ratings


## Standard Elo formula: R_new = R_a + K * (S_a - E_a)
static func _elo_update(ra: float, rb: float, score_a: float, k: float) -> float:
	var expected_a: float = 1.0 / (1.0 + pow(10.0, (rb - ra) / 400.0))
	return ra + k * (score_a - expected_a)


## Calculates a composite skill score from gameplay metrics.
## metrics keys: input_diversity, avg_reaction_frames, punishment_rate, movement_variety
## All should be raw values; this function normalizes and clamps internally.
## Returns 0.0 to 1.0.
static func calculate_skill_score(metrics: Dictionary) -> float:
	var diversity: float = clampf(metrics.get("input_diversity", 0.0), 0.0, 1.0)

	# Reaction: lower frames = better. 3 frames = perfect (1.0), 15+ frames = 0.0
	var raw_reaction: float = metrics.get("avg_reaction_frames", 15.0)
	var reaction: float = clampf(1.0 - (raw_reaction - 3.0) / 12.0, 0.0, 1.0)

	var punishment: float = clampf(metrics.get("punishment_rate", 0.0), 0.0, 1.0)
	var movement: float = clampf(metrics.get("movement_variety", 0.0), 0.0, 1.0)

	# Weighted sum: diversity 0.2, reaction 0.3, punishment 0.3, movement 0.2
	var score: float = (
		diversity * 0.2
		+ reaction * 0.3
		+ punishment * 0.3
		+ movement * 0.2
	)

	return clampf(score, 0.0, 1.0)


## Adjusts base Elo rating with skill score modifier.
## Skill score of 0.5 is neutral; above adds rating, below subtracts.
static func get_display_rating(base_rating: float, skill_score: float) -> int:
	return clampi(roundi(base_rating * (1.0 + SKILL_WEIGHT * (skill_score - 0.5))), 100, 9999)
