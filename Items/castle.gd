extends Node3D

## Parametric castle structures (Tiny Glade energy, jam budget):
##  - WALLS: click a chain of points and a solid stone wall runs through
##    them — crenellation teeth, posts at bends, gate variant with an arch.
##    Height is LIVE (select in god mode, scroll), and penetrations can be
##    punched through any segment after the fact.
##  - TOWERS: one click, a cylindrical tower with a crenellated rim; height
##    set by scroll while placing (and live after, like walls).
## Everything rebuilds from its record on 'castleUpdated'.

const WALL_H := 6.0     # default body height above the base
const SKIRT := 8.0      # buried below it, so sloping ground never shows a gap
const THICK := 2.0      # full wall thickness
const TOOTH_H := 1.1
const TOOTH_W := 0.5    # merlon depth along each top edge
const TOOTH_L := 1.6    # merlon length + same-size gap, alternating
const POST := 3.0       # square post at each path node
const GATE_W := 4.0
const GATE_H := 4.5
const TOWER_R := 3.2
const MAX_LEN := 64.0   # per-segment clamp
const MAX_NODES := 16

var _castles: Dictionary = {}   # id -> {root, points: Array[Vector3], data}


func _ready() -> void:
	add_to_group("world_castles")
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentCastles":
			for id in _castles:
				_castles[id]["root"].queue_free()
			_castles.clear()
			for c in data:
				_add_castle(c)
		"castlePlaced":
			_add_castle(data)
		"castleUpdated":
			# Height changed or a hole punched: rebuild that structure
			var uid := str(data.get("id", "")) if data is Dictionary else ""
			if _castles.has(uid):
				_castles[uid]["root"].queue_free()
				_castles.erase(uid)
			_add_castle(data)
		"castleRemoved":
			var id := str(data)
			if _castles.has(id):
				_castles[id]["root"].queue_free()
				_castles.erase(id)


## Nearest castle within `radius` of a point — god menu delete/select. {} if none.
func nearest_deletable(pos: Vector3, radius := 5.0) -> Dictionary:
	var best := {}
	for id in _castles:
		for p in _castles[id]["points"]:
			var d: float = (p as Vector3).distance_to(pos)
			if d < radius and (best.is_empty() or d < best["dist"]):
				best = {"id": id, "dist": d, "pos": p}
	return best


func _add_castle(c: Dictionary) -> void:
	var id := str(c.get("id", ""))
	if id == "" or _castles.has(id):
		return
	var nodes: Array = c.get("nodes", [])
	# Legacy two-point payloads ({a, b}) still render
	if nodes.is_empty() and c.get("a") is Dictionary and c.get("b") is Dictionary:
		nodes = [c.get("a"), c.get("b")]
	var pts: Array = []
	for n in nodes:
		if n is Dictionary:
			pts.append(Vector3(n.get("x", 0.0), n.get("y", 0.0), n.get("z", 0.0)))
		if pts.size() >= MAX_NODES:
			break
	if pts.is_empty():
		return
	var arch: bool = c.get("arch", false)
	var h := clampf(float(c.get("h", WALL_H)), 2.0, 24.0)
	var holes: Array = []
	for hd in c.get("holes", []):
		if hd is Dictionary:
			holes.append(Vector3(hd.get("x", 0.0), hd.get("y", 0.0), hd.get("z", 0.0)))

	var root := StaticBody3D.new()
	add_child(root)
	var mat := stone_material()

	if str(c.get("kind", "wall")) == "tower":
		_build_tower(root, pts[0], h, mat)
		_castles[id] = {"root": root, "points": [pts[0], pts[0] + Vector3(0, h, 0)], "data": c}
		return

	if pts.size() < 2:
		root.queue_free()
		return
	var mids: Array = []
	for i in pts.size() - 1:
		_build_segment(root, pts[i], pts[i + 1], arch, mat, h, holes)
		# Sample along the run so select/delete clicks land anywhere on it
		var seg := (pts[i + 1] as Vector3) - (pts[i] as Vector3)
		var steps := maxi(1, int(seg.length() / 4.0))
		for s in steps:
			mids.append((pts[i] as Vector3) + seg * ((s + 0.5) / steps))
	for p in pts:
		_post(root, p, mat, h)
	_castles[id] = {"root": root, "points": pts + mids, "data": c}


## Tiled stone, triplanar so every box is textured without UV work.
static func stone_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://Terrain/textures/rock.jpg")
	mat.albedo_color = Color(0.78, 0.76, 0.72)
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(0.22, 0.22, 0.22)
	mat.roughness = 1.0
	return mat


## Square post at every node: seals corners so bends have no gaps.
func _post(root: Node3D, p: Vector3, mat: StandardMaterial3D, h := WALL_H, collide := true) -> void:
	_solid_box(root,
		Vector3(p.x, p.y + (h + 1.2 - SKIRT) / 2.0, p.z),
		Vector3(POST, h + 1.2 + SKIRT, POST), Basis(), mat, collide)


