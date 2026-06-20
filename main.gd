extends Control

const Secp256k1 = preload("res://addons/nostr_godot/secp256k1.gd")

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
	$Sidebar/SidebarInner/NavSection/NavMenu/NavProfile,
	$Sidebar/SidebarInner/NavSection/NavMenu/NavSettings
]

enum Section { TIMELINE, PROFILE, SETTINGS }
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
var _pending_sorted_timeline: Array = []
var _pending_profile_events: Array[Dictionary] = []
var _relays_timeline_subscribed: Dictionary = {}
const TIMELINE_MAX_ITEMS: int = 50
const MAX_TIMELINE_RELAYS: int = 3

enum UIState { LOGGED_OUT, LOGIN_FORM, CREATE_FORM, LOGGED_IN }
var _ui_state: int = UIState.LOGGED_OUT

var _timeline_paused: bool = false
var _last_displayed_count: int = 0
var _last_displayed_ids: Dictionary = {}
var _sidebar_visible: bool = true
var _is_mobile: bool = false
var _bottom_nav: PanelContainer = null
var _bottom_nav_buttons: Array[Button] = []
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
	_setup_responsive_layout()
	if _is_mobile:
		_setup_mobile_bottom_nav()

	$MainPanel/ScrollContainer.clip_contents = true
	$MainPanel/ScrollContainer/Timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var nav_icons = [
		_get_icon("house", 16),
		_get_icon("user", 16),
		_get_icon("settings", 16),
	]
	for i in nav_buttons.size():
		if i < nav_icons.size() and nav_icons[i]:
			nav_buttons[i].icon = nav_icons[i]
		nav_buttons[i].add_theme_color_override("icon_normal_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_hover_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_pressed_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_focus_color", Color.WHITE)
		nav_buttons[i].add_theme_color_override("icon_disabled_color", Color.WHITE)

	$MainPanel/ScrollContainer.get_v_scroll_bar().value_changed.connect(_on_timeline_scrolled)

	message_input.text_submitted.connect(func(text):
		if not text.strip_edges().is_empty():
			_on_send_button_pressed()
	)

	message_input.gui_input.connect(func(event):
		if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.echo:
			message_input.release_focus()
	)

	$Sidebar/SidebarInner/AccountSection/VBoxContainer/LoggedInContainer/DisconnectButton.visible = false

	NostrGD.Connected.connect(_on_nostr_connected)
	NostrGD.Disconnected.connect(_on_nostr_disconnected)
	NostrGD.EventReceived.connect(_on_nostr_event_received)
	NostrGD.NoticeReceived.connect(_on_nostr_notice)
	NostrGD.ExtensionAuthCompleted.connect(_on_extension_auth_completed)
	NostrGD.TimelineUpdated.connect(_on_nostr_timeline_updated)


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
		else:
			_set_ui_state(UIState.LOGGED_OUT)
			status_label.text = "未ログイン"
	else:
		_set_ui_state(UIState.LOGGED_OUT)
		status_label.text = "未ログイン"

	_build_sections()
	_switch_section(Section.TIMELINE)
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

func _on_nostr_disconnected(url: String) -> void:
	_relays_timeline_subscribed.erase(url)

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
	var icon_names := ["house", "user", "settings"]
	var section_names := ["タイムライン", "プロフィール", "設定"]
	var section_indices := [Section.TIMELINE, Section.PROFILE, Section.SETTINGS]
	for i in icon_names.size():
		var btn := Button.new()
		btn.flat = true
		btn.icon = _get_icon(icon_names[i], 20)
		btn.tooltip_text = section_names[i]
		btn.custom_minimum_size = Vector2(0, BOTTOM_NAV_HEIGHT)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_bottom_nav_pressed.bind(section_indices[i]))
		hbox.add_child(btn)
		_bottom_nav_buttons.append(btn)
	_update_bottom_nav_highlight()
	add_child(_bottom_nav)

func _update_bottom_nav_highlight() -> void:
	if _bottom_nav_buttons.is_empty():
		return
	for i in _bottom_nav_buttons.size():
		var btn = _bottom_nav_buttons[i]
		var section_map := [Section.TIMELINE, Section.PROFILE, Section.SETTINGS]
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

func _on_show_login_form() -> void:
	_set_ui_state(UIState.LOGIN_FORM)

func _on_show_create_form() -> void:
	_set_ui_state(UIState.CREATE_FORM)

func _on_back_to_auth_choice() -> void:
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
	_build_profile_section()
	_build_settings_section()

func _build_profile_section() -> void:
	var panel = $MainPanel/ProfilePanel
	if panel.get_child_count() > 0:
		return

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

	var nl = Label.new()
	nl.name = "ProfileName"
	nl.add_theme_font_size_override("font_size", 22)
	vbox.add_child(nl)

	var al = Label.new()
	al.name = "ProfileAbout"
	al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	al.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	vbox.add_child(al)

	var pl = Label.new()
	pl.name = "ProfilePubkey"
	pl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(pl)

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
	_pending_sorted_timeline.clear()
	_pending_profile_events.clear()
	for child in timeline.get_children():
		child.queue_free()
	pending_labels.clear()
	_connect_relays()
	status_label.text = "リレー設定を保存・再接続しました"

