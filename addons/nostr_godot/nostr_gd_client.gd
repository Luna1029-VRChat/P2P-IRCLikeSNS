extends Node

const Secp256k1 = preload("res://addons/nostr_godot/secp256k1.gd")
const ConfigPath = "user://nostr_config.cfg"

signal Connected(url: String)
signal Disconnected(url: String)
signal MessageReceived(url: String, command: String, data: Array)
signal EventReceived(subscription_id: String, event_dict: Dictionary)
signal NoticeReceived(url: String, message: String)
signal ExtensionAuthCompleted()
signal TimelineUpdated(timeline_array: Array)
signal ReactionReceived(url: String, subscription_id: String, event_dict: Dictionary)
signal ZapReceiptReceived(url: String, subscription_id: String, event_dict: Dictionary)
signal NwcResponseReceived(url: String, subscription_id: String, event_dict: Dictionary)
signal WalletInfoReceived(url: String, subscription_id: String, event_dict: Dictionary)
signal DirectMessageReceived(url: String, subscription_id: String, event_dict: Dictionary)

const MAX_TIMELINE_ITEMS := 100
const MAX_PACKETS_PER_FRAME := 10

var IsLoggedIn: bool = false
var IsNwcConfigured: bool = false
var NwcWalletPubkey: String = ""
var JapaneseFilterEnabled: bool = true

var _private_key_hex: String = ""
var _public_key_hex: String = ""
var _is_extension_login: bool = false
var _extension_pubkey: String = ""

var _relays: Dictionary = {}
var _timeline_pool: Array[Dictionary] = []
var _timeline_event_ids: Dictionary = {}
var _debounce_timer: SceneTreeTimer = null

var _auth_server: TCPServer = null
var _auth_connections: Array[StreamPeerTCP] = []
var _web_auth_pending: bool = false

var _nwc_connection_string: String = ""
var _nwc_relay_url: String = ""
var _nwc_secret_key: String = ""
var _nwc_secret_pubkey: String = ""
var _nwc_pending_event_id: String = ""
var _nwc_pending_method: String = ""

var _web_sign_pending: bool = false
var _signature_pending: String = ""
var _pending_web_event: Dictionary = {}

var _self_profile_check_subs: Dictionary = {}
var _last_self_profile_event: Dictionary = {}


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	if OS.has_feature("web"):
		_poll_web_auth()
		_poll_web_sign()
	_poll_auth_server()
	if _relays.is_empty():
		return
	for url in _relays.keys():
		var r = _relays[url]
		if r.ws == null:
			continue
		r.ws.poll()
		var state = r.ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			if not r.connected:
				r.connected = true
				print("NostrGD: relay connected ", url)
				Connected.emit(url)
				for msg in r.pending_messages:
					r.ws.send_text(JSON.new().stringify(msg))
				r.pending_messages.clear()
				if IsLoggedIn:
					_ensure_self_profile_on_relay(url)
			var count = 0
			while r.ws.get_available_packet_count() > 0 and count < MAX_PACKETS_PER_FRAME:
				_handle_incoming_packet(url)
				count += 1
		elif state == WebSocketPeer.STATE_CLOSED or state == WebSocketPeer.STATE_CONNECTING:
			if state == WebSocketPeer.STATE_CONNECTING:
				continue
			if r.connected:
				r.connected = false
				Disconnected.emit(url)
			r.failed_once = true


func _ensure_self_profile_on_relay(url: String) -> void:
	if _public_key_hex.is_empty():
		return
	var sub_id := "_selfprof_" + url.md5_text()
	if sub_id in _self_profile_check_subs:
		return
	_self_profile_check_subs[sub_id] = {relay_url = url, received_profile = false}
	var filter := {kinds = [0], authors = [_public_key_hex], limit = 1}
	_send_to_relay(url, ["REQ", sub_id, filter])


func _handle_profile_check_eose(sub_id: String, url: String) -> void:
	var info = _self_profile_check_subs.get(sub_id)
	if info == null:
		return
	if not info.received_profile:
		var profile_ev = _last_self_profile_event
		if profile_ev.is_empty():
			var profile := {name = _public_key_hex.left(8)}
			var ev := _make_event(0, JSON.new().stringify(profile), [])
			profile_ev = Secp256k1.sign_event(_private_key_hex, ev)
			_last_self_profile_event = profile_ev
		var j := JSON.new()
		var msg := j.stringify(["EVENT", profile_ev])
		var r = _relays.get(url)
		if r != null and r.connected and r.ws != null:
			r.ws.send_text(msg)
	_send_to_relay(url, ["CLOSE", sub_id])
	_self_profile_check_subs.erase(sub_id)


# ──────────────────────────────────────────
# Relay management
# ──────────────────────────────────────────

func ConnectToRelay(url: String) -> void:
	if _relays.has(url):
		return
	var ws := WebSocketPeer.new()
	var err := ws.connect_to_url(url)
	if err == OK:
		_relays[url] = {
			ws = ws,
			connected = false,
			failed_once = false,
			pending_messages = []
		}


