extends Node3D

## Bullets, rockets, mines, explosions, and coins (PORT_BLUEPRINT.md §5).
## Same authority split as the web: every client simulates all projectiles;
## only the OWNER's client emits machinegunHit / triggerExplosion, and the
## server answers with applyImpulse / explosion / coinsDropped.

const BULLET_LIFE := 2.0
const ROCKET_LIFE := 5.0
const ROCKET_GRAVITY := -8.0   # web quirk: rockets fall slower than players
const HIT_RADIUS := 1.5        # bullet hit sphere
const ROCKET_FUSE := 1.2       # rocket proximity + mine trigger distance
const COIN_COLLECT_DIST := 1.5
const COIN_GRAVITY := -20.0

@export var player: CharacterBody3D

var _sync: Node
var _bullets: Array = []   # {pos, vel, life, owner, node}
var _rockets: Array = []   # {pos, vel, life, owner, node}
var _mines: Dictionary = {}   # id -> {pos, node}
var _coins: Dictionary = {}   # id -> {pos, vel, collect_timer, node}


func _ready() -> void:
	Net.event_received.connect(_on_net_event)


func _self_id() -> String:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	return _sync.self_id if _sync else ""


func _remotes() -> Dictionary:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	return _sync.remotes() if _sync else {}


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"machinegunFired":
			_spawn_bullet(data)
		"rocketFired":
			_spawn_rocket(data)
		"explosion":
			_on_explosion(data)
		"applyImpulse":
			_on_apply_impulse(data)
		"currentMines":
			for id in _mines:
				_mines[id]["node"].queue_free()
			_mines.clear()
			for m in data:
				_add_mine(m)
		"minePlaced":
			_add_mine(data)
		"mineTriggered":
			var id := str(data.get("id", ""))
			if _mines.has(id):
				_mines[id]["node"].queue_free()
				_mines.erase(id)
		"coinsDropped":
			for c in data:
				_add_coin(c)
		"coinCollected":
			var id := str(data)
			if _coins.has(id):
				_coins[id]["node"].queue_free()
				_coins.erase(id)


# --- Spawners -------------------------------------------------------------

func _vec3(d: Dictionary) -> Vector3:
	return Vector3(d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0))


func _tracer_node(color: Color, size: Vector3, emissive := false) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if emissive:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 1.5
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = mat
	node.mesh = box
	add_child(node)
	return node


func _spawn_bullet(data: Dictionary) -> void:
	var pos := _vec3(data.get("start", {}))
	var vel := _vec3(data.get("velocity", {}))
	var node := _tracer_node(Color.YELLOW, Vector3(0.1, 0.1, 2.0))
	node.position = pos
	if vel.length() > 0.01:
		node.look_at_from_position(pos, pos + vel)
	_bullets.append({"pos": pos, "vel": vel, "life": BULLET_LIFE, "owner": str(data.get("owner", "")), "node": node})


func _spawn_rocket(data: Dictionary) -> void:
	var pos := _vec3(data.get("start", {}))
	var vel := _vec3(data.get("velocity", {}))
	var node := _tracer_node(Color(1.0, 0.15, 0.15), Vector3(0.25, 0.25, 0.8), true)
	node.position = pos
	if vel.length() > 0.01:
		node.look_at_from_position(pos, pos + vel)
	_rockets.append({"pos": pos, "vel": vel, "life": ROCKET_LIFE, "owner": str(data.get("owner", "")), "node": node})


func _add_mine(m: Dictionary) -> void:
	var id := str(m.get("id", ""))
	if id == "" or _mines.has(id):
		return
	var node := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.4
	cyl.bottom_radius = 0.4
	cyl.height = 0.1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#ff2222")
	mat.emission_enabled = true
	mat.emission = Color("#440000")
	mat.emission_energy_multiplier = 2.0
	cyl.material = mat
	node.mesh = cyl
	node.position = _vec3(m)
	add_child(node)
	_mines[id] = {"pos": _vec3(m), "node": node}


func _add_coin(c: Dictionary) -> void:
	var id := str(c.get("id", ""))
	if id == "" or _coins.has(id):
		return
	var node := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.3
	cyl.bottom_radius = 0.3
	cyl.height = 0.1
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#ffd700")
	mat.emission_enabled = true
	mat.emission = Color("#aa8800")
	mat.emission_energy_multiplier = 1.2
	cyl.material = mat
	node.mesh = cyl
	node.position = _vec3(c)
	add_child(node)
	_coins[id] = {
		"pos": _vec3(c),
		"vel": Vector3(c.get("vx", 0.0), c.get("vy", 0.0), c.get("vz", 0.0)),
		"collect_timer": 1.0,  # web: uncollectable for the first second
		"node": node,
	}


# --- Impulses (web pendingImpulses + applyImpulse) --------------------------

func _on_explosion(data: Dictionary) -> void:
	var pos := _vec3(data)
	var is_mine: bool = str(data.get("type", "")) == "mine"
	_explosion_vfx(pos, is_mine)
	if player == null:
		return
	var dist := player.global_position.distance_to(pos)
	var radius := 6.0 if is_mine else 8.0
	if dist >= radius:
		return
	var dir := (player.global_position - pos).normalized()
	if is_mine:
		dir.y = maxf(0.3, dir.y + 0.4)
	else:
		dir.y = maxf(0.5, dir.y + 1.0)
	dir = dir.normalized()
	var force := (radius - dist) * (9.0 if is_mine else 7.0)
	player.global_position.y += 1.0 if is_mine else 1.5  # pop off the ground
	player.velocity.x += dir.x * force
	player.velocity.y = maxf(player.velocity.y, 0.0) + dir.y * force
	player.velocity.z += dir.z * force
	player.speed_cap = maxf(player.speed_cap, Vector2(player.velocity.x, player.velocity.z).length())


