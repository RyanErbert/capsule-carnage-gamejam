extends Node3D

## Server-placed world objects: pedestals, launch/boost pads, teleporters
## (PORT_BLUEPRINT.md §4.1, §4.6, §4.7). Visuals are built in code (the web
## used prefab glb + procedural geometry). Triggers are client-side like the
## web: pedestal pickup < 1.8, pad/teleporter trigger < 1.5.

const PICKUP_DIST := 1.8
const TRIGGER_DIST := 1.5
const TELEPORT_COOLDOWN := 1.5
const CRYSTAL_COLORS := {
	"green": Color("#44ff44"), "red": Color("#ff4444"), "yellow": Color("#ffff44"),
}

@export var player: CharacterBody3D

var _item_controller: Node
var _pedestals: Dictionary = {}   # id -> {node, crystal, has_item, type}
var _pads: Array = []             # {type, pos: Vector3, dx, dz, node}
var _teleporters: Array = []      # {a: Vector3, b: Vector3, nodes: [..]}
var _teleport_cd := 0.0
var _pending_ghost: MeshInstance3D = null
var _time := 0.0
var _spawn_markers: Dictionary = {}   # id -> Node3D


func _ready() -> void:
	Net.event_received.connect(_on_net_event)
	if player:
		_item_controller = player.get_node_or_null("ItemController")
	for sp in Net.spawn_points:
		_add_spawn(sp)
	_sync_player_spawns()


## Placed spawn beacons: a small pillar of light. Player respawns use them.
func _add_spawn(sp: Dictionary) -> void:
	var id := str(sp.get("id", ""))
	if id == "" or _spawn_markers.has(id):
		return
	var node := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.7
	cyl.height = 3.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.9, 1.0, 0.25)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cyl.material = mat
	node.mesh = cyl
	node.position = Vector3(sp.get("x", 0.0), float(sp.get("y", 0.0)) + 1.5, sp.get("z", 0.0))
	add_child(node)
	_spawn_markers[id] = node


func _sync_player_spawns() -> void:
	if player == null or Net.spawn_points.is_empty():
		return
	var pts: Array = []
	for sp in Net.spawn_points:
		pts.append(Vector3(sp.get("x", 0.0), float(sp.get("y", 0.0)) + 1.0, sp.get("z", 0.0)))
	player.spawn_points = pts


## Nearest spawn marker within `radius` — god menu delete. {} if none.
func nearest_spawn(pos: Vector3, radius := 2.5) -> Dictionary:
	var best := {}
	for id in _spawn_markers:
		var d: float = _spawn_markers[id].position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _spawn_markers[id].position}
	return best


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentPedestals":
			for id in _pedestals:
				_pedestals[id]["node"].queue_free()
			_pedestals.clear()
			for ped in data:
				_add_pedestal(ped)
		"pedestalPlaced":
			_add_pedestal(data)
		"pedestalRemoved":
			var id := str(data)
			if _pedestals.has(id):
				_pedestals[id]["node"].queue_free()
				_pedestals.erase(id)
		"pedestalsUpdated":
			for ped in data:
				var id := str(ped.get("id", ""))
				if _pedestals.has(id):
					_pedestals[id]["has_item"] = ped.get("currentItem") != null
					_pedestals[id]["crystal"].visible = _pedestals[id]["has_item"]
		"currentPads":
			for p in _pads:
				p["node"].queue_free()
			_pads.clear()
			for p in data:
				_add_pad(p)
		"padPlaced":
			_add_pad(data)
		"currentTeleporters":
			for t in _teleporters:
				for n in t["nodes"]:
					n.queue_free()
			_teleporters.clear()
			for t in data:
				_add_teleporter(t)
		"teleporterPlaced":
			_add_teleporter(data)
		"currentSpawns":
			for id in _spawn_markers:
				_spawn_markers[id].queue_free()
			_spawn_markers.clear()
			for sp in data:
				_add_spawn(sp)
			_sync_player_spawns()
		"spawnPlaced":
			_add_spawn(data)
			_sync_player_spawns()
		"spawnRemoved":
			var sid := str(data)
			if _spawn_markers.has(sid):
				_spawn_markers[sid].queue_free()
				_spawn_markers.erase(sid)
			_sync_player_spawns()


