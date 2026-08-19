extends Node3D

## LEGACY. Walls and towers placed before the parametric records existed, kept
## alive so a round already in progress does not lose what is standing in it.
## The build drone places Items/parametrics.gd structures now, which persist to
## disk, take handles and carry their own parameters; this node only renders
## what the server still holds in activeCastles and is read-only from here.
##
## The geometry is the same code either way -- everything below goes through
## Items/parametric/registry -- so an old wall and a new one are the same object
## with a thinner protocol in front of it.

const Registry := preload("res://Items/parametric/registry.gd")

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

	var kind := str(c.get("kind", "wall"))
	if kind == "tower":
		var tower := _make(pts, "tower", false, h, [], stone_material(), true)
		if tower == null:
			return
		add_child(tower)
		_castles[id] = {"root": tower, "points": [pts[0], pts[0] + Vector3(0, h, 0)], "data": c}
		return

	if pts.size() < 2:
		return
	# Per-segment reach cap, pulled in along the run rather than truncating the
	# drawn wall and leaving the node behind it stranded.
	for i in range(1, pts.size()):
		var prev: Vector3 = pts[i - 1]
		var step: Vector3 = (pts[i] as Vector3) - prev
		if step.length() > MAX_LEN:
			pts[i] = prev + step.normalized() * MAX_LEN
	var root := _make(pts, "wall", arch, h, holes, stone_material(), true)
	if root == null:
		return
	add_child(root)
	# Sample along the run so select/delete clicks land anywhere on it
	var mids: Array = []
	for i in pts.size() - 1:
		var seg := (pts[i + 1] as Vector3) - (pts[i] as Vector3)
		var steps := maxi(1, int(seg.length() / 4.0))
		for s in steps:
			mids.append((pts[i] as Vector3) + seg * ((s + 0.5) / steps))
	_castles[id] = {"root": root, "points": pts + mids, "data": c}


static func stone_material() -> Material:
	return Registry.stone()


## Castles are the legacy protocol on top of the parametric models: this node
## still speaks castlePlaced/castleUpdated, but the geometry comes from
## Items/parametric/models the same as anything else. One implementation, and
## a wall placed the old way is the same object as one placed the new way.
func _record(pts: Array, kind: String, arch: bool, h: float, holes: Array) -> Dictionary:
	if kind == "tower":
		return {
			"type": "tower",
			"nodes": Registry.to_wire([pts[0]]),
			"params": {"height": h, "radius": TOWER_R, "coping": COPING, "tooth": TOOTH_H},
		}
	# The old protocol had a `gate` flag. There is no such flag now -- a gateway
	# is a hole aimed low -- so an arched legacy wall gets one punched at the
	# middle of its run, which is exactly where the flag used to put it.
	var punched: Array = holes.duplicate()
	if arch and pts.size() >= 2:
		var mid: Vector3 = (pts[0] as Vector3).lerp(pts[pts.size() - 1], 0.5)
		punched.append(mid + Vector3(0, 2.2, 0))
	return {
		"type": "wall",
		"nodes": Registry.to_wire(pts),
		"holes": Registry.to_wire(punched),
		"params": {
			"height": h, "thickness": THICK, "batter": BATTER,
			"coping": COPING, "tooth": TOOTH_H,
		},
	}


func _make(pts: Array, kind: String, arch: bool, h: float, holes: Array,
		mat: Material, collide: bool) -> Node3D:
	return Registry.build(_record(pts, kind, arch, h, holes), mat, collide)
