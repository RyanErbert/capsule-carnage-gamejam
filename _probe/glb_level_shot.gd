extends Node3D

## A maps/ level as the game loads it: the spawn view and an overview. Run with
## FRIENDSLOP_LEVEL=glb:<name> and PROBE_SHOT set; point FRIENDSLOP_SERVER at
## a dead port so nothing reaches the live server.

var _scene: Node3D
var _cam: Camera3D


func _ready() -> void:
	_scene = load("res://Scenes/glb_level.tscn").instantiate()
	add_child(_scene)
	_cam = Camera3D.new()
	add_child(_cam)
	_shoot()


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for i in 12:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_spawn.png"))
	_cam.position = Vector3(-70.0, 62.0, 95.0)
	_cam.look_at(Vector3(0.0, 4.0, 0.0))
	_cam.fov = 60.0
	_cam.current = true
	for i in 6:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_overview.png"))
	# Count what the loader found
	var spawns: Array = _scene.get("_spawns")
	var peds: Array = _scene.get("_pedestal_marks")
	var bodies := 0
	for n in _all(_scene.get_node("World")):
		if n is StaticBody3D:
			bodies += 1
	print("PROBE spawns=%d pedestals=%d static_bodies=%d" % [spawns.size(), peds.size(), bodies])
	get_tree().quit()


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
