extends SceneTree

## Every registered model: builds it, checks the solid is closed, lists its
## handles, and dumps its spec so _probe/spec_parity can diff it against
## server/parametrics.js.

const Registry := preload("res://Items/parametric/registry.gd")
const SpecLib := preload("res://Items/parametric/spec.gd")

const CASES := {
	"wall": [Vector3(-20, 0, -6), Vector3(-2, 0, -6), Vector3(6, 2, 4)],
	"tower": [Vector3(14, 0, 0)],
	"bridge": [Vector3(-20, 8, 14), Vector3(-4, 9, 18), Vector3(12, 9, 15), Vector3(24, 8, 18)],
	"path": [Vector3(-20, 0, 6), Vector3(-6, 0, 10), Vector3(10, 1, 7), Vector3(22, 0, 10)],
}


func _initialize() -> void:
	var mat := StandardMaterial3D.new()
	var specs := {}
	for type in Registry.types():
		var rec := {
			"type": type,
			"nodes": Registry.to_wire(CASES[type]),
			"params": Registry.defaults(type),
		}
		if type == "wall":
			rec["params"]["gate"] = 1.0
			rec["holes"] = [{"x": -12.0, "y": 2.0, "z": -6.0}]
		var body: Node3D = Registry.build(rec, mat, true)
		_report(type, body)
		var hs := Registry.handles(rec)
		var names: Array = []
		for h in hs:
			var d: Dictionary = h
			names.append("node%d" % int(d["node"]) if int(d["node"]) >= 0 else str(d["key"]))
		print("       handles: %s" % ", ".join(names))
		_check_roundtrip(type, hs)

		var table := {}
		for e in Registry.spec(type):
			var d: Dictionary = e
			table[str(d["key"])] = [float(d["min"]), float(d["max"]), float(d["default"])]
		specs[type] = table

	var f := FileAccess.open(OS.get_environment("SPEC_OUT"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(specs))
		f.close()
	quit()


## A handle placed at origin + axis * value * scale must read back the same
## value when you invert it. If this drifts, dragging jumps on grab.
func _check_roundtrip(type: String, handles: Array) -> void:
	var bad := 0
	for h in handles:
		var d: Dictionary = h
		if int(d["node"]) >= 0:
			continue
		if absf(SpecLib.value_at(d, d["pos"]) - float(d["value"])) > 1e-3:
			bad += 1
	if bad:
		print("       HANDLE ROUNDTRIP FAILED on %d handles (%s)" % [bad, type])


func _report(type: String, body: Node3D) -> void:
	if body == null:
		print("[%s] NULL" % type)
		return
	var mi: MeshInstance3D = null
	var shapes := 0
	for c in body.get_children():
		if c is MeshInstance3D:
			mi = c
		elif c is CollisionShape3D:
			shapes += 1
	if mi == null:
		print("[%s] EMPTY" % type)
		return
	var arrays: Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var i: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	print("[%s] tris=%d shapes=%d open_edges=%d" % [type, i.size() / 3, shapes, _open(v, i)])


static func _open(verts: PackedVector3Array, idx: PackedInt32Array) -> int:
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
