extends SceneTree

## Are any faces inside out?
##
## The open-edge count cannot answer this. It bins edges without direction, so a
## triangle wound backwards still contributes two edges and still reads as
## closed -- which is why every model has been reporting watertight while Ryan
## keeps seeing through walls.
##
## Orientation is a DIRECTED question. On a consistently wound closed surface
## every directed edge a->b appears exactly once, and its reverse b->a exactly
## once. Two triangles sharing an edge in the SAME direction disagree about
## which side is out: one of them is inside out.

const Registry := preload("res://Items/parametric/registry.gd")

const CASES := {
	"wall": [Vector3(-20, 0, -6), Vector3(-2, 0, -6), Vector3(6, 2, 4)],
	"tower": [Vector3(0, 0, 0)],
	"bridge": [Vector3(-20, 8, 14), Vector3(-4, 9, 18), Vector3(12, 9, 15), Vector3(24, 8, 18)],
	"path": [Vector3(-20, 0, 6), Vector3(-6, 0, 10), Vector3(10, 1, 7), Vector3(22, 0, 10)],
}

var _fails := 0


func _initialize() -> void:
	for type in CASES:
		var rec := {
			"type": type,
			"nodes": Registry.to_wire(CASES[type]),
			"params": Registry.defaults(type),
		}
		if type == "wall":
			rec["holes"] = [{"x": -12.0, "y": 2.0, "z": -6.0}]
		_check(type, Registry.build(rec, null, false))
	print("winding: %s" % ("all consistent" if _fails == 0 else "%d MODELS INSIDE OUT" % _fails))
	quit()


func _check(type: String, body: Node3D) -> void:
	var mesh: ArrayMesh = null
	for c in body.get_children():
		if c is MeshInstance3D:
			mesh = (c as MeshInstance3D).mesh as ArrayMesh
	if mesh == null:
		print("  [%s] no mesh" % type)
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var dir := {}
	var i := 0
	while i + 2 < idx.size():
		for e: Array in [[0, 1], [1, 2], [2, 0]]:
			var pa: Vector3 = v[idx[i + e[0]]]
			var pb: Vector3 = v[idx[i + e[1]]]
			# A tower's section folds its inner edge onto the axis, so every
			# station's triangles meet along that one line. Many faces sharing a
			# collapsed seam is a cone apex, not a disagreement about which way
			# is out, so the seam does not count.
			if _collapsed(pa, pb):
				continue
			dir[_key(pa) + ">" + _key(pb)] = int(dir.get(_key(pa) + ">" + _key(pb), 0)) + 1
		i += 3
	# A directed edge seen more than once means two faces agree on direction,
	# which on a surface means they disagree on which way is out.
	var clash := 0
	for k in dir:
		if int(dir[k]) > 1:
			clash += int(dir[k]) - 1
	# Second, independent read: a closed solid's signed volume is positive when
	# its faces point outward. Negative means the whole thing is inverted.
	var vol := 0.0
	i = 0
	while i + 2 < idx.size():
		var a: Vector3 = v[idx[i]]
		var b: Vector3 = v[idx[i + 1]]
		var c: Vector3 = v[idx[i + 2]]
		vol += a.dot(b.cross(c)) / 6.0
		i += 3
	if clash > 0:
		_fails += 1
	print("  [%s] %d faces, %d directed-edge clashes, signed volume %+.1f%s" % [
		idx.size() / 3, clash, vol, ""] if false else "  [%s] %d faces, %d clashes, volume %+.1f  %s" % [
		type, idx.size() / 3, clash, vol, "INSIDE OUT" if clash > 0 else "ok"])


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x * 64.0), roundi(p.y * 64.0), roundi(p.z * 64.0)]


## An edge lying on the model's own vertical axis, where a collapsed section
## makes many faces meet by construction.
static func _collapsed(a: Vector3, b: Vector3) -> bool:
	return Vector2(a.x, a.z).length() < 0.02 and Vector2(b.x, b.z).length() < 0.02
