extends Node3D

## Eyeball the sections: a gateway, an arched window, a flat lintel and a bare
## wall in a row, lit and framed. The numbers live in opening_check; this is for
## the half of "does it look right" that a triangle count cannot answer.
## Set PROBE_SHOT to a png path. Windowed, because headless never draws.

const Registry := preload("res://Items/parametric/registry.gd")


func _ready() -> void:
	var mat := Registry.stone()
	# gateway, arched window, flat lintel, plain -- left to right
	_wall(mat, Vector3(-36, 0, 0), 1.0, 0.7, [])
	_wall(mat, Vector3(-12, 0, 0), 0.0, 0.7, [Vector3(-12, 5, 0)])
	_wall(mat, Vector3(12, 0, 0), 0.0, 0.0, [Vector3(12, 5, 0)])
	_wall(mat, Vector3(36, 0, 0), 0.0, 0.0, [])
	_stage()


func _wall(mat: Material, at: Vector3, gate: float, arch: float, holes: Array) -> void:
	var rec := {
		"type": "wall",
		"nodes": Registry.to_wire([at + Vector3(-11, 0, 0), at + Vector3(11, 0, 0)]),
		"holes": Registry.to_wire(holes),
		"params": {"height": 9.0, "thickness": 2.0, "batter": 0.22, "coping": 0.9,
			"tooth": 1.1, "chamfer": 0.18, "arch": arch, "gate": gate},
	}
	var built: Node3D = Registry.build(rec, mat, false)
	if built:
		add_child(built)


func _stage() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 13, 74)
	cam.look_at(Vector3(0, 4.5, 0))
	cam.fov = 58.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-38, 34, 0)
	sun.light_energy = 1.15
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.44, 0.57, 0.70)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.59, 0.66)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for i in 5:
		await RenderingServer.frame_post_draw
	var shot := OS.get_environment("PROBE_SHOT")
	if shot != "":
		get_viewport().get_texture().get_image().save_png(shot)
	get_tree().quit()
