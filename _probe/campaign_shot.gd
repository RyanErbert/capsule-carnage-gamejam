extends Node3D

## The campaign greybox, two frames: the plaza from the player's arrival, and
## the whole layout from above. Set PROBE_SHOT. Runs the real scene, so the
## NPCs, crates, board and checkpoints are the real ones (no server: the
## sheet stays empty, which is fine for a picture).

var _scene: Node3D
var _cam: Camera3D


func _ready() -> void:
	_scene = load("res://Scenes/campaign.tscn").instantiate()
	add_child(_scene)
	_cam = Camera3D.new()
	add_child(_cam)
	_shoot()


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for i in 10:
		await RenderingServer.frame_post_draw
	# Frame 1: what the player's own camera sees on arrival
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_arrive.png"))
	# Frame 2: the layout from above and behind the plaza
	_cam.position = Vector3(30.0, 46.0, 70.0)
	_cam.look_at(Vector3(35.0, 2.0, -20.0))
	_cam.fov = 62.0
	_cam.current = true
	for i in 6:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_overview.png"))
	# Frame 3: the shop and the merchant up close
	_cam.position = Vector3(-10.0, 3.2, 12.0)
	_cam.look_at(Vector3(-17.0, 1.2, 4.0))
	_cam.fov = 50.0
	for i in 6:
		await RenderingServer.frame_post_draw
	if base != "":
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_shop.png"))
	get_tree().quit()
