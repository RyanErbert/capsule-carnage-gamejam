extends Node3D

## NPC turrets: sentry guns that belong to whoever placed them and open up on
## everyone else. The OWNER's client runs the brain — acquire the nearest
## enemy, swing the head, and fire through the normal machinegun pipeline, so
## tracers, hits, and damage all reuse the existing plumbing. The server owns
## turret health; bullets and blasts wear it down until it pops.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")
const Registry := preload("res://Items/parametric/registry.gd")

const RANGE := 30.0
const FIRE_INTERVAL := 0.22
const AIM_RATE := 3.0          # rad/s the head chases its target
const AIM_TOLERANCE := 0.18    # radians off-target it will still fire at
const RELAY_INTERVAL := 0.2
const MUZZLE_H := 1.55
const HP_MAX := 60.0
const MG_SPEED := 200.0
const MOUTH_OPEN := 0.5        # radians the upper jaw swings back when it fires
const MOUTH_RATE := 7.0        # how fast it gapes, and how fast it shuts

@export var player: CharacterBody3D

var _turrets: Dictionary = {}  # id -> {node, head, barrels, owner, ry, fire_cd, spin}
var _sync: Node
var _relay_cd := 0.0


func _ready() -> void:
	add_to_group("world_turrets")
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
		"currentTurrets":
			for id in _turrets:
				_turrets[id]["node"].queue_free()
			_turrets.clear()
			for t in data:
				_add_turret(t)
		"turretPlaced":
			_add_turret(data)
		"turretRemoved", "turretDestroyed":
			var id := str(data)
			if _turrets.has(id):
				_turrets[id]["node"].queue_free()
				_turrets.erase(id)
		"turretHealth":
			if data is Dictionary:
				var tid := str(data.get("id", ""))
				if _turrets.has(tid):
					var fill: MeshInstance3D = _turrets[tid]["hp_fill"]
					fill.scale.x = clampf(float(data.get("hp", 0)) / HP_MAX, 0.05, 1.0)
		"turretAim":
			if data is Dictionary:
				var aid := str(data.get("id", ""))
				if _turrets.has(aid) and _turrets[aid]["owner"] != _self_id():
					_turrets[aid]["ry"] = float(data.get("ry", 0.0))
					_turrets[aid]["rx"] = float(data.get("rx", 0.0))
					_turrets[aid]["firing"] = bool(data.get("f", false))


## Position of a live turret, or null — critters resolving their grudge.
func turret_pos(id: String) -> Variant:
	return _turrets[id]["node"].global_position if _turrets.has(id) else null


## Whether this client owns the turret (single-authority gnaw damage).
func my_turret(id: String) -> bool:
	return _turrets.has(id) and _turrets[id]["owner"] == _self_id()


## Nearest turret within `radius` — god menu delete/select. {} if none.
func nearest_deletable(pos: Vector3, radius := 4.0) -> Dictionary:
	var best := {}
	for id in _turrets:
		var d: float = _turrets[id]["node"].global_position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _turrets[id]["node"].global_position}
	return best


func _add_turret(t: Variant) -> void:
	if not t is Dictionary:
		return
	var id := str(t.get("id", ""))
	if id == "" or _turrets.has(id):
		return
	var node := _make_turret_node(id)
	add_child(node)
	node.global_position = Vector3(t.get("x", 0.0), t.get("y", 0.0), t.get("z", 0.0))
	var hp_fill: MeshInstance3D = node.get_node("HpFill")
	hp_fill.scale.x = clampf(float(t.get("hp", HP_MAX)) / HP_MAX, 0.05, 1.0)
	_turrets[id] = {
		"node": node,
		"head": node.get_node("Head"),
		"pivot": node.get_node("Head/Pivot"),
		"barrels": node.get_node("Head/Pivot/Barrels"),
		"hp_fill": hp_fill,
		"owner": str(t.get("owner", "")),
		"ry": float(t.get("ry", 0.0)),
		"rx": 0.0,
		"jaw_hi": node.get_node("Head/Pivot/JawUpper"),
		"jaw_lo": node.get_node("Head/Pivot/JawLower"),
		"fire_cd": 0.0,
		"spin": 0.0,   # gatling spin speed, ramps while firing
		"firing": false,   # relayed, so everyone sees the same mouth open
		"mouth": 0.0,
	}


