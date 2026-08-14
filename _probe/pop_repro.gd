extends Node3D

## The jump, reproduced. It is not physics.
##
## Scenes/creative.gd runs this every frame, from a node that is NOT the player:
##
##   if terrain.density_at(player.global_position + Vector3(0, 0.2, 0)) > 0.55:
##       player.global_position.y += 1.0
##       player.velocity.y = maxf(player.velocity.y, 0.0)
##
## A safety hatch for remote FILL strokes burying you. But density_at samples a
## 2 m voxel lattice and interpolates, so on a steep face the point 0.2 m above
## your centre reads solid while you are standing perfectly well on the surface.
## It then lifts you exactly one metre and deletes your downward velocity. You
## fall back into the same reading and it fires again. Forever.
##
## DENSITY is that sample, live. Over 0.55 and the pop fires: the screen flashes
## and POPS counts up. Watch the number cross the line as you climb a slope.
##
## SPACE toggles the rule off and on, so the same slope can be ridden both ways.
## WASD + mouse. R respawns. ESC frees the mouse, again quits.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const PlayerScene := preload("res://Player/player.tscn")
const PX := 40
const SAMPLE := 0.2       # creative.gd's probe height above the player origin
const TRIP := 0.55        # ...and the density it calls "buried"

var player: CharacterBody3D
var terrain: Node3D
var hud: Label
var pops := 0
var flash := 0.0
var armed := true
var spawn_at := Vector3(0, 26, 0)


func _ready() -> void:
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

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = spawn_at
	player.spawn_position = spawn_at
	var cam: Camera3D = player.get_node_or_null("CameraRig/SpringArm/Camera3D")
	if cam:
		cam.current = true

	if OS.has_environment("DRIVE"):
		Input.action_press("ui_up", 1.0)

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
			var fx := float(px) / float(PX)
			var fz := float(pz) / float(PX)
			var h := 2.1 + 1.9 * sin(fx * TAU * 1.1) * cos(fz * TAU * 0.9) \
				+ 0.9 * sin(fx * TAU * 2.7 + 1.0) + 0.6 * cos(fz * TAU * 3.3 + 2.0)
			for li in clampi(int(roundf(h)), 0, 4) + 1:
				out[li][pz * w + (px >> 5)] |= 1 << (31 - (px & 31))
	return out


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			player.global_position = spawn_at
			player.velocity = Vector3.ZERO
		elif event.keycode == KEY_SPACE:
			armed = not armed
		elif event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				get_tree().quit()


var frames := 0
var on_ground_pops := 0        # fired while STANDING on the surface, not buried
var worst_d := 0.0

func _physics_process(delta: float) -> void:
	var d: float = terrain.density_at(player.global_position + Vector3(0, SAMPLE, 0))
	if OS.has_environment("DRIVE"):
		frames += 1
		if player.camera_rig:
			player.camera_rig.yaw = sin(frames * 0.0037) * 3.0
		if armed and d > TRIP and player.touching:
			on_ground_pops += 1
			worst_d = maxf(worst_d, d)
		if frames >= 60 * 60:
			print("RESULT %d pops, %d of them while TOUCHING the surface (worst density %.3f)" % [
				pops, on_ground_pops, worst_d])
			get_tree().quit()
	# creative.gd's rule, verbatim.
	if armed and d > TRIP:
		player.global_position.y += 1.0
		player.velocity.y = maxf(player.velocity.y, 0.0)
		pops += 1
		flash = 1.0
	flash = maxf(0.0, flash - delta * 2.5)
	hud.text = "POPS %d      rule %s  [space]\n\nDENSITY %.3f   trips over %.2f\ny %.2f   vy %+.2f   speed %.1f\n%s\n\nWASD move   R respawn   ESC out" % [
		pops, "ON" if armed else "off", d, TRIP,
		player.global_position.y, player.velocity.y,
		Vector2(player.velocity.x, player.velocity.z).length(),
		"TOUCHING" if player.touching else "air"]
	hud.add_theme_color_override("font_color", Color(1.0, 1.0 - flash, 1.0 - flash))
