extends Node3D

## Ryan's screenshot: a tall wall with a dark sheet hanging inside the arch and
## bars adrift at the top. This builds the case that produces it -- several holes
## punched close together, which is what you do when you want one wide opening --
## and renders it from underneath, where he was standing.

const Registry := preload("res://Items/parametric/registry.gd")
const Ops := preload("res://Items/parametric/ops.gd")

var _wall: Node3D


func _ready() -> void:
	_stage()
	_report()
	_shoot()


func _record() -> Dictionary:
	# Four holes at head height, two metres apart. Each carves a GATE_W (4 m)
	# stretch, so every one of them overlaps its neighbours.
	var holes: Array = []
	for i in 4:
		holes.append(Vector3(-3.0 + float(i) * 2.0, 7.0, 0.0))
	return {
		"type": "wall",
		"nodes": Registry.to_wire([Vector3(-22, 0, 0), Vector3(22, 0, 0)]),
		"holes": Registry.to_wire(holes),
		"params": {"height": 16.0, "thickness": 2.4, "batter": 0.22, "coping": 0.9,
			"tooth": 1.1, "chamfer": 0.18, "arch": 0.7, "gate": 0.0},
	}


## Coincident triangles are the tell: geometry swept twice over the same stretch
## lands on itself, and that is what reads as a sheet hanging in the opening.
func _report() -> void:
	var body: Node3D = Registry.build(_record(), null, false)
	var mesh: ArrayMesh = null
	for c in body.get_children():
		if c is MeshInstance3D:
			mesh = (c as MeshInstance3D).mesh as ArrayMesh
	if mesh == null:
		print("no mesh")
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var seen := {}
	var dupes := 0
	var i := 0
	while i + 2 < idx.size():
		var key: Array = []
		for k in 3:
			key.append(verts[idx[i + k]].snapped(Vector3(0.01, 0.01, 0.01)))
		key.sort()
		var s := str(key)
		if seen.has(s):
			dupes += 1
		else:
			seen[s] = true
		i += 3
	print("triangles %d, coincident duplicates %d" % [idx.size() / 3, dupes])


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	_wall = Registry.build(_record(), Registry.stone(), false)
	add_child(_wall)
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for i in 8:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base)
	get_tree().quit()


func _stage() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(300, 300)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.72, 0.63, 0.47)
	ground.material_override = gm
	add_child(ground)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(9, 2.2, 17)
	cam.look_at(Vector3(-1, 9, 0))
	cam.fov = 62.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-38, 34, 0)
	sun.light_energy = 1.2
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.71, 0.80)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.60, 0.63, 0.68)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
