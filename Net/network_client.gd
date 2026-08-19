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
signal server_outdated
signal client_outdated

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
var creative_grid: Variant = null  # {layers: [4 x 32-int bitmasks]}
var terrain_edits: Array = []
var paint_rows: Variant = null  # in-progress editor canvas, same layered shape
var game_settings: Dictionary = {}  # server-authoritative global settings
var spawn_points: Array = []        # placed spawn markers ({id,x,y,z})
var spawn_zones: Dictionary = {}    # socket id -> [r, c] claimed in the editor
var claim_state: Variant = null     # Xonix land-grab board, if one is running
var start_vote: Variant = null      # editor poll on cutting the sculpt short
var end_vote: Variant = null        # in-match poll on ending the round
var presence: Array = []            # everyone connected: {id, name, color, where}
var chat_log: Array = []            # the room's conversation, replayed on connect
const CHAT_LOG_MAX := 80
var socket_id := ""                 # our own id, so we know which zone is ours
var server_build := ""              # commit the SERVER is running
var _uptime_ms := 0                 # ...how long it had been up when it told us
var _uptime_at := 0.0               # ...and our clock when that arrived
var server_build_time := 0          # when the server's commit was made
var server_version := [0, 0, 0]     # ...and the version it is running
var _reconnect_timer := 0.0


func _ready() -> void:
	var server := OS.get_environment("FRIENDSLOP_SERVER")
	if server.is_empty():
		server = DEFAULT_SERVER
	connect_to_server(server)


## Seconds the server has been up, carried forward on our own clock between
## snapshots. -1 when it has not told us yet.
func server_uptime() -> float:
	if _uptime_at <= 0.0:
		return -1.0
	return float(_uptime_ms) / 1000.0 + (Time.get_ticks_msec() / 1000.0 - _uptime_at)


func note_server(build: String, uptime_ms: int, build_time := 0,
		version: Array = []) -> void:
	var was := server_build
	server_build = build
	server_build_time = build_time
	if version.size() == 3:
		server_version = [int(version[0]), int(version[1]), int(version[2])]
	_uptime_ms = uptime_ms
	_uptime_at = Time.get_ticks_msec() / 1000.0
	if was == build:
		return
	if server_stale():
		_rebuild_server()
	elif client_stale():
		client_outdated.emit()


## A server on an older commit is not something to play on: the protocol and the
## world generator both move. Kick the rebuild once, then let the disconnect that
## follows drop everyone to a clean lobby.
const DEPLOY_HOOK := "https://api.render.com/deploy/srv-d9s2kkegekts73faq3vg?key=psfptLVM8D4"

var _rebuild_sent := ""


func _rebuild_server() -> void:
	if _rebuild_sent == server_build:
		return                     # already asked, for this exact stale build
	_rebuild_sent = server_build
	print("[net] server is on %s, we are on %s -- asking for a rebuild" % [
		server_build, git_commit()])
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, code, _h, _b):
		print("[net] rebuild hook returned %d" % code)
		req.queue_free())
	if req.request(DEPLOY_HOOK, [], HTTPClient.METHOD_POST, "") != OK:
		req.queue_free()
	server_outdated.emit()


## version.json, the one source of truth for which build is which. A hash only
## says two builds DIFFER; a number says which came first, which is the whole
## question. Comparing commit dates worked but had to parse a reflog on both
## ends and was blank in any export without a .git.
var _ver: Array = []


func version() -> Array:
	if not _ver.is_empty():
		return _ver
	_ver = [0, 0, 0]
	var f := FileAccess.open("res://version.json", FileAccess.READ)
	if f:
		var j: Variant = JSON.parse_string(f.get_as_text())
		if j is Dictionary:
			_ver = [int((j as Dictionary).get("major", 0)),
				int((j as Dictionary).get("minor", 0)),
				int((j as Dictionary).get("build", 0))]
	return _ver


func version_text() -> String:
	var v := version()
	return "v%d.%d.%d" % [v[0], v[1], v[2]]


## -1 we are older, 0 same, 1 we are newer.
func _cmp_version() -> int:
	var mine := version()
	for i in 3:
		if mine[i] != int(server_version[i]):
			return 1 if mine[i] > int(server_version[i]) else -1
	return 0


func server_stale() -> bool:
	return _cmp_version() > 0


## We are the old one. Rebuilding the server would not help; the fix is a pull.
func client_stale() -> bool:
	return _cmp_version() < 0


