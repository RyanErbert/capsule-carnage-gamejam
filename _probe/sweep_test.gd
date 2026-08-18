extends Node3D

## Visual probe for the parametric sweep: one wall that turns a corner and
## climbs, one tower (the same wall profile bent onto a ring rail), one bridge
## deck and one pathway. Saves a shot and quits.
##
## Windowed Godot on Windows detaches from the parent console, so this logs to
## PROBE_LOG rather than stdout. Numbers live in sweep_check.gd, which runs
## headless under --script and can print.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")

var _log: FileAccess = null


func _ready() -> void:
	var log_path := OS.get_environment("PROBE_LOG")
	if log_path != "":
		_log = FileAccess.open(log_path, FileAccess.WRITE)
	_say("ready")

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.76, 0.72)
	mat.roughness = 1.0

	_run("wall", Ops.mitre_frames([
		Vector3(-16, 0, -8), Vector3(-4, 0, -8),
		Vector3(2, 1.6, -2), Vector3(2, 2.6, 8),
	]), Profiles.wall(1.0, 6.0, 3.0, 0.22, 0.9), mat, true, false)

	_run("tower", Ops.ring_frames(Vector3(14, 0, -4), 3.6, 14),
		Profiles.wall(1.0, 9.0, 3.0, 0.3, 0.9), mat, false, true)

	_run("deck", Ops.curve_frames([
		Vector3(-16, 5, 10), Vector3(-4, 6, 14), Vector3(8, 6, 11), Vector3(18, 5, 14),
	], {"spacing": 2.0}), Profiles.deck(3.0, 0.6, 0.45), mat, true, false)

	_run("path", Ops.curve_frames([
		Vector3(-16, 0.2, 3), Vector3(-5, 0.2, 6), Vector3(6, 0.6, 3), Vector3(16, 0.4, 6),
	], {"spacing": 1.6}), Profiles.path(2.0), mat, true, false)

	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(-2, 13, 30)
	cam.look_at(Vector3(0, 2.5, 0))
	cam.fov = 55.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-46, -38, 0)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.42, 0.55, 0.68)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.56, 0.62)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)
	_say("scene built")
	_shoot()


func _run(label: String, frames: Array, profile: PackedVector2Array,
		mat: Material, caps: bool, closed: bool) -> void:
	var st: SurfaceTool = Ops.surface()
	var hulls: Array = []
	Ops.sweep(st, frames, profile, hulls, {"caps": caps, "closed": closed})
	var body := StaticBody3D.new()
	add_child(body)
	Ops.attach(body, st, hulls, mat)
	_say("%s frames=%d hulls=%d len=%.1f" % [
		label, frames.size(), hulls.size(), Ops.rail_length(frames)])


func _shoot() -> void:
	var shot := OS.get_environment("PROBE_SHOT")
	for i in 5:
		await RenderingServer.frame_post_draw
	if shot != "":
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(shot)
		_say("shot %s err=%d" % [shot, err])
	_say("quit")
	if _log:
		_log.close()
	get_tree().quit()


func _say(msg: String) -> void:
	print(msg)
	if _log:
		_log.store_line(msg)
		_log.flush()
