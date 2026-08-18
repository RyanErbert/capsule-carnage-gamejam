extends Node3D

## Every parametric structure standing in the world, and the one being edited.
##
## Nothing here is geometry over the wire. A structure is a record -- a type, a
## chain of nodes, some punched holes and a bag of numbers -- and this node
## rebuilds the mesh from it locally. That is what makes a live handle drag
## affordable: stretching a wall is a couple of hundred bytes a frame where the
## mesh it produces is megabytes.
##
## A drag runs optimistically. The local record moves the instant the handle
## does, so the wall follows your hand at frame rate, and the server is told at
## SEND_HZ. Its echo is authoritative and is applied on release -- but ignored
## while you are still dragging, or every round trip would yank the geometry
## back to where it was a fifth of a second ago.

const Registry := preload("res://Items/parametric/registry.gd")
const HandleRig := preload("res://Items/parametric/handle_rig.gd")

const SEND_HZ := 12.0     # updateParametric messages per second while dragging
const PICK_R := 6.0       # how far a click may miss and still find a structure
const MAX_HOLES := 24     # matches server/parametrics.js

signal selection_changed(id: String)

var _structs: Dictionary = {}   # id -> {root, points, rec}
var _rig: Node3D
var _selected := ""
var _dirty := false             # local record has moved ahead of the server
var _send_cd := 0.0
var _stone: StandardMaterial3D
var _ghost: StandardMaterial3D
## Bodies the owner is flying that must not catch a node drag -- the build
## drone sits right in front of the camera and would eat every one of them.
var extra_exclude: Array = []


func _ready() -> void:
	add_to_group("world_parametrics")
	_stone = Registry.stone()
	_ghost = Registry.ghost()
	_rig = HandleRig.new()
	_rig.name = "HandleRig"
	_rig.self_input = false     # the build drone arbitrates the click
	add_child(_rig)
	_rig.param_changed.connect(_on_param_changed)
	_rig.node_changed.connect(_on_node_changed)
	_rig.edit_committed.connect(_on_edit_committed)
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentParametrics":
			for id in _structs.keys():
				_drop(str(id))
			if data is Array:
				for rec in data:
					_add(rec)
		"parametricPlaced":
			_add(data)
		"parametricUpdated":
			if data is Dictionary:
				var id := str(data.get("id", ""))
				# Mid-drag, our local copy is ahead of this. Taking it would
				# fight the hand that is moving the handle.
				if id == _selected and (_rig.is_dragging() or _dirty):
					return
				_add(data)
				if id == _selected:
					_rig.show_record(_structs[id]["rec"], _mesh_of(id))
		"parametricRemoved":
			_drop(str(data))


# --- Store -------------------------------------------------------------------

func _add(rec: Variant) -> void:
	if not (rec is Dictionary):
		return
	var id := str((rec as Dictionary).get("id", ""))
	if id == "":
		return
	var root: Node3D = Registry.build(rec, _stone, true)
	if root == null:
		return
	_free_root(id)
	add_child(root)
	_structs[id] = {"root": root, "points": _sample(rec), "rec": rec}


func _drop(id: String) -> void:
	_free_root(id)
	_structs.erase(id)
	if id == _selected:
		select("")


func _free_root(id: String) -> void:
	if _structs.has(id) and is_instance_valid(_structs[id]["root"]):
		_structs[id]["root"].queue_free()


func record(id: String) -> Dictionary:
	return _structs[id]["rec"] if _structs.has(id) else {}


func _mesh_of(id: String) -> Mesh:
	if not _structs.has(id):
		return null
	for c in (_structs[id]["root"] as Node).get_children():
		if c is MeshInstance3D:
			return (c as MeshInstance3D).mesh
	return null


## Rebuild one structure from its own record. Collision is skipped mid-drag:
## a wall being stretched is re-hulled every frame otherwise, and nothing can
## stand on it while your hand is still moving anyway.
func _rebuild(id: String, collide: bool) -> void:
	if not _structs.has(id):
		return
	var rec: Dictionary = _structs[id]["rec"]
	var root: Node3D = Registry.build(rec, _stone, collide)
	if root == null:
		return
	_free_root(id)
	add_child(root)
	_structs[id]["root"] = root
	_structs[id]["points"] = _sample(rec)


# --- Selection ---------------------------------------------------------------

func selected() -> String:
	return _selected


## Select by id, or "" to drop the selection. The rig borrows the mesh we just
## built rather than building its own copy of it.
func select(id: String) -> void:
	if id != "" and not _structs.has(id):
		id = ""
	if id == _selected:
		return
	_selected = id
	_dirty = false
	if id == "":
		_rig.show_record({})
	else:
		_rig.ray_exclude = _bodies_of(id)
		_rig.show_record(_structs[id]["rec"], _mesh_of(id))
	selection_changed.emit(id)


## Bodies a node drag must not land on. The structure under edit is directly
## beneath the aim, so without this a node dragged across its own wall sticks
## to it and cannot be pulled anywhere else.
func _bodies_of(id: String) -> Array:
	var out: Array = []
	if _structs.has(id) and _structs[id]["root"] is CollisionObject3D:
		out.append((_structs[id]["root"] as CollisionObject3D).get_rid())
	return out + extra_exclude


## Which structure a raycast landed on, exactly -- no radius, no guessing.
func id_for_collider(node: Object) -> String:
	if not (node is Node):
		return ""
	for id in _structs:
		var root: Node = _structs[id]["root"]
		if is_instance_valid(root) and (root == node or root.is_ancestor_of(node as Node)):
			return str(id)
	return ""


