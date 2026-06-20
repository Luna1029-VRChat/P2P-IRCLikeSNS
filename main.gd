extends Control

const Secp256k1 = preload("res://addons/nostr_godot/secp256k1.gd")
const NostrUtils = preload("res://scripts/nostr_utils.gd")

var _icons: Dictionary = {}

func _get_icon(name: String, size: int = 14) -> Texture2D:
	var key := name + "_" + str(size)
	if _icons.has(key):
		return _icons[key]
	var path := "res://icons/" + name + ".svg"
	if not ResourceLoader.exists(path):
		return null
	var svg := load(path) as Texture2D
	if not svg:
		return null
	var img := svg.get_image()
	if not img:
		return null
	if img.get_width() != size or img.get_height() != size:
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_icons[key] = tex
	return tex

@onready var private_key_input: TextEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/LoginContainer/PrivateKeyInput
@onready var status_label: Label = $Sidebar/SidebarInner/StatusSection/StatusLabel
@onready var message_input: LineEdit = $MainPanel/InputBar/HBoxContainer/MessageInput
@onready var timeline: VBoxContainer = $MainPanel/ScrollContainer/Timeline
@onready var register_name_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterNameInput
@onready var register_display_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterDisplayInput
@onready var register_picture_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterPictureInput
@onready var register_banner_input: LineEdit = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/RegisterBannerInput
@onready var auth_choice_hbox: HBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/AuthChoiceHBox
@onready var login_container: VBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/LoginContainer
@onready var create_container: VBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer
@onready var logged_in_container: VBoxContainer = $Sidebar/SidebarInner/AccountSection/VBoxContainer/LoggedInContainer
@onready var section_header: Label = $MainPanel/SectionHeader/HeaderHBox/HeaderLabel
@onready var hamburger_btn: Button = $MainPanel/SectionHeader/HeaderHBox/HamburgerBtn
@onready var drawer_bg: ColorRect = $DrawerBg
@onready var snackbar_container: PanelContainer = $Snackbar
@onready var snackbar_label: Label = $Snackbar/SnackbarLabel
@onready var sidebar: PanelContainer = $Sidebar
@onready var sidebar_close_btn: Button = $Sidebar/SidebarInner/SidebarTitle/TitleHBox/CloseBtn
@onready var nav_buttons: Array[Button] = [
	$Sidebar/SidebarInner/NavSection/NavMenu/NavTimeline,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavNotifications,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavDM,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavProfile,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavSettings,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavBookmarks
]

enum Section { TIMELINE, NOTIFICATIONS, DM, PROFILE, SETTINGS, BOOKMARKS }
var _current_section: int = Section.TIMELINE

var RELAY_URL: Array[String] = []


var received_event_ids: Dictionary = {}
var profile_cache: Dictionary = {}
var pending_labels: Dictionary = {}
var pubkey_request_pool: Array[String] = []
var pool_timer: Timer
var _profile_request_active: bool = false
var _profile_request_time: int = 0
var _timeline_update_timer: Timer
var _notif_refresh_timer: Timer
var _pending_sorted_timeline: Array = []
var _pending_profile_events: Array[Dictionary] = []
var _relays_timeline_subscribed: Dictionary = {}
const TIMELINE_MAX_ITEMS: int = 50
const MAX_NOTIFICATIONS: int = 20
const MAX_NOTIF_RELAYS: int = 5
const MAX_DM_RELAYS: int = 2
const MAX_TIMELINE_RELAYS: int = 3

enum UIState { LOGGED_OUT, LOGIN_FORM, CREATE_FORM, LOGGED_IN }
var _ui_state: int = UIState.LOGGED_OUT
var _is_profile_edit: bool = false

var _stamp_event_id: String = ""
var _stamp_pubkey: String = ""
var _nav_button_icons: Array = []
var _like_button_cache: Dictionary = {}
var _liked_events: Dictionary = {}
var _avatar_texture_cache: Dictionary = {}
var _image_texture_cache: Dictionary = {}
var _pending_embeds: Dictionary = {}
var _pending_notif_embeds: Dictionary = {}
var _notifications_events: Array = []
var _dm_conversations: Dictionary = {}
var _reply_context: Dictionary = {}
var _reaction_counts: Dictionary = {}
var _stamp_counts: Dictionary = {}
var _timeline_count_labels: Dictionary = {}
var _timeline_panels: Dictionary = {}
var _file_dialog: FileDialog
var _notification_sub_id: String = ""
var _dm_sub_id: String = ""
var _reply_context_label: Label
var _timeline_paused: bool = false
var _last_displayed_count: int = 0
var _last_displayed_ids: Dictionary = {}
var _last_notif_ids: Dictionary = {}
var _bookmarked_events: Array[Dictionary] = []
var _bookmark_sub_id: String = ""
var _bookmark_content_sub_id: String = ""
var _bookmark_loaded_event_ids: Dictionary = {}
var _sidebar_visible: bool = true
var _is_mobile: bool = false
var _bottom_nav: PanelContainer = null
var _bottom_nav_buttons: Array[Button] = []
var _relays_notif_subscribed: Dictionary = {}
var _relays_dm_subscribed: Dictionary = {}
const SIDEBAR_WIDTH: int = 280
const DESKTOP_BREAKPOINT: int = 800
const BOTTOM_NAV_HEIGHT: int = 56
const BTN_MQ: int = 38
const BTN_MQ_TALL: int = 44
var _touch_start_x: float = -1.0
var _touch_start_y: float = -1.0
var _touch_started: bool = false

static func _relay_url(entry: String) -> String:
	return entry.split(" ", false)[0]

static func _relay_can_read(entry: String) -> bool:
	var parts = entry.split(" ", false)
	if parts.size() == 1:
		return true
	return "r" in parts

static func _relay_can_write(entry: String) -> bool:
	var parts = entry.split(" ", false)
	if parts.size() == 1:
		return true
	return "w" in parts

func _ready() -> void:
	_apply_theme()
	_setup_stamp_popup()
	_setup_responsive_layout()
	if _is_mobile:
		_setup_mobile_bottom_nav()

	$MainPanel/ScrollContainer.clip_contents = true
	$MainPanel/ScrollContainer/Timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var img_btn = Button.new()
	img_btn.icon = _get_icon("image")
	img_btn.text = ""
	img_btn.custom_minimum_size = _btn_size(28, 24)
	img_btn.pressed.connect(_on_image_upload_button)
	$MainPanel/InputBar/HBoxContainer.add_child(img_btn)
	$MainPanel/InputBar/HBoxContainer.move_child(img_btn, 0)

	_nav_button_icons = [
		_get_icon("house", 16),
		_get_icon("bell", 16),
		_get_icon("message-square", 16),
		_get_icon("user", 16),
		_get_icon("settings", 16),
		_get_icon("bookmark", 16),
	]
	for i in nav_buttons.size():
		if i < _nav_button_icons.size() and _nav_button_icons[i]:
			nav_buttons[i].icon = _nav_button_icons[i]
		nav_buttons[i].add_theme_color_override("icon_normal_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_hover_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_pressed_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_focus_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_disabled_color", Color.WHITE)

	_reply_context_label = Label.new()
	_reply_context_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
	_reply_context_label.add_theme_font_size_override("font_size", 11)
	_reply_context_label.visible = false
	_reply_context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	$MainPanel/InputBar.add_child(_reply_context_label)
	$MainPanel/InputBar.move_child(_reply_context_label, 0)

	$MainPanel/ScrollContainer.get_v_scroll_bar().value_changed.connect(_on_timeline_scrolled)

	message_input.text_submitted.connect(func(text):
		if not text.strip_edges().is_empty():
			_on_send_button_pressed()
	)

	message_input.gui_input.connect(func(event):
		if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.echo:
			_reply_context = {}
			_reply_context_label.visible = false
			_set_input_placeholder("")
			message_input.release_focus()
	)

	$Sidebar/SidebarInner/AccountSection/VBoxContainer/LoggedInContainer/DisconnectButton.visible = false

	NostrGD.Connected.connect(_on_nostr_connected)
	NostrGD.Disconnected.connect(_on_nostr_disconnected)
	NostrGD.EventReceived.connect(_on_nostr_event_received)
	NostrGD.NoticeReceived.connect(_on_nostr_notice)
	NostrGD.ExtensionAuthCompleted.connect(_on_extension_auth_completed)
	NostrGD.TimelineUpdated.connect(_on_nostr_timeline_updated)
	NostrGD.ReactionReceived.connect(_on_nostr_reaction_received)
	NostrGD.DirectMessageReceived.connect(_on_nostr_direct_message_received)

	pool_timer = Timer.new()
	pool_timer.wait_time = 1.0
	pool_timer.autostart = false
	pool_timer.one_shot = false
	pool_timer.timeout.connect(_on_pool_timer_timeout)
	add_child(pool_timer)

	_timeline_update_timer = Timer.new()
	_timeline_update_timer.wait_time = 0.3
	_timeline_update_timer.one_shot = true
	_timeline_update_timer.timeout.connect(_apply_timeline_update)
	add_child(_timeline_update_timer)

	_notif_refresh_timer = Timer.new()
	_notif_refresh_timer.wait_time = 0.3
	_notif_refresh_timer.one_shot = true
	_notif_refresh_timer.timeout.connect(_refresh_notifications)
	add_child(_notif_refresh_timer)

	var saved_relays = NostrGD.LoadRelayUrls()
	if saved_relays.size() > 0:
		for url in saved_relays:
			RELAY_URL.append(url)
	else:
		var default_relays = [
			"wss://relay-jp.nostr.wirednet.jp/",
			"wss://nrelay-jp.nostr.wirednet.jp/",
			"wss://yabu.me/",
			"wss://nos.lol/",
			"wss://relay.nostr.band/",
		]
		for url in default_relays:
			RELAY_URL.append(url)
		NostrGD.SaveRelayUrls(default_relays)

	var saved_key = _load_private_key()
	if not saved_key.is_empty():
		private_key_input.text = saved_key
		if NostrGD.Login(saved_key):
			_set_ui_state(UIState.LOGGED_IN)
			status_label.text = "自動ログイン完了"
			NostrGD.TryInitNWC()
		else:
			_set_ui_state(UIState.LOGGED_OUT)
			status_label.text = "未ログイン"
	else:
		_set_ui_state(UIState.LOGGED_OUT)
		status_label.text = "未ログイン"

	_build_sections()
	_switch_section(Section.TIMELINE)
	_load_bookmarks()
	if NostrGD.IsLoggedIn:
		_update_settings_nsec_field()
		_refresh_profile()

	_connect_relays()

func _apply_theme() -> void:
	var window_bg = StyleBoxFlat.new()
	window_bg.bg_color = Color(0.09, 0.1, 0.12)

	var panel_bg = StyleBoxFlat.new()
	panel_bg.bg_color = Color(0.11, 0.12, 0.14)
	panel_bg.border_width_bottom = 1
	panel_bg.border_color = Color(0.18, 0.19, 0.22)

	var input_bg = StyleBoxFlat.new()
	input_bg.bg_color = Color(0.14, 0.15, 0.17)
	input_bg.border_width_bottom = 1
	input_bg.border_color = Color(0.25, 0.26, 0.3)

	var btn_bg = StyleBoxFlat.new()
	btn_bg.bg_color = Color(0.25, 0.45, 0.7)
	btn_bg.corner_radius_top_left = 4
	btn_bg.corner_radius_top_right = 4
	btn_bg.corner_radius_bottom_right = 4
	btn_bg.corner_radius_bottom_left = 4

	var btn_bg_hover = StyleBoxFlat.new()
	btn_bg_hover.bg_color = Color(0.3, 0.5, 0.8)
	btn_bg_hover.corner_radius_top_left = 4
	btn_bg_hover.corner_radius_top_right = 4
	btn_bg_hover.corner_radius_bottom_right = 4
	btn_bg_hover.corner_radius_bottom_left = 4

	var btn_bg_pressed = StyleBoxFlat.new()
	btn_bg_pressed.bg_color = Color(0.2, 0.35, 0.6)
	btn_bg_pressed.corner_radius_top_left = 4
	btn_bg_pressed.corner_radius_top_right = 4
	btn_bg_pressed.corner_radius_bottom_right = 4
	btn_bg_pressed.corner_radius_bottom_left = 4

	var sidebar_section = StyleBoxFlat.new()
	sidebar_section.bg_color = Color(0.1, 0.11, 0.13)
	sidebar_section.content_margin_left = 12
	sidebar_section.content_margin_right = 12
	sidebar_section.content_margin_top = 12
	sidebar_section.content_margin_bottom = 12

	var title_bar_bg = StyleBoxFlat.new()
	title_bar_bg.bg_color = Color(0.05, 0.06, 0.08)
	title_bar_bg.border_width_bottom = 1
	title_bar_bg.border_color = Color(0.2, 0.22, 0.25)

	var status_bg = StyleBoxFlat.new()
	status_bg.bg_color = Color(0.08, 0.09, 0.11)
	status_bg.content_margin_left = 12
	status_bg.content_margin_right = 12
	status_bg.content_margin_top = 8
	status_bg.content_margin_bottom = 12

	var timeline_header_bg = StyleBoxFlat.new()
	timeline_header_bg.bg_color = Color(0.05, 0.06, 0.08)
	timeline_header_bg.border_width_bottom = 1
	timeline_header_bg.border_color = Color(0.2, 0.22, 0.25)

	var input_bar_bg = StyleBoxFlat.new()
	input_bar_bg.bg_color = Color(0.08, 0.09, 0.11)
	input_bar_bg.border_width_top = 1
	input_bar_bg.border_color = Color(0.2, 0.22, 0.25)
	input_bar_bg.content_margin_left = 8
	input_bar_bg.content_margin_right = 8
	input_bar_bg.content_margin_top = 6
	input_bar_bg.content_margin_bottom = 6

	$Sidebar.add_theme_stylebox_override("panel", panel_bg)
	$Sidebar/SidebarInner/SidebarTitle.add_theme_stylebox_override("panel", title_bar_bg)
	$Sidebar/SidebarInner/StatusSection.add_theme_stylebox_override("panel", status_bg)
	$MainPanel/SectionHeader.add_theme_stylebox_override("panel", timeline_header_bg)
	$MainPanel/InputBar.add_theme_stylebox_override("panel", input_bar_bg)
	timeline.add_theme_constant_override("separation", 8)

	for btn in [$Sidebar/SidebarInner/AccountSection/VBoxContainer/AuthChoiceHBox/LoginChoiceBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/AuthChoiceHBox/CreateChoiceBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/LoginContainer/LoginConfirmBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateBackBtn,
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/ExtensionLogin,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavTimeline,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavNotifications,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavDM,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavProfile,
		$Sidebar/SidebarInner/NavSection/NavMenu/NavSettings,
		$MainPanel/InputBar/HBoxContainer/SendButton]:
		btn.add_theme_stylebox_override("normal", btn_bg)
		btn.add_theme_stylebox_override("hover", btn_bg_hover)
		btn.add_theme_stylebox_override("pressed", btn_bg_pressed)
		btn.add_theme_color_override("font_color", Color(1, 1, 1))

