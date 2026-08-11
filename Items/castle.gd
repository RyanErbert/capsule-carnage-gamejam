extends Node3D

## Parametric castle walls: click a chain of points (like channels) and a
## SOLID stone wall runs through them — full-thickness body (no squeezing
## between bricks), crenellation teeth along the top edges, a walkable
## parapet between them, square posts at every bend, and (gate variant) an
## archway through each segment's middle. Plain solid geometry — castles no
## longer crumble into physics bricks.

const WALL_H := 6.0     # solid body height above the base
const SKIRT := 8.0      # buried below it, so sloping ground never shows a gap
const THICK := 2.0      # full wall thickness
const TOOTH_H := 1.1
const TOOTH_W := 0.5    # merlon depth along each top edge
const TOOTH_L := 1.6    # merlon length + same-size gap, alternating
const POST := 3.0       # square post at each path node
const GATE_W := 4.0
const GATE_H := 4.5
const MAX_LEN := 64.0   # per-segment clamp
const MAX_NODES := 16

var _castles: Dictionary = {}   # id -> {root, points: Array[Vector3]}


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
		"castleRemoved":
			var id := str(data)
			if _castles.has(id):
				_castles[id]["root"].queue_free()
				_castles.erase(id)


## Nearest castle within `radius` of a point — god menu delete. {} if none.
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
	if pts.size() < 2:
		return
	var arch: bool = c.get("arch", false)

	var root := StaticBody3D.new()
	add_child(root)
	var mat := stone_material()

	var mids: Array = []
	for i in pts.size() - 1:
		_build_segment(root, pts[i], pts[i + 1], arch, mat)
		mids.append((pts[i] + pts[i + 1]) / 2.0)
	for p in pts:
		_post(root, p, mat)
	_castles[id] = {"root": root, "points": pts + mids}


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
func _post(root: Node3D, p: Vector3, mat: StandardMaterial3D, collide := true) -> void:
	_solid_box(root,
		Vector3(p.x, p.y + (WALL_H + 1.2 - SKIRT) / 2.0, p.z),
		Vector3(POST, WALL_H + 1.2 + SKIRT, POST), Basis(), mat, collide)


## The wall a click-chain would build, as an unlit blue ghost. Caller owns
## the node and frees it when the cursor moves.
func make_preview(pts: Array, arch: bool) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in maxi(0, pts.size() - 1):
		_build_segment(root, pts[i], pts[i + 1], arch, mat, false)
	for p in pts:
		_post(root, p, mat, false)
	return root


func _build_segment(root: Node3D, a: Vector3, b: Vector3, arch: bool, mat: StandardMaterial3D, collide := true) -> void:
	var flat := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var length := minf(flat.length(), MAX_LEN)
	if length < 1.0:
		return
	var dir := flat.normalized()
	var right := Vector3(-dir.z, 0.0, dir.x)
	var base_y := minf(a.y, b.y)
	var basis := Basis.looking_at(dir, Vector3.UP)
	var mid := Vector3(a.x, 0, a.z) + dir * (length / 2.0)

	# Every body reaches SKIRT metres below its base, so a wall crossing
	# sloping or dug-out ground still meets it with no gap underneath.
	if arch and length > GATE_W + 2.0:
		# Gate: two flanks + a lintel over the opening
		var flank := (length - GATE_W) / 2.0
		for side: float in [-1.0, 1.0]:
			var center: Vector3 = Vector3(mid.x, 0, mid.z) + dir * side * ((GATE_W + flank) / 2.0)
			_solid_box(root, Vector3(center.x, base_y + (WALL_H - SKIRT) / 2.0, center.z),
				Vector3(THICK, WALL_H + SKIRT, flank), basis, mat, collide)
		_solid_box(root, Vector3(mid.x, base_y + GATE_H + (WALL_H - GATE_H) / 2.0, mid.z),
			Vector3(THICK, WALL_H - GATE_H, GATE_W), basis, mat, collide)
	else:
		_solid_box(root, Vector3(mid.x, base_y + (WALL_H - SKIRT) / 2.0, mid.z),
			Vector3(THICK, WALL_H + SKIRT, length), basis, mat, collide)

	# Teeth: alternating merlons along both top edges (visual + collision)
	var n := int(length / TOOTH_L)
	for i in n:
		if i % 2 == 1:
			continue
		var along := (i + 0.5) * TOOTH_L
		for side: float in [-1.0, 1.0]:
			var tp: Vector3 = Vector3(a.x, 0, a.z) + dir * along + right * side * ((THICK - TOOTH_W) / 2.0)
			_solid_box(root, Vector3(tp.x, base_y + WALL_H + TOOTH_H / 2.0, tp.z),
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
