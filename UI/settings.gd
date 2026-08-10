extends Node

## Player/lobby settings chosen in the main menu (web §6.1), read by
## multiplayer_sync (ready payload), player.gd (model), and item_controller
## (starting weapon / infinite ammo). Autoload: Settings.

const RANDOM_NAMES := ["Blockhead", "Squarold", "Edgelord", "Hexahedron", "Rhombert", "Squaredward"]
const WEAPONS := ["none", "machinegun", "rocket", "mines", "grapple"]
# Starting-weapon ammo (web game.js:3908) — richer than pedestal pickups
const STARTING_AMMO := {"machinegun": 100, "rocket": 3, "mines": 3, "grapple": 5}

var player_name: String = RANDOM_NAMES[randi() % RANDOM_NAMES.size()]
var color := Color("#b5651d")
var model := "bear"            # "bear" | "cube"
var starting_weapon := "none"
var infinite_ammo := false


func _ready() -> void:
	var env_name := OS.get_environment("USERNAME")
	if env_name != "":
		player_name = env_name.left(16)
	if OS.get_environment("FRIENDSLOP_MODEL").to_lower() == "cube":
		model = "cube"


func color_hex() -> String:
	return "#" + color.to_html(false)