func _save_private_key(key: String) -> void:
	NostrGD.SavePrivateKey(key)
	print("NostrGD: 秘密鍵を保存しました。")

func _load_private_key() -> String:
	return NostrGD.LoadPrivateKey()

func _on_nostr_connected(url: String) -> void:
	status_label.text = "接続完了"

	if not pool_timer.is_processing():
		pool_timer.start()

	if _relays_timeline_subscribed.size() < MAX_TIMELINE_RELAYS and not _relays_timeline_subscribed.has(url):
		for entry in RELAY_URL:
			if _relay_url(entry) == url and _relay_can_read(entry):
				_relays_timeline_subscribed[url] = true
				NostrGD.RequestTimeline("global_feed", 50, url)
				break

	if NostrGD.IsLoggedIn:
		if not _notification_sub_id.is_empty() and not _relays_notif_subscribed.has(url):
			var sub_count = 0
			for _k in _relays_notif_subscribed: sub_count += 1
			if sub_count < MAX_NOTIF_RELAYS:
				for entry in RELAY_URL:
					if _relay_url(entry) == url and _relay_can_read(entry):
						_relays_notif_subscribed[url] = true
						var pubkey = NostrGD.GetPublicKeyHex()
						NostrGD.RequestNotificationsForRelay(_notification_sub_id, pubkey, url)
						break
		if not _dm_sub_id.is_empty() and not _relays_dm_subscribed.has(url):
			var sub_count = 0
			for _k in _relays_dm_subscribed: sub_count += 1
			if sub_count < MAX_DM_RELAYS:
				for entry in RELAY_URL:
					if _relay_url(entry) == url and _relay_can_read(entry):
						_relays_dm_subscribed[url] = true
						var pubkey = NostrGD.GetPublicKeyHex()
						NostrGD.RequestDirectMessagesForRelay(_dm_sub_id, pubkey, url)
						break

func _on_nostr_disconnected(url: String) -> void:
	_relays_timeline_subscribed.erase(url)
	_relays_notif_subscribed.erase(url)
	_relays_dm_subscribed.erase(url)

func _input(event: InputEvent) -> void:
	if not _is_mobile:
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_start_x = event.position.x
			_touch_start_y = event.position.y
			_touch_started = true
		elif _touch_started:
			var dx = event.position.x - _touch_start_x
			var dy = event.position.y - _touch_start_y
			_touch_started = false
			if abs(dx) > 50 and abs(dx) > abs(dy) * 2:
				if dx > 0 and not _sidebar_visible:
					_sidebar_visible = true
					_update_sidebar_state()
				elif dx < 0 and _sidebar_visible:
					_sidebar_visible = false
					_update_sidebar_state()

func _setup_responsive_layout() -> void:
	var vp = get_viewport()
	_is_mobile = vp.size.x < DESKTOP_BREAKPOINT
	_sidebar_visible = not _is_mobile
	_update_sidebar_state()
	$DrawerBg.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_sidebar_close_pressed()
	)
	get_tree().root.size_changed.connect(_on_viewport_resized)

func _setup_mobile_bottom_nav() -> void:
	if _bottom_nav != null:
		_bottom_nav.queue_free()
		_bottom_nav_buttons.clear()
	_bottom_nav = PanelContainer.new()
	_bottom_nav.name = "BottomNav"
	_bottom_nav.anchor_right = 1.0
	_bottom_nav.anchor_bottom = 1.0
	_bottom_nav.offset_top = -BOTTOM_NAV_HEIGHT
	_bottom_nav.offset_bottom = 0
	_bottom_nav.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.11, 0.12, 0.14)
	bg.corner_radius_top_left = 8
	bg.corner_radius_top_right = 8
	_bottom_nav.add_theme_stylebox_override("panel", bg)
	var hbox := HBoxContainer.new()
	hbox.anchor_right = 1.0
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_bottom_nav.add_child(hbox)
	var icon_names := ["house", "bell", "message-square", "user", "bookmark", "settings"]
	for i in icon_names.size():
		var btn := Button.new()
		btn.flat = true
		btn.icon = _get_icon(icon_names[i], 20)
		btn.tooltip_text = ["タイムライン", "通知", "DM", "プロフィール", "ブックマーク", "設定"][i]
		btn.custom_minimum_size = Vector2(0, BOTTOM_NAV_HEIGHT)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var section_index = [Section.TIMELINE, Section.NOTIFICATIONS, Section.DM, Section.PROFILE, Section.BOOKMARKS, Section.SETTINGS][i]
		btn.pressed.connect(_on_bottom_nav_pressed.bind(section_index))
		hbox.add_child(btn)
		_bottom_nav_buttons.append(btn)
	_update_bottom_nav_highlight()
	add_child(_bottom_nav)

func _update_bottom_nav_highlight() -> void:
	if _bottom_nav_buttons.is_empty():
		return
	for i in _bottom_nav_buttons.size():
		var btn = _bottom_nav_buttons[i]
		var section_map := [Section.TIMELINE, Section.NOTIFICATIONS, Section.DM, Section.PROFILE, Section.BOOKMARKS, Section.SETTINGS]
		var idx = section_map.find(_current_section)
		if i == idx:
			btn.add_theme_color_override("icon_normal_color", Color(0.4, 0.7, 1.0))
		else:
			btn.add_theme_color_override("icon_normal_color", Color(0.5, 0.5, 0.6))

func _on_bottom_nav_pressed(section: int) -> void:
	if _is_mobile and _sidebar_visible:
		_sidebar_visible = false
		_update_sidebar_state()
	_switch_section(section)

func _on_viewport_resized() -> void:
	var vp_w = get_viewport().size.x
	var was_mobile = _is_mobile
	_is_mobile = vp_w < DESKTOP_BREAKPOINT
	if _is_mobile and _sidebar_visible:
		_sidebar_visible = false
		_update_sidebar_state()
	elif not _is_mobile and not _sidebar_visible:
		_sidebar_visible = true
		_update_sidebar_state()
	if _is_mobile and not was_mobile:
		_setup_mobile_bottom_nav()
		if _ui_state == UIState.LOGGED_IN:
			$MainPanel/InputBar.visible = (_current_section == Section.TIMELINE)
	elif not _is_mobile and was_mobile:
		if _bottom_nav != null:
			_bottom_nav.queue_free()
			_bottom_nav = null
			_bottom_nav_buttons.clear()
		$MainPanel/InputBar.visible = (_ui_state == UIState.LOGGED_IN and _current_section == Section.TIMELINE)

func _on_hamburger_pressed() -> void:
	_sidebar_visible = not _sidebar_visible
	_update_sidebar_state()

func _on_sidebar_close_pressed() -> void:
	_sidebar_visible = false
	_update_sidebar_state()

func _update_sidebar_state() -> void:
	sidebar.visible = _sidebar_visible
	drawer_bg.visible = _is_mobile and _sidebar_visible
	hamburger_btn.visible = not _is_mobile or not _sidebar_visible
	sidebar_close_btn.visible = _is_mobile
	var main_panel = $MainPanel
	if _is_mobile:
		sidebar.offset_left = 0
		sidebar.offset_right = SIDEBAR_WIDTH
		main_panel.offset_left = 0
		main_panel.offset_bottom = 0
		if _bottom_nav != null:
			_bottom_nav.visible = true
			_bottom_nav.offset_left = 0
			_bottom_nav.offset_right = 0
	else:
		if _bottom_nav != null:
			_bottom_nav.visible = false
		main_panel.offset_bottom = 0
		if _sidebar_visible:
			sidebar.offset_left = 0
			sidebar.offset_right = SIDEBAR_WIDTH
			main_panel.offset_left = SIDEBAR_WIDTH
		else:
			sidebar.offset_left = -SIDEBAR_WIDTH
			sidebar.offset_right = 0
			main_panel.offset_left = 0

func _set_ui_state(state: int) -> void:
	_ui_state = state
	auth_choice_hbox.visible = (state == UIState.LOGGED_OUT)
	login_container.visible = (state == UIState.LOGIN_FORM)
	create_container.visible = (state == UIState.CREATE_FORM)
	logged_in_container.visible = (state == UIState.LOGGED_IN)
	if _is_mobile:
		$MainPanel/InputBar.visible = (state == UIState.LOGGED_IN and _current_section == Section.TIMELINE)
	else:
		$MainPanel/InputBar.visible = (state == UIState.LOGGED_IN)
	$Sidebar/SidebarInner/AccountSection/VBoxContainer/ExtensionLogin.visible = (state != UIState.LOGGED_IN)

	if state == UIState.LOGGED_IN:
		var acct_hbox = logged_in_container.get_node_or_null("AccountHBox")
		if acct_hbox == null:
			acct_hbox = HBoxContainer.new()
			acct_hbox.name = "AccountHBox"
			acct_hbox.add_theme_constant_override("separation", 4)
			var acct_label = Label.new()
			acct_label.name = "AccountLabel"
			acct_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			acct_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
			acct_label.add_theme_font_size_override("font_size", 11)
			acct_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			acct_hbox.add_child(acct_label)
			var copy_btn = Button.new()
			copy_btn.name = "AccountCopyBtn"
			copy_btn.text = "コピー"
			copy_btn.custom_minimum_size = _btn_size(50, 24)
			copy_btn.add_theme_font_size_override("font_size", 10)
			copy_btn.pressed.connect(_copy_account_pubkey)
			acct_hbox.add_child(copy_btn)
			logged_in_container.add_child(acct_hbox)
			logged_in_container.move_child(acct_hbox, 0)
		if NostrGD.IsLoggedIn:
			var pk_hex = NostrGD.GetPublicKeyHex()
			var npub = Secp256k1.npub_encode(pk_hex)
			var acct_label = acct_hbox.get_node("AccountLabel") as Label
			acct_label.text = npub.left(24) + "..."
		if _notification_sub_id.is_empty():
			_notification_sub_id = "notif_" + NostrGD.GetPublicKeyHex().left(8)
			_dm_sub_id = "dm_" + NostrGD.GetPublicKeyHex().left(8)
			_bookmark_sub_id = "bm_" + NostrGD.GetPublicKeyHex().left(8)
			_bookmark_content_sub_id = "bmc_" + NostrGD.GetPublicKeyHex().left(8)
			_notifications_events.clear()
			_last_notif_ids = {}
			_dm_conversations.clear()
		_start_notification_subscription()
		_start_dm_subscription()
		_start_bookmark_subscription()
	else:
		_relays_notif_subscribed.clear()
		_relays_dm_subscribed.clear()
		_last_notif_ids = {}
		if not _notification_sub_id.is_empty():
			NostrGD.CloseSubscription(_notification_sub_id)
			_notification_sub_id = ""
		if not _dm_sub_id.is_empty():
			NostrGD.CloseSubscription(_dm_sub_id)
			_dm_sub_id = ""

func _on_show_login_form() -> void:
	_set_ui_state(UIState.LOGIN_FORM)

func _on_show_create_form() -> void:
	_set_ui_state(UIState.CREATE_FORM)

func _on_back_to_auth_choice() -> void:
	_is_profile_edit = false
	$Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn.text = "作成"
	if NostrGD.IsLoggedIn:
		_set_ui_state(UIState.LOGGED_IN)
	else:
		_set_ui_state(UIState.LOGGED_OUT)

func _connect_relays() -> void:
	for entry in RELAY_URL:
		NostrGD.ConnectToRelay(_relay_url(entry))
	NostrGD.ActivateRelayProcessing()

func _build_sections() -> void:
	_build_notifications_section()
	_build_dm_section()
	_build_profile_section()
	_build_settings_section()
	_build_bookmarks_section()

func _build_notifications_section() -> void:
	var panel = $MainPanel/NotificationsPanel
	var scroll = ScrollContainer.new()
	scroll.name = "NotifScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var vbox = VBoxContainer.new()
	vbox.name = "NotifList"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(vbox)