## The wall a click-chain would build, as an unlit blue ghost. Caller owns
## the node and frees it when the cursor moves.
func make_preview(pts: Array, arch: bool, h := WALL_H) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in maxi(0, pts.size() - 1):
		_build_segment(root, pts[i], pts[i + 1], arch, mat, h, [], false)
	for p in pts:
		_post(root, p, mat, h, false)
	return root


## Cylindrical tower: body, crenellated rim, done. Height is parametric.
func _build_tower(root: Node3D, p: Vector3, h: float, mat: StandardMaterial3D, collide := true) -> void:
	if collide:
		var col := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = TOWER_R
		shape.height = h + SKIRT
		col.shape = shape
		root.add_child(col)
		col.global_position = Vector3(p.x, p.y + (h - SKIRT) / 2.0, p.z)
	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = TOWER_R
	cyl.bottom_radius = TOWER_R + 0.4
	cyl.height = h + SKIRT
	cyl.radial_segments = 14
	cyl.material = mat
	body.mesh = cyl
	root.add_child(body)
	body.global_position = Vector3(p.x, p.y + (h - SKIRT) / 2.0, p.z)
	# Merlons around the rim
	var n := 9
	for i in n:
		var ang := TAU * i / n
		var tp := Vector3(p.x + cos(ang) * (TOWER_R - TOOTH_W / 2.0), p.y + h + TOOTH_H / 2.0, p.z + sin(ang) * (TOWER_R - TOOTH_W / 2.0))
		_solid_box(root, tp, Vector3(TOOTH_W, TOOTH_H, TOOTH_L * 0.8),
			Basis(Vector3.UP, -ang), mat, collide)


## A tower the size the scroll picked, as a ghost (god menu preview).
func make_tower_preview(h: float) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_build_tower(root, Vector3.ZERO, h, mat, false)
	return root


func _build_segment(root: Node3D, a: Vector3, b: Vector3, arch: bool, mat: StandardMaterial3D, h: float, holes: Array, collide := true) -> void:
	var flat := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var length := minf(flat.length(), MAX_LEN)
	if length < 1.0:
		return
	var dir := flat.normalized()
	var right := Vector3(-dir.z, 0.0, dir.x)
	var base_y := minf(a.y, b.y)
	var basis := Basis.looking_at(dir, Vector3.UP)
	var a_flat := Vector3(a.x, 0, a.z)

	# Openings along this segment: the gate arch (middle) plus every punched
	# hole whose point projects onto it. Sorted, non-overlapping-ish.
	var opens: Array = []
	if arch and length > GATE_W + 2.0:
		opens.append(length / 2.0)
	for hp in holes:
		var t: float = (Vector3(hp.x, 0, hp.z) - a_flat).dot(dir)
		if t < GATE_W / 2.0 + 0.5 or t > length - GATE_W / 2.0 - 0.5:
			continue
		var perp: float = (Vector3(hp.x, 0, hp.z) - a_flat - dir * t).length()
		if perp > THICK * 1.6:
			continue
		opens.append(t)
	opens.sort()

	var gate_h := minf(GATE_H, h - 0.8)
	# Solid stretches between openings, each reaching SKIRT below the base
	var cursor := 0.0
	for t_v in opens + [length + GATE_W / 2.0]:
		var t := float(t_v)
		var start: float = cursor
		var stop: float = minf(t - GATE_W / 2.0, length)
		if stop - start > 0.05:
			var mid := a_flat + dir * ((start + stop) / 2.0)
			_solid_box(root, Vector3(mid.x, base_y + (h - SKIRT) / 2.0, mid.z),
				Vector3(THICK, h + SKIRT, stop - start), basis, mat, collide)
		cursor = maxf(cursor, t + GATE_W / 2.0)
	# Lintels over every opening
	for t_v in opens:
		var t := float(t_v)
		var omid := a_flat + dir * t
		_solid_box(root, Vector3(omid.x, base_y + gate_h + (h - gate_h) / 2.0, omid.z),
			Vector3(THICK, h - gate_h, GATE_W), basis, mat, collide)

	# Teeth: alternating merlons along both top edges (visual + collision)
	var n := int(length / TOOTH_L)
	for i in n:
		if i % 2 == 1:
			continue
		var along := (i + 0.5) * TOOTH_L
		for side: float in [-1.0, 1.0]:
			var tp: Vector3 = a_flat + dir * along + right * side * ((THICK - TOOTH_W) / 2.0)
			_solid_box(root, Vector3(tp.x, base_y + h + TOOTH_H / 2.0, tp.z),
				Vector3(TOOTH_W, TOOTH_H, TOOTH_L * 0.9), basis, mat, collide)


func _solid_box(root: Node3D, center: Vector3, size: Vector3, basis: Basis, mat: StandardMaterial3D, collide := true) -> void:
	if collide:
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		root.add_child(col)
		col.global_position = center
		col.global_basis = basis
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	root.add_child(mi)
	mi.global_position = center
	mi.global_basis = basis
