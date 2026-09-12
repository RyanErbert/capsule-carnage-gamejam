extends Node3D

## The campaign world: co-op, persistent, hand-built.
##
## The level is a Blender export at res://Campaign/world.glb. Everything the
## game needs to know about it is carried by the NAMES of empties in that file:
##
##   Spawn               where players arrive (and respawn)
##   NPC_<name>          a character; talks from res://Campaign/dialogue/<name>.json
##   QuestBoard          the board
##   Crate_<anything>    a loot crate (the whole name is its id)
##   Checkpoint_<Name>   a quest target; standing on it reports "Checkpoint_<Name>"
##
## Meshes named with the -col suffix get collision on import, the usual Godot
## way. One Blender unit is one metre; the player ball is 0.79 m across.
##
## Until that file exists (or if it goes missing) the same markers are laid
## out by _greybox() so the systems can be played today: a plaza with the
## greeter, a shop and a quest board, a pillar climb to a summit checkpoint,
## and a field of crates and trees out east with the hermit's hollow beyond.

## Where the world may live, first found wins. FRIENDSLOP_WORLD overrides
## (handy for trying an export without moving it). Until a real campaign
## world exists the deathmatch arena stands in for it.
const WORLD_PATHS := ["res://Campaign/world.glb", "res://maps/deathmatch.glb"]
const KILL_Y := -30.0
const PlayerScene := preload("res://Player/player.tscn")
const HudScene := preload("res://UI/game_hud.tscn")
const Npc := preload("res://Campaign/npc.gd")
const Crate := preload("res://Campaign/loot_crate.gd")
const Checkpoint := preload("res://Campaign/checkpoint.gd")
const QuestBoard := preload("res://Campaign/quest_board.gd")
const Interactor := preload("res://Campaign/interactor.gd")
const Lava := preload("res://Campaign/lava.gd")

var player: CharacterBody3D
var _spawn := Vector3(0, 2, 0)
var _respawn := Vector3.INF     # last checkpoint touched; INF = the spawn
var _markers: Array = []   # Node3D, by name


func _ready() -> void:
	_environment()
	var world: Node3D
	var path := _world_path()
	if path != "":
		var packed: PackedScene = load(path)
		world = packed.instantiate()
		world.name = "World"
		print("[campaign] world from %s" % path)
	else:
		world = _greybox()
	add_child(world)
	if path != "":
		_ensure_collision(world)
	_collect_markers(world)
	var spawned := false
	for m in _markers:
		if (m as Node3D).name.begins_with("Spawn"):
			_spawn = (m as Node3D).global_position + Vector3(0, 1.0, 0)
			spawned = true
			break
	if not spawned and path != "":
		# No Spawn empty yet: land on top of whatever is at the origin
		_spawn = Vector3(0, _top_at(Vector3.ZERO) + 1.0, 0)
	_spawn_gameplay()
	var has_npcs := false
	for m in _markers:
		if (m as Node3D).name.begins_with("NPC_"):
			has_npcs = true
			break
	_place_lava(world)
	if has_npcs:
		_place_from_markers()
	else:
		# A map with no campaign markers (the deathmatch arena, say): furnish
		# it around the spawn once the colliders are live to be rayed against.
		await get_tree().physics_frame
		await get_tree().physics_frame
		_improvise(world)
		_place_from_markers()
	Net.event_received.connect(_on_net_event)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _world_path() -> String:
	var forced := OS.get_environment("FRIENDSLOP_WORLD")
	if forced != "" and ResourceLoader.exists(forced):
		return forced
	for p in WORLD_PATHS:
		if ResourceLoader.exists(p):
			return p
	return ""


## An export with no -col suffixes anywhere still has to be walkable: every
## mesh that has no collision under it gets a trimesh body. Meshes the author
## DID mark are left alone (Godot already built theirs on import).
func _ensure_collision(root: Node) -> void:
	var any_body := false
	for n in _all(root):
		if n is StaticBody3D:
			any_body = true
			break
	if any_body:
		return
	for mi in _meshes(root):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		col.shape = m.mesh.create_trimesh_shape()
		body.add_child(col)
		m.add_child(body)


## Height of the highest surface under a point, or 0 with nothing there.
func _top_at(p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 200, 0), p + Vector3(0, -200, 0))
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return float(hit["position"].y) if hit else 0.0


