extends Node3D

## Creative level: paint a 32x32 pixel matrix across 4 stacked LAYERS
## (scroll wheel changes the active layer), GENERATE extrudes the stack into
## a 128x128 m world of 4 m slabs — ground (default solid, erase for pits),
## main, +1, +2 — sitting on an uneditable bedrock plane, surrounded by a
## flat unmodifiable plain instead of a rim dropoff (voxel_terrain.gd).
##
## Multiplayer: the pixel grid and every brush stroke go through the server
## ('creativeGrid' / 'terrainEdit'); joiners get a snapshot on connect, so
## everyone sculpts the same world.
##
## Terraforming is gated: god mode has DIG/FILL tools (god_menu.gd) and the
## drill vehicle carves while driving — no free sculpting during normal play.

const PIXELS := 32
const LAYERS := 4
const LAYER_NAMES := ["GROUND", "MAIN", "+1", "+2"]  # index 0..3, bottom up
const BRUSH_RADIUS := 3.0       # default radius for replayed edits
const KILL_Y := -20.0           # below the world: instant respawn backstop

# Stage bounds: a base haze sits over the whole world, visible fog banks
# stand just outside the 128x128 play area, and the closer you get to the
# edge the thicker it reads — full white ~38 m out, where you're turned
# around to face the center.
const FOG_START := 72.0    # partway up the boundary bowl (max-norm)
const FOG_WHITE := 108.0
const FOG_BASE := 0.0015   # always-on depth-fog density inside the arena

# Unshaded white haze sheet for the boundary fog banks: solid near the
# ground, fading out toward the top so it reads as weather, not a fence.
const FOG_WALL_SHADER := "
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform float alpha_max = 0.1;
void fragment() {
	float fade = smoothstep(0.02, 0.55, UV.y);
	ALBEDO = vec3(1.0);
	ALPHA = alpha_max * fade;
}
"
# Spawn zones: each painter can claim one. The 5x5-pixel block around a claim
# is a DEADZONE — unpaintable here, unsculptable in play — so respawns always
# land on known ground. No claims = no deadzones. Mirrors server DEADZONE_R.
const DEADZONE_PX := 2          # pixels either side of the claimed pixel

# Confined spaces duck the wind and fade in a cave drone; venturing past the
# bounds ramps in a gale over the top of it.
const PROBE_DIRS := [
	Vector3(0, 1, 0), Vector3(0.6, 0.8, 0), Vector3(-0.6, 0.8, 0),
	Vector3(0, 0.8, 0.6), Vector3(0, 0.8, -0.6),
]
const PROBE_DIST := 16.0
const AMBIENCE_LERP := 1.4      # how fast the mix follows the space you're in

const PlayerScene := preload("res://Player/player.tscn")
const HudScene := preload("res://UI/game_hud.tscn")
const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")

var terrain: Node3D
var player: CharacterBody3D
var _playing := false
var _layers: Array = []        # 4 x (32 ints), bit (31-col) = filled
var _active_layer := 1         # painting target; 1 = MAIN
var _layer_buttons: Array = []
var _brush := 1                # painter brush size, in cells across
var _spire_mode := true        # painting high fills the column underneath
var _zones: Dictionary = {}    # socket id -> [r, c]; one spawn zone each
var _cursors: Dictionary = {}  # socket id -> {r, c, t}; co-painters' hovers
var _hover_px := Vector2i(-1, -1)
var _hover_sent := Vector2i(-1, -1)
var _cursor_send_cd := 0.0
var _spawn_mode := false       # SPAWN chip armed: clicks claim your zone
var _spawn_button: Button
var _vote_bar: PanelContainer
var _vote_label: Label
var _editor_layer: CanvasLayer
var _painter: Control
var _status: Label
var _fog_rect: ColorRect
var _env_ref: Environment
var _wind: AudioStreamPlayer    # base ambience
var _gale: AudioStreamPlayer    # boundary wind, ramps in past the bounds
var _cave: AudioStreamPlayer    # low drone for confined spaces
var _motes: CPUParticles3D      # cave dust, fades in with confinement
var _confine := 0.0             # 0 open sky .. 1 fully enclosed
var _probe_cd := 0.0


func _ready() -> void:
	_setup_environment()
	_layers = _default_layers()
	_zones = Net.spawn_zones.duplicate()
	_build_editor_ui()
	Net.event_received.connect(_on_net_event)
	Net.emit_event("editing", true)   # counts us in the generate/clear votes
	# Someone already sculpted a world this session? Join it as-is.
	var live := _norm_layers(Net.creative_grid)
	var painting := _norm_layers(Net.paint_rows)
	if not live.is_empty():
		_start_play(live, Net.terrain_edits.duplicate(), false)
	elif OS.get_environment("FRIENDSLOP_AUTOJOIN") == "1":
		_start_play.call_deferred(_layers, [], true)  # headless testing
	elif not painting.is_empty():
		# Someone is mid-painting: adopt their canvas
		_adopt_paint(painting)


