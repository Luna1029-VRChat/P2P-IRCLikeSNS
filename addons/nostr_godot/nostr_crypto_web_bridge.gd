# JavaScript bridge for Nostr secp256k1 crypto on Web exports.
# Matches the GDExtension NostrCrypto singleton API.
# Uses @noble/secp256k1 loaded from CDN for sub-ms performance.

const NOBLE_CDN := "https://cdn.jsdelivr.net/npm/@noble/secp256k1@2.1.0/umd/index.min.js"
static var _injected := false

static func is_ready() -> bool:
	return JavaScriptBridge.eval("typeof window.NostrCryptoJS") == "object"

static func inject() -> void:
	if _injected:
		if is_ready():
			return
		_injected = false
	_injected = true
	var js := "(function(){"
	js += "if(window.NostrCryptoJS)return;"
	js += "var s=document.createElement('script');"
	js += "s.src='" + NOBLE_CDN + "';"
	js += "s.onload=function(){"
	js += "window.NostrCryptoJS={"
	js += "generatePrivateKey:function(){return window.secp256k1.utils.randomPrivateKeyHex();},"
	js += "derivePubkey:function(h){return window.secp256k1.schnorr.getPublicKey(h);},"
	js += "schnorrSign:function(m,p){return window.secp256k1.schnorr.sign(m,p);},"
	js += "schnorrSignRaw:function(k,m){return window.secp256k1.schnorr.sign(window.secp256k1.utils.bytesToHex(k),window.secp256k1.utils.bytesToHex(m));},"
	js += "ecdh:function(priv,pub){var pt=window.secp256k1.Point.fromHex(pub);var sp=pt.multiply(window.secp256k1.utils.hexToBytes(priv));return window.secp256k1.utils.bytesToHex(sp.x);}"
	js += "};};"
	js += "document.head.appendChild(s);"
	js += "})();"
	JavaScriptBridge.eval(js)

func derive_pubkey(private_key_hex: String) -> String:
	if not is_ready():
		return ""
	return JavaScriptBridge.eval("window.NostrCryptoJS.derivePubkey('" + private_key_hex + "')")

func schnorr_sign(private_key_hex: String, message: PackedByteArray) -> PackedByteArray:
	if not is_ready() or message.size() != 32:
		return PackedByteArray()
	var msg_hex := _hex(message)
	var sig_hex := JavaScriptBridge.eval("window.NostrCryptoJS.schnorrSign('" + msg_hex + "','" + private_key_hex + "')")
	if typeof(sig_hex) != TYPE_STRING:
		return PackedByteArray()
	return _hex_to_bytes(sig_hex as String)

func schnorr_sign_raw(private_key: PackedByteArray, message: PackedByteArray) -> PackedByteArray:
	if not is_ready() or private_key.size() != 32 or message.size() != 32:
		return PackedByteArray()
	var key_hex := _hex(private_key)
	var msg_hex := _hex(message)
	var sig_hex := JavaScriptBridge.eval("window.NostrCryptoJS.schnorrSignRaw('" + key_hex + "','" + msg_hex + "')")
	if typeof(sig_hex) != TYPE_STRING:
		return PackedByteArray()
	return _hex_to_bytes(sig_hex as String)

func ecdh(private_key_hex: String, pubkey_hex: String) -> PackedByteArray:
	if not is_ready():
		return PackedByteArray()
	var result = JavaScriptBridge.eval("window.NostrCryptoJS.ecdh('" + private_key_hex + "','" + pubkey_hex + "')")
	if not (result is String):
		return PackedByteArray()
	return _hex_to_bytes(result as String)

func generate_private_key() -> String:
	if not is_ready():
		return ""
	return JavaScriptBridge.eval("window.NostrCryptoJS.generatePrivateKey()")

static func _hex(bytes: PackedByteArray) -> String:
	var h := ""
	for i in range(bytes.size()):
		h += "%02x" % bytes[i]
	return h

static func _hex_to_bytes(h: String) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(h.length() / 2)
	for i in range(0, h.length(), 2):
		b[i / 2] = int("0x" + h.substr(i, 2))
	return b
