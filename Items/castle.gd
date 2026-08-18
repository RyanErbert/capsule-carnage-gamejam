extends Node3D

## Parametric castle structures (Tiny Glade energy, jam budget):
##  - WALLS: click a chain of points and a solid stone wall runs through
##    them — crenellation teeth, posts at bends, gate variant with an arch.
##    Height is LIVE (select in god mode, scroll), and penetrations can be
##    punched through any segment after the fact.
##  - TOWERS: one click, a cylindrical tower with a crenellated rim; height
##    set by scroll while placing (and live after, like walls).
## Everything rebuilds from its record on 'castleUpdated'.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")

const WALL_H := 6.0     # default body height above the base
const SKIRT := 8.0      # buried below it, so sloping ground never shows a gap
const THICK := 2.0      # full wall thickness
const TOOTH_H := 1.1
const TOOTH_W := 0.5    # merlon depth along each top edge
const TOOTH_L := 1.6    # merlon length + same-size gap, alternating
const GATE_W := 4.0
const GATE_H := 4.5
const TOWER_R := 3.2
const MAX_LEN := 64.0   # per-segment clamp
const MAX_NODES := 16
const BATTER := 0.22    # how much wider the foot is than the head
const COPING := 0.9     # depth of the band that oversails the head

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
	# Per-segment reach cap, pulled in along the run rather than truncating the
	# drawn wall and leaving the node behind it stranded.
	for i in range(1, pts.size()):
		var prev: Vector3 = pts[i - 1]
		var step: Vector3 = (pts[i] as Vector3) - prev
		if step.length() > MAX_LEN:
			pts[i] = prev + step.normalized() * MAX_LEN
	_build_run(root, pts, arch, mat, h, holes)
	# Sample along the run so select/delete clicks land anywhere on it
	var mids: Array = []
	for i in pts.size() - 1:
		var seg := (pts[i + 1] as Vector3) - (pts[i] as Vector3)
		var steps := maxi(1, int(seg.length() / 4.0))
		for s in steps:
			mids.append((pts[i] as Vector3) + seg * ((s + 0.5) / steps))
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


## The wall a click-chain would build, as an unlit blue ghost. Caller owns
## the node and frees it when the cursor moves.
func make_preview(pts: Array, arch: bool, h := WALL_H) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	if pts.size() >= 2:
		_build_run(root, pts, arch, _ghost_material(), h, [], false)
	return root


static func _ghost_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## A tower is the same wall bent onto a circle: one ring rail, the tower
## profile swept around it, merlons repeated on the head. Height is parametric.
func _build_tower(root: Node3D, p: Vector3, h: float, mat: Material, collide := true) -> void:
	var frames := Ops.ring_frames(p, TOWER_R, 14)
	var st := Ops.surface()
	var hulls: Array = []
	Ops.sweep(st, frames, Profiles.tower(TOWER_R, h, SKIRT, 0.35, COPING),
		hulls, {"closed": true})
	# Reopen the ring into a rail that covers the full circle, so a merlon can
	# be sliced off the seam like any other stretch of head.
	var head := Ops.lift(frames, h)
	head.append(head[0])
	_crenellate(st, hulls, head, Profiles.rect(-TOOTH_W, 0.1, 0.0, TOOTH_H))
	Ops.attach(root, st, hulls, mat, collide)


## A tower the size the scroll picked, as a ghost (god menu preview).
func make_tower_preview(h: float) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	_build_tower(root, Vector3.ZERO, h, _ghost_material(), false)
	return root


## The whole run in one sweep: the wall profile carried along a mitred rail, so
## a corner closes itself without a post and a slope is a ramp instead of a
## stack of steps. Openings break the rail into stretches, each opening takes a
## lintel over it, and the merlons ride the head.
func _build_run(root: Node3D, pts: Array, arch: bool, mat: Material,
		h: float, holes: Array, collide := true) -> void:
	var frames := Ops.mitre_frames(pts)
	if frames.size() < 2:
		return
	var total := Ops.rail_length(frames)
	if total < 1.0:
		return
	var st := Ops.surface()
	var hulls: Array = []
	var body := Profiles.wall(THICK * 0.5, h, SKIRT, BATTER, COPING)

	# Openings as distances along the whole run: the gate arch at the middle,
	# plus every punched hole that lands near enough to the line to count.
	var opens: Array = []
	if arch and total > GATE_W + 2.0:
		opens.append(total * 0.5)
	for hp in holes:
		var pr := Ops.project(frames, hp)
		var d := float(pr["d"])
		if d < GATE_W * 0.5 + 0.5 or d > total - GATE_W * 0.5 - 0.5:
			continue
		if float(pr["off"]) > THICK * 1.6:
			continue
		opens.append(d)
	opens.sort()

	var gate_h := minf(GATE_H, h - 0.8)
	var lintel := Profiles.rect(-THICK * 0.5, THICK * 0.5, gate_h, h)
	var cursor := 0.0
	for t_v in opens + [total + GATE_W * 0.5]:
		var stop: float = minf(float(t_v) - GATE_W * 0.5, total)
		if stop - cursor > 0.05:
			Ops.sweep(st, Ops.slice(frames, cursor, stop), body, hulls, {"caps": true})
		cursor = maxf(cursor, float(t_v) + GATE_W * 0.5)
	for t_v in opens:
		Ops.sweep(st, Ops.slice(frames, float(t_v) - GATE_W * 0.5,
			float(t_v) + GATE_W * 0.5), lintel, hulls, {"caps": true})

	var head := Ops.lift(frames, h)
	for side: float in [-1.0, 1.0]:
		_crenellate(st, hulls, head, Profiles.merlon(THICK * 0.5, side, TOOTH_W, TOOTH_H))
	Ops.attach(root, st, hulls, mat, collide)


## Alternating teeth along a head rail. Each one is sliced off the real rail
## rather than dropped on as a box, so a merlon that straddles a corner mitres
## with it instead of shearing through.
func _crenellate(st: SurfaceTool, hulls: Array, head: Array, tooth: PackedVector2Array) -> void:
	if tooth.is_empty():
		return
	var i := 0
	for d in Ops.repeat_distances(head, TOOTH_L):
		i += 1
		if i % 2 == 0:
			continue
		Ops.sweep(st, Ops.slice(head, float(d) - TOOTH_L * 0.45,
			float(d) + TOOTH_L * 0.45), tooth, hulls, {"caps": true})