## Back to the menu, or any other exit: stop counting toward editor votes.
func _exit_tree() -> void:
	Net.emit_event("editing", false)


## Ground layer full (the flat plain you walk on), everything above empty.
func _default_layers() -> Array:
	var out := []
	for li in LAYERS:
		var rows := []
		for r in PIXELS:
			rows.append(0xFFFFFFFF if li == 0 else 0)
		out.append(rows)
	return out


## Validate + int-normalize a {layers:[4x32]} payload (or a raw 4x32 Array).
## Returns [] when the shape is wrong.
func _norm_layers(data: Variant) -> Array:
	if data is Dictionary:
		data = data.get("layers")
	if not (data is Array) or data.size() != LAYERS:
		return []
	var out := []
	for rows in data:
		if not (rows is Array) or rows.size() != PIXELS:
			return []
		var ints := []
		for v in rows:
			ints.append(int(v))
		out.append(ints)
	return out


func _grid_payload() -> Dictionary:
	return {"layers": _layers}


func _adopt_paint(layers: Array) -> void:
	_layers = layers
	if _painter:
		_painter.queue_redraw()


## Painter calls this on every stroke; sends are throttled in _process.
var _paint_dirty := false
var _paint_send_cd := 0.0

func _on_painted() -> void:
	_paint_dirty = true


func _process(delta: float) -> void:
	if _playing:
		return
	_paint_send_cd = maxf(0.0, _paint_send_cd - delta)
	if _paint_dirty and _paint_send_cd <= 0.0:
		_paint_dirty = false
		_paint_send_cd = 0.12
		Net.emit_event("creativePaint", _grid_payload())
	# Hover cursor, relayed so co-painters can see where you are
	_cursor_send_cd = maxf(0.0, _cursor_send_cd - delta)
	if _cursor_send_cd <= 0.0 and _hover_px.x >= 0 and _hover_px != _hover_sent:
		_cursor_send_cd = 0.1
		_hover_sent = _hover_px
		Net.emit_event("editCursor", {"r": _hover_px.y, "c": _hover_px.x})
	if not _cursors.is_empty() and _painter:
		_painter.queue_redraw()  # keeps stale cursors fading out


func _on_hover(r: int, c: int) -> void:
	_hover_px = Vector2i(c, r)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"creativePaint":
			var painted := _norm_layers(data)
			if not _playing and not painted.is_empty() and not _same_layers(painted):
				_adopt_paint(painted)
		"paintCleared":
			if not _playing:
				_adopt_paint(_default_layers())
		"spawnZones":
			_zones = data if data is Dictionary else {}
			if _painter:
				_painter.queue_redraw()
			if _playing:
				_make_deadzone_marker()
		"editCursor":
			if not _playing and data is Dictionary:
				_cursors[str(data.get("id", ""))] = {
					"r": int(data.get("r", 0)), "c": int(data.get("c", 0)),
					"t": Time.get_ticks_msec(),
				}
		"editVote":
			_show_vote(data)
		"creativeGrid":
			var grid := _norm_layers(data)
			if not grid.is_empty() and (not _playing or not _same_layers(grid)):
				_start_play(grid, [], false)
		"gameEnded":
			# Full wipe, grid included: everyone goes back to the lobby so the
			# next map starts from a blank canvas.
			get_tree().change_scene_to_file("res://UI/main_menu.tscn")
		"terrainEdit":
			if _playing and data is Dictionary and terrain:
				_replay_edit(data)


## One replayed brush stroke from the server (or the join snapshot).
func _replay_edit(e: Dictionary) -> void:
	var at := Vector3(e.get("x", 0.0), e.get("y", 0.0), e.get("z", 0.0))
	var r := float(e.get("r", BRUSH_RADIUS))
	var st := float(e.get("st", 1.0))
	if str(e.get("m", "add")) == "smooth":
		terrain.smooth_brush(at, r, st)
	else:
		terrain.apply_brush(at, r, float(e.get("s", -1.0)), st)


## JSON round-trips ints as floats — compare numerically, not by hash.
func _same_layers(other: Array) -> bool:
	if other.size() != _layers.size():
		return false
	for li in _layers.size():
		var a: Array = _layers[li]
		var b: Array = other[li]
		if a.size() != b.size():
			return false
		for i in a.size():
			if int(a[i]) != int(b[i]):
				return false
	return true


