static func bytes_from_hex(s: String) -> PackedByteArray:
	var clean = s.replace("0x", "").replace("0X", "").strip_edges()
	if clean.length() % 2 == 1:
		clean = "0" + clean
	var arr = PackedByteArray()
	arr.resize(clean.length() / 2)
	for i in arr.size():
		arr[i] = clean.substr(i * 2, 2).hex_to_int()
	return arr

static func hex_from_bytes(arr: PackedByteArray) -> String:
	return arr.hex_encode()

const LIMB_BITS = 16
const LIMB_MASK = 0xFFFF
const LIMBS_256 = 16

const P_HEX = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F"
const N_HEX = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"

static var _p: PackedInt64Array
static var _n: PackedInt64Array
static var _gx: PackedInt64Array
static var _gy: PackedInt64Array
static var _p_shift_val: PackedInt64Array
static var _p_plus_1_over_4: PackedInt64Array
static var _initialized = false

static func _ensure_init():
	if _initialized:
		return
	_p = _limbs_from_hex(P_HEX)
	_n = _limbs_from_hex(N_HEX)
	_gx = _limbs_from_hex("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")
	_gy = _limbs_from_hex("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")
	_p_shift_val = _limbs_from_int(4294968273)
	_p_plus_1_over_4 = _shr(_add(_p, _limbs_from_int(1)), 2)
	_initialized = true

static func _trim(limbs: PackedInt64Array) -> PackedInt64Array:
	if limbs.size() == 0:
		return PackedInt64Array([0])
	var i = limbs.size() - 1
	while i > 0 and limbs[i] == 0:
		i -= 1
	return limbs.slice(0, i + 1)

static func _limbs_from_int(n: int) -> PackedInt64Array:
	if n == 0:
		return PackedInt64Array([0])
	var arr = PackedInt64Array()
	var v = abs(n)
	while v > 0:
		arr.append(v & LIMB_MASK)
		v >>= LIMB_BITS
	return arr

static func _limbs_from_hex(s: String) -> PackedInt64Array:
	var clean = s.replace("0x", "").replace("0X", "").strip_edges()
	if clean.is_empty():
		return PackedInt64Array([0])
	var hex_len = clean.length()
	var total_bits = hex_len * 4
	var num_limbs = max(1, int(ceil(float(total_bits) / LIMB_BITS)))
	var arr = PackedInt64Array()
	arr.resize(num_limbs)
	arr.fill(0)
	for i in range(hex_len):
		var digit = clean[hex_len - 1 - i].hex_to_int()
		var limb_i = (i * 4) / LIMB_BITS
		var bit_off = (i * 4) % LIMB_BITS
		arr[limb_i] |= (digit << bit_off)
	return _trim(arr)

const HEX_CHARS = "0123456789abcdef"

static func _limbs_to_hex(limbs: PackedInt64Array) -> String:
	var t = _trim(limbs)
	if t.size() == 0:
		return "00"
	var total_bits = t.size() * LIMB_BITS
	var hex_len = int(ceil(float(total_bits) / 4))
	var s = ""
	for pos in range(hex_len - 1, -1, -1):
		var bit_pos = pos * 4
		var limb_i = bit_pos / LIMB_BITS
		var bit_off = bit_pos % LIMB_BITS
		s += HEX_CHARS[(t[limb_i] >> bit_off) & 0xF]
	return s

static func _cmp(a: PackedInt64Array, b: PackedInt64Array) -> int:
	var at = _trim(a); var bt = _trim(b)
	if at.size() != bt.size():
		return 1 if at.size() > bt.size() else -1
	for i in range(at.size() - 1, -1, -1):
		if at[i] != bt[i]:
			return 1 if at[i] > bt[i] else -1
	return 0

