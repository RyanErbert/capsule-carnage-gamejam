extends Node3D

## Server-placed world objects: pedestals, launch/boost pads, teleporters
## (PORT_BLUEPRINT.md §4.1, §4.6, §4.7). Visuals are built in code (the web
## used prefab glb + procedural geometry). Triggers are client-side like the
## web: pedestal pickup < 1.8, pad/teleporter trigger < 1.5.

const PICKUP_DIST := 1.8
const TRIGGER_DIST := 1.5
const TELEPORT_COOLDOWN := 1.5
## A pedestal says what it hands out, not what colour it is. The server still
## calls the three pools green/red/yellow; nothing in the world does.
const CATEGORIES := {
	"green": {"label": "MOVEMENT", "color": Color("#40ff9a")},
	"red": {"label": "WEAPONS", "color": Color("#ff5340")},
	"yellow": {"label": "BUILD", "color": Color("#ffc23c")},
}

@export var player: CharacterBody3D

var _item_controller: Node
var _pedestals: Dictionary = {}   # id -> {node, crystal, has_item, type}
var _pads: Array = []             # {type, pos: Vector3, dx, dz, node}
var _teleporters: Array = []      # {a: Vector3, b: Vector3, nodes: [..]}
var _teleport_cd := 0.0
var _pending_ghost: Node3D = null
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

static func _lit(color: Color, energy := 2.2) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


static func _metal(color: Color, rough := 0.45) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.7
	mat.roughness = rough
	return mat


