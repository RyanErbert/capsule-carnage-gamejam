extends Node3D

## Creative level: paint a 32x32 pixel matrix, GENERATE extrudes it into a
## 128x128 m canyon (filled pixel = 16 m wall column, empty = canyon floor),
## then the whole world is diggable/fillable Astroneer-style (voxel_terrain).
##
## Multiplayer: the pixel grid and every brush stroke go through the server
## ('creativeGrid' / 'terrainEdit'); joiners get a snapshot on connect, so
## everyone sculpts the same world.
##
## In play: hold Q to dig, hold F to fill, at the crosshair.

const PIXELS := 32
const BRUSH_RADIUS := 3.0
const BRUSH_INTERVAL := 0.08    # ~12 soft strokes/s reads as continuous
const BRUSH_STRENGTH := 0.5     # per stroke — full carve in ~2 ticks at center
const KILL_Y := -20.0           # below the world: instant respawn backstop
const PlayerScene := preload("res://Player/player.tscn")
const HudScene := preload("res://UI/game_hud.tscn")
const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")

var terrain: Node3D
var player: CharacterBody3D
var _playing := false
var _rows: Array = []          # 32 ints, bit (31-col) = wall
var _editor_layer: CanvasLayer
var _painter: Control
var _status: Label
var _brush_cd := 0.0
var _brush_marker: MeshInstance3D


func _ready() -> void:
	_setup_environment()
	_rows = _default_rows()
	_build_editor_ui()
	Net.event_received.connect(_on_net_event)
	# Someone already sculpted a world this session? Join it as-is.
	if Net.creative_grid is Array and not Net.creative_grid.is_empty():
		_start_play(Net.creative_grid.duplicate(), Net.terrain_edits.duplicate(), false)
	elif OS.get_environment("FRIENDSLOP_AUTOJOIN") == "1":
		_start_play.call_deferred(_rows, [], true)  # headless testing
	elif Net.paint_rows is Array and Net.paint_rows.size() == PIXELS:
		# Someone is mid-painting: adopt their canvas
		_adopt_paint(Net.paint_rows)


func _default_rows() -> Array:
	var rows := []
	for r in PIXELS:
		rows.append(0xFFFFFFFF if (r == 0 or r == PIXELS - 1) else ((1 << 31) | 1))
	return rows  # border ring of walls, open interior


func _adopt_paint(rows: Array) -> void:
	_rows = []
	for v in rows:
		_rows.append(int(v))
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
		Net.emit_event("creativePaint", _rows)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"creativePaint":
			if not _playing and data is Array and data.size() == PIXELS and not _same_rows(data):
				_adopt_paint(data)
		"creativeGrid":
			if data is Array and not _same_rows(data):
				_start_play(data.duplicate(), [], false)
		"terrainEdit":
			if _playing and data is Dictionary and terrain:
				terrain.apply_brush(
					Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0)),
					float(data.get("r", BRUSH_RADIUS)), float(data.get("s", -1.0)),
					float(data.get("st", 1.0)))


## JSON round-trips ints as floats — compare numerically, not by hash.
func _same_rows(other: Array) -> bool:
	if other.size() != _rows.size():
		return false
	for i in _rows.size():
		if int(other[i]) != int(_rows[i]):
			return false
	return true


func _start_play(rows: Array, edits: Array, announce: bool) -> void:
	_rows = []
	for v in rows:
		_rows.append(int(v))
	rows = _rows
	_status.text = "generating terrain..."
	await get_tree().process_frame  # let the label paint before the long build
	if terrain == null:
		terrain = VoxelTerrain.new()
		add_child(terrain)
	terrain.build_from_pixels(rows)
	for e in edits:
		if e is Dictionary:
			terrain.apply_brush(Vector3(e.get("x", 0.0), e.get("y", 0.0), e.get("z", 0.0)),
				float(e.get("r", BRUSH_RADIUS)), float(e.get("s", -1.0)), float(e.get("st", 1.0)))
	if announce:
		Net.emit_event("creativeGrid", rows)
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

	var hud := HudScene.instantiate()
	hud.sync_node = sync
	add_child(hud)

	_brush_marker = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = BRUSH_RADIUS
	sphere.height = BRUSH_RADIUS * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.15)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = mat
	_brush_marker.mesh = sphere
	_brush_marker.visible = false
	add_child(_brush_marker)


