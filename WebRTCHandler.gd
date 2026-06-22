extends Node

enum State { IDLE, CONNECTING, SUBSCRIBED, CALLING, CONNECTED }

class PeerSession:
	var pubkey: String
	var state: int = State.IDLE
	var pc: WebRTCPeerConnection
	var dc: WebRTCDataChannel
	var is_initiator: bool = false
	var pending_ice: Array = []
	var ice_sent: int = 0
	var ice_rcvd: int = 0
	var file_recv: Dictionary = {}

const SIGNAL_KIND := 21000
const APP_TAG := "p2p-irc"

var state: int = State.IDLE
var relay_url := ""
var my_pubkey := ""
var world_pck_path := ""
var peers: Dictionary = {}

var dc: WebRTCDataChannel:
	get:
		for p in peers.values():
			if p.dc and p.dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
				return p.dc
		return null

signal state_changed(new_state: int)
signal stats_updated(dc_state: int, ice_sent: int, ice_rcvd: int, gather_state: int)
signal data_channel_opened(dc: WebRTCDataChannel, peer_pubkey: String)
signal data_channel_closed(peer_pubkey: String)
signal msg_received(msg: Dictionary, peer_pubkey: String)
signal file_progress(filename: String, received: int, total: int, peer_pubkey: String)
signal file_complete(filename: String, path: String, peer_pubkey: String)
signal file_error(filename: String, error: String, peer_pubkey: String)
signal file_sent(filename: String, peer_pubkey: String)
signal peer_joined(pubkey: String)

# ============================================================
# Public API
# ============================================================

func connect_to_relay(url: String):
	relay_url = url
	if not NostrGD.IsLoggedIn:
		_nsec = NostrGD.CreateNewKeyPair()
		if _nsec.is_empty():
			push_error("Failed to generate key")
			return
	my_pubkey = NostrGD.GetPublicKeyHex()
	state = State.CONNECTING
	state_changed.emit(state)
	_connect_time = 0.0
	NostrGD.ConnectToRelay(relay_url)
	NostrGD.ActivateRelayProcessing()

func cancel_connecting():
	NostrGD.DisconnectFromRelay(relay_url)
	state = State.IDLE
	state_changed.emit(state)

func join_host(host_pubkey: String):
	var ps = _get_or_create_session(host_pubkey)
	ps.state = State.SUBSCRIBED
	var msg = {"type": "join"}
	_send_signal(msg, host_pubkey)

func get_connected_peers() -> Array:
	var result = []
	for pubkey in peers:
		var ps = peers[pubkey] as PeerSession
		if ps.dc and ps.dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			result.append(pubkey)
	return result

func call_peer(pubkey: String):
	var ps = _get_or_create_session(pubkey)
	ps.state = State.CALLING
	if not _start_webrtc(ps, true):
		ps.state = State.IDLE
		return

func send_string(text: String):
	var pkt = text.to_utf8_buffer()
	for ps in peers.values():
		if ps.dc and ps.dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			ps.dc.put_packet(pkt)

func send_string_to(text: String, pubkey: String):
	var ps = peers.get(pubkey)
	if ps and ps.dc and ps.dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		ps.dc.put_packet(text.to_utf8_buffer())

func send_file(path: String):
	var fname = path.get_file()
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot open file: ", path)
		return
	var data = file.get_buffer(file.get_length())
	file.close()
	var meta = {"type": "file_meta", "name": fname, "size": data.size()}
	var done = {"type": "file_done", "name": fname}
	var meta_pkt = JSON.stringify(meta).to_utf8_buffer()
	var done_pkt = JSON.stringify(done).to_utf8_buffer()
	var offset := 0
	var chunks := []
	while offset < data.size():
		var chunk_size = mini(FILE_CHUNK_SIZE, data.size() - offset)
		chunks.append(data.slice(offset, offset + chunk_size))
		offset += chunk_size
	var targets := []
	for pubkey in peers:
		var ps = peers[pubkey] as PeerSession
		if ps.dc and ps.dc.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			targets.append(pubkey)
	if targets.is_empty():
		file_error.emit(fname, "No connected peers", "")
		return
	for pubkey in targets:
		var ps = peers[pubkey] as PeerSession
		if not ps.dc or ps.dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
			file_error.emit(fname, "Peer DC closed", pubkey)
			continue
		if ps.dc.put_packet(meta_pkt) != OK:
			file_error.emit(fname, "Failed to send meta", pubkey)
			continue
		var ci := 0
		var ok := true
		while ci < chunks.size():
			for _i in range(5):
				if ci >= chunks.size():
					break
				if not ps.dc or ps.dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
					push_error("send_file: DC closed for ", pubkey.left(12))
					ok = false
					break
				if ps.dc.put_packet(chunks[ci]) != OK:
					push_error("send_file: put_packet failed for ", pubkey.left(12))
					ok = false
					break
				ci += 1
			if not ok:
				break
			await get_tree().process_frame
		if not ok:
			continue
		ps.dc.put_packet(done_pkt)
		file_sent.emit(fname, pubkey)