static func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out


## Lava surfaces: meshes named Lava* without a -col suffix. Each gets a
## watcher that sends a dipped ball back to its last checkpoint.
func _place_lava(world: Node3D) -> void:
	for mi in _meshes(world):
		var n: String = (mi as MeshInstance3D).name
		if n.begins_with("Lava") and not n.ends_with("-col"):
			var lava := Lava.new()
			lava.mesh = mi
			lava.player = player
			add_child(lava)


## Where a burnt or fallen player comes back: the last checkpoint, else spawn.
func respawn_pos() -> Vector3:
	return _respawn if _respawn != Vector3.INF else _spawn


## A checkpoint ring was stood on (Campaign/checkpoint.gd tells us).
func checkpoint_reached(at: Vector3) -> void:
	_respawn = at + Vector3(0, 1.0, 0)


## Into the lava: a flash and back to the checkpoint. Not a death; no coins
## are lost, and the quest to reach the summit stays on.
func burn(at: Vector3) -> void:
	if player == null:
		return
	Sfx.bomb(at)
	var proj: Node = get_node_or_null("WorldProjectiles")
	if proj and proj.has_method("_explosion_vfx"):
		proj._explosion_vfx(at, false)
	player.global_position = respawn_pos()
	player.velocity = Vector3.ZERO
	player.launched(0.3)


func _collect_markers(root: Node) -> void:
	for child in root.get_children():
		if child is Node3D:
			var n: String = child.name
			if n.begins_with("Spawn") or n.begins_with("NPC_") or n.begins_with("Crate_") \
					or n.begins_with("Checkpoint_") or n.begins_with("QuestBoard"):
				_markers.append(child)
		_collect_markers(child)


## Every marker becomes the thing it names. Blender may suffix duplicates
## (".001"): the id keeps the suffix, the kind ignores it.
func _place_from_markers() -> void:
	for m in _markers:
		var node := m as Node3D
		var n: String = node.name
		var at := node.global_transform
		if n.begins_with("NPC_"):
			var key := n.substr(4).get_slice(".", 0).to_lower()
			var npc := Npc.new()
			npc.npc_key = key
			add_child(npc)
			npc.global_transform = at
			npc.player = player
		elif n.begins_with("Crate_"):
			var crate := Crate.new()
			crate.crate_id = n
			add_child(crate)
			crate.global_transform = at
		elif n.begins_with("Checkpoint_"):
			var cp := Checkpoint.new()
			cp.target = n.get_slice(".", 0)
			cp.player = player
			add_child(cp)
			cp.global_transform = at
		elif n.begins_with("QuestBoard"):
			var qb := QuestBoard.new()
			add_child(qb)
			qb.global_transform = at


## Campaign furniture for a map that only has arena markers: the plaza set
## (greeter, merchant, warden, board) fans out around the spawn, every item
## pedestal spot gets a crate, the summit checkpoint sits on the highest
## ground in the middle and the hollow on the pedestal furthest from spawn.
func _improvise(world: Node3D) -> void:
	var peds: Array = []
	for m in _markers:
		if (m as Node3D).name.begins_with("Pedestal_"):
			peds.append((m as Node3D).global_position)
	var here := Vector3(_spawn.x, 0, _spawn.z)
	var to_centre := (Vector3.ZERO - here)
	to_centre.y = 0.0
	var fwd := to_centre.normalized() if to_centre.length() > 0.1 else Vector3.FORWARD
	var right := fwd.cross(Vector3.UP)
	var set := {
		"NPC_greeter": here + fwd * 4.0 + right * 1.5,
		"NPC_merchant": here - right * 7.0 + fwd * 1.0,
		"NPC_warden": here + right * 7.0 + fwd * 1.0,
		"QuestBoard": here + right * 9.5 - fwd * 1.0,
	}
	for k in set:
		var p: Vector3 = set[k]
		_marker(world, k, Vector3(p.x, _top_at(p), p.z))
	for i in peds.size():
		var p: Vector3 = peds[i]
		_marker(world, "Crate_%d" % (i + 1), Vector3(p.x, _top_at(p), p.z))
	# Summit: the highest surface within 20 m of the map centre
	var best := Vector3(0, -INF, 0)
	for gx in range(-20, 21, 5):
		for gz in range(-20, 21, 5):
			var top := _top_at(Vector3(gx, 0, gz))
			if top > best.y:
				best = Vector3(gx, top, gz)
	if best.y > -INF:
		_marker(world, "Checkpoint_Summit", best)
	var far := here
	var far_d := -1.0
	for p in peds:
		var d: float = Vector2(p.x - here.x, p.z - here.z).length()
		if d > far_d:
			far_d = d
			far = p
	if far_d > 0.0:
		_marker(world, "Checkpoint_Hollow", Vector3(far.x, _top_at(far), far.z))
		var hp := far + (here - far).normalized() * 5.0
		_marker(world, "NPC_hermit", Vector3(hp.x, _top_at(hp), hp.z))
	_markers = []
	_collect_markers(world)


