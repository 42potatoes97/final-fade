class_name CryptoUtils

# Cryptographic utilities for Final Fade online play
# AES-256 room code encryption, CRC32 packet integrity, HMAC-SHA256 auth

# Room code character set (31 chars, no ambiguous I/O/0/1)
const CODE_CHARS: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


# --- AES-256-CBC Encryption for Room Codes ---

static func generate_session_key() -> PackedByteArray:
	# Full 32-byte key for AES-256 (no padding/mirroring)
	var crypto: Crypto = Crypto.new()
	return crypto.generate_random_bytes(32)


static func _derive_key(session_key: PackedByteArray) -> PackedByteArray:
	# HKDF-like key derivation: SHA256(session_key + "finalfade-room-key")
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(session_key)
	ctx.update("finalfade-room-key".to_utf8_buffer())
	return ctx.finish()  # Always 32 bytes


static func encrypt_room_data(ip: String, port: int, session_key: PackedByteArray) -> PackedByteArray:
	# Pack IP:port into 16 bytes, encrypt with AES-256-CBC + random IV
	var parts: PackedStringArray = ip.split(".")
	if parts.size() != 4:
		return PackedByteArray()

	var plaintext: PackedByteArray = PackedByteArray()
	plaintext.resize(16)  # One AES block
	for i in range(4):
		plaintext[i] = int(parts[i]) & 0xFF
	plaintext[4] = (port >> 8) & 0xFF
	plaintext[5] = port & 0xFF
	# Bytes 6-15: random padding for uniqueness per encryption
	var crypto: Crypto = Crypto.new()
	var padding: PackedByteArray = crypto.generate_random_bytes(10)
	for i in range(10):
		plaintext[6 + i] = padding[i]

	# Generate random IV for CBC mode
	var iv: PackedByteArray = crypto.generate_random_bytes(16)
	var key_32: PackedByteArray = _derive_key(session_key)

	var aes: AESContext = AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, key_32, iv)
	var ciphertext: PackedByteArray = aes.update(plaintext)
	aes.finish()

	# Compute HMAC-SHA256 auth tag over (IV + ciphertext), truncated to 16 bytes
	var iv_cipher: PackedByteArray = PackedByteArray()
	iv_cipher.append_array(iv)
	iv_cipher.append_array(ciphertext)
	var auth_tag: PackedByteArray = hmac_sha256(key_32, iv_cipher).slice(0, 16)

	# Return IV + ciphertext + auth_tag
	var result: PackedByteArray = PackedByteArray()
	result.append_array(iv)
	result.append_array(ciphertext)
	result.append_array(auth_tag)
	return result  # 48 bytes: [16B IV][16B ciphertext][16B auth_tag]


static func decrypt_room_data(encrypted: PackedByteArray, session_key: PackedByteArray) -> Dictionary:
	if encrypted.size() != 48:
		return {"ip": "", "port": 0, "valid": false}

	var iv: PackedByteArray = encrypted.slice(0, 16)
	var ciphertext: PackedByteArray = encrypted.slice(16, 32)
	var received_tag: PackedByteArray = encrypted.slice(32, 48)
	var key_32: PackedByteArray = _derive_key(session_key)

	# Verify auth tag before decrypting (authenticate-then-decrypt)
	var iv_cipher: PackedByteArray = PackedByteArray()
	iv_cipher.append_array(iv)
	iv_cipher.append_array(ciphertext)
	var expected_tag: PackedByteArray = hmac_sha256(key_32, iv_cipher).slice(0, 16)
	# Constant-time comparison
	var tag_diff: int = 0
	for i in range(16):
		tag_diff = tag_diff | (received_tag[i] ^ expected_tag[i])
	if tag_diff != 0:
		return {"ip": "", "port": 0, "valid": false}

	var aes: AESContext = AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, key_32, iv)
	var plaintext: PackedByteArray = aes.update(ciphertext)
	aes.finish()

	var ip: String = "%d.%d.%d.%d" % [plaintext[0], plaintext[1], plaintext[2], plaintext[3]]
	var port: int = (plaintext[4] << 8) | plaintext[5]

	# Basic validation
	for i in range(4):
		if plaintext[i] > 255:
			return {"ip": "", "port": 0, "valid": false}
	if port <= 0 or port > 65535:
		return {"ip": "", "port": 0, "valid": false}

	return {"ip": ip, "port": port, "valid": true}