func send_file_to(path: String, peer_pubkey: String):
	var fname = path.get_file()
	var ps = peers.get(peer_pubkey)
	if not ps or not ps.dc or ps.dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		file_error.emit(fname, "Peer not connected", peer_pubkey)
		return
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		file_error.emit(fname, "Cannot open file", peer_pubkey)
		return
	var data = file.get_buffer(file.get_length())
	file.close()
	if not ps.dc or ps.dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		file_error.emit(fname, "DC closed during read", peer_pubkey)
		return
	var meta = {"type": "file_meta", "name": fname, "size": data.size()}
	var done = {"type": "file_done", "name": fname}
	if ps.dc.put_packet(JSON.stringify(meta).to_utf8_buffer()) != OK:
		file_error.emit(fname, "Failed to send meta", peer_pubkey)
		return
	var offset := 0
	var ci := 0
	var total_chunks = ceili(float(data.size()) / FILE_CHUNK_SIZE)
	while offset < data.size():
		if not ps.dc or ps.dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
			file_error.emit(fname, "DC closed during send", peer_pubkey)
			return
		var chunk_size = mini(FILE_CHUNK_SIZE, data.size() - offset)
		var chunk = data.slice(offset, offset + chunk_size)
		if ps.dc.put_packet(chunk) != OK:
			file_error.emit(fname, "put_packet failed", peer_pubkey)
			return
		offset += chunk_size
		ci += 1
		if ci % 5 == 0 or ci == total_chunks:
			await get_tree().process_frame
	if not ps.dc or ps.dc.get_ready_state() != WebRTCDataChannel.STATE_OPEN:
		file_error.emit(fname, "DC closed before done", peer_pubkey)
		return
	ps.dc.put_packet(JSON.stringify(done).to_utf8_buffer())
	file_sent.emit(fname, peer_pubkey)

# ============================================================
# Internal
# ============================================================

var _nsec := ""
var _sig_sub_id := ""
var _connect_time := 0.0

const FILE_CHUNK_SIZE := 16384
var hud_label: Label

func _send_signal(msg: Dictionary, target_pubkey: String):
	var tags: Array = [["p", target_pubkey], ["s", APP_TAG]]
	NostrGD.SendCustomEvent(SIGNAL_KIND, JSON.stringify(msg), tags)

func _get_or_create_session(pubkey: String) -> PeerSession:
	if peers.has(pubkey):
		return peers[pubkey] as PeerSession
	var ps = PeerSession.new()
	ps.pubkey = pubkey
	peers[pubkey] = ps
	return ps

func hud(text: String):
	if hud_label:
		hud_label.text = text

func hud_log(msg: String):
	if not hud_label:
		return
	var lines := hud_label.text.split("\n", false)
	lines.append(msg)
	if lines.size() > 20:
		lines = lines.slice(lines.size() - 20)
	hud_label.text = "\n".join(lines)

func _ready():
	NostrGD.Connected.connect(_on_relay_connected)
	NostrGD.Disconnected.connect(_on_relay_disconnected)
	NostrGD.EventReceived.connect(_on_event_received)
	data_channel_opened.connect(_on_dc_opened_auto)
	print("WebRTCHandler ready")

func _enter_tree():
	call_deferred("_emit_initial_state")

func _emit_initial_state():
	state_changed.emit(state)

func _on_relay_connected(url: String):
	if url != relay_url:
		return
	if state == State.CONNECTING:
		my_pubkey = NostrGD.GetPublicKeyHex()
		hud_log("Relay connected: " + my_pubkey.left(12))
		_sig_sub_id = "sig_" + my_pubkey.left(8)
		var kinds: Array = [SIGNAL_KIND]
		NostrGD.RequestEventsWithTag(_sig_sub_id, kinds, "s", APP_TAG)
		state = State.SUBSCRIBED
		state_changed.emit(state)

func _on_relay_disconnected(url: String):
	if url != relay_url:
		return
	if state != State.IDLE:
		hud_log("Relay disconnected")
		state = State.IDLE
		state_changed.emit(state)

