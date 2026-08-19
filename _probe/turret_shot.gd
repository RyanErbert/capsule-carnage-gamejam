extends Node3D

## The gun puppy, shut and gaping. Closed it should read as a rock; open, as a
## rock with a gatling in its mouth. Set PROBE_SHOT; two files land beside it.

const Turrets := preload("res://Items/turrets.gd")

var _hi: Node3D
var _lo: Node3D


func _ready() -> void:
	_stage()
	var host := Node3D.new()
	host.set_script(Turrets)
	add_child(host)
	var t: Node3D = host.call("_make_turret_node", "probe")
	add_child(t)
	t.position = Vector3.ZERO
	# The range ring and the HP bar are not what this shot is about.
	for n in [t.get_node_or_null("HpFill"), t.get_node_or_null("HpBack")]:
		if n:
			(n as Node3D).visible = false
	for c in t.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is ImmediateMesh:
			(c as MeshInstance3D).visible = false
	_hi = t.get_node("Head/Pivot/JawUpper")
	_lo = t.get_node("Head/Pivot/JawLower")
	# The muzzle points -Z, so the camera has to be on that side to see a face.
	(t.get_node("Head") as Node3D).rotation.y = 0.0
	_shoot()


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for pass_name: Array in [["shut", 0.0], ["gaping", 0.5]]:
		_hi.rotation.x = float(pass_name[1])
		_lo.rotation.x = -float(pass_name[1]) * 0.75
		for i in 6:
			await RenderingServer.frame_post_draw
		if base != "":
			get_viewport().get_texture().get_image().save_png(
				base.replace(".png", "_%s.png" % pass_name[0]))
	get_tree().quit()


func _stage() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.70, 0.62, 0.47)
	ground.material_override = gm
	add_child(ground)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(1.9, 1.8, -3.3)
	cam.look_at(Vector3(0, 1.2, 0))
	cam.fov = 45.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-40, 35, 0)
	sun.light_energy = 1.3
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.60, 0.69, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.65, 0.70)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