## Nearest pedestal within `radius` — god menu delete. {} if none.
func nearest_deletable(pos: Vector3, radius := 2.5) -> Dictionary:
	var best := {}
	for id in _pedestals:
		var node: Node3D = _pedestals[id]["node"]
		var d: float = node.position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": node.position}
	return best


# --- Builders -----------------------------------------------------------

func _add_pedestal(ped: Dictionary) -> void:
	var id := str(ped.get("id", ""))
	if id == "" or _pedestals.has(id):
		return
	var root := Node3D.new()
	root.position = Vector3(ped.get("x", 0.0), ped.get("y", 0.0), ped.get("z", 0.0))
	root.rotation.y = float(ped.get("ry", 0.0))
	add_child(root)

	# The plate: a shallow, tapered disc flush with the ground
	var plate := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.85
	cyl.bottom_radius = 1.2
	cyl.height = 0.28
	var col_mat := StandardMaterial3D.new()
	col_mat.albedo_color = Color(0.55, 0.55, 0.6)
	col_mat.roughness = 0.8
	cyl.material = col_mat
	plate.mesh = cyl
	plate.position.y = 0.14
	root.add_child(plate)

	# The item: a pill lying on its side, colored by category
	var crystal := MeshInstance3D.new()
	var pill := CapsuleMesh.new()
	pill.radius = 0.17
	pill.height = 0.78
	crystal.mesh = pill
	var color: Color = CRYSTAL_COLORS.get(str(ped.get("type", "green")), Color.WHITE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.6
	crystal.material_override = mat
	crystal.rotation.z = PI / 2.0  # lie flat: it's a pill, not an obelisk
	crystal.position.y = 0.95
	crystal.visible = ped.get("currentItem") != null
	root.add_child(crystal)

	_pedestals[id] = {
		"node": root, "crystal": crystal,
		"has_item": ped.get("currentItem") != null,
		"type": str(ped.get("type", "green")),
	}


func _add_pad(p: Dictionary) -> void:
	var node := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 0.1, 1.2)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#44ff44")
	mat.emission_enabled = true
	mat.emission = Color("#114411")
	mat.emission_energy_multiplier = 2.0
	box.material = mat
	node.mesh = box
	node.position = Vector3(p.get("x", 0.0), float(p.get("y", 0.0)) + 0.05, p.get("z", 0.0))

	# White marker: boost pads get a direction bar, launch pads a square
	var marker := MeshInstance3D.new()
	var mbox := BoxMesh.new()
	var mmat := StandardMaterial3D.new()
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.albedo_color = Color.WHITE
	mbox.material = mmat
	if str(p.get("type", "")) == "boost_pad":
		mbox.size = Vector3(0.2, 0.15, 0.8)
		node.rotation.y = atan2(float(p.get("dx", 0.0)), float(p.get("dz", 1.0)))
	else:
		mbox.size = Vector3(0.6, 0.15, 0.6)
	marker.mesh = mbox
	node.add_child(marker)
	add_child(node)

	_pads.append({
		"type": str(p.get("type", "launch_pad")),
		"pos": Vector3(p.get("x", 0.0), p.get("y", 0.0), p.get("z", 0.0)),
		"dx": float(p.get("dx", 0.0)), "dz": float(p.get("dz", 0.0)),
		"node": node,
	})


