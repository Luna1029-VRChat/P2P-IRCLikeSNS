extends Control

const RELAY_URL := "wss://p2p-nostr.yoinekodo.jp"
const APP_TAG := "p2p-irc"
const DISCOVER_SUB_ID := "sess_discover"
const CHAT_SUB_ID := "chat_eavesdrop"
const SUBSCRIBED_STATE := 2

var _wh: Node
var _display_name := ""
var _my_pubkey := ""
var _is_host := false
var _has_joined := false
var _host_pubkey := ""
var _discover_events: Array = []
var _subscribed := false
var _join_order: Array = []

@onready var join_overlay: ColorRect = $JoinOverlay
@onready var overlay_close_btn: Button = $JoinOverlay/OverlayCloseBtn
@onready var show_join_btn: Button = $ChatPanel/VBox/TopBar/TopHBox/ShowJoinBtn
@onready var join_area: VBoxContainer = $JoinArea
@onready var name_input: LineEdit = $JoinArea/NameInput
@onready var join_btn: Button = $JoinArea/JoinBtn
@onready var status_label: Label = $JoinArea/StatusLabel
@onready var chat_panel: PanelContainer = $ChatPanel
@onready var timeline: VBoxContainer = $ChatPanel/VBox/ScrollContainer/Timeline
@onready var scroll_container: ScrollContainer = $ChatPanel/VBox/ScrollContainer
@onready var message_input: LineEdit = $ChatPanel/VBox/InputArea/InputHBox/MessageInput
@onready var send_btn: Button = $ChatPanel/VBox/InputArea/InputHBox/SendBtn
@onready var status_label2: Label = $ChatPanel/VBox/TopBar/TopHBox/StatusLabel2
@onready var host_label: Label = $ChatPanel/VBox/TopBar/TopHBox/HostLabel
@onready var listening_hint: Label = $ChatPanel/VBox/InputArea/InputHBox/ListeningHint


func _ready() -> void:
	_wh = get_node("/root/WebRTCHandler")

	join_btn.pressed.connect(_on_join_pressed)
	overlay_close_btn.pressed.connect(_on_overlay_close_pressed)
	show_join_btn.pressed.connect(_on_show_join_pressed)
	send_btn.pressed.connect(_on_send_pressed)
	message_input.text_submitted.connect(func(_t): _on_send_pressed())

	_wh.state_changed.connect(_on_wh_state_changed)
	_wh.msg_received.connect(_on_dc_msg_received)
	_wh.data_channel_opened.connect(_on_data_channel_opened)
	_wh.data_channel_closed.connect(_on_data_channel_closed)

	NostrGD.EventReceived.connect(_on_nostr_event_received)

	_wh.connect_to_relay(RELAY_URL)


func _on_wh_state_changed(state: int) -> void:
	if state == SUBSCRIBED_STATE and not _subscribed:
		_subscribed = true
		_my_pubkey = NostrGD.GetPublicKeyHex()
		print("ChatManager: Relay subscribed, pubkey=", _my_pubkey.left(12))

		var kinds0: Array = [0]
		NostrGD.RequestEventsWithTag(DISCOVER_SUB_ID, kinds0, "s", APP_TAG)

		var kinds21000: Array = [21000]
		NostrGD.RequestEventsWithTag(CHAT_SUB_ID, kinds21000, "s", APP_TAG)

		status_label.text = "会話を傍受中... 名前を入力して参加"
		listening_hint.visible = true
		_add_system_message("--- 傍受モード ---")


func _on_nostr_event_received(sub_id: String, ev: Dictionary) -> void:
	var kind = ev.get("kind", 0)
	var pubkey = str(ev.get("pubkey", ""))

	if sub_id == DISCOVER_SUB_ID and kind == 0:
		_discover_events.append(ev.duplicate())
		_process_discover_event(ev, false)
	elif sub_id == CHAT_SUB_ID and kind == 21000:
		_process_chat_event(ev)


