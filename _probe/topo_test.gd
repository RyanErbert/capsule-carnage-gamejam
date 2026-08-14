extends Node3D

## Drive it yourself, on the ground the game actually builds.
##
## Real surface-nets terrain (Terrain/voxel_terrain.gd) raised into hills, so the
## slopes steepen gradually the way a cliffside does, plus real WFC compounds
## sitting on it. Synthetic ramps never reproduced the jump because they are
## single clean surfaces at 1.4 degrees per facet; this is 5-30 degrees per facet
## with overlapping solids welded into one trimesh, which is the real case.
##
## SLIP is the height a frame gained that the velocity entering it cannot
## account for. Physics cannot produce that number. Only depenetration or a
## direct write to position can, so a run of it names the culprit outright.
##
## The player respawns itself after 10 s of falling, which is a huge teleport and
## is NOT the bug — that is counted separately as RESPAWNS and never as a
## teleport. Getting that wrong is what made the last build of this probe lie.
##
## WASD + mouse, shift sprints, space jumps. R puts you back on the hill.
## TAB resets the counters. F is slow motion. ESC frees the mouse, again quits.

const Wfc := preload("res://Items/wfc.gd")
const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const PlayerScene := preload("res://Player/player.tscn")
const PX := 48                 # painted pixels per side: a 192 m field
const FALL_RESPAWN := 10.0   # mirrors player.gd FALL_RESPAWN_AIRTIME

var player: CharacterBody3D
var terrain: Node3D
var hud: Label
var spawn_at := Vector3(0, 30, 0)
var teleports := 0
var respawns := 0
var worst := 0.0
var recent: Array[float] = []
var flash := 0.0
var frames := 0
var _skip := 0
var _frozen := false
var _prev_air := 0.0
var prev_pos := Vector3.ZERO
var prev_vel := Vector3.ZERO


## Terraced columns per painted pixel; the terrain's own smoothing pass turns the
## steps into continuous slopes, which is where the gradual steepening lives.
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
			var fx := float(px) / float(PX)
			var fz := float(pz) / float(PX)
			var h := 2.1 \
				+ 1.9 * sin(fx * TAU * 1.1) * cos(fz * TAU * 0.9) \
				+ 0.9 * sin(fx * TAU * 2.7 + 1.0) \
				+ 0.6 * cos(fz * TAU * 3.3 + 2.0)
			var top := clampi(int(roundf(h)), 0, 4)
			for li in top + 1:
				var wi := pz * w + (px >> 5)
				out[li][wi] = int(out[li][wi]) | (1 << (31 - (px & 31)))
	return out


func _ready() -> void:
	Net.game_settings = {
		"speedScale": 0.7, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0,
		"monkey": OS.get_environment("MONKEY") != "0",
		"infiniteAmmo": true, "slayer": false,
	}
	Settings.movement = "default"

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = Sky.new()
	e.sky.sky_material = ProceduralSkyMaterial.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -34, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)

	terrain = VoxelTerrain.new()
	add_child(terrain)
	terrain.configure(PX, PX)
	terrain.deadzone_centers = []
	terrain.build_from_layers(_layers())

	# Real compounds standing on the slopes, so the seam between built geometry
	# and terrain is in the test too.
	var style := OS.get_environment("STYLE") if OS.has_environment("STYLE") else "surface"
	var spots := [Vector3(-34, 0, -30), Vector3(30, 0, 26), Vector3(-28, 0, 34)]
	for i in spots.size():
		var c: StaticBody3D = Wfc.build(11 + i * 17, 8, style)
		c.position = spots[i]
		add_child(c)

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = spawn_at
	player.spawn_position = spawn_at
	var cam: Camera3D = player.get_node_or_null("CameraRig/SpringArm/Camera3D")
	if cam:
		cam.current = true

	if OS.has_environment("DRIVE"):
		Input.action_press("ui_up", 1.0)
		Input.action_press("sprint", 1.0)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(14, 10)
	hud.add_theme_font_size_override("font_size", 17)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	prev_pos = player.global_position


func _respawn() -> void:
	player.global_position = spawn_at
	player.velocity = Vector3.ZERO
	_clear_window()


func _clear_window() -> void:
	recent.clear()
	prev_pos = player.global_position
	prev_vel = player.velocity
	_skip = 2


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_respawn()
		elif event.keycode == KEY_TAB:
			teleports = 0
			respawns = 0
			worst = 0.0
		elif event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				get_tree().quit()
		elif event.keycode == KEY_F:
			_frozen = not _frozen
			Engine.time_scale = 0.15 if _frozen else 1.0


func _physics_process(delta: float) -> void:
	var p: Vector3 = player.global_position
	# The player teleports ITSELF home after FALL_RESPAWN_AIRTIME of falling.
	# air_time crossing the limit and resetting is that event exactly, so it is
	# never confused for a physics one.
	var air: float = player.air_time
	if _prev_air > 0.0 and air == 0.0 and _prev_air >= FALL_RESPAWN - 0.05:
		respawns += 1
		_clear_window()
		_prev_air = air
		return
	_prev_air = air

	# Height gained BEYOND what the frame intended. Contact only ever subtracts
	# from intended motion, so rising further than you meant to is the one thing
	# physics cannot do. `actual - intended` was wrong: it reads a landing (meant
	# to drop 0.37 m, ground held it at zero) as 0.37 m of unexplained rise.
	var want := (prev_vel * delta).y
	var slip := maxf(0.0, (p - prev_pos).y - maxf(0.0, want))
	if _skip > 0:
		_skip -= 1
		slip = 0.0
	recent.append(slip)
	if recent.size() > 30:                      # half a second
		recent.remove_at(0)
	var run := 0.0
	for s in recent:
		run += s
	if run > 0.45 and flash <= 0.0:
		teleports += 1
		worst = maxf(worst, run)
		flash = 1.0
	flash = maxf(0.0, flash - delta * 2.0)
	prev_pos = p
	prev_vel = player.velocity

	if OS.has_environment("DRIVE"):
		frames += 1
		if player.camera_rig:
			player.camera_rig.yaw = sin(frames * 0.0035) * 3.0
		if frames >= 60 * 45:
			print("RESULT %d teleports, worst %.2f m unexplained rise (%d fall respawns, not counted)" % [
				teleports, worst, respawns])
			get_tree().quit()

	var faces := ""
	for i in player.get_slide_collision_count():
		var n: Vector3 = player.get_slide_collision(i).get_normal()
		faces += " %.0f" % rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
	hud.text = "TELEPORTS %d   worst %.2f m      respawns %d\n\ny %.2f   slip %+.3f   run %+.3f\nvy %+.2f   speed %.1f\n%s%s  contacts%s\n\nWASD move   shift sprint   space jump\nR respawn   TAB reset   F slow   ESC out" % [
		teleports, worst, respawns, p.y, slip, run, player.velocity.y,
		Vector2(player.velocity.x, player.velocity.z).length(),
		"TOUCH " if player.touching else "air   ",
		"GROUND" if player.grounded else "      ", faces]
	hud.add_theme_color_override("font_color", Color(1.0, 1.0 - flash, 1.0 - flash))
