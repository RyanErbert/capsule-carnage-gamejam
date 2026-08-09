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

## Deployed game server — override with FRIENDSLOP_SERVER=ws://localhost:3001 for local dev.
const DEFAULT_SERVER := "wss://friendslop-gamejam.onrender.com"

var _ws := WebSocketPeer.new()
var _url := ""
var _handshake_done := false
var _was_open := false


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


func is_socket_connected() -> bool:
	return _handshake_done and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func emit_event(event: String, data: Variant = null) -> void:
	if not is_socket_connected():
		return
	var payload: Array = [event]
	if data != null:
		payload.append(data)
	_ws.send_text("42" + JSON.stringify(payload))


func _process(_delta: float) -> void:
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


func _handle_frame(frame: String) -> void:
	if frame.begins_with("0"):
		_ws.send_text("40")  # engine.io open -> join default namespace
	elif frame.begins_with("40"):
		_handshake_done = true
		socket_connected.emit()
	elif frame == "2":
		_ws.send_text("3")  # ping -> pong
	elif frame.begins_with("42"):
		var parsed: Variant = JSON.parse_string(frame.substr(2))
		if parsed is Array and parsed.size() >= 1:
			var event: String = str(parsed[0])
			var data: Variant = parsed[1] if parsed.size() > 1 else null
			event_received.emit(event, data)