func _physics_process(delta: float) -> void:
	var self_id := _self_id()
	var remotes := _remotes()
	_relay_cd -= delta
	var relay := _relay_cd <= 0.0
	if relay:
		_relay_cd = RELAY_INTERVAL
	for id in _turrets:
		var t: Dictionary = _turrets[id]
		var head: Node3D = t["head"]
		var pivot: Node3D = t["pivot"]
		var firing := false
		if t["owner"] == self_id:
			firing = _run_brain(id, t, remotes, delta)
			if relay:
				Net.emit_event("turretAim", {"id": id, "ry": head.rotation.y,
					"rx": pivot.rotation.x, "f": firing})
		else:
			head.rotation.y = lerp_angle(head.rotation.y, t["ry"], minf(1.0, 6.0 * delta))
			pivot.rotation.x = lerpf(pivot.rotation.x, t["rx"], minf(1.0, 6.0 * delta))
			# Firing is relayed now. Without it a remote turret sat with its
			# mouth shut and its barrels idling while it shot you.
			firing = bool(t["firing"])
		# Gatling barrels: spin up while firing, wind down after
		t["spin"] = clampf(t["spin"] + (22.0 if firing else -14.0) * delta, 1.2, 26.0)
		(t["barrels"] as Node3D).rotate_object_local(Vector3.FORWARD, t["spin"] * delta)
		# The mouth gapes to shoot and shuts again: closed it is a rock, and the
		# barrels are not visible until it means it.
		t["mouth"] = clampf(float(t["mouth"]) + (1.0 if firing else -1.0) * MOUTH_RATE * delta, 0.0, 1.0)
		var gape: float = float(t["mouth"]) * MOUTH_OPEN
		(t["jaw_hi"] as Node3D).rotation.x = gape
		(t["jaw_lo"] as Node3D).rotation.x = -gape * 0.75


## Owner brain: pick the nearest enemy in range with line of sight, swing the
## head, fire when roughly on target. Returns whether it fired this frame.
func _run_brain(id: String, t: Dictionary, remotes: Dictionary, delta: float) -> bool:
	var node: Node3D = t["node"]
	var head: Node3D = t["head"]
	t["fire_cd"] = maxf(0.0, float(t["fire_cd"]) - delta)
	var muzzle: Vector3 = node.global_position + Vector3(0, MUZZLE_H, 0)
	var target := Vector3.INF
	var best := RANGE
	var fauna := false
	for rid in remotes:
		var rpos: Vector3 = remotes[rid].global_position
		var d: float = rpos.distance_to(node.global_position)
		if d < best:
			best = d
			target = rpos
	# Aggressive fauna is fair game too: whatever's closest gets the burst
	var wc: Node = get_tree().get_first_node_in_group("world_critters")
	if wc:
		var boid: Dictionary = wc.nearest_boid(node.global_position, best)
		if not boid.is_empty():
			target = boid["pos"]
			fauna = true
	if target == Vector3.INF:
		return false
	var to := target + (Vector3.ZERO if fauna else Vector3(0, 0.4, 0)) - muzzle
	var want_yaw := atan2(-to.x, -to.z)
	head.rotation.y = lerp_angle(head.rotation.y, want_yaw, minf(1.0, AIM_RATE * delta))
	# The gun also nods at its target: crows overhead, rats under the ring
	var pivot: Node3D = t["pivot"]
	var want_pitch := clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.9, 1.1)
	pivot.rotation.x = lerpf(pivot.rotation.x, want_pitch, minf(1.0, AIM_RATE * delta))
	if absf(angle_difference(head.rotation.y, want_yaw)) > AIM_TOLERANCE \
			or absf(pivot.rotation.x - want_pitch) > AIM_TOLERANCE:
		return false
	if t["fire_cd"] > 0.0:
		return true  # mid-burst: keep the barrels spinning
	# Line of sight (don't shoot through the wall it's parked behind)
	var q := PhysicsRayQueryParameters3D.create(muzzle, target + Vector3(0, 0.4, 0))
	q.exclude = _own_rids(node)
	var block := get_world_3d().direct_space_state.intersect_ray(q)
	if not block.is_empty() and block["position"].distance_to(target) > 2.0:
		return false
	t["fire_cd"] = FIRE_INTERVAL
	var dir := to.normalized()
	dir += Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 0.05
	dir = dir.normalized()
	var start := muzzle + dir * 1.2
	# "tid" tags the tracer as turret fire, so a killed critter's flock
	# aggros the TURRET, not the player whose client relayed the shot
	Net.emit_event("fireMachinegun", {
		"start": {"x": start.x, "y": start.y, "z": start.z},
		"velocity": {"x": dir.x * MG_SPEED, "y": dir.y * MG_SPEED, "z": dir.z * MG_SPEED},
		"tid": id,
	})
	return true