# --- Room Code Encoding (bytes <-> alphanumeric string) ---

static func bytes_to_code(data: PackedByteArray) -> String:
	# Convert arbitrary bytes to base-31 alphanumeric string
	# Process as big-endian integer
	var value: Array = [0]  # Use array of ints for big number math
	for b in data:
		value = _bignum_mul_add(value, 256, b)

	var base: int = CODE_CHARS.length()
	var chars: Array = []
	while not _bignum_is_zero(value):
		var result: Dictionary = _bignum_divmod(value, base)
		value = result["quotient"]
		chars.push_front(CODE_CHARS[result["remainder"]])

	# Pad to consistent length (32 bytes -> ~49 chars)
	var expected_len: int = ceili(data.size() * 8.0 / log(base) * log(2))
	while chars.size() < expected_len:
		chars.push_front(CODE_CHARS[0])

	var code: String = ""
	for c in chars:
		code += c
	return code


static func code_to_bytes(code: String, expected_size: int) -> PackedByteArray:
	# Convert base-31 string back to bytes
	var base: int = CODE_CHARS.length()
	var value: Array = [0]

	for i in range(code.length()):
		var idx: int = CODE_CHARS.find(code[i].to_upper())
		if idx < 0:
			return PackedByteArray()
		value = _bignum_mul_add(value, base, idx)

	# Convert big number back to bytes
	var result: PackedByteArray = PackedByteArray()
	result.resize(expected_size)
	for i in range(expected_size - 1, -1, -1):
		var divmod: Dictionary = _bignum_divmod(value, 256)
		result[i] = divmod["remainder"]
		value = divmod["quotient"]

	return result


# --- Generate / Decode Full Room Code ---

static func generate_room_code(ip: String, port: int) -> Dictionary:
	# Returns {code: String, session_key: PackedByteArray}
	var session_key: PackedByteArray = generate_session_key()
	var encrypted: PackedByteArray = encrypt_room_data(ip, port, session_key)
	if encrypted.is_empty():
		return {"code": "ERROR", "session_key": PackedByteArray()}

	# Combine key + encrypted: [32B key][48B IV+cipher+tag] = 80 bytes
	var combined: PackedByteArray = PackedByteArray()
	combined.append_array(session_key)
	combined.append_array(encrypted)

	var code: String = bytes_to_code(combined)
	return {"code": code, "session_key": session_key}


static func decode_room_code(code: String) -> Dictionary:
	# Returns {ip, port, session_key, valid}
	var combined: PackedByteArray = code_to_bytes(code, 80)
	if combined.size() != 80:
		return {"ip": "", "port": 0, "session_key": PackedByteArray(), "valid": false}

	var session_key: PackedByteArray = combined.slice(0, 32)
	var encrypted: PackedByteArray = combined.slice(32, 80)
	var decrypted: Dictionary = decrypt_room_data(encrypted, session_key)
	decrypted["session_key"] = session_key
	return decrypted


# --- CRC32 for Packet Integrity ---

static func crc32(data: PackedByteArray) -> int:
	var crc: int = 0xFFFFFFFF
	for b in data:
		crc = crc ^ b
		for _j in range(8):
			if crc & 1:
				crc = (crc >> 1) ^ 0xEDB88320
			else:
				crc = crc >> 1
	return crc ^ 0xFFFFFFFF


static func append_crc32(data: PackedByteArray) -> PackedByteArray:
	var crc: int = crc32(data)
	var result: PackedByteArray = data.duplicate()
	var crc_bytes: PackedByteArray = PackedByteArray()
	crc_bytes.resize(4)
	crc_bytes.encode_u32(0, crc)
	result.append_array(crc_bytes)
	return result