func ActivateRelayProcessing() -> void:
	if _relays.size() > 0:
		set_process(true)


func DisconnectFromRelay(url: String) -> void:
	if not _relays.has(url):
		return
	var r = _relays[url]
	if r.ws != null:
		r.ws.close()
	if r.connected:
		r.connected = false
		Disconnected.emit(url)
	_relays.erase(url)
	if _relays.is_empty():
		_stop_auth_server()
		_is_extension_login = false
		set_process(false)


func GetConnectedRelayUrls() -> Array:
	var result: Array[String] = []
	for url in _relays.keys():
		result.append(url)
	return result


# ──────────────────────────────────────────
# Low-level message helpers
# ──────────────────────────────────────────

func _retry_relay_connection(url: String) -> void:
	if not _relays.has(url):
		ConnectToRelay(url)
		return
	var r = _relays[url]
	if r.ws != null:
		r.ws.close()
	r.failed_once = false
	r.ws = WebSocketPeer.new()
	var err: int = r.ws.connect_to_url(url)
	if err != OK:
		r.ws = null


func _broadcast_message(message: Array) -> void:
	var j := JSON.new()
	var json_str := j.stringify(message)
	for url in _relays.keys():
		var r = _relays[url]
		if r.connected and r.ws != null:
			r.ws.send_text(json_str)


func _broadcast_or_queue(message: Array) -> void:
	var j := JSON.new()
	var json_str := j.stringify(message)
	for url in _relays.keys():
		var r = _relays[url]
		if r.connected and r.ws != null:
			r.ws.send_text(json_str)
		else:
			r.pending_messages.append(message.duplicate(true))


func _send_to_relay(target_url: String, message: Array) -> void:
	var j := JSON.new()
	var json_str := j.stringify(message)
	for url in _relays.keys():
		if url != target_url:
			continue
		var r = _relays[url]
		if r.connected and r.ws != null:
			r.ws.send_text(json_str)
		else:
			r.pending_messages.append(message.duplicate(true))
			if r.ws != null and r.ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				_retry_relay_connection(url)
		return
	ConnectToRelay(target_url)
	if _relays.has(target_url):
		_relays[target_url].pending_messages.append(message.duplicate(true))


# ──────────────────────────────────────────
# Key management
# ──────────────────────────────────────────

func CreateNewKeyPair() -> String:
	var buf := PackedByteArray()
	buf.resize(32)
	for i in 32:
		buf[i] = randi() % 256
	_private_key_hex = buf.hex_encode()
	_public_key_hex = Secp256k1.derive_pubkey(_private_key_hex)
	IsLoggedIn = true
	return Secp256k1.nsec_encode(_private_key_hex)


func GetPrivateKeyHex() -> String:
	if _is_extension_login:
		return ""
	return _private_key_hex


func GetPrivateKeyNsec() -> String:
	if _is_extension_login:
		return ""
	return Secp256k1.nsec_encode(_private_key_hex)


func Login(key_input: String) -> bool:
	var hex_key := key_input.strip_edges()
	if hex_key.begins_with("nsec1"):
		hex_key = Secp256k1.nsec_decode(hex_key)
		if hex_key.is_empty():
			push_error("NostrGD: Invalid nsec")
			return false
	if hex_key.length() != 64 or not _is_valid_hex(hex_key):
		push_error("NostrGD: Invalid private key")
		return false
	_private_key_hex = hex_key
	_public_key_hex = Secp256k1.derive_pubkey(hex_key)
	IsLoggedIn = true
	return true


func LoginWithExtension(pubkey_hex: String) -> void:
	_private_key_hex = ""
	_public_key_hex = ""
	_extension_pubkey = pubkey_hex.to_lower()
	_is_extension_login = true
	IsLoggedIn = true


func Logout() -> void:
	_private_key_hex = ""
	_public_key_hex = ""
	_extension_pubkey = ""
	_is_extension_login = false
	IsLoggedIn = false


func GetPublicKeyHex() -> String:
	if _is_extension_login:
		return _extension_pubkey
	return _public_key_hex


func HasSavedPrivateKey() -> bool:
	return not LoadPrivateKey().is_empty()


# ──────────────────────────────────────────
# Config persistence
# ──────────────────────────────────────────

func SavePrivateKey(key: String) -> void:
	var config := ConfigFile.new()
	config.load(ConfigPath)
	config.set_value("auth", "private_key", key)
	config.save(ConfigPath)


func LoadPrivateKey() -> String:
	var config := ConfigFile.new()
	if config.load(ConfigPath) == OK:
		return config.get_value("auth", "private_key", "")
	return ""


func SaveRelayUrls(urls: Array) -> void:
	var config := ConfigFile.new()
	config.load(ConfigPath)
	config.set_value("relays", "list", urls)
	config.save(ConfigPath)


func LoadRelayUrls() -> Array:
	var config := ConfigFile.new()
	if config.load(ConfigPath) == OK and config.has_section("relays"):
		return config.get_value("relays", "list", [])
	return []


# ──────────────────────────────────────────
# Japanese filter
# ──────────────────────────────────────────

