extends Node3D

## Standing still on a gentle slope should be the most boring thing the body can
## do. The log says it leaves the ground 27 times in two seconds there. Sit the
## player on a ramp of ANG degrees, touch no input, and print every frame it is
## not in contact. Resting motion into a surface is gravity alone -- about 5 mm a
## frame -- against a 20 mm safe_margin, so the question is whether contact can
## survive being four times smaller than the gap it is held at.

const PlayerScene := preload("res://Player/player.tscn")

var player: CharacterBody3D
var frames := 0
var lost := 0            # frames not touching
var drops := 0           # ...and how many separate times contact was lost
var was_down := true
var y_min := 1e9
var y_max := -1e9
var trace: Array[String] = []


func _ready() -> void:
	Net.game_settings = {
		"speedScale": 0.7, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0,
		"monkey": OS.get_environment("MONKEY") != "0",
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	var ang := deg_to_rad(float(OS.get_environment("ANG")) if OS.has_environment("ANG") else 14.0)
	# One big quad tilted by ang, built as real triangles so it is the same kind
	# of collider the real world uses (concave, backfaces on).
	var t := tan(ang)
	var tris := PackedVector3Array()
	for q in [[-40.0, -40.0], [-40.0, 0.0], [0.0, -40.0], [0.0, 0.0]]:
		var ox: float = q[0]
		var oz: float = q[1]
		var c := [Vector2(ox, oz), Vector2(ox + 40, oz), Vector2(ox, oz + 40), Vector2(ox + 40, oz + 40)]
		var p := []
		for v in c:
			p.append(Vector3(v.x, v.y * t, v.y))
		tris.append_array([p[0], p[2], p[1], p[1], p[2], p[3]])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.name = "Ramp"
	body.add_child(cs)
	add_child(body)

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(0.0, 1.2, 0.0)
	print("resting on a %.0f degree ramp, monkey=%s" % [
		rad_to_deg(ang), Net.game_settings["monkey"]])


func _physics_process(_delta: float) -> void:
	frames += 1
	if frames < 60:
		return                               # let it settle first
	var p: Vector3 = player.global_position
	y_min = minf(y_min, p.y)
	y_max = maxf(y_max, p.y)
	var n := player.get_slide_collision_count()
	if not player.touching:
		lost += 1
		if was_down:
			drops += 1
		was_down = false
	else:
		was_down = true
	if trace.size() < 90:
		trace.append("%4d t=%d g=%d n=%d y=%.4f vy=%+.3f |v|=%.3f" % [
			frames, int(player.touching), int(player.grounded), n,
			p.y, player.velocity.y, player.velocity.length()])
	if frames >= 60 * 6:
		var run := frames - 60
		print("\n".join(trace))
		print("RESULT not touching %d/%d frames (%.0f%%), %d separate drops, y span %.4f m" % [
			lost, run, 100.0 * lost / run, drops, y_max - y_min])
		get_tree().quit()
