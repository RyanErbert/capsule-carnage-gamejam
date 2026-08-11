extends Node3D

## Ambient critter flocks with boid steering — crows that wheel overhead and
## dive-bomb, rats that swarm the ground and nip ankles. The server only
## stores each flock's anchor; every client simulates its own copy (they're
## scenery with teeth, not competitive state), and each client applies chip
## damage to ITS OWN player on contact via the existing selfDamage pipeline.

const CROWS := 11
const RATS := 9
const SEP_R := 1.4          # boid separation radius
const NEIGH_R := 5.0        # cohesion/alignment radius
const CROW_SPEED := 7.5
const CROW_DIVE_SPEED := 14.0
const RAT_SPEED := 4.2
const RAT_CHASE := 8.0      # rats within this of the player go for the ankles
const CROW_AGGRO := 24.0
const BITE_CD := 1.4        # seconds between nips per flock
const ANCHOR_R := 16.0      # how far a flock strays from home

@export var player: CharacterBody3D

var _flocks: Dictionary = {}   # id -> {kind, anchor, boids, bite_cd, dive_cd}


func _ready() -> void:
	add_to_group("world_critters")
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentFlocks":
			for id in _flocks:
				_free_flock(id)
			_flocks.clear()
			for f in data:
				_add_flock(f)
		"flockPlaced":
			_add_flock(data)
		"flockRemoved":
			var id := str(data)
			if _flocks.has(id):
				_free_flock(id)
				_flocks.erase(id)


func _free_flock(id: String) -> void:
	for b in _flocks[id]["boids"]:
		if is_instance_valid(b["node"]):
			(b["node"] as Node3D).queue_free()


## Nearest flock anchor within `radius` — god menu delete/select. {} if none.
func nearest_deletable(pos: Vector3, radius := 6.0) -> Dictionary:
	var best := {}
	for id in _flocks:
		var d: float = (_flocks[id]["anchor"] as Vector3).distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _flocks[id]["anchor"]}
	return best


func _add_flock(f: Variant) -> void:
	if not f is Dictionary:
		return
	var id := str(f.get("id", ""))
	if id == "" or _flocks.has(id):
		return
	var kind := str(f.get("kind", "crows"))
	var anchor := Vector3(f.get("x", 0.0), f.get("y", 0.0), f.get("z", 0.0))
	var boids: Array = []
	var n := CROWS if kind == "crows" else RATS
	for i in n:
		var node := _make_crow() if kind == "crows" else _make_rat()
		add_child(node)
		var off := Vector3(randf_range(-4, 4), randf_range(4, 9) if kind == "crows" else 0.3, randf_range(-4, 4))
		node.global_position = anchor + off
		boids.append({
			"node": node,
			"pos": node.global_position,
			"vel": Vector3(randf_range(-2, 2), 0, randf_range(-2, 2)),
			"diving": false,
		})
	_flocks[id] = {"kind": kind, "anchor": anchor, "boids": boids, "bite_cd": 0.0, "dive_cd": randf_range(3.0, 7.0)}


func _physics_process(delta: float) -> void:
	for id in _flocks:
		var flock: Dictionary = _flocks[id]
		flock["bite_cd"] = maxf(0.0, float(flock["bite_cd"]) - delta)
		if flock["kind"] == "crows":
			_tick_crows(flock, delta)
		else:
			_tick_rats(flock, delta)


## Classic three-rule boids plus an anchor pull; one crow at a time breaks
## formation to dive at the player, then climbs back into the wheel.
func _tick_crows(flock: Dictionary, delta: float) -> void:
	var boids: Array = flock["boids"]
	var anchor: Vector3 = flock["anchor"]
	flock["dive_cd"] = float(flock["dive_cd"]) - delta
	var can_aggro: bool = player != null and not player.dead and not player.godmode \
		and player.global_position.distance_to(anchor) < CROW_AGGRO
	if flock["dive_cd"] <= 0.0 and can_aggro:
		flock["dive_cd"] = randf_range(4.0, 9.0)
		var pick: Dictionary = boids.pick_random()
		pick["diving"] = true
	for b in boids:
		var pos: Vector3 = b["pos"]
		var vel: Vector3 = b["vel"]
		var accel := Vector3.ZERO
		# Separation / cohesion / alignment
		var center := Vector3.ZERO
		var heading := Vector3.ZERO
		var mates := 0
		for o in boids:
			if o == b:
				continue
			var d: float = pos.distance_to(o["pos"])
			if d < SEP_R and d > 0.001:
				accel += (pos - o["pos"]) / d * 6.0
			if d < NEIGH_R:
				center += o["pos"]
				heading += o["vel"]
				mates += 1
		if mates > 0:
			accel += (center / mates - pos) * 0.8
			accel += (heading / mates - vel) * 0.6
		var speed := CROW_SPEED
		if b["diving"] and can_aggro:
			var target: Vector3 = player.global_position + Vector3(0, 0.8, 0)
			accel += (target - pos).normalized() * 22.0
			speed = CROW_DIVE_SPEED
			if pos.distance_to(target) < 1.4:
				b["diving"] = false
				if float(flock["bite_cd"]) <= 0.0:
					flock["bite_cd"] = BITE_CD
					Net.emit_event("selfDamage", 1)
					Sfx.jump(pos)  # sharp flap-snap on the hit
		else:
			b["diving"] = false
			# Wheel around home: pull toward the anchor ring, hold altitude
			var home := anchor + Vector3(0, 8.0, 0)
			var out := pos - home
			if out.length() > ANCHOR_R:
				accel += -out.normalized() * 10.0
			accel += Vector3(-out.z, 0, out.x).normalized() * 3.0  # orbit bias
			accel.y += clampf(home.y - pos.y, -4.0, 4.0)
		vel += accel * delta
		vel = vel.limit_length(speed)
		pos += vel * delta
		b["pos"] = pos
		b["vel"] = vel
		var node: Node3D = b["node"]
		node.global_position = pos
		if vel.length() > 0.5:
			node.rotation.y = atan2(-vel.x, -vel.z)
			node.rotation.x = clampf(-vel.y * 0.12, -0.7, 0.7)
		# Wing flap
		var t := Time.get_ticks_msec() / 1000.0 + pos.x
		var flap := sin(t * (18.0 if b["diving"] else 9.0)) * 0.55
		(node.get_node("WingL") as Node3D).rotation.z = flap
		(node.get_node("WingR") as Node3D).rotation.z = -flap