func _switch_section(section: int) -> void:
	_current_section = section

	if _ui_state == UIState.CREATE_FORM and NostrGD.IsLoggedIn:
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
	$MainPanel/ProfilePanel.hide()
	$MainPanel/SettingsPanel.hide()

	var names = {
		Section.TIMELINE: "タイムライン",
		Section.PROFILE: "プロフィール",
		Section.SETTINGS: "設定"
	}
	section_header.text = names.get(section, "セクション")

	match section:
		Section.TIMELINE:
			$MainPanel/ScrollContainer.show()
			if not _is_mobile:
				$MainPanel/InputBar.visible = (_ui_state == UIState.LOGGED_IN)
		Section.PROFILE:
			$MainPanel/ProfilePanel.show()
			$MainPanel/InputBar.hide()
			_refresh_profile()
		Section.SETTINGS:
			$MainPanel/SettingsPanel.show()
			$MainPanel/InputBar.hide()

	_update_nav_highlight()
	_update_bottom_nav_highlight()

	if _is_mobile:
		if section == Section.TIMELINE and _ui_state == UIState.LOGGED_IN:
			$MainPanel/InputBar.visible = true
		else:
			$MainPanel/InputBar.visible = false

func _refresh_profile() -> void:
	var panel = $MainPanel/ProfilePanel
	var name_label = panel.get_node_or_null("ProfileScroll/ProfileMargin/ProfileVBox/ProfileName")
	if name_label == null:
		for c in panel.get_children():
			panel.remove_child(c)
			c.free()
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
		var nl = Label.new()
		nl.name = "ProfileName"
		nl.add_theme_font_size_override("font_size", 22)
		vbox.add_child(nl)
		var al = Label.new()
		al.name = "ProfileAbout"
		al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		al.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		vbox.add_child(al)
		var pl = Label.new()
		pl.name = "ProfilePubkey"
		pl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(pl)
		var cb = Button.new()
		cb.text = "Pubkey をコピー"
		cb.pressed.connect(func():
			_safe_clipboard_set(NostrGD.GetPublicKeyHex())
			status_label.text = "Pubkey をコピーしました"
		)
		vbox.add_child(cb)
		name_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileName")
	var about_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfileAbout")
	var pubkey_label = panel.get_node("ProfileScroll/ProfileMargin/ProfileVBox/ProfilePubkey")

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

func _on_nav_profile() -> void:
	_switch_section(Section.PROFILE)

func _on_nav_settings() -> void:
	_switch_section(Section.SETTINGS)

func _on_nostr_notice(url: String, message: String) -> void:
	_show_snackbar("[%s] %s" % [url.get_file(), message], 4.0)
	print("[%s]からの通知: %s" % [url, message])





func _on_nostr_event_received(subscription_id: String, event_dict: Dictionary) -> void:
	match subscription_id:
		"profile_resolver":
			_profile_request_active = false
			_profile_request_time = 0
			_parse_profile_event(event_dict)
		_:
			if event_dict.has("kind") and event_dict["kind"] == 0:
				_parse_profile_event(event_dict)









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
			"display_name": display_name
		}
		_refresh_profile()

		NostrGD.SendProfileMetaData(
			user_name,
			display_name,
			"P2P IRC Chat"
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
	for entry in RELAY_URL:
		NostrGD.DisconnectFromRelay(_relay_url(entry))
	_set_ui_state(UIState.LOGGED_OUT)
	status_label.text = "切断しました"

func _on_send_button_pressed() -> void:
	var content = message_input.text.strip_edges()
	if content.is_empty() or not NostrGD.IsLoggedIn:
		return
	NostrGD.SendTextNote(content)
	message_input.clear()





func _rebuild_timeline_item(event: Dictionary) -> void:
	var pubkey: String = event["pubkey"]
	var content: String = event["content"]
	var event_id: String = event.get("id", "")

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

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	post_panel.add_child(vbox)

	var name_label = Label.new()
	name_label.add_theme_color_override("font_color", Color.GREEN_YELLOW)
	vbox.add_child(name_label)

	var entry_label = Label.new()
	entry_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(entry_label)

	if profile_cache.has(pubkey) and profile_cache[pubkey] is Dictionary:
		var profile = profile_cache[pubkey]
		name_label.text = profile.get("display_name", profile.get("name", "Unknown"))
		entry_label.text = content
	else:
		name_label.text = "[%s...]" % pubkey.left(8)
		entry_label.text = content

		if not pending_labels.has(pubkey):
			pending_labels[pubkey] = []
		pending_labels[pubkey].append({
			"name_label": name_label,
			"content": content
		})
		if not pubkey_request_pool.has(pubkey):
			pubkey_request_pool.append(pubkey)

	var time_str = Time.get_datetime_string_from_unix_time(event.get("created_at", 0), true).left(16)
	var time_label = Label.new()
	time_label.text = time_str
	time_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	time_label.add_theme_font_size_override("font_size", 10)
	vbox.add_child(time_label)

	event_id = event.get("id", "")

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

		if pending_labels.has(pubkey):
			for item in pending_labels[pubkey]:
				if item.has("name_label") and is_instance_valid(item["name_label"]):
					item["name_label"].text = user_name
			pending_labels.erase(pubkey)

		if NostrGD.IsLoggedIn and pubkey == NostrGD.GetPublicKeyHex() and _current_section == Section.PROFILE:
			_refresh_profile()

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


