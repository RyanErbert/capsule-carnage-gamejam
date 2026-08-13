extends Node

## Player/lobby settings chosen in the main menu (web §6.1), read by
## multiplayer_sync (ready payload), player.gd (model), and item_controller
## (starting weapon / infinite ammo). Autoload: Settings.

const RANDOM_NAMES := ["Blockhead", "Squarold", "Edgelord", "Hexahedron", "Rhombert", "Squaredward"]
const WEAPONS := ["none", "machinegun", "rocket", "mines", "grapple", "terragun"]
# Starting-weapon ammo (web game.js:3908) — richer than pedestal pickups.
# The terraformer isn't ammo-driven: its number is a charge cell that refills
# itself out of your health (Items/terra_gun.gd), so it starts full.
const STARTING_AMMO := {"machinegun": 100, "rocket": 3, "mines": 3, "grapple": 5, "terragun": 100}

var player_name: String = RANDOM_NAMES[randi() % RANDOM_NAMES.size()]
# Same saturation and brightness as the old fixed orange, random hue: two
# people opening the game are a different colour without touching the picker.
const DEFAULT_COLOR := Color("#b5651d")
var color := Color.from_hsv(randf(), DEFAULT_COLOR.s, DEFAULT_COLOR.v)
var model := "bear"            # "bear" | "cube"
var starting_weapon := "rocket"  # default loadout (infinite ammo is on)
var infinite_ammo := false
var movement := "web"          # "web" (Cube Fight physics) | "source" (bhop/air-strafe)
var camera_zoom := 4.5         # chain length, local only (camera_rig.gd)
var level := "creative"        # "creative" (default) | "testworld"

## Who you are, kept between launches so the lobby opens on the name and colour
## you already picked instead of a fresh random one.
const PROFILE_PATH := "user://profile.cfg"


func _ready() -> void:
	# Name defaults to one of the web game's predesignated random names
	# (player_name is already rolled from RANDOM_NAMES above) until a saved
	# profile overrides it.
	_load_profile()
	if OS.get_environment("FRIENDSLOP_MODEL").to_lower() == "cube":
		model = "cube"
	if OS.get_environment("FRIENDSLOP_LEVEL") != "":
		level = OS.get_environment("FRIENDSLOP_LEVEL")


func _load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) != OK:
		return
	var saved := str(cfg.get_value("player", "name", "")).strip_edges().left(16)
	if saved != "":
		player_name = saved
	var hex := str(cfg.get_value("player", "color", ""))
	if hex != "" and Color.html_is_valid(hex):
		color = Color.html(hex)
	var saved_model := str(cfg.get_value("player", "model", ""))
	if saved_model == "bear" or saved_model == "cube":
		model = saved_model


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "color", color_hex())
	cfg.set_value("player", "model", model)
	cfg.save(PROFILE_PATH)


func color_hex() -> String:
	return "#" + color.to_html(false)
