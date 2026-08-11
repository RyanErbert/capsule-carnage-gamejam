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
const Style := preload("res://UI/ui_style.gd")
const SettingsPanel := preload("res://UI/settings_panel.gd")

var _status: Label
var _name_edit: LineEdit
var _roster: Label
var _join_btn: Button
var _gamemode_opt: OptionButton
var _settings_box: PanelContainer
var _players: Dictionary = {}   # id -> {name, skinColor, x, y, z}
var _map: LiveMap
var _preview_model: Node3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()
	Net.event_received.connect(_on_net_event)
	Net.socket_connected.connect(_refresh_status)
	Net.socket_disconnected.connect(_refresh_status)
	_apply_game_settings(Net.game_settings)
	_refresh_status()
	if OS.get_environment("FRIENDSLOP_AUTOJOIN") == "1":
		_join.call_deferred()


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"spectatorPlayers":
			if data is Dictionary:
				_players = data.get("players", {})
				_refresh_status()
		"newPlayer":
			if data is Dictionary and data.has("id"):
				_players[str(data["id"])] = data
				_refresh_status()
		"playerDisconnected":
			_players.erase(str(data))
			_refresh_status()
		"playerMoved":
			# Keeps the overhead map live while a game is in progress
			if data is Dictionary and _players.has(str(data.get("id", ""))):
				var p: Dictionary = _players[str(data["id"])]
				p["x"] = data.get("x", 0.0)
				p["z"] = data.get("z", 0.0)
		"gameSettings":
			_apply_game_settings(data)
		"creativeGrid", "gameEnded":
			if _map:
				_map.queue_redraw()


func _apply_game_settings(gs: Variant) -> void:
	if not gs is Dictionary:
		return
	if _gamemode_opt:
		_gamemode_opt.select(maxi(0, MODES.find(str(gs.get("mode", "slayer")))))


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
	# Everyone the server reports is already on the field; you're still here
	var lines: Array = ["%s  -  In Lobby" % my_name]
	for id in _players:
		var p: Dictionary = _players[id]
		lines.append("%s  -  In Game" % str(p.get("name", "???")))
	_roster.text = "\n".join(lines)
	# Nobody in the arena yet: you'd be STARTING the game, not joining one
	_join_btn.text = "START GAME" if _players.is_empty() else "JOIN GAME"


func _join() -> void:
	if not Net.is_socket_connected() and OS.get_environment("FRIENDSLOP_AUTOJOIN") != "1":
		return
	if _name_edit.text.strip_edges() != "":
		Settings.player_name = _name_edit.text.strip_edges().left(16)
	get_tree().change_scene_to_file(LEVELS.get(Settings.level, LEVELS["creative"]))