func _build_dm_section() -> void:
	var panel = $MainPanel/DMPanel
	var scroll = ScrollContainer.new()
	scroll.name = "DMScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var vbox = VBoxContainer.new()
	vbox.name = "DMList"
	vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(vbox)

	var input_hbox = HBoxContainer.new()
	input_hbox.name = "DMInputBar"
	panel.add_child(input_hbox)

	var dm_pk = LineEdit.new()
	dm_pk.name = "DMPubkey"
	dm_pk.placeholder_text = "送信先 pubkey hex"
	dm_pk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_hbox.add_child(dm_pk)

	var dm_input = LineEdit.new()
	dm_input.name = "DMMessage"
	dm_input.placeholder_text = "DMを入力..."
	dm_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_hbox.add_child(dm_input)

	var dm_send = Button.new()
	dm_send.name = "DMSendButton"
	dm_send.text = "送信"
	dm_send.pressed.connect(_on_dm_send)
	input_hbox.add_child(dm_send)

func _build_profile_section() -> void:
	var panel = $MainPanel/ProfilePanel
	if panel.get_child_count() > 0:
		return

	var banner_height = 120 if _is_mobile else 200
	var avatar_size = 60 if _is_mobile else 80
	var banner = TextureRect.new()
	banner.name = "ProfileBanner"
	banner.custom_minimum_size = Vector2(0, banner_height)
	banner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	banner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	banner.clip_contents = true
	panel.add_child(banner)

	var scroll = ScrollContainer.new()
	scroll.name = "ProfileScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var margin = MarginContainer.new()
	margin.name = "ProfileMargin"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "ProfileVBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var header_hbox = HBoxContainer.new()
	header_hbox.name = "ProfileHeader"
	header_hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(header_hbox)

	var arect = TextureRect.new()
	arect.name = "ProfileAvatar"
	arect.custom_minimum_size = Vector2(avatar_size, avatar_size)
	arect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	arect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	arect.clip_contents = true
	arect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	header_hbox.add_child(arect)

	var name_vbox = VBoxContainer.new()
	name_vbox.name = "ProfileNameSection"
	name_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_hbox.add_child(name_vbox)

	var nl = Label.new()
	nl.name = "ProfileName"
	nl.add_theme_font_size_override("font_size", 22)
	name_vbox.add_child(nl)

	var al = Label.new()
	al.name = "ProfileAbout"
	al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	al.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	name_vbox.add_child(al)

	var pl = Label.new()
	pl.name = "ProfilePubkey"
	pl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(pl)

	var eb = Button.new()
	eb.text = "プロフィールを編集"
	eb.pressed.connect(_on_profile_edit)
	vbox.add_child(eb)

	var cb = Button.new()
	cb.text = "Pubkey をコピー"
	cb.pressed.connect(func():
		_safe_clipboard_set(NostrGD.GetPublicKeyHex())
		status_label.text = "Pubkey をコピーしました"
	)
	vbox.add_child(cb)

func _build_settings_section() -> void:
	var panel = $MainPanel/SettingsPanel
	var scroll = ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var margin = MarginContainer.new()
	margin.name = "SettingsMargin"
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "SettingsVBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var relay_title = Label.new()
	relay_title.text = "接続リレー"
	relay_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(relay_title)

	var relay_edit = TextEdit.new()
	relay_edit.name = "RelayEdit"
	relay_edit.placeholder_text = "ws://localhost:8080 r w"
	relay_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	relay_edit.custom_minimum_size = Vector2(0, 120)
	for entry in RELAY_URL:
		relay_edit.text += entry + "\n"
	vbox.add_child(relay_edit)

	var relay_hint = Label.new()
	relay_hint.text = "1行に1つ: <url> r(読込) w(書込)  rとwは省略可能"
	relay_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	relay_hint.add_theme_font_size_override("font_size", 10)
	vbox.add_child(relay_hint)

	var relay_save_btn = Button.new()
	relay_save_btn.text = "リレー保存・再接続"
	relay_save_btn.custom_minimum_size = Vector2(0, 40) if _is_mobile else Vector2(0, 32)
	relay_save_btn.pressed.connect(_on_save_relays)
	vbox.add_child(relay_save_btn)

	var nsec_title = Label.new()
	nsec_title.text = "秘密鍵 (nsec)"
	nsec_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(nsec_title)

	var nsec_hbox = HBoxContainer.new()
	nsec_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(nsec_hbox)

	var nsec_input = LineEdit.new()
	nsec_input.name = "SettingsNsecInput"
	nsec_input.placeholder_text = "nsec1..."
	nsec_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nsec_input.custom_minimum_size = Vector2(0, 32)
	nsec_input.secret = true
	if NostrGD.IsLoggedIn:
		nsec_input.text = NostrGD.GetPrivateKeyNsec()
	nsec_hbox.add_child(nsec_input)

	var nsec_toggle_btn = Button.new()
	nsec_toggle_btn.name = "SettingsNsecToggle"
	nsec_toggle_btn.text = "表示"
	nsec_toggle_btn.custom_minimum_size = _btn_size(50, 32)
	nsec_toggle_btn.pressed.connect(func():
		var inp = nsec_hbox.get_node("SettingsNsecInput") as LineEdit
		var btn = nsec_hbox.get_node("SettingsNsecToggle") as Button
		inp.secret = not inp.secret
		btn.text = "隠す" if not inp.secret else "表示"
	)
	nsec_hbox.add_child(nsec_toggle_btn)

	var nsec_copy_btn = Button.new()
	nsec_copy_btn.text = "コピー"
	nsec_copy_btn.custom_minimum_size = _btn_size(50, 32)
	nsec_copy_btn.pressed.connect(func():
		if NostrGD.IsLoggedIn:
			_safe_clipboard_set(NostrGD.GetPrivateKeyNsec())
			status_label.text = "nsec をコピーしました"
	)
	nsec_hbox.add_child(nsec_copy_btn)

	vbox.add_child(HSeparator.new())

	var filter_title = Label.new()
	filter_title.text = "表示フィルター"
	filter_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(filter_title)

	var filter_hbox = HBoxContainer.new()
	filter_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(filter_hbox)

	var filter_label = Label.new()
	filter_label.text = "日本語のみ表示"
	filter_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_hbox.add_child(filter_label)

	var filter_toggle = CheckButton.new()
	filter_toggle.name = "JapaneseFilterToggle"
	filter_toggle.button_pressed = NostrGD.JapaneseFilterEnabled
	filter_toggle.toggled.connect(func(enabled):
		NostrGD.SetJapaneseFilterEnabled(enabled)
		_last_displayed_count = 0
		_last_displayed_ids = {}
		status_label.text = "日本語フィルター: " + ("ON" if enabled else "OFF")
	)
	filter_hbox.add_child(filter_toggle)

	var about = Label.new()
	about.text = "NostrGD Client\nGodot 4 + .NET 8 + Nostr SDK"
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(about)

	vbox.add_child(HSeparator.new())

	var disconnect_btn = Button.new()
	disconnect_btn.text = "切断してログアウト"
	disconnect_btn.icon = _get_icon("plug", 14)
	disconnect_btn.pressed.connect(_on_disconnect_button_pressed)
	vbox.add_child(disconnect_btn)

func _on_save_relays() -> void:
	var panel = $MainPanel/SettingsPanel
	var relay_edit = panel.get_node_or_null("SettingsScroll/SettingsMargin/SettingsVBox/RelayEdit") as TextEdit
	if relay_edit == null:
		return
	var new_relays: Array[String] = []
	for line in relay_edit.text.split("\n"):
		var trimmed = line.strip_edges()
		if trimmed.is_empty():
			continue
		var parts = trimmed.split(" ", false)
		if parts.is_empty():
			continue
		var url = parts[0]
		if not url.begins_with("ws://") and not url.begins_with("wss://"):
			status_label.text = "スキップ(無効なURL): " + url
			continue
		new_relays.append(trimmed)
	for entry in RELAY_URL:
		NostrGD.DisconnectFromRelay(_relay_url(entry))
	RELAY_URL = new_relays
	NostrGD.SaveRelayUrls(RELAY_URL)
	_relays_timeline_subscribed.clear()
	_relays_notif_subscribed.clear()
	_relays_dm_subscribed.clear()
	_pending_sorted_timeline.clear()
	_pending_profile_events.clear()
	for child in timeline.get_children():
		child.queue_free()
	pending_labels.clear()
	_pending_embeds.clear()
	_notifications_events.clear()
	_last_notif_ids = {}
	_connect_relays()
	status_label.text = "リレー設定を保存・再接続しました"

func _build_bookmarks_section() -> void:
	var panel = $MainPanel/BookmarksPanel
	var scroll = ScrollContainer.new()
	scroll.name = "BookmarkScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var vbox = VBoxContainer.new()
	vbox.name = "BookmarkList"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(vbox)

func _switch_section(section: int) -> void:
	_current_section = section

	if _ui_state == UIState.CREATE_FORM and NostrGD.IsLoggedIn:
		_is_profile_edit = false
		_ui_state = UIState.LOGGED_IN
		auth_choice_hbox.visible = false
		login_container.visible = false
		create_container.visible = false
		logged_in_container.visible = true
		$Sidebar/SidebarInner/AccountSection/VBoxContainer/ExtensionLogin.visible = false
		var confirm_btn = $Sidebar/SidebarInner/AccountSection/VBoxContainer/CreateContainer/CreateBtnHBox/CreateConfirmBtn
		if confirm_btn and is_instance_valid(confirm_btn):
			confirm_btn.text = "作成"

	$MainPanel/ScrollContainer.hide()
	$MainPanel/NotificationsPanel.hide()
	$MainPanel/DMPanel.hide()
	$MainPanel/ProfilePanel.hide()
	$MainPanel/SettingsPanel.hide()
	$MainPanel/BookmarksPanel.hide()

	var names = {
		Section.TIMELINE: "タイムライン",
		Section.NOTIFICATIONS: "通知",
		Section.DM: "DM",
		Section.PROFILE: "プロフィール",
		Section.SETTINGS: "設定",
		Section.BOOKMARKS: "ブックマーク"
	}
	section_header.text = names.get(section, "セクション")

	match section:
		Section.TIMELINE:
			$MainPanel/ScrollContainer.show()
			if not _is_mobile:
				$MainPanel/InputBar.visible = (_ui_state == UIState.LOGGED_IN)
		Section.NOTIFICATIONS:
			$MainPanel/NotificationsPanel.show()
			$MainPanel/InputBar.hide()
			_refresh_notifications()
		Section.DM:
			$MainPanel/DMPanel.show()
			$MainPanel/InputBar.hide()
			_refresh_dms()
		Section.PROFILE:
			$MainPanel/ProfilePanel.show()
			$MainPanel/InputBar.hide()
			_refresh_profile()
		Section.SETTINGS:
			$MainPanel/SettingsPanel.show()
			$MainPanel/InputBar.hide()
		Section.BOOKMARKS:
			$MainPanel/BookmarksPanel.show()
			$MainPanel/InputBar.hide()
			_refresh_bookmarks()

	_update_nav_highlight()
	_update_bottom_nav_highlight()

	if _is_mobile:
		if section == Section.TIMELINE and _ui_state == UIState.LOGGED_IN:
			$MainPanel/InputBar.visible = true
		else:
			$MainPanel/InputBar.visible = false

func _refresh_profile() -> void:
	var panel = $MainPanel/ProfilePanel
	var name_label = panel.get_node_or_null("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileNameSection/ProfileName")
	if name_label == null:
		for c in panel.get_children():
			panel.remove_child(c)
			c.free()
		var banner_height2 = 120 if _is_mobile else 200
		var banner = TextureRect.new()
		banner.name = "ProfileBanner"
		banner.custom_minimum_size = Vector2(0, banner_height2)
		banner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		banner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		banner.clip_contents = true
		panel.add_child(banner)
		var scroll = ScrollContainer.new()
		scroll.name = "ProfileScroll"
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_child(scroll)
		var margin = MarginContainer.new()
		margin.name = "ProfileMargin"
		margin.add_theme_constant_override("margin_left", 16)
		margin.add_theme_constant_override("margin_right", 16)
		margin.add_theme_constant_override("margin_top", 16)
		margin.add_theme_constant_override("margin_bottom", 16)
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(margin)
		var vbox = VBoxContainer.new()
		vbox.name = "ProfileVBox"
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 8)
		margin.add_child(vbox)
		var hbox = HBoxContainer.new()
		hbox.name = "ProfileHeader"
		hbox.add_theme_constant_override("separation", 16)
		vbox.add_child(hbox)
		var arect = TextureRect.new()
		arect.name = "ProfileAvatar"
		arect.custom_minimum_size = Vector2(80, 80)
		arect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		arect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		arect.clip_contents = true
		arect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		arect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		hbox.add_child(arect)
		var nvbox = VBoxContainer.new()
		nvbox.name = "ProfileNameSection"
		nvbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nvbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hbox.add_child(nvbox)
		var nl = Label.new()
		nl.name = "ProfileName"
		nl.add_theme_font_size_override("font_size", 22)
		nvbox.add_child(nl)
		var al = Label.new()
		al.name = "ProfileAbout"
		al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		al.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		nvbox.add_child(al)
		var pl = Label.new()
		pl.name = "ProfilePubkey"
		pl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(pl)
		var eb = Button.new()
		eb.text = "プロフィールを編集"
		eb.pressed.connect(_on_profile_edit)
		vbox.add_child(eb)
		var cb = Button.new()
		cb.text = "Pubkey をコピー"
		cb.pressed.connect(func():
			_safe_clipboard_set(NostrGD.GetPublicKeyHex())
			status_label.text = "Pubkey をコピーしました"
		)
		vbox.add_child(cb)
		name_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileNameSection/ProfileName")
	var name_vbox = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileNameSection")
	var about_label = name_vbox.get_node("ProfileAbout")
	var pubkey_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfilePubkey")
	var avatar_rect = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileHeader/ProfileAvatar")
	var banner_rect = panel.get_node_or_null("ProfileBanner")

	if not NostrGD.IsLoggedIn:
		name_label.text = "ログインが必要です"
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	var profile = profile_cache.get(pubkey, {})
	if not profile is Dictionary or profile.is_empty():
		name_label.text = "プロフィールを読み込み中..."
		pubkey_label.text = "Pubkey: " + pubkey
		if not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)
		if not pool_timer.is_processing():
			pool_timer.start()
		return

	name_label.text = profile.get("display_name", profile.get("name", "Unknown"))
	about_label.text = profile.get("about", "")
	pubkey_label.text = "Pubkey: " + pubkey

	var avatar_url = profile.get("picture", "")
	if avatar_url != "":
		_load_and_apply_avatar(avatar_url, avatar_rect)

	var banner_url = profile.get("banner", "")
	if banner_url != "" and banner_rect != null:
		_load_and_apply_banner(banner_url, banner_rect)

