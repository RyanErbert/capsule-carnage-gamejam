extends Node3D

## The ball sits still, right on the lip where a flat deck ends, with a face
## dropping away underneath it. Two surfaces in contact at once, and the solver
## has to satisfy both. ANG is how far below horizontal that lower face runs:
## 90 is a sheer drop straight down from the lip, 45 a slope away from it.
##
## Nothing is pressed. A ball resting on an edge should stay there, or roll off
## once, and then be still. Anything else is the bug.
##
## RISE is height gained beyond what the frame intended, which contact can never
## produce -- it only ever subtracts from intended motion.

const PlayerScene := preload("res://Player/player.tscn")

var player: CharacterBody3D
var frames := 0
var settle := 45
var rise_total := 0.0
var rise_worst := 0.0
var flips := 0             # times contact came and went
var was_touch := false
var y_lo := 1e9
var y_hi := -1e9
var prev_pos := Vector3.ZERO
var prev_vel := Vector3.ZERO
var tape: Array[String] = []
var ang := 90.0
var over := 0.0


func _ready() -> void:
	Net.game_settings = {
		"speedScale": 0.7, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0,
		"monkey": OS.get_environment("MONKEY") != "0",
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	ang = float(OS.get_environment("ANG")) if OS.has_environment("ANG") else 90.0
	# How far the ball's centre sits PAST the lip, out over the drop.
	over = float(OS.get_environment("OVER")) if OS.has_environment("OVER") else 0.0
	var back := OS.get_environment("BACKFACE") != "0"

	var hz := 30.0
	var deck := 40.0
	var drop := 40.0
	var a := deg_to_rad(ang)
	var far := Vector3(-cos(a) * drop, -sin(a) * drop, 0.0)
	var tris := PackedVector3Array()
	# The deck, running +x away from the lip at y = 0.
	tris.append_array([
		Vector3(0, 0, -hz), Vector3(deck, 0, -hz), Vector3(0, 0, hz),
		Vector3(deck, 0, hz), Vector3(0, 0, hz), Vector3(deck, 0, -hz)])
	# ...and the face falling away from that same lip.
	tris.append_array([
		Vector3(0, 0, -hz), Vector3(0, 0, hz), far + Vector3(0, 0, -hz),
		far + Vector3(0, 0, hz), far + Vector3(0, 0, -hz), Vector3(0, 0, hz)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = back
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.name = "Lip"
	body.add_child(cs)
	add_child(body)

	player = PlayerScene.instantiate()
	add_child(player)
	# Just above the deck, `over` metres out past the lip.
	player.global_position = Vector3(-over, 0.6, 0.0)
	prev_pos = player.global_position

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = Sky.new()
	e.sky.sky_material = ProceduralSkyMaterial.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var cam: Camera3D = player.get_node_or_null("CameraRig/SpringArm/Camera3D")
	if cam:
		cam.current = true


func _physics_process(delta: float) -> void:
	frames += 1
	var p: Vector3 = player.global_position
	var want := (prev_vel * delta).y
	var rise := maxf(0.0, (p - prev_pos).y - maxf(0.0, want))
	if frames > settle:
		rise_total += rise
		rise_worst = maxf(rise_worst, rise)
		y_lo = minf(y_lo, p.y)
		y_hi = maxf(y_hi, p.y)
		if player.touching != was_touch:
			flips += 1
			was_touch = player.touching
		if tape.size() < 40 and (rise > 0.002 or absf(player.velocity.y) > 0.5):
			var faces := ""
			for i in player.get_slide_collision_count():
				var n: Vector3 = player.get_slide_collision(i).get_normal()
				faces += " %.0f" % rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
			tape.append("  %4d y%8.4f x%8.4f rise%+7.4f vy%+7.3f %s n%d%s" % [
				frames, p.y, p.x, rise, player.velocity.y,
				"T" if player.touching else "-", player.get_slide_collision_count(), faces])
	prev_pos = p
	prev_vel = player.velocity

	if frames >= 60 * 6:
		var verdict := "still"
		if rise_total > 0.25 or flips > 6:
			verdict = "JUMPING"
		print("ANG %5.1f over %.2f | rise total %6.3f worst %6.4f | contact flips %3d | y span %6.3f | %s" % [
			ang, over, rise_total, rise_worst, flips, maxf(0.0, y_hi - y_lo), verdict])
		if OS.has_environment("TAPE"):
			for t in tape:
				print(t)
		get_tree().quit()