func _spawn_gameplay() -> void:
	player = PlayerScene.instantiate()
	player.name = "player"
	player.spawn_points = [_spawn]
	player.respawn_provider = respawn_pos
	player.position = _spawn
	add_child(player)

	var sync := Node.new()
	sync.name = "MultiplayerSync"
	sync.set_script(load("res://Net/multiplayer_sync.gd"))
	sync.player = player
	add_child(sync)

	var items := Node3D.new()
	items.name = "WorldItems"
	items.set_script(load("res://Items/world_items.gd"))
	items.player = player
	add_child(items)

	var proj := Node3D.new()
	proj.name = "WorldProjectiles"
	proj.set_script(load("res://Items/projectiles.gd"))
	proj.player = player
	add_child(proj)

	var generators := Node3D.new()
	generators.name = "WorldGenerators"
	generators.set_script(load("res://Items/generators.gd"))
	generators.player = player
	add_child(generators)

	var critters := Node3D.new()
	critters.name = "WorldCritters"
	critters.set_script(load("res://Items/critters.gd"))
	critters.player = player
	add_child(critters)

	# Before the HUD, so its ESC (close the panel) is seen before the HUD's
	# ESC (open the menu)
	var inter := Interactor.new()
	inter.name = "Interactor"
	inter.player = player
	add_child(inter)

	var hud := HudScene.instantiate()
	hud.sync_node = sync
	add_child(hud)


func _physics_process(_delta: float) -> void:
	# Off the edge of the world: back to the last checkpoint, no death
	if player and not player.dead and player.global_position.y < KILL_Y:
		player.global_position = respawn_pos()
		player.velocity = Vector3.ZERO


func _on_net_event(event: String, _data: Variant) -> void:
	if event == "gameEnded" or event == "kicked":
		get_tree().change_scene_to_file("res://UI/main_menu.tscn")


func _environment() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.36, 0.55, 0.85)
	mat.sky_horizon_color = Color(0.78, 0.82, 0.88)
	mat.ground_bottom_color = Color(0.25, 0.22, 0.2)
	mat.ground_horizon_color = Color(0.6, 0.58, 0.55)
	sky.sky_material = mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.8
	e.fog_enabled = true
	e.fog_density = 0.0012
	e.fog_light_color = Color(0.7, 0.75, 0.85)
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.glow_enabled = true
	e.glow_intensity = 0.35
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	add_child(sun)


# --- The stand-in world ---------------------------------------------------

const SAND := Color(0.66, 0.6, 0.48)
const STONE := Color(0.55, 0.55, 0.58)
const WOOD := Color(0.5, 0.36, 0.22)
const ROCK := Color(0.42, 0.4, 0.4)