func _on_profile_edit() -> void:
	_is_profile_edit = true
	var panel = $MainPanel/ProfilePanel
	var vbox = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox")
	for c in vbox.get_children():
		if c.name != "ProfileHeader":
			vbox.remove_child(c)
			c.queue_free()
	var profile = profile_cache.get(NostrGD.GetPublicKeyHex(), {})
	var name_val = profile.get("name", "")
	if name_val.begins_with("@"):
		name_val = name_val.substr(1)
	var display_val = profile.get("display_name", "")
	var about_val = profile.get("about", "")

	var name_inp = LineEdit.new()
	name_inp.name = "EditName"
	name_inp.placeholder_text = "ユーザー名 (例: @user)"
	name_inp.text = "@" + name_val
	vbox.add_child(name_inp)

	var display_inp = LineEdit.new()
	display_inp.name = "EditDisplay"
	display_inp.placeholder_text = "表示名"
	display_inp.text = display_val
	vbox.add_child(display_inp)

	var about_inp = LineEdit.new()
	about_inp.name = "EditAbout"
	about_inp.placeholder_text = "自己紹介"
	about_inp.text = about_val
	vbox.add_child(about_inp)

	var picture_inp = LineEdit.new()
	picture_inp.name = "EditPicture"
	picture_inp.placeholder_text = "アイコン画像 URL"
	picture_inp.text = profile.get("picture", "")
	vbox.add_child(picture_inp)

	var banner_inp = LineEdit.new()
	banner_inp.name = "EditBanner"
	banner_inp.placeholder_text = "ヘッダー画像 URL"
	banner_inp.text = profile.get("banner", "")
	vbox.add_child(banner_inp)

	var btn_hbox = HBoxContainer.new()
	btn_hbox.name = "EditButtons"
	btn_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_hbox)

	var save_btn = Button.new()
	save_btn.text = "保存"
	save_btn.pressed.connect(_save_profile_from_tab)
	btn_hbox.add_child(save_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "キャンセル"
	cancel_btn.pressed.connect(_cancel_profile_edit)
	btn_hbox.add_child(cancel_btn)


func _save_profile_from_tab() -> void:
	var panel = $MainPanel/ProfilePanel
	var vbox = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox")
	var name_inp = vbox.get_node("EditName") as LineEdit
	var display_inp = vbox.get_node("EditDisplay") as LineEdit
	var about_inp = vbox.get_node("EditAbout") as LineEdit
	var picture_inp = vbox.get_node("EditPicture") as LineEdit
	var banner_inp = vbox.get_node("EditBanner") as LineEdit
	if name_inp == null or display_inp == null:
		return
	var user_name = name_inp.text.strip_edges()
	var display_name = display_inp.text.strip_edges()
	if user_name.is_empty() or display_name.is_empty():
		status_label.text = "エラー: ユーザー名と表示名を入力してください"
		return
	if user_name.begins_with("@"):
		user_name = user_name.substr(1)
	_is_profile_edit = false
	NostrGD.SendProfileMetaData(
		user_name, display_name, about_inp.text.strip_edges(),
		picture_inp.text.strip_edges(),
		banner_inp.text.strip_edges()
	)
	profile_cache[NostrGD.GetPublicKeyHex()] = {
		"name": user_name,
		"display_name": display_name,
		"about": about_inp.text.strip_edges(),
		"picture": picture_inp.text.strip_edges(),
		"banner": banner_inp.text.strip_edges()
	}
	for c in panel.get_children():
		panel.remove_child(c)
		c.queue_free()
	_build_profile_section()
	_refresh_profile()
	status_label.text = "プロフィールを更新しました"

func _cancel_profile_edit() -> void:
	_is_profile_edit = false
	var panel = $MainPanel/ProfilePanel
	for c in panel.get_children():
		panel.remove_child(c)
		c.queue_free()
	_build_profile_section()
	_refresh_profile()

func _update_nav_highlight() -> void:
	for i in nav_buttons.size():
		var btn = nav_buttons[i]
		if i == _current_section:
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
			var bg = StyleBoxFlat.new()
			bg.bg_color = Color(0.25, 0.45, 0.7, 0.3)
			btn.add_theme_stylebox_override("normal", bg)
		else:
			btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			var bg = StyleBoxFlat.new()
			bg.bg_color = Color(0, 0, 0, 0)
			btn.add_theme_stylebox_override("normal", bg)

func _on_nav_timeline() -> void:
	_switch_section(Section.TIMELINE)

func _on_nav_notifications() -> void:
	_switch_section(Section.NOTIFICATIONS)

func _on_nav_dm() -> void:
	_switch_section(Section.DM)

func _on_nav_profile() -> void:
	_switch_section(Section.PROFILE)

func _on_nav_settings() -> void:
	_switch_section(Section.SETTINGS)

func _on_nav_bookmarks() -> void:
	_switch_section(Section.BOOKMARKS)

func _on_nostr_notice(url: String, message: String) -> void:
	_show_snackbar("[%s] %s" % [url.get_file(), message], 4.0)
	print("[%s]からの通知: %s" % [url, message])

func _on_nostr_reaction_received(url: String, subscription_id: String, event_dict: Dictionary) -> void:
	var pubkey = event_dict.get("pubkey", "")
	var short_pk = pubkey.left(8)
	var tags = event_dict.get("tags", [])
	var target_eid = ""
	var content = event_dict.get("content", "")
	for tag in tags:
		if tag is Array and tag.size() >= 2 and tag[0] == "e":
			target_eid = tag[1]
			break
	if target_eid.is_empty():
		return
	var is_like = content in ["❤️", "+", "🩶"]
	if is_like:
		_reaction_counts[target_eid] = _reaction_counts.get(target_eid, 0) + 1
		_show_snackbar("いいね: %s..." % short_pk, 2.5)
		var labels = _timeline_count_labels.get(target_eid, {})
		if labels.has("like") and is_instance_valid(labels["like"]):
			var c = _reaction_counts[target_eid]
			labels["like"].text = str(c) if c > 0 else ""
	else:
		var stamp_map = _stamp_counts.get(target_eid, {})
		stamp_map[content] = stamp_map.get(content, 0) + 1
		_stamp_counts[target_eid] = stamp_map
		_show_snackbar("スタンプ: %s..." % short_pk, 2.5)
		var labels = _timeline_count_labels.get(target_eid, {})
		if labels.has("stamp") and is_instance_valid(labels["stamp"]):
			var total = 0
			for k in stamp_map: total += stamp_map[k]
			labels["stamp"].text = str(total) if total > 0 else ""



func _on_nostr_direct_message_received(url: String, subscription_id: String, event_dict: Dictionary) -> void:
	var pubkey = event_dict.get("pubkey", "")
	if pubkey == NostrGD.GetPublicKeyHex():
		return
	var short_pk = pubkey.left(8)
	_show_snackbar("DM from %s..." % short_pk, 3.0)

func _on_nostr_event_received(subscription_id: String, event_dict: Dictionary) -> void:
	match subscription_id:
		"profile_resolver":
			_profile_request_active = false
			_profile_request_time = 0
			_parse_profile_event(event_dict)
		_:
			if event_dict.has("kind") and event_dict["kind"] == 0:
				_parse_profile_event(event_dict)
			elif subscription_id.begins_with("embed_"):
				_handle_embed_response(event_dict)
			elif subscription_id.begins_with("notif_embed_"):
				_handle_notif_embed_response(event_dict)
			elif not _notification_sub_id.is_empty() and subscription_id == _notification_sub_id:
				_notifications_events.append(event_dict)
				while _notifications_events.size() > MAX_NOTIFICATIONS:
					_notifications_events.pop_front()
				if _current_section == Section.NOTIFICATIONS and not _notif_refresh_timer.is_processing():
					_notif_refresh_timer.start()
			elif not _bookmark_sub_id.is_empty() and subscription_id == _bookmark_sub_id:
				_handle_bookmark_list_event(event_dict)
			elif not _bookmark_content_sub_id.is_empty() and subscription_id.begins_with(_bookmark_content_sub_id):
				_handle_bookmark_content_event(event_dict)
			elif not _dm_sub_id.is_empty() and subscription_id == _dm_sub_id:
				_on_nostr_direct_message("", subscription_id, event_dict)

func _setup_stamp_popup() -> void:
	var popup = PopupPanel.new()
	popup.name = "StampPopup"
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	var grid = GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	for pair in [["👍", "thumbs-up"], ["❤️", "heart"], ["😂", "smile"], ["🎉", "party"], ["🔥", "flame"], ["😢", "frown"], ["😡", "angry"], ["💯", "award"], ["🚀", "rocket"], ["👀", "eye"]]:
		var emoji = pair[0]
		var icon_name = pair[1]
		var btn = Button.new()
		var icon_tex = _get_icon(icon_name, 20)
		if icon_tex:
			btn.icon = icon_tex
		btn.text = ""
		btn.custom_minimum_size = Vector2(44, 44) if _is_mobile else Vector2(40, 36)
		btn.pressed.connect(_on_stamp_selected.bind(emoji))
		grid.add_child(btn)
	margin.add_child(grid)
	popup.add_child(margin)
	add_child(popup)

func _on_stamp_selected(emoji: String) -> void:
	if _stamp_event_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	NostrGD.SendReaction(_stamp_event_id, _stamp_pubkey, emoji)
	_stamp_event_id = ""
	_stamp_pubkey = ""
	$StampPopup.hide()









func _on_nostr_timeline_updated(sorted_timeline: Array) -> void:
	var has_new = false
	for event in sorted_timeline:
		var eid = event.get("id", "")
		if eid != "" and not _last_displayed_ids.has(eid):
			has_new = true
			break
	if not has_new:
		return
	_pending_sorted_timeline = sorted_timeline
	if _timeline_update_timer.is_processing():
		_timeline_update_timer.stop()
	_timeline_update_timer.start()

func _on_timeline_scrolled(value: float) -> void:
	if _current_section != Section.TIMELINE:
		return
	var scroll = $MainPanel/ScrollContainer
	var max_val = scroll.get_v_scroll_bar().max_value
	if max_val <= 0:
		return
	var at_bottom = value >= max_val - 10
	if at_bottom and not _timeline_paused:
		_pause_timeline()
	elif not at_bottom and _timeline_paused:
		_resume_timeline()

func _pause_timeline() -> void:
	_timeline_paused = true
	status_label.text = "タイムライン一時停止中"
	NostrGD.CloseSubscription("global_feed")

func _reset_timeline() -> void:
	_timeline_paused = false
	_last_displayed_count = 0
	_last_displayed_ids = {}
	NostrGD.CloseSubscription("global_feed")
	NostrGD.ClearTimeline()
	_pending_sorted_timeline = []
	_pending_profile_events.clear()
	for child in timeline.get_children():
		child.queue_free()
	pending_labels.clear()
	_pending_embeds.clear()
	_relays_timeline_subscribed.clear()
	for entry in RELAY_URL:
		if _relays_timeline_subscribed.size() >= MAX_TIMELINE_RELAYS:
			break
		if not _relay_can_read(entry):
			continue
		var url = _relay_url(entry)
		_relays_timeline_subscribed[url] = true
		NostrGD.RequestTimeline("global_feed", 50, url)

func _resume_timeline() -> void:
	_timeline_paused = false
	status_label.text = "タイムライン再開"
	_relays_timeline_subscribed.clear()
	for entry in RELAY_URL:
		if _relays_timeline_subscribed.size() >= MAX_TIMELINE_RELAYS:
			break
		if not _relay_can_read(entry):
			continue
		var url = _relay_url(entry)
		_relays_timeline_subscribed[url] = true
		NostrGD.RequestTimeline("global_feed", 50, url)

func _apply_timeline_update() -> void:
	var events = _pending_sorted_timeline
	_pending_sorted_timeline = []

	for child in timeline.get_children():
		child.queue_free()

	pending_labels.clear()
	_pending_embeds.clear()
	_timeline_count_labels.clear()
	_timeline_panels.clear()
	_reaction_counts.clear()
	_stamp_counts.clear()

	var count = 0
	for event in events:
		if count >= TIMELINE_MAX_ITEMS:
			break

		var pubkey = event.get("pubkey", "")
		_rebuild_timeline_item(event)
		count += 1
		if not profile_cache.has(pubkey) and not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

	for event in _pending_profile_events:
		if count >= TIMELINE_MAX_ITEMS:
			break
		var pubkey = event.get("pubkey", "")
		_rebuild_timeline_item(event)
		count += 1
		if not profile_cache.has(pubkey) and not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

	_pending_profile_events.clear()
	_last_displayed_count = count
	_last_displayed_ids.clear()
	for event in events:
		var eid = event.get("id", "")
		if eid != "":
			_last_displayed_ids[eid] = true

func _on_extension_auth_completed():
	_set_ui_state(UIState.LOGGED_IN)
	status_label.text = "拡張認証完了"

func _on_create_account_button_pressed() -> void:
	var user_name = register_name_input.text.strip_edges()
	var display_name = register_display_input.text.strip_edges()

	if user_name.is_empty() or display_name.is_empty():
		status_label.text = "エラー: ユーザー名と表示名を入力してください"
		return

	var new_private_key_nsec: String = NostrGD.CreateNewKeyPair()
	if not new_private_key_nsec.is_empty():
		private_key_input.text = new_private_key_nsec
		_save_private_key(new_private_key_nsec)

		var hex_key: String = NostrGD.GetPrivateKeyHex()
		var pubkey_hex: String = NostrGD.GetPublicKeyHex()
		var nsec_key: String = NostrGD.GetPrivateKeyNsec()
		_safe_clipboard_set(nsec_key)
		status_label.text = "新しいアカウントを作成しました！\n"
		status_label.text += "【重要】秘密鍵(nsec)をクリップボードにコピーしました\n"
		status_label.text += "Hex: " + hex_key + "\n"
		status_label.text += "nsec: " + nsec_key

		_connect_relays()
		_set_ui_state(UIState.LOGGED_IN)
		_update_settings_nsec_field()

		profile_cache[NostrGD.GetPublicKeyHex()] = {
			"name": user_name,
			"display_name": display_name,
			"picture": register_picture_input.text.strip_edges(),
			"banner": register_banner_input.text.strip_edges()
		}
		_refresh_profile()

		NostrGD.SendProfileMetaData(
			user_name,
			display_name,
			"Multi-relay test",
			register_picture_input.text.strip_edges(),
			register_banner_input.text.strip_edges()
		)

		if not pool_timer.is_processing():
			pool_timer.start()
	else:
		status_label.text = "アカウントの作成に失敗しました"

func _on_login_button_pressed() -> void:
	var key_input_text = private_key_input.text.strip_edges()
	if key_input_text.is_empty():
		status_label.text = "エラー: 鍵が空です"
		return

	if NostrGD.Login(key_input_text):
		_save_private_key(key_input_text)
		_connect_relays()
		_set_ui_state(UIState.LOGGED_IN)
		_update_settings_nsec_field()
		_refresh_profile()
	else:
		status_label.text = "エラー: 無効な秘密鍵(Hexまたはnsec)です"

func _on_extension_login_button_pressed() -> void:
	status_label.text = "ブラウザを起動してローカル認証中..."
	NostrGD.StartLocalAuthServer()

func _on_disconnect_button_pressed() -> void:
	_timeline_paused = false
	NostrGD.CloseSubscription("global_feed")
	NostrGD.ClearTimeline()
	_pending_sorted_timeline = []
	for child in timeline.get_children():
		child.queue_free()
	pending_labels.clear()
	_pending_embeds.clear()
	for entry in RELAY_URL:
		NostrGD.DisconnectFromRelay(_relay_url(entry))
	_set_ui_state(UIState.LOGGED_OUT)
	status_label.text = "切断しました"

func _on_send_button_pressed() -> void:
	var content = message_input.text.strip_edges()
	if content.is_empty() or not NostrGD.IsLoggedIn:
		return
	if _reply_context.has("event_id"):
		NostrGD.SendReply(content, _reply_context["event_id"], _reply_context["pubkey"])
		_reply_context = {}
		_set_input_placeholder("")
	else:
		NostrGD.SendTextNote(content)
	message_input.clear()
	_reply_context_label.visible = false

func _set_input_placeholder(text: String) -> void:
	message_input.placeholder_text = text

func _on_reply_button(event_id: String, pubkey: String, name: String, content: String) -> void:
	_reply_context = { "event_id": event_id, "pubkey": pubkey }
	message_input.grab_focus()
	_set_input_placeholder(name + " に返信... (Escでキャンセル)")
	_reply_context_label.text = "返信先: " + name + ": " + content.left(80)
	_reply_context_label.visible = true

func _on_repost_button(event_id: String) -> void:
	if not NostrGD.IsLoggedIn:
		return
	var dialog = AcceptDialog.new()
	dialog.title = "引用リポスト"
	dialog.ok_button_text = "リポスト"
	dialog.min_size = Vector2(360, 0)
	var input = LineEdit.new()
	input.placeholder_text = "コメント (空なら通常リポスト)"
	input.custom_minimum_size = Vector2(0, 32)
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dialog.add_child(input)
	add_child(dialog)
	dialog.register_text_enter(input)
	dialog.popup_centered(Vector2(400, 100))
	dialog.confirmed.connect(func():
		var quote = input.text.strip_edges()
		NostrGD.SendRepost(event_id, quote)
		status_label.text = "リポストしました"
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)

func _start_notification_subscription() -> void:
	if _notification_sub_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	var sub_count = 0
	for entry in RELAY_URL:
		if sub_count >= MAX_NOTIF_RELAYS:
			break
		if not _relay_can_read(entry):
			continue
		var url = _relay_url(entry)
		NostrGD.RequestNotificationsForRelay(_notification_sub_id, pubkey, url)
		_relays_notif_subscribed[url] = true
		sub_count += 1

func _refresh_notifications() -> void:
	var notif_panel = $MainPanel/NotificationsPanel
	var list_vbox = notif_panel.get_node_or_null("NotifScroll/NotifList")
	if list_vbox == null:
		_build_notifications_section()
		list_vbox = notif_panel.get_node("NotifScroll/NotifList")

	var has_new = false
	for ev in _notifications_events:
		var eid = ev.get("id", "")
		if eid != "" and not _last_notif_ids.has(eid):
			has_new = true
			break
	if not has_new:
		return

	_notifications_events.sort_custom(func(a, b):
		return a.get("created_at", 0) > b.get("created_at", 0)
	)

	while _notifications_events.size() > MAX_NOTIFICATIONS:
		_notifications_events.pop_back()

	for child in list_vbox.get_children():
		child.queue_free()

	if _notifications_events.is_empty():
		var empty_label = Label.new()
		empty_label.text = "通知はありません"
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		list_vbox.add_child(empty_label)
		return

	for ev in _notifications_events:
		var kind = ev.get("kind", 0)
		var pubkey = ev.get("pubkey", "")
		var content = ev.get("content", "")
		var tags = ev.get("tags", [])
		var ref_event_id = ""
		for t in tags:
			if t is Array and t.size() >= 2 and t[0] == "e" and t[1] is String:
				ref_event_id = t[1]
				break

		var card = PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.1, 0.11, 0.13)
		s.content_margin_left = 14
		s.content_margin_right = 14
		s.content_margin_top = 10
		s.content_margin_bottom = 10
		card.add_theme_stylebox_override("panel", s)
		list_vbox.add_child(card)

		var vbox = VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 4)
		card.add_child(vbox)

		var reactor_hbox = HBoxContainer.new()
		reactor_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		reactor_hbox.add_theme_constant_override("separation", 6)
		vbox.add_child(reactor_hbox)

		var avatar_rect = TextureRect.new()
		avatar_rect.custom_minimum_size = Vector2(24, 24)
		avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		avatar_rect.clip_contents = true
		avatar_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		reactor_hbox.add_child(avatar_rect)

		var reactor_name = pubkey.left(12) + "..."
		if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
			reactor_name = profile_cache[pubkey].get("display_name", profile_cache[pubkey].get("name", reactor_name))
		var reactor_label = Label.new()
		reactor_label.text = reactor_name
		reactor_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
		reactor_label.add_theme_font_size_override("font_size", 12)
		reactor_hbox.add_child(reactor_label)

		var kind_str = ""
		var kind_color = Color(0.5, 0.5, 0.6)
		match kind:
			1:
				kind_str = "返信しました"
				kind_color = Color(0.6, 0.8, 1.0)
			7:
				kind_str = "リアクションしました"
				kind_color = Color(1, 0.6, 0.6)
			6, 16:
				kind_str = "リポストしました"
				kind_color = Color(0.4, 0.8, 0.6)
			9735:
				var za = ""
				for t in tags:
					if t is Array and t.size() >= 2 and t[0] == "amount":
						za = str(int(t[1]) / 1000)
						break
				kind_str = "Zap: " + za + " sats"
				kind_color = Color(1, 0.8, 0.4)
		var kind_label = Label.new()
		kind_label.text = kind_str
		kind_label.add_theme_color_override("font_color", kind_color)
		kind_label.add_theme_font_size_override("font_size", 11)
		reactor_hbox.add_child(kind_label)

		if kind == 7:
			var raw = content.strip_edges()
			if raw not in ["+", "-", ""]:
				var emoji_url = NostrUtils.resolve_custom_emoji(content, tags)
				if emoji_url != "":
					var emoji_rect = TextureRect.new()
					emoji_rect.custom_minimum_size = Vector2(22, 22)
					emoji_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					emoji_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					emoji_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					reactor_hbox.add_child(emoji_rect)
					_load_and_apply_avatar(emoji_url, emoji_rect)
				else:
					var emoji_label = Label.new()
					emoji_label.text = raw
					emoji_label.add_theme_font_size_override("font_size", 16)
					reactor_hbox.add_child(emoji_label)

		if kind == 1:
			var preview = content.strip_edges().left(80)
			if not preview.is_empty():
				var preview_label = Label.new()
				preview_label.text = preview
				preview_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
				preview_label.add_theme_font_size_override("font_size", 11)
				preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				vbox.add_child(preview_label)

		if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
			var avatar_url = profile_cache[pubkey].get("picture", "")
			if avatar_url != "":
				_load_and_apply_avatar(avatar_url, avatar_rect)
		elif not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

		if ref_event_id != "":
			var nested_panel = PanelContainer.new()
			var ns = StyleBoxFlat.new()
			ns.bg_color = Color(0.05, 0.06, 0.08)
			ns.set_border_width_all(1)
			ns.border_color = Color(0.2, 0.22, 0.25)
			ns.corner_radius_top_left = 4
			ns.corner_radius_top_right = 4
			ns.corner_radius_bottom_right = 4
			ns.corner_radius_bottom_left = 4
			ns.content_margin_left = 8
			ns.content_margin_right = 8
			ns.content_margin_top = 6
			ns.content_margin_bottom = 6
			nested_panel.add_theme_stylebox_override("panel", ns)
			vbox.add_child(nested_panel)

			var nested_vbox = VBoxContainer.new()
			nested_vbox.add_theme_constant_override("separation", 4)
			nested_panel.add_child(nested_vbox)

			var loading_label = Label.new()
			loading_label.text = "読み込み中..."
			loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			loading_label.add_theme_font_size_override("font_size", 11)
			nested_vbox.add_child(loading_label)

			if not _pending_notif_embeds.has(ref_event_id):
				_pending_notif_embeds[ref_event_id] = []
			_pending_notif_embeds[ref_event_id].append(nested_vbox)

			var embed_sub_id = "notif_embed_" + ref_event_id.left(8)
			NostrGD.RequestEventById(ref_event_id, embed_sub_id)

	_last_notif_ids.clear()
	for ev in _notifications_events:
		var eid = ev.get("id", "")
		if eid != "":
			_last_notif_ids[eid] = true