static func _own_rids(node: Node) -> Array:
	var out: Array = []
	if node is CollisionObject3D:
		out.append(node.get_rid())
	for child in node.get_children():
		out.append_array(_own_rids(child))
	return out


# --- Visuals ------------------------------------------------------------------

func _make_turret_node(id: String) -> Node3D:
	var root := Node3D.new()
	var body := StaticBody3D.new()
	body.add_to_group("turret_body")
	body.set_meta("turret_id", id)
	root.add_child(body)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.75
	shape.height = 1.6
	col.shape = shape
	col.position.y = 0.8
	body.add_child(col)

	var stone := _stone()

	# Body: a squat cairn, not a gun carriage. Two rough drums with few enough
	# facets to read as cut rock rather than a machined cylinder.
	root.add_child(_drum(stone, 0.82, 0.62, 0.72, 0.36, 7, 0.0))
	root.add_child(_drum(stone, 0.58, 0.46, 0.52, 0.98, 9, 0.4))

	var head := Node3D.new()
	head.name = "Head"
	head.position.y = 1.46
	root.add_child(head)

	# Yaw is the head, pitch is the pivot, and everything below hangs off the
	# pivot so the whole face nods at you rather than a gun poking out of it.
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	head.add_child(pivot)

	# The cranium sits BACK. The jaws are the whole front of the head, the way a
	# gun puppy is mostly mouth -- a boulder with two small lumps on it reads as
	# a boulder, and the mouth has to be the thing you see.
	var skull := MeshInstance3D.new()
	var sk := SphereMesh.new()
	sk.radius = 0.5
	sk.height = 0.84
	sk.radial_segments = 11
	sk.rings = 6
	skull.mesh = sk
	skull.material_override = stone
	skull.scale = Vector3(1.06, 1.0, 0.9)
	skull.position.z = 0.14
	pivot.add_child(skull)

	# The throat, dark and tapering back, so an open mouth reads as a hole
	# rather than a dent in the front of a rock.
	var throat := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.29
	tm.bottom_radius = 0.08
	tm.height = 0.5
	tm.radial_segments = 10
	throat.mesh = tm
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.07, 0.06, 0.06)
	dark.roughness = 1.0
	throat.material_override = dark
	throat.rotation.x = -PI * 0.5
	throat.position = Vector3(0, 0, 0.04)
	pivot.add_child(throat)

	# Jaws hinge at the back of the mouth and swing apart. Chamfered slabs,
	# tapering to the lip, so they carry the same arris the walls do.
	var jaw_hi := Node3D.new()
	jaw_hi.name = "JawUpper"
	jaw_hi.position = Vector3(0, 0.0, 0.16)
	pivot.add_child(jaw_hi)
	jaw_hi.add_child(_jaw(stone))

	var jaw_lo := Node3D.new()
	jaw_lo.name = "JawLower"
	jaw_lo.position = Vector3(0, 0.0, 0.16)
	pivot.add_child(jaw_lo)
	var flip := Node3D.new()
	# Rotated, not scaled by -1: a negative scale flips the winding and every
	# face on the lower jaw would render inside out.
	flip.rotation.z = PI
	flip.add_child(_jaw(stone))
	jaw_lo.add_child(flip)

	# Gatling cluster, recessed into the throat so it is out of sight until the
	# mouth opens for it.
	var barrels := Node3D.new()
	barrels.name = "Barrels"
	# Far enough back that the lips close in front of them: a shut mouth with
	# six barrels poking through it is not shut.
	barrels.position = Vector3(0, 0, 0.06)
	pivot.add_child(barrels)
	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.14, 0.14, 0.16)
	barrel_mat.metallic = 0.85
	barrel_mat.roughness = 0.25
	for i in 6:
		var ang := TAU * i / 6.0
		var barrel := MeshInstance3D.new()
		var bmesh := CylinderMesh.new()
		bmesh.top_radius = 0.045
		bmesh.bottom_radius = 0.045
		bmesh.height = 0.56
		bmesh.material = barrel_mat
		barrel.mesh = bmesh
		barrel.rotation.x = -PI / 2.0
		barrel.position = Vector3(cos(ang) * 0.11, sin(ang) * 0.11, -0.24)
		barrels.add_child(barrel)

	# Attack range, outlined on the floor as a thin flat band
	var ring := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in 73:
		var a := TAU * i / 72.0
		im.surface_add_vertex(Vector3(cos(a) * (RANGE - 0.5), 0.06, sin(a) * (RANGE - 0.5)))
		im.surface_add_vertex(Vector3(cos(a) * RANGE, 0.06, sin(a) * RANGE))
	im.surface_end()
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(1.0, 0.62, 0.36, 0.35)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.mesh = im
	ring.material_override = ring_mat
	root.add_child(ring)

	# HP bar riding above the head
	var back := MeshInstance3D.new()
	var back_quad := QuadMesh.new()
	back_quad.size = Vector2(1.1, 0.12)
	var back_mat := StandardMaterial3D.new()
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_mat.albedo_color = Color(0, 0, 0, 0.6)
	back_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	back_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	back_mat.no_depth_test = true
	back_quad.material = back_mat
	back.mesh = back_quad
	back.name = "HpBack"
	back.position.y = 2.35
	root.add_child(back)
	var fill := MeshInstance3D.new()
	var fill_quad := QuadMesh.new()
	fill_quad.size = Vector2(1.02, 0.07)
	var fill_mat := StandardMaterial3D.new()
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.albedo_color = Color(1.0, 0.55, 0.3)
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.no_depth_test = true
	fill_quad.material = fill_mat
	fill.mesh = fill_quad
	fill.name = "HpFill"
	fill.position.y = 2.35
	root.add_child(fill)
	return root