func SetJapaneseFilterEnabled(enabled: bool) -> void:
	JapaneseFilterEnabled = enabled
	_broadcast_sorted_timeline()


func IsJapaneseText(text: String) -> bool:
	if text.is_empty():
		return false
	for c in text:
		var u = c.unicode_at(0)
		if (u >= 0x3040 and u <= 0x309F) or (u >= 0x30A0 and u <= 0x30FF) \
			or (u >= 0x4E00 and u <= 0x9FFF) or (u >= 0x3400 and u <= 0x4DBF):
			return true
	return false


# ──────────────────────────────────────────
# Event helpers
# ──────────────────────────────────────────

func _make_event(kind: int, content: String, tags: Array) -> Dictionary:
	return {
		pubkey = GetPublicKeyHex(),
		created_at = int(Time.get_unix_time_from_system()),
		kind = kind,
		tags = tags,
		content = content
	}


func _sign_and_broadcast(event: Dictionary) -> Dictionary:
	if _private_key_hex.is_empty() and not _is_extension_login:
		return {}
	if not _private_key_hex.is_empty():
		var signed := Secp256k1.sign_event(_private_key_hex, event.duplicate(true))
		_broadcast_or_queue(["EVENT", signed])
		_process_event_for_timeline(signed)
		return signed
	elif _is_extension_login and OS.has_feature("web"):
		if _web_sign_pending:
			return {}
		var ev_json := JSON.new().stringify(event.duplicate())
		_pending_web_event = event.duplicate()
		_initiate_web_sign(ev_json)
	return {}


func _sign_with_key(event: Dictionary, key_hex: String) -> Dictionary:
	return Secp256k1.sign_event(key_hex, event)


# ──────────────────────────────────────────
# Event sending
# ──────────────────────────────────────────

func SendTextNote(content: String) -> void:
	if not IsLoggedIn:
		return
	var tags := [["client", "NostrGD"]]
	var ev := _make_event(1, content, tags)
	_sign_and_broadcast(ev)


func SendProfileMetaData(name: String, display_name: String, about: String = "", picture: String = "", banner: String = "", lud16: String = "") -> void:
	if not IsLoggedIn:
		return
	var profile := {name = name, display_name = display_name, about = about}
	if not picture.is_empty():
		profile.picture = picture
	if not banner.is_empty():
		profile.banner = banner
	if not lud16.is_empty():
		profile.lud16 = lud16
	var ev := _make_event(0, JSON.new().stringify(profile), [])
	if not _private_key_hex.is_empty():
		var signed := Secp256k1.sign_event(_private_key_hex, ev)
		_last_self_profile_event = signed
		_broadcast_or_queue(["EVENT", signed])
		_process_event_for_timeline(signed)
	elif _is_extension_login and OS.has_feature("web"):
		if _web_sign_pending:
			return
		var ev_json := JSON.new().stringify(ev)
		_initiate_web_sign(ev_json)


func SendRepost(target_event_id: String, quote: String = "") -> void:
	if not IsLoggedIn:
		return
	var tags := [["e", target_event_id]]
	var ev := _make_event(6, quote, tags)
	_sign_and_broadcast(ev)


func SendReply(content: String, reply_to_event_id: String, reply_to_pubkey: String) -> void:
	if not IsLoggedIn:
		return
	var tags := [["e", reply_to_event_id], ["p", reply_to_pubkey], ["client", "NostrGD"]]
	var ev := _make_event(1, content, tags)
	_sign_and_broadcast(ev)


func SendDirectMessage(content: String, target_pubkey: String) -> void:
	if not IsLoggedIn or _private_key_hex.is_empty():
		return
	var encrypted := Secp256k1.nip04_encrypt(_private_key_hex, target_pubkey, content)
	var tags := [["p", target_pubkey]]
	var ev := _make_event(4, encrypted, tags)
	_sign_and_broadcast(ev)


func SendReaction(target_event_id: String, target_pubkey: String, emoji: String = "+") -> void:
	if not IsLoggedIn:
		return
	var tags := [["e", target_event_id], ["p", target_pubkey]]
	var ev := _make_event(7, emoji, tags)
	_sign_and_broadcast(ev)


func SendCustomEvent(kind: int, content: String, tags: Array) -> void:
	if not IsLoggedIn:
		return
	var ev := _make_event(kind, content, tags)
	_sign_and_broadcast(ev)


func CreateZapRequestEvent(target_event_id: String, target_pubkey: String, amount_msat: int, comment: String = "", relay_urls: Array = []) -> Dictionary:
	if not IsLoggedIn:
		return {}
	var tags := [["p", target_pubkey], ["amount", str(amount_msat)]]
	if not target_event_id.is_empty():
		tags.append(["e", target_event_id])
	if relay_urls.size() > 0:
		var relays_tag := ["relays"]
		for u in relay_urls:
			relays_tag.append(u)
		tags.append(relays_tag)
	var ev := _make_event(9734, comment, tags)
	if not _private_key_hex.is_empty():
		ev = _sign_with_key(ev, _private_key_hex)
	return ev


