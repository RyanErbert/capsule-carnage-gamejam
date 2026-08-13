extends Node3D

## Headless rig for the ground handling. TEST=cliff|hill|lip|arcade.
## ACCEL scales the accel slider, MONKEY=0 runs the arcade movement instead.

const PlayerScene := preload("res://Player/player.tscn")

var player: CharacterBody3D
var mode := "cliff"
var frames := 0
var start_z := -42.0
var peak := -999.0
var top_speed := 0.0
var prev_vy := 0.0
var throws := 0
var biggest_throw := 0.0
var crossings := 0
var rising := false
var samples: Array[String] = []


func _ready() -> void:
	mode = OS.get_environment("TEST")
	if mode == "":
		mode = "cliff"
	Net.game_settings = {
		"speedScale": 0.7,
		"accelScale": float(OS.get_environment("ACCEL")) if OS.has_environment("ACCEL") else 1.0,
		"turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0,
		"monkey": OS.get_environment("MONKEY") != "0" and mode != "arcade",
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	match mode:
		"cliff":
			_strip(_curve(12.0, 85.0))
		"lip":
			_strip(_curve(12.0, 50.0))
		"hill":
			var prof := _curve(9.0, 65.0)
			var crest: Vector2 = prof[prof.size() - 1]
			for i in range(1, 31):
				var a := deg_to_rad(65.0) * (1.0 - float(i) / 30.0)
				prof.append(crest + Vector2(
					9.0 * (sin(deg_to_rad(65.0)) - sin(a)), 9.0 * (cos(a) - cos(deg_to_rad(65.0)))))
			prof.append(prof[prof.size() - 1] + Vector2(60.0, 0.0))
			_strip(prof)
		"arcade":
			_strip([Vector2(start_z, 0.0), Vector2(0.0, 0.0),
				Vector2(240.0, -240.0 * tan(deg_to_rad(25.0)))])

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(0.0, 1.2, start_z)
	if player.camera_rig:
		player.camera_rig.yaw = PI          # forward is +Z
	Input.action_press("ui_up", 1.0)


func _strip(prof: Array) -> void:
	var w := 24.0
	var tris := PackedVector3Array()
	for i in prof.size() - 1:
		var a: Vector2 = prof[i]
		var b: Vector2 = prof[i + 1]
		tris.append_array([
			Vector3(-w, a.y, a.x), Vector3(-w, b.y, b.x), Vector3(w, a.y, a.x),
			Vector3(w, a.y, a.x), Vector3(-w, b.y, b.x), Vector3(w, b.y, b.x)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.add_child(cs)
	add_child(body)


## A flat run-up, then a circular fillet sweeping from level to `cut` degrees.
## dy/dz at parameter a is exactly tan(a), so the slope angle IS a.
func _curve(radius: float, cut: float) -> Array:
	var prof: Array[Vector2] = [Vector2(start_z - 4.0, 0.0), Vector2(0.0, 0.0)]
	for i in range(1, 61):
		var a := deg_to_rad(cut) * float(i) / 60.0
		prof.append(Vector2(radius * sin(a), radius * (1.0 - cos(a))))
	return prof


func _physics_process(_delta: float) -> void:
	if player == null:
		return
	frames += 1
	var p: Vector3 = player.global_position
	var v: Vector3 = player.velocity
	peak = maxf(peak, p.y)
	top_speed = maxf(top_speed, Vector2(v.x, v.z).length())
	var jump := v.y - prev_vy
	if jump > 5.0:
		throws += 1
		biggest_throw = maxf(biggest_throw, jump)
		samples.append("  THROW t%4.1f z%7.2f y%7.2f  +%.2f m/s" % [frames / 60.0, p.z, p.y, jump])
	if v.y > 0.5 and not rising:
		rising = true
	elif v.y < -0.5 and rising:
		rising = false
		crossings += 1
	prev_vy = v.y
	if frames % 30 == 0:
		samples.append("t%4.1f z%7.2f y%7.2f  h%6.2f vy%7.2f  %s" % [
			frames / 60.0, p.z, p.y, Vector2(v.x, v.z).length(), v.y,
			"ground" if player.grounded else ("face" if player.touching else "air")])
	if frames >= 60 * 14:
		for s in samples:
			print(s)
		print("RESULT mode=%s peak=%.2f top_speed=%.2f throws=%d biggest_throw=%.2f arcs=%d" % [
			mode, peak, top_speed, throws, biggest_throw, crossings])
		get_tree().quit()
