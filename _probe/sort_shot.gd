extends Node3D

## Eyeball the death sort. Renders the same scene at three strengths, so the
## shader is proved to compile on the real renderer AND the look can be judged.
## Set PROBE_SHOT to a png path; three files land beside it, suffixed by
## strength. Windowed, because headless never draws.

const Registry := preload("res://Items/parametric/registry.gd")
const SPAN := 4.0            # a respawn countdown
const AT := [0.15, 2.6, 3.3, 3.9]   # seconds into it to capture

var _fx: Node


func _ready() -> void:
	var mat := Registry.stone()
	for i in 3:
		var at := Vector3(-26 + 26 * i, 0, 0)
		_wall(mat, at, 1.0 if i == 1 else 0.0, 0.7, [] if i == 1 else [at + Vector3(0, 5, 0)])
	_stage()
	_fx = Node.new()
	_fx.set_script(load("res://UI/screen_fx.gd"))
	add_child(_fx)
	_shoot()


func _wall(mat: Material, at: Vector3, gate: float, arch: float, holes: Array) -> void:
	var built: Node3D = Registry.build({
		"type": "wall",
		"nodes": Registry.to_wire([at + Vector3(-11, 0, 0), at + Vector3(11, 0, 0)]),
		"holes": Registry.to_wire(holes),
		"params": {"height": 9.0, "thickness": 2.0, "batter": 0.22, "coping": 0.9,
			"tooth": 1.1, "chamfer": 0.18, "arch": arch, "gate": gate},
	}, mat, false)
	if built:
		add_child(built)


## Runs the REAL death timeline rather than poking the shader, so what lands in
## the png is what a player sees: the sort on top, the mosh held up under it.
func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	_fx.call("death", SPAN)
	var shot := 0
	var elapsed := 0.0
	while shot < AT.size():
		await RenderingServer.frame_post_draw
		elapsed += get_process_delta_time()
		if elapsed < float(AT[shot]):
			continue
		if base != "":
			get_viewport().get_texture().get_image().save_png(base.replace(".png",
				"_%02d.png" % int(float(_fx.call("sort_amount")) * 100.0)))
		shot += 1
	get_tree().quit()


func _stage() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 11, 56)
	cam.look_at(Vector3(0, 4.5, 0))
	cam.fov = 58.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-38, 34, 0)
	sun.light_energy = 1.6
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.44, 0.57, 0.70)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.59, 0.66)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
