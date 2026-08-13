extends Control

## Main menu / lobby, laid out like the web version's 2x2 lobby (§6.1):
## PLAYER | GAMEMODE on top, MAP | PLAYERS below, JOIN underneath. Gamemode
## settings live behind the gear and are server-authoritative — the server
## freezes them once a game is running (except in Build mode).
##
## While a game is live the background is a top-down view of the map being
## played, with everyone's position on it.

const LEVELS := {
	"testworld": "res://Scenes/testworld.tscn",
	"creative": "res://Scenes/creative.tscn",
}
const MODES := ["slayer", "sandbox", "build"]
const MODE_NAMES := ["Slayer", "Sandbox", "Build"]
# Per-axis map size, mirroring the server's GRID_SIZES (pixels are 4 m)
const GRID_SIZES := [24, 32, 40, 48, 56, 64, 80, 96]
# Generator passes, mirroring server/mapgen.js SCHEMES
const SCHEMES := ["plateaus", "canyons", "spires", "tunnels", "cellars",
	"craters", "causeways"]
const Style := preload("res://UI/ui_style.gd")
const SettingsPanel := preload("res://UI/settings_panel.gd")

var _status: Label
var _name_edit: LineEdit
var _roster: Label
var _join_btn: Button
var _gamemode_opt: OptionButton
var _w_opt: OptionButton
var _h_opt: OptionButton
var _scheme_boxes: Dictionary = {}   # scheme -> CheckBox
var _sub_box: CheckBox
var _settings_box: PanelContainer
var _map_box: PanelContainer
var _presence: Array = []       # everyone connected: {id, name, color, where}
var _map: BirdseyeMap
var _preview_model: Node3D
var _countdown: Label            # shared 5 s pre-editor countdown
var _countdown_left := 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()
	Net.event_received.connect(_on_net_event)
	Net.socket_connected.connect(_refresh_status)
	Net.socket_disconnected.connect(_refresh_status)
	_apply_game_settings(Net.game_settings)
	_presence = Net.presence.duplicate()
	_refresh_status()
	# Tell the server who we are before we're a "player": the roster and every
	# chat line we send in the lobby hang off this.
	_send_profile()
	# Sitting in the lobby means we are NOT in a game. Without this the server
	# still counts us as a live player after a round, and the next START gets
	# treated as "join the session already in progress" — which dropped you
	# straight into the old map with no editor at all.
	Net.emit_event("leaveGame")
	if OS.get_environment("FRIENDSLOP_AUTOJOIN") == "1":
		_join.call_deferred()


func _send_profile() -> void:
	if _name_edit and _name_edit.text.strip_edges() != "":
		Settings.player_name = _name_edit.text.strip_edges().left(16)
	Net.emit_event("profile", {
		"name": Settings.player_name, "skinColor": Settings.color_hex()})


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"presence":
			_presence = data if data is Array else []
			_refresh_status()
		"gameSettings":
			_apply_game_settings(data)
		"startCountdown":
			# Every lobby counts the same countdown down together
			if data is Dictionary:
				_countdown_left = float(data.get("ms", 3000)) / 1000.0
				_countdown.text = str(ceili(_countdown_left))
				_countdown.visible = true
				_join_btn.disabled = true
		"enterEditor":
			get_tree().change_scene_to_file(LEVELS["creative"])


func _apply_game_settings(gs: Variant) -> void:
	if not gs is Dictionary:
		return
	if _gamemode_opt:
		_gamemode_opt.select(maxi(0, MODES.find(str(gs.get("mode", "slayer")))))
	if _w_opt:
		_w_opt.select(maxi(0, GRID_SIZES.find(int(gs.get("gridW", 32)))))
	if _h_opt:
		_h_opt.select(maxi(0, GRID_SIZES.find(int(gs.get("gridH", 32)))))
	var gen: Array = gs.get("gen", []) if gs.get("gen") is Array else []
	for key in _scheme_boxes:
		(_scheme_boxes[key] as CheckBox).set_pressed_no_signal(key in gen)
	if _sub_box:
		_sub_box.set_pressed_no_signal(bool(gs.get("subterranean", false)))