## Spawns scattered across the OPEN (unfilled) pixels, one per 3x3 block of
## the canvas so they cover the whole map (web randomSpawn equivalent).
func _spawn_points() -> Array:
	var points: Array = []
	for r in range(1, PIXELS - 1, 3):
		for c in range(1, PIXELS - 1, 3):
			if (int(_rows[r]) >> (31 - c)) & 1:
				continue
			points.append(Vector3(-64.0 + c * 4.0 + 2.0, 2.0, -64.0 + r * 4.0 + 2.0))
	if points.is_empty():
		points.append(Vector3(2.0, WALL_TOP_HEIGHT + 2.0, 2.0))  # all-filled map: spawn on top
	return points

const WALL_TOP_HEIGHT := 16.0


# --- Terraforming (Q dig / F fill at the crosshair) ------------------------

func _physics_process(delta: float) -> void:
	if not _playing or player == null:
		return
	# Backstop: anything that slips below the world snaps back to a spawn
	if player.global_position.y < KILL_Y:
		player.global_position = player.respawn_point()
		player.velocity = Vector3.ZERO
	_brush_cd = maxf(0.0, _brush_cd - delta)
	var busy: bool = get_viewport().gui_get_focus_owner() != null \
		or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or player.godmode
	var dig: bool = not busy and Input.is_key_pressed(KEY_Q)
	var fill: bool = not busy and Input.is_key_pressed(KEY_F)
	if not dig and not fill:
		_brush_marker.visible = false
		return
	var target: Variant = _aim_point()
	if target == null:
		_brush_marker.visible = false
		return
	_brush_marker.visible = true
	_brush_marker.global_position = target
	if _brush_cd > 0.0:
		return
	_brush_cd = BRUSH_INTERVAL
	var s := -1.0 if dig else 1.0
	if terrain.apply_brush(target, BRUSH_RADIUS, s, BRUSH_STRENGTH):
		Net.emit_event("terrainEdit", {
			"x": target.x, "y": target.y, "z": target.z,
			"r": BRUSH_RADIUS, "s": s, "st": BRUSH_STRENGTH,
		})


func _aim_point() -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.global_position
	var to := from + (-cam.global_transform.basis.z) * 100.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if hit else null


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
	title.text = "CREATIVE — paint the canyon"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(title)

	var hint := Label.new()
	hint.text = "orange = rock wall (16 m), dark = canyon floor\nleft-drag paints, right-drag erases — in game: Q digs, F fills"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(hint)

	_painter = PixelPainter.new()
	_painter.owner_scene = self
	box.add_child(_painter)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var gen := Button.new()
	gen.text = "GENERATE & PLAY"
	gen.custom_minimum_size = Vector2(0, 40)
	gen.pressed.connect(func(): _start_play(_rows, [], true))
	buttons.add_child(gen)
	var clear := Button.new()
	clear.text = "CLEAR"
	clear.pressed.connect(func():
		_rows = _default_rows()
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


class PixelPainter extends Control:
	const CELL := 14
	var owner_scene: Node
	var _paint_value := -1  # -1 idle, 1 wall, 0 floor

	func _init() -> void:
		custom_minimum_size = Vector2(32 * CELL, 32 * CELL)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
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
		if _paint_value == 1:
			owner_scene._rows[r] = int(owner_scene._rows[r]) | bit
		else:
			owner_scene._rows[r] = int(owner_scene._rows[r]) & ~bit
		owner_scene._on_painted()
		queue_redraw()

	func _draw() -> void:
		for r in 32:
			for c in 32:
				var solid := (int(owner_scene._rows[r]) >> (31 - c)) & 1
				var rect := Rect2(c * CELL, r * CELL, CELL - 1, CELL - 1)
				draw_rect(rect, Color("#c78b5e") if solid else Color("#1a2030"))
