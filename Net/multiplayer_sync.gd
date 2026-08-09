extends Node

## Bridges the local player and the Node server (PORT_BLUEPRINT.md §2, §8.4 Path A).
## Handles the join handshake (connect -> ready -> snapshots) and the player
## roster/movement events. Scoring, items, and the rest arrive in later phases.

const RemotePlayerScene := preload("res://Net/remote_player.tscn")
const SEND_RATE := 20.0  # Hz — the web client sent every frame; 20 Hz is plenty

@export var player: CharacterBody3D

var self_id := ""
var _remotes: Dictionary = {}  # id -> RemotePlayer node
var _send_accum := 0.0


func _ready() -> void:
	Net.socket_connected.connect(_on_socket_connected)
	Net.socket_disconnected.connect(_on_socket_disconnected)
	Net.event_received.connect(_on_event)
	if Net.is_socket_connected():
		_on_socket_connected()


func _on_socket_connected() -> void:
	# Two-phase join: server sends spectatorPlayers first; 'ready' enters the game.
	Net.emit_event("ready", {
		"type": "desktop",
		"name": OS.get_environment("USERNAME").left(16) if OS.get_environment("USERNAME") else "GodotBear",
		"shape": "sphere",
		"skinColor": "#b5651d",
		"skinImage": null,
		"model": null,
	})


func _on_socket_disconnected() -> void:
	for id in _remotes:
		_remotes[id].queue_free()
	_remotes.clear()
	self_id = ""


func _on_event(event: String, data: Variant) -> void:
	match event:
		"currentPlayers":
			self_id = str(data.get("selfId", ""))
			var players: Dictionary = data.get("players", {})
			for id in players:
				if str(id) != self_id:
					_spawn_remote(str(id), players[id])
		"newPlayer":
			var id := str(data.get("id", ""))
			if id != "" and id != self_id:
				_spawn_remote(id, data)
		"playerMoved":
			var id := str(data.get("id", ""))
			if _remotes.has(id):
				_remotes[id].apply_move(data)
		"playerDisconnected":
			var id := str(data)
			if _remotes.has(id):
				_remotes[id].queue_free()
				_remotes.erase(id)
		"kicked", "gameEnded":
			# Menu flow comes in a later phase; for now just note it.
			print("[net] server ended session: ", event)


func _spawn_remote(id: String, data: Dictionary) -> void:
	if _remotes.has(id):
		return
	var remote := RemotePlayerScene.instantiate()
	add_child(remote)
	remote.setup(id, data)
	_remotes[id] = remote
	print("[net] spawned remote player '%s' (%s) at %s" % [remote.player_name, id, remote.target_position])


func _physics_process(delta: float) -> void:
	if not player or not Net.is_socket_connected() or self_id == "":
		return
	_send_accum += delta
	if _send_accum < 1.0 / SEND_RATE:
		return
	_send_accum = 0.0
	var q := player.global_transform.basis.get_rotation_quaternion()
	Net.emit_event("playerMoved", {
		"x": player.global_position.x,
		"y": player.global_position.y,
		"z": player.global_position.z,
		"qx": q.x, "qy": q.y, "qz": q.z, "qw": q.w,
		"smoothing": 1.0,  # web ball-morph field; we're always a sphere
		"godmode": false,
	})
