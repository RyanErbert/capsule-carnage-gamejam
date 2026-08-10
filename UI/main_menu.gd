extends Control

## Main menu / lobby, laid out like the web version's 2x2 lobby (§6.1):
## PLAYER | GAME SETTINGS on top, MAP | PLAYERS below, JOIN underneath.
## Game settings are server-authoritative — edits broadcast to everyone and
## the server announces who changed what. The PLAYERS panel is the live
## roster, so the lobby feels multiplayer before you even join.

const LEVELS := {
	"testworld": "res://Scenes/testworld.tscn",
	"creative": "res://Scenes/creative.tscn",
}
const GAME_TOGGLES := [
	["infiniteAmmo", "Infinite ammo"],
	["selfAssign", "Players can self-assign items"],
	["allowMidgameChanges", "Allow setting changes mid-game"],
]

var _status: Label
var _name_edit: LineEdit
var _roster: Label
var _join_btn: Button
var _toggle_checks: Dictionary = {}
var _players: Dictionary = {}   # id -> {name, skinColor}
var _scores: Dictionary = {}


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
				_scores = data.get("scores", {})
				_refresh_status()
		"newPlayer":
			if data is Dictionary and data.has("id"):
				_players[str(data["id"])] = data
				_refresh_status()
		"playerDisconnected":
			_players.erase(str(data))
			_refresh_status()
		"scores":
			if data is Dictionary:
				_scores = data
				_refresh_status()
		"gameSettings":
			_apply_game_settings(data)


func _apply_game_settings(gs: Variant) -> void:
	if not gs is Dictionary:
		return
	for key in _toggle_checks:
		_toggle_checks[key].set_pressed_no_signal(bool(gs.get(key, false)))


func _refresh_status() -> void:
	if _status == null:
		return
	if Net.is_socket_connected():
		_status.text = "● server connected"
		_status.add_theme_color_override("font_color", Color("#7dedb0"))
	else:
		_status.text = "● disconnected — retrying... (free tier wakes in ~60 s)"
		_status.add_theme_color_override("font_color", Color("#ff8080"))
	_join_btn.disabled = not Net.is_socket_connected()
	var lines: Array = []
	for id in _players:
		var p: Dictionary = _players[id]
		lines.append("%s — %d" % [str(p.get("name", "???")), int(_scores.get(id, 0))])
	_roster.text = "\n".join(lines) if lines.size() > 0 else "nobody in the arena yet"


func _join() -> void:
	if not Net.is_socket_connected() and OS.get_environment("FRIENDSLOP_AUTOJOIN") != "1":
		return
	if _name_edit.text.strip_edges() != "":
		Settings.player_name = _name_edit.text.strip_edges().left(16)
	get_tree().change_scene_to_file(LEVELS.get(Settings.level, LEVELS["creative"]))


# --- UI --------------------------------------------------------------------

func _panel(title: String) -> VBoxContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#12151c")
	style.border_color = Color("#2a3040")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	p.add_theme_stylebox_override("panel", style)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	p.add_child(box)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 13)
	t.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(t)
	box.set_meta("panel", p)
	return box


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#0c0e12")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(720, 0)
	root.add_theme_constant_override("separation", 12)
	center.add_child(root)

	# Web lobby look: pixel title in 04B_03 with a drop shadow
	var title := Label.new()
	title.text = "CAPSULE CARNAGE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var pixel_font: FontFile = load("res://UI/fonts/04B_03__.TTF")
	if pixel_font:
		title.add_theme_font_override("font", pixel_font)
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Color("#ffd54a"))
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
	_name_edit = LineEdit.new()
	_name_edit.text = Settings.player_name
	_name_edit.max_length = 16
	player_box.add_child(_name_edit)
	var color_btn := ColorPickerButton.new()
	color_btn.color = Settings.color
	color_btn.edit_alpha = false
	color_btn.custom_minimum_size = Vector2(0, 28)
	color_btn.color_changed.connect(func(c: Color): Settings.color = c)
	player_box.add_child(color_btn)
	var model_opt := OptionButton.new()
	model_opt.add_item("Bear (marble)")
	model_opt.add_item("Cube (web classic)")
	model_opt.select(1 if Settings.model == "cube" else 0)
	model_opt.item_selected.connect(func(i: int): Settings.model = "cube" if i == 1 else "bear")
	player_box.add_child(model_opt)

	# --- GAME SETTINGS (server-wide) ---
	var settings_box := _panel("GAME SETTINGS (everyone)")
	grid.add_child(settings_box.get_meta("panel"))
	for entry in GAME_TOGGLES:
		var check := CheckBox.new()
		check.text = entry[1]
		check.toggled.connect(func(on: bool): Net.emit_event("updateGameSetting", {"key": entry[0], "value": on}))
		settings_box.add_child(check)
		_toggle_checks[entry[0]] = check
	var weapon_opt := OptionButton.new()
	for w in Settings.WEAPONS:
		weapon_opt.add_item("start: " + str(w))
	weapon_opt.select(Settings.WEAPONS.find(Settings.starting_weapon))
	weapon_opt.item_selected.connect(func(i: int): Settings.starting_weapon = Settings.WEAPONS[i])
	settings_box.add_child(weapon_opt)

	# --- MAP ---
	var map_box := _panel("MAP")
	grid.add_child(map_box.get_meta("panel"))
	var level_opt := OptionButton.new()
	level_opt.add_item("Canyon Sandbox")
	level_opt.add_item("Testworld")
	level_opt.select(1 if Settings.level == "testworld" else 0)
	level_opt.item_selected.connect(func(i: int): Settings.level = "testworld" if i == 1 else "creative")
	map_box.add_child(level_opt)
	var map_hint := Label.new()
	map_hint.text = "Canyon Sandbox: paint a map together,\nthen dig, build, and fight in it."
	map_hint.add_theme_font_size_override("font_size", 11)
	map_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	map_box.add_child(map_hint)

	# --- PLAYERS (live roster) ---
	var roster_box := _panel("PLAYERS")
	grid.add_child(roster_box.get_meta("panel"))
	_roster = Label.new()
	_roster.add_theme_font_size_override("font_size", 13)
	roster_box.add_child(_roster)

	_join_btn = Button.new()
	_join_btn.text = "JOIN GAME"
	_join_btn.custom_minimum_size = Vector2(0, 46)
	_join_btn.add_theme_font_size_override("font_size", 18)
	_join_btn.pressed.connect(_join)
	root.add_child(_join_btn)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 12)
	root.add_child(_status)

	var build := Label.new()
	build.text = "build " + Net.git_commit()
	build.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	build.add_theme_font_size_override("font_size", 11)
	build.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	root.add_child(build)
