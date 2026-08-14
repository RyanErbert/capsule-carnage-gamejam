extends Node

## Bridges the local player and the Node server (PORT_BLUEPRINT.md §2, §8.4 Path A).
## Handles the join handshake (connect -> ready -> snapshots) and the player
## roster/movement events. Scoring, items, and the rest arrive in later phases.

signal scores_changed(scores: Dictionary)
signal holder_changed(holder_id: String)

const RemotePlayerScene := preload("res://Net/remote_player.tscn")
const SEND_RATE := 20.0  # Hz — the web client sent every frame; 20 Hz is plenty
const TAG_DISTANCE := 1.5  # web §1.9

@export var player: CharacterBody3D

var self_id := ""
var scores: Dictionary = {}       # id -> int (includes self)
var holder_id := ""
var _tag_cooldown := 0.0
var _remotes: Dictionary = {}  # id -> RemotePlayer node
var _send_accum := 0.0


func name_of(id: String) -> String:
	if id == self_id:
		return "You"
	return _remotes[id].player_name if _remotes.has(id) else "???"


func remotes() -> Dictionary:
	return _remotes


func _ready() -> void:
	add_to_group("net_sync")
	Net.socket_connected.connect(_on_socket_connected)
	Net.socket_disconnected.connect(_on_socket_disconnected)
	Net.server_outdated.connect(_on_server_outdated)
	Net.client_outdated.connect(_on_client_outdated)
	Net.event_received.connect(_on_event)
	if Net.is_socket_connected():
		_on_socket_connected()


func _on_socket_connected() -> void:
	# Two-phase join: server sends spectatorPlayers first; 'ready' enters the game.
	Net.emit_event("ready", {
		"type": "desktop",
		"name": Settings.player_name,
		"shape": "roundcube" if (player and player.use_cube) else "sphere",
		"skinColor": Settings.color_hex(),
		"skinImage": null,
		"model": null,
		"build": Net.git_commit(),
	})


## An outdated server is being rebuilt under us, so there is nothing to stay
## connected to. Same teardown as losing the connection: the level, the terrain
## and everything spawned in it go, and we come back up in the lobby.
func _on_server_outdated() -> void:
	_return_to_menu("server is behind, rebuilding")


## Nothing here can update us, and an old client on a new protocol desyncs
## quietly rather than loudly. Out of the match, and the lobby keeps JOIN
## disabled until the pull lands.
func _on_client_outdated() -> void:
	_return_to_menu("client is out of date, pull required")


func _on_socket_disconnected() -> void:
	# Losing the server mid-game: back to the menu, which shows the red
	# disconnected state and disables JOIN until the connection returns.
	_return_to_menu("lost connection to the server")
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
		"scores":
			scores = data
			scores_changed.emit(scores)
		"holderChanged":
			holder_id = str(data) if data != null else ""
			for id in _remotes:
				_remotes[id].set_holder(id == holder_id)
			if player and player.has_method("set_it"):
				player.set_it(holder_id == self_id)
			holder_changed.emit(holder_id)
		"tagCooldown":
			_tag_cooldown = float(data) / 1000.0  # server sends ms
		"playerJumped":
			var jid := str(data)
			if _remotes.has(jid):
				Sfx.jump(_remotes[jid].global_position)
		"droneHealth":
			var did := str(data.get("id", ""))
			if _remotes.has(did):
				_remotes[did].set_drone_hp(int(data.get("hp", 0)))
		"droneDestroyed":
			var xid := str(data.get("id", ""))
			if _remotes.has(xid):
				_remotes[xid].clear_drone()
		"kicked":
			_return_to_menu("kicked (inactivity)")
		"gameEnded":
			_return_to_menu("game ended by vote")
		"kicked", "gameEnded":
			# Menu flow comes in a later phase; for now just note it.
			print("[net] server ended session: ", event)


## Web returnToMenu(): full teardown + a fresh socket id, back to the lobby.
func _return_to_menu(reason: String) -> void:
	print("[net] returning to menu — %s" % reason)
	Net.reconnect()
	get_tree().change_scene_to_file.call_deferred("res://UI/main_menu.tscn")


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

	# Holder auto-tags on proximity (web §1.9: dist < 1.5, 4 s server cooldown)
	_tag_cooldown = maxf(0.0, _tag_cooldown - delta)
	if holder_id == self_id and _tag_cooldown <= 0.0:
		for id in _remotes:
			if player.global_position.distance_to(_remotes[id].global_position) < TAG_DISTANCE:
				Net.emit_event("tagPlayer", id)
				break

	_send_accum += delta
	if _send_accum < 1.0 / SEND_RATE:
		return
	_send_accum = 0.0
	var q: Quaternion = player.visual_quat()
	var payload := {
		"x": player.global_position.x,
		"y": player.global_position.y,
		"z": player.global_position.z,
		"qx": q.x, "qy": q.y, "qz": q.z, "qw": q.w,
		"smoothing": player.smoothing,  # web ball-morph field (1.0 for the bear)
		# Drone-style god mode: the body stays put and stays a normal,
		# vulnerable target — never render it as an untouchable ghost.
		"godmode": false,
	}
	# Drone out? Report it — the server tracks it as a shootable target and
	# remotes render it (with its health) at this spot.
	if player.godmode:
		var drone: Node = get_tree().get_first_node_in_group("god_drone")
		if drone is Node3D and drone.get("return_to") == null:
			var dp: Vector3 = drone.global_position
			payload["drone"] = {"x": dp.x, "y": dp.y, "z": dp.z}
	# Held weapon + where it's pointing, so remotes mount the same gun at the
	# same angle instead of everyone else running around empty-handed.
	var items: Node = player.get_node_or_null("ItemController")
	if items:
		var a: Vector3 = items.aim_dir()
		payload["w"] = items.held_type()
		payload["ax"] = a.x
		payload["ay"] = a.y
		payload["az"] = a.z
	Net.emit_event("playerMoved", payload)