func _refresh_status() -> void:
	if _status == null:
		return
	if Net.is_socket_connected():
		_status.text = "● server connected"
		_status.add_theme_color_override("font_color", Color("#7dedb0"))
	else:
		_status.text = "● disconnected - retrying"
		_status.add_theme_color_override("font_color", Color("#ff8080"))
	_join_btn.disabled = not Net.is_socket_connected()
	var my_name := Settings.player_name
	if _name_edit and _name_edit.text.strip_edges() != "":
		my_name = _name_edit.text.strip_edges().left(16)
	# The server reports EVERYONE connected and where they are, so a second
	# player sitting in this same menu shows up here too.
	const WHERE := {"game": "In Game", "editor": "Editing", "lobby": "In Lobby"}
	var lines: Array = []
	var live := false
	for row in _presence:
		if not row is Dictionary:
			continue
		var id := str(row.get("id", ""))
		var where := str(row.get("where", "lobby"))
		live = live or where != "lobby"
		lines.append("%s  -  %s" % [
			my_name if id == Net.socket_id else str(row.get("name", "???")),
			WHERE.get(where, "In Lobby")])
	if lines.is_empty():
		lines.append("%s  -  In Lobby" % my_name)
	_roster.text = "\n".join(lines)
	# Nobody in the arena or the editor yet: you'd be STARTING, not joining
	_join_btn.text = "JOIN GAME" if live else "START GAME"


func _join() -> void:
	if not Net.is_socket_connected() and OS.get_environment("FRIENDSLOP_AUTOJOIN") != "1":
		return
	if _name_edit.text.strip_edges() != "":
		Settings.player_name = _name_edit.text.strip_edges().left(16)
	# STARTING a creative session goes through the server's shared countdown so
	# every lobby lands in the editor together. Joining one in motion is direct.
	# The server makes the same call itself and answers with 'enterEditor'.
	if Settings.level == "creative" \
			and OS.get_environment("FRIENDSLOP_AUTOJOIN") != "1":
		Net.emit_event("requestStart")
		return
	get_tree().change_scene_to_file(LEVELS.get(Settings.level, LEVELS["creative"]))


func _process(_delta: float) -> void:
	if _map:
		_map.tick(_delta)
	if _preview_model:
		_preview_model.rotate_y(_delta * 0.7)
	if _countdown_left > 0.0:
		_countdown_left -= _delta
		_countdown.text = str(maxi(1, ceili(_countdown_left)))
		if _countdown_left <= 0.0:
			_countdown.visible = false  # 'enterEditor' arrives right about now


# --- UI --------------------------------------------------------------------