func SendEvent(event_dict: Dictionary) -> void:
	if event_dict.is_empty() or not event_dict.has("id"):
		print("NostrGD: SendEvent called with invalid event")
		return
	_broadcast_or_queue(["EVENT", event_dict])


# ──────────────────────────────────────────
# Subscriptions / queries
# ──────────────────────────────────────────

func RequestTimeline(subscription_id: String, limit: int = 20, target_url: String = "") -> void:
	var filter := {kinds = [1], limit = limit}
	var j := JSON.new()
	var json_str := j.stringify(["REQ", subscription_id, filter])
	for url in _relays.keys():
		var r = _relays[url]
		if r.connected and r.ws != null and (target_url.is_empty() or url == target_url):
			r.ws.send_text(json_str)


func RequestNotifications(subscription_id: String, pubkey: String) -> void:
	var filter := {"kinds": [7, 6, 16, 9735], "#p": [pubkey], "limit": 30}
	_broadcast_or_queue(["REQ", subscription_id, filter])


func RequestNotificationsForRelay(subscription_id: String, pubkey: String, target_url: String) -> void:
	var filter := {"kinds": [1, 7, 6, 16, 9735], "#p": [pubkey], "limit": 30}
	_send_to_relay(target_url, ["REQ", subscription_id, filter])


func RequestDirectMessages(subscription_id: String, pubkey: String) -> void:
	var filter1 := {"kinds": [4], "#p": [pubkey], "limit": 50}
	var filter2 := {"kinds": [4], "authors": [pubkey], "limit": 50}
	_broadcast_or_queue(["REQ", subscription_id, filter1, filter2])


func RequestDirectMessagesForRelay(subscription_id: String, pubkey: String, target_url: String) -> void:
	var filter1 := {"kinds": [4], "#p": [pubkey], "limit": 50}
	var filter2 := {"kinds": [4], "authors": [pubkey], "limit": 50}
	_send_to_relay(target_url, ["REQ", subscription_id, filter1, filter2])


func RequestProfiles(subscription_id: String, pubkeys: Array) -> void:
	var filter := {kinds = [0], authors = pubkeys}
	_broadcast_or_queue(["REQ", subscription_id, filter])


func RequestProfilesForRelay(subscription_id: String, pubkeys: Array, target_url: String) -> void:
	var filter := {kinds = [0], authors = pubkeys}
	_send_to_relay(target_url, ["REQ", subscription_id, filter])


func RequestEventById(event_id: String, subscription_id: String) -> void:
	var filter := {ids = [event_id], limit = 1}
	_broadcast_message(["REQ", subscription_id, filter])


func RequestZapReceipts(subscription_id: String, event_ids: Array) -> void:
	var filter := {"kinds": [9735], "#e": event_ids}
	_broadcast_message(["REQ", subscription_id, filter])


func RequestCustomEvents(subscription_id: String, kinds: Array, pubkey: String) -> void:
	var filter := {"kinds": kinds, "#p": [pubkey], "limit": 50}
	_broadcast_or_queue(["REQ", subscription_id, filter])

func RequestUserEvents(subscription_id: String, kinds: Array, author: String) -> void:
	var filter := {"kinds": kinds, "authors": [author], "limit": 10}
	_broadcast_or_queue(["REQ", subscription_id, filter])

func RequestEventsWithTag(subscription_id: String, kinds: Array, tag_name: String, tag_value: String) -> void:
	var filter := {"kinds": kinds, "#" + tag_name: [tag_value]}
	_broadcast_or_queue(["REQ", subscription_id, filter])

func CloseSubscription(subscription_id: String) -> void:
	_broadcast_message(["CLOSE", subscription_id])


func ClearTimeline() -> void:
	_timeline_pool.clear()
	_timeline_event_ids.clear()
	if _debounce_timer != null:
		_debounce_timer.timeout.disconnect(_broadcast_sorted_timeline)
		_debounce_timer = null


# ──────────────────────────────────────────
# Event processing pipeline
# ──────────────────────────────────────────

func _handle_incoming_packet(url: String) -> void:
	if not _relays.has(url):
		return
	var r = _relays[url]
	var packet: PackedByteArray = r.ws.get_packet()
	var json_str: String = packet.get_string_from_utf8()
	if json_str.is_empty():
		return
	var j := JSON.new()
	if j.parse(json_str) != OK:
		return
	var parsed = j.get_data()
	if parsed == null or not (parsed is Array) or parsed.is_empty():
		return
	var cmd := str(parsed[0])
	MessageReceived.emit(url, cmd, parsed)
	match cmd:
		"EVENT":
			if parsed.size() >= 3:
				var sub_id := str(parsed[1])
				var ev := parsed[2] as Dictionary
				if ev == null:
					return
				var ev_kind = ev.get("kind", 0)
				var ev_pk = str(ev.get("pubkey", "")).left(12)
				print("NostrGD: EVENT sub=", sub_id, " kind=", ev_kind, " from=", ev_pk)
				if sub_id in _self_profile_check_subs and ev.get("kind") == 0:
					_self_profile_check_subs[sub_id].received_profile = true
				EventReceived.emit(sub_id, ev)
				_process_event_for_timeline(ev)
				_route_event_by_kind(ev, url, sub_id)
		"NOTICE":
			if parsed.size() >= 2:
				NoticeReceived.emit(url, str(parsed[1]))
		"OK":
			if parsed.size() >= 3:
				var event_id := str(parsed[1])
				var accepted := bool(parsed[2])
				var msg := str(parsed[3] if parsed.size() >= 4 else "")
				print("NostrGD: OK ", event_id.left(16), " accepted=", accepted, " message=", msg)
		"EOSE":
			if parsed.size() >= 2:
				var sub_id := str(parsed[1])
				print("NostrGD: EOSE ", sub_id)
				if sub_id in _self_profile_check_subs:
					_handle_profile_check_eose(sub_id, url)


