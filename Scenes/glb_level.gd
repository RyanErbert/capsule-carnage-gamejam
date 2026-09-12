extends Node3D

## A hand-built level (a Blender glb in res://maps/) played with the full
## Slayer / Reverse Tag stack: same player, weapons, builds, vehicles, cores
## and HUD as the canyon, on geometry somebody modelled instead of painted.
##
## Which file: Settings.level is "glb:<name>" for res://maps/<name>.glb. The
## file's empties name the spawns ("Spawn_1"...) and the item pedestals
## ("Pedestal_red_1", "Pedestal_green_2"); see Campaign/glb_world.gd.
##
## Pedestals are server objects. The first player into an empty map plants
## them from the markers, once, so a late joiner never doubles them up.

const KILL_Y := -40.0
const GlbWorld := preload("res://Campaign/glb_world.gd")
const PlayerScene := preload("res://Player/player.tscn")
const HudScene := preload("res://UI/game_hud.tscn")

var player: CharacterBody3D
var _spawns: Array = []          # Vector3
var _pedestal_marks: Array = []  # {pos, type}
var _sync: Node
var _planted := false


func _ready() -> void:
	_environment()
	var name := str(Settings.level).trim_prefix("glb:")
	var path := GlbWorld.pick(["res://maps/%s.glb" % name])
	var world: Node3D
	if path == "":
		push_warning("[glb_level] no map at res://maps/%s.glb; standing on a slab" % name)
		world = _slab()
	else:
		world = GlbWorld.instantiate(path)
	add_child(world)
	if path != "":
		GlbWorld.ensure_collision(world)
	var marks := GlbWorld.markers(world)
	for m in GlbWorld.of_kind(marks, "Spawn"):
		_spawns.append((m as Node3D).global_position + Vector3(0, 0.6, 0))
	for m in GlbWorld.of_kind(marks, "Pedestal_"):
		var kind := GlbWorld.base_name(m).get_slice("_", 1)
		_pedestal_marks.append({"pos": (m as Node3D).global_position,
			"type": kind if kind in ["red", "green", "yellow"] else "red"})
	if _spawns.is_empty():
		_spawns.append(Vector3(0, 2.0, 0))
	_spawn_gameplay()
	Net.event_received.connect(_on_net_event)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _spawn_gameplay() -> void:
	player = PlayerScene.instantiate()
	player.name = "player"
	player.spawn_points = _spawns
	player.position = _spawns.pick_random()
	add_child(player)

	_sync = Node.new()
	_sync.name = "MultiplayerSync"
	_sync.set_script(load("res://Net/multiplayer_sync.gd"))
	_sync.player = player
	add_child(_sync)

	for entry in [
		["WorldItems", "res://Items/world_items.gd", true],
		["WorldProjectiles", "res://Items/projectiles.gd", true],
		["WorldBuilds", "res://Items/builds.gd", false],
		["WorldProps", "res://Items/props.gd", false],
		["WorldCastles", "res://Items/castle.gd", false],
		["WorldParametrics", "res://Items/parametrics.gd", false],
		["WorldVehicles", "res://Vehicles/world_vehicles.gd", true],
		["WorldGenerators", "res://Items/generators.gd", true],
		["WorldTurrets", "res://Items/turrets.gd", true],
		["WorldCritters", "res://Items/critters.gd", true],
	]:
		var n := Node3D.new()
		n.name = entry[0]
		n.set_script(load(entry[1]))
		if entry[2]:
			n.set("player", player)
		add_child(n)

	var hud := HudScene.instantiate()
	hud.sync_node = _sync
	add_child(hud)


func _physics_process(_delta: float) -> void:
	if player and not player.dead and player.global_position.y < KILL_Y:
		player.global_position = _spawns.pick_random()
		player.velocity = Vector3.ZERO


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentPedestals":
			# Alone in an empty map: the markers become the pedestals
			if not _planted and data is Array and (data as Array).is_empty() \
					and _sync and _sync.remotes().is_empty():
				_planted = true
				for pm in _pedestal_marks:
					var p: Vector3 = pm["pos"]
					Net.emit_event("placePedestal", {"x": p.x, "y": p.y, "z": p.z, "ry": 0.0, "type": pm["type"]})
		"gameEnded", "kicked":
			get_tree().change_scene_to_file("res://UI/main_menu.tscn")


func _environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.3, 0.45, 0.72)
	mat.sky_horizon_color = Color(0.72, 0.74, 0.8)
	mat.ground_bottom_color = Color(0.2, 0.18, 0.17)
	mat.ground_horizon_color = Color(0.5, 0.48, 0.46)
	sky.sky_material = mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.75
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.glow_enabled = true
	e.glow_intensity = 0.3
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 28, 0)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	add_child(sun)


## Nothing to load: a slab so the scene is at least standable.
func _slab() -> Node3D:
	var root := Node3D.new()
	root.name = "World"
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 2, 80)
	col.shape = box
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	body.add_child(mi)
	body.position.y = -1.0
	root.add_child(body)
	return root