func _greybox() -> Node3D:
	var root := Node3D.new()
	root.name = "World"
	_slab(root, Vector3(0, -1, 0), Vector3(260, 2, 260), SAND)                 # the ground
	_disc(root, Vector3(0, 0.15, 0), 15.0, 0.3, STONE)                         # plaza
	_marker(root, "Spawn", Vector3(0, 0.3, 5))
	_marker(root, "NPC_greeter", Vector3(3.5, 0.3, -3))

	# Shop: a counter under a canopy, west side of the plaza
	_slab(root, Vector3(-17, 0.6, 5), Vector3(4.0, 1.2, 1.1), WOOD)
	for dx: float in [-2.0, 2.0]:
		for dz: float in [-1.6, 1.6]:
			_slab(root, Vector3(-17 + dx, 1.6, 5 + dz), Vector3(0.2, 3.2, 0.2), WOOD)
	_slab(root, Vector3(-17, 3.3, 5), Vector3(5.0, 0.15, 4.2), Color(0.75, 0.3, 0.25))
	_marker(root, "NPC_merchant", Vector3(-17, 0.0, 3.6))

	# Quest board and its keeper, east side
	_marker(root, "QuestBoard", Vector3(17, 0.0, 4))
	_marker(root, "NPC_warden", Vector3(14.5, 0.0, 7))

	# Pillar climb north: ten steps rising to a summit stone
	var y := 1.0
	var z := -22.0
	for i in 10:
		var x := sin(i * 1.7) * 4.0
		_slab(root, Vector3(x, y * 0.5, z), Vector3(3.2, y, 3.2), STONE)
		z -= 5.4 + i * 0.15
		y += 1.15
	_slab(root, Vector3(0, y * 0.5, z - 3.0), Vector3(10, y, 10), STONE)
	_marker(root, "Checkpoint_Summit", Vector3(0, y, z - 3.0))

	# The field east: trees, a couple of buildings, crates
	var tree: PackedScene = load("res://Models/tree_1.glb")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 26:
		var p := Vector3(rng.randf_range(32, 118), 0, rng.randf_range(-75, 45))
		if p.distance_to(Vector3(100, 0, -58)) < 14.0:
			continue
		_model(root, tree, p, rng.randf_range(0.9, 1.4), rng.randf() * TAU)
	_model(root, load("res://Models/building_2.glb"), Vector3(52, 0, 22), 1.0, 0.4)
	_model(root, load("res://Models/building_4.glb"), Vector3(84, 0, 30), 1.0, -1.2)
	_model(root, load("res://Models/cactus.glb"), Vector3(66, 0, -30), 1.2, 0.0)
	var crate_spots := [Vector3(40, 0, -8), Vector3(58, 0, 8), Vector3(70, 0, -22),
		Vector3(88, 0, 12), Vector3(96, 0, -30), Vector3(110, 0, 2), Vector3(48, 0, 34)]
	for i in crate_spots.size():
		_marker(root, "Crate_%d" % (i + 1), crate_spots[i])

	# The hermit's hollow: a ring of rock with the checkpoint inside
	for i in 9:
		var a := TAU * i / 9.0
		if i == 4:
			continue   # the way in
		var at := Vector3(100, 0, -58) + Vector3(cos(a), 0, sin(a)) * 9.0
		_pillar(root, at, rng.randf_range(1.2, 2.0), rng.randf_range(4.0, 7.5), ROCK)
	_marker(root, "Checkpoint_Hollow", Vector3(100, 0, -58))
	_marker(root, "NPC_hermit", Vector3(94, 0, -50))
	return root


func _marker(root: Node3D, mname: String, at: Vector3) -> void:
	var m := Node3D.new()
	m.name = mname
	m.position = at
	root.add_child(m)


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m


func _slab(root: Node3D, at: Vector3, size: Vector3, c: Color) -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat(c)
	mi.mesh = bm
	body.add_child(mi)
	body.position = at
	root.add_child(body)


func _disc(root: Node3D, at: Vector3, radius: float, height: float, c: Color) -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	col.shape = cyl
	body.add_child(col)
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 40
	cm.material = _mat(c)
	mi.mesh = cm
	body.add_child(mi)
	body.position = at
	root.add_child(body)


func _pillar(root: Node3D, at: Vector3, radius: float, height: float, c: Color) -> void:
	_disc(root, at + Vector3(0, height * 0.5, 0), radius, height, c)


func _model(root: Node3D, packed: PackedScene, at: Vector3, s: float, ry: float) -> void:
	var inst := packed.instantiate()
	root.add_child(inst)
	inst.position = at
	inst.scale = Vector3.ONE * s
	inst.rotation.y = ry
	# Trimesh collision on every mesh, the way the props do it
	for mi in _meshes(inst):
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		col.shape = (mi as MeshInstance3D).mesh.create_trimesh_shape()
		body.add_child(col)
		mi.add_child(body)


static func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