func _start_play(layers: Array, edits: Array, announce: bool) -> void:
	_layers = layers
	_status.text = "generating terrain..."
	await get_tree().process_frame  # let the label paint before the long build
	if terrain == null:
		terrain = VoxelTerrain.new()
		add_child(terrain)
	terrain.deadzone_centers = _home_pixels().map(_px_world)
	terrain.build_from_layers(_layers)
	_make_deadzone_marker()
	for e in edits:
		if e is Dictionary:
			_replay_edit(e)
	if announce:
		Net.emit_event("creativeGrid", _grid_payload())
	_editor_layer.visible = false
	Net.emit_event("editing", false)
	if not _playing:
		_playing = true
		_spawn_gameplay()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Instantiate the same gameplay stack testworld wires in its scene file.
func _spawn_gameplay() -> void:
	player = PlayerScene.instantiate()
	player.name = "player"
	var spawns := _spawn_points()
	player.spawn_points = spawns
	player.respawn_provider = _zone_respawn
	var zp: Variant = _zone_respawn()
	player.position = zp if zp is Vector3 else spawns.pick_random()
	add_child(player)

	var sync := Node.new()
	sync.name = "MultiplayerSync"
	sync.set_script(load("res://Net/multiplayer_sync.gd"))
	sync.player = player
	add_child(sync)

	var items := Node3D.new()
	items.name = "WorldItems"
	items.set_script(load("res://Items/world_items.gd"))
	items.player = player
	add_child(items)

	var proj := Node3D.new()
	proj.name = "WorldProjectiles"
	proj.set_script(load("res://Items/projectiles.gd"))
	proj.player = player
	add_child(proj)

	var builds := Node3D.new()
	builds.name = "WorldBuilds"
	builds.set_script(load("res://Items/builds.gd"))
	add_child(builds)

	var props := Node3D.new()
	props.name = "WorldProps"
	props.set_script(load("res://Items/props.gd"))
	add_child(props)

	var castles := Node3D.new()
	castles.name = "WorldCastles"
	castles.set_script(load("res://Items/castle.gd"))
	add_child(castles)

	var vehicles := Node3D.new()
	vehicles.name = "WorldVehicles"
	vehicles.set_script(load("res://Vehicles/world_vehicles.gd"))
	vehicles.player = player
	add_child(vehicles)

	var generators := Node3D.new()
	generators.name = "WorldGenerators"
	generators.set_script(load("res://Items/generators.gd"))
	generators.player = player
	add_child(generators)

	var turrets := Node3D.new()
	turrets.name = "WorldTurrets"
	turrets.set_script(load("res://Items/turrets.gd"))
	turrets.player = player
	add_child(turrets)

	var critters := Node3D.new()
	critters.name = "WorldCritters"
	critters.set_script(load("res://Items/critters.gd"))
	critters.player = player
	add_child(critters)

	var hud := HudScene.instantiate()
	hud.sync_node = sync
	add_child(hud)

	# Dust motes: drift around the player while enclosed, catching the light
	# where a cave opens up (the Compatibility renderer has no real volumetrics)
	_motes = CPUParticles3D.new()
	_motes.amount = 70
	_motes.lifetime = 7.0
	_motes.preprocess = 3.0
	_motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_motes.emission_box_extents = Vector3(8, 4.5, 8)
	_motes.gravity = Vector3(0, -0.05, 0)
	_motes.direction = Vector3(0, 0, 0)
	_motes.spread = 180.0
	_motes.initial_velocity_min = 0.05
	_motes.initial_velocity_max = 0.35
	var mote_mesh := QuadMesh.new()
	mote_mesh.size = Vector2(0.05, 0.05)
	var mote_mat := StandardMaterial3D.new()
	mote_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote_mat.albedo_color = Color(1.0, 0.97, 0.85, 0.4)
	mote_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mote_mesh.material = mote_mat
	_motes.mesh = mote_mesh
	_motes.emitting = false
	add_child(_motes)

	# White-out overlay for the fog boundary (above the 3D world, below the HUD)
	var fog_layer := CanvasLayer.new()
	fog_layer.layer = 0
	add_child(fog_layer)
	_fog_rect = ColorRect.new()
	_fog_rect.color = Color(1, 1, 1, 0.0)
	_fog_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fog_layer.add_child(_fog_rect)
	_make_fog_shells()


## Fake volumetric fog outside the play bounds: concentric square shells of
## translucent white haze (the Compatibility renderer has no FogVolume).
## From inside they read as a distant fog bank; walking out you pass through
## shell after shell, so the whiteout builds gradually instead of snapping on.
func _make_fog_shells() -> void:
	var shader := Shader.new()
	shader.code = FOG_WALL_SHADER
	var wall_h := 90.0
	var wall_y := wall_h * 0.5 - 16.0  # from below the slabs up past their tops
	# [half-extent, opacity] — denser the deeper into the fog you are
	# (first bank stands just past the boundary bowl's rim at 80)
	for ring in [[82.0, 0.05], [90.0, 0.08], [98.0, 0.12], [107.0, 0.16], [120.0, 0.24]]:
		var r: float = ring[0]
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("alpha_max", ring[1])
		for i in 4:
			var mi := MeshInstance3D.new()
			var quad := QuadMesh.new()
			quad.size = Vector2(r * 2.0 + 10.0, wall_h)
			mi.mesh = quad
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.rotation.y = i * PI / 2.0
			mi.position = Vector3(0, wall_y, 0) + Basis(Vector3.UP, i * PI / 2.0) * Vector3(0, 0, -r)
			add_child(mi)


