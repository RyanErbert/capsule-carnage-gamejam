extends Node3D

## The log's every bounce=0.42 event had a SHALLOW floor face in contact
## alongside the steep one. If the restitution picked for the wall is handed to
## the floor as well, the throw comes off the ground pointing up, and you land
## and it happens again. Run flat into a wall while standing on a gentle floor
## and watch which way the body leaves: back down the floor is a wall bounce,
## upward is the ground going trampoline.

const PlayerScene := preload("res://Player/player.tscn")

var player: CharacterBody3D
var frames := 0
var peak_up := 0.0       # best upward velocity seen after the impact
var peak_air := 0.0      # ...and how high it actually got
var takeoffs := 0
var was_down := true
var hit_at := 0
var floor_t := 0.0
var max_z := -1e9


func _ready() -> void:
	Net.game_settings = {
		"speedScale": 1.0, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0, "monkey": true,
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	var ang := deg_to_rad(float(OS.get_environment("ANG")) if OS.has_environment("ANG") else 27.0)
	floor_t = -tan(ang)          # downhill toward the wall, so it arrives fast
	var tris := PackedVector3Array()
	# A floor tilted `ang` about X, running -40..24 in Z.
	for k in range(-40, 24, 2):
		var a := float(k)
		var b := float(k + 2)
		tris.append_array([
			Vector3(-25, a * floor_t, a), Vector3(-25, b * floor_t, b), Vector3(25, a * floor_t, a),
			Vector3(25, a * floor_t, a), Vector3(-25, b * floor_t, b), Vector3(25, b * floor_t, b)])
	# ...and a wall standing on the end of it, steep enough to earn a bounce.
	var wy := 24.0 * floor_t
	tris.append_array([
		Vector3(-25, wy, 24), Vector3(-25, wy + 30, 24), Vector3(25, wy, 24),
		Vector3(25, wy, 24), Vector3(-25, wy + 30, 24), Vector3(25, wy + 30, 24)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.name = "FloorAndWall"
	body.add_child(cs)
	add_child(body)

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(0.0, -40.0 * floor_t + 1.5, -40.0)
	if player.camera_rig:
		player.camera_rig.yaw = PI          # forward is +Z, into the wall
	Input.action_press("ui_up", 1.0)
	Input.action_press("sprint", 1.0)


func _physics_process(_delta: float) -> void:
	frames += 1
	var p: Vector3 = player.global_position
	var up: float = player.velocity.y
	# Only start judging once it is close enough to be in the wall's business.
	if p.z > 14.0:
		if hit_at == 0:
			hit_at = frames
		peak_up = maxf(peak_up, up)
		peak_air = maxf(peak_air, p.y - (minf(p.z, 24.0) * floor_t))
		if not player.touching:
			if was_down:
				takeoffs += 1
			was_down = false
		else:
			was_down = true
	max_z = maxf(max_z, p.z)
	if frames >= 60 * 10:
		print("RESULT best upward velocity %.2f m/s, peak %.2f m above the floor, %d takeoffs (max z=%.1f, wall at 24, %s)" % [
			peak_up, peak_air, takeoffs, max_z,
			"THROUGH THE WALL" if max_z > 24.5 else "held"])
		get_tree().quit()
