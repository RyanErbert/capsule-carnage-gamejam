extends Control

## Main menu / lobby (web §6.1, trimmed to what the Godot game supports):
## name, color, character (bear/cube), starting weapon, infinite ammo, JOIN.
## Map select is omitted — the Godot game plays the TrenchBroom testworld.
## FRIENDSLOP_AUTOJOIN=1 skips straight into the game (headless testing).

const GAME_SCENE := "res://Scenes/testworld.tscn"

var _status: Label
var _players_label: Label
var _name_edit: LineEdit
var _player_count := 0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()
	Net.event_received.connect(_on_net_event)
	Net.socket_connected.connect(_refresh_status)
	Net.socket_disconnected.connect(_refresh_status)
	_refresh_status()
	if OS.get_environment("FRIENDSLOP_AUTOJOIN") == "1":
		_join.call_deferred()


func _on_net_event(event: String, data: Variant) -> void:
	if event == "spectatorPlayers" and data is Dictionary:
		_player_count = (data.get("players", {}) as Dictionary).size()
		_refresh_status()
	elif event == "newPlayer":
		_player_count += 1
		_refresh_status()
	elif event == "playerDisconnected":
		_player_count = maxi(0, _player_count - 1)
		_refresh_status()


func _refresh_status() -> void:
	if _status == null:
		return
	if Net.is_socket_connected():
		_status.text = "server: connected"
		_status.add_theme_color_override("font_color", Color("#7dedb0"))
	else:
		_status.text = "server: connecting... (free tier wakes in ~60 s)"
		_status.add_theme_color_override("font_color", Color("#ff8080"))
	_players_label.text = "%d player%s in game" % [_player_count, "" if _player_count == 1 else "s"]


func _join() -> void:
	if _name_edit.text.strip_edges() != "":
		Settings.player_name = _name_edit.text.strip_edges().left(16)
	get_tree().change_scene_to_file(GAME_SCENE)


# --- UI (code-built) -------------------------------------------------------

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#0c0e12")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#12151c")
	style.border_color = Color("#ffd54a")
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "CAPSULE CARNAGE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "reverse tag — hold the oddball, dodge everyone"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	box.add_child(subtitle)

	box.add_child(_row_label("NAME"))
	_name_edit = LineEdit.new()
	_name_edit.text = Settings.player_name
	_name_edit.max_length = 16
	box.add_child(_name_edit)

	box.add_child(_row_label("COLOR"))
	var color_btn := ColorPickerButton.new()
	color_btn.color = Settings.color
	color_btn.edit_alpha = false
	color_btn.custom_minimum_size = Vector2(0, 30)
	color_btn.color_changed.connect(func(c: Color): Settings.color = c)
	box.add_child(color_btn)

	box.add_child(_row_label("CHARACTER"))
	var model_opt := OptionButton.new()
	model_opt.add_item("Bear (marble)")
	model_opt.add_item("Cube (web classic)")
	model_opt.select(1 if Settings.model == "cube" else 0)
	model_opt.item_selected.connect(func(i: int): Settings.model = "cube" if i == 1 else "bear")
	box.add_child(model_opt)

	box.add_child(_row_label("STARTING WEAPON"))
	var weapon_opt := OptionButton.new()
	for w in Settings.WEAPONS:
		weapon_opt.add_item(w)
	weapon_opt.select(Settings.WEAPONS.find(Settings.starting_weapon))
	weapon_opt.item_selected.connect(func(i: int): Settings.starting_weapon = Settings.WEAPONS[i])
	box.add_child(weapon_opt)

	var ammo_check := CheckBox.new()
	ammo_check.text = "infinite ammo"
	ammo_check.button_pressed = Settings.infinite_ammo
	ammo_check.toggled.connect(func(on: bool): Settings.infinite_ammo = on)
	box.add_child(ammo_check)

	var join := Button.new()
	join.text = "JOIN GAME"
	join.custom_minimum_size = Vector2(0, 44)
	join.add_theme_font_size_override("font_size", 18)
	join.pressed.connect(_join)
	box.add_child(join)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	box.add_child(_status)
	_players_label = Label.new()
	_players_label.add_theme_font_size_override("font_size", 12)
	_players_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	box.add_child(_players_label)

	var build := Label.new()
	build.text = "build " + Net.git_commit()
	build.add_theme_font_size_override("font_size", 11)
	build.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	box.add_child(build)


func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	return l
