extends Node3D

## Headless check that the rebuilt castle still builds: a bent wall, a gate, a
## wall with punched holes, and a tower. Counts triangles, collision shapes and
## open edges (an open edge is a hole in the solid).
## Runs as a scene, not --script, because castle.gd touches the Net autoload.

const Castle := preload("res://Items/castle.gd")

var _log: FileAccess = null


func _ready() -> void:
	var lp := OS.get_environment("PROBE_LOG")
	if lp != "":
		_log = FileAccess.open(lp, FileAccess.WRITE)
	_say("ready")
	var node: Node3D = Castle.new()
	add_child(node)
	_check("wall", node, [Vector3(-26, 0, -6), Vector3(-8, 0, -6), Vector3(-2, 2, 2)], false, [])
	_check("gate", node, [Vector3(-24, 0, 10), Vector3(0, 0, 10)], true, [])
	_check("holed", node, [Vector3(4, 0, 10), Vector3(28, 0, 10)], false,
		[Vector3(10, 2, 10), Vector3(22, 2, 10)])
	_check("hairpin", node, [Vector3(6, 0, -14), Vector3(24, 0, -14), Vector3(7, 0, -11)], false, [])
	var body := StaticBody3D.new()
	node.add_child(body)
	node.call("_build_tower", body, Vector3(-16, 0, -16), 9.0, Castle.stone_material(), true)
	_report("tower", body)
	_say("done")
	_shoot()


## Windowed run: light the scene, frame it and save a shot.
func _shoot() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(-6, 20, 44)
	cam.look_at(Vector3(0, 3, 2))
	cam.fov = 55.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-44, -36, 0)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.42, 0.55, 0.68)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.56, 0.62)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)
	var shot := OS.get_environment("PROBE_SHOT")
	for i in 5:
		await RenderingServer.frame_post_draw
	if shot != "":
		_say("shot err=%d" % get_viewport().get_texture().get_image().save_png(shot))
	if _log:
		_log.close()
	get_tree().quit()


func _say(msg: String) -> void:
	print(msg)
	if _log:
		_log.store_line(msg)
		_log.flush()


func _check(label: String, node: Node3D, pts: Array, arch: bool, holes: Array) -> void:
	var body := StaticBody3D.new()
	node.add_child(body)
	node.call("_build_run", body, pts, arch, Castle.stone_material(), 6.0, holes, true)
	_report(label, body)


func _report(label: String, body: StaticBody3D) -> void:
	var mi: MeshInstance3D = null
	var shapes := 0
	for c in body.get_children():
		if c is MeshInstance3D:
			mi = c
		elif c is CollisionShape3D:
			shapes += 1
	if mi == null:
		_say("[%s] EMPTY" % label)
		return
	var arrays: Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_say("[%s] nodes=%d tris=%d shapes=%d open_edges=%d" % [
		label, body.get_child_count(), idx.size() / 3, shapes, _open(verts, idx)])


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