func _start_dm_subscription() -> void:
	if _dm_sub_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	var sub_count = 0
	for entry in RELAY_URL:
		if sub_count >= MAX_DM_RELAYS:
			break
		if not _relay_can_read(entry):
			continue
		var url = _relay_url(entry)
		NostrGD.RequestDirectMessagesForRelay(_dm_sub_id, pubkey, url)
		_relays_dm_subscribed[url] = true
		sub_count += 1

func _start_bookmark_subscription() -> void:
	if _bookmark_sub_id.is_empty() or not NostrGD.IsLoggedIn:
		return
	var pubkey = NostrGD.GetPublicKeyHex()
	NostrGD.RequestUserEvents(_bookmark_sub_id, [10003], pubkey)

func _on_nostr_direct_message(url: String, subscription_id: String, event_dict: Dictionary) -> void:
	var sender = event_dict.get("pubkey", "")
	if sender.is_empty():
		return
	var my_pubkey = NostrGD.GetPublicKeyHex()
	var counterparty = sender
	if sender == my_pubkey:
		var tags = event_dict.get("tags", [])
		for t in tags:
			if t is Array and t.size() >= 2 and t[0] == "p":
				counterparty = t[1]
				break
	if counterparty.is_empty():
		return
	if not _dm_conversations.has(counterparty):
		_dm_conversations[counterparty] = []
	_dm_conversations[counterparty].append(event_dict)

	if _current_section == Section.DM:
		_refresh_dms()

