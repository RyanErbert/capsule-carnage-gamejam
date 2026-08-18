extends SceneTree

## Headless manifold + size check for the parametric sweep. Every edge of a
## closed solid is shared by exactly two triangles; anything else is a hole,
## which is how the WFC compounds went wrong. Run before trusting a profile.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")


func _initialize() -> void:
	_run("wall", Ops.mitre_frames([
		Vector3(-24, 0, -10), Vector3(-6, 0, -10),
		Vector3(4, 2.5, 0), Vector3(4, 4.0, 16),
	]), Profiles.wall(1.0, 6.0, 3.0, 0.22, 0.9), true, false)
	_run("wall_hairpin", Ops.mitre_frames([
		Vector3(0, 0, 0), Vector3(20, 0, 0), Vector3(1, 0, 1.5),
	]), Profiles.wall(1.0, 6.0, 3.0, 0.22, 0.9), true, false)
	_run("tower", Ops.ring_frames(Vector3(22, 0, -6), 4.5, 14),
		Profiles.wall(1.0, 9.0, 3.0, 0.3, 0.9), false, true)
	_run("deck", Ops.curve_frames([
		Vector3(-24, 6, 24), Vector3(-8, 8, 30), Vector3(10, 8, 26), Vector3(26, 6, 30),
	], {"spacing": 2.0}), Profiles.deck(3.0, 0.6, 0.45), true, false)
	_run("path", Ops.curve_frames([
		Vector3(-26, 0.2, 8), Vector3(-10, 0.2, 14), Vector3(8, 0.6, 10), Vector3(24, 0.4, 16),
	], {"spacing": 1.6}), Profiles.path(2.0), true, false)
	_run("trough", Ops.curve_frames([
		Vector3(-20, 4, 0), Vector3(0, 2, 10), Vector3(20, 4, 0),
	], {"spacing": 1.5, "bank": 1.0}), Profiles.trough(2.5, 16), true, false)

	# repeat_along + slice: the merlon path, cut off a real rail
	var f: Array = Ops.mitre_frames([Vector3(0, 0, 0), Vector3(12, 0, 0), Vector3(12, 0, 9)])
	var ds: PackedFloat32Array = Ops.repeat_distances(f, 3.2)
	var spans := 0
	for d in ds:
		spans += Ops.slice(f, d - 0.8, d + 0.8).size()
	print("[repeat] len=%.1f repeats=%d sliced_frames=%d" % [Ops.rail_length(f), ds.size(), spans])
	quit()


func _run(label: String, frames: Array, profile: PackedVector2Array,
		caps: bool, closed: bool) -> void:
	var st: SurfaceTool = Ops.surface()
	var hulls: Array = []
	Ops.sweep(st, frames, profile, hulls, {"caps": caps, "closed": closed})
	st.index()
	var mesh: ArrayMesh = st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		print("[%s] EMPTY" % label)
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	print("[%s] frames=%d profile=%d tris=%d verts=%d hulls=%d open_edges=%d len=%.1f" % [
		label, frames.size(), profile.size(), idx.size() / 3, verts.size(),
		hulls.size(), _open_edges(verts, idx), Ops.rail_length(frames)])


static func _open_edges(verts: PackedVector3Array, idx: PackedInt32Array) -> int:
	var seen := {}
	var i := 0
	while i + 2 < idx.size():
		for e in [[0, 1], [1, 2], [2, 0]]:
			var ka: String = _key(verts[idx[i + e[0]]])
			var kb: String = _key(verts[idx[i + e[1]]])
			var k: String = (ka + "|" + kb) if ka < kb else (kb + "|" + ka)
			seen[k] = int(seen.get(k, 0)) + 1
		i += 3
	var open := 0
	for k in seen:
		if int(seen[k]) != 2:
			open += 1
	return open


static func _key(v: Vector3) -> String:
	return "%d,%d,%d" % [roundi(v.x * 64.0), roundi(v.y * 64.0), roundi(v.z * 64.0)]