func _on_event_received(sub_id: String, event: Dictionary):
	if sub_id != _sig_sub_id and sub_id != "_":
		return
	var kind = event.get("kind", 0)
	if kind != SIGNAL_KIND:
		return
	var from = event.get("pubkey", "")
	if from == my_pubkey:
		return
	var content = event.get("content", "")
	var json = JSON.new()
	if json.parse(content) != OK:
		return
	var msg = json.get_data()
	if not msg is Dictionary:
		return
	var msg_type = msg.get("type", "")
	hud_log("Event: " + msg_type + " from " + from.left(12))

	# join は p タグ不要（新しいホスト宛に送られてくるため）
	if msg_type != "join":
		var tags: Array = event.get("tags", [])
		var is_for_me := false
		for t in tags:
			if t is Array and t.size() >= 2 and t[0] == "p" and t[1] == my_pubkey:
				is_for_me = true
				break
		if not is_for_me:
			hud_log("Skip signal not for me from " + from.left(12))
			return

	match msg_type:
		"join":
			var ps = _get_or_create_session(from)
			ps.state = State.SUBSCRIBED
			peer_joined.emit(from)
			hud("Guest joined: " + from.left(12))
			print("WebRTCHandler: join from ", from.left(12), " → calling peer")
			call_peer(from)

		"offer":
			var ps = _get_or_create_session(from)
			if ps.state != State.SUBSCRIBED:
				return
			ps.state = State.CALLING
			print("WebRTCHandler: Got offer from ", from.left(12), ", starting WebRTC...")
			if not _start_webrtc(ps, false):
				ps.state = State.IDLE
				return
			if ps.pc:
				ps.pc.set_remote_description("offer", msg.get("sdp", ""))
				_flush_pending_ice(ps)
		"answer":
			var ps = peers.get(from)
			if not ps or not ps.pc:
				return
			print("WebRTCHandler: Got answer from ", from.left(12), ", setting remote desc")
			ps.pc.set_remote_description("answer", msg.get("sdp", ""))
			_flush_pending_ice(ps)
		"ice":
			var ps = peers.get(from)
			if not ps or not ps.pc:
				return
			ps.ice_rcvd += 1
			ps.pending_ice.append(msg.duplicate())
			_flush_pending_ice(ps)

func _start_webrtc(ps: PeerSession, initiator: bool) -> bool:
	ps.is_initiator = initiator
	ps.pc = WebRTCPeerConnection.new()
	ps.pc.session_description_created.connect(func(p_type, p_sdp): _on_sdp_created(ps, p_type, p_sdp))
	ps.pc.ice_candidate_created.connect(func(mid, index, cand): _on_ice_candidate(ps, mid, index, cand))
	var result = ps.pc.initialize({
		"ice_servers": [
			{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]}
		]
	})
	if result != OK:
		push_error("WebRTC init failed for ", ps.pubkey.left(12))
		return false
	else:
		print("WebRTCHandler: WebRTC init OK for ", ps.pubkey.left(12), " initiator=", initiator)

	if initiator:
		ps.dc = ps.pc.create_data_channel("game")
		if ps.dc == null:
			push_error("Failed to create data channel for ", ps.pubkey.left(12))
			return false
		print("WebRTCHandler: DC created, creating offer for ", ps.pubkey.left(12))
		ps.pc.create_offer()
	else:
		ps.pc.data_channel_received.connect(func(ch): _on_dc_received(ps, ch))
	return true

func _flush_pending_ice(ps: PeerSession):
	if ps.pc == null:
		return
	for msg in ps.pending_ice:
		ps.pc.add_ice_candidate(msg.get("mid", ""), msg.get("mlineIndex", 0), str(msg.get("candidate", "")))
	ps.pending_ice.clear()

func _on_sdp_created(ps: PeerSession, p_type: String, p_sdp: String):
	print("WebRTCHandler: SDP created type=", p_type, " for ", ps.pubkey.left(12))
	ps.pc.set_local_description(p_type, p_sdp)
	_flush_pending_ice(ps)
	var msg = {"type": p_type, "sdp": p_sdp}
	_send_signal(msg, ps.pubkey)


func _filter_ipv4_from_sdp(sdp: String) -> String:
	return sdp

func _on_ice_candidate(ps: PeerSession, mid: String, index: int, candidate: String) -> void:
	ps.ice_sent += 1
	hud_log("ICE sent: " + candidate.left(80))
	var msg = {"type": "ice", "candidate": candidate, "mid": mid, "mlineIndex": index}
	_send_signal(msg, ps.pubkey)


func _is_ipv4_candidate(candidate: String) -> bool:
	# ICE candidate format: "candidate:<foundation> <component> <protocol> <priority> <address> <port> typ <type> ..."
	# IPv4 address pattern: 4 octets separated by dots
	# Match typical IPv4 in candidate string (e.g., "192.168.1.1" or "10.0.0.1")
	var regex := RegEx.new()
	regex.compile("\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b")
	return regex.search(candidate) != null