static func _add(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var ml = max(a.size(), b.size())
	var r = PackedInt64Array()
	var c: int = 0
	for i in range(ml):
		var s = (a[i] if i < a.size() else 0) + (b[i] if i < b.size() else 0) + c
		r.append(s & LIMB_MASK)
		c = s >> LIMB_BITS
	while c > 0:
		r.append(c & LIMB_MASK)
		c >>= LIMB_BITS
	return _trim(r)

static func _sub(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var r = PackedInt64Array()
	r.resize(a.size())
	r.fill(0)
	var br: int = 0
	for i in range(a.size()):
		var d = a[i] - (b[i] if i < b.size() else 0) - br
		if d < 0:
			d += (1 << LIMB_BITS)
			br = 1
		else:
			br = 0
		r[i] = d
	return _trim(r)

static func _mul(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var r = PackedInt64Array()
	r.resize(a.size() + b.size())
	r.fill(0)
	for i in range(a.size()):
		if a[i] == 0:
			continue
		var c: int = 0
		for j in range(b.size()):
			var s = r[i + j] + a[i] * b[j] + c
			r[i + j] = s & LIMB_MASK
			c = s >> LIMB_BITS
		if c > 0:
			r[i + b.size()] = (r[i + b.size()] + c) & LIMB_MASK
	return _trim(r)

static func _shr(limbs: PackedInt64Array, bits: int) -> PackedInt64Array:
	var t = _trim(limbs)
	if t.size() == 0:
		return PackedInt64Array([0])
	var ls = bits / LIMB_BITS
	var bs = bits % LIMB_BITS
	if ls >= t.size():
		return PackedInt64Array([0])
	var src = t.slice(ls)
	var r = PackedInt64Array()
	r.resize(src.size())
	r.fill(0)
	for i in range(src.size() - 1):
		r[i] = (src[i] >> bs) | ((src[i + 1] & ((1 << bs) - 1)) << (LIMB_BITS - bs))
	r[src.size() - 1] = src[src.size() - 1] >> bs
	return _trim(r)

static func _shl(limbs: PackedInt64Array, bits: int) -> PackedInt64Array:
	var t = _trim(limbs)
	var ls = bits / LIMB_BITS
	var bs = bits % LIMB_BITS
	var r = PackedInt64Array()
	r.resize(t.size() + ls + 1)
	r.fill(0)
	for i in range(t.size() - 1):
		r[i + ls] = ((t[i] << bs) | (t[i + 1] >> (LIMB_BITS - bs))) & LIMB_MASK
	var top = t[t.size() - 1] << bs
	var top_idx = t.size() - 1 + ls
	r[top_idx] = top & LIMB_MASK
	if top >> LIMB_BITS != 0:
		r[top_idx + 1] = top >> LIMB_BITS
	return _trim(r)

static func _is_zero(limbs: PackedInt64Array) -> bool:
	for v in limbs:
		if v != 0:
			return false
	return true

static func _reduce_p(x: PackedInt64Array) -> PackedInt64Array:
	_ensure_init()
	var t = _trim(x)
	while t.size() > LIMBS_256 or _cmp(t, _p) >= 0:
		if t.size() <= LIMBS_256:
			t = _sub(t, _p)
			continue
		var low = t.slice(0, LIMBS_256)
		var high = t.slice(LIMBS_256)
		if _is_zero(high):
			t = low
			continue
		t = _add(low, _mul(high, _p_shift_val))
	return t

static func _reduce_n(x: PackedInt64Array) -> PackedInt64Array:
	_ensure_init()
	var t = _trim(x)
	var n_bits = _n.size() * LIMB_BITS
	while _cmp(t, _n) >= 0:
		if t.size() <= _n.size() + 1:
			t = _sub(t, _n)
		else:
			var shift = (t.size() - _n.size()) * LIMB_BITS
			var shifted = _shl(_n, shift)
			if _cmp(shifted, t) > 0:
				shift -= LIMB_BITS
				shifted = _shl(_n, shift)
			t = _sub(t, shifted)
	return t

static func _mod_mul(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	return _reduce_p(_mul(a, b))

static func _mod_sqr(a: PackedInt64Array) -> PackedInt64Array:
	return _mod_mul(a, a)

static func _mod_pow(base: PackedInt64Array, exp: PackedInt64Array) -> PackedInt64Array:
	_ensure_init()
	var r = _limbs_from_int(1)
	var b = _trim(base)
	var e = _trim(exp)
	while _cmp(e, _limbs_from_int(0)) > 0:
		if e[0] & 1:
			r = _mod_mul(r, b)
		b = _mod_sqr(b)
		e = _shr(e, 1)
	return r

static func _mod_inv(x: PackedInt64Array) -> PackedInt64Array:
	_ensure_init()
	return _mod_pow(x, _sub(_p, _limbs_from_int(2)))

static func _jac_double(p: Dictionary) -> Dictionary:
	var z = _trim(p.z)
	if z.size() == 1 and z[0] == 0:
		return p
	var x = p.x; var y = p.y
	var t = _mod_mul(_limbs_from_int(3), _mod_sqr(x))
	var yy = _mod_sqr(y)
	var yyyy = _mod_sqr(yy)
	var s = _mod_mul(_limbs_from_int(4), _mod_mul(x, yy))
	var nx = _sub(_mod_sqr(t), _mod_mul(_limbs_from_int(2), s))
	var ny = _sub(_mod_mul(t, _sub(s, nx)), _mod_mul(_limbs_from_int(8), yyyy))
	var nz = _mod_mul(_limbs_from_int(2), _mod_mul(y, z))
	return {"x": nx, "y": ny, "z": nz}

static func _jac_add(p1: Dictionary, p2: Dictionary) -> Dictionary:
	var z1t = _trim(p1.z)
	var z2t = _trim(p2.z)
	if z1t.size() == 1 and z1t[0] == 0:
		return p2
	if z2t.size() == 1 and z2t[0] == 0:
		return p1
	var x1 = p1.x; var y1 = p1.y; var z1 = p1.z
	var x2 = p2.x; var y2 = p2.y; var z2 = p2.z
	var z1z1 = _mod_sqr(z1); var z2z2 = _mod_sqr(z2)
	var u1 = _mod_mul(x1, z2z2); var u2 = _mod_mul(x2, z1z1)
	var s1 = _mod_mul(_mod_mul(y1, z2), z2z2)
	var s2 = _mod_mul(_mod_mul(y2, z1), z1z1)
	if _cmp(u1, u2) == 0:
		if _cmp(s1, s2) != 0:
			return {"x": _limbs_from_int(0), "y": _limbs_from_int(1), "z": _limbs_from_int(0)}
		return _jac_double(p1)
	var h = _sub(u2, u1); var r = _sub(s2, s1)
	var h2 = _mod_sqr(h); var h3 = _mod_mul(h, h2)
	var u1h2 = _mod_mul(u1, h2)
	var nx = _sub(_sub(_mod_sqr(r), h3), _mod_mul(_limbs_from_int(2), u1h2))
	var ny = _sub(_mod_mul(r, _sub(u1h2, nx)), _mod_mul(s1, h3))
	var nz = _mod_mul(h, _mod_mul(z1, z2))
	return {"x": nx, "y": ny, "z": nz}

static func _jac_affine(p: Dictionary) -> Dictionary:
	var z = _trim(p.z)
	if z.size() == 1 and z[0] == 0:
		return {"x": _limbs_from_int(0), "y": _limbs_from_int(0)}
	var zi = _mod_inv(z)
	var zi2 = _mod_sqr(zi)
	return {"x": _mod_mul(p.x, zi2), "y": _mod_mul(p.y, _mod_mul(zi, zi2))}

static func _scalar_mult(k: PackedInt64Array, px: PackedInt64Array, py: PackedInt64Array) -> Dictionary:
	_ensure_init()
	var kn = _reduce_n(k)
	var r = {"x": _limbs_from_int(0), "y": _limbs_from_int(1), "z": _limbs_from_int(0)}
	var add = {"x": px, "y": py, "z": _limbs_from_int(1)}
	var kb = _trim(kn)
	var tb = kb.size() * LIMB_BITS
	var msb = -1
	for bit in range(tb - 1, -1, -1):
		var li = bit / LIMB_BITS
		var bo = bit % LIMB_BITS
		if li < kb.size() and ((kb[li] >> bo) & 1):
			msb = bit
			break
	if msb < 0:
		return {"x": _limbs_from_int(0), "y": _limbs_from_int(0)}
	for bit in range(msb, -1, -1):
		r = _jac_double(r)
		var li = bit / LIMB_BITS
		var bo = bit % LIMB_BITS
		if li < kb.size() and ((kb[li] >> bo) & 1):
			r = _jac_add(r, add)
	return _jac_affine(r)

static func _bytes_to_limbs(b: PackedByteArray) -> PackedInt64Array:
	return _limbs_from_hex(b.hex_encode())

static func _limbs_to_32b(l: PackedInt64Array) -> PackedByteArray:
	var h = _limbs_to_hex(l)
	while h.length() < 64:
		h = "0" + h
	if h.length() > 64:
		h = h.substr(h.length() - 64)
	return bytes_from_hex(h)

static func _tagged_hash(tag: String, msg: PackedByteArray) -> PackedByteArray:
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(tag.to_utf8_buffer())
	var tag_h = ctx.finish()
	ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(tag_h)
	ctx.update(tag_h)
	ctx.update(msg)
	return ctx.finish()

static var _crypto: Variant
static var _WebBridge = preload("nostr_crypto_web_bridge.gd")

static func _get_crypto() -> Variant:
	if _crypto != null:
		return _crypto if _crypto else null
	if Engine.has_singleton("NostrCrypto"):
		_crypto = Engine.get_singleton("NostrCrypto")
		return _crypto
	if OS.has_feature("web"):
		_WebBridge.inject()
		if _WebBridge.is_ready():
			_crypto = _WebBridge.new()
			return _crypto
		return null
	_crypto = false
	return null

static func schnorr_sign(private_key_hex: String, message: PackedByteArray) -> PackedByteArray:
	var crypto = _get_crypto()
	if crypto:
		return crypto.schnorr_sign(private_key_hex, message)
	_ensure_init()
	var d = _limbs_from_hex(private_key_hex)
	if _cmp(d, _limbs_from_int(0)) == 0 or _cmp(d, _n) >= 0:
		return PackedByteArray()
	var pub = _scalar_mult(d, _gx, _gy)
	var pxb = _limbs_to_32b(pub.x); var pyb = _limbs_to_32b(pub.y)
	if pyb[31] & 1:
		d = _sub(_n, d)
		pub = _scalar_mult(d, _gx, _gy)
		pxb = _limbs_to_32b(pub.x)
	var aux = PackedByteArray()
	aux.resize(32); aux.fill(0)
	var t = _tagged_hash("BIP340/aux", aux)
	var d_bytes = bytes_from_hex(private_key_hex)
	for i in 32:
		t[i] ^= d_bytes[i]
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(t)
	var k_bytes = ctx.finish()
	ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("BIP340/nonce".to_utf8_buffer())
	var nonce_tag = ctx.finish()
	ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(nonce_tag)
	ctx.update(nonce_tag)
	ctx.update(_limbs_to_32b(d))
	ctx.update(pxb)
	ctx.update(message)
	k_bytes = ctx.finish()
	var k = _reduce_n(_bytes_to_limbs(k_bytes))
	if _cmp(k, _limbs_from_int(0)) == 0:
		return PackedByteArray()
	var R = _scalar_mult(k, _gx, _gy)
	var rxb = _limbs_to_32b(R.x); var ryb = _limbs_to_32b(R.y)
	if ryb[31] & 1:
		k = _sub(_n, k)
		R = _scalar_mult(k, _gx, _gy)
		rxb = _limbs_to_32b(R.x)
	var challenge = _tagged_hash("BIP340/challenge", rxb + pxb + message)
	var e = _reduce_n(_bytes_to_limbs(challenge))
	var s_val = _add(k, _reduce_n(_mul(e, d)))
	s_val = _reduce_n(s_val)
	var sig = rxb + _limbs_to_32b(s_val)
	return sig

static func schnorr_sign_raw(private_key: PackedByteArray, message: PackedByteArray) -> PackedByteArray:
	var crypto = _get_crypto()
	if crypto:
		return crypto.schnorr_sign_raw(private_key, message)
	return schnorr_sign(private_key.hex_encode(), message)

static func ecb(private_key_hex: String, pubkey_hex: String) -> PackedByteArray:
	var crypto = _get_crypto()
	if crypto:
		return crypto.ecdh(private_key_hex, pubkey_hex)
	_ensure_init()
	var d = _limbs_from_hex(private_key_hex)
	var px = _limbs_from_hex(pubkey_hex)
	var t1 = _mod_sqr(px)
	var t2 = _mod_mul(t1, px)
	t2 = _add(t2, _limbs_from_int(7))
	t2 = _reduce_p(t2)
	var py = _mod_pow(t2, _p_plus_1_over_4)
	var pt = _scalar_mult(d, px, py)
	return _limbs_to_32b(pt.x)

static func nip04_encrypt(private_key_hex: String, pubkey_hex: String, plaintext: String) -> String:
	var shared = ecb(private_key_hex, pubkey_hex)
	var key = shared.slice(0, 32)
	var iv = PackedByteArray()
	iv.resize(16)
	for i in 16:
		iv[i] = randi() % 256
	var pt = plaintext.to_utf8_buffer()
	var pad_len = 16 - (pt.size() % 16)
	pt.resize(pt.size() + pad_len)
	for i in range(pt.size() - pad_len, pt.size()):
		pt[i] = pad_len
	var enc = _aes_cbc_encrypt(key, iv, pt)
	return Marshalls.raw_to_base64(enc) + "?iv=" + Marshalls.raw_to_base64(iv)


static func nip04_decrypt(private_key_hex: String, pubkey_hex: String, payload: String) -> String:
	var parts = payload.split("?iv=")
	if parts.size() != 2:
		return payload
	var shared = ecb(private_key_hex, pubkey_hex)
	var key = shared.slice(0, 32)
	var iv = Marshalls.base64_to_raw(parts[1])
	var enc = Marshalls.base64_to_raw(parts[0])
	if iv.size() != 16 or enc.size() == 0 or enc.size() % 16 != 0:
		return payload
	var dec = _aes_cbc_decrypt(key, iv, enc)
	if dec.is_empty():
		return payload
	var pad_len = dec[dec.size() - 1]
	if pad_len < 1 or pad_len > 16:
		return ""
	var dec_bytes = dec.slice(0, dec.size() - pad_len)
	var dec_str = dec_bytes.get_string_from_utf8()
	if "\ufffd" in dec_str:
		return ""
	return dec_str


const _S: PackedByteArray = [
	0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
	0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
	0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
	0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
	0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
	0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
	0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
	0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
	0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
	0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
	0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
	0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
	0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
	0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
	0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
	0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
]

const _SI: PackedByteArray = [
	0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
	0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
	0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
	0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
	0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
	0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
	0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
	0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
	0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
	0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
	0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
	0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
	0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
	0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
	0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
	0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d
]

const _Rcon: PackedByteArray = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d]


static func _aes_key_expand(key: PackedByteArray) -> PackedByteArray:
	var w = PackedByteArray()
	w.resize(240)
	for i in 32:
		w[i] = key[i]
	for i in range(8, 60):
		var wi = i * 4
		var wim1 = (i - 1) * 4
		var wim8 = (i - 8) * 4
		var temp = PackedByteArray()
		temp.resize(4)
		for j in 4:
			temp[j] = w[wim1 + j]
		if i % 8 == 0:
			var t0 = temp[0]; temp[0] = temp[1]; temp[1] = temp[2]; temp[2] = temp[3]; temp[3] = t0
			for j in 4:
				temp[j] = _S[temp[j]]
			temp[0] ^= _Rcon[i / 8 - 1]
		elif i % 8 == 4:
			for j in 4:
				temp[j] = _S[temp[j]]
		for j in 4:
			w[wi + j] = w[wim8 + j] ^ temp[j]
	return w


static func _aes_encrypt_block(block: PackedByteArray, w: PackedByteArray) -> PackedByteArray:
	var s = PackedByteArray()
	s.resize(16)
	for i in 16:
		s[i] = block[i] ^ w[i]
	for r in range(1, 14):
		for i in 16:
			s[i] = _S[s[i]]
		var t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t
		t = s[2]; s[2] = s[10]; s[10] = t
		t = s[6]; s[6] = s[14]; s[14] = t
		t = s[3]; s[3] = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = t
		for c in 4:
			var i0 = c * 4; var i1 = i0 + 1; var i2 = i0 + 2; var i3 = i0 + 3
			var a = s[i0]; var b = s[i1]; var c_ = s[i2]; var d = s[i3]
			s[i0] = _gmul(a, 2) ^ _gmul(b, 3) ^ c_ ^ d
			s[i1] = a ^ _gmul(b, 2) ^ _gmul(c_, 3) ^ d
			s[i2] = a ^ b ^ _gmul(c_, 2) ^ _gmul(d, 3)
			s[i3] = _gmul(a, 3) ^ b ^ c_ ^ _gmul(d, 2)
		for i in 16:
			s[i] ^= w[r * 16 + i]
	for i in 16:
		s[i] = _S[s[i]]
	var t2 = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t2
	t2 = s[2]; s[2] = s[10]; s[10] = t2
	t2 = s[6]; s[6] = s[14]; s[14] = t2
	t2 = s[3]; s[3] = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = t2
	for i in 16:
		s[i] ^= w[14 * 16 + i]
	return s


static func _aes_decrypt_block(block: PackedByteArray, w: PackedByteArray) -> PackedByteArray:
	var s = PackedByteArray()
	s.resize(16)
	for i in 16:
		s[i] = block[i] ^ w[14 * 16 + i]
	for r in range(13, 0, -1):
		var t = s[1]; s[1] = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = t
		t = s[2]; s[2] = s[10]; s[10] = t
		t = s[6]; s[6] = s[14]; s[14] = t
		t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t
		for i in 16:
			s[i] = _SI[s[i]]
		for i in 16:
			s[i] ^= w[r * 16 + i]
		for c in 4:
			var i0 = c * 4; var i1 = i0 + 1; var i2 = i0 + 2; var i3 = i0 + 3
			var a = s[i0]; var b = s[i1]; var c_ = s[i2]; var d = s[i3]
			s[i0] = _gmul(a, 14) ^ _gmul(b, 11) ^ _gmul(c_, 13) ^ _gmul(d, 9)
			s[i1] = _gmul(a, 9) ^ _gmul(b, 14) ^ _gmul(c_, 11) ^ _gmul(d, 13)
			s[i2] = _gmul(a, 13) ^ _gmul(b, 9) ^ _gmul(c_, 14) ^ _gmul(d, 11)
			s[i3] = _gmul(a, 11) ^ _gmul(b, 13) ^ _gmul(c_, 9) ^ _gmul(d, 14)
	var t3 = s[1]; s[1] = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = t3
	t3 = s[2]; s[2] = s[10]; s[10] = t3
	t3 = s[6]; s[6] = s[14]; s[14] = t3
	t3 = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t3
	for i in 16:
		s[i] = _SI[s[i]]
	for i in 16:
		s[i] ^= w[i]
	return s


static func _gmul(a: int, b: int) -> int:
	var r := 0
	var x := a
	for _i in 8:
		if b & 1:
			r ^= x
		var hi := x & 0x80
		x = (x << 1) & 0xff
		if hi:
			x ^= 0x1b
		b >>= 1
	return r


static func _aes_cbc_encrypt(key: PackedByteArray, iv: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var w = _aes_key_expand(key)
	var out = PackedByteArray()
	out.resize(data.size())
	var prev = iv
	var n = data.size() / 16
	for b in range(n):
		var block = PackedByteArray()
		block.resize(16)
		for i in 16:
			block[i] = data[b * 16 + i] ^ prev[i]
		var enc = _aes_encrypt_block(block, w)
		for i in 16:
			out[b * 16 + i] = enc[i]
		prev = enc
	return out


static func _aes_cbc_decrypt(key: PackedByteArray, iv: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var w = _aes_key_expand(key)
	var out = PackedByteArray()
	out.resize(data.size())
	var n = data.size() / 16
	for b in range(n):
		var block = data.slice(b * 16, (b + 1) * 16)
		var dec = _aes_decrypt_block(block, w)
		var prev = iv if b == 0 else data.slice((b - 1) * 16, b * 16)
		for i in 16:
			out[b * 16 + i] = dec[i] ^ prev[i]
	return out

static func derive_pubkey(private_key_hex: String) -> String:
	var crypto = _get_crypto()
	if crypto:
		return crypto.derive_pubkey(private_key_hex)
	_ensure_init()
	var d = _limbs_from_hex(private_key_hex)
	var pub = _scalar_mult(d, _gx, _gy)
	return _limbs_to_32b(pub.x).hex_encode()

static func compute_event_id(event: Dictionary) -> String:
	var serial = [0, event["pubkey"], event.get("created_at", 0), event.get("kind", 1), event.get("tags", []), event.get("content", "")]
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(JSON.new().stringify(serial).to_utf8_buffer())
	return ctx.finish().hex_encode()

static func sign_event(private_key_hex: String, event: Dictionary) -> Dictionary:
	var pubkey = derive_pubkey(private_key_hex)
	event["pubkey"] = pubkey
	event["id"] = compute_event_id(event)
	var sig = schnorr_sign(private_key_hex, bytes_from_hex(event["id"]))
	event["sig"] = sig.hex_encode()
	return event

static func bech32_encode(hrp: String, data: PackedByteArray) -> String:
	var B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
	var conv = _conv_bits(data, 8, 5, true)
	var ck = _bech32_checksum(hrp, conv)
	var r = hrp + "1"
	for v in conv:
		r += B32[v]
	for v in ck:
		r += B32[v]
	return r

static func bech32_decode(hrp: String, encoded: String) -> PackedByteArray:
	var parts = encoded.split("1")
	if parts.size() != 2 or parts[0] != hrp:
		return PackedByteArray()
	var B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
	var data = PackedByteArray()
	for c in parts[1]:
		var idx = B32.find(c)
		if idx == -1:
			return PackedByteArray()
		data.append(idx)
	if data.size() < 6:
		return PackedByteArray()
	var ck = data.slice(data.size() - 6)
	data = data.slice(0, data.size() - 6)
	var exp = _bech32_checksum(hrp, data)
	for i in 6:
		if ck[i] != exp[i]:
			return PackedByteArray()
	return _conv_bits(data, 5, 8, false)

static func _conv_bits(data: PackedByteArray, from: int, to: int, pad: bool) -> PackedByteArray:
	var acc: int = 0; var bits: int = 0; var r = PackedByteArray()
	var mv = (1 << to) - 1
	for v in data:
		acc = (acc << from) | v; bits += from
		while bits >= to:
			bits -= to; r.append((acc >> bits) & mv)
	if pad and bits > 0:
		r.append((acc << (to - bits)) & mv)
	elif not pad and bits >= from:
		return PackedByteArray()
	elif bits > 0 and (acc & ((1 << bits) - 1)) != 0:
		return PackedByteArray()
	return r

static func _bech32_checksum(hrp: String, data: PackedByteArray) -> PackedByteArray:
	var GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
	var exp = PackedByteArray()
	for c in hrp:
		exp.append(c.unicode_at(0) >> 5)
	exp.append(0)
	for c in hrp:
		exp.append(c.unicode_at(0) & 31)
	var comb = PackedByteArray()
	comb.append_array(exp); comb.append_array(data)
	for _i in 6:
		comb.append(0)
	var chk = _bech32_poly(comb) ^ 1
	var r = PackedByteArray()
	for i in 6:
		r.append((chk >> (5 * (5 - i))) & 31)
	return r

static func _bech32_poly(values: PackedByteArray) -> int:
	var GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
	var chk: int = 1
	for v in values:
		var top = chk >> 25
		chk = ((chk & 0x1FFFFFF) << 5) ^ v
		for i in 5:
			if (top >> i) & 1:
				chk ^= GEN[i]
	return chk

static func npub_encode(pubkey_hex: String) -> String:
	return bech32_encode("npub", bytes_from_hex(pubkey_hex))

static func npub_decode(npub: String) -> String:
	var data = bech32_decode("npub", npub)
	if data.size() != 32:
		return ""
	return data.hex_encode()

static func nsec_encode(private_key_hex: String) -> String:
	return bech32_encode("nsec", bytes_from_hex(private_key_hex))

static func nsec_decode(nsec: String) -> String:
	var data = bech32_decode("nsec", nsec)
	if data.size() != 32:
		return ""
	return data.hex_encode()

static func nwc_try_decrypt(private_key_hex: String, pubkey_hex: String, payload: String) -> String:
	var parts = payload.split("?iv=")
	if parts.size() != 2:
		return payload
	var iv = Marshalls.base64_to_raw(parts[1])
	var enc = Marshalls.base64_to_raw(parts[0])
	if iv.size() != 16 or enc.size() == 0 or enc.size() % 16 != 0:
		return payload
	var shared_x = ecb(private_key_hex, pubkey_hex)
	var keys = [shared_x]
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var c02 = PackedByteArray()
	c02.resize(33)
	c02[0] = 0x02
	for i in 32:
		c02[1 + i] = shared_x[i]
	ctx.update(c02)
	keys.append(ctx.finish())
	ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var c03 = PackedByteArray()
	c03.resize(33)
	c03[0] = 0x03
	for i in 32:
		c03[1 + i] = shared_x[i]
	ctx.update(c03)
	keys.append(ctx.finish())
	var labels = ["raw_x", "sha256(02||x)", "sha256(03||x)"]
	for ki in keys.size():
		var dec = _aes_cbc_decrypt(keys[ki], iv, enc)
		if dec.is_empty() or dec.size() == 0:
			continue
		var pad_len = dec[dec.size() - 1]
		if pad_len < 1 or pad_len > 16:
			continue
		var valid_pad = true
		for i in range(dec.size() - pad_len, dec.size()):
			if dec[i] != pad_len:
				valid_pad = false
				break
		if not valid_pad:
			continue
		var text = dec.slice(0, dec.size() - pad_len).get_string_from_utf8()
		if not text.is_empty():
			print("NostrGD/NWC: decrypt OK using ", labels[ki], " key=", keys[ki].hex_encode().left(16))
			return text
	print("NostrGD/NWC: all 3 decryption attempts failed")
	print("  raw_x=", shared_x.hex_encode().left(16))
	return ""
