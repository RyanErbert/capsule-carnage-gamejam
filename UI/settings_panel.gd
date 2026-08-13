extends VBoxContainer

## The gamemode's settings, shared by the lobby gear and the Build-mode gear
## in the escape menu. Everything here is server-authoritative except the
## starting weapon, which is per-player: controls emit updateGameSetting and
## the panel re-reads whatever the server broadcasts back.
##
## The server refuses these once a game is live unless the mode is Build.

const Style := preload("res://UI/ui_style.gd")
const Player := preload("res://Player/player.gd")
const CameraRig := preload("res://Player/camera_rig.gd")
const TOGGLES := [
	["infiniteAmmo", "Infinite ammo"],
	["selfAssign", "Creative (spawn items)"],
	["pedestals", "Item pedestals"],
	["monkey", "Monkey ball"],
]
## key, label, and the base constant + unit the scale multiplies — the readout
## next to each slider shows the number the slider actually lands on, so a bad
## feel can be read off the menu instead of guessed at.
const SLIDERS := [
	["speedScale", "Speed", Player.MAX_SPEED, "m/s"],
	["accelScale", "Accel", Player.MOVE_ACCEL, "m/s2"],
	["turnScale", "Turn", Player.TURN_RATE, "/s"],
	["boostScale", "Boost", Player.BOOST_MULT, "x"],
	["jumpScale", "Jump", Player.JUMP_IMPULSE, "m/s"],
	["gravityScale", "Gravity", Player.GRAVITY, "m/s2"],
]

var _checks: Dictionary = {}
var _sliders: Dictionary = {}
var _readouts: Dictionary = {}
var _weapon_btn: OptionButton
var _zoom: HSlider
var _zoom_readout: Label


## Mid-game outside Build mode: only the tuning sliders stay usable — the
## server refuses everything else, so gray it out instead of lying.
func set_tuning_only(on: bool) -> void:
	for key in _checks:
		_checks[key].disabled = on
	if _weapon_btn:
		_weapon_btn.disabled = on


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	for entry in TOGGLES:
		var check := CheckBox.new()
		check.text = entry[1]
		check.focus_mode = Control.FOCUS_NONE
		check.toggled.connect(func(on: bool):
			Net.emit_event("updateGameSetting", {"key": entry[0], "value": on}))
		add_child(check)
		_checks[entry[0]] = check

	var weapon := OptionButton.new()
	_weapon_btn = weapon
	weapon.focus_mode = Control.FOCUS_NONE
	for w in Settings.WEAPONS:
		weapon.add_item("start: " + str(w))
	weapon.select(maxi(0, Settings.WEAPONS.find(Settings.starting_weapon)))
	weapon.item_selected.connect(func(i: int): Settings.starting_weapon = Settings.WEAPONS[i])
	add_child(weapon)

	for entry in SLIDERS:
		var readout := Label.new()
		var slider := _slider_row(entry[1], readout)
		slider.value_changed.connect(func(v: float):
			readout.text = "%.2f  %.1f%s" % [v, v * float(entry[2]), entry[3]])
		slider.drag_ended.connect(func(changed: bool):
			if changed:
				Net.emit_event("updateGameSetting", {"key": entry[0], "value": slider.value}))
		_sliders[entry[0]] = slider
		_readouts[entry[0]] = readout

	# Camera zoom is the one control here that is NOT server-authoritative:
	# it only moves your own chain length, so it never leaves this client.
	_zoom_readout = Label.new()
	_zoom = _slider_row("Zoom", _zoom_readout)
	_zoom.min_value = CameraRig.BASE_CHAIN_MIN
	_zoom.max_value = CameraRig.BASE_CHAIN_MAX
	_zoom.step = 0.5
	_zoom.value_changed.connect(func(v: float):
		Settings.camera_zoom = v
		_zoom_readout.text = "%.1fm" % v)
	_zoom.value = Settings.camera_zoom

	Net.event_received.connect(_on_net_event)
	apply(Net.game_settings)


## [name] [-----slider-----] [value] — the readout is right-aligned so the
## numbers line up in a column down the panel.
func _slider_row(name: String, readout: Label) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = name
	lbl.custom_minimum_size = Vector2(58, 0)
	lbl.add_theme_font_size_override("font_size", 16)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0.1
	slider.max_value = 2.0
	slider.step = 0.01
	slider.custom_minimum_size = Vector2(110, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.focus_mode = Control.FOCUS_NONE
	row.add_child(slider)
	readout.custom_minimum_size = Vector2(96, 0)
	readout.add_theme_font_size_override("font_size", 14)
	readout.add_theme_color_override("font_color", Color("#8ad4ff"))
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(readout)
	add_child(row)
	return slider


func _on_net_event(event: String, data: Variant) -> void:
	if event == "gameSettings":
		apply(data)


func apply(gs: Variant) -> void:
	if not gs is Dictionary:
		return
	for key in _checks:
		_checks[key].set_pressed_no_signal(bool(gs.get(key, false)))
	for entry in SLIDERS:
		var v := clampf(float(gs.get(entry[0], 1.0)), 0.1, 2.0)
		_sliders[entry[0]].set_value_no_signal(v)
		_readouts[entry[0]].text = "%.2f  %.1f%s" % [v, v * float(entry[2]), entry[3]]