func _panel(title: String) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", Style.panel_box(Color("#12151c"), 14))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	p.add_child(box)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 16)
	t.add_theme_color_override("font_color", Style.ACCENT)
	box.add_child(t)
	box.set_meta("panel", p)
	return box


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#0c0e12")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_map = BirdseyeMap.new()
	_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map)
	# Scrim over the 3D view so the panels stay readable on top of it
	var scrim := ColorRect.new()
	scrim.color = Color(0.047, 0.055, 0.071, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(860, 0)
	root.add_theme_constant_override("separation", 12)
	center.add_child(root)

	var title := Label.new()
	title.text = "CAPSULE CARNAGE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Style.ACCENT)
	title.add_theme_color_override("font_shadow_color", Color(0.9, 0.3, 0.1, 0.7))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	root.add_child(grid)

	# --- PLAYER ---
	var player_box := _panel("PLAYER")
	grid.add_child(player_box.get_meta("panel"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	player_box.add_child(row)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 8)
	row.add_child(fields)
	_name_edit = LineEdit.new()
	_name_edit.text = Settings.player_name
	_name_edit.max_length = 16
	_name_edit.text_changed.connect(func(_t: String):
		_refresh_status()
		_send_profile())
	fields.add_child(_name_edit)
	var model_opt := OptionButton.new()
	model_opt.add_item("Bear")
	model_opt.add_item("Cube")
	model_opt.select(1 if Settings.model == "cube" else 0)
	model_opt.item_selected.connect(func(i: int):
		Settings.model = "cube" if i == 1 else "bear"
		_build_model_preview())
	fields.add_child(model_opt)
	row.add_child(_make_model_viewport())
	_build_model_preview()

	# --- GAME (mode + map + size in one panel; gear holds the settings) ---
	var settings_col := _panel("GAME")
	grid.add_child(settings_col.get_meta("panel"))
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	settings_col.add_child(mode_row)
	_gamemode_opt = OptionButton.new()
	_gamemode_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for n in MODE_NAMES:
		_gamemode_opt.add_item(n)
	_gamemode_opt.select(maxi(0, MODES.find(str(Net.game_settings.get("mode", "slayer")))))
	_gamemode_opt.item_selected.connect(func(i: int):
		Net.emit_event("updateGameSetting", {"key": "mode", "value": MODES[i]}))
	mode_row.add_child(_gamemode_opt)
	var gear := Button.new()
	gear.text = "⚙"
	gear.focus_mode = Control.FOCUS_NONE
	gear.custom_minimum_size = Vector2(34, 0)
	mode_row.add_child(gear)

	# The level, with its own gear for how the map itself is rolled
	var level_row := HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 6)
	settings_col.add_child(level_row)
	var level_opt := OptionButton.new()
	level_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	level_opt.add_item("Canyon Sandbox")
	level_opt.add_item("Testworld")
	level_opt.select(1 if Settings.level == "testworld" else 0)
	level_opt.item_selected.connect(func(i: int): Settings.level = "testworld" if i == 1 else "creative")
	level_row.add_child(level_opt)
	var map_gear := Button.new()
	map_gear.text = "⚙"
	map_gear.focus_mode = Control.FOCUS_NONE
	map_gear.custom_minimum_size = Vector2(34, 0)
	level_row.add_child(map_gear)
	_map_box = _build_map_settings()
	settings_col.add_child(_map_box)
	map_gear.pressed.connect(func(): _map_box.visible = not _map_box.visible)

	_settings_box = PanelContainer.new()
	_settings_box.visible = false
	_settings_box.add_theme_stylebox_override("panel", Style.panel_box(Color(0, 0, 0, 0.3), 8))
	_settings_box.add_child(SettingsPanel.new())
	settings_col.add_child(_settings_box)
	gear.pressed.connect(func(): _settings_box.visible = not _settings_box.visible)

	# --- Bottom row: chat on the left, roster + JOIN + status on the right ---
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	root.add_child(bottom)

	# Chat docked into the lobby, shared with the editor and HUD
	var chat := PanelContainer.new()
	chat.set_script(load("res://UI/chat_box.gd"))
	chat.custom_minimum_size = Vector2(0, 190)
	chat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(chat)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(320, 0)
	right.add_theme_constant_override("separation", 8)
	bottom.add_child(right)

	var roster_box := _panel("PLAYERS")
	right.add_child(roster_box.get_meta("panel"))
	_roster = Label.new()
	_roster.add_theme_font_size_override("font_size", 16)
	roster_box.add_child(_roster)

	_join_btn = Button.new()
	_join_btn.text = "JOIN GAME"
	_join_btn.custom_minimum_size = Vector2(0, 46)
	_join_btn.add_theme_font_size_override("font_size", 16)
	_join_btn.pressed.connect(_join)
	right.add_child(_join_btn)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 16)
	right.add_child(_status)

	# Big shared countdown before everyone is dropped into the editor
	_countdown = Label.new()
	_countdown.visible = false
	_countdown.set_anchors_preset(Control.PRESET_CENTER)
	_countdown.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_countdown.grow_vertical = Control.GROW_DIRECTION_BOTH
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.add_theme_font_size_override("font_size", 120)
	_countdown.add_theme_color_override("font_color", Style.ACCENT)
	_countdown.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_countdown.add_theme_constant_override("shadow_offset_x", 4)
	_countdown.add_theme_constant_override("shadow_offset_y", 4)
	add_child(_countdown)

	var build := Label.new()
	build.text = "build " + Net.git_commit()
	build.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	build.add_theme_font_size_override("font_size", 16)
	build.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	root.add_child(build)


# --- Map settings (behind the gear beside the level) --------------------------

## Size per axis, which generator passes run, and whether the whole arena is
## sunk into the ground. All server-wide, like the gamemode.
func _build_map_settings() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.visible = false
	panel.add_theme_stylebox_override("panel", Style.panel_box(Color(0, 0, 0, 0.3), 8))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 6)
	box.add_child(size_row)
	_w_opt = _size_dropdown("gridW", int(Net.game_settings.get("gridW", 32)))
	size_row.add_child(_w_opt)
	var by := Label.new()
	by.text = "x"
	by.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	size_row.add_child(by)
	_h_opt = _size_dropdown("gridH", int(Net.game_settings.get("gridH", 32)))
	size_row.add_child(_h_opt)

	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	var live: Array = Net.game_settings.get("gen", SCHEMES) if Net.game_settings.get("gen") is Array else SCHEMES
	for scheme in SCHEMES:
		var cb := CheckBox.new()
		cb.text = scheme
		cb.focus_mode = Control.FOCUS_NONE
		cb.set_pressed_no_signal(scheme in live)
		cb.toggled.connect(func(_on: bool): _send_schemes())
		grid.add_child(cb)
		_scheme_boxes[scheme] = cb

	_sub_box = CheckBox.new()
	_sub_box.text = "subterranean"
	_sub_box.focus_mode = Control.FOCUS_NONE
	_sub_box.set_pressed_no_signal(bool(Net.game_settings.get("subterranean", false)))
	_sub_box.toggled.connect(func(on: bool):
		Net.emit_event("updateGameSetting", {"key": "subterranean", "value": on}))
	box.add_child(_sub_box)
	return panel


