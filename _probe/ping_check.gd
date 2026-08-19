extends Node

## End to end against a real server: connect, then check that a round trip is
## measured locally AND that the server broadcasts everyone's.
##
## Listens on Net directly rather than standing up multiplayer_sync, which wants
## a real player node and would fault every frame without one.

var _t := 0.0
var _own := -1
var _map := -1


func _ready() -> void:
	Net.event_received.connect(_on_event)
	Net.connect_to_server(OS.get_environment("FRIENDSLOP_SERVER"))
	await get_tree().create_timer(1.0).timeout
	Net.emit_event("ready", {"name": "probe", "shape": "bear", "skinColor": "#ffffff"})


func _on_event(event: String, data: Variant) -> void:
	if event == "pings" and data is Dictionary:
		_map = (data as Dictionary).size()


func _process(delta: float) -> void:
	_t += delta
	if Net.ping_ms >= 0 and _own < 0:
		_own = Net.ping_ms
	if _t < 9.0:
		return
	_say(Net.is_socket_connected(), "connected to the server")
	_say(_own >= 0, "own round trip measured: %s" % ("%d ms" % _own if _own >= 0 else "never"))
	_say(_map > 0, "server broadcast a ping map (%d entries)" % _map)
	print("ping: %s" % ("all checks passed" if _own >= 0 and _map > 0 else "FAILED"))
	get_tree().quit()


func _say(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