## Spawns scattered across walkable pixels — nothing at main level (that's
## what blocks you at ground height) AND ground present (not a pit) — one per
## 3x3 block (web randomSpawn equivalent).
func _spawn_points() -> Array:
	var points: Array = []
	for r in range(1, PIXELS - 1, 3):
		for c in range(1, PIXELS - 1, 3):
			if (int(_layers[1][r]) >> (31 - c)) & 1:
				continue  # wall column
			if not ((int(_layers[0][r]) >> (31 - c)) & 1):
				continue  # pit
			points.append(Vector3(-64.0 + c * 4.0 + 2.0, 2.0, -64.0 + r * 4.0 + 2.0))
	if points.is_empty():
		points.append(Vector3(2.0, 27.0, 2.0))  # all filled: spawn on the stack top
	return points


# --- Home base deadzone ------------------------------------------------------

## Every claimed spawn pixel (possibly none).
func _home_pixels() -> Array:
	var out: Array = []
	for id in _zones:
		var z: Array = _zones[id]
		out.append([int(z[0]), int(z[1])])
	return out


## Our own claim, or null if we haven't placed one yet.
func _my_px() -> Variant:
	var z: Variant = _zones.get(Net.socket_id)
	return [int(z[0]), int(z[1])] if z is Array else null


func _px_world(h: Array) -> Vector3:
	return Vector3(-64.0 + int(h[1]) * 4.0 + 2.0, 0.0, -64.0 + int(h[0]) * 4.0 + 2.0)


func _in_deadzone(r: int, c: int) -> bool:
	for h in _home_pixels():
		if absi(r - int(h[0])) <= DEADZONE_PX and absi(c - int(h[1])) <= DEADZONE_PX:
			return true
	return false


## Respawns land somewhere random inside YOUR zone. The zone is edit-protected,
## so the painted layer stack is still the truth about its surface height.
## Returns null with no claim — respawn_point() falls back to spawn_points.
func _zone_respawn() -> Variant:
	var mine: Variant = _my_px()
	if not mine is Array or _layers.is_empty():
		return null
	for _i in 16:
		var rr := clampi(int(mine[0]) + randi_range(-DEADZONE_PX, DEADZONE_PX), 0, PIXELS - 1)
		var cc := clampi(int(mine[1]) + randi_range(-DEADZONE_PX, DEADZONE_PX), 0, PIXELS - 1)
		if not ((int(_layers[0][rr]) >> (31 - cc)) & 1):
			continue  # pit
		return Vector3(-64.0 + cc * 4.0 + 2.0, _surface_y(rr, cc) + 1.0, -64.0 + rr * 4.0 + 2.0)
	return null


## Painted surface height at a pixel: 8 m slabs, surface ~1 m into the slab.
func _surface_y(r: int, c: int) -> float:
	if _layers.is_empty() or not ((int(_layers[0][r]) >> (31 - c)) & 1):
		return 1.0
	var top := 0
	for li in range(1, LAYERS):
		if (int(_layers[li][r]) >> (31 - c)) & 1:
			top = li
	return top * 8.0 + 1.0


## In play a zone is just the patch respawns land on — no monolith. A faint
## boundary line on the ground marks where terrain tools stop working.
var _deadzone_node: Node3D

func _make_deadzone_marker() -> void:
	if _deadzone_node:
		_deadzone_node.queue_free()
	_deadzone_node = Node3D.new()
	add_child(_deadzone_node)
	if terrain:
		terrain.deadzone_centers = _home_pixels().map(_px_world)
	for h in _home_pixels():
		var at := _px_world(h)
		at.y = _surface_y(int(h[0]), int(h[1]))
		_deadzone_edge(at)


func _deadzone_edge(at: Vector3) -> void:
	var size := VoxelTerrain.DEADZONE_R * 2.0
	var edge_mat := StandardMaterial3D.new()
	edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge_mat.albedo_color = Color(0.55, 1.0, 0.75, 0.2)
	edge_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var h := VoxelTerrain.DEADZONE_R
	for side in 4:
		var band := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(size + 0.6, 0.6)
		band.mesh = quad
		band.material_override = edge_mat
		band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		band.rotation = Vector3(-PI / 2.0, side * PI / 2.0, 0)
		band.position = at + Vector3(0, 0.08, 0) \
			+ Basis(Vector3.UP, side * PI / 2.0) * Vector3(0, 0, -h)
		_deadzone_node.add_child(band)


