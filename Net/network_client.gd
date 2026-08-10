extends Node

## Socket.io client for the friendslop-web Node server (PORT_BLUEPRINT.md §8.4 Path A).
## Speaks the Engine.IO v4 websocket framing directly so server.js needs no changes:
##   0{json}  -> engine.io open        (we reply "40" to join the "/" namespace)
##   40{json} -> namespace connected
##   2 / 3    -> ping / pong
##   42["event", data] -> event message

signal socket_connected
signal socket_disconnected
signal event_received(event: String, data: Variant)

## Deployed game server (auto-deploys from this repo's main branch).
## Override with FRIENDSLOP_SERVER=ws://localhost:3001 for local dev.
const DEFAULT_SERVER := "wss://capsule-carnage-gamejam.onrender.com"

const RECONNECT_DELAY := 3.0  # seconds between retries after a drop

var _ws := WebSocketPeer.new()
var _url := ""
var _handshake_done := false
var _was_open := false

## Creative-level world state, cached so a scene opened later can catch up
## (the server sends the snapshot on connection, long before scenes exist).
var creative_grid: Variant = null
var terrain_edits: Array = []
var _reconnect_timer := 0.0


func _ready() -> void:
	var server := OS.get_environment("FRIENDSLOP_SERVER")
	if server.is_empty():
		server = DEFAULT_SERVER
	connect_to_server(server)


## Current git commit (short) — used for the HUD build label and the server
## version check. Returns "dev" when not running from a clone (e.g. exports).
func git_commit() -> String:
	var head := FileAccess.open("res://.git/HEAD", FileAccess.READ)
	if head == null:
		return "dev"
	var line := head.get_as_text().strip_edges()
	if not line.begins_with("ref: "):
		return line.left(7)  # detached HEAD
	var ref := line.substr(5)
	var ref_file := FileAccess.open("res://.git/" + ref, FileAccess.READ)
	if ref_file:
		return ref_file.get_as_text().strip_edges().left(7)
	var packed := FileAccess.open("res://.git/packed-refs", FileAccess.READ)
	if packed:
		for l in packed.get_as_text().split("\n"):
			if l.ends_with(" " + ref):
				return l.get_slice(" ", 0).left(7)
	return "dev"


func connect_to_server(url: String) -> void:
	_url = url.trim_suffix("/") + "/socket.io/?EIO=4&transport=websocket"
	_handshake_done = false
	var err := _ws.connect_to_url(_url)
	if err != OK:
		push_warning("NetworkClient: connect failed (%s) — running offline" % err)


## Drop the socket and rejoin with a fresh id (web returnToMenu did
## socket.disconnect(); socket.connect()).
func reconnect() -> void:
	_ws = WebSocketPeer.new()
	_handshake_done = false
	_was_open = false
	var err := _ws.connect_to_url(_url)
	if err != OK:
		push_warning("NetworkClient: reconnect failed (%s)" % err)


func is_socket_connected() -> bool:
	return _handshake_done and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## Events emitted before the handshake finishes wait here (socket.io buffers
## the same way) — e.g. the creative level announces its grid right after a
## main-thread-blocking terrain build, when the handshake may not be done.
var _outbox: Array = []

func emit_event(event: String, data: Variant = null) -> void:
	var payload: Array = [event]
	if data != null:
		payload.append(data)
	if not is_socket_connected():
		_outbox.append(payload)
		if _outbox.size() > 64:
			_outbox.pop_front()
		return
	_ws.send_text("42" + JSON.stringify(payload))


func _process(delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_was_open = true
		while _ws.get_available_packet_count() > 0:
			_handle_frame(_ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_open:
			_was_open = false
			_handshake_done = false
			socket_disconnected.emit()
			print("[net] connection lost — retrying every %.0fs" % RECONNECT_DELAY)
		# Auto-reconnect (server redeploys drop everyone; rejoin the new instance).
		# On reconnect multiplayer_sync re-sends 'ready', which also re-runs the
		# server version check.
		if _url != "":
			_reconnect_timer += delta
			if _reconnect_timer >= RECONNECT_DELAY:
				_reconnect_timer = 0.0
				_ws.connect_to_url(_url)


func _handle_frame(frame: String) -> void:
	if frame.begins_with("0"):
		_ws.send_text("40")  # engine.io open -> join default namespace
	elif frame.begins_with("40"):
		_handshake_done = true
		for payload in _outbox:
			_ws.send_text("42" + JSON.stringify(payload))
		_outbox.clear()
		socket_connected.emit()
	elif frame == "2":
		_ws.send_text("3")  # ping -> pong
	elif frame.begins_with("42"):
		var parsed: Variant = JSON.parse_string(frame.substr(2))
		if parsed is Array and parsed.size() >= 1:
			var event: String = str(parsed[0])
			var data: Variant = parsed[1] if parsed.size() > 1 else null
			match event:
				"creativeGrid":
					creative_grid = data
					terrain_edits.clear()
				"terrainEdit":
					terrain_edits.append(data)
				"terrainEdits":
					terrain_edits = data if data is Array else []
			event_received.emit(event, data)
