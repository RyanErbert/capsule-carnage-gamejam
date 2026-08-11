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

# Weapon terrain damage (Creative level — no-ops when there's no voxel field)
const ROCKET_CRATER := 5.0
const MINE_CRATER := 4.5
const BULLET_CHIP_R := 2.0
const BULLET_CHIP_ST := 0.25

# Slayer death blast: the crater carved into the terrain IS the death mark
const DEATH_CRATER := 6.0

@export var player: CharacterBody3D

var _sync: Node
var _bullets: Array = []   # {pos, vel, life, owner, node}
var _rockets: Array = []   # {pos, vel, life, owner, node}
var _mines: Dictionary = {}   # id -> {pos, node}
var _coins: Dictionary = {}   # id -> {pos, vel, collect_timer, node}
var _terrain_node: Node3D
var _triggered_mines: Dictionary = {}


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


func _terrain() -> Node3D:
	if _terrain_node == null or not is_instance_valid(_terrain_node):
		_terrain_node = get_tree().get_first_node_in_group("voxel_terrain")
	return _terrain_node


## Carve the destructible terrain AND network it, so every client (and every
## late joiner, via the server's edit log) ends up with the same crater.
## Only the destruction's owner calls this — others receive the terrainEdit.
func _carve(pos: Vector3, radius: float, strength: float) -> void:
	var t := _terrain()
	if t == null:
		return
	if t.apply_brush(pos, radius, -1.0, strength):
		Net.emit_event("terrainEdit", {
			"x": pos.x, "y": pos.y, "z": pos.z,
			"r": radius, "s": -1.0, "st": strength,
		})


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"machinegunFired":
			_spawn_bullet(data)
		"rocketFired":
			_spawn_rocket(data)
		"explosion":
			_on_explosion(data)
		"playerDied":
			if data is Dictionary:
				_on_player_died(data)
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
			_triggered_mines.erase(id)
			if _mines.has(id):
				_mines[id]["node"].queue_free()
				_mines.erase(id)
		"coinsDropped":
			for c in data:
				_add_coin(c)
		"coinCollected":
			var id := str(data)
			if _coins.has(id):
				Sfx.boost(_coins[id]["node"].global_position, 0.6)
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
	if vel.length() > 0.01 and absf(vel.normalized().dot(Vector3.UP)) < 0.999:
		node.look_at_from_position(pos, pos + vel)
	Sfx.boost(pos, 0.2)
	_bullets.append({
		"pos": pos, "vel": vel, "life": BULLET_LIFE,
		"owner": str(data.get("owner", "")), "node": node,
		"tid": str(data.get("tid", "")),  # non-empty = fired by that turret
	})


func _spawn_rocket(data: Dictionary) -> void:
	var pos := _vec3(data.get("start", {}))
	var vel := _vec3(data.get("velocity", {}))
	var node := _tracer_node(Color(1.0, 0.15, 0.15), Vector3(0.25, 0.25, 0.8), true)
	node.position = pos
	if vel.length() > 0.01 and absf(vel.normalized().dot(Vector3.UP)) < 0.999:
		node.look_at_from_position(pos, pos + vel)
	Sfx.boost(pos, 1.0)
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


## Coins are real rigid bodies (web: cannon Cylinder mass 1) — they bounce,
## tumble, and can be shoved around before being collected.
func _add_coin(c: Dictionary) -> void:
	var id := str(c.get("id", ""))
	if id == "" or _coins.has(id):
		return
	var body := RigidBody3D.new()
	body.mass = 1.0
	body.linear_damp = 0.1
	body.angular_damp = 0.1
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.3
	shape.height = 0.1
	col.shape = shape
	body.add_child(col)
	var mesh_inst := MeshInstance3D.new()
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
	mesh_inst.mesh = cyl
	body.add_child(mesh_inst)
	add_child(body)
	body.global_position = _vec3(c)
	body.linear_velocity = Vector3(c.get("vx", 0.0), c.get("vy", 0.0), c.get("vz", 0.0))
	body.angular_velocity = Vector3(c.get("rx", 0.0), c.get("ry", 0.0), c.get("rz", 0.0))
	_coins[id] = {
		"collect_timer": 1.0,  # web: uncollectable for the first second
		"life": 15.0,          # server forgets coins after 15 s
		"node": body,
	}


# --- Impulses (web pendingImpulses + applyImpulse) --------------------------