# --- World backstops --------------------------------------------------------
# (riding a vehicle: world_vehicles.gd rescues the vehicle + driver instead)

func _physics_process(delta: float) -> void:
	if not _playing or player == null:
		return
	_update_fog_bounds()
	_update_ambience(delta)
	if player.vehicle != null:
		return
	# Backstop: anything that slips below the world snaps back to a spawn
	if player.global_position.y < KILL_Y:
		player.global_position = player.respawn_point()
		player.velocity = Vector3.ZERO
	# Filled-in terrain can embed the player (remote FILL strokes); the
	# depenetration then shoves them through the floor. Pop upward instead.
	if terrain and terrain.density_at(player.global_position + Vector3(0, 0.2, 0)) > 0.55:
		player.global_position.y += 1.0
		player.velocity.y = maxf(player.velocity.y, 0.0)


## Distance-based white-out past FOG_START; at FOG_WHITE the screen is fully
## white and the player (or their vehicle) is turned to face the center.
func _update_fog_bounds() -> void:
	if _fog_rect == null:
		return
	var hpos := Vector2(player.global_position.x, player.global_position.z)
	# Max-norm distance so the fog line hugs the SQUARE play area exactly
	var d := maxf(absf(hpos.x), absf(hpos.y))
	var f := clampf((d - FOG_START) / (FOG_WHITE - FOG_START), 0.0, 1.0)
	if player.godmode or player.dead:
		f = 0.0
	_fog_f = f
	_fog_rect.color.a = f * f  # eases in, hits solid white right at the bound
	if _env_ref:
		# Thicken the ever-present base haze; the sky whites out with it
		_env_ref.fog_density = FOG_BASE + f * 0.05
		_env_ref.fog_sky_affect = 0.1 + 0.9 * f
	if f < 1.0 or d < 1.0:
		return
	# Whited out: about-face toward the center (camera too, so W walks back)
	var dir := Vector3(-hpos.x, 0.0, -hpos.y).normalized()
	var yaw := atan2(-dir.x, -dir.z)
	if player.camera_rig:
		player.camera_rig.yaw = yaw
	if player.vehicle != null and is_instance_valid(player.vehicle):
		var veh: CharacterBody3D = player.vehicle
		var vspd := maxf(Vector2(veh.velocity.x, veh.velocity.z).length(), 12.0)
		veh.velocity.x = dir.x * vspd
		veh.velocity.z = dir.z * vspd
		veh.rotation.y = yaw
	else:
		var pspd := maxf(Vector2(player.velocity.x, player.velocity.z).length(), 8.0)
		player.velocity.x = dir.x * pspd
		player.velocity.z = dir.z * pspd


# --- Environment ------------------------------------------------------------

func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.95, 0.85)  # warm sun makes slopes read
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.55  # lower ambient: shading carries the shape
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Base haze: always on, so the boundary fog is a thickening of something
	# already there instead of an effect that snaps on at the edge
	e.fog_enabled = true
	e.fog_light_color = Color(1, 1, 1)
	e.fog_density = FOG_BASE
	e.fog_sky_affect = 0.1
	env.environment = e
	_env_ref = e
	add_child(env)
	_setup_ambience()


# --- Ambience ----------------------------------------------------------------
# Three beds, mixed live: open-air wind, a low cave drone that swaps in when
# you're enclosed, and a gale that ramps up as you push past the boundary.

