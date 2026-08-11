extends VBoxContainer

## The gamemode's settings, shared by the lobby gear and the Build-mode gear
## in the escape menu. Everything here is server-authoritative except the
## starting weapon, which is per-player: controls emit updateGameSetting and
## the panel re-reads whatever the server broadcasts back.
##
## The server refuses these once a game is live unless the mode is Build.

const Style := preload("res://UI/ui_style.gd")
const TOGGLES := [
	["infiniteAmmo", "Infinite ammo"],
	["selfAssign", "Creative (spawn items)"],
	["pedestals", "Item pedestals"],
]
const SLIDERS := [["speedScale", "Speed"], ["jumpScale", "Jump"], ["gravityScale", "Gravity"]]

var _checks: Dictionary = {}
var _sliders: Dictionary = {}
var _weapon_btn: OptionButton


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
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lbl := Label.new()
		lbl.text = entry[1]
		lbl.custom_minimum_size = Vector2(58, 0)
		lbl.add_theme_font_size_override("font_size", 16)
		row.add_child(lbl)
		var slider := HSlider.new()
		slider.min_value = 0.1
		slider.max_value = 2.0
		slider.step = 0.01
		slider.custom_minimum_size = Vector2(120, 0)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.focus_mode = Control.FOCUS_NONE
		slider.drag_ended.connect(func(changed: bool):
			if changed:
				Net.emit_event("updateGameSetting", {"key": entry[0], "value": slider.value}))
		row.add_child(slider)
		add_child(row)
		_sliders[entry[0]] = slider

	Net.event_received.connect(_on_net_event)
	apply(Net.game_settings)


func _on_net_event(event: String, data: Variant) -> void:
	if event == "gameSettings":
		apply(data)


func apply(gs: Variant) -> void:
	if not gs is Dictionary:
		return
	for key in _checks:
		_checks[key].set_pressed_no_signal(bool(gs.get(key, false)))
	for key in _sliders:
		_sliders[key].set_value_no_signal(clampf(float(gs.get(key, 1.0)), 0.1, 2.0))