## Nearest structure to a point, for the delete tool, which works off a
## position rather than a hit. Samples run along the rail AND at mid height, so
## clicking the top of a tall wall finds it as readily as clicking its foot.
func nearest_deletable(pos: Vector3, radius := PICK_R) -> Dictionary:
	var best := {}
	for id in _structs:
		for p in _structs[id]["points"]:
			var d: float = (p as Vector3).distance_to(pos)
			if d < radius and (best.is_empty() or d < best["dist"]):
				best = {"id": str(id), "dist": d, "pos": p}
	return best


func _sample(rec: Dictionary) -> Array:
	var pts := Registry.to_points(rec.get("nodes", []))
	if pts.is_empty():
		return []
	var params: Dictionary = rec.get("params", {})
	var h := float(params.get("height", params.get("thick", 1.0)))
	var out: Array = []
	var rail: Array = pts.duplicate()
	for i in pts.size() - 1:
		var seg: Vector3 = (pts[i + 1] as Vector3) - (pts[i] as Vector3)
		var steps := maxi(1, int(seg.length() / 4.0))
		for s in steps:
			rail.append((pts[i] as Vector3) + seg * ((s + 0.5) / steps))
	for p in rail:
		out.append(p)
		if h > 2.0:
			out.append((p as Vector3) + Vector3(0, h * 0.5, 0))
			out.append((p as Vector3) + Vector3(0, h, 0))
	return out


# --- Editing -----------------------------------------------------------------

## The build drone owns the mouse button and hands the press here first. True
## means a handle took it, so nothing else should act on the same click.
func click(pressed: bool) -> bool:
	return _rig.click(pressed)


func rig() -> Node3D:
	return _rig


## Punch a penetration at a world point. The model decides what a hole there
## means -- a wall turns it into a window with a sill and a lintel.
func punch(id: String, at: Vector3) -> void:
	if not _structs.has(id):
		return
	var rec: Dictionary = _structs[id]["rec"]
	var holes: Array = (rec.get("holes", []) as Array).duplicate()
	if holes.size() >= MAX_HOLES:
		return
	holes.append({"x": at.x, "y": at.y, "z": at.z})
	rec["holes"] = holes
	Net.emit_event("updateParametric", {"id": id, "holes": holes})
	_rebuild(id, true)
	if id == _selected:
		_rig.show_record(rec, _mesh_of(id))


## Nudge one parameter by a step -- the scroll wheel's way in, for the
## parameters that have no handle of their own.
func nudge(id: String, key: String, delta: float) -> float:
	if not _structs.has(id):
		return 0.0
	var rec: Dictionary = _structs[id]["rec"]
	var e := _entry(str(rec.get("type", "")), key)
	if e.is_empty():
		return 0.0
	var params: Dictionary = (rec.get("params", {}) as Dictionary).duplicate()
	var v := clampf(float(params.get(key, e["default"])) + delta * maxf(float(e["step"]), 0.01),
		float(e["min"]), float(e["max"]))
	params[key] = v
	rec["params"] = params
	_dirty = true
	_rebuild(id, true)
	if id == _selected:
		_rig.refresh(rec, _mesh_of(id))
	return v


static func _entry(type: String, key: String) -> Dictionary:
	for e in Registry.spec(type):
		if str((e as Dictionary).get("key", "")) == key:
			return e
	return {}


func _on_param_changed(key: String, value: float) -> void:
	if not _structs.has(_selected):
		return
	var rec: Dictionary = _structs[_selected]["rec"]
	var params: Dictionary = (rec.get("params", {}) as Dictionary).duplicate()
	params[key] = value
	rec["params"] = params
	_dirty = true


func _on_node_changed(index: int, pos: Vector3) -> void:
	if not _structs.has(_selected):
		return
	var rec: Dictionary = _structs[_selected]["rec"]
	var nodes: Array = (rec.get("nodes", []) as Array).duplicate()
	if index < 0 or index >= nodes.size():
		return
	nodes[index] = {"x": pos.x, "y": pos.y, "z": pos.z}
	rec["nodes"] = nodes
	_dirty = true


func _on_edit_committed() -> void:
	if not _structs.has(_selected):
		return
	_rebuild(_selected, true)
	_rig.ray_exclude = _bodies_of(_selected)
	_rig.refresh(_structs[_selected]["rec"], _mesh_of(_selected))
	_send()


func _process(dt: float) -> void:
	_send_cd = maxf(_send_cd - dt, 0.0)
	if not _dirty or _selected == "" or not _structs.has(_selected):
		return
	# Follow the hand every frame locally; tell the server at SEND_HZ.
	_rebuild(_selected, not _rig.is_dragging())
	_rig.refresh(_structs[_selected]["rec"], _mesh_of(_selected))
	if _send_cd <= 0.0:
		_send()


func _send() -> void:
	if not _structs.has(_selected):
		return
	var rec: Dictionary = _structs[_selected]["rec"]
	Net.emit_event("updateParametric", {
		"id": _selected,
		"params": rec.get("params", {}),
		"nodes": rec.get("nodes", []),
	})
	_dirty = false
	_send_cd = 1.0 / SEND_HZ


# --- Previews ----------------------------------------------------------------

## The structure a click-chain would build, as an unlit blue ghost. Caller owns
## the node and frees it when the cursor moves.
func make_preview(type: String, nodes: Array, params: Dictionary) -> Node3D:
	var root: Node3D = Registry.build(
		{"type": type, "nodes": Registry.to_wire(nodes), "params": params}, _ghost, false)
	if root == null:
		root = Node3D.new()
	add_child(root)
	return root


