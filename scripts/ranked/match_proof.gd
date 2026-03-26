class_name MatchProof
extends RefCounted

## Cryptographic match proof system for Final Fade ranked.
## Uses HMAC-SHA256 signatures and SHA-256 hashing via CryptoUtils and HashingContext.

const SIGN_TIMEOUT_SEC: float = 15.0
const MAX_PROOF_SIZE: int = 4096


## Builds canonical match data dictionary.
## round_results: [{round: int, winner_id: str, p1_health: int, p2_health: int}]
static func create_match_data(
	p1_id: String,
	p2_id: String,
	winner_id: String,
	replay_cid: String,
	round_results: Array,
	timestamp: String,
) -> Dictionary:
	return {
		"p1_id": p1_id,
		"p2_id": p2_id,
		"winner_id": winner_id,
		"replay_cid": replay_cid,
		"round_results": round_results,
		"timestamp": timestamp,
	}


## Deterministic hash of match data: sort keys -> JSON -> SHA-256 hex.
static func hash_match(match_data: Dictionary) -> String:
	var json_text: String = _sorted_json(match_data)
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(json_text.to_utf8_buffer())
	var digest: PackedByteArray = ctx.finish()
	return digest.hex_encode()


## HMAC-SHA256 sign a match hash with the player's signing key.
## Returns base64-encoded signature.
static func sign_match(match_hash: String, signing_key: PackedByteArray) -> String:
	var mac: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, match_hash.to_utf8_buffer())
	return Marshalls.raw_to_base64(mac)


## Verify an HMAC-SHA256 signature using constant-time comparison.
static func verify_signature(match_hash: String, sig_b64: String, signing_key: PackedByteArray) -> bool:
	var expected_mac: PackedByteArray = CryptoUtils.hmac_sha256(signing_key, match_hash.to_utf8_buffer())
	var received_mac: PackedByteArray = Marshalls.base64_to_raw(sig_b64)

	if expected_mac.size() != received_mac.size():
		return false

	# Constant-time compare
	var diff: int = 0
	for i in range(expected_mac.size()):
		diff = diff | (expected_mac[i] ^ received_mac[i])
	return diff == 0


## Combines match data with both player signatures into a complete proof.
static func create_proof(match_data: Dictionary, p1_sig: String, p2_sig: String) -> Dictionary:
	var match_hash: String = hash_match(match_data)
	return {
		"match_data": match_data,
		"match_hash": match_hash,
		"p1_sig": p1_sig,
		"p2_sig": p2_sig,
	}


## Validates that a proof dict has all required fields, correct types,
## and that the embedded hash matches recomputation from match_data.
static func verify_proof_structure(proof: Dictionary) -> bool:
	# Required top-level keys
	var required_keys: Array = ["match_data", "match_hash", "p1_sig", "p2_sig"]
	for key in required_keys:
		if not proof.has(key):
			return false

	if not proof["match_data"] is Dictionary:
		return false
	if not proof["match_hash"] is String:
		return false
	if not proof["p1_sig"] is String:
		return false
	if not proof["p2_sig"] is String:
		return false

	# Required match_data keys
	var md: Dictionary = proof["match_data"]
	var md_keys: Array = ["p1_id", "p2_id", "winner_id", "replay_cid", "round_results", "timestamp"]
	for key in md_keys:
		if not md.has(key):
			return false

	if not md["p1_id"] is String:
		return false
	if not md["p2_id"] is String:
		return false
	if not md["winner_id"] is String:
		return false
	if not md["replay_cid"] is String:
		return false
	if not md["round_results"] is Array:
		return false
	if not md["timestamp"] is String:
		return false

	# Verify hash matches recomputation
	var recomputed_hash: String = hash_match(md)
	if recomputed_hash != proof["match_hash"]:
		return false

	return true


## Builds a proof chain for a player from an array of proof dicts.
## Each proof gets a prev_hash linking to the previous proof's match_hash.
## chain_hash = SHA-256 of all proof hashes + prev_hash links concatenated in order.
static func build_proof_chain(player_id: String, proofs: Array) -> Dictionary:
	# Add prev_hash links to each proof
	var prev_hash: String = ""
	for i in range(proofs.size()):
		proofs[i]["prev_hash"] = prev_hash
		prev_hash = proofs[i].get("match_hash", "")

	# Compute chain_hash from all proof hashes INCLUDING prev_hash links
	var hash_data: String = ""
	for proof in proofs:
		hash_data += proof.get("prev_hash", "")
		hash_data += proof.get("match_hash", "")

	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(hash_data.to_utf8_buffer())
	var chain_hash: String = ctx.finish().hex_encode()

	return {
		"player_id": player_id,
		"proofs": proofs,
		"chain_hash": chain_hash,
	}


## Verifies a proof chain by recomputing chain_hash from its proofs.
## Also verifies prev_hash links form a valid chain, timestamps are strictly
## ascending, and no duplicate proofs exist (by match_hash).
static func verify_chain_integrity(chain: Dictionary) -> bool:
	if not chain.has("player_id") or not chain.has("proofs") or not chain.has("chain_hash"):
		return false
	if not chain["proofs"] is Array:
		return false

	var proofs: Array = chain["proofs"]
	var seen_hashes: Dictionary = {}
	var prev_expected: String = ""
	var last_timestamp: String = ""

	var hash_data: String = ""
	for i in range(proofs.size()):
		var proof = proofs[i]
		if not proof is Dictionary:
			return false

		var match_hash: String = proof.get("match_hash", "")
		var prev_hash: String = proof.get("prev_hash", "")

		# Verify prev_hash links: first proof must have empty prev_hash,
		# subsequent proofs must link to the previous proof's match_hash
		if prev_hash != prev_expected:
			return false
		prev_expected = match_hash

		# Check for duplicate proofs by match_hash
		if seen_hashes.has(match_hash):
			return false
		seen_hashes[match_hash] = true

		# Verify timestamps are strictly ascending
		var md: Dictionary = proof.get("match_data", {})
		if md is Dictionary and md.has("timestamp"):
			var ts: String = str(md["timestamp"])
			if not last_timestamp.is_empty() and ts <= last_timestamp:
				return false
			last_timestamp = ts

		hash_data += prev_hash
		hash_data += match_hash

	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(hash_data.to_utf8_buffer())
	var recomputed: String = ctx.finish().hex_encode()

	return recomputed == chain["chain_hash"]


## Deterministic JSON with recursively sorted dictionary keys.
static func _sorted_json(data: Variant) -> String:
	if data is Dictionary:
		var keys: Array = data.keys()
		keys.sort()
		var parts: PackedStringArray = PackedStringArray()
		for key in keys:
			var key_json: String = JSON.stringify(str(key))
			var val_json: String = _sorted_json(data[key])
			parts.append("%s:%s" % [key_json, val_json])
		return "{%s}" % ",".join(parts)
	elif data is Array:
		var parts: PackedStringArray = PackedStringArray()
		for item in data:
			parts.append(_sorted_json(item))
		return "[%s]" % ",".join(parts)
	else:
		return JSON.stringify(data)