static func _box(root: Node3D, size: Vector3, pos: Vector3, rot: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	root.add_child(mi)
	return mi


## What the pedestal is offering, said in a shape you can read across a map:
## chevrons for movement, a dart for weapons, a stack for build.
static func _emblem(kind: String, mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	match kind:
		"red":
			var dart := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.24
			cone.height = 0.5
			dart.mesh = cone
			dart.material_override = mat
			dart.position.y = 0.1
			root.add_child(dart)
			for s: float in [-1.0, 1.0]:
				_box(root, Vector3(0.06, 0.26, 0.2), Vector3(s * 0.17, -0.2, 0),
					Vector3(0, 0, s * 0.5), mat)
		"yellow":
			_box(root, Vector3(0.44, 0.16, 0.44), Vector3(0, -0.22, 0), Vector3.ZERO, mat)
			_box(root, Vector3(0.3, 0.16, 0.3), Vector3(0, -0.04, 0), Vector3.ZERO, mat)
			_box(root, Vector3(0.16, 0.16, 0.16), Vector3(0, 0.14, 0), Vector3.ZERO, mat)
		_:
			for i in 2:
				var y := -0.16 + float(i) * 0.28
				for s: float in [-1.0, 1.0]:
					_box(root, Vector3(0.34, 0.09, 0.09), Vector3(s * 0.13, y, 0),
						Vector3(0, 0, s * -0.7), mat)
	return root


func _add_pedestal(ped: Dictionary) -> void:
	var id := str(ped.get("id", ""))
	if id == "" or _pedestals.has(id):
		return
	var kind := str(ped.get("type", "green"))
	var cat: Dictionary = CATEGORIES.get(kind, CATEGORIES["green"])
	var color: Color = cat["color"]
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
	plate.mesh = cyl
	plate.material_override = _metal(Color(0.2, 0.21, 0.24), 0.6)
	plate.position.y = 0.14
	root.add_child(plate)
	# A ring in the pool's own colour, so the category reads from above too
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.72
	torus.outer_radius = 0.84
	ring.mesh = torus
	ring.material_override = _lit(color, 2.0)
	ring.position.y = 0.3
	root.add_child(ring)

	var crystal := _emblem(kind, _lit(color, 1.6))
	crystal.position.y = 0.95
	crystal.visible = ped.get("currentItem") != null
	root.add_child(crystal)

	var tag := Label3D.new()
	tag.text = str(cat["label"])
	tag.font_size = 96
	tag.pixel_size = 0.0032
	tag.outline_size = 24
	tag.modulate = color
	tag.outline_modulate = Color(0, 0, 0, 0.85)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position.y = 1.55
	root.add_child(tag)

	_pedestals[id] = {
		"node": root, "crystal": crystal, "tag": tag,
		"has_item": ped.get("currentItem") != null,
		"type": kind,
	}


## A jet on the floor: octagonal pad, three angled vanes, a lit ring, and a
## column of exhaust standing in it so you can see one from across the arena.
func _add_pad(p: Dictionary) -> void:
	var boost := str(p.get("type", "")) == "boost_pad"
	var color := Color("#ffaa33") if boost else Color("#4cff88")
	var node := Node3D.new()
	node.position = Vector3(p.get("x", 0.0), float(p.get("y", 0.0)) + 0.02, p.get("z", 0.0))
	if boost:
		node.rotation.y = atan2(float(p.get("dx", 0.0)), float(p.get("dz", 1.0)))
	var shell := _metal(Color(0.17, 0.18, 0.21), 0.5)

	var base := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.95
	disc.bottom_radius = 1.15
	disc.height = 0.16
	disc.radial_segments = 8
	base.mesh = disc
	base.material_override = shell
	base.position.y = 0.08
	node.add_child(base)

	var lit := _lit(color, 2.6)
	if boost:
		# Chevrons pointing the way it throws you
		for i in 3:
			var z := -0.45 + float(i) * 0.45
			for s: float in [-1.0, 1.0]:
				_box(node, Vector3(0.5, 0.06, 0.14), Vector3(s * 0.18, 0.18, z),
					Vector3(0, s * 0.7, 0), lit)
		for s: float in [-1.0, 1.0]:
			_box(node, Vector3(0.12, 0.3, 1.9), Vector3(s * 0.95, 0.15, 0), Vector3.ZERO, shell)
	else:
		# Three vanes leaning in over the throat, and a ring around it
		for i in 3:
			var a := float(i) * TAU / 3.0
			_box(node, Vector3(0.18, 0.62, 0.5),
				Vector3(sin(a) * 0.72, 0.32, cos(a) * 0.72),
				Vector3(-0.36, a, 0), shell)
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.5
		torus.outer_radius = 0.62
		ring.mesh = torus
		ring.material_override = lit
		ring.position.y = 0.2
		node.add_child(ring)

	var jet := _plume(color, Vector3(0, 1, 0) if not boost else Vector3(0, 0.25, 1),
		18.0 if not boost else 12.0, Vector3(0.9, 0.05, 0.9) if not boost else Vector3(0.7, 0.2, 0.2))
	jet.position.y = 0.2
	node.add_child(jet)
	add_child(node)

	_pads.append({
		"type": str(p.get("type", "launch_pad")),
		"pos": Vector3(p.get("x", 0.0), p.get("y", 0.0), p.get("z", 0.0)),
		"dx": float(p.get("dx", 0.0)), "dz": float(p.get("dz", 0.0)),
		"node": node, "color": color,
	})


## A continuous stream: pads exhaust upward or along their throw, teleporters
## draw a column. Cheap CPU particles, small counts — there can be a lot of
## these on a busy map.
static func _plume(color: Color, dir: Vector3, speed: float, extents: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 22
	p.lifetime = 0.85
	p.direction = dir.normalized()
	p.spread = 9.0
	p.initial_velocity_min = speed * 0.55
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -6, 0)
	p.scale_amount_min = 0.06
	p.scale_amount_max = 0.16
	p.color = color
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = extents
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var quad := QuadMesh.new()
	quad.size = Vector2(0.3, 0.3)
	quad.material = mat
	p.mesh = quad
	return p


## One end of a teleporter: a plinth, three pylons, and a ring that turns above
## them inside a rising column of light.
func _teleporter_disc(pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = pos
	var shell := _metal(Color(0.18, 0.2, 0.26), 0.45)
	var lit := _lit(Color("#4cd8ff"), 2.4)

	var base := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.78
	cyl.bottom_radius = 0.92
	cyl.height = 0.2
	cyl.radial_segments = 6
	base.mesh = cyl
	base.material_override = shell
	base.position.y = 0.1
	node.add_child(base)
	for i in 3:
		var a := float(i) * TAU / 3.0
		_box(node, Vector3(0.14, 1.1, 0.14), Vector3(sin(a) * 0.62, 0.65, cos(a) * 0.62),
			Vector3.ZERO, shell)
		_box(node, Vector3(0.16, 0.1, 0.16), Vector3(sin(a) * 0.62, 1.22, cos(a) * 0.62),
			Vector3.ZERO, lit)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.56
	torus.rings = 12
	ring.mesh = torus
	ring.material_override = lit
	ring.position.y = 1.05
	ring.name = "Ring"
	node.add_child(ring)

	var column := _plume(Color("#4cd8ff"), Vector3.UP, 5.0, Vector3(0.55, 0.05, 0.55))
	column.lifetime = 1.4
	column.gravity = Vector3.ZERO
	column.position.y = 0.2
	node.add_child(column)
	add_child(node)
	return node


func _add_teleporter(t: Dictionary) -> void:
	var a_d: Dictionary = t.get("a", {})
	var b_d: Dictionary = t.get("b", {})
	var a := Vector3(a_d.get("x", 0.0), a_d.get("y", 0.0), a_d.get("z", 0.0))
	var b := Vector3(b_d.get("x", 0.0), b_d.get("y", 0.0), b_d.get("z", 0.0))
	_teleporters.append({"a": a, "b": b, "nodes": [_teleporter_disc(a), _teleporter_disc(b)]})


## A one-shot flash where something just fired.
func _burst(pos: Vector3, color: Color, dir: Vector3) -> void:
	var p := _plume(color, dir, 22.0, Vector3(0.4, 0.1, 0.4))
	p.amount = 34
	p.one_shot = true
	p.explosiveness = 1.0
	p.lifetime = 0.7
	p.emitting = false
	add_child(p)
	p.global_position = pos
	p.emitting = true
	get_tree().create_timer(1.4).timeout.connect(p.queue_free)


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
		var ghost := MeshInstance3D.new()
		var gcyl := CylinderMesh.new()
		gcyl.top_radius = 0.8
		gcyl.bottom_radius = 0.9
		gcyl.height = 0.2
		gcyl.radial_segments = 6
		ghost.mesh = gcyl
		var gmat := StandardMaterial3D.new()
		gmat.albedo_color = Color(0.27, 1.0, 0.27, 0.5)
		gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ghost.material_override = gmat
		ghost.position = pending
		add_child(ghost)
		_pending_ghost = ghost
	elif pending == null and _pending_ghost != null:
		_pending_ghost.queue_free()
		_pending_ghost = null

	# The emblem spins and bobs over its plate (web: sin(ms*0.003 + x) * 0.1)
	for id in _pedestals:
		var ped: Dictionary = _pedestals[id]
		if ped["has_item"]:
			var crystal: Node3D = ped["crystal"]
			crystal.rotation.y += delta * 2.0
			crystal.position.y = 0.95 + sin(_time * 3.0 + ped["node"].position.x) * 0.1
		var tag: Label3D = ped["tag"]
		tag.modulate.a = 1.0 if ped["has_item"] else 0.35

	# Teleporter rings turn slowly, in opposite directions at the two ends
	for i in _teleporters.size():
		var pair: Array = _teleporters[i]["nodes"]
		for k in pair.size():
			var ring: Node3D = (pair[k] as Node3D).get_node_or_null("Ring")
			if ring:
				ring.rotation.y += delta * (0.9 if k == 0 else -0.9)

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
				player.launched(0.4)
				Sfx.jump(player.global_position)
				_burst(pad["pos"] + Vector3(0, 0.3, 0), pad["color"], Vector3.UP)
			elif pad["type"] == "boost_pad":
				var h_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
				if h_speed < 27.0:
					player.velocity = Vector3(pad["dx"] * 45.0, 5.0, pad["dz"] * 45.0)
					player.speed_cap = maxf(player.speed_cap, 45.0)
					player.launched(0.25)
					Sfx.boost(player.global_position, 1.0)
					_burst(pad["pos"] + Vector3(0, 0.4, 0), pad["color"],
						Vector3(pad["dx"], 0.35, pad["dz"]))

	# Teleporters (web §4.7: trigger 1.5, arrive +1.5 Y, 1.5 s cooldown)
	_teleport_cd = maxf(0.0, _teleport_cd - delta)
	if _teleport_cd <= 0.0:
		for t in _teleporters:
			var dist_a: float = player.global_position.distance_to(t["a"])
			var dist_b: float = player.global_position.distance_to(t["b"])
			if dist_a < TRIGGER_DIST or dist_b < TRIGGER_DIST:
				var from: Vector3 = t["a"] if dist_a < TRIGGER_DIST else t["b"]
				var dest: Vector3 = t["b"] if dist_a < TRIGGER_DIST else t["a"]
				player.global_position = dest + Vector3(0, 1.5, 0)  # web keeps velocity
				Sfx.boost(dest, 1.0)
				_burst(from + Vector3(0, 1.0, 0), Color("#4cd8ff"), Vector3.UP)
				_burst(dest + Vector3(0, 1.0, 0), Color("#4cd8ff"), Vector3.UP)
				_teleport_cd = TELEPORT_COOLDOWN
				break