func _size_dropdown(key: String, value: int) -> OptionButton:
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in GRID_SIZES:
		opt.add_item(str(s))
	opt.select(maxi(0, GRID_SIZES.find(value)))
	opt.item_selected.connect(func(i: int):
		Net.emit_event("updateGameSetting", {"key": key, "value": GRID_SIZES[i]}))
	return opt


func _send_schemes() -> void:
	var want: Array = []
	for scheme in SCHEMES:
		if (_scheme_boxes[scheme] as CheckBox).button_pressed:
			want.append(scheme)
	Net.emit_event("updateGameSetting", {"key": "gen", "value": want})


# --- Character preview -------------------------------------------------------

var _preview_root: Node3D

## A little turntable of the marble you'll actually play as, lit in its own
## world so nothing else in the menu affects it. A palette sits over its top
## left corner: that, or the ball itself, opens the colour picker.
func _make_model_viewport() -> Control:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(120, 120)
	var vc := _make_turntable()
	vc.set_anchors_preset(Control.PRESET_FULL_RECT)
	wrap.add_child(vc)
	vc.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_open_color_picker())
	var palette := PaletteIcon.new()
	palette.custom_minimum_size = Vector2(26, 26)
	palette.size = Vector2(26, 26)
	palette.position = Vector2(2, 2)
	palette.tooltip_text = ""
	palette.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_open_color_picker())
	wrap.add_child(palette)
	return wrap


var _color_popup: PopupPanel

func _open_color_picker() -> void:
	if _color_popup == null:
		_color_popup = PopupPanel.new()
		var picker := ColorPicker.new()
		picker.color = Settings.color
		picker.edit_alpha = false
		picker.color_changed.connect(func(c: Color):
			Settings.color = c
			_send_profile()
			if _preview_shell:
				_preview_shell.set_color(c)
			if _preview_model and _preview_model.has_method("set_color"):
				_preview_model.set_color(c))
		_color_popup.add_child(picker)
		add_child(_color_popup)
	_color_popup.popup_centered()


func _make_turntable() -> SubViewportContainer:
	var vc := SubViewportContainer.new()
	vc.custom_minimum_size = Vector2(120, 120)
	vc.stretch = true
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.size = Vector2i(120, 120)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vc.add_child(vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.5, 2.6)
	cam.rotation_degrees = Vector3(-8, 0, 0)
	cam.fov = 45.0
	vp.add_child(cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 35, 0)
	key.light_energy = 1.4
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, -140, 0)
	fill.light_energy = 0.5
	vp.add_child(fill)
	_preview_root = Node3D.new()
	vp.add_child(_preview_root)
	return vc


var _preview_shell: Node3D

func _build_model_preview() -> void:
	if _preview_root == null:
		return
	if _preview_model:
		_preview_model.queue_free()
	_preview_model = Node3D.new()
	_preview_root.add_child(_preview_model)
	var model: Node3D
	if Settings.model == "cube":
		model = preload("res://Player/roundcube_visual.tscn").instantiate()
		model.set_color.call_deferred(Settings.color)
	else:
		model = preload("res://Player/PL_bear.glb").instantiate()
	# You play as a character riding inside a glass marble, so that's what the
	# menu shows. Scaled up to fill the viewport, and tipped so the two-tone
	# seam is visible while it turns.
	_preview_shell = load("res://Player/marble_shell.gd").new()
	_preview_shell.set_color(Settings.color)
	_preview_shell.hold(model, 0.8)
	_preview_shell.scale = Vector3.ONE * 1.7
	_preview_shell.position = Vector3(0, 0.45, 0)
	_preview_shell.rotation = Vector3(0.32, 0, 0.16)
	_preview_model.add_child(_preview_shell)


## A painter's palette, drawn rather than imported: a rounded board with a
## thumb hole and four dabs of colour. Click it (or the ball) to recolour.
class PaletteIcon extends Control:
	const DABS := [Color("#ff5a4a"), Color("#ffd54a"), Color("#7dedb0"), Color("#7fb2ff")]

	func _draw() -> void:
		var r: float = size.x * 0.5
		var mid := Vector2(r, r)
		draw_circle(mid, r, Color("#3a2b1e"))
		draw_circle(mid, r - 1.5, Color("#c8a06a"))
		draw_circle(mid + Vector2(r * 0.34, r * 0.42), r * 0.19, Color("#3a2b1e"))
		for i in DABS.size():
			var a: float = PI * (0.82 + i * 0.42)
			draw_circle(mid + Vector2(cos(a), sin(a)) * r * 0.55, r * 0.17, DABS[i])


