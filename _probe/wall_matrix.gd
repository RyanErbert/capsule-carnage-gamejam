extends SceneTree

## Which wall is torn? One row per case, so the failing axis is obvious rather
## than inferred. Defaults everywhere except the axis named.

const Registry := preload("res://Items/parametric/registry.gd")

const RAILS := {
	"straight": [Vector3(-20, 0, 0), Vector3(20, 0, 0)],
	"straight 3": [Vector3(-20, 0, 0), Vector3(0, 0, 0), Vector3(20, 0, 0)],
	"bent flat": [Vector3(-20, 0, -6), Vector3(-2, 0, -6), Vector3(6, 0, 4)],
	"bent sloped": [Vector3(-20, 0, -6), Vector3(-2, 0, -6), Vector3(6, 2, 4)],
	"sloped": [Vector3(-20, 0, 0), Vector3(20, 6, 0)],
}


func _initialize() -> void:
	print("%-13s %-6s %-6s %-7s %s" % ["rail", "holes", "arch", "open", "tris"])
	for name in RAILS:
		for holes in [0, 1]:
			for arch: float in [0.0, 0.7]:
				var params: Dictionary = Registry.defaults("wall")
				params["arch"] = arch
				var rec := {
					"type": "wall",
					"nodes": Registry.to_wire(RAILS[name]),
					"params": params,
				}
				if holes > 0:
					rec["holes"] = [{"x": -12.0, "y": 2.0, "z": (RAILS[name][0] as Vector3).z}]
				var r := _edges(Registry.build(rec, null, false))
				print("%-13s %-6d %-6.2f %-7d %d%s" % [name, holes, arch, r[0], r[1],
					"   <-- OPEN" if r[0] > 0 else ""])
	quit()


func _edges(body: Node3D) -> Array:
	var mesh: ArrayMesh = null
	for c in body.get_children():
		if c is MeshInstance3D:
			mesh = (c as MeshInstance3D).mesh as ArrayMesh
	if mesh == null:
		return [-1, 0]
	var arrays: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var seen := {}
	var i := 0
	while i + 2 < idx.size():
		for e: Array in [[0, 1], [1, 2], [2, 0]]:
			var ka := _key(v[idx[i + e[0]]])
			var kb := _key(v[idx[i + e[1]]])
			var k := (ka + "|" + kb) if ka < kb else (kb + "|" + ka)
			seen[k] = int(seen.get(k, 0)) + 1
		i += 3
	var open := 0
	for k in seen:
		if int(seen[k]) == 1:
			open += 1
	return [open, idx.size() / 3]


static func _key(v: Vector3) -> String:
	return "%d,%d,%d" % [roundi(v.x * 64.0), roundi(v.y * 64.0), roundi(v.z * 64.0)]
