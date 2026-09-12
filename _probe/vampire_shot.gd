extends Node3D

## The vampire gun in hand and its beam on a target. Set PROBE_SHOT; two
## frames land beside it: the gun close up, and the beam from behind.

const WeaponRig := preload("res://Items/weapon_rig.gd")
const Beam := preload("res://Items/vampire_beam.gd")

var _cam: Camera3D
var _beam: Node3D
var _gun: Node3D


func _ready() -> void:
	_stage()
	_gun = WeaponRig.build_model("vampire")
	add_child(_gun)
	_gun.position = Vector3(0, 1.2, 0)
	# A stand-in body and target so the beam has something to leave and land on
	_ball(Vector3(0, 1.0, 1.0), Color(0.3, 0.5, 0.9))
	_ball(Vector3(1.5, 1.0, -9.0), Color(0.9, 0.4, 0.3))
	_beam = Beam.new()
	add_child(_beam)
	_shoot()


func _ball(at: Vector3, c: Color) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.39
	sm.height = 0.78
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	sm.material = m
	mi.mesh = sm
	mi.position = at
	add_child(mi)


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	# Frame 1: the gun, filling the frame
	_cam.position = Vector3(1.1, 1.45, -1.3)
	_cam.look_at(Vector3(0, 1.2, -0.2))
	_cam.fov = 35.0
	for i in 6:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_gun.png"))
	# Frame 2: the beam, hot, feeding on the far ball
	_cam.position = Vector3(-1.8, 2.2, 3.4)
	_cam.look_at(Vector3(0.6, 1.0, -4.0))
	_cam.fov = 55.0
	for i in 8:
		_beam.show_beam(Vector3(0.34, 1.31, 0.1), Vector3(1.5, 1.0, -9.0), 0.75, true)
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_beam.png"))
	get_tree().quit()


func _stage() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.42, 0.40)
	ground.material_override = gm
	add_child(ground)
	_cam = Camera3D.new()
	add_child(_cam)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-40, 35, 0)
	sun.light_energy = 1.3
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.17, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.52, 0.6)
	e.ambient_light_energy = 0.9
	e.glow_enabled = true
	e.glow_intensity = 0.6
	e.glow_bloom = 0.2
	env.environment = e
	add_child(env)
