extends SceneTree

## Is the SWEEP inside out, or is it separate solids touching? Same directed-edge
## test, but on one bare sweep at a time with nothing else in the mesh.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")
const Registry := preload("res://Items/parametric/registry.gd")

func _initialize() -> void:
	_one("straight wall section", Ops.mitre_frames([Vector3(-10, 0, 0), Vector3(10, 0, 0)]),
		Profiles.wall(1.0, 6.0, 8.0, 0.22, 0.9, 0.0), false)
	_one("plain box section", Ops.mitre_frames([Vector3(-10, 0, 0), Vector3(10, 0, 0)]),
		Profiles.rect(-1.0, 1.0, 0.0, 4.0), false)
	_one("tower ring (closed)", Ops.ring_frames(Vector3.ZERO, 3.2, 14),
		Profiles.tower(3.2, 9.0, 8.0, 0.35, 0.9, 0.0), true)
	print("--- whole models, teeth off ---")
	for type in ["tower", "wall"]:
		var params: Dictionary = Registry.defaults(type)
		params["tooth"] = 0.0
		var nodes := [Vector3.ZERO] if type == "tower" else [Vector3(-10, 0, 0), Vector3(10, 0, 0)]
		_report(type + " no teeth", _mesh_of(Registry.build({
			"type": type, "nodes": Registry.to_wire(nodes), "params": params}, null, false)))
	quit()


func _one(label: String, frames: Array, prof: PackedVector2Array, closed: bool) -> void:
	var st := Ops.surface()
	var hulls: Array = []
	Ops.sweep(st, frames, prof, hulls, {"caps": not closed, "closed": closed, "hulls": false})
	st.index()
	_report(label, st.commit())


func _mesh_of(body: Node3D) -> ArrayMesh:
	for c in body.get_children():
		if c is MeshInstance3D:
			return (c as MeshInstance3D).mesh as ArrayMesh
	return null


func _report(label: String, mesh: ArrayMesh) -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		print("  %-24s EMPTY" % label)
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var dir := {}
	var i := 0
	var vol := 0.0
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
		vol += v[idx[i]].dot(v[idx[i + 1]].cross(v[idx[i + 2]])) / 6.0
		i += 3
	var clash := 0
	for k in dir:
		if int(dir[k]) > 1:
			clash += int(dir[k]) - 1
	print("  %-24s %4d faces  %4d clashes  volume %+9.1f  %s" % [
		label, idx.size() / 3, clash, vol, "INSIDE OUT" if clash > 0 else "consistent"])


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x * 64.0), roundi(p.y * 64.0), roundi(p.z * 64.0)]


## An edge lying on the model's own vertical axis, where a collapsed section
## makes many faces meet by construction.
static func _collapsed(a: Vector3, b: Vector3) -> bool:
	return Vector2(a.x, a.z).length() < 0.02 and Vector2(b.x, b.z).length() < 0.02