static func verify_crc32(data: PackedByteArray) -> bool:
	if data.size() < 5:
		return false
	var payload: PackedByteArray = data.slice(0, data.size() - 4)
	var received_crc: int = data.decode_u32(data.size() - 4)
	return crc32(payload) == received_crc


static func strip_crc32(data: PackedByteArray) -> PackedByteArray:
	if data.size() < 5:
		return data
	return data.slice(0, data.size() - 4)


# --- HMAC-SHA256 for Auth ---

static func hmac_sha256(key: PackedByteArray, message: PackedByteArray) -> PackedByteArray:
	var block_size: int = 64  # SHA-256 block size

	# If key is longer than block size, hash it
	if key.size() > block_size:
		var ctx: HashingContext = HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(key)
		key = ctx.finish()

	# Pad key to block size
	var padded_key: PackedByteArray = key.duplicate()
	padded_key.resize(block_size)

	# Inner and outer padding
	var i_pad: PackedByteArray = PackedByteArray()
	var o_pad: PackedByteArray = PackedByteArray()
	i_pad.resize(block_size)
	o_pad.resize(block_size)
	for i in range(block_size):
		i_pad[i] = padded_key[i] ^ 0x36
		o_pad[i] = padded_key[i] ^ 0x5C

	# Inner hash: SHA256(i_pad + message)
	var inner_ctx: HashingContext = HashingContext.new()
	inner_ctx.start(HashingContext.HASH_SHA256)
	inner_ctx.update(i_pad)
	inner_ctx.update(message)
	var inner_hash: PackedByteArray = inner_ctx.finish()

	# Outer hash: SHA256(o_pad + inner_hash)
	var outer_ctx: HashingContext = HashingContext.new()
	outer_ctx.start(HashingContext.HASH_SHA256)
	outer_ctx.update(o_pad)
	outer_ctx.update(inner_hash)
	return outer_ctx.finish()


static func generate_nonce() -> PackedByteArray:
	var crypto: Crypto = Crypto.new()
	return crypto.generate_random_bytes(32)


# --- HMAC-based Packet Signing (replaces CRC32 for authenticated integrity) ---

static func sign_packet(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	# Append truncated HMAC-SHA256 (8 bytes) for authenticated integrity
	var mac: PackedByteArray = hmac_sha256(key, data)
	var result: PackedByteArray = data.duplicate()
	result.append_array(mac.slice(0, 8))  # Truncated to 8 bytes (64-bit security)
	return result


static func verify_packet(data: PackedByteArray, key: PackedByteArray) -> bool:
	if data.size() < 9:  # At least 1 byte payload + 8 bytes MAC
		return false
	var payload: PackedByteArray = data.slice(0, data.size() - 8)
	var received_mac: PackedByteArray = data.slice(data.size() - 8)
	var expected_mac: PackedByteArray = hmac_sha256(key, payload).slice(0, 8)
	# Constant-time comparison
	var diff: int = 0
	for i in range(8):
		diff = diff | (received_mac[i] ^ expected_mac[i])
	return diff == 0


static func strip_mac(data: PackedByteArray) -> PackedByteArray:
	if data.size() < 9:
		return data
	return data.slice(0, data.size() - 8)


# --- Big Number Helpers (for base conversion of 32-byte values) ---

static func _bignum_mul_add(num: Array, mul: int, add: int) -> Array:
	var carry: int = add
	for i in range(num.size() - 1, -1, -1):
		var val: int = num[i] * mul + carry
		num[i] = val & 0xFFFFFFFF
		carry = val >> 32
	while carry > 0:
		num.push_front(carry & 0xFFFFFFFF)
		carry = carry >> 32
	return num


static func _bignum_divmod(num: Array, divisor: int) -> Dictionary:
	var quotient: Array = []
	var remainder: int = 0
	for i in range(num.size()):
		var val: int = (remainder << 32) | num[i]
		quotient.append(val / divisor)
		remainder = val % divisor
	# Strip leading zeros
	while quotient.size() > 1 and quotient[0] == 0:
		quotient.pop_front()
	return {"quotient": quotient, "remainder": remainder}


static func _bignum_is_zero(num: Array) -> bool:
	for v in num:
		if v != 0:
			return false
	return true