func _on_explosion(data: Dictionary) -> void:
	var pos := _vec3(data)
	var is_mine: bool = str(data.get("type", "")) == "mine"
	_explosion_vfx(pos, is_mine)
	Sfx.bomb(pos)
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
		dir.y = maxf(0.35, dir.y + 0.6)
	dir = dir.normalized()
	var force := (radius - dist) * (9.0 if is_mine else 4.2)
	player.global_position.y += 1.0 if is_mine else 0.8  # pop off the ground
	player.velocity.x += dir.x * force
	player.velocity.y = maxf(player.velocity.y, 0.0) + dir.y * force
	player.velocity.z += dir.z * force
	player.speed_cap = maxf(player.speed_cap, Vector2(player.velocity.x, player.velocity.z).length())


## Slayer death: normal blast visuals + knockback for everyone. Only the
## dead player's own client carves the crater (the destruction-owner rule)
## and starts the local respawn countdown.
func _on_player_died(data: Dictionary) -> void:
	var pos := _vec3(data)
	_on_explosion({"x": pos.x, "y": pos.y, "z": pos.z})
	if str(data.get("id", "")) == _self_id() and player:
		_carve(pos, DEATH_CRATER, 1.0)
		player.die_slayer(float(data.get("respawnMs", 4000.0)) / 1000.0)


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

func _ray_hit(from: Vector3, dir: Vector3, dist: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * dist)
	if player:
		q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


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
		var hit: bool = b["pos"].y < 0.0
		if not hit:
			var rh := _ray_hit(b["pos"], vel.normalized(), vel.length() * delta + 0.1)
			if rh:
				hit = true
				# Owner's bullets chip the destructible terrain (Creative)
				if b["owner"] == self_id and _terrain() != null \
						and rh["collider"].get_parent() == _terrain():
					_carve(rh["position"], BULLET_CHIP_R, BULLET_CHIP_ST)
				# ...and wear down NPC turrets
				elif b["owner"] == self_id and rh["collider"] is Node \
						and (rh["collider"] as Node).is_in_group("turret_body"):
					Net.emit_event("turretHit", {
						"id": str((rh["collider"] as Node).get_meta("turret_id", "")), "dmg": 10})
		# Critters: shooter's client is the hit authority, same as player hits
		if not hit and b["owner"] == self_id:
			var wc: Node = get_tree().get_first_node_in_group("world_critters")
			if wc:
				var ch: Dictionary = wc.hit_test(b["pos"])
				if not ch.is_empty():
					hit = true
					var src := {"t": "turret", "id": b["tid"]} if b["tid"] != "" else {"t": "player"}
					Net.emit_event("critterHit", {"id": ch["id"], "idx": ch["idx"], "src": src})
		if not hit and b["owner"] == self_id:
			for id in remotes:
				if remotes[id].global_position.distance_to(b["pos"]) < HIT_RADIUS:
					hit = true
					var d := vel.normalized()
					Net.emit_event("machinegunHit", {"targetId": id, "dir": {"x": d.x, "y": d.y, "z": d.z}})
					break
				# Their drone is a target too — smaller, so a tighter sphere
				var dp: Variant = remotes[id].drone_pos()
				if dp is Vector3 and dp.distance_to(b["pos"]) < 0.9:
					hit = true
					Net.emit_event("droneHit", id)
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
		# look_at errors out when the direction is parallel to the up vector
		if rvel.length() > 0.01 and absf(rvel.normalized().dot(Vector3.UP)) < 0.999:
			rnode.look_at(r["pos"] + rvel)
		var boom: bool = r["pos"].y < 0.0 \
			or not _ray_hit(r["pos"], rvel.normalized(), rvel.length() * delta + 0.5).is_empty() \
			or not _ray_hit(r["pos"], Vector3.DOWN, 0.5).is_empty()
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
				_carve(r["pos"], ROCKET_CRATER, 1.0)
			rnode.queue_free()
			_rockets.remove_at(i)

	if player == null:
		return

	# Mines: trigger within 1.2 — web has no owner immunity or arming delay.
	# Whoever steps on it owns the crater (deduped: one trigger per mine).
	for id in _mines:
		if _triggered_mines.has(id):
			continue
		if player.global_position.distance_to(_mines[id]["pos"]) < ROCKET_FUSE:
			_triggered_mines[id] = true
			Net.emit_event("triggerMine", id)
			_carve(_mines[id]["pos"], MINE_CRATER, 1.0)

	# Coins (web §5.6): physics handled by the engine; collect < 1.5 after 1 s
	var expired: Array = []
	for id in _coins:
		var c: Dictionary = _coins[id]
		c["collect_timer"] -= delta
		c["life"] -= delta
		if c["life"] <= 0.0:  # server has forgotten this coin — clean up quietly
			c["node"].queue_free()
			expired.append(id)
			continue
		if c["collect_timer"] <= 0.0 \
				and player.global_position.distance_to(c["node"].global_position) < COIN_COLLECT_DIST:
			c["collect_timer"] = 999.0
			Net.emit_event("collectCoin", id)
	for id in expired:
		_coins.erase(id)