func _refresh_dms() -> void:
	var list_vbox = $MainPanel/DMPanel/DMScroll/DMList
	for child in list_vbox.get_children():
		child.queue_free()

	if _dm_conversations.is_empty():
		var empty_label = Label.new()
		empty_label.text = "DMはありません"
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		list_vbox.add_child(empty_label)
		return

	for sender in _dm_conversations:
		var msgs = _dm_conversations[sender]
		var name_str = sender.left(12) + "..."
		if profile_cache.has(sender) and profile_cache[sender] is Dictionary:
			name_str = profile_cache[sender].get("display_name", profile_cache[sender].get("name", name_str))

		var header = Label.new()
		header.text = "--- " + name_str + " ---"
		header.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
		list_vbox.add_child(header)

		for msg in msgs:
			var content = msg.get("content", "")
			var time = msg.get("created_at", 0)
			var time_str = "[" + Time.get_datetime_string_from_unix_time(time, true) + "]"

			var msg_label = Label.new()
			msg_label.text = time_str + " " + content
			msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			msg_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
			list_vbox.add_child(msg_label)

func _refresh_bookmarks() -> void:
	var list_vbox = $MainPanel/BookmarksPanel/BookmarkScroll/BookmarkList
	for child in list_vbox.get_children():
		child.queue_free()
	if _bookmarked_events.is_empty():
		var empty_label = Label.new()
		empty_label.text = "ブックマークはありません\nイベントのブックマークボタンで追加"
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list_vbox.add_child(empty_label)
		return
	for ev in _bookmarked_events:
		var card = _render_bookmark_card(ev)
		if card != null:
			list_vbox.add_child(card)

func _render_bookmark_card(event: Dictionary) -> PanelContainer:
	var pubkey = event.get("pubkey", "")
	var content = event.get("content", "")
	var time = event.get("created_at", 0)
	var event_id = event.get("id", "")
	var is_loading = pubkey.is_empty() and content == "読み込み中..."

	var card = PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var s = StyleBoxFlat.new()
	s.bg_color = Color(0.1, 0.11, 0.13)
	s.set_border_width_all(1)
	s.border_color = Color(0.18, 0.19, 0.22)
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_right = 6
	s.corner_radius_bottom_left = 6
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", s)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	card.add_child(vbox)

	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	if not is_loading:
		var name_str = pubkey.left(12) + "..."
		if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
			name_str = profile_cache[pubkey].get("display_name", profile_cache[pubkey].get("name", name_str))
		var name_label = Label.new()
		name_label.text = name_str
		name_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
		name_label.add_theme_font_size_override("font_size", 12)
		header.add_child(name_label)

		var time_str = Time.get_datetime_string_from_unix_time(time, true).left(16)
		var time_label = Label.new()
		time_label.text = time_str
		time_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		time_label.add_theme_font_size_override("font_size", 10)
		time_label.size_flags_horizontal = Control.SIZE_SHRINK_END
		header.add_child(time_label)
	else:
		var loading_label = Label.new()
		loading_label.text = "読み込み中..."
		loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		loading_label.add_theme_font_size_override("font_size", 12)
		header.add_child(loading_label)

	var content_label = Label.new()
	content_label.text = content
	content_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9) if not is_loading else Color(0.5, 0.5, 0.5))
	content_label.add_theme_font_size_override("font_size", 13)
	content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(content_label)

	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(btn_hbox)

	var remove_btn = Button.new()
	remove_btn.text = "削除"
	remove_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	remove_btn.add_theme_font_size_override("font_size", 10)
	remove_btn.pressed.connect(_remove_bookmark.bind(event_id))
	btn_hbox.add_child(remove_btn)

	if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
		var avatar_url = profile_cache[pubkey].get("picture", "")
		if avatar_url != "":
			var avatar_rect = TextureRect.new()
			avatar_rect.custom_minimum_size = Vector2(18, 18)
			avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			avatar_rect.clip_contents = true
			header.add_child(avatar_rect)
			header.move_child(avatar_rect, 0)
			_load_and_apply_avatar(avatar_url, avatar_rect)
	elif not pubkey_request_pool.has(pubkey):
		pubkey_request_pool.append(pubkey)

	return card

func _remove_bookmark(event_id: String) -> void:
	for i in range(_bookmarked_events.size()):
		if _bookmarked_events[i].get("id", "") == event_id:
			_bookmarked_events.remove_at(i)
			break
	_save_bookmarks()
	_refresh_bookmarks()

func _save_bookmarks() -> void:
	var save_data: Array[Dictionary] = []
	for ev in _bookmarked_events:
		save_data.append(ev.duplicate())
	var save_str = JSON.new().stringify(save_data)
	var f = FileAccess.open("user://bookmarks.json", FileAccess.WRITE)
	if f != null:
		f.store_string(save_str)
		f.close()

func _load_bookmarks() -> void:
	var f = FileAccess.open("user://bookmarks.json", FileAccess.READ)
	if f == null:
		return
	var raw = f.get_as_text()
	f.close()
	var json = JSON.new()
	if json.parse(raw) != OK:
		return
	var arr = json.get_data()
	if arr == null or not (arr is Array):
		return
	_bookmarked_events.clear()
	for ev in arr:
		if ev is Dictionary and ev.get("id", "") != "":
			_bookmarked_events.append(ev)

func _is_bookmarked(event_id: String) -> bool:
	for ev in _bookmarked_events:
		if ev.get("id", "") == event_id:
			return true
	return false

func _toggle_bookmark(event_id: String, event: Dictionary) -> void:
	if _is_bookmarked(event_id):
		for i in range(_bookmarked_events.size()):
			if _bookmarked_events[i].get("id", "") == event_id:
				_bookmarked_events.remove_at(i)
				break
	else:
		_bookmarked_events.append(event.duplicate())
	_save_bookmarks()
	_publish_bookmark_list()
	if _current_section == Section.BOOKMARKS:
		_refresh_bookmarks()

func _publish_bookmark_list() -> void:
	var tags: Array = [["d", ""]]
	for ev in _bookmarked_events:
		var eid = ev.get("id", "")
		if eid != "":
			tags.append(["e", eid])
	NostrGD.SendCustomEvent(10003, "", tags)

func _handle_bookmark_list_event(event_dict: Dictionary) -> void:
	var tags = event_dict.get("tags", [])
	var remote_ids: Dictionary = {}
	var need_fetch: Array[String] = []
	for t in tags:
		if t is Array and t.size() >= 2 and t[0] == "e":
			var eid = t[1]
			if eid != "":
				remote_ids[eid] = true
				if not _is_bookmarked(eid) and not _bookmark_loaded_event_ids.has(eid):
					need_fetch.append(eid)
	_bookmark_loaded_event_ids = remote_ids.duplicate()
	for eid in need_fetch:
		var sub_id = _bookmark_content_sub_id + "_" + eid.left(8)
		NostrGD.RequestEventById(eid, sub_id)
	var added = false
	for eid in remote_ids:
		if not _is_bookmarked(eid):
			_bookmarked_events.append({"id": eid, "pubkey": "", "content": "読み込み中...", "created_at": 0, "tags": []})
			added = true
	if added:
		_save_bookmarks()
		if _current_section == Section.BOOKMARKS:
			_refresh_bookmarks()

func _handle_bookmark_content_event(event_dict: Dictionary) -> void:
	var eid = event_dict.get("id", "")
	if eid == "":
		return
	for i in range(_bookmarked_events.size()):
		if _bookmarked_events[i].get("id", "") == eid:
			_bookmarked_events[i] = event_dict.duplicate()
			_save_bookmarks()
			if _current_section == Section.BOOKMARKS:
				_refresh_bookmarks()
			return
	if not _is_bookmarked(eid):
		_bookmarked_events.append(event_dict.duplicate())
		_save_bookmarks()
		if _current_section == Section.BOOKMARKS:
			_refresh_bookmarks()

func _on_dm_send() -> void:
	if not NostrGD.IsLoggedIn:
		return
	var target = $MainPanel/DMPanel/DMInputBar/DMPubkey.text.strip_edges()
	var content = $MainPanel/DMPanel/DMInputBar/DMMessage.text.strip_edges()
	if content.is_empty() or target.is_empty():
		return
	NostrGD.SendDirectMessage(content, target)
	$MainPanel/DMPanel/DMInputBar/DMMessage.clear()
	status_label.text = "DMを送信しました"

func _on_image_upload_button() -> void:
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.add_filter("*.png,*.jpg,*.jpeg,*.gif,*.webp", "画像ファイル")
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_selected.connect(_on_image_file_selected)
		add_child(_file_dialog)
	_file_dialog.popup_centered(Vector2(600, 400))

func _on_image_file_selected(path: String) -> void:
	status_label.text = "画像をアップロード中..."
	var http = HTTPRequest.new()
	add_child(http)

	var callback = func(result, response_code, headers, body):
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var json = JSON.new()
			if json.parse(body.get_string_from_utf8()) == OK:
				var data = json.get_data()
				var url = ""
				if data is Dictionary:
					if data.has("url"):
						url = data["url"]
					elif data.has("data") and data["data"] is Dictionary and data["data"].has("url"):
						url = data["data"]["url"]
				if not url.is_empty():
					var current_text = message_input.text
					if not current_text.is_empty():
						current_text += "\n"
					message_input.text = current_text + url
					status_label.text = "画像URLを挿入しました"
		return

	if not pool_timer.is_processing():
		pool_timer.start()
			status_label.text = "URLが取得できませんでした。手動でURLを貼ってください。"
		else:
			status_label.text = "アップロード失敗(" + str(response_code) + ")。手動で画像URLを貼ってください。"
		if is_instance_valid(http):
			http.queue_free()

	http.request_completed.connect(callback)

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		status_label.text = "ファイルを開けませんでした"
		http.queue_free()
		return

	var buffer = file.get_buffer(file.get_length())
	var b64 = Marshalls.raw_to_base64(buffer)
	var ext = path.get_extension().to_lower()

	var boundary = "----NostrGD" + str(Time.get_unix_time_from_system())
	var header_str = "--" + boundary + "\r\n"
	header_str += "Content-Disposition: form-data; name=\"image\"; filename=\"upload." + ext + "\"\r\n"
	header_str += "Content-Type: image/" + ext + "\r\n\r\n"
	var footer_str = "\r\n--" + boundary + "--\r\n"

	var header_bytes = header_str.to_utf8_buffer()
	var footer_bytes = footer_str.to_utf8_buffer()

	var body = PackedByteArray()
	body.append_array(header_bytes)
	body.append_array(buffer)
	body.append_array(footer_bytes)

	var content_type = "Content-Type: multipart/form-data; boundary=" + boundary
	var error = http.request("https://nostr.build/api/upload.php", [content_type], HTTPClient.METHOD_POST, body)
	if error != OK:
		status_label.text = "アップロードリクエスト失敗"
		http.queue_free()

func _on_reaction(event_id: String, target_pubkey: String, emoji: String) -> void:
	if not NostrGD.IsLoggedIn:
		return
	NostrGD.SendReaction(event_id, target_pubkey, emoji)

func _on_like_toggle(event_id: String, target_pubkey: String, btn: Button) -> void:
	if not NostrGD.IsLoggedIn:
		return
	if _liked_events.has(event_id):
		NostrGD.SendReaction(event_id, target_pubkey, "-")
		_liked_events.erase(event_id)
		btn.icon = _get_icon("heart")
		btn.text = ""
		btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	else:
		NostrGD.SendReaction(event_id, target_pubkey, "❤️")
		_liked_events[event_id] = true
		btn.text = "取消"
		btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))

func _open_stamp(event_id: String, pubkey: String) -> void:
	_stamp_event_id = event_id
	_stamp_pubkey = pubkey
	$StampPopup.popup_centered(Vector2(280, 200))

func _handle_embed_response(event_dict: Dictionary) -> void:
	var embed_id = event_dict.get("id", "")
	if embed_id.is_empty() or not _pending_embeds.has(embed_id):
		return

	var embed_data = _pending_embeds[embed_id]
	var nested_vbox = embed_data.get("nested_vbox", null)
	if not is_instance_valid(nested_vbox):
		_pending_embeds.erase(embed_id)
		return

	for child in nested_vbox.get_children():
		child.queue_free()

	var embed_content = event_dict.get("content", "")
	var embed_pubkey = event_dict.get("pubkey", "")

	var name_str = embed_pubkey.left(12) + "..."
	if profile_cache.has(embed_pubkey) and profile_cache[embed_pubkey] is Dictionary:
		name_str = profile_cache[embed_pubkey].get("display_name", profile_cache[embed_pubkey].get("name", name_str))

	var name_label = Label.new()
	name_label.text = name_str
	name_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
	name_label.add_theme_font_size_override("font_size", 11)
	nested_vbox.add_child(name_label)

	var content_label = Label.new()
	content_label.text = embed_content
	content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	content_label.add_theme_font_size_override("font_size", 12)
	nested_vbox.add_child(content_label)

	_pending_embeds.erase(embed_id)
	if not pubkey_request_pool.has(embed_pubkey):
		pubkey_request_pool.append(embed_pubkey)

