extends Node3D

## Before and after on the terrain's shading normals, on the same mesh.
##
## "after" is what the mesher now builds: the trilinear field gradient, which is
## continuous everywhere. "before" is the same vertices with the SNAPPED lattice
## gradient put back on them -- constant across a 2 m cell, stepping at the
## boundary. Nothing about the geometry differs between the two shots, which is
## the point: the faceting was never in the mesh.
##
## Set PROBE_SHOT; two files land beside it. Windowed, because headless never
## draws.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")

var _t: Node3D
var _smooth: Array = []      # the mesh each chunk was built with
var _faceted: Array = []     # the same, renormalled the old way


func _ready() -> void:
	_t = VoxelTerrain.new()
	add_child(_t)
	_t.configure(40, 40)
	_t.build_from_layers(_layers())
	_stage()
	_collect()
	_shoot()


## A rolling hill out of the five paint layers: each slab a shrinking blob, so
## the surface arrives at a slope with real curvature rather than a flat ramp.
func _layers() -> Array:
	var out: Array = []
	for li in 5:
		var rows: Array = []
		for z in 40:
			var bits := 0
			for x in 40:
				var dx := float(x) - 20.0
				var dz := float(z) - 20.0
				var r := sqrt(dx * dx + dz * dz) + sin(float(x) * 0.4) * 1.6
				if r < 19.0 - float(li) * 3.4:
					bits |= 1 << (39 - x)
			rows.append(bits)
		out.append(rows)
	return out


func _collect() -> void:
	for key in _t.get("_chunks"):
		var body: Node3D = (_t.get("_chunks")[key])["body"]
		for c in body.get_children():
			if not (c is MeshInstance3D):
				continue
			var mi: MeshInstance3D = c
			var arrays: Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)
			_smooth.append([mi, mi.mesh])
			_faceted.append([mi, _renormal(arrays, mi.mesh)])


## The same surface, shaded the way it used to be.
func _renormal(arrays: Array, src: ArrayMesh) -> ArrayMesh:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	for i in verts.size():
		normals[i] = _snapped(verts[i])
	var out_arrays := []
	out_arrays.resize(Mesh.ARRAY_MAX)
	out_arrays[Mesh.ARRAY_VERTEX] = verts
	out_arrays[Mesh.ARRAY_NORMAL] = normals
	out_arrays[Mesh.ARRAY_COLOR] = arrays[Mesh.ARRAY_COLOR]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
	mesh.surface_set_material(0, src.surface_get_material(0))
	return mesh


func _snapped(p: Vector3) -> Vector3:
	var g: Vector3 = (p - _t.ORIGIN) / _t.VOXEL
	var x := clampi(roundi(g.x), 1, int(_t.NX) - 1)
	var y := clampi(roundi(g.y), 1, int(_t.NY) - 1)
	var z := clampi(roundi(g.z), 1, int(_t.NZ) - 1)
	var n := Vector3(
		float(_t.call("_d", x - 1, y, z)) - float(_t.call("_d", x + 1, y, z)),
		float(_t.call("_d", x, y - 1, z)) - float(_t.call("_d", x, y + 1, z)),
		float(_t.call("_d", x, y, z - 1)) - float(_t.call("_d", x, y, z + 1)),
	)
	return n.normalized() if n.length() > 0.0001 else Vector3.UP


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for pass_name in ["before", "after"]:
		for pair in (_faceted if pass_name == "before" else _smooth):
			(pair[0] as MeshInstance3D).mesh = pair[1]
		for i in 6:
			await RenderingServer.frame_post_draw
		if base != "":
			get_viewport().get_texture().get_image().save_png(
				base.replace(".png", "_%s.png" % pass_name))
	get_tree().quit()


func _stage() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(34, 26, 44)
	cam.look_at(Vector3(0, 6, 0))
	cam.fov = 52.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-32, 40, 0)
	sun.light_energy = 1.35
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.47, 0.60, 0.72)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.56, 0.60, 0.66)
	e.ambient_light_energy = 0.75
	env.environment = e
	add_child(env)
