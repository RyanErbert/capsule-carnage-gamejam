extends SceneTree

## WHERE are the tower's clashing edges? Printing their endpoints says which
## part of the section is at fault, which guessing does not.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")

func _initialize() -> void:
	var prof := Profiles.tower(3.2, 9.0, 8.0, 0.35, 0.9, 0.0)
	print("section: %d points" % prof.size())
	for i in prof.size():
		print("  %2d  u %7.3f  v %7.3f" % [i, prof[i].x, prof[i].y])
	var st := Ops.surface()
	var hulls: Array = []
	Ops.sweep(st, Ops.ring_frames(Vector3.ZERO, 3.2, 14), prof, hulls,
		{"closed": true, "hulls": false})
	st.index()
	var mesh := st.commit()
	var arrays: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var dir := {}
	var i := 0
	while i + 2 < idx.size():
		for e: Array in [[0, 1], [1, 2], [2, 0]]:
			var k := _key(v[idx[i + e[0]]]) + ">" + _key(v[idx[i + e[1]]])
			if not dir.has(k):
				dir[k] = [0, v[idx[i + e[0]]], v[idx[i + e[1]]]]
			dir[k][0] = int(dir[k][0]) + 1
		i += 3
	var shown := 0
	for k in dir:
		if int(dir[k][0]) > 1:
			shown += 1
			if shown <= 8:
				var a: Vector3 = dir[k][1]
				var b: Vector3 = dir[k][2]
				print("  clash x%d  (%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f)  r %.2f/%.2f" % [
					int(dir[k][0]), a.x, a.y, a.z, b.x, b.y, b.z,
					Vector2(a.x, a.z).length(), Vector2(b.x, b.z).length()])
	print("total clashing directed edges: %d" % shown)
	quit()


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x * 64.0), roundi(p.y * 64.0), roundi(p.z * 64.0)]