func _handle_notif_embed_response(event_dict: Dictionary) -> void:
	var embed_id = event_dict.get("id", "")
	if embed_id.is_empty() or not _pending_notif_embeds.has(embed_id):
		return
	var targets = _pending_notif_embeds[embed_id]
	_pending_notif_embeds.erase(embed_id)
	var embed_content = event_dict.get("content", "")
	var embed_pubkey = event_dict.get("pubkey", "")
	var embed_name = embed_pubkey.left(12) + "..."
	if profile_cache.has(embed_pubkey) and profile_cache[embed_pubkey] is Dictionary:
		embed_name = profile_cache[embed_pubkey].get("display_name", profile_cache[embed_pubkey].get("name", embed_name))
	for nvbox in targets:
		if not is_instance_valid(nvbox):
			continue
		for child in nvbox.get_children():
			child.queue_free()
		var nl = Label.new()
		nl.text = embed_name
		nl.add_theme_color_override("font_color", Color.GREEN_YELLOW)
		nl.add_theme_font_size_override("font_size", 11)
		nvbox.add_child(nl)
		var cl = Label.new()
		cl.text = embed_content
		cl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
		cl.add_theme_font_size_override("font_size", 12)
		nvbox.add_child(cl)
	if not pubkey_request_pool.has(embed_pubkey):
		pubkey_request_pool.append(embed_pubkey)

func _rebuild_timeline_item(event: Dictionary) -> void:
	var pubkey: String = event["pubkey"]
	var content: String = event["content"]
	var is_repost: bool = event.get("is_repost", false)
	var repost_eid: String = event.get("repost_event_id", "")
	var repost_pk: String = event.get("repost_pubkey", "")
	var is_reply: bool = false
	if event.has("tags"):
		for t in event["tags"]:
			if t is Array and t.size() >= 2 and t[0] == "e":
				is_reply = true
				break

	var post_panel = PanelContainer.new()
	post_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.add_child(post_panel)

	var style_box = StyleBoxFlat.new()
	style_box.bg_color = Color(0.1, 0.11, 0.13)
	style_box.set_border_width_all(1)
	style_box.border_color = Color(0.18, 0.19, 0.22)
	style_box.corner_radius_top_left = 6
	style_box.corner_radius_top_right = 6
	style_box.corner_radius_bottom_right = 6
	style_box.corner_radius_bottom_left = 6
	style_box.content_margin_left = 16
	style_box.content_margin_right = 16
	style_box.content_margin_top = 10
	style_box.content_margin_bottom = 10

	post_panel.add_theme_stylebox_override("panel", style_box)

	var main_hbox = HBoxContainer.new()
	main_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_theme_constant_override("separation", 12)
	post_panel.add_child(main_hbox)

	var avatar_rect = TextureRect.new()
	avatar_rect.custom_minimum_size = Vector2(44, 44)
	avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	avatar_rect.clip_contents = true
	avatar_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	main_hbox.add_child(avatar_rect)

	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(right_vbox)

	if is_repost:
		var repost_header = Label.new()
		repost_header.text = "Repost"
		repost_header.add_theme_color_override("font_color", Color(0.4, 0.8, 0.6))
		repost_header.add_theme_font_size_override("font_size", 12)
		right_vbox.add_child(repost_header)

	if is_reply:
		var reply_badge = Label.new()
		reply_badge.text = "Reply"
		reply_badge.add_theme_color_override("font_color", Color(0.6, 0.6, 0.8))
		reply_badge.add_theme_font_size_override("font_size", 12)
		right_vbox.add_child(reply_badge)

	var name_label = Label.new()
	name_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
	right_vbox.add_child(name_label)

	var entry_label = Label.new()
	entry_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_vbox.add_child(entry_label)

	var hide_content: bool = is_repost and content.is_empty()
	if hide_content:
		entry_label.visible = false

	var has_npub_link: bool = false
	var npub_url: String = ""
	if content.begins_with("https://npub") or content.begins_with("nostr:"):
		has_npub_link = true
		npub_url = content.split("\n")[0].strip_edges()
	elif event.has("media_nostr_uris") and event["media_nostr_uris"].size() > 0:
		has_npub_link = true
		npub_url = event["media_nostr_uris"][0]

	var event_id: String = event.get("id", "")
	_timeline_panels[event_id] = post_panel
	if NostrGD.IsLoggedIn and not event_id.is_empty():
		var action_hbox = HBoxContainer.new()
		action_hbox.add_theme_constant_override("separation", 4)
		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		right_vbox.add_child(spacer)
		right_vbox.add_child(action_hbox)

		var _act_bg := StyleBoxEmpty.new()
		var _act_hover := StyleBoxFlat.new()
		_act_hover.bg_color = Color(0.22, 0.23, 0.26)
		_act_hover.corner_radius_top_left = 4
		_act_hover.corner_radius_top_right = 4
		_act_hover.corner_radius_bottom_right = 4
		_act_hover.corner_radius_bottom_left = 4
		var _btn_sz = _btn_size(30, 24)
		var like_btn = Button.new()
		like_btn.icon = _get_icon("heart")
		like_btn.text = ""
		like_btn.custom_minimum_size = _btn_sz
		like_btn.add_theme_stylebox_override("normal", _act_bg)
		like_btn.add_theme_stylebox_override("hover", _act_hover)
		if _liked_events.has(event_id):
			like_btn.text = "取消"
			like_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		like_btn.pressed.connect(_on_like_toggle.bind(event_id, pubkey, like_btn))
		action_hbox.add_child(like_btn)

		var stamp_btn = Button.new()
		stamp_btn.icon = _get_icon("star")
		stamp_btn.text = ""
		stamp_btn.custom_minimum_size = _btn_sz
		stamp_btn.add_theme_stylebox_override("normal", _act_bg)
		stamp_btn.add_theme_stylebox_override("hover", _act_hover)
		stamp_btn.pressed.connect(_open_stamp.bind(event_id, pubkey))
		action_hbox.add_child(stamp_btn)

		var reply_btn = Button.new()
		reply_btn.icon = _get_icon("reply")
		reply_btn.text = ""
		reply_btn.custom_minimum_size = _btn_sz
		reply_btn.add_theme_stylebox_override("normal", _act_bg)
		reply_btn.add_theme_stylebox_override("hover", _act_hover)
		var reply_name = profile_cache.get(pubkey, {}).get("display_name", profile_cache.get(pubkey, {}).get("name", pubkey.left(8)))
		reply_btn.pressed.connect(_on_reply_button.bind(event_id, pubkey, reply_name, content))
		action_hbox.add_child(reply_btn)

		var repost_btn = Button.new()
		repost_btn.icon = _get_icon("repeat")
		repost_btn.text = ""
		repost_btn.custom_minimum_size = _btn_sz
		repost_btn.add_theme_stylebox_override("normal", _act_bg)
		repost_btn.add_theme_stylebox_override("hover", _act_hover)
		repost_btn.pressed.connect(_on_repost_button.bind(event_id))
		action_hbox.add_child(repost_btn)

		var bookmark_btn = Button.new()
		bookmark_btn.icon = _get_icon("bookmark")
		bookmark_btn.text = ""
		bookmark_btn.custom_minimum_size = _btn_sz
		bookmark_btn.add_theme_stylebox_override("normal", _act_bg)
		bookmark_btn.add_theme_stylebox_override("hover", _act_hover)
		if _is_bookmarked(event_id):
			bookmark_btn.add_theme_color_override("font_color", Color(1, 0.8, 0.2))
		bookmark_btn.pressed.connect(_toggle_bookmark.bind(event_id, event))
		action_hbox.add_child(bookmark_btn)

		var count_hbox = HBoxContainer.new()
		count_hbox.name = "CountHBox_" + event_id.left(8)
		count_hbox.add_theme_constant_override("separation", 8)
		right_vbox.add_child(count_hbox)

		var rc = _reaction_counts.get(event_id, 0)
		var like_count = Label.new()
		like_count.name = "LikeCount"
		like_count.text = "Like " + str(rc) if rc > 0 else ""
		like_count.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		like_count.add_theme_font_size_override("font_size", 10)
		count_hbox.add_child(like_count)

		var sc_map = _stamp_counts.get(event_id, {})
		var sc_total = 0
		for k in sc_map: sc_total += sc_map[k]
		var stamp_count = Label.new()
		stamp_count.name = "StampCount"
		stamp_count.text = "Reaction " + str(sc_total) if sc_total > 0 else ""
		stamp_count.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		stamp_count.add_theme_font_size_override("font_size", 10)
		count_hbox.add_child(stamp_count)

		_timeline_count_labels[event_id] = {
			like = like_count,
			stamp = stamp_count
		}

	_reaction_counts[event_id] = _reaction_counts.get(event_id, 0)
	_stamp_counts[event_id] = _stamp_counts.get(event_id, {})

	if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
		var profile = profile_cache[pubkey]
		name_label.text = profile.get("display_name", profile.get("name", "Unknown"))
		entry_label.text = content

		var avatar_url = profile.get("picture", "")
		if avatar_url != "":
			_load_and_apply_avatar(avatar_url, avatar_rect)
	else:
		name_label.text = "[%s...]" % pubkey.left(8)
		entry_label.text = content

		if not pending_labels.has(pubkey):
			pending_labels[pubkey] = []
		pending_labels[pubkey].append({
			"name_label": name_label,
			"avatar_rect": avatar_rect,
			"content": content
		})
		if not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

	if event.has("media_hashtags") and event["media_hashtags"].size() > 0:
		var tag_hbox = HBoxContainer.new()
		tag_hbox.add_theme_constant_override("separation", 4)
		right_vbox.add_child(tag_hbox)
		for tag in event["media_hashtags"]:
			var tag_btn = Button.new()
			tag_btn.text = tag
			tag_btn.add_theme_color_override("font_color", Color(0.4, 0.6, 1.0))
			tag_btn.add_theme_font_size_override("font_size", 11)
			var tag_url = "https://nostr.band/?q=" + tag.trim_prefix("#").uri_encode()
			tag_btn.pressed.connect(func(): _open_url(tag_url))
			tag_hbox.add_child(tag_btn)

	var note_id_from_content: String = ""
	if event.has("media_nostr_uris") and event["media_nostr_uris"].size() > 0:
		for uri in event["media_nostr_uris"]:
			var decoded = NostrUtils.decode_note1_id(uri)
			if decoded != "":
				note_id_from_content = decoded
				break

	var show_nested: bool = is_repost or has_npub_link or note_id_from_content != ""

	if show_nested:
		var nested_panel = PanelContainer.new()
		var nested_style = StyleBoxFlat.new()
		nested_style.bg_color = Color(0.05, 0.06, 0.08)
		nested_style.set_border_width_all(1)
		nested_style.border_color = Color(0.2, 0.22, 0.25)
		nested_style.corner_radius_top_left = 4
		nested_style.corner_radius_top_right = 4
		nested_style.corner_radius_bottom_right = 4
		nested_style.corner_radius_bottom_left = 4
		nested_style.content_margin_left = 8
		nested_style.content_margin_right = 8
		nested_style.content_margin_top = 6
		nested_style.content_margin_bottom = 6
		nested_panel.add_theme_stylebox_override("panel", nested_style)
		right_vbox.add_child(nested_panel)

		var nested_vbox = VBoxContainer.new()
		nested_vbox.add_theme_constant_override("separation", 4)
		nested_panel.add_child(nested_vbox)

		if is_repost and repost_eid != "":
			if event.has("repost_original_content") and event["repost_original_content"] != "":
				var orig_pk = event.get("repost_original_pubkey", "")
				var repost_name = orig_pk.left(12) + "..."
				if orig_pk != "" and profile_cache.has(orig_pk) and profile_cache[orig_pk] is Dictionary:
					repost_name = profile_cache[orig_pk].get("display_name", profile_cache[orig_pk].get("name", repost_name))
				var name_label2 = Label.new()
				name_label2.text = repost_name
				name_label2.add_theme_color_override("font_color", Color.GREEN_YELLOW)
				name_label2.add_theme_font_size_override("font_size", 11)
				nested_vbox.add_child(name_label2)
				var content_label2 = Label.new()
				content_label2.text = event["repost_original_content"]
				content_label2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				content_label2.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
				content_label2.add_theme_font_size_override("font_size", 12)
				nested_vbox.add_child(content_label2)
				if event.has("repost_media_images"):
					var img_container2 = VBoxContainer.new()
					img_container2.alignment = BoxContainer.ALIGNMENT_BEGIN
					nested_vbox.add_child(img_container2)
					for img_url in event["repost_media_images"]:
						_load_and_display_image(img_url, img_container2)
				if event.has("repost_media_youtube_ids"):
					for yt_id in event["repost_media_youtube_ids"]:
						_render_youtube_embed(yt_id, nested_vbox)
			else:
				var loading_label = Label.new()
				loading_label.text = "読み込み中..."
				loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
				loading_label.add_theme_font_size_override("font_size", 11)
				nested_vbox.add_child(loading_label)
				var embed_sub_id = "embed_" + repost_eid.left(8)
				NostrGD.RequestEventById(repost_eid, embed_sub_id)
				_pending_embeds[repost_eid] = { "nested_vbox": nested_vbox, "parent_event_id": event.get("id", "") }
		elif has_npub_link and npub_url != "":
			var url_label = Label.new()
			url_label.text = npub_url
			url_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			url_label.add_theme_color_override("font_color", Color(0.5, 0.7, 1))
			url_label.add_theme_font_size_override("font_size", 11)
			nested_vbox.add_child(url_label)
			var open_btn = Button.new()
			open_btn.text = "ブラウザで開く"
			open_btn.pressed.connect(func(): _open_url(npub_url))
			nested_vbox.add_child(open_btn)
		elif note_id_from_content != "":
			var loading_label = Label.new()
			loading_label.text = "読み込み中..."
			loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			loading_label.add_theme_font_size_override("font_size", 11)
			nested_vbox.add_child(loading_label)
			var embed_sub_id = "embed_" + note_id_from_content.left(8)
			NostrGD.RequestEventById(note_id_from_content, embed_sub_id)
			_pending_embeds[note_id_from_content] = { "nested_vbox": nested_vbox, "parent_event_id": event.get("id", "") }

	if event.has("media_images") and event["media_images"].size() > 0:
		var image_container = VBoxContainer.new()
		image_container.alignment = BoxContainer.ALIGNMENT_BEGIN
		right_vbox.add_child(image_container)

		for img_url in event["media_images"]:
			_load_and_display_image(img_url, image_container)

	if event.has("media_youtube_ids") and event["media_youtube_ids"].size() > 0:
		for yt_id in event["media_youtube_ids"]:
			_render_youtube_embed(yt_id, right_vbox)

	var all_links = []
	if event.has("media_nostr_uris"): all_links.append_array(event["media_nostr_uris"])
	if event.has("media_images"):
		for img_url in event["media_images"]:
			if not content.contains(img_url):
				all_links.append(img_url)
	if event.has("media_youtube"):
		for yt_url in event["media_youtube"]:
			if not content.contains(yt_url):
				all_links.append(yt_url)

	for link in all_links:
		var link_btn = LinkButton.new()
		link_btn.text = link
		link_btn.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
		link_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		link_btn.pressed.connect(func(): _open_url(link))
		right_vbox.add_child(link_btn)

