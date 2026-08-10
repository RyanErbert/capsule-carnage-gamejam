extends Node

## Inventory + item use, child of the player (PORT_BLUEPRINT.md §1.8, §4.6–4.8).
## Web rules: 3 slots, slot 0 is active, left click uses it, 2/3 swap slots.
## Green items implemented here; weapons/builds (red/yellow) land in phases 5/6.

signal inventory_changed(items: Array)

const MAX_INVENTORY := 3
# Ammo granted on pedestal pickup (web game.js:4050). Missing = 0 = single use.
const PICKUP_AMMO := {"machinegun": 100, "rocket": 3, "bridge_gun": 3, "wall": 3, "ramp": 3, "platform": 3}
const GRAPPLE_SPEED := 40.0
const PLACE_RANGE := 10.0   # pads/mines must be placed within 10 u (web)
const AIM_RANGE := 200.0
# Weapons (web §5.1–5.3)
const MG_INTERVAL := 0.08       # 12.5 rounds/s
const MG_SPEED := 200.0
const MG_SPREAD := 0.04         # (rand-0.5)*0.04 per axis
const ROCKET_SPEED := 60.0
const ROCKET_COOLDOWN := 2.0

var inventory: Array = []   # of {type: String, ammo: int}
var is_grappling := false
var grapple_target := Vector3.ZERO
var pending_teleporter: Variant = null  # first click position, or null

@onready var player: CharacterBody3D = get_parent()

var _grapple_line: MeshInstance3D
var _sync: Node
var _mg_firing := false
var _mg_timer := 0.0
var _rocket_cd := 0.0


func _ready() -> void:
	Net.event_received.connect(_on_net_event)
	# Lobby starting weapon (web menu: none/machinegun/rocket/mines/grapple)
	var weapon: String = Settings.starting_weapon
	if weapon != "none" and weapon != "":
		inventory.append({"type": weapon, "ammo": int(Settings.STARTING_AMMO.get(weapon, 0))})
		inventory_changed.emit.call_deferred(inventory)
	_grapple_line = MeshInstance3D.new()
	_grapple_line.top_level = true
	_grapple_line.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 1.0, 0.3)
	_grapple_line.material_override = mat
	add_child(_grapple_line)


func _on_net_event(event: String, data: Variant) -> void:
	if event == "itemPickedUp":
		var item := str(data)
		if inventory.size() < MAX_INVENTORY and item != "":
			inventory.append({"type": item, "ammo": int(PICKUP_AMMO.get(item, 0))})
			print("[items] picked up %s — inventory: %s" % [item, inventory])
			inventory_changed.emit(inventory)
	elif event == "gameEnded" or event == "kicked":
		inventory.clear()
		is_grappling = false
		pending_teleporter = null
		inventory_changed.emit(inventory)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_mg_firing = false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or player.godmode:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Web: mousedown starts the machinegun loop; anything else is consumeItem()
		if not inventory.is_empty() and inventory[0]["type"] == "machinegun":
			_mg_firing = true
			_mg_timer = 0.0
		else:
			use_item()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_2:
			swap_to_first(1)
		elif event.keycode == KEY_3:
			swap_to_first(2)


func swap_to_first(index: int) -> void:
	if index <= 0 or index >= inventory.size():
		return
	var tmp = inventory[0]
	inventory[0] = inventory[index]
	inventory[index] = tmp
	inventory_changed.emit(inventory)


## Web consumeItem(): dispatch on the active slot's item type.
func use_item() -> void:
	if inventory.is_empty():
		return
	var item: String = inventory[0]["type"]
	var target: Variant = _aim_point()
	match item:
		"grapple":
			if target == null:
				return
			grapple_target = target
			is_grappling = true
			Sfx.boost(player.global_position, 0.8)
			_use_ammo()
		"launch_pad", "boost_pad", "mines":
			if target == null or player.global_position.distance_to(target) > PLACE_RANGE:
				return
			if item == "mines":
				Net.emit_event("placeMine", {"x": target.x, "y": target.y, "z": target.z})
			else:
				var cam := get_viewport().get_camera_3d()
				var dir := -cam.global_transform.basis.z
				dir.y = 0.0
				dir = dir.normalized()
				Net.emit_event("placePad", {
					"x": target.x, "y": target.y, "z": target.z,
					"type": item, "dx": dir.x, "dz": dir.z,
				})
			_shift_inventory()  # web quirk: mines consume the whole item, ammo ignored
		"teleporter":
			if target == null:
				return
			if pending_teleporter == null:
				pending_teleporter = target  # first click: ghost, no consume
				return
			Net.emit_event("placeTeleporter", {
				"a": {"x": pending_teleporter.x, "y": pending_teleporter.y, "z": pending_teleporter.z},
				"b": {"x": target.x, "y": target.y, "z": target.z},
			})
			pending_teleporter = null
			_shift_inventory()
		"block", "wall", "ramp", "platform":
			var builds := get_parent().get_node_or_null("BuildController")
			if builds:
				builds.try_place()
		"bridge_gun":
			var bridge := get_parent().get_node_or_null("BuildController")
			if bridge:
				bridge.fire_bridge_gun()
		"rocket":
			if _rocket_cd > 0.0:
				return
			var fire_dir := _aim_direction()
			var origin := player.global_position + Vector3(0, 0.4, 0)
			var start := origin + fire_dir * 2.5
			Net.emit_event("fireRocket", {
				"start": {"x": start.x, "y": start.y, "z": start.z},
				"velocity": {"x": fire_dir.x * ROCKET_SPEED, "y": fire_dir.y * ROCKET_SPEED, "z": fire_dir.z * ROCKET_SPEED},
			})
			_rocket_cd = ROCKET_COOLDOWN
			_use_ammo()
		_:
			print("[items] unknown item '%s'" % item)


