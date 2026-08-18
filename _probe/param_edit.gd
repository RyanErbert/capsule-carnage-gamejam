extends Node3D

## The whole edit loop, without a mouse: records in, geometry out, handles on
## it, drags and punches and scrolls changing it. Runs as a .tscn probe rather
## than --script because Items/parametrics.gd talks to the Net autoload, and
## --script probes have no autoloads.

const Parametrics := preload("res://Items/parametrics.gd")

var _pm: Node3D
var _fails := 0
var _step := 0
var _fat := Vector3.ZERO   # the wall's bounds at maximum thickness


func _ready() -> void:
	# Everything the god menu touches has to compile with the autoloads present.
	for path in ["res://Items/parametrics.gd", "res://UI/god_menu.gd",
			"res://Items/castle.gd", "res://Items/parametric/handle_rig.gd"]:
		_check(load(path) != null, "compiles: %s" % path.get_file())

	_pm = Node3D.new()
	_pm.set_script(Parametrics)
	add_child(_pm)


func _process(_dt: float) -> void:
	# One assertion block per frame: the node rebuilds in _process, so the
	# effect of a drag is only visible on the frame after it.
	_step += 1
	match _step:
		1: _place()
		2: _select_and_handles()
		3: _drag_height()
		4: _after_drag()
		5: _punch_and_nudge()
		6: _echo_and_remove()
		7: _finish()


func _place() -> void:
	Net.event_received.emit("currentParametrics", [_wall(), _tower()])
	_check(_pm.record("w1").get("type", "") == "wall", "wall record stored")
	_check(_pm.record("t1").get("type", "") == "tower", "tower record stored")
	_check(_body("w1") != null, "wall built a body")
	_check(_shapes("w1") > 0, "wall built collision hulls: %d" % _shapes("w1"))

	# Selection by ray hit: the collider is a child of the structure root.
	var body := _body("w1")
	var child: Node = body.get_child(0) if body.get_child_count() else body
	_check(_pm.id_for_collider(child) == "w1", "id_for_collider walks up to the root")
	_check(_pm.id_for_collider(self) == "", "id_for_collider ignores strangers")
	# And by proximity, for the delete tool, which only ever has a position.
	var near: Dictionary = _pm.nearest_deletable(Vector3(0, 5, 0))
	_check(str(near.get("id", "")) == "w1", "nearest_deletable finds the wall at head height")


func _select_and_handles() -> void:
	_pm.select("w1")
	var rig: Node = _pm.rig()
	_check(rig.active, "rig is up")
	_check(rig.record.get("id", "") == "w1", "rig points at the selection")
	# 3 nodes + height + thickness
	_check(rig._handles.size() == 5, "handles on a 3-node wall: %d" % rig._handles.size())
	_check(rig._outline != null and rig._outline.mesh != null, "outline borrowed a mesh")
	_check(rig._outline.mesh == _mesh("w1"), "outline is the structure's own mesh, not a rebuild")
	_check(rig.ray_exclude.size() == 1, "node drags exclude the wall they belong to")


func _drag_height() -> void:
	var rig: Node = _pm.rig()
	# Stand in for a drag: the rig emits these every frame while a handle moves.
	rig._held = 3          # the height handle
	rig.param_changed.emit("height", 15.0)
	_check(absf(float(_pm.record("w1")["params"]["height"]) - 15.0) < 0.01,
		"drag moved the local record straight away")
	# An echo of the OLD value while the hand is still moving must not land.
	Net.event_received.emit("parametricUpdated", _wall())
	_check(absf(float(_pm.record("w1")["params"]["height"]) - 15.0) < 0.01,
		"mid-drag server echo is ignored")


func _after_drag() -> void:
	var top := _aabb("w1").end.y
	_check(top > 13.0, "geometry followed the drag: top at %.1f" % top)
	_check(_shapes("w1") == 0, "collision is skipped mid-drag")
	var rig: Node = _pm.rig()
	rig._held = -1
	rig.edit_committed.emit()
	_check(_shapes("w1") > 0, "collision comes back on release: %d hulls" % _shapes("w1"))
	_check(rig._handles.size() == 5, "handles survived the rebuild")


