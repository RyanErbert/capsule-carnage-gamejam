extends Node

## Inventory + item use, child of the player (PORT_BLUEPRINT.md §1.8, §4.6–4.8).
## Web rules: 3 slots, slot 0 is active, left click uses it, 2/3 swap slots.
## Green items implemented here; weapons/builds (red/yellow) land in phases 5/6.

signal inventory_changed(items: Array)

const MAX_INVENTORY := 3
# Ammo granted on pedestal pickup (web game.js:4050). Missing = 0 = single use.
const PICKUP_AMMO := {"machinegun": 100, "rocket": 3, "bridge_gun": 3, "wall": 3, "ramp": 3,
	"platform": 3, "terragun": 100, "mines": 3}
const GRAPPLE_SPEED := 40.0
# The hook is thrown, not teleported: it flies under gravity like a rocket and
# only bites when it actually reaches something.
const HOOK_SPEED := 72.0
const HOOK_GRAVITY := -9.0
const HOOK_LIFE := 1.6
const HOOK_RETURN := 90.0
const ROPE_W := 0.055
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

var _rope: MeshInstance3D
var _hook: Node3D
var _hook_pos := Vector3.ZERO
var _hook_vel := Vector3.ZERO
var _hook_state := ""      # "" idle | "fly" | "set" | "back"
var _hook_life := 0.0
var _sync: Node
var _mg_firing := false
var _mg_timer := 0.0
var _rocket_cd := 0.0
var _rig: Node3D          # the held weapon on the body (Items/weapon_rig.gd)
var _aim_cache := Vector3.FORWARD


## What the body is holding, and where it's pointing — multiplayer_sync ships
## both so remotes can mount the same gun at the same angle.
func held_type() -> String:
	return str(inventory[0]["type"]) if not inventory.is_empty() else ""


func aim_dir() -> Vector3:
	return _aim_cache


func _ready() -> void:
	Net.event_received.connect(_on_net_event)
	# Lobby starting weapon (web menu: none/machinegun/rocket/mines/grapple)
	var weapon: String = Settings.starting_weapon
	if weapon != "none" and weapon != "":
		inventory.append({"type": weapon, "ammo": int(Settings.STARTING_AMMO.get(weapon, 0))})
		inventory_changed.emit.call_deferred(inventory)
	_rope = MeshInstance3D.new()
	_rope.top_level = true
	_rope.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.72, 0.64, 0.44)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rope.material_override = mat
	add_child(_rope)
	_hook = _make_hook()
	_hook.top_level = true
	_hook.visible = false
	add_child(_hook)
	# The gun rides on the body, at chest height, swinging with the aim ray
	_rig = load("res://Items/weapon_rig.gd").new()
	_rig.position = Vector3(0, 0.15, 0)
	player.add_child.call_deferred(_rig)
	inventory_changed.connect(func(_items: Array): _rig.set_weapon(held_type()))
	_rig.set_weapon.call_deferred(held_type())