func _looping_player(path: String, pitch: float, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var stream: AudioStreamOggVorbis = load(path).duplicate()
	stream.loop = true
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = db
	p.autoplay = true
	add_child(p)
	return p


func _setup_ambience() -> void:
	# CC0 wind loop (opengameart.org/content/wind-whoosh-loop)
	_wind = _looping_player("res://Audio/ambient_wind.ogg", 1.0, -16.0)
	# Same loop, slowed and detuned: the boundary gale over the top of it
	_gale = _looping_player("res://Audio/ambient_wind.ogg", 0.78, -60.0)
	# Cave drone: generated brown noise, so there's nothing tonal in it to
	# oscillate — just a low, slow rush.
	_cave = AudioStreamPlayer.new()
	_cave.stream = _make_cave_noise()
	_cave.volume_db = -60.0
	_cave.autoplay = true
	add_child(_cave)


## Brown noise (integrated white noise, then heavily low-passed) rendered to a
## looping 16-bit sample at load. The tail is cross-faded into the head so the
## loop point is inaudible.
func _make_cave_noise() -> AudioStreamWAV:
	var rate := 22050
	var total := rate * 8
	var fade := rate * 2
	var loop_len := total - fade
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260810
	var buf := PackedFloat32Array()
	buf.resize(total)
	var brown := 0.0
	var slow := 0.0
	for i in total:
		brown = clampf(brown * 0.995 + rng.randf_range(-1.0, 1.0) * 0.03, -1.0, 1.0)
		slow += (brown - slow) * 0.03   # only the lowest band survives
		buf[i] = slow
	for i in fade:
		var t := float(i) / float(fade)
		buf[i] = buf[i] * t + buf[loop_len + i] * (1.0 - t)
	var peak := 0.0001
	for i in loop_len:
		peak = maxf(peak, absf(buf[i]))
	var data := PackedByteArray()
	data.resize(loop_len * 2)
	for i in loop_len:
		var v := int(clampf(buf[i] / peak, -1.0, 1.0) * 32000.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = loop_len
	return wav


## Roof/wall probes from the head: the share that hit something nearby is how
## enclosed you are. Cheap enough at 6 Hz, and it reacts to dug-out caves and
## built structures alike because it's just raycasts against the world.
func _probe_confinement() -> void:
	var space := player.get_world_3d().direct_space_state
	var from := player.global_position + Vector3(0, 1.0, 0)
	var blocked := 0
	for dir in PROBE_DIRS:
		var q := PhysicsRayQueryParameters3D.create(from, from + dir.normalized() * PROBE_DIST)
		q.exclude = [player.get_rid()]
		if not space.intersect_ray(q).is_empty():
			blocked += 1
	var target := float(blocked) / float(PROBE_DIRS.size())
	# Only a real roof counts as a cave; one wall nearby shouldn't muffle you
	_confine_target = smoothstep(0.35, 1.0, target)


var _confine_target := 0.0
var _fog_f := 0.0

func _update_ambience(delta: float) -> void:
	if _wind == null or player == null:
		return
	_probe_cd -= delta
	if _probe_cd <= 0.0:
		_probe_cd = 0.16
		_probe_confinement()
	_confine = lerpf(_confine, _confine_target, minf(1.0, AMBIENCE_LERP * delta))
	# Wind drops away indoors, and lifts a little out in the open boundary
	_wind.volume_db = lerpf(-16.0 + 4.0 * _fog_f, -34.0, _confine)
	_cave.volume_db = -60.0 if _confine < 0.02 else lerpf(-40.0, -13.0, _confine)
	# The gale ignores confinement: outside the bounds there's nothing to hide in
	_gale.volume_db = -60.0 if _fog_f < 0.01 else lerpf(-30.0, -5.0, _fog_f)
	# Dust hangs in enclosed air
	if _motes:
		_motes.emitting = _confine > 0.35
		_motes.global_position = player.global_position


# --- Editor UI ---------------------------------------------------------------

func _build_editor_ui() -> void:
	_editor_layer = CanvasLayer.new()
	add_child(_editor_layer)
	var bg := ColorRect.new()
	bg.color = Color("#0c0e12")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_editor_layer.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_editor_layer.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "PAINT THE MAP"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(title)

	var hint := Label.new()
	hint.text = "[LMB - Paint]  [RMB - Erase]  [Scroll - Layer]"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(hint)

	# Brush size + spire mode, above the canvas
	var opts := HBoxContainer.new()
	opts.alignment = BoxContainer.ALIGNMENT_CENTER
	opts.add_theme_constant_override("separation", 6)
	box.add_child(opts)
	var brush_lbl := Label.new()
	brush_lbl.text = "BRUSH"
	brush_lbl.add_theme_font_size_override("font_size", 16)
	brush_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	opts.add_child(brush_lbl)
	var brush_group := ButtonGroup.new()
	for size in [1, 2, 3, 5]:
		var bb := Button.new()
		bb.text = "%d" % size
		bb.toggle_mode = true
		bb.button_group = brush_group
		bb.focus_mode = Control.FOCUS_NONE
		bb.custom_minimum_size = Vector2(34, 28)
		bb.button_pressed = size == _brush
		bb.pressed.connect(func(): _brush = size)
		opts.add_child(bb)
	# SPIRE MODE: paint high and the column beneath fills in with it. Off,
	# slabs are free to float.
	var spire := Button.new()
	spire.text = "SPIRE"
	spire.toggle_mode = true
	spire.focus_mode = Control.FOCUS_NONE
	spire.button_pressed = _spire_mode
	spire.custom_minimum_size = Vector2(110, 28)
	spire.add_theme_color_override("font_color", Color("#ff5560"))
	spire.toggled.connect(func(on: bool): _spire_mode = on)
	opts.add_child(spire)

	var canvas_row := HBoxContainer.new()
	canvas_row.alignment = BoxContainer.ALIGNMENT_CENTER
	canvas_row.add_theme_constant_override("separation", 14)
	box.add_child(canvas_row)

	# Chat docked beside the canvas, so painters talk in the same column
	var chat := PanelContainer.new()
	chat.set_script(load("res://UI/chat_box.gd"))
	chat.custom_minimum_size = Vector2(250, 0)
	canvas_row.add_child(chat)

	_painter = PixelPainter.new()
	_painter.owner_scene = self
	canvas_row.add_child(_painter)

	# Layer chips beside the canvas, top slab first; click or scroll to switch
	var layer_col := VBoxContainer.new()
	layer_col.alignment = BoxContainer.ALIGNMENT_CENTER
	layer_col.add_theme_constant_override("separation", 6)
	canvas_row.add_child(layer_col)
	_layer_buttons.resize(LAYERS)
	for li in range(LAYERS - 1, -1, -1):
		var lb := Button.new()
		lb.text = LAYER_NAMES[li]
		lb.toggle_mode = true
		lb.focus_mode = Control.FOCUS_NONE
		lb.custom_minimum_size = Vector2(88, 34)
		lb.add_theme_color_override("font_color", Color(PixelPainter.LAYER_FILL[li]))
		lb.pressed.connect(func(): _set_layer(li))
		layer_col.add_child(lb)
		_layer_buttons[li] = lb
	var bedrock_chip := Label.new()
	bedrock_chip.text = "BEDROCK"
	bedrock_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bedrock_chip.custom_minimum_size = Vector2(88, 0)
	bedrock_chip.add_theme_font_size_override("font_size", 16)
	bedrock_chip.add_theme_color_override("font_color", Color(1, 1, 1, 0.3))
	layer_col.add_child(bedrock_chip)

	# SPAWN chip: click the canvas to drop the spawn (a building generates there)
	_spawn_button = Button.new()
	_spawn_button.text = "⌂ SPAWN"
	_spawn_button.toggle_mode = true
	_spawn_button.focus_mode = Control.FOCUS_NONE
	_spawn_button.custom_minimum_size = Vector2(88, 34)
	_spawn_button.add_theme_color_override("font_color", Color("#7dedb0"))
	_spawn_button.pressed.connect(func():
		_spawn_mode = _spawn_button.button_pressed
		if _painter:
			_painter.queue_redraw())
	layer_col.add_child(_spawn_button)
	_set_layer(_active_layer)

	# Confirmation bar: GENERATE and CLEAR need everyone at the canvas to agree
	_vote_bar = PanelContainer.new()
	_vote_bar.visible = false
	_vote_bar.add_theme_stylebox_override("panel",
		preload("res://UI/ui_style.gd").panel_box(Color(0.25, 0.06, 0.08, 0.9), 8))
	box.add_child(_vote_bar)
	var vrow := HBoxContainer.new()
	vrow.add_theme_constant_override("separation", 10)
	_vote_bar.add_child(vrow)
	_vote_label = Label.new()
	_vote_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vrow.add_child(_vote_label)
	for entry in [["YES", true], ["NO", false]]:
		var vb := Button.new()
		vb.text = entry[0]
		vb.focus_mode = Control.FOCUS_NONE
		vb.pressed.connect(func(): Net.emit_event("castEditVote", entry[1]))
		vrow.add_child(vb)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var gen := Button.new()
	gen.text = "GENERATE & PLAY"
	gen.custom_minimum_size = Vector2(0, 40)
	gen.pressed.connect(func(): Net.emit_event("requestGenerate"))
	buttons.add_child(gen)
	var clear := Button.new()
	clear.text = "CLEAR"
	clear.pressed.connect(func(): Net.emit_event("requestClear"))
	buttons.add_child(clear)
	var back := Button.new()
	back.text = "BACK TO MENU"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://UI/main_menu.tscn"))
	buttons.add_child(back)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	box.add_child(_status)


## The server relays who still has to confirm a GENERATE or CLEAR.
func _show_vote(data: Variant) -> void:
	if _vote_bar == null:
		return
	if not data is Dictionary:
		_vote_bar.visible = false
		return
	_vote_bar.visible = true
	_vote_label.text = "%s?   %d/%d" % [
		"CLEAR" if str(data.get("kind", "")) == "clear" else "START",
		int(data.get("yes", 0)), int(data.get("need", 0))]


func _set_layer(li: int) -> void:
	_active_layer = clampi(li, 0, LAYERS - 1)
	_spawn_mode = false
	if _spawn_button:
		_spawn_button.button_pressed = false
	for i in LAYERS:
		if _layer_buttons[i]:
			_layer_buttons[i].button_pressed = i == _active_layer
	if _painter:
		_painter.queue_redraw()


func change_layer(dir: int) -> void:
	_set_layer(_active_layer + dir)


## One canvas cell on the active layer. SPIRE MODE fills the layers beneath
## as you paint high, so a tower comes with its column; with it off, slabs
## are free to hang in the air. The home deadzone refuses paint entirely.
func paint_cell(r: int, c: int, fill: bool) -> void:
	if _in_deadzone(r, c):
		return
	var bit := 1 << (31 - c)
	var rows: Array = _layers[_active_layer]
	if fill:
		rows[r] = int(rows[r]) | bit
		if _spire_mode:
			for li in _active_layer:
				_layers[li][r] = int(_layers[li][r]) | bit
	else:
		rows[r] = int(rows[r]) & ~bit


class PixelPainter extends Control:
	const CELL := 14
	# Fill colors bottom-up: ground, main, +1, +2 (lighter = higher)
	const LAYER_FILL := ["#8a5a3a", "#c78b5e", "#dfa878", "#f0cb96"]
	const BG := Color("#1a2030")
	const PIT := Color("#07080c")
	const GHOST_ALPHA := 0.3
	var owner_scene: Node
	var _paint_value := -1  # -1 idle, 1 fill, 0 erase

	func _init() -> void:
		custom_minimum_size = Vector2(32 * CELL, 32 * CELL)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
				owner_scene.change_layer(1)
				accept_event()
				return
			if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				owner_scene.change_layer(-1)
				accept_event()
				return
			if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				_paint_value = 1
			elif event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
				_paint_value = 0
			elif not event.pressed:
				_paint_value = -1
			_paint_at(event.position)
		elif event is InputEventMouseMotion:
			owner_scene._on_hover(
				clampi(int(event.position.y) / CELL, 0, 31),
				clampi(int(event.position.x) / CELL, 0, 31))
			if _paint_value != -1:
				_paint_at(event.position)

	func _paint_at(pos: Vector2) -> void:
		if _paint_value == -1:
			return
		var c := clampi(int(pos.x) / CELL, 0, 31)
		var r := clampi(int(pos.y) / CELL, 0, 31)
		if owner_scene._spawn_mode:
			# The server owns zones: it rejects overlaps and broadcasts the set
			Net.emit_event("setSpawn", {"r": r, "c": c} if _paint_value == 1 else null)
			return
		var reach: int = owner_scene._brush - 1
		for rr in range(r - reach, r + reach + 1):
			for cc in range(c - reach, c + reach + 1):
				if rr >= 0 and rr < 32 and cc >= 0 and cc < 32:
					owner_scene.paint_cell(rr, cc, _paint_value == 1)
		owner_scene._on_painted()
		queue_redraw()

	func _bit(li: int, r: int, c: int) -> bool:
		return bool((int(owner_scene._layers[li][r]) >> (31 - c)) & 1)

	## Active layer at full color; every other layer ghosted underneath so
	## you can line slabs up. Missing ground reads as a near-black pit.
	func _draw() -> void:
		var active: int = owner_scene._active_layer
		for r in 32:
			for c in 32:
				var rect := Rect2(c * CELL, r * CELL, CELL - 1, CELL - 1)
				var col := BG if _bit(0, r, c) else PIT
				for li in range(1, 4):
					if li != active and _bit(li, r, c):
						col = col.lerp(Color(LAYER_FILL[li]), GHOST_ALPHA)
				if active == 0:
					if _bit(0, r, c):
						col = col.lerp(Color(LAYER_FILL[0]), 0.85)
				elif _bit(active, r, c):
					col = Color(LAYER_FILL[active])
				# Home deadzone: off-limits to the brush, in play as well
				if owner_scene._in_deadzone(r, c):
					col = col.lerp(Color(1.0, 0.25, 0.25), 0.35)
				draw_rect(rect, col)
		# Spawn zones: yours green, everyone else's blue
		var mine: Variant = owner_scene._my_px()
		for h in owner_scene._home_pixels():
			var is_mine: bool = mine is Array 				and int(mine[0]) == int(h[0]) and int(mine[1]) == int(h[1])
			var col := Color("#7dedb0") if is_mine else Color("#7fb2ff")
			var srect := Rect2(int(h[1]) * CELL, int(h[0]) * CELL, CELL - 1, CELL - 1)
			draw_rect(srect, col)
			draw_rect(srect.grow(-3), Color("#0c2018"))
			draw_rect(srect.grow(-5), col)
		# Co-painters' live cursors: an outline where they're hovering
		var now := Time.get_ticks_msec()
		for cid in owner_scene._cursors:
			var cur: Dictionary = owner_scene._cursors[cid]
			var age := now - int(cur["t"])
			if age > 2500:
				continue
			var ccol := Color("#7fb2ff", clampf(1.0 - age / 2500.0 * 0.6, 0.0, 1.0))
			draw_rect(Rect2(int(cur["c"]) * CELL, int(cur["r"]) * CELL, CELL - 1, CELL - 1),
				ccol, false, 2.0)