## "2h 14m", "3d 04h", "45s" -- whatever reads at a glance.
func uptime_text() -> String:
	var s := server_uptime()
	if s < 0.0:
		return "?"
	if s < 60.0:
		return "%ds" % int(s)
	if s < 3600.0:
		return "%dm %02ds" % [int(s / 60.0), int(s) % 60]
	if s < 86400.0:
		return "%dh %02dm" % [int(s / 3600.0), int(s / 60.0) % 60]
	return "%dd %02dh" % [int(s / 86400.0), int(s / 3600.0) % 24]


## The commit's own date, so a build label says WHEN as well as which.
func commit_when() -> String:
	var t := git_commit_time()
	if t <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


## When HEAD last moved, from the reflog -- the commit object itself is zlib and
## not worth unpacking in GDScript. Unix seconds, 0 if unknown.
func git_commit_time() -> int:
	var f := FileAccess.open("res://.git/logs/HEAD", FileAccess.READ)
	if f == null:
		return 0
	var last := ""
	for l in f.get_as_text().split("
"):
		if not l.strip_edges().is_empty():
			last = l
	var head := last.split("	")[0].split(" ")
	# <old> <new> <name> <email> <unix> <tz>
	for i in range(head.size() - 1, -1, -1):
		var tok: String = head[i]
		if tok.is_valid_int() and tok.length() >= 9:
			return int(tok)
	return 0


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

## Round trip to the server in milliseconds, -1 until the first reply lands.
## Measured app-level rather than off engine.io's own heartbeat: that fires
## about twice a minute, which is a number from the past by the time you look.
var ping_ms := -1
const PING_INTERVAL := 2.0
const PING_SMOOTH := 0.4      # new sample's share, so one bad packet is not the reading
var _ping_accum := 0.0


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
		if _handshake_done:
			_ping_accum += delta
			if _ping_accum >= PING_INTERVAL:
				_ping_accum = 0.0
				# Our own reading rides along, so the server can tell everyone
				# else what this client's connection is like without timing it.
				emit_event("netPing", {"t": Time.get_ticks_msec(), "rtt": ping_ms})
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_open:
			_was_open = false
			_handshake_done = false
			ping_ms = -1
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
				"chatHistory":
					chat_log = data if data is Array else []
				"chatMessage", "systemMessage":
					# Mirror of the server's log, so a chat box built by the
					# NEXT scene opens on the conversation so far.
					if data is Dictionary:
						var row: Dictionary = (data as Dictionary).duplicate()
						row["sys"] = event == "systemMessage"
						chat_log.append(row)
						while chat_log.size() > CHAT_LOG_MAX:
							chat_log.pop_front()
				"presence":
					presence = data if data is Array else []
				"startVote":
					start_vote = data
				"endVote":
					end_vote = data
				"creativeGrid":
					creative_grid = data
					terrain_edits.clear()
				"terrainEdit":
					terrain_edits.append(data)
				"terrainEdits":
					terrain_edits = data if data is Array else []
				"creativePaint":
					paint_rows = data
				"paintCleared":
					paint_rows = null
				"netPong":
					if data is Dictionary:
						var rtt := Time.get_ticks_msec() - int((data as Dictionary).get("t", 0))
						if ping_ms < 0:
							ping_ms = rtt
						else:
							ping_ms = int(round(lerpf(float(ping_ms), float(rtt), PING_SMOOTH)))
				"hello":
					if data is Dictionary:
						socket_id = str(data.get("id", ""))
				"spawnZones":
					spawn_zones = data if data is Dictionary else {}
				"claimState":
					claim_state = data
				"gameSettings":
					game_settings = data if data is Dictionary else {}
				"gameEnded":
					# Full reset: the server wiped the field and the grid
					creative_grid = null
					terrain_edits.clear()
					paint_rows = null
					spawn_points = []
					spawn_zones = {}
					claim_state = null
				"currentSpawns":
					spawn_points = data if data is Array else []
				"spawnPlaced":
					spawn_points.append(data)
				"spawnRemoved":
					for i in spawn_points.size():
						if str(spawn_points[i].get("id", "")) == str(data):
							spawn_points.remove_at(i)
							break
			# Every snapshot the server opens with carries what it is running and
			# how long it has been up; the pill is driven off these.
			if event == "spectatorPlayers" and data is Dictionary:
				note_server(str((data as Dictionary).get("build", "")),
					int((data as Dictionary).get("uptimeMs", 0)),
					int((data as Dictionary).get("buildTime", 0)),
					(data as Dictionary).get("version", []) as Array)
			event_received.emit(event, data)