func _process_discover_event(ev: Dictionary, _is_refresh: bool) -> void:
	var content = str(ev.get("content", ""))
	var pubkey = str(ev.get("pubkey", ""))

	var j = JSON.new()
	if j.parse(content) != OK:
		return
	var data = j.get_data()
	if not data is Dictionary:
		return

	var app = str(data.get("app", ""))
	if app != APP_TAG:
		return

	var role = str(data.get("role", ""))
	var name = str(data.get("name", pubkey.left(12)))

	if role == "host" and pubkey != _my_pubkey:
		_host_pubkey = pubkey
		_add_system_message("ホスト検出: " + name + " (" + pubkey.left(12) + ")")
		_update_status_bar()


func _process_chat_event(ev: Dictionary) -> void:
	var content = str(ev.get("content", ""))
	var pubkey = str(ev.get("pubkey", ""))

	if pubkey == _my_pubkey:
		return

	var j = JSON.new()
	if j.parse(content) != OK:
		return
	var msg = j.get_data()
	if not msg is Dictionary:
		return

	var msg_type = str(msg.get("type", ""))
	if msg_type == "chat":
		var name = str(msg.get("name", pubkey.left(12)))
		var text = str(msg.get("content", ""))
		var ts = int(msg.get("timestamp", 0))
		_add_chat_message(name, text, pubkey, ts)


func _on_overlay_close_pressed() -> void:
	join_overlay.visible = false
	join_area.visible = false
	show_join_btn.visible = true


func _on_show_join_pressed() -> void:
	join_overlay.visible = true
	join_area.visible = true
	show_join_btn.visible = false


func _on_join_pressed() -> void:
	_display_name = name_input.text.strip_edges()
	if _display_name.is_empty():
		status_label.text = "名前を入力してください"
		return

	_has_joined = true

	if _host_pubkey.is_empty():
		_become_host()
	else:
		_become_guest()

	join_overlay.visible = false
	join_area.visible = false
	show_join_btn.visible = false
	message_input.editable = true
	send_btn.disabled = false
	listening_hint.visible = false

	join_btn.disabled = false


func _become_host() -> void:
	_is_host = true
	_host_pubkey = _my_pubkey
	print("ChatManager: Become host")

	var content_dict := {
		name = _display_name,
		app = APP_TAG,
		role = "host"
	}
	var tags: Array = [["s", APP_TAG]]
	NostrGD.SendCustomEvent(0, JSON.new().stringify(content_dict), tags)

	_join_order.clear()
	_join_order.append(_my_pubkey)

	_add_system_message("あなたがホストになりました")
	_update_status_bar()


func _become_guest() -> void:
	_is_host = false
	print("ChatManager: Join as guest, host=", _host_pubkey.left(12))

	var content_dict := {
		name = _display_name,
		app = APP_TAG,
		role = "guest"
	}
	var tags: Array = [["s", APP_TAG]]
	NostrGD.SendCustomEvent(0, JSON.new().stringify(content_dict), tags)

	_wh.join_host(_host_pubkey)
	_add_system_message("ホストに参加リクエストを送信しました")
	_update_status_bar()


func _on_data_channel_opened(_dc, peer_pubkey: String) -> void:
	print("ChatManager: DC opened with ", peer_pubkey.left(12))
	if _is_host and not _join_order.has(peer_pubkey):
		_join_order.append(peer_pubkey)
	_add_system_message("P2P接続: " + peer_pubkey.left(12))
	_update_status_bar()


func _on_data_channel_closed(peer_pubkey: String) -> void:
	print("ChatManager: DC closed with ", peer_pubkey.left(12))
	_add_system_message("切断: " + peer_pubkey.left(12))
	_join_order.erase(peer_pubkey)

	if peer_pubkey == _host_pubkey and not _is_host and _has_joined:
		_handle_host_disconnected()

	_update_status_bar()