func _teleporter_disc(pos: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.8
	cyl.bottom_radius = 0.8
	cyl.height = 0.2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#33ccff")
	mat.emission_enabled = true
	mat.emission = Color("#0a6699")
	mat.emission_energy_multiplier = 0.8
	cyl.material = mat
	node.mesh = cyl
	node.position = pos
	add_child(node)
	return node


func _add_teleporter(t: Dictionary) -> void:
	var a_d: Dictionary = t.get("a", {})
	var b_d: Dictionary = t.get("b", {})
	var a := Vector3(a_d.get("x", 0.0), a_d.get("y", 0.0), a_d.get("z", 0.0))
	var b := Vector3(b_d.get("x", 0.0), b_d.get("y", 0.0), b_d.get("z", 0.0))
	_teleporters.append({"a": a, "b": b, "nodes": [_teleporter_disc(a), _teleporter_disc(b)]})


# --- Per-frame animation + triggers --------------------------------------

func _physics_process(delta: float) -> void:
	_time += delta

	# Spawn beacons are editor furniture: only shown while in god mode
	var editing: bool = player != null and player.godmode
	for id in _spawn_markers:
		_spawn_markers[id].visible = editing

	# Pending-teleporter ghost (web: half-transparent green disc on first click)
	var pending: Variant = _item_controller.pending_teleporter if _item_controller else null
	if pending != null and _pending_ghost == null:
		_pending_ghost = _teleporter_disc(pending)
		_pending_ghost.mesh = _pending_ghost.mesh.duplicate()
		var gmat := StandardMaterial3D.new()
		gmat.albedo_color = Color(0.27, 1.0, 0.27, 0.5)
		gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_pending_ghost.mesh.material = gmat
	elif pending == null and _pending_ghost != null:
		_pending_ghost.queue_free()
		_pending_ghost = null

	# Pills spin 2 rad/s and bob (web: sin(ms*0.003 + x) * 0.1)
	for id in _pedestals:
		var ped: Dictionary = _pedestals[id]
		if ped["has_item"]:
			var crystal: MeshInstance3D = ped["crystal"]
			crystal.rotation.y += delta * 2.0
			crystal.position.y = 0.95 + sin(_time * 3.0 + ped["node"].position.x) * 0.1

	if not player:
		return

	# Pedestal pickup (< 1.8, never in godmode; web hides the crystal
	# optimistically). A full inventory still picks up: the new item takes
	# slot 0 and the last one falls off — same as a god-given item.
	if _item_controller and not player.godmode:
		for id in _pedestals:
			var ped: Dictionary = _pedestals[id]
			if ped["has_item"] and player.global_position.distance_to(ped["node"].position) < PICKUP_DIST:
				ped["has_item"] = false
				ped["crystal"].visible = false
				Net.emit_event("pickupItem", id)

	# Pads (web §4.6)
	for pad in _pads:
		if player.global_position.distance_to(pad["pos"]) < TRIGGER_DIST:
			if pad["type"] == "launch_pad" and player.velocity.y < 16.0:
				player.velocity.y = 32.0
				Sfx.jump(player.global_position)
			elif pad["type"] == "boost_pad":
				var h_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
				if h_speed < 27.0:
					player.velocity = Vector3(pad["dx"] * 45.0, 5.0, pad["dz"] * 45.0)
					player.speed_cap = maxf(player.speed_cap, 45.0)
					Sfx.boost(player.global_position, 1.0)

	# Teleporters (web §4.7: trigger 1.5, arrive +1.5 Y, 1.5 s cooldown)
	_teleport_cd = maxf(0.0, _teleport_cd - delta)
	if _teleport_cd <= 0.0:
		for t in _teleporters:
			var dist_a: float = player.global_position.distance_to(t["a"])
			var dist_b: float = player.global_position.distance_to(t["b"])
			if dist_a < TRIGGER_DIST or dist_b < TRIGGER_DIST:
				var dest: Vector3 = t["b"] if dist_a < TRIGGER_DIST else t["a"]
				player.global_position = dest + Vector3(0, 1.5, 0)  # web keeps velocity
				Sfx.boost(dest, 1.0)
				_teleport_cd = TELEPORT_COOLDOWN
				break