func _route_event_by_kind(ev: Dictionary, url: String, sub_id: String) -> void:
	var kind := int(ev.get("kind", 0))
	match kind:
		4:
			if not _private_key_hex.is_empty() and ev.has("content"):
				var sender := str(ev.get("pubkey", ""))
				if sender != _public_key_hex:
					var decrypted := Secp256k1.nip04_decrypt(_private_key_hex, sender, str(ev.get("content", "")))
					ev["decrypted_content"] = decrypted
			DirectMessageReceived.emit(url, sub_id, ev)
		7:
			ReactionReceived.emit(url, sub_id, ev)
		9735:
			ZapReceiptReceived.emit(url, sub_id, ev)
		23194:
			NwcResponseReceived.emit(url, sub_id, ev)
		23195:
			if IsNwcConfigured and ev.has("content"):
				var decrypted := _nwc_decrypt(str(ev.get("content", "")), str(ev.get("pubkey", "")))
				ev["decrypted_content"] = decrypted
			NwcResponseReceived.emit(url, sub_id, ev)


func _process_event_for_timeline(ev: Dictionary) -> void:
	var kind := int(ev.get("kind", 0))
	if kind == 1:
		var content := str(ev.get("content", ""))
		ev["media_images"] = _extract_image_urls(content)
		ev["media_nostr_uris"] = _extract_regex(content, "nostr:[a-z0-9]+")
		ev["media_youtube"] = _extract_regex(content, "https?://(?:www\\.)?(?:youtube\\.com/watch\\?v=|youtu\\.be/)[a-zA-Z0-9_-]+")
		ev["media_youtube_ids"] = _extract_youtube_ids(content)
		ev["media_hashtags"] = _extract_regex(content, "#\\w+")
		var eid := str(ev.get("id", ""))
		if not eid.is_empty() and _timeline_event_ids.has(eid):
			return
		_timeline_pool.append(ev)
		if not eid.is_empty():
			_timeline_event_ids[eid] = true
		_trim_pool()
		_trigger_debounce()
	elif kind == 6 or kind == 16:
		ev["is_repost"] = true
		var tags := ev.get("tags", []) as Array
		var repost_eid := ""
		for t in tags:
			if t is Array and t.size() >= 2:
				if t[0] == "e":
					repost_eid = str(t[1])
					ev["repost_event_id"] = repost_eid
				elif t[0] == "p":
					ev["repost_pubkey"] = str(t[1])
		if not repost_eid.is_empty():
			for existing in _timeline_pool:
				if str(existing.get("id", "")) == repost_eid:
					ev["repost_original_content"] = existing.get("content", "")
					ev["repost_original_pubkey"] = existing.get("pubkey", "")
					if existing.has("media_images"):
						ev["repost_media_images"] = existing["media_images"]
					if existing.has("media_youtube"):
						ev["repost_media_youtube"] = existing["media_youtube"]
					if existing.has("media_youtube_ids"):
						ev["repost_media_youtube_ids"] = existing["media_youtube_ids"]
					if existing.has("media_hashtags"):
						ev["repost_media_hashtags"] = existing["media_hashtags"]
					break
		var reid := str(ev.get("id", ""))
		if not reid.is_empty() and _timeline_event_ids.has(reid):
			return
		_timeline_pool.append(ev)
		if not reid.is_empty():
			_timeline_event_ids[reid] = true
		_trim_pool()
		_trigger_debounce()


func _trigger_debounce() -> void:
	if _debounce_timer != null:
		_debounce_timer.timeout.disconnect(_broadcast_sorted_timeline)
	_debounce_timer = get_tree().create_timer(0.4)
	_debounce_timer.timeout.connect(_broadcast_sorted_timeline)


func _trim_pool() -> void:
	if _timeline_pool.size() <= MAX_TIMELINE_ITEMS:
		return
	_timeline_pool.sort_custom(func(a, b): return int(a.get("created_at", 0)) > int(b.get("created_at", 0)))
	while _timeline_pool.size() > MAX_TIMELINE_ITEMS:
		_timeline_pool.pop_back()
	_timeline_event_ids.clear()
	for ev in _timeline_pool:
		var eid := str(ev.get("id", ""))
		if not eid.is_empty():
			_timeline_event_ids[eid] = true