## The structures' stone, but triplanar in LOCAL space. A world-space
## projection slides across the head as it turns to track you, which on a rock
## is the one thing that gives away that it is not one.
static func _stone() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://Terrain/textures/rock.jpg")
	mat.albedo_color = Color(0.78, 0.76, 0.72)
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = false
	mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
	mat.roughness = 1.0
	return mat


## One drum of the body. Few facets and an odd count, turned off axis from its
## neighbour, so a stack of them looks quarried rather than turned.
static func _drum(mat: Material, bottom: float, top: float, h: float, y: float,
		facets: int, spin: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = bottom
	cm.top_radius = top
	cm.height = h
	cm.radial_segments = facets
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = mat
	mi.position.y = y
	mi.rotation.y = spin
	return mi


## One jaw: a chamfered slab swept from the hinge out to the lip, narrowing and
## thinning as it goes. Built with the same sweep the walls use, so the arris
## matches -- and so the taper is a varying section rather than a scaled box,
## which would have thinned the chamfer along with everything else.
static func _jaw(mat: Material) -> Node3D:
	var st := Ops.surface()
	var hulls: Array = []
	var rail := Ops.mitre_frames([Vector3(0, 0, 0.06), Vector3(0, 0, -0.62)])
	var profs: Array = [
		Profiles.chamfer(Profiles.rect(-0.52, 0.52, 0.0, 0.32), 0.11),
		Profiles.chamfer(Profiles.rect(-0.46, 0.46, 0.0, 0.13), 0.06),
	]
	Ops.sweep(st, rail, profs[0], hulls,
		{"caps": true, "profiles": profs, "ground": false, "hulls": false})
	var holder := Node3D.new()
	Ops.attach(holder, st, hulls, mat, false)
	# The lip: the one warm edge on the whole thing, so a shut mouth still reads
	# as a mouth and an open one reads as a threat.
	var lip := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.92, 0.06, 0.09)
	lip.mesh = lm
	var lip_mat := StandardMaterial3D.new()
	lip_mat.albedo_color = Color(0.92, 0.72, 0.24)
	lip_mat.roughness = 0.55
	lip_mat.emission_enabled = true
	lip_mat.emission = Color(0.5, 0.34, 0.06)
	lip_mat.emission_energy_multiplier = 0.5
	lip.material_override = lip_mat
	lip.position = Vector3(0, 0.03, -0.62)
	holder.add_child(lip)
	return holder