## Rats: 2D boids pinned to the ground, mobbing the player when close.
func _tick_rats(flock: Dictionary, delta: float) -> void:
	var boids: Array = flock["boids"]
	var anchor: Vector3 = flock["anchor"]
	var chase: bool = player != null and not player.dead and not player.godmode \
		and player.global_position.distance_to(anchor) < RAT_CHASE + ANCHOR_R
	for b in boids:
		var pos: Vector3 = b["pos"]
		var vel: Vector3 = b["vel"]
		var accel := Vector3.ZERO
		for o in boids:
			if o == b:
				continue
			var d: float = pos.distance_to(o["pos"])
			if d < SEP_R * 0.6 and d > 0.001:
				accel += (pos - o["pos"]) / d * 8.0
		if chase and player.global_position.distance_to(pos) < RAT_CHASE:
			accel += (player.global_position - pos).normalized() * 14.0
			if player.global_position.distance_to(pos) < 1.0 and float(flock["bite_cd"]) <= 0.0:
				flock["bite_cd"] = BITE_CD
				Net.emit_event("selfDamage", 1)
				Sfx.boost(pos, 0.3)
		else:
			var out := pos - anchor
			if out.length() > 10.0:
				accel += -out.normalized() * 8.0
			# Idle scurry: wander noise
			accel += Vector3(randf_range(-3, 3), 0, randf_range(-3, 3))
		accel.y = 0.0
		vel += accel * delta
		vel.y = 0.0
		vel = vel.limit_length(RAT_SPEED)
		pos += vel * delta
		pos.y = _ground_y(pos) + 0.12
		b["pos"] = pos
		b["vel"] = vel
		var node: Node3D = b["node"]
		node.global_position = pos
		if vel.length() > 0.3:
			node.rotation.y = atan2(-vel.x, -vel.z)


func _ground_y(pos: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 4, 0), pos + Vector3(0, -12, 0))
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if hit else pos.y


# --- Bodies (procedural, matching the blocky look) ---------------------------

func _make_crow() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.1)
	mat.roughness = 0.9
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.16, 0.12, 0.42)
	bm.material = mat
	body.mesh = bm
	root.add_child(body)
	var beak := MeshInstance3D.new()
	var beak_mesh := BoxMesh.new()
	beak_mesh.size = Vector3(0.05, 0.05, 0.12)
	var beak_mat := StandardMaterial3D.new()
	beak_mat.albedo_color = Color(0.9, 0.75, 0.3)
	beak_mesh.material = beak_mat
	beak.mesh = beak_mesh
	beak.position = Vector3(0, 0.02, -0.25)
	root.add_child(beak)
	for side in [-1.0, 1.0]:
		var wing := MeshInstance3D.new()
		wing.name = "WingL" if side < 0 else "WingR"
		var wm := BoxMesh.new()
		wm.size = Vector3(0.55, 0.02, 0.28)
		wm.material = mat
		wing.mesh = wm
		wing.position = Vector3(side * 0.33, 0.04, 0.02)
		root.add_child(wing)
	return root


func _make_rat() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.4, 0.38)
	mat.roughness = 0.95
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.09
	cap.height = 0.4
	cap.material = mat
	body.mesh = cap
	body.rotation.x = PI / 2.0  # lie flat, nose forward
	body.position.y = 0.09
	root.add_child(body)
	var tail := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.025, 0.025, 0.3)
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.7, 0.5, 0.45)
	tm.material = tail_mat
	tail.mesh = tm
	tail.position = Vector3(0, 0.07, 0.32)
	root.add_child(tail)
	return root