func _broadcast_sorted_timeline() -> void:
	_timeline_pool.sort_custom(func(a, b): return int(a.get("created_at", 0)) > int(b.get("created_at", 0)))
	var result: Array[Dictionary] = []
	for ev in _timeline_pool:
		if JapaneseFilterEnabled:
			var content := str(ev.get("content", ""))
			var has_ja := IsJapaneseText(content)
			if not has_ja and ev.has("repost_original_content"):
				has_ja = IsJapaneseText(str(ev["repost_original_content"]))
			if not has_ja:
				continue
		result.append(ev)
	TimelineUpdated.emit(result)


# ──────────────────────────────────────────
# Pattern extraction
# ──────────────────────────────────────────

func _extract_image_urls(text: String) -> Array:
	var result: Array[String] = []
	var re := RegEx.create_from_string("(https?://\\S+\\.(?:jpg|jpeg|png|gif|webp)(?:\\?\\S+)?)")
	if re == null:
		return result
	for m in re.search_all(text):
		var s := m.get_string()
		if not result.has(s):
			result.append(s)
	return result


func _extract_regex(text: String, pattern: String) -> Array:
	var result: Array[String] = []
	var re := RegEx.create_from_string(pattern)
	if re == null:
		return result
	for m in re.search_all(text):
		var s := m.get_string()
		if not result.has(s):
			result.append(s)
	return result


func _extract_youtube_ids(text: String) -> Array:
	var result: Array[String] = []
	var re := RegEx.create_from_string("(?:youtube\\.com/watch\\?v=|youtu\\.be/)([a-zA-Z0-9_-]+)")
	if re == null:
		return result
	for m in re.search_all(text):
		if m.get_group_count() >= 1:
			var vid := m.get_string(1)
			if not result.has(vid):
				result.append(vid)
	return result


# ──────────────────────────────────────────
# NIP-07 Auth (Desktop TCPServer)
# ──────────────────────────────────────────

func StartLocalAuthServer() -> void:
	if OS.has_feature("web"):
		_start_web_auth()
		return
	if _auth_server != null:
		return
	_auth_server = TCPServer.new()
	var err := _auth_server.listen(8123)
	if err != OK:
		push_error("NostrGD: Failed to start auth server on port 8123")
		return
	set_process(true)
	OS.shell_open("http://localhost:8123/")


func StopLocalAuthServer() -> void:
	_web_auth_pending = false
	if _auth_server == null:
		return
	_auth_server.stop()
	_auth_server = null
	for conn in _auth_connections:
		if is_instance_valid(conn):
			conn.disconnect_from_stream()
	_auth_connections.clear()


func _stop_auth_server() -> void:
	StopLocalAuthServer()


func _poll_auth_server() -> void:
	if _auth_server == null:
		return
	while _auth_server.is_connection_available():
		var conn := _auth_server.take_connection()
		if conn == null:
			continue
		_auth_connections.append(conn)
	var i := 0
	while i < _auth_connections.size():
		var conn = _auth_connections[i]
		if not is_instance_valid(conn) or conn.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_auth_connections.remove_at(i)
			continue
		if conn.get_available_bytes() <= 0:
			i += 1
			continue
		var raw := conn.get_data(conn.get_available_bytes())
		if raw[0] != OK:
			_auth_connections.remove_at(i)
			continue
		var req := (raw[1] as PackedByteArray).get_string_from_utf8()
		var lines := req.split("\r\n")
		if lines.is_empty():
			_auth_connections.remove_at(i)
			continue
		var parts := lines[0].split(" ")
		if parts.size() < 2:
			_auth_connections.remove_at(i)
			continue
		var path := parts[1]
		if parts[0] == "OPTIONS":
			_send_http(conn, 200, "text/plain", "OK", true)
		elif path == "/":
			_send_http(conn, 200, "text/html; charset=utf-8", _get_auth_html())
		elif path.begins_with("/receive?pubkey="):
			var q := path.split("?")[1] if "?" in path else ""
			var params := _parse_query(q)
			var pk := params.get("pubkey", "")
			if not pk.is_empty():
				call_deferred("_on_auth_pubkey", pk)
			_send_http(conn, 200, "text/plain", "OK")
		else:
			_send_http(conn, 404, "text/plain", "Not Found")
		_auth_connections.remove_at(i)


func _on_auth_pubkey(pubkey_hex: String) -> void:
	LoginWithExtension(pubkey_hex)
	ExtensionAuthCompleted.emit()


func _parse_query(query: String) -> Dictionary:
	var result := {}
	for pair in query.split("&"):
		var kv := pair.split("=")
		if kv.size() == 2:
			result[kv[0]] = kv[1].uri_decode()
	return result


