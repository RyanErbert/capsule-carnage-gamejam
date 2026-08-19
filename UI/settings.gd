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
## "spring" is Godot's SpringArm, which casts and PLACES the camera at the hit
## every frame. "legacy" is the web game's: three lerps and one ray, where the
## ray moves the camera's GOAL and the camera eases toward it, so a wall
## appearing or vanishing glides instead of snapping. Local only.
var camera_mode := "spring"
var level := "creative"        # "creative" (default) | "testworld"
## How the window opens. "maximized" fills the screen but keeps its border and
## title bar, which is what you want while building something and reading a
## second window beside it; "fullscreen" takes the display exclusively.
var window_mode := "maximized"   # "maximized" | "windowed" | "fullscreen"
const WINDOW_MODES := ["maximized", "windowed", "fullscreen"]
## Below this the HUD columns start overlapping the scoreboard.
const MIN_WINDOW := Vector2i(1024, 768)

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
	apply_window()


## Enforce the floor and open at the saved size. Headless has no window to set,
## and a probe that tries gets an error per call.
func apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_min_size(MIN_WINDOW)
	match window_mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"windowed":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var got := DisplayServer.window_get_size()
			DisplayServer.window_set_size(Vector2i(maxi(got.x, MIN_WINDOW.x),
				maxi(got.y, MIN_WINDOW.y)))
		_:
			# Maximized, not fullscreen: the whole screen, border kept.
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


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
	camera_mode = "legacy" \
		if str(cfg.get_value("player", "camera", "spring")) == "legacy" else "spring"
	camera_zoom = clampf(float(cfg.get_value("player", "zoom", 4.5)), 2.0, 20.0)
	var saved_win := str(cfg.get_value("player", "window", "maximized"))
	if saved_win in WINDOW_MODES:
		window_mode = saved_win
	var saved_model := str(cfg.get_value("player", "model", ""))
	if saved_model == "bear" or saved_model == "cube":
		model = saved_model


func save_profile() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "color", color_hex())
	cfg.set_value("player", "model", model)
	cfg.set_value("player", "camera", camera_mode)
	cfg.set_value("player", "zoom", camera_zoom)
	cfg.set_value("player", "window", window_mode)
	cfg.save(PROFILE_PATH)


func color_hex() -> String:
	return "#" + color.to_html(false)
