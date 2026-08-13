extends Node3D

## Roll flat-out at an abrupt 45 degree face and watch the VELOCITY, not the
## position. A bounce shows up as upward velocity appearing from nowhere:
## vy rising by more than gravity allows, with no jump pressed.

const PlayerScene := preload("res://Player/player.tscn")
const BuildsScript := preload("res://Items/builds.gd")

var player: CharacterBody3D
var frames := 0
var prev_vy := 0.0
var kicks := 0
var biggest := 0.0
var lines: Array[String] = []


func _ready() -> void:
	Net.game_settings = {
		"speedScale": 0.7, "accelScale": 2.5, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0, "monkey": true,
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	var ground := StaticBody3D.new()
	ground.name = "Deck"
	var gcs := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(60, 4, 120)
	gcs.shape = gbox
	ground.add_child(gcs)
	ground.position = Vector3(0, -2, 0)
	add_child(ground)

	# A build-gun ramp is wedge_mesh(4,4,4): exactly 45 degrees, meeting the
	# deck abruptly, which is the case a smooth test curve can never produce.
	var builds := Node3D.new()
	builds.set_script(BuildsScript)
	builds.name = "Builds"
	add_child(builds)
	if OS.get_environment("CASE") == "wall":
		# The thing the bounce is FOR: a kerb you smack into flat out.
		builds._add_build({"id": "w0", "type": "wall", "x": 0.0, "y": 2.0,
			"z": 0.0, "ry": 0.0})
	else:
		for k in 4:
			builds._add_build({"id": "r%d" % k, "type": "ramp",
				"x": 0.0, "y": 2.0 + 4.0 * k, "z": -4.0 * k, "ry": 0.0})

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(0.0, 1.0, 40.0)
	if player.camera_rig:
		player.camera_rig.yaw = 0.0      # forward is -Z, at the ramp
	Input.action_press("ui_up", 1.0)


func _physics_process(delta: float) -> void:
	frames += 1
	var vy: float = player.velocity.y
	# Gravity can only ever LOWER vy. Anything that raises it is a kick.
	var gain := vy - prev_vy
	if gain > 1.0 and frames > 10:
		kicks += 1
		biggest = maxf(biggest, gain)
		if lines.size() < 20:
			lines.append("  KICK f%3d z%7.2f y%6.2f  vy %6.2f -> %6.2f (+%.2f)  |v|%5.1f  %s" % [
				frames, player.global_position.z, player.global_position.y,
				prev_vy, vy, gain, player.velocity.length(),
				"ground" if player.grounded else ("face" if player.touching else "air")])
	prev_vy = vy
	if frames % 30 == 0 and lines.size() < 26:
		lines.append("t%4.1f z%7.2f y%6.2f  |v|%5.1f vy%6.2f  %s" % [
			frames / 60.0, player.global_position.z, player.global_position.y,
			Vector2(player.velocity.x, player.velocity.z).length(), vy,
			"ground" if player.grounded else ("face" if player.touching else "air")])
	if frames >= 60 * 9:
		for s in lines:
			print(s)
		print("RESULT kicks=%d biggest=+%.2f m/s of upward velocity from nowhere" % [
			kicks, biggest])
		get_tree().quit()