## Web getAimDirection: aim at the level hit if it's beyond 15 u, else at a
## point 150 u out; direction taken from the player's chest (+0.4 Y).
func _aim_direction() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	var origin := player.global_position + Vector3(0, 0.4, 0)
	if cam == null:
		return -player.global_transform.basis.z
	var cam_dir := -cam.global_transform.basis.z
	var aim_point := cam.global_position + cam_dir * 150.0
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, aim_point)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit and cam.global_position.distance_to(hit["position"]) > 15.0:
		aim_point = hit["position"]
	return (aim_point - origin).normalized()


## Web findLockOnTarget: nearest remote within a 3 u cylinder along the aim
## ray, projected distance 2..80.
func _lock_on_target(origin: Vector3, aim_dir: Vector3) -> Variant:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	if _sync == null:
		return null
	var best: Variant = null
	var best_dist := INF
	for id in _sync.remotes():
		var remote_pos: Vector3 = _sync.remotes()[id].global_position
		var to_player := remote_pos - origin
		var proj := to_player.dot(aim_dir)
		if proj < 2.0 or proj > 80.0:
			continue
		var perp := (origin + aim_dir * proj).distance_to(remote_pos)
		if perp < 3.0 and proj < best_dist:
			best_dist = proj
			best = remote_pos
	return best


func _fire_machinegun_shot() -> void:
	var origin := player.global_position + Vector3(0, 0.4, 0)
	var dir := _aim_direction()
	var lock: Variant = _lock_on_target(origin, dir)
	if lock != null:
		dir = (lock - origin).normalized()
	dir += Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * MG_SPREAD
	dir = dir.normalized()
	var start := origin + dir * 2.0
	Net.emit_event("fireMachinegun", {
		"start": {"x": start.x, "y": start.y, "z": start.z},
		"velocity": {"x": dir.x * MG_SPEED, "y": dir.y * MG_SPEED, "z": dir.z * MG_SPEED},
	})
	if Settings.infinite_ammo:
		return
	inventory[0]["ammo"] = int(inventory[0]["ammo"]) - 1
	if int(inventory[0]["ammo"]) <= 0:
		_mg_firing = false
		_shift_inventory()
	else:
		inventory_changed.emit(inventory)


## Raycast from the camera center (mouse is captured; web used mouse NDC).
func _aim_point() -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.global_position
	var to := from + (-cam.global_transform.basis.z) * AIM_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if hit else null


func _use_ammo() -> void:
	if Settings.infinite_ammo:
		return
	inventory[0]["ammo"] = int(inventory[0]["ammo"]) - 1
	if int(inventory[0]["ammo"]) <= 0:
		_shift_inventory()
	else:
		inventory_changed.emit(inventory)


func _shift_inventory() -> void:
	if inventory.is_empty():
		return
	var item = inventory.pop_front()
	print("[items] consumed %s" % item["type"])
	inventory_changed.emit(inventory)


func _process(delta: float) -> void:
	_rocket_cd = maxf(0.0, _rocket_cd - delta)

	# Machinegun loop (web setInterval 80 ms while mousedown)
	if _mg_firing:
		if inventory.is_empty() or inventory[0]["type"] != "machinegun":
			_mg_firing = false
		else:
			_mg_timer -= delta
			if _mg_timer <= 0.0:
				_mg_timer = MG_INTERVAL
				_fire_machinegun_shot()

	var im: ImmediateMesh = _grapple_line.mesh
	im.clear_surfaces()
	if is_grappling:
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_add_vertex(player.global_position)
		im.surface_add_vertex(grapple_target)
		im.surface_end()
