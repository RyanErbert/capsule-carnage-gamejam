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
const PlayerScene := preload("res://Player/player.tscn")
const HudScene := preload("res://UI/game_hud.tscn")
const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")

var terrain: Node3D
var player: CharacterBody3D
var _playing := false
var _layers: Array = []        # 4 x (32 ints), bit (31-col) = filled
var _active_layer := 1         # painting target; 1 = MAIN
var _layer_buttons: Array = []
var _editor_layer: CanvasLayer
var _painter: Control
var _status: Label


func _ready() -> void:
	_setup_environment()
	_layers = _default_layers()
	_build_editor_ui()
	Net.event_received.connect(_on_net_event)
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
		Net.emit_event("creativePaint", {"layers": _layers})


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"creativePaint":
			var painted := _norm_layers(data)
			if not _playing and not painted.is_empty() and not _same_layers(painted):
				_adopt_paint(painted)
		"creativeGrid":
			var grid := _norm_layers(data)
			if not grid.is_empty() and not _same_layers(grid):
				_start_play(grid, [], false)
		"mapRebuilt":
			# Round reset: regenerate terrain from the layers, fresh spawn
			if _playing and terrain:
				var rebuilt: Array = _norm_layers(data) if data is Dictionary else []
				if not rebuilt.is_empty():
					_layers = rebuilt
				terrain.build_from_layers(_layers)
				if player:
					player.spawn_points = _spawn_points()
					player.global_position = player.respawn_point()
					player.velocity = Vector3.ZERO
		"terrainEdit":
			if _playing and data is Dictionary and terrain:
				terrain.apply_brush(
					Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0)),
					float(data.get("r", BRUSH_RADIUS)), float(data.get("s", -1.0)),
					float(data.get("st", 1.0)))


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
	terrain.build_from_layers(_layers)
	for e in edits:
		if e is Dictionary:
			terrain.apply_brush(Vector3(e.get("x", 0.0), e.get("y", 0.0), e.get("z", 0.0)),
				float(e.get("r", BRUSH_RADIUS)), float(e.get("s", -1.0)), float(e.get("st", 1.0)))
	if announce:
		Net.emit_event("creativeGrid", {"layers": _layers})
	_editor_layer.visible = false
	if not _playing:
		_playing = true
		_spawn_gameplay()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Instantiate the same gameplay stack testworld wires in its scene file.
func _spawn_gameplay() -> void:
	player = PlayerScene.instantiate()
	player.name = "player"
	var spawns := _spawn_points()
	player.position = spawns.pick_random()
	player.spawn_points = spawns
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

	var hud := HudScene.instantiate()
	hud.sync_node = sync
	add_child(hud)


## Spawns scattered across walkable pixels — main layer open AND ground
## present (not a pit) — one per 3x3 block (web randomSpawn equivalent).
func _spawn_points() -> Array:
	var points: Array = []
	for r in range(1, PIXELS - 1, 3):
		for c in range(1, PIXELS - 1, 3):
			if (int(_layers[1][r]) >> (31 - c)) & 1:
				continue  # main-layer wall
			if not ((int(_layers[0][r]) >> (31 - c)) & 1):
				continue  # pit
			points.append(Vector3(-64.0 + c * 4.0 + 2.0, 2.0, -64.0 + r * 4.0 + 2.0))
	if points.is_empty():
		points.append(Vector3(2.0, 15.0, 2.0))  # all filled: spawn on the stack top
	return points


# --- World backstops --------------------------------------------------------
# (riding a vehicle: world_vehicles.gd rescues the vehicle + driver instead)

func _physics_process(_delta: float) -> void:
	if not _playing or player == null or player.vehicle != null:
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


# --- Environment ------------------------------------------------------------

func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)


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
	title.text = "CREATIVE - paint the canyon"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(title)

	var hint := Label.new()
	hint.text = "left-drag paints, right-drag erases | scroll: layer"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(hint)

	var canvas_row := HBoxContainer.new()
	canvas_row.alignment = BoxContainer.ALIGNMENT_CENTER
	canvas_row.add_theme_constant_override("separation", 14)
	box.add_child(canvas_row)

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
	bedrock_chip.add_theme_font_size_override("font_size", 11)
	bedrock_chip.add_theme_color_override("font_color", Color(1, 1, 1, 0.3))
	layer_col.add_child(bedrock_chip)
	_set_layer(_active_layer)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var gen := Button.new()
	gen.text = "GENERATE & PLAY"
	gen.custom_minimum_size = Vector2(0, 40)
	gen.pressed.connect(func(): _start_play(_layers, [], true))
	buttons.add_child(gen)
	var clear := Button.new()
	clear.text = "CLEAR"
	clear.pressed.connect(func():
		_layers = _default_layers()
		_on_painted()
		_painter.queue_redraw())
	buttons.add_child(clear)
	var back := Button.new()
	back.text = "BACK TO MENU"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://UI/main_menu.tscn"))
	buttons.add_child(back)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	box.add_child(_status)


func _set_layer(li: int) -> void:
	_active_layer = clampi(li, 0, LAYERS - 1)
	for i in LAYERS:
		if _layer_buttons[i]:
			_layer_buttons[i].button_pressed = i == _active_layer
	if _painter:
		_painter.queue_redraw()


func change_layer(dir: int) -> void:
	_set_layer(_active_layer + dir)


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
		elif event is InputEventMouseMotion and _paint_value != -1:
			_paint_at(event.position)

	func _paint_at(pos: Vector2) -> void:
		if _paint_value == -1:
			return
		var c := clampi(int(pos.x) / CELL, 0, 31)
		var r := clampi(int(pos.y) / CELL, 0, 31)
		var bit := 1 << (31 - c)
		var rows: Array = owner_scene._layers[owner_scene._active_layer]
		if _paint_value == 1:
			rows[r] = int(rows[r]) | bit
		else:
			rows[r] = int(rows[r]) & ~bit
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
				draw_rect(rect, col)
