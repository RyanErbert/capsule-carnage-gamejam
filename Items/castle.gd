extends Node3D

## Parametric castle walls (Ryan's spec): two clicks A->B make a stone wall
## with crenellation teeth, a walkable parapet top, and (gate variant) an
## archway through the middle. Built from BRICK CELLS — 2x1x1 masonry blocks,
## each with its own collider — so destruction is per-brick: explosions knock
## bricks out (deterministically, from the shared explosion event) and the
## lost bricks fall away as rigid-body gibs.

const BRICK_L := 2.0    # along the wall
const BRICK_H := 1.0
const BRICK_T := 1.0
const WALL_ROWS := 6    # 5 solid + teeth row
const WALL_COLS := 3    # outer / walkway / outer
const MAX_LEN := 48.0
const GIB_LIFE := 6.0

var _castles: Dictionary = {}   # id -> {root, bricks: {key -> CollisionShape3D}, mm, list, arch, frame}


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
		"explosion":
			var pos := Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0))
			var radius := 6.0 if str(data.get("type", "")) == "mine" else 8.0
			_blast(pos, radius * 0.75)  # bricks are tougher than score radius


## Nearest castle within `radius` of a point — god menu delete. {} if none.
func nearest_deletable(pos: Vector3, radius := 5.0) -> Dictionary:
	var best := {}
	for id in _castles:
		for b in _castles[id]["list"]:
			var d: float = (b["pos"] as Vector3).distance_to(pos)
			if d < radius and (best.is_empty() or d < best["dist"]):
				best = {"id": id, "dist": d, "pos": b["pos"]}
	return best


## Which brick cells exist for a wall of `n_along` bricks (arch = gate hole).
static func _cell_exists(i: int, row: int, col: int, n_along: int, arch: bool) -> bool:
	var outer := col == 0 or col == WALL_COLS - 1
	if row == WALL_ROWS - 1:
		return outer and i % 2 == 0        # teeth: alternating merlons, outer edges
	if row == WALL_ROWS - 2 and not outer:
		return true                        # walkway floor is the row below
	if not outer and row < WALL_ROWS - 2:
		return true                        # interior fill
	if arch and row <= 3:
		# gate: a 2-brick-wide opening through the middle, all columns
		var mid := n_along / 2
		if i == mid or i == mid - 1:
			return false
	return row < WALL_ROWS - 1             # solid outer body below the teeth


func _add_castle(c: Dictionary) -> void:
	var id := str(c.get("id", ""))
	if id == "" or _castles.has(id):
		return
	var a_d: Dictionary = c.get("a", {})
	var b_d: Dictionary = c.get("b", {})
	var a := Vector3(a_d.get("x", 0.0), a_d.get("y", 0.0), a_d.get("z", 0.0))
	var b := Vector3(b_d.get("x", 0.0), b_d.get("y", 0.0), b_d.get("z", 0.0))
	var arch: bool = c.get("arch", false)
	var flat := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var length := minf(flat.length(), MAX_LEN)
	if length < BRICK_L:
		return
	var dir := flat.normalized()
	var right := Vector3(-dir.z, 0.0, dir.x)
	var base := Vector3(a.x, minf(a.y, b.y), a.z)
	var n_along := int(length / BRICK_L)

	var root := StaticBody3D.new()
	add_child(root)
	var bricks: Dictionary = {}
	var list: Array = []
	for i in n_along:
		for row in WALL_ROWS:
			for col in WALL_COLS:
				if not _cell_exists(i, row, col, n_along, arch):
					continue
				var pos: Vector3 = base \
					+ dir * (i * BRICK_L + BRICK_L / 2.0) \
					+ right * ((col - 1) * BRICK_T) \
					+ Vector3(0, row * BRICK_H + BRICK_H / 2.0, 0)
				var shape := CollisionShape3D.new()
				var box := BoxShape3D.new()
				box.size = Vector3(BRICK_L, BRICK_H, BRICK_T)
				shape.shape = box
				root.add_child(shape)
				shape.global_position = pos
				shape.global_basis = Basis.looking_at(dir, Vector3.UP)
				var key := "%d,%d,%d" % [i, row, col]
				bricks[key] = shape
				list.append({"key": key, "pos": pos})

	var mm := _make_multimesh(list, dir)
	root.add_child(mm)
	_castles[id] = {"root": root, "bricks": bricks, "mm": mm, "list": list, "dir": dir}


func _make_multimesh(list: Array, dir: Vector3) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3(BRICK_L - 0.06, BRICK_H - 0.06, BRICK_T - 0.06)  # mortar gaps
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.roughness = 1.0
	mat.vertex_color_use_as_albedo = true
	box.material = mat
	mm.mesh = box
	mm.instance_count = list.size()
	var basis := Basis.looking_at(dir, Vector3.UP)
	for i in list.size():
		mm.set_instance_transform(i, Transform3D(basis, list[i]["pos"]))
		# stone variation: hash the position for a stable per-brick shade
		var shade := 0.5 + 0.18 * fposmod(sin(list[i]["pos"].dot(Vector3(12.9, 78.2, 37.7))) * 43758.5, 1.0)
		mm.set_instance_color(i, Color(shade, shade * 0.97, shade * 0.9))
	mmi.multimesh = mm
	return mmi


## Knock out every brick within the blast and send it flying as a gib.
func _blast(pos: Vector3, radius: float) -> void:
	for id in _castles:
		var castle: Dictionary = _castles[id]
		var removed := false
		var kept: Array = []
		for b in castle["list"]:
			var bpos: Vector3 = b["pos"]
			if bpos.distance_to(pos) < radius:
				removed = true
				var shape: CollisionShape3D = castle["bricks"].get(b["key"])
				if shape:
					shape.queue_free()
				castle["bricks"].erase(b["key"])
				_spawn_gib(bpos, (bpos - pos).normalized(), castle["dir"])
			else:
				kept.append(b)
		if removed:
			castle["list"] = kept
			castle["mm"].queue_free()
			castle["mm"] = _make_multimesh(kept, castle["dir"])
			castle["root"].add_child(castle["mm"])


func _spawn_gib(pos: Vector3, out_dir: Vector3, wall_dir: Vector3) -> void:
	var gib := RigidBody3D.new()
	gib.mass = 2.0
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(BRICK_L, BRICK_H, BRICK_T) * 0.8
	col.shape = box
	gib.add_child(col)
	var mesh_inst := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.53, 0.48)
	mat.roughness = 1.0
	bm.material = mat
	mesh_inst.mesh = bm
	gib.add_child(mesh_inst)
	add_child(gib)
	gib.global_position = pos
	gib.global_basis = Basis.looking_at(wall_dir, Vector3.UP)
	gib.linear_velocity = out_dir * (6.0 + randf() * 6.0) + Vector3(0, 4.0 + randf() * 4.0, 0)
	gib.angular_velocity = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 8.0
	get_tree().create_timer(GIB_LIFE).timeout.connect(gib.queue_free)