func _on_dc_received(ps: PeerSession, channel: WebRTCDataChannel):
	ps.dc = channel

func _handle_dc_packet(packet: PackedByteArray, peer_pubkey: String):
	var ps = peers.get(peer_pubkey)
	if not ps:
		return
	var raw_text := packet.get_string_from_utf8()
	if raw_text.begins_with("{"):
		var json = JSON.new()
		if json.parse(raw_text) == OK:
			var msg = json.get_data()
			if msg is Dictionary:
				var t = msg.get("type", "")
				if t == "file_meta":
					ps.file_recv = {
						"name": msg.get("name", ""),
						"size": msg.get("size", 0),
						"buffer": PackedByteArray()
					}
					hud_log("File meta: " + msg.get("name", "") + " (" + str(msg.get("size", 0)) + " bytes)")
					return
				elif t == "file_done":
					hud_log("File done, finalizing...")
					_finalize_file(peer_pubkey)
					return
				msg_received.emit(msg, peer_pubkey)
				return
	if not ps.file_recv.is_empty():
		ps.file_recv.buffer.append_array(packet)
		var name = ps.file_recv.get("name", "")
		var recv = ps.file_recv.buffer.size()
		var total = ps.file_recv.get("size", 0)
		file_progress.emit(name, recv, total, peer_pubkey)
		return

func _finalize_file(peer_pubkey: String):
	var ps = peers.get(peer_pubkey)
	if not ps or ps.file_recv.is_empty():
		return
	var ft = ps.file_recv
	var path = OS.get_user_data_dir().path_join(ft.name)
	hud_log("Writing " + str(ft.buffer.size()) + " bytes to " + path)
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		file_error.emit(ft.name, "Cannot write to " + path, peer_pubkey)
		ps.file_recv = {}
		return
	file.store_buffer(ft.buffer)
	file.close()
	ps.file_recv = {}
	hud_log("Write done, deferring load")
	call_deferred("_load_pck", path, ft.name, peer_pubkey)

func _load_pck(path: String, fname: String, peer_pubkey: String):
	hud_log("Loading PCK: " + path)
	var ok = ProjectSettings.load_resource_pack(path)
	hud_log("load_resource_pack returned: " + str(ok))
	print("_load_pck: ", fname, " ok=", ok, " peer=", peer_pubkey)
	if ok:
		file_complete.emit(fname, path, peer_pubkey)
	else:
		file_error.emit(fname, "Failed to load PCK", peer_pubkey)

func _on_dc_opened_auto(_dc: WebRTCDataChannel, peer_pubkey: String):
	if not world_pck_path.is_empty():
		hud_log("DC open, sending PCK to " + peer_pubkey.left(12))
		send_file_to(world_pck_path, peer_pubkey)
	else:
		hud_log("DC open for " + peer_pubkey.left(12) + " (no PCK ready)")

func _process(delta):
	if state == State.CONNECTING:
		_connect_time += delta
		if _connect_time > 10.0:
			push_error("Connection timeout - relay unreachable")
			NostrGD.DisconnectFromRelay(relay_url)
			state = State.IDLE
			state_changed.emit(state)

	var to_remove := []
	for pubkey in peers.keys():
		var ps = peers[pubkey] as PeerSession
		if ps.pc:
			ps.pc.poll()
		if ps.dc:
			var rs = ps.dc.get_ready_state()
			if rs == WebRTCDataChannel.STATE_OPEN and ps.state == State.CALLING:
				ps.state = State.CONNECTED
				print("WebRTCHandler: DC OPEN for ", pubkey.left(12))
				data_channel_opened.emit(ps.dc, pubkey)
			elif rs == WebRTCDataChannel.STATE_CLOSED and ps.state not in [State.CALLING, State.CONNECTED]:
				to_remove.append(pubkey)
				data_channel_closed.emit(pubkey)
			elif rs == WebRTCDataChannel.STATE_CLOSED and ps.state in [State.CALLING, State.CONNECTED]:
				_cleanup_peer(pubkey)
				data_channel_closed.emit(pubkey)
			while ps.dc.get_available_packet_count() > 0:
				_handle_dc_packet(ps.dc.get_packet(), pubkey)
	for pubkey in to_remove:
		_cleanup_peer(pubkey)

func _cleanup_peer(pubkey: String):
	var ps = peers.get(pubkey)
	if not ps:
		return
	if ps.dc:
		ps.dc.close()
	if ps.pc:
		ps.pc.close()
	peers.erase(pubkey)
