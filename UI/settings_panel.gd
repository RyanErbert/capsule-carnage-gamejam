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
## key, label, the base constant + unit the scale multiplies, then the range and
## whether the slider runs backwards. The readout shows the number the slider
## actually lands on, so a bad feel can be read off the menu instead of guessed.
##
## Every slider used to share one 0.1-2.0 range, which put the tuned defaults
## hard against the right-hand end -- boost sat at 1.93 of 2.0 with nowhere left
## to go. Each has its own range now, chosen so the default lands around a third
## of the way along: room to push, and the useless bottom end trimmed off.
##
## Gravity is inverted, because the slider should read as the thing you want.
## Pushing it up makes you lighter.
const SLIDERS := [
	["speedScale", "Speed", Player.MAX_SPEED, "m/s", 0.4, 3.0, false],
	["accelScale", "Accel", Player.MOVE_ACCEL, "m/s2", 0.5, 3.5, false],
	["turnScale", "Turn", Player.TURN_RATE, "/s", 0.2, 2.5, false],
	["boostScale", "Boost", Player.BOOST_MULT, "x", 1.0, 4.0, false],
	["jumpScale", "Jump", Player.JUMP_IMPULSE, "m/s", 0.2, 1.5, false],
	["gravityScale", "Gravity", Player.GRAVITY, "m/s2", 0.15, 1.6, true],
]


## An inverted slider shows one number and means the other; the two are
## reflections about the middle of the range, so the mapping is its own inverse.
static func _flip(entry: Array, v: float) -> float:
	return (float(entry[4]) + float(entry[5]) - v) if bool(entry[6]) else v

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
		slider.min_value = float(entry[4])
		slider.max_value = float(entry[5])
		slider.value_changed.connect(func(v: float):
			var scale := _flip(entry, v)
			readout.text = "%.2f  %.1f%s" % [scale, scale * float(entry[2]), entry[3]])
		slider.drag_ended.connect(func(changed: bool):
			if changed:
				Net.emit_event("updateGameSetting",
					{"key": entry[0], "value": _flip(entry, slider.value)}))
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

	# Camera model. Local only, like zoom: which one you look through is yours.
	var cam_btn := OptionButton.new()
	cam_btn.focus_mode = Control.FOCUS_NONE
	cam_btn.add_item("camera: spring")
	cam_btn.add_item("camera: legacy")
	cam_btn.select(1 if Settings.camera_mode == "legacy" else 0)
	cam_btn.item_selected.connect(func(i: int):
		Settings.camera_mode = "legacy" if i == 1 else "spring"
		Settings.save_profile())
	add_child(cam_btn)

	# How the window opens. Maximized keeps the border, which is the difference
	# between filling the screen and taking it over.
	var win_btn := OptionButton.new()
	win_btn.focus_mode = Control.FOCUS_NONE
	for m in Settings.WINDOW_MODES:
		win_btn.add_item("window: " + m)
	win_btn.select(maxi(0, Settings.WINDOW_MODES.find(Settings.window_mode)))
	win_btn.item_selected.connect(func(i: int):
		Settings.window_mode = str(Settings.WINDOW_MODES[i])
		Settings.apply_window()
		Settings.save_profile())
	add_child(win_btn)

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
		# The server speaks in scales; the slider may show its reflection.
		var scale := clampf(float(gs.get(entry[0], 1.0)),
			float(entry[4]), float(entry[5]))
		_sliders[entry[0]].set_value_no_signal(_flip(entry, scale))
		_readouts[entry[0]].text = "%.2f  %.1f%s" % [
			scale, scale * float(entry[2]), entry[3]]
