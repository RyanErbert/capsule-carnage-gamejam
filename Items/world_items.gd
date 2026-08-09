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


func _ready() -> void:
	Net.event_received.connect(_on_net_event)
	if player:
		_item_controller = player.get_node_or_null("ItemController")


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


## Nearest pedestal id within `radius` of a point ("" if none) — god menu delete.
func pedestal_near(pos: Vector3, radius := 2.0) -> String:
	var best_id := ""
	var best := radius
	for id in _pedestals:
		var d: float = _pedestals[id]["node"].position.distance_to(pos)
		if d < best:
			best = d
			best_id = id
	return best_id


# --- Builders -----------------------------------------------------------

func _add_pedestal(ped: Dictionary) -> void:
	var id := str(ped.get("id", ""))
	if id == "" or _pedestals.has(id):
		return
	var root := Node3D.new()
	root.position = Vector3(ped.get("x", 0.0), ped.get("y", 0.0), ped.get("z", 0.0))
	root.rotation.y = float(ped.get("ry", 0.0))
	add_child(root)

	# Column stand-in for /prefabs/item_ped.glb
	var column := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.45
	cyl.height = 1.0
	var col_mat := StandardMaterial3D.new()
	col_mat.albedo_color = Color(0.55, 0.55, 0.6)
	cyl.material = col_mat
	column.mesh = cyl
	column.position.y = 0.5
	root.add_child(column)

	# Octahedron crystal at y 1.2, colored by category (web §4.1)
	var crystal := MeshInstance3D.new()
	crystal.mesh = _octahedron_mesh(0.3)
	var color: Color = CRYSTAL_COLORS.get(str(ped.get("type", "green")), Color.WHITE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.6
	crystal.material_override = mat
	crystal.position.y = 1.2
	crystal.visible = ped.get("currentItem") != null
	root.add_child(crystal)

	_pedestals[id] = {
		"node": root, "crystal": crystal,
		"has_item": ped.get("currentItem") != null,
		"type": str(ped.get("type", "green")),
	}


func _octahedron_mesh(r: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := Vector3(0, r, 0)
	var bottom := Vector3(0, -r, 0)
	var ring := [Vector3(r, 0, 0), Vector3(0, 0, r), Vector3(-r, 0, 0), Vector3(0, 0, -r)]
	for i in 4:
		var a: Vector3 = ring[i]
		var b: Vector3 = ring[(i + 1) % 4]
		st.add_vertex(top); st.add_vertex(b); st.add_vertex(a)
		st.add_vertex(bottom); st.add_vertex(a); st.add_vertex(b)
	st.generate_normals()
	return st.commit()


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

	# Crystals spin 2 rad/s and bob (web: sin(ms*0.003 + x) * 0.1 around y 1.2)
	for id in _pedestals:
		var ped: Dictionary = _pedestals[id]
		if ped["has_item"]:
			var crystal: MeshInstance3D = ped["crystal"]
			crystal.rotation.y += delta * 2.0
			crystal.position.y = 1.2 + sin(_time * 3.0 + ped["node"].position.x) * 0.1

	if not player:
		return

	# Pedestal pickup (< 1.8, needs a free slot, never in godmode; web hides
	# the crystal optimistically)
	if _item_controller and not player.godmode \
			and _item_controller.inventory.size() < _item_controller.MAX_INVENTORY:
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
			elif pad["type"] == "boost_pad":
				var h_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
				if h_speed < 27.0:
					player.velocity = Vector3(pad["dx"] * 45.0, 5.0, pad["dz"] * 45.0)
					player.speed_cap = maxf(player.speed_cap, 45.0)

	# Teleporters (web §4.7: trigger 1.5, arrive +1.5 Y, 1.5 s cooldown)
	_teleport_cd = maxf(0.0, _teleport_cd - delta)
	if _teleport_cd <= 0.0:
		for t in _teleporters:
			var dist_a: float = player.global_position.distance_to(t["a"])
			var dist_b: float = player.global_position.distance_to(t["b"])
			if dist_a < TRIGGER_DIST or dist_b < TRIGGER_DIST:
				var dest: Vector3 = t["b"] if dist_a < TRIGGER_DIST else t["a"]
				player.global_position = dest + Vector3(0, 1.5, 0)  # web keeps velocity
				_teleport_cd = TELEPORT_COOLDOWN
				break