# --- Live overhead map -------------------------------------------------------

class BirdseyeMap extends SubViewportContainer:
	## A real 3D birdseye view of the map behind the lobby: the painted layer
	## stack extruded into blocks in its own little world, slowly orbiting.
	## Rebuilt whenever the grid changes.
	# Bottom up: basement, ground, main, +1, +2 (mirrors the painter's chips)
	const LAYER_TINT := [Color("#4a3226"), Color("#8a5a3a"), Color("#c78b5e"),
		Color("#dfa878"), Color("#f0cb96")]
	const LAYERS := 5
	const SLAB := 8.0

	var _vp: SubViewport
	var _cam: Camera3D
	var _world: Node3D
	var _blocks: MultiMeshInstance3D
	var _built := ""               # signature of the grid we rendered
	var _orbit := 0.0
	var _span := 128.0

	func _init() -> void:
		stretch = true
		_vp = SubViewport.new()
		_vp.own_world_3d = true
		_vp.transparent_bg = false
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(_vp)
		_world = Node3D.new()
		_vp.add_child(_world)
		var env := WorldEnvironment.new()
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color("#0c0e12")
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.5, 0.55, 0.68)
		e.ambient_light_energy = 0.7
		e.fog_enabled = true
		e.fog_light_color = Color("#0c0e12")
		e.fog_density = 0.006
		env.environment = e
		_world.add_child(env)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-58, -34, 0)
		sun.light_energy = 1.1
		sun.light_color = Color(1.0, 0.94, 0.84)
		_world.add_child(sun)
		_cam = Camera3D.new()
		_cam.fov = 58.0
		_world.add_child(_cam)
		_blocks = MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var box := BoxMesh.new()
		box.size = Vector3(4.0, SLAB, 4.0)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.95
		box.material = mat
		mm.mesh = box
		_blocks.multimesh = mm
		_world.add_child(_blocks)

	func tick(delta: float) -> void:
		if _vp.size != Vector2i(size):
			_vp.size = Vector2i(size)
		_rebuild_if_needed()
		_orbit += delta * 0.05
		# Slow high orbit, steep enough to read as a birdseye view
		var r := _span * 0.7
		_cam.position = Vector3(cos(_orbit) * r, _span * 1.05, sin(_orbit) * r)
		_cam.look_at(Vector3(0, 0, 0))

	## Extrude the painted grid into one MultiMesh of slab blocks (top layer
	## per pixel only — the stack below is hidden anyway from up here).
	func _rebuild_if_needed() -> void:
		var grid: Variant = Net.creative_grid
		var sig := str(grid).md5_text() if grid is Dictionary else "empty"
		if sig == _built:
			return
		_built = sig
		var live := grid is Dictionary and (grid.get("layers") is Array) \
			and (grid["layers"] as Array).size() == LAYERS
		var layers: Array = grid["layers"] if live else []
		var raw: Variant = grid.get("gs", [32, 32]) if live else [32, 32]
		var gw := int(raw[0]) if raw is Array else 32
		var gh := int(raw[1]) if raw is Array else 32
		var words := (gw + 31) >> 5
		_span = maxf(gw, gh) * 4.0
		# No map yet: a seeded idle skyline so the lobby is never an empty void
		var idle := RandomNumberGenerator.new()
		idle.seed = 20260811
		var xforms: Array = []
		var cols: Array = []
		for r in gh:
			for c in gw:
				var top := -1
				if live:
					var wi := r * words + (c >> 5)
					for li in LAYERS:
						if wi < (layers[li] as Array).size() \
								and (int(layers[li][wi]) >> (31 - (c & 31))) & 1:
							top = li
				else:
					# Rolling mounds: ground everywhere, occasional stacks
					var n := sin(r * 0.31) * cos(c * 0.27) + idle.randf() * 0.55
					top = 0 if n < 0.75 else (1 if n < 1.05 else 2)
				if top < 0:
					continue
				var x := -gw * 2.0 + c * 4.0 + 2.0
				var z := -gh * 2.0 + r * 4.0 + 2.0
				xforms.append(Transform3D(Basis(), Vector3(x, top * SLAB - SLAB * 0.5, z)))
				cols.append(LAYER_TINT[top])
		var mm := _blocks.multimesh
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
			mm.set_instance_color(i, cols[i])

	## Deliberately no player markers. The lobby watches the map being built,
	## which is half the fun of sitting one out, but where everybody IS while
	## they build it is not the lobby's business.