func _process(_delta: float) -> void:
	if _map and not _players.is_empty():
		_map.queue_redraw()
	if _preview_model:
		_preview_model.rotate_y(_delta * 0.7)


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

	_map = LiveMap.new()
	_map.menu = self
	_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(720, 0)
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
	_name_edit.text_changed.connect(func(_t: String): _refresh_status())
	fields.add_child(_name_edit)
	var color_btn := ColorPickerButton.new()
	color_btn.color = Settings.color
	color_btn.edit_alpha = false
	color_btn.custom_minimum_size = Vector2(0, 28)
	color_btn.color_changed.connect(func(c: Color):
		Settings.color = c
		_build_model_preview())
	fields.add_child(color_btn)
	var model_opt := OptionButton.new()
	model_opt.add_item("Bear (marble)")
	model_opt.add_item("Cube (web classic)")
	model_opt.select(1 if Settings.model == "cube" else 0)
	model_opt.item_selected.connect(func(i: int):
		Settings.model = "cube" if i == 1 else "bear"
		_build_model_preview())
	fields.add_child(model_opt)
	row.add_child(_make_model_viewport())
	_build_model_preview()

	# --- GAMEMODE (server-wide, gear holds the settings) ---
	var settings_col := _panel("GAMEMODE")
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

	_settings_box = PanelContainer.new()
	_settings_box.visible = false
	_settings_box.add_theme_stylebox_override("panel", Style.panel_box(Color(0, 0, 0, 0.3), 8))
	_settings_box.add_child(SettingsPanel.new())
	settings_col.add_child(_settings_box)
	gear.pressed.connect(func(): _settings_box.visible = not _settings_box.visible)

	# --- MAP ---
	var map_box := _panel("MAP")
	grid.add_child(map_box.get_meta("panel"))
	var level_opt := OptionButton.new()
	level_opt.add_item("Canyon Sandbox")
	level_opt.add_item("Testworld")
	level_opt.select(1 if Settings.level == "testworld" else 0)
	level_opt.item_selected.connect(func(i: int): Settings.level = "testworld" if i == 1 else "creative")
	map_box.add_child(level_opt)

	# --- PLAYERS (live roster) ---
	var roster_box := _panel("PLAYERS")
	grid.add_child(roster_box.get_meta("panel"))
	_roster = Label.new()
	_roster.add_theme_font_size_override("font_size", 16)
	roster_box.add_child(_roster)

	_join_btn = Button.new()
	_join_btn.text = "JOIN GAME"
	_join_btn.custom_minimum_size = Vector2(0, 46)
	_join_btn.add_theme_font_size_override("font_size", 16)
	_join_btn.pressed.connect(_join)
	root.add_child(_join_btn)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 16)
	root.add_child(_status)

	# Chat, shared with the map editor and the in-game HUD
	var chat := PanelContainer.new()
	chat.set_script(load("res://UI/chat_box.gd"))
	chat.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat.offset_left = 12
	chat.offset_top = -206
	chat.offset_bottom = -12
	chat.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(chat)

	var build := Label.new()
	build.text = "build " + Net.git_commit()
	build.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	build.add_theme_font_size_override("font_size", 16)
	build.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	root.add_child(build)


# --- Character preview -------------------------------------------------------

var _preview_root: Node3D

## A little turntable of the model you'll actually play as, lit in its own
## world so nothing else in the menu affects it.
func _make_model_viewport() -> SubViewportContainer:
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
	_preview_model.add_child(model)
	# Fit whatever the model's native scale is into the viewport
	var box: AABB = preload("res://Vehicles/vehicle.gd")._model_aabb(model)
	if box.size.y > 0.001:
		var s := 1.3 / box.size.y
		model.scale = Vector3.ONE * s
		var c := box.get_center() * s
		model.position = Vector3(-c.x, 0.45 - c.y, -c.z)


# --- Live overhead map -------------------------------------------------------

class LiveMap extends Control:
	## Top-down view of the map currently being played, drawn straight from
	## the painted layer stack the server broadcast, with a dot per player.
	const LAYER_TINT := [Color("#8a5a3a"), Color("#c78b5e"), Color("#dfa878"), Color("#f0cb96")]
	var menu: Node

	func _draw() -> void:
		var grid: Variant = Net.creative_grid
		if not (grid is Dictionary) or not (grid.get("layers") is Array):
			return
		var layers: Array = grid["layers"]
		if layers.size() != 4:
			return
		var span := minf(size.x, size.y) * 0.92
		var cell := span / 32.0
		var origin := (size - Vector2(span, span)) / 2.0
		for r in 32:
			for c in 32:
				var top := -1
				for li in 4:
					if (int(layers[li][r]) >> (31 - c)) & 1:
						top = li
				if top < 0:
					continue
				var col: Color = LAYER_TINT[top]
				col.a = 0.16 + 0.06 * top
				draw_rect(Rect2(origin + Vector2(c, r) * cell, Vector2(cell, cell)), col)
		# Players, in their own colors
		for id in menu._players:
			var p: Dictionary = menu._players[id]
			var px := (float(p.get("x", 0.0)) + 64.0) / 128.0
			var pz := (float(p.get("z", 0.0)) + 64.0) / 128.0
			if px < 0.0 or px > 1.0 or pz < 0.0 or pz > 1.0:
				continue
			var dot := origin + Vector2(px, pz) * span
			var col := Color(str(p.get("skinColor", "#ffffff")))
			col.a = 0.85
			draw_circle(dot, maxf(3.0, cell * 0.4), col)