func _handle_host_disconnected() -> void:
	_add_system_message("ホスト切断。昇格処理中...")
	NostrGD.CloseSubscription(DISCOVER_SUB_ID)
	var kinds0: Array = [0]
	NostrGD.RequestEventsWithTag(DISCOVER_SUB_ID, kinds0, "s", APP_TAG)

	await get_tree().create_timer(2.0).timeout

	var next_host := ""
	var earliest := 1 << 62
	for ev_variant in _discover_events:
		var ev_dict = ev_variant as Dictionary
		if ev_dict == null:
			continue
		var c = str(ev_dict.get("content", ""))
		var j = JSON.new()
		if j.parse(c) != OK:
			continue
		var d = j.get_data()
		if not d is Dictionary:
			continue
		var r = str(d.get("role", ""))
		var a = str(d.get("app", ""))
		if a != APP_TAG or r != "guest":
			continue
		var pk = str(ev_dict.get("pubkey", ""))
		var cr = int(ev_dict.get("created_at", 1 << 62))
		if cr < earliest:
			earliest = cr
			next_host = pk

	if next_host.is_empty() or next_host == _my_pubkey:
		_promote_to_host()
	else:
		_host_pubkey = next_host
		_add_system_message("新ホスト: " + _host_pubkey.left(12))


func _promote_to_host() -> void:
	_is_host = true
	_host_pubkey = _my_pubkey
	print("ChatManager: Promoted to host!")

	var content_dict := {
		name = _display_name,
		app = APP_TAG,
		role = "host"
	}
	var tags: Array = [["s", APP_TAG]]
	NostrGD.SendCustomEvent(0, JSON.new().stringify(content_dict), tags)

	if not _join_order.has(_my_pubkey):
		_join_order.insert(0, _my_pubkey)

	_add_system_message("あなたが新しいホストになりました")
	_update_status_bar()


func _on_dc_msg_received(msg: Dictionary, peer_pubkey: String) -> void:
	var msg_type = str(msg.get("type", ""))
	if msg_type == "chat":
		var name = str(msg.get("name", peer_pubkey.left(12)))
		var content = str(msg.get("content", ""))
		var ts = int(msg.get("timestamp", 0))
		_add_chat_message(name, content, peer_pubkey, ts)


func _on_send_pressed() -> void:
	if not _has_joined:
		return
	var text := message_input.text.strip_edges()
	if text.is_empty():
		return

	var msg := {
		type = "chat",
		content = text,
		name = _display_name,
		pubkey = _my_pubkey,
		timestamp = int(Time.get_unix_time_from_system())
	}
	var json_str := JSON.new().stringify(msg)

	var tags: Array = [["s", APP_TAG]]
	NostrGD.SendCustomEvent(21000, json_str, tags)

	_wh.send_string(json_str)

	_add_chat_message(_display_name, text, _my_pubkey, Time.get_unix_time_from_system())
	message_input.clear()


func _add_chat_message(name: String, content: String, pubkey: String, timestamp: int) -> void:
	var color := Color(0.4, 0.7, 1.0)
	if pubkey == _host_pubkey:
		color = Color(1.0, 0.8, 0.2)

	var panel := PanelContainer.new()
	var hbox := HBoxContainer.new()
	panel.add_child(hbox)
	panel.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	hbox.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL

	var name_label := Label.new()
	name_label.text = name
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", color)
	name_label.custom_minimum_size = Vector2(100, 0)
	hbox.add_child(name_label)

	var msg_label := Label.new()
	msg_label.text = content
	msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg_label.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	hbox.add_child(msg_label)

	var time_label := Label.new()
	var dt := Time.get_datetime_dict_from_unix_time(timestamp)
	time_label.text = "%02d:%02d" % [dt.hour, dt.minute]
	time_label.add_theme_font_size_override("font_size", 10)
	time_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hbox.add_child(time_label)

	timeline.add_child(panel)
	_scroll_to_bottom()


func _add_system_message(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_FILL
	timeline.add_child(label)
	_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	call_deferred("_deferred_scroll_to_bottom")


func _deferred_scroll_to_bottom() -> void:
	scroll_container.scroll_vertical = scroll_container.get_v_scroll_bar().max_value


func _update_status_bar() -> void:
	if not _subscribed:
		return

	var role_text := ""
	if _is_host:
		role_text = "👑 ホスト"
	elif _has_joined:
		role_text = "ゲスト"
	else:
		role_text = "傍受中"
	var peer_count = _wh.get_connected_peers().size()
	status_label2.text = role_text + " | 接続: " + str(peer_count)
	host_label.text = "" if _host_pubkey.is_empty() else "host: " + _host_pubkey.left(12)