func _on_net_event(event: String, data: Variant) -> void:
	if event == "itemPickedUp":
		var item := str(data)
		if item != "":
			# New item always takes slot 0 (picked up OR god-given); the rest
			# shift right, and a fourth pushes the last one off the end.
			inventory.push_front({"type": item, "ammo": int(PICKUP_AMMO.get(item, 0))})
			if inventory.size() > MAX_INVENTORY:
				inventory.resize(MAX_INVENTORY)
			print("[items] picked up %s — inventory: %s" % [item, inventory])
			inventory_changed.emit(inventory)
	elif event == "gameEnded" or event == "kicked":
		inventory.clear()
		_drop_hook()
		pending_teleporter = null
		inventory_changed.emit(inventory)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_mg_firing = false
	# Weapons are offline in god mode, riding a vehicle (the drill's left-click
	# carve owns the mouse there), and piloting a bot (click = swarm strike)
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or player.godmode \
			or player.vehicle != null or player.piloting:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Web: mousedown starts the machinegun loop; anything else is consumeItem()
		if not inventory.is_empty() and inventory[0]["type"] == "machinegun":
			_mg_firing = true
			_mg_timer = 0.0
		else:
			use_item()
	elif event is InputEventMouseButton and event.pressed \
			and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		# Scroll cycles weapons — unless a build is armed, where it's the
		# placement height instead.
		var builder: Node = get_parent().get_node_or_null("BuildController")
		if builder and builder.is_build_active():
			return
		cycle(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_2:
			swap_to_first(1)
		elif event.keycode == KEY_3:
			swap_to_first(2)


## Rotate the inventory so a different slot becomes active.
func cycle(dir: int) -> void:
	if inventory.size() < 2:
		return
	if dir > 0:
		inventory.push_back(inventory.pop_front())
	else:
		inventory.push_front(inventory.pop_back())
	inventory_changed.emit(inventory)


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
			if _hook_state != "":
				return
			_fire_hook()
			_use_ammo()
		"launch_pad", "boost_pad", "mines":
			if target == null or player.global_position.distance_to(target) > PLACE_RANGE:
				return
			if item == "mines":
				Net.emit_event("placeMine", {"x": target.x, "y": target.y, "z": target.z})
				_use_ammo()   # a mine is a round, not the whole box
				return
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
		"terragun":
			pass   # polled, not clicked — TerraGun watches both buttons itself
		"block", "wall", "ramp", "platform":
			var builds := get_parent().get_node_or_null("BuildController")
			if builds:
				builds.try_place()
		"bridge_gun":
			var bridge := get_parent().get_node_or_null("BuildController")
			if bridge:
				bridge.fire_bridge_gun()
		"crowbot":
			# Deploys a crow-bot machine ahead of you and takes the stick.
			# Single use; the machine stays in the world afterwards (E re-pilots).
			var wv: Node = get_tree().get_first_node_in_group("world_vehicles")
			if wv == null or player.piloting or player.vehicle != null:
				return
			wv.deploy_bot("crowbot")
			_shift_inventory()
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
	if bool(Net.game_settings.get("infiniteAmmo", false)):
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
	if bool(Net.game_settings.get("infiniteAmmo", false)):
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
	_aim_cache = _aim_direction()
	if _rig and is_instance_valid(_rig):
		_rig.aim(_aim_cache)
		_rig.set_holstered(player.godmode or player.piloting or player.dead
			or player.vehicle != null)

	# Machinegun loop (web setInterval 80 ms while mousedown)
	if _mg_firing:
		if inventory.is_empty() or inventory[0]["type"] != "machinegun" or player.vehicle != null:
			_mg_firing = false
		else:
			_mg_timer -= delta
			if _mg_timer <= 0.0:
				_mg_timer = MG_INTERVAL
				_fire_machinegun_shot()

	_hook_step(delta)
	_draw_rope()


# --- Grapple: a thrown hook on a rope ---------------------------------------

func _fire_hook() -> void:
	var dir := _aim_direction()
	_hook_pos = player.global_position + Vector3(0, 0.4, 0) + dir * 1.2
	_hook_vel = dir * HOOK_SPEED
	_hook_state = "fly"
	_hook_life = HOOK_LIFE
	_hook.visible = true
	_hook.global_position = _hook_pos
	Sfx.boost(player.global_position, 0.5)


func _drop_hook() -> void:
	_hook_state = ""
	is_grappling = false
	if _hook and is_instance_valid(_hook):
		_hook.visible = false


func _hook_step(delta: float) -> void:
	if _hook_state == "" or player == null:
		return
	var chest := player.global_position + Vector3(0, 0.4, 0)
	match _hook_state:
		"fly":
			_hook_life -= delta
			_hook_vel.y += HOOK_GRAVITY * delta
			var step := _hook_vel * delta
			var q := PhysicsRayQueryParameters3D.create(_hook_pos, _hook_pos + step)
			q.exclude = [player.get_rid()]
			var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
			if hit:
				# It bit: only now does the rope start pulling (player.gd §4.8)
				_hook_pos = hit["position"] + hit["normal"] * 0.08
				grapple_target = _hook_pos
				is_grappling = true
				_hook_state = "set"
				Sfx.jump(_hook_pos)
			else:
				_hook_pos += step
				if _hook_life <= 0.0 or _hook_pos.distance_to(chest) > AIM_RANGE:
					_hook_state = "back"
		"set":
			# The player lets go by jumping or arriving — reel it in after them
			if not is_grappling:
				_hook_state = "back"
		"back":
			var home := chest - _hook_pos
			if home.length() < 1.2:
				_drop_hook()
				return
			_hook_pos += home.normalized() * minf(HOOK_RETURN * delta, home.length())
	if not _hook.visible:
		return
	_hook.global_position = _hook_pos
	var look := _hook_vel if _hook_state == "fly" else (_hook_pos - chest)
	if look.length() > 0.01 and absf(look.normalized().dot(Vector3.UP)) < 0.999:
		_hook.look_at_from_position(_hook_pos, _hook_pos + look)


## The rope as a ribbon of camera-facing quads, sagging while the hook is still
## in the air and snapping straight the moment it takes the load.
func _draw_rope() -> void:
	var im: ImmediateMesh = _rope.mesh
	im.clear_surfaces()
	if _hook_state == "" or player == null:
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam else player.global_position
	var from := player.global_position + Vector3(0, 0.35, 0)
	var sag := 0.0 if is_grappling else from.distance_to(_hook_pos) * 0.05
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev := from
	for i in range(1, 9):
		var t := float(i) / 8.0
		var p := from.lerp(_hook_pos, t) + Vector3.DOWN * sin(t * PI) * sag
		var run := p - prev
		if run.length() > 0.0001:
			var side := run.normalized().cross((prev + p) * 0.5 - eye)
			side = Vector3.RIGHT * ROPE_W if side.length() < 1e-5 else side.normalized() * ROPE_W
			im.surface_add_vertex(prev - side)
			im.surface_add_vertex(p - side)
			im.surface_add_vertex(prev + side)
			im.surface_add_vertex(p - side)
			im.surface_add_vertex(p + side)
			im.surface_add_vertex(prev + side)
		prev = p
	im.surface_end()


## Three flukes swept back off a shank, pointing down its own -Z so aiming it
## is just a look_at.
static func _make_hook() -> Node3D:
	var root := Node3D.new()
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.52, 0.55, 0.6)
	steel.metallic = 0.85
	steel.roughness = 0.32
	var shank := MeshInstance3D.new()
	var rod := CylinderMesh.new()
	rod.top_radius = 0.05
	rod.bottom_radius = 0.05
	rod.height = 0.4
	shank.mesh = rod
	shank.material_override = steel
	shank.rotation.x = PI / 2.0
	root.add_child(shank)
	var tip := MeshInstance3D.new()
	var point := CylinderMesh.new()
	point.top_radius = 0.0
	point.bottom_radius = 0.09
	point.height = 0.22
	tip.mesh = point
	tip.material_override = steel
	tip.rotation.x = -PI / 2.0
	tip.position.z = -0.3
	root.add_child(tip)
	for i in 3:
		var arm := Node3D.new()
		arm.rotation.z = float(i) * TAU / 3.0
		root.add_child(arm)
		var claw := MeshInstance3D.new()
		var bar := BoxMesh.new()
		bar.size = Vector3(0.045, 0.045, 0.26)
		claw.mesh = bar
		claw.material_override = steel
		claw.position = Vector3(0, 0.08, 0.06)
		claw.rotation.x = -0.5
		arm.add_child(claw)
	var eye := MeshInstance3D.new()
	var loop := TorusMesh.new()
	loop.inner_radius = 0.05
	loop.outer_radius = 0.09
	loop.rings = 8
	eye.mesh = loop
	eye.material_override = steel
	eye.position.z = 0.23
	eye.rotation.x = PI / 2.0
	root.add_child(eye)
	return root
