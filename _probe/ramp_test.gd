extends Node3D

## Rolling UP into a steeper face: the inside of a corner, not the outside. The
## ball climbs a shallow ramp and meets a steeper one, and at the crease both
## faces are in contact at once. A quarter pipe is just that transition repeated,
## which is why it fires there every time.
##
## LO is the angle it rolls up, HI the steeper one it meets. MODE=pipe instead
## builds a real quarter pipe out of SEG facets from LO up to HI.
##
## A ball rolling up a pipe should FOLLOW it. Leaving the surface is the bug, so
## the number that matters is how far off the surface it gets.

const PlayerScene := preload("res://Player/player.tscn")

var player: CharacterBody3D
var frames := 0
var lo := 10.0
var hi := 45.0
var seg := 1
var speed := 26.0
var prof: Array[Vector2] = []      # (x, y) of the surface, for height-above
var air_frames := 0
var takeoffs := 0
var was_down := true
var peak_air := 0.0
var rise_total := 0.0
var started := false
var tape: Array[String] = []
var prev_pos := Vector3.ZERO
var prev_vel := Vector3.ZERO
var crease := Vector2.ZERO   # where the two faces meet
var faces_geo: Array = []    # [point on the face, its outward normal]
var top := Vector2.ZERO      # ...and where the ramp runs out


func _ready() -> void:
	Net.game_settings = {
		"speedScale": 1.0, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0,
		"monkey": OS.get_environment("MONKEY") != "0",
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"
	lo = float(OS.get_environment("LO")) if OS.has_environment("LO") else 10.0
	hi = float(OS.get_environment("HI")) if OS.has_environment("HI") else 45.0
	seg = int(OS.get_environment("SEG")) if OS.has_environment("SEG") else 1
	speed = float(OS.get_environment("SPD")) if OS.has_environment("SPD") else 26.0

	# Build the surface as a run of (x, y) points: a long flat approach, then the
	# climb, in `seg` equal angle steps from lo to hi.
	prof.append(Vector2(-90.0, 0.0))
	prof.append(Vector2(-30.0, 0.0))
	var at := Vector2(-30.0, 0.0)
	var run := 26.0 / float(seg)
	for k in seg:
		var t := (float(k) + 1.0) / float(seg)
		var a := deg_to_rad(lerpf(lo, hi, t if seg > 1 else 1.0)) if seg > 1 else deg_to_rad(lo)
		at += Vector2(cos(a), sin(a)) * run
		prof.append(at)
	crease = at
	# ...and for the two-face case the second, steeper face after the crease.
	if seg == 1:
		var a2 := deg_to_rad(hi)
		at += Vector2(cos(a2), sin(a2)) * 40.0
		prof.append(at)

	top = prof[prof.size() - 1]
	for k in prof.size() - 1:
		var d: Vector2 = ((prof[k + 1] as Vector2) - (prof[k] as Vector2)).normalized()
		faces_geo.append([prof[k], Vector2(-d.y, d.x)])
	top = prof[prof.size() - 1]
	var hz := 26.0
	var tris := PackedVector3Array()
	for k in prof.size() - 1:
		var p0: Vector2 = prof[k]
		var p1: Vector2 = prof[k + 1]
		tris.append_array([
			Vector3(p0.x, p0.y, -hz), Vector3(p1.x, p1.y, -hz), Vector3(p0.x, p0.y, hz),
			Vector3(p1.x, p1.y, -hz), Vector3(p1.x, p1.y, hz), Vector3(p0.x, p0.y, hz)])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = OS.get_environment("BACKFACE") != "0"
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.name = "Pipe"
	body.add_child(cs)
	add_child(body)

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(-70.0, 0.6, 0.0)
	if player.camera_rig:
		player.camera_rig.yaw = -PI * 0.5        # forward is +x
	player.velocity = Vector3(speed, 0, 0)
	Input.action_press("ui_up", 1.0)
	Input.action_press("sprint", 1.0)
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


## How far clear of the geometry the ball is, as a PERPENDICULAR distance to the
## faces themselves. Reading a height off the profile by x is meaningless once a
## face approaches vertical -- x stops advancing, so the ball climbing the face
## looks like it is flying away from it. Distance to the plane is exact at any
## angle, which is the whole point.
func _clearance(p: Vector3) -> float:
	var here := Vector2(p.x, p.y)
	var best := 1e9
	for f in faces_geo:
		var d: float = (here - (f[0] as Vector2)).dot(f[1] as Vector2)
		best = minf(best, d)
	return best - 0.41


func _physics_process(delta: float) -> void:
	frames += 1
	var p: Vector3 = player.global_position
	var want := (prev_vel * delta).y
	var rise := maxf(0.0, (p - prev_pos).y - maxf(0.0, want))
	# Judge ONLY around the crease. Past the top of the ramp the ball is a
	# projectile and "height above the surface" grows on its own, which reads as
	# a launch when nothing happened -- the same false positive that has already
	# cost this hunt three wrong answers.
	# One crease: look around it. A whole pipe: look along ALL of it -- anchoring
	# the window at the last facet would be watching the wrong place and calling
	# the silence a pass.
	started = (absf(p.x - crease.x) < 6.0 if seg == 1 else p.x > -30.0) 		and p.x < top.x - 1.0
	if started:
		rise_total += rise
		var above := _clearance(p)
		if not player.touching:
			air_frames += 1
			peak_air = maxf(peak_air, above)
			if was_down:
				takeoffs += 1
			was_down = false
		else:
			was_down = true
		if tape.size() < 34 and (rise > 0.004 or above > 0.12):
			var faces := ""
			for i in player.get_slide_collision_count():
				var n: Vector3 = player.get_slide_collision(i).get_normal()
				faces += " %.0f" % rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
			tape.append("  %4d x%8.3f above%7.3f rise%+7.4f vy%+7.3f |v|%6.2f %s n%d%s" % [
				frames, p.x, above, rise, player.velocity.y, player.velocity.length(),
				"T" if player.touching else "-", player.get_slide_collision_count(), faces])
	prev_pos = p
	prev_vel = player.velocity

	if frames >= 60 * 7:
		var verdict := "follows"
		if peak_air > 0.35:
			verdict = "LAUNCHES"
		print("LO %4.1f HI %4.1f seg %2d | at the crease: peak %6.3f m off the face | %2d takeoffs | air %3d f | rise %6.3f | %s" % [
			lo, hi, seg, peak_air, takeoffs, air_frames, rise_total, verdict])
		if OS.has_environment("TAPE"):
			for t in tape:
				print(t)
		get_tree().quit()