func _punch_and_nudge() -> void:
	var before := _tris("w1")
	_pm.punch("w1", Vector3(0, 8, -3.0))   # on the face, at head height
	_check((_pm.record("w1")["holes"] as Array).size() == 1, "hole recorded")
	_check(_tris("w1") != before, "punching changed the mesh: %d -> %d tris" % [before, _tris("w1")])

	# Scroll: one spec step per notch, clamped at the ends of the range.
	var thick0 := float(_pm.record("w1")["params"]["thickness"])
	var thick1: float = _pm.nudge("w1", "thickness", 1.0)
	_check(absf(thick1 - thick0 - 0.1) < 0.001, "one notch is one spec step: %.2f" % thick1)
	for i in 200:
		_pm.nudge("w1", "thickness", 1.0)
	_check(absf(float(_pm.record("w1")["params"]["thickness"]) - 6.0) < 0.001,
		"scroll clamps at the spec maximum")
	_check(_pm.nudge("w1", "nonsense", 1.0) == 0.0, "unknown parameter is refused")

	# Thickness is a real dimension after placement, which was the whole point.
	_fat = _aabb("w1").size
	_pm.nudge("w1", "thickness", -100.0)


func _echo_and_remove() -> void:
	var thin := float(_pm.record("w1")["params"]["thickness"])
	_check(absf(thin - 0.6) < 0.001, "thickness ran all the way down to the minimum")
	var slim := _aabb("w1").size
	# The run bends, so neither axis carries the whole change; between them they
	# have to account for it.
	_check(slim.x < _fat.x and slim.z < _fat.z
		and (_fat.x - slim.x) + (_fat.z - slim.z) > 4.0,
		"and the wall got thinner with it: %.1f x %.1f -> %.1f x %.1f"
		% [_fat.x, _fat.z, slim.x, slim.z])
	# Not dragging now, so the server's word is final.
	Net.event_received.emit("parametricUpdated", _wall())
	_check(absf(float(_pm.record("w1")["params"]["height"]) - 6.0) < 0.01,
		"a settled echo is authoritative")
	Net.event_received.emit("parametricRemoved", "w1")
	_check(_pm.record("w1").is_empty(), "removed")
	_check(_pm.selected() == "", "removing the selection drops it")
	_check(not (_pm.rig() as Node).active, "and puts the rig away")


func _finish() -> void:
	print("param edit: %s" % ("all checks passed" if _fails == 0 else "%d FAILED" % _fails))
	get_tree().quit()


# --- Fixtures ----------------------------------------------------------------

static func _wall() -> Dictionary:
	return {
		"id": "w1", "type": "wall", "owner": "probe",
		"nodes": [{"x": -14, "y": 0, "z": -4}, {"x": 6, "y": 0, "z": -4}, {"x": 16, "y": 1, "z": 6}],
		"holes": [],
		"params": {"height": 6.0, "thickness": 2.0, "batter": 0.22,
			"coping": 0.9, "tooth": 1.1, "gate": 0.0},
	}


static func _tower() -> Dictionary:
	return {
		"id": "t1", "type": "tower", "owner": "probe",
		"nodes": [{"x": 40, "y": 0, "z": 40}], "holes": [],
		"params": {"height": 9.0, "radius": 3.2, "batter": 0.35,
			"coping": 0.9, "tooth": 1.1, "sides": 14.0},
	}


# --- Poking about ------------------------------------------------------------

func _body(id: String) -> Node3D:
	return _pm._structs[id]["root"] if _pm._structs.has(id) else null


func _mesh(id: String) -> Mesh:
	var b := _body(id)
	if b == null:
		return null
	for c in b.get_children():
		if c is MeshInstance3D:
			return (c as MeshInstance3D).mesh
	return null


func _tris(id: String) -> int:
	var m := _mesh(id)
	return m.get_faces().size() / 3 if m else 0


func _aabb(id: String) -> AABB:
	var m := _mesh(id)
	return m.get_aabb() if m else AABB()


func _shapes(id: String) -> int:
	var b := _body(id)
	if b == null:
		return 0
	var n := 0
	for c in b.get_children():
		if c is CollisionShape3D:
			n += 1
	return n


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
