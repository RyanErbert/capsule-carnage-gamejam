extends Node3D

## The Fortwars barriers over a fake two-team board, seen from a low angle so
## the grid and the height fade read. Set PROBE_SHOT.

const Creative := preload("res://Scenes/creative.gd")

var _cam: Camera3D


func _ready() -> void:
	_stage()
	# A 24x24 board: red on the west, blue on the east, a jagged border, a
	# free pocket in the middle
	var w := 24
	var h := 24
	var own := ""
	for r in h:
		for c in w:
			var split := 12 + int(3.0 * sin(r * 0.7))
			var o := 0 if c < split else 1
			if absi(r - 12) < 2 and absi(c - 12) < 2:
				o = -1
			own += String.chr(50 + o)
	# Drive the real builder on a bare creative node (nothing else in _ready
	# is wanted here, so the node is never added through the normal flow)
	var scene := Node3D.new()
	scene.set_script(Creative)
	scene.set_process(false)
	add_child(scene)
	# The map creator's 2D layer comes up with the node; this shot is the world
	var layer: Variant = scene.get("_editor_layer")
	if layer is CanvasLayer:
		(layer as CanvasLayer).visible = false
	scene.set("_playing", true)
	scene.call("_apply_fort", {"phase": "build", "own": own, "gs": [w, h], "teams": {}, "score": {}})
	scene.call("_apply_fort", {"phase": "battle", "own": own, "gs": [w, h], "teams": {}, "score": {},
		"zone": {"x": 2.0, "y": 1.0, "z": 2.0, "r": 6.0}})
	# Keep the barriers up for the shot as well: rebuild them under the zone
	scene.set("_fort_phase", "")
	scene.call("_apply_fort", {"phase": "build", "own": own, "gs": [w, h], "teams": {}, "score": {}})
	_shoot()


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	_cam.position = Vector3(-22.0, 9.0, 44.0)
	_cam.look_at(Vector3(4.0, 6.0, 0.0))
	_cam.fov = 60.0
	for i in 8:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base)
	get_tree().quit()


func _stage() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(120, 120)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.38, 0.33)
	ground.material_override = gm
	ground.position.y = 1.0
	add_child(ground)
	_cam = Camera3D.new()
	add_child(_cam)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_energy = 1.2
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.65, 0.78)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.62, 0.7)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
