extends Node3D

## The case the smooth test curves could never show: real ground is faceted,
## and at monkey-ball speed every seam is a little ramp. Run flat out along an
## undulating deck and count how much of the time is spent in the air, and how
## high above the surface it gets. A ball rolling over bumps should stay on them.

const PlayerScene := preload("res://Player/player.tscn")

var player: CharacterBody3D
var frames := 0
var air_frames := 0
var takeoffs := 0
var was_down := true
var peak_air := 0.0
var top_speed := 0.0


func _ready() -> void:
	Net.game_settings = {
		"speedScale": float(OS.get_environment("SPD")) if OS.has_environment("SPD") else 0.7,
		"accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0, "monkey": true,
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	# 400 m of deck with 2 m facets and gentle undulation: face angles land in
	# the 5-30 degree band the real log complained about.
	var prof: Array[Vector2] = []
	var z := -60.0
	var i := 0
	while z < 400.0:
		var h := sin(z * 0.21) * 0.35 + sin(z * 0.07 + 1.3) * 0.9 + sin(z * 0.53) * 0.15
		prof.append(Vector2(z, h))
		z += 2.0
		i += 1
	var tris := PackedVector3Array()
	for k in prof.size() - 1:
		var a: Vector2 = prof[k]
		var b: Vector2 = prof[k + 1]
		tris.append_array([
			Vector3(-30, a.y, a.x), Vector3(-30, b.y, b.x), Vector3(30, a.y, a.x),
			Vector3(30, a.y, a.x), Vector3(-30, b.y, b.x), Vector3(30, b.y, b.x)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.name = "Undulating"
	body.add_child(cs)
	add_child(body)

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(0.0, 3.0, -55.0)
	if player.camera_rig:
		player.camera_rig.yaw = PI          # forward is +Z
	Input.action_press("ui_up", 1.0)
	if OS.get_environment("SPRINT") != "0":
		Input.action_press("sprint", 1.0)


func _surface_at(z: float) -> float:
	return sin(z * 0.21) * 0.35 + sin(z * 0.07 + 1.3) * 0.9 + sin(z * 0.53) * 0.15


func _physics_process(_delta: float) -> void:
	frames += 1
	if frames < 90:
		return                              # let it settle onto the deck first
	var p: Vector3 = player.global_position
	top_speed = maxf(top_speed, Vector2(player.velocity.x, player.velocity.z).length())
	var above := p.y - 0.41 - _surface_at(p.z)
	if not player.touching:
		air_frames += 1
		peak_air = maxf(peak_air, above)
		if was_down:
			takeoffs += 1
		was_down = false
	else:
		was_down = true
	if frames >= 60 * 12:
		var run := frames - 90
		print("RESULT airborne %d/%d frames (%.0f%%), %d takeoffs, peak %.2f m above the deck, top %.1f m/s" % [
			air_frames, run, 100.0 * air_frames / run, takeoffs, peak_air, top_speed])
		get_tree().quit()
