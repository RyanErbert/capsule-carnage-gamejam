extends SceneTree

## The ground blend is a number baked into every vertex, so it can be checked
## as a number. COLOR.r must be 0 at the ground line and below it, 1 once clear
## of the blend band, and -- the part that is easy to get wrong -- 1 on a merlon,
## which rides a rail lifted by the whole height of the wall and would otherwise
## come out buried in dirt at the top of a battlement.

const Registry := preload("res://Items/parametric/registry.gd")
const Ops := preload("res://Items/parametric/ops.gd")

const H := 9.0
const BAND := Ops.GROUND_BLEND

var _fails := 0


func _initialize() -> void:
	var wall := _verts("wall", [Vector3(-16, 0, 0), Vector3(16, 0, 0)])
	_check(not wall.is_empty(), "wall has vertices to check")

	var bad_low := 0
	var bad_high := 0
	var bad_mid := 0
	var top := 0
	for pair in wall:
		var y: float = (pair[0] as Vector3).y
		var g: float = pair[1]
		if y <= 0.001 and g > 0.001:
			bad_low += 1
		elif y >= BAND and g < 0.999:
			bad_high += 1
		elif y > 0.001 and y < BAND and absf(g - y / BAND) > 0.01:
			bad_mid += 1
		if y > H - 0.01:
			top += 1
			if g < 0.999:
				_fails += 1
	_check(bad_low == 0, "buried and at the line: fully ground (%d wrong)" % bad_low)
	_check(bad_high == 0, "clear of the band: fully stone (%d wrong)" % bad_high)
	_check(bad_mid == 0, "and linear in between (%d wrong)" % bad_mid)
	_check(top > 0, "found the merlon course: %d vertices at the head or above" % top)

	# A rail that does not sit on the ground opts out entirely.
	for type in ["path", "bridge"]:
		var flat := _verts(type, [Vector3(-14, 4, 0), Vector3(0, 5, 0), Vector3(14, 4, 0)])
		var blended := 0
		for pair in flat:
			if float(pair[1]) < 0.999:
				blended += 1
		_check(not flat.is_empty() and blended == 0,
			"%s opts out: %d of %d vertices blended" % [type, blended, flat.size()])

	# A tower is a wall bent onto a circle, so it obeys the same rule.
	var tower := _verts("tower", [Vector3(0, 0, 0)])
	var t_low := 0
	for pair in tower:
		if (pair[0] as Vector3).y <= 0.001 and float(pair[1]) > 0.001:
			t_low += 1
	_check(t_low == 0, "tower reads the same at its foot (%d wrong)" % t_low)

	print("ground blend: %s" % ("all checks passed" if _fails == 0 else "%d FAILED" % _fails))
	quit()


## Every vertex as [position, ground factor].
func _verts(type: String, nodes: Array) -> Array:
	var params: Dictionary = Registry.defaults(type)
	if params.has("height"):
		params["height"] = H
	var body: Node3D = Registry.build(
		{"type": type, "nodes": Registry.to_wire(nodes), "params": params}, null, false)
	if body == null:
		return []
	var mesh: ArrayMesh = null
	for c in body.get_children():
		if c is MeshInstance3D:
			mesh = (c as MeshInstance3D).mesh as ArrayMesh
	if mesh == null:
		return []
	var arrays: Array = mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var col: Variant = arrays[Mesh.ARRAY_COLOR]
	if not (col is PackedColorArray) or (col as PackedColorArray).size() != pos.size():
		_check(false, "%s baked no vertex colour at all" % type)
		return []
	var out: Array = []
	for i in pos.size():
		out.append([pos[i], (col as PackedColorArray)[i].r])
	return out


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