func _send_http(conn: StreamPeerTCP, code: int, content_type: String, body: String, cors: bool = false) -> void:
	var status := "OK" if code == 200 else ("Not Found" if code == 404 else "OK")
	var resp := "HTTP/1.1 %d %s\r\n" % [code, status]
	resp += "Content-Type: %s\r\n" % content_type
	resp += "Content-Length: %d\r\n" % body.to_utf8_buffer().size()
	resp += "Connection: close\r\n"
	if cors:
		resp += "Access-Control-Allow-Origin: *\r\n"
		resp += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
	resp += "\r\n" + body
	conn.put_data(resp.to_utf8_buffer())
	conn.disconnect_from_stream()


func _get_auth_html() -> String:
	return """<!DOCTYPE html>
<html><head><title>NostrGD Connect</title></head>
<body style='font-family:sans-serif;text-align:center;padding-top:50px;background:#f0f2f5;'>
<div style='max-width:500px;margin:0 auto;background:white;padding:30px;border-radius:10px;'>
<h2>NostrGD Authentication (NIP-07)</h2>
<p id='status'>Waiting for Nostr extension...</p>
<script>
window.addEventListener('load', async () => {
    if (!window.nostr) {
        document.getElementById('status').innerText = 'Nostr extension not found. Install Alby or nos2x.';
        return;
    }
    try {
        const pk = await window.nostr.getPublicKey();
        const resp = await fetch('/receive?pubkey=' + encodeURIComponent(pk), {mode:'cors'});
        if (resp.ok) {
            document.getElementById('status').innerText = 'OK! Pubkey: ' + pk.substring(0,12) + '... You can close this tab.';
        }
    } catch(e) {
        document.getElementById('status').innerText = 'Error: ' + e.message;
    }
});
</script>
</div></body></html>"""


# ──────────────────────────────────────────
# Web (JavaScriptBridge) NIP-07
# ──────────────────────────────────────────

func _start_web_auth() -> void:
	_web_auth_pending = true
	set_process(true)
	JavaScriptBridge.eval("""
		if (!window.nostr) {
			window._nostrGDError = 'Nostr extension not found.';
		} else {
			window.nostr.getPublicKey().then(function(pk) {
				window._nostrGDPubkey = pk;
			}).catch(function(err) {
				window._nostrGDError = 'Failed to get public key: ' + err.message;
			});
		}
	""")


func _poll_web_auth() -> void:
	if not _web_auth_pending:
		return
	var err := str(JavaScriptBridge.eval("window._nostrGDError || ''"))
	if not err.is_empty():
		_web_auth_pending = false
		push_error("NostrGD: Web auth error: ", err)
		return
	var pk := str(JavaScriptBridge.eval("window._nostrGDPubkey || ''"))
	if not pk.is_empty():
		_web_auth_pending = false
		LoginWithExtension(pk)
		ExtensionAuthCompleted.emit()


func _initiate_web_sign(event_json: String) -> void:
	if _web_sign_pending:
		return
	_web_sign_pending = true
	set_process(true)
	var escaped := event_json.replace("\\", "\\\\").replace("'", "\\'")
	JavaScriptBridge.eval("""
		try {
			var ev = JSON.parse('""" + escaped + """');
			delete ev.id;
			window.nostr.signEvent(ev).then(function(signedEvent) {
				window._nostrGDSig = JSON.stringify(signedEvent);
			}).catch(function(err) {
				window._nostrGDError = 'Signing failed: ' + err.message;
			});
		} catch(e) {
			window._nostrGDError = 'JS error: ' + e.message;
		}
	""")


func _poll_web_sign() -> void:
	if not _web_sign_pending:
		return
	var err := str(JavaScriptBridge.eval("window._nostrGDError || ''"))
	if not err.is_empty():
		_web_sign_pending = false
		_signature_pending = ""
		_pending_web_event = {}
		push_error("NostrGD: Web sign error: ", err)
		return
	var sig_raw := str(JavaScriptBridge.eval("window._nostrGDSig || ''"))
	if sig_raw.is_empty():
		return
	_web_sign_pending = false
	var j := JSON.new()
	if j.parse(sig_raw) != OK:
		_signature_pending = ""
		_pending_web_event = {}
		return
	var signed_event: Dictionary = j.data
	if not signed_event.has("sig") or not signed_event.has("id"):
		_signature_pending = ""
		_pending_web_event = {}
		return
	_signature_pending = signed_event.sig
	_broadcast_or_queue(["EVENT", signed_event])
	_process_event_for_timeline(signed_event)
	_pending_web_event = {}


# ──────────────────────────────────────────
# NWC (NIP-47)
# ──────────────────────────────────────────

func SaveNwcConnectionString(conn_str: String) -> void:
	var config := ConfigFile.new()
	config.load(ConfigPath)
	config.set_value("nwc", "connection_string", conn_str)
	config.save(ConfigPath)
	_nwc_connection_string = conn_str


func LoadNwcConnectionString() -> String:
	var config := ConfigFile.new()
	if config.load(ConfigPath) == OK:
		var val := config.get_value("nwc", "connection_string", "")
		if not str(val).is_empty():
			_nwc_connection_string = str(val)
			return _nwc_connection_string
	_nwc_connection_string = ""
	return ""


