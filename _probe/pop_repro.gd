extends Node3D

## Two planes and an angle. That is the whole level.
##
## A straight ramp, one layer of rise every four pixels, which lands at 36.9
## degrees. The ball spawns at the one spot on it where a RESTING ball reads
## density 0.556 -- just over the 0.55 that makes creative.gd do this, every
## frame, from a node that is not the player:
##
##   if terrain.density_at(pos + Vector3(0, 0.2, 0)) > 0.55:
##       player.global_position.y += 1.0
##       player.velocity.y = maxf(player.velocity.y, 0.0)
##
## Lifted a metre, downward velocity deleted, falls back into the same reading,
## fires again. No level generation, no driving, no luck: it starts doing it.
##
## SPACE toggles the rule. Same ramp, same spot, both ways.
## WASD + mouse. R puts you back on the spot. ESC frees the mouse, again quits.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const PlayerScene := preload("res://Player/player.tscn")
const PX := 32
const SAMPLE := 0.2
const TRIP := 0.55
const BALL := 0.41

var player: CharacterBody3D
var terrain: Node3D
var hud: Label
var pops := 0
var flash := 0.0
var armed := true
var spawn_at := Vector3(-18.8, 11.0, 0)
var slope := 0.0
var frames := 0
var found := false
var old_hits := 0          # what the density rule WOULD have done
var use_old := false       # space swaps which rule is live
var bury_shape: SphereShape3D


func _ready() -> void:
	Settings.movement = "default"
	Net.game_settings = {
		"speedScale": 0.7, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0, "monkey": true,
		"infiniteAmmo": true, "slayer": false,
	}
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = Sky.new()
	e.sky.sky_material = ProceduralSkyMaterial.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.75
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -30, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	terrain = VoxelTerrain.new()
	add_child(terrain)
	terrain.configure(PX, PX)
	terrain.deadzone_centers = []
	terrain.build_from_layers(_layers())

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = spawn_at
	player.spawn_position = spawn_at
	var cam: Camera3D = player.get_node_or_null("CameraRig/SpringArm/Camera3D")
	if cam:
		cam.current = true

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(14, 10)
	hud.add_theme_font_size_override("font_size", 18)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)


func _layers() -> Array:
	var w := (PX + 31) >> 5
	var out: Array = []
	for li in 5:
		var rows: Array = []
		rows.resize(PX * w)
		rows.fill(0)
		out.append(rows)
	for pz in PX:
		for px in PX:
			for li in clampi(px / 4, 0, 4) + 1:
				out[li][pz * w + (px >> 5)] |= 1 << (31 - (px & 31))
	return out


## Put the ball where a RESTING ball reads highest, so the repro does not depend
## on anyone driving to the right place.
func _seek_spawn() -> void:
	var space := get_world_3d().direct_space_state
	var best := 0.0
	for i in 120:
		var x := lerpf(-PX * 0.9, PX * 0.9, float(i) / 119.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, 0), Vector3(x, -40, 0))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		var centre: Vector3 = (hit["position"] as Vector3) + n * BALL
		var d: float = terrain.density_at(centre + Vector3(0, SAMPLE, 0))
		if d > best:
			best = d
			spawn_at = centre
			slope = rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
	found = true
	player.global_position = spawn_at
	player.spawn_position = spawn_at
	player.velocity = Vector3.ZERO
	print("[seam] resting ball reads %.3f on a %.1f deg face at %v (trips over %.2f)" % [
		best, slope, spawn_at, TRIP])


## The fix: crossing parity. Walk up counting surface crossings; odd means the
## point started inside the solid. Exact, and independent of normals.
func _is_buried() -> bool:
	var space := get_world_3d().direct_space_state
	var at := player.global_position
	var top := at.y + 80.0
	var crossings := 0
	while at.y < top and crossings < 32:
		var q := PhysicsRayQueryParameters3D.create(at, Vector3(at.x, top, at.z))
		q.hit_back_faces = true
		q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		crossings += 1
		at = (hit["position"] as Vector3) + Vector3(0, 0.02, 0)
	return crossings % 2 == 1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			# Genuinely bury it, to prove the rescue still works.
			player.global_position -= Vector3(0, 1.6, 0)
			player.velocity = Vector3.ZERO
		elif event.keycode == KEY_R:
			player.global_position = spawn_at
			player.velocity = Vector3.ZERO
		elif event.keycode == KEY_SPACE:
			use_old = not use_old
		elif event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				get_tree().quit()


func _physics_process(delta: float) -> void:
	frames += 1
	if frames == 6:
		_seek_spawn()
	if not found:
		return
	var d: float = terrain.density_at(player.global_position + Vector3(0, SAMPLE, 0))
	var buried := _is_buried()
	if d > TRIP:
		old_hits += 1
	if (d > TRIP) if use_old else buried:
		player.global_position.y += 1.0
		player.velocity.y = maxf(player.velocity.y, 0.0)
		pops += 1
		flash = 1.0
	flash = maxf(0.0, flash - delta * 2.5)
	hud.text = "POPS %d      rule %s  [space]\n\nDENSITY %.3f   lifts you over %.2f\nslope here %.1f deg\ny %.2f   vy %+.2f   speed %.1f   %s\n\nWASD move   R back to the spot   ESC out" % [
		pops, "ON" if armed else "off", d, TRIP, slope,
		player.global_position.y, player.velocity.y,
		Vector2(player.velocity.x, player.velocity.z).length(),
		"TOUCHING" if player.touching else "air"]
	hud.add_theme_color_override("font_color", Color(1.0, 1.0 - flash, 1.0 - flash))
	if OS.has_environment("DRIVE"):
		if frames == 60 * 6:
			player.global_position -= Vector3(0, 1.6, 0)   # now genuinely bury it
			player.velocity = Vector3.ZERO
		if frames == 60 * 7:
			print("BURIED TEST: rescued=%s (y %.2f)" % [
				"yes" if player.global_position.y > spawn_at.y - 1.2 else "NO",
				player.global_position.y])
		if frames >= 60 * 12:
			print("RESULT new rule lifted %d times; old rule would have lifted %d, standing still on a %.1f deg face" % [
				pops, old_hits, slope])
			get_tree().quit()