func _on_apply_impulse(data: Dictionary) -> void:
	if player == null or str(data.get("id", "")) != _self_id():
		return
	var dir := _vec3(data.get("dir", {}))
	var force := float(data.get("force", 0.0))
	player.global_position.y += 0.1  # break ground friction
	player.velocity += dir * force
	player.speed_cap = maxf(player.speed_cap, Vector2(player.velocity.x, player.velocity.z).length())


## One-shot particle burst standing in for the web's GPU particles (§1.6).
func _explosion_vfx(pos: Vector3, is_mine: bool) -> void:
	var p := CPUParticles3D.new()
	p.position = pos
	p.emitting = false
	p.one_shot = true
	p.amount = 30 if not is_mine else 20
	p.lifetime = 0.8
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 8.0 if is_mine else 10.0
	p.initial_velocity_max = 12.0
	p.gravity = Vector3(0, -3, 0)
	p.scale_amount_min = 0.3
	p.scale_amount_max = 0.6
	p.color = Color(1.0, 0.1, 0.05) if is_mine else Color(1.0, 0.45, 0.1)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	sphere.material = mat
	p.mesh = sphere
	add_child(p)
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)


# --- Simulation ------------------------------------------------------------

func _ray_hit(from: Vector3, dir: Vector3, dist: float) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * dist)
	if player:
		q.exclude = [player.get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _physics_process(delta: float) -> void:
	var self_id := _self_id()
	var remotes := _remotes()

	# Bullets (web §5.2): CCD ray, kill below y 0, owner does hit detection
	for i in range(_bullets.size() - 1, -1, -1):
		var b: Dictionary = _bullets[i]
		b["life"] -= delta
		var vel: Vector3 = b["vel"]
		b["pos"] += vel * delta
		b["node"].position = b["pos"]
		var hit: bool = b["pos"].y < 0.0 or _ray_hit(b["pos"], vel.normalized(), vel.length() * delta + 0.1)
		if not hit and b["owner"] == self_id:
			for id in remotes:
				if remotes[id].global_position.distance_to(b["pos"]) < HIT_RADIUS:
					hit = true
					var d := vel.normalized()
					Net.emit_event("machinegunHit", {"targetId": id, "dir": {"x": d.x, "y": d.y, "z": d.z}})
					break
		if not hit and b["owner"] != self_id and player \
				and player.global_position.distance_to(b["pos"]) < HIT_RADIUS:
			hit = true  # visual only — knockback arrives via applyImpulse
		if hit or b["life"] <= 0.0:
			b["node"].queue_free()
			_bullets.remove_at(i)

	# Rockets (web §5.3): gravity -8, detonate on level/down-ray/y<0/proximity
	for i in range(_rockets.size() - 1, -1, -1):
		var r: Dictionary = _rockets[i]
		r["life"] -= delta
		r["vel"].y += ROCKET_GRAVITY * delta
		var rvel: Vector3 = r["vel"]
		r["pos"] += rvel * delta
		var rnode: MeshInstance3D = r["node"]
		rnode.position = r["pos"]
		if rvel.length() > 0.01:
			rnode.look_at(r["pos"] + rvel)
		var boom: bool = r["pos"].y < 0.0 \
			or _ray_hit(r["pos"], rvel.normalized(), rvel.length() * delta + 0.5) \
			or _ray_hit(r["pos"], Vector3.DOWN, 0.5)
		if not boom:
			for id in remotes:
				if id != r["owner"] and remotes[id].global_position.distance_to(r["pos"]) < ROCKET_FUSE:
					boom = true
					break
		if not boom and self_id != r["owner"] and player \
				and player.global_position.distance_to(r["pos"]) < ROCKET_FUSE:
			boom = true
		if boom or r["life"] <= 0.0:
			if boom and r["owner"] == self_id:
				Net.emit_event("triggerExplosion", {"x": r["pos"].x, "y": r["pos"].y, "z": r["pos"].z})
			rnode.queue_free()
			_rockets.remove_at(i)

	if player == null:
		return

	# Mines: trigger within 1.2 — web has no owner immunity or arming delay
	for id in _mines:
		if player.global_position.distance_to(_mines[id]["pos"]) < ROCKET_FUSE:
			Net.emit_event("triggerMine", id)

	# Coins (web §5.6): light manual physics + terrain rest, collect < 1.5
	for id in _coins:
		var c: Dictionary = _coins[id]
		c["vel"].y += COIN_GRAVITY * delta
		c["vel"] *= pow(0.9, delta)  # ~cannon linearDamping 0.1
		c["pos"] += c["vel"] * delta
		var cp: Vector3 = c["pos"]
		var q := PhysicsRayQueryParameters3D.create(cp + Vector3(0, 0.6, 0), cp + Vector3(0, -80, 0))
		q.exclude = [player.get_rid()]
		var ground := get_world_3d().direct_space_state.intersect_ray(q)
		if ground:
			var rest_y: float = ground["position"].y + 0.06
			if cp.y < rest_y:
				c["pos"].y = rest_y
				if c["vel"].y < 0.0:
					c["vel"].y *= -0.3
				c["vel"].x *= 0.6
				c["vel"].z *= 0.6
		c["node"].position = c["pos"]
		c["collect_timer"] -= delta
		if c["collect_timer"] <= 0.0 and player.global_position.distance_to(c["pos"]) < COIN_COLLECT_DIST:
			c["collect_timer"] = 999.0
			Net.emit_event("collectCoin", id)
