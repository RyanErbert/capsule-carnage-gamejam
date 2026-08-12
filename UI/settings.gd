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
var color := Color("#b5651d")
var model := "bear"            # "bear" | "cube"
var starting_weapon := "rocket"  # default loadout (infinite ammo is on)
var infinite_ammo := false
var movement := "web"          # "web" (Cube Fight physics) | "source" (bhop/air-strafe)
var camera_zoom := 13.0        # chain length, local only (camera_rig.gd)
var level := "creative"        # "creative" (default) | "testworld"


func _ready() -> void:
	# Name defaults to one of the web game's predesignated random names
	# (player_name is already rolled from RANDOM_NAMES above).
	if OS.get_environment("FRIENDSLOP_MODEL").to_lower() == "cube":
		model = "cube"
	if OS.get_environment("FRIENDSLOP_LEVEL") != "":
		level = OS.get_environment("FRIENDSLOP_LEVEL")


func color_hex() -> String:
	return "#" + color.to_html(false)