func ClearNwcConnectionString() -> void:
	_nwc_connection_string = ""
	NwcWalletPubkey = ""
	_nwc_relay_url = ""
	_nwc_secret_key = ""
	_nwc_secret_pubkey = ""
	IsNwcConfigured = false
	var config := ConfigFile.new()
	config.load(ConfigPath)
	config.set_value("nwc", "connection_string", "")
	config.save(ConfigPath)


func InitNWC(connection_string: String) -> bool:
	var info := _parse_nwc_str(connection_string)
	if info == null:
		push_error("NostrGD/NWC: Failed to parse connection string")
		return false
	if not _setup_nwc_enc(info.secret):
		push_error("NostrGD/NWC: Encryption setup failed")
		return false
	NwcWalletPubkey = info.wallet_pubkey
	_nwc_relay_url = info.relay_url
	_nwc_connection_string = connection_string
	print("NostrGD/NWC: InitNWC connecting to relay=", info.relay_url, " wallet_pk=", info.wallet_pubkey.left(16))
	ConnectToRelay(info.relay_url)
	ActivateRelayProcessing()
	IsNwcConfigured = true
	return true


func TryInitNWC() -> bool:
	var conn_str := LoadNwcConnectionString()
	if conn_str.is_empty():
		return false
	return InitNWC(conn_str)


func _parse_nwc_str(conn_str: String) -> Dictionary:
	var s := conn_str.replace("nostr+walletconnect://", "https://")
	var uri := s.split("?")
	if uri.is_empty():
		return {}
	var host := uri[0].replace("https://", "")
	var wallet_pubkey := host.split("/")[0] if "/" in host else host
	var params_str := uri[1] if uri.size() >= 2 else ""
	var params := _parse_query(params_str)
	var relay_url := params.get("relay", "")
	var secret := params.get("secret", "")
	if wallet_pubkey.is_empty() or relay_url.is_empty():
		return {}
	return {wallet_pubkey = wallet_pubkey, relay_url = relay_url, secret = secret}


func _setup_nwc_enc(secret: String) -> bool:
	if secret.is_empty():
		return false
	_nwc_secret_key = secret
	_nwc_secret_pubkey = Secp256k1.derive_pubkey(secret)
	return true


func _nwc_encrypt(plaintext: String, wallet_pubkey: String) -> String:
	return Secp256k1.nip04_encrypt(_nwc_secret_key, wallet_pubkey, plaintext)


func _nwc_decrypt(ciphertext: String, sender_pubkey: String) -> String:
	return Secp256k1.nip04_decrypt(_nwc_secret_key, sender_pubkey, ciphertext)


func SendNWCCommand(method: String, params: Dictionary, wallet_pubkey: String) -> String:
	if not IsLoggedIn:
		push_error("NostrGD/NWC: Not logged in")
		return ""
	if _nwc_relay_url.is_empty():
		push_error("NostrGD/NWC: No NWC relay configured")
		return ""
	var payload := {method = method, params = params}
	var encrypted := _nwc_encrypt(JSON.new().stringify(payload), wallet_pubkey)
	var tags := [["p", wallet_pubkey]]
	var ev := {
		pubkey = _nwc_secret_pubkey,
		created_at = int(Time.get_unix_time_from_system()),
		kind = 23194,
		tags = tags,
		content = encrypted
	}
	ev = _sign_with_key(ev, _nwc_secret_key)
	var event_id := str(ev.get("id", ""))
	_nwc_pending_event_id = event_id
	_nwc_pending_method = method
	print("NostrGD/NWC: sending kind 23194 to ", _nwc_relay_url, " method=", method, " id=", event_id)
	var in_relays := _relays.has(_nwc_relay_url)
	print("NostrGD/NWC: relay in _relays=", in_relays)
	if in_relays:
		var r = _relays[_nwc_relay_url]
		print("NostrGD/NWC: relay connected=", r.connected, " ws=", r.ws != null, " pending=", r.pending_messages.size())
	_send_to_relay(_nwc_relay_url, ["EVENT", ev])
	return event_id


func NWCGetBalance(wallet_pubkey: String) -> void:
	SendNWCCommand("get_balance", {}, wallet_pubkey)


func NWCPayInvoice(invoice: String, wallet_pubkey: String) -> bool:
	return not SendNWCCommand("pay_invoice", {invoice = invoice}, wallet_pubkey).is_empty()


func NWCMakeInvoice(amount_msat: int, description: String, wallet_pubkey: String) -> void:
	SendNWCCommand("make_invoice", {amount = amount_msat, description = description}, wallet_pubkey)


func NWCGetInfo(wallet_pubkey: String) -> void:
	SendNWCCommand("get_info", {}, wallet_pubkey)


func NWCLookupInvoice(payment_hash: String, wallet_pubkey: String) -> void:
	SendNWCCommand("lookup_invoice", {payment_hash = payment_hash}, wallet_pubkey)


# ──────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────

func _is_valid_hex(s: String) -> bool:
	if s.is_empty():
		return false
	for c in s:
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
			return false
	return true