func _load_and_display_image(url: String, parent_node: Node) -> void:
	var cleaned_url = url.strip_edges()
	if cleaned_url.is_empty() or not cleaned_url.begins_with("http"):
		return

	if _image_texture_cache.has(cleaned_url):
		var cached_texture = _image_texture_cache[cleaned_url]
		if cached_texture == null:
			_image_texture_cache.erase(cleaned_url)
		else:
			var img_w = cached_texture.get_width()
			var img_h = cached_texture.get_height()
			var max_w = _get_media_max_width()
			var max_h = _get_media_max_height()
			var scale = min(min(max_w / max(img_w, 1), max_h / max(img_h, 1)), 1.0)
			var texture_rect = TextureRect.new()
			texture_rect.texture = cached_texture
			texture_rect.custom_minimum_size = Vector2(img_w * scale, img_h * scale)
			texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			parent_node.add_child(texture_rect)
		return

	var http_request = HTTPRequest.new()
	parent_node.add_child(http_request)

	var callback = func(result, response_code, _headers, body, node, req):
		if is_instance_valid(req):
			req.queue_free()
		if not is_instance_valid(node):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = OK
			var ext = cleaned_url.get_extension().to_lower().split("?")[0]
			if ext in ["jpg", "jpeg"]:
				error = image.load_jpg_from_buffer(body)
			elif ext == "png":
				error = image.load_png_from_buffer(body)
			elif ext == "webp":
				error = image.load_webp_from_buffer(body)
			elif ext.is_empty():
				error = image.load_jpg_from_buffer(body)
				if error != OK:
					error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_webp_from_buffer(body)

			if error == OK and is_instance_valid(node):
				var texture = ImageTexture.create_from_image(image)
				_image_texture_cache[cleaned_url] = texture

				var texture_rect = TextureRect.new()
				texture_rect.texture = texture

				var img_w = image.get_width()
				var img_h = image.get_height()
				var max_w = _get_media_max_width()
				var max_h = _get_media_max_height()
				var scale = min(min(max_w / max(img_w, 1), max_h / max(img_h, 1)), 1.0)
				texture_rect.custom_minimum_size = Vector2(img_w * scale, img_h * scale)
				texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				node.add_child(texture_rect)

	http_request.request_completed.connect(callback.bind(parent_node, http_request))

	var err = http_request.request(cleaned_url)
	if err != OK:
		http_request.queue_free()

func _load_and_apply_avatar(url: String, target_rect: TextureRect) -> void:
	var cleaned_url = url.strip_edges()
	if cleaned_url.is_empty() or not cleaned_url.begins_with("http"):
		return

	if _avatar_texture_cache.has(cleaned_url):
		var cached = _avatar_texture_cache[cleaned_url]
		if cached != null:
			target_rect.texture = cached
		else:
			_avatar_texture_cache.erase(cleaned_url)
		return

	var http_request = HTTPRequest.new()
	add_child(http_request)

	var callback = func(result, response_code, _headers, body, rect):
		if not is_instance_valid(rect):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = OK
			var ext = cleaned_url.get_extension().to_lower().split("?")[0]

			if ext in ["jpg", "jpeg"]: error = image.load_jpg_from_buffer(body)
			elif ext == "png": error = image.load_png_from_buffer(body)
			elif ext == "webp": error = image.load_webp_from_buffer(body)
			elif ext.is_empty():
				error = image.load_jpg_from_buffer(body)
				if error != OK:
					error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_webp_from_buffer(body)

			if error == OK and is_instance_valid(rect):
				var texture = ImageTexture.create_from_image(image)
				if texture != null:
					_avatar_texture_cache[cleaned_url] = texture
					rect.texture = texture

		if is_instance_valid(http_request):
			http_request.queue_free()

	http_request.request_completed.connect(callback.bind(target_rect))

	var err = http_request.request(cleaned_url)
	if err != OK:
		http_request.queue_free()

func _load_and_apply_banner(url: String, target_rect: TextureRect) -> void:
	var cleaned_url = url.strip_edges()
	if cleaned_url.is_empty() or not cleaned_url.begins_with("http"):
		return
	if _avatar_texture_cache.has(cleaned_url):
		var cached = _avatar_texture_cache[cleaned_url]
		if cached != null:
			target_rect.texture = cached
		else:
			_avatar_texture_cache.erase(cleaned_url)
		return
	var http_request = HTTPRequest.new()
	add_child(http_request)
	var callback = func(result, response_code, _headers, body, rect):
		if not is_instance_valid(rect):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			var error = OK
			var ext = cleaned_url.get_extension().to_lower().split("?")[0]
			if ext in ["jpg", "jpeg"]: error = image.load_jpg_from_buffer(body)
			elif ext == "png": error = image.load_png_from_buffer(body)
			elif ext == "webp": error = image.load_webp_from_buffer(body)
			elif ext.is_empty():
				error = image.load_jpg_from_buffer(body)
				if error != OK:
					error = image.load_png_from_buffer(body)
				if error != OK:
					error = image.load_webp_from_buffer(body)
			if error == OK and is_instance_valid(rect):
				var texture = ImageTexture.create_from_image(image)
				if texture != null:
					_avatar_texture_cache[cleaned_url] = texture
					rect.texture = texture
		if is_instance_valid(http_request):
			http_request.queue_free()
	http_request.request_completed.connect(callback.bind(target_rect))
	var err = http_request.request(cleaned_url)
	if err != OK:
		http_request.queue_free()

func _on_pool_timer_timeout() -> void:
	if _profile_request_active:
		var elapsed = Time.get_ticks_msec() - _profile_request_time
		if _profile_request_time > 0 and elapsed < 15000:
			return
		_profile_request_active = false

	if pubkey_request_pool.is_empty():
		_profile_request_active = false
		_profile_request_time = 0
		return

	_profile_request_active = true
	_profile_request_time = Time.get_ticks_msec()
	var pool_copy = pubkey_request_pool.duplicate()
	pubkey_request_pool.clear()

	NostrGD.RequestProfiles("profile_resolver", pool_copy)

func _parse_profile_event(event: Dictionary) -> void:
	var pubkey: String = event["pubkey"]
	var raw_content: String = event["content"]

	var json = JSON.new()
	if json.parse(raw_content) == OK:
		var profile_data = json.get_data()

		profile_cache[pubkey] = profile_data

		var user_name = profile_data.get("display_name", profile_data.get("name", pubkey.left(8)))
		var avatar_url = profile_data.get("picture", "")

		if pending_labels.has(pubkey):
			for item in pending_labels[pubkey]:
				if item.has("name_label") and is_instance_valid(item["name_label"]):
					item["name_label"].text = user_name

				if avatar_url != "" and item.has("avatar_rect") and is_instance_valid(item["avatar_rect"]):
					_load_and_apply_avatar(avatar_url, item["avatar_rect"])
			pending_labels.erase(pubkey)

		if NostrGD.IsLoggedIn and pubkey == NostrGD.GetPublicKeyHex() and _current_section == Section.PROFILE:
			_refresh_profile()

		if _current_section == Section.NOTIFICATIONS:
			for nev in _notifications_events:
				if nev.get("pubkey", "") == pubkey:
					_refresh_notifications()
					break

		if not _pending_profile_events.is_empty() and not _timeline_update_timer.is_processing():
			_timeline_update_timer.start()

const BTN_MIN_W: int = 28
const BTN_MIN_H: int = 24

func _btn_size(w: int, h: int) -> Vector2:
	var mw = max(w, BTN_MIN_W)
	var mh = max(h, BTN_MIN_H)
	if _is_mobile:
		return Vector2(max(mw, BTN_MQ), max(mh, BTN_MQ_TALL))
	return Vector2(mw, mh)

func _get_media_max_width() -> int:
	var vp_w = get_viewport().size.x
	var desktop_max = vp_w - 280 - 32
	if _is_mobile:
		return min(vp_w - 32, 420)
	return max(min(desktop_max, 560), 280)

func _get_media_max_height() -> int:
	var vp_h = get_viewport().size.y
	if _is_mobile:
		return min(int(vp_h * 0.4), 320)
	return min(int(vp_h * 0.5), 480)
func _copy_account_pubkey() -> void:
	if not NostrGD.IsLoggedIn:
		return
	var pk_hex = NostrGD.GetPublicKeyHex()
	var npub = Secp256k1.npub_encode(pk_hex)
	_safe_clipboard_set(npub)
	status_label.text = "npub をコピーしました"

func _safe_clipboard_set(text: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("navigator.clipboard.writeText('" + text.replace("\\", "\\\\").replace("'", "\\'") + "').catch(function(e) {})")
	else:
		DisplayServer.clipboard_set(text)

func _open_url(url: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.open('" + url.replace("\\", "\\\\").replace("'", "\\'") + "','_blank')")
	else:
		OS.shell_open(url)

func _update_settings_nsec_field() -> void:
	var panel = $MainPanel/SettingsPanel
	if panel == null:
		return
	var nsec_input = panel.get_node_or_null("SettingsNsecInput") as LineEdit
	if nsec_input != null and NostrGD.IsLoggedIn:
		nsec_input.text = NostrGD.GetPrivateKeyNsec()

var _snackbar_timer: Timer = null

func _show_snackbar(msg: String, duration: float = 3.0) -> void:
	if _snackbar_timer == null:
		_snackbar_timer = Timer.new()
		_snackbar_timer.one_shot = true
		_snackbar_timer.timeout.connect(_hide_snackbar)
		add_child(_snackbar_timer)
	_snackbar_timer.stop()
	snackbar_label.text = msg
	snackbar_container.visible = true
	snackbar_container.modulate = Color(1, 1, 1, 1)
	_snackbar_timer.start(duration)

func _hide_snackbar() -> void:
	var tween = create_tween()
	tween.set_parallel(false)
	tween.tween_property(snackbar_container, "modulate", Color(1, 1, 1, 0), 0.4)
	tween.tween_callback(func():
		snackbar_container.visible = false
	)

func _is_japanese_text(text: String) -> bool:
	if text.is_empty():
		return false
	for c in text:
		var unicode = c.unicode_at(0)
		if (unicode >= 0x3040 and unicode <= 0x309F) \
			or (unicode >= 0x30A0 and unicode <= 0x30FF) \
			or (unicode >= 0x4E00 and unicode <= 0x9FFF) \
			or (unicode >= 0x3400 and unicode <= 0x4DBF):
			return true
	return false

func _render_youtube_embed(video_id: String, parent: Node) -> void:
	var yt_url = "https://www.youtube.com/watch?v=%s" % video_id
	var thumb_url = "https://img.youtube.com/vi/%s/hqdefault.jpg" % video_id

	var yt_vbox = VBoxContainer.new()
	yt_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	parent.add_child(yt_vbox)

	var yt_width = _get_media_max_width()
	var yt_height = yt_width * 9 / 16
	var play_btn = Button.new()
	play_btn.text = video_id
	play_btn.custom_minimum_size = Vector2(yt_width, 40)
	play_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	play_btn.pressed.connect(func(): _open_url(yt_url))
	yt_vbox.add_child(play_btn)

	var thumb_rect = TextureRect.new()
	thumb_rect.custom_minimum_size = Vector2(yt_width, yt_height)
	thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb_rect.clip_contents = true
	thumb_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	yt_vbox.add_child(thumb_rect)

	thumb_rect.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_open_url(yt_url)
	)

	_load_youtube_thumbnail(thumb_url, thumb_rect)





func _load_youtube_thumbnail(url: String, target_rect: TextureRect) -> void:
	if not is_instance_valid(target_rect):
		return
	var http_request = HTTPRequest.new()
	add_child(http_request)
	var req_id = http_request.request(url)
	if req_id != OK:
		http_request.queue_free()
		return
	http_request.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		if not is_instance_valid(target_rect) or not is_instance_valid(http_request):
			return
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
			var image = Image.new()
			if image.load_jpg_from_buffer(body) == OK:
				target_rect.texture = ImageTexture.create_from_image(image)
		http_request.queue_free()
	)
