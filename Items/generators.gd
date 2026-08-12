extends Node3D

## Slayer heal generators: humming cylinders that restore +1 health per 2 s
## when you stand near one (the heal itself is server-side). Press E next to
## one to tie a rope and drag it (it slows you down a lot); E again drops it.
##
## In a vehicle it's F, and it isn't a rope at all: the core is racked on the
## nose and CARRIED. No tumbling boulder to fight, but a loaded hull crawls
## (vehicle.gd CARRY_THRUST / CARRY_CAP).
##
## Sync mirrors the vehicle pattern: the holder's client simulates the drag
## and relays generatorMoved ~10 Hz; everyone else interpolates. The rope is
## drawn on every client between the holder and the generator.

const GRAB_RANGE := 3.5
const TOW_RANGE := 6.0        # a vehicle can scoop one up from further out
const ROPE_LEN := 3.0
const ROPE_SNAP := 12.0       # overstretched: the rope lets go
const GEN_MASS := 140.0       # a big core is a boulder: hauling it is a chore
const MINI_MASS := 6.0        # corpse drops are luggable
# A person on a rope can only pull so hard, no matter what's on the other end,
# so a big core barely budges on foot. A vehicle doesn't pull at all — it
# picks the thing up (see _drag_step) and pays for it in speed.
const HAND_TENSION := 900.0   # newtons-ish, FLAT (not scaled by mass)
const PLAYER_PULL := 0.55     # ...times mass: the big one really fights back
const SETTLE_TIME := 1.4      # after release it keeps tumbling before freezing
const RELAY_INTERVAL := 0.1
const CARRY_MOUNT := Vector3(0.0, -0.15, -2.5)   # rack point in vehicle space
const CARRY_SNAP := 14.0      # how fast the core seats itself on the rack
const NET_LERP := 8.0
const HEAL_RANGE := 4.5  # matches the server's GEN_HEAL_RANGE ring
const LABEL_RANGE := 8.0 # energy readout only shows when you're right on it
const HUM_DB := 0.0
# CC0 loop from Kenney's Sci-Fi Sounds pack (kenney.nl, engineCircular_000)
const HumStream := preload("res://Audio/generator_hum.ogg")

@export var player: CharacterBody3D

var _gens: Dictionary = {}    # id -> {node, holder, net_pos}
var _held_id := ""            # generator I am dragging
var _carrying := false        # ...on a vehicle rack rather than a rope
var _carry_veh: Node3D        # the hull currently loaded, so we can unload it
var _gen_layer := 1           # collision bits, stashed while a core is racked
var _gen_mask := 1
var _settle_id := ""          # just dropped: still tumbling under physics
var _settle_t := 0.0
var _relay_cd := 0.0
var _sync: Node
var _rope: MeshInstance3D
var _rope_mesh: ImmediateMesh
var _prompt: PanelContainer
var _prompt_key: Label
var _prompt_suffix: Label


func _ready() -> void:
	add_to_group("world_generators")
	Net.event_received.connect(_on_net_event)
	_rope_mesh = ImmediateMesh.new()
	_rope = MeshInstance3D.new()
	_rope.mesh = _rope_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.85, 0.75, 0.5)
	_rope.material_override = mat
	add_child(_rope)
	_build_prompt()


## "E" keycap prompt, shown when you're close to a generator and looking at it.
func _build_prompt() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_prompt = PanelContainer.new()
	_prompt.visible = false
	_prompt.set_anchors_preset(Control.PRESET_CENTER)
	_prompt.offset_top = 60
	_prompt.offset_bottom = 96
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.add_theme_stylebox_override("panel",
		preload("res://UI/ui_style.gd").panel_box(Color(0, 0, 0, 0.65), 6))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_prompt.add_child(row)
	_prompt_key = Label.new()
	_prompt_key.text = " E "
	_prompt_key.add_theme_font_size_override("font_size", 16)
	row.add_child(_prompt_key)
	_prompt_suffix = Label.new()
	_prompt_suffix.add_theme_font_size_override("font_size", 16)
	_prompt_suffix.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_prompt_suffix.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_prompt_suffix)
	layer.add_child(_prompt)


func _self_id() -> String:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	return _sync.self_id if _sync else ""


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentGenerators":
			_drop_held(false)
			for id in _gens:
				_gens[id]["node"].queue_free()
			_gens.clear()
			for g in data:
				_add_gen(g)
		"generatorPlaced":
			_add_gen(data)
		"generatorRemoved":
			var id := str(data)
			if _held_id == id:
				_drop_held(false)
			if _gens.has(id):
				_gens[id]["node"].queue_free()
				_gens.erase(id)
		"generatorMoved":
			if data is Dictionary:
				var g: Dictionary = _gens.get(str(data.get("id", "")), {})
				if not g.is_empty() and _held_id != str(data.get("id", "")):
					g["net_pos"] = Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0))
		"generatorHolder":
			if data is Dictionary:
				var id := str(data.get("id", ""))
				var holder: Variant = data.get("holder")
				var holder_id := str(holder) if holder is String else ""
				if _gens.has(id):
					_gens[id]["holder"] = holder_id
					_gens[id]["carry"] = bool(data.get("carry", false))
				# Someone else won the grab race: let go locally.
				if _held_id == id and holder_id != _self_id():
					_drop_held(false)
		"generatorEnergy":
			if data is Dictionary:
				var gid := str(data.get("id", ""))
				if _gens.has(gid):
					var lbl: Label3D = _gens[gid]["label"]
					lbl.text = str(int(data.get("energy", 0)))


func _add_gen(g: Variant) -> void:
	if not g is Dictionary:
		return
	var id := str(g.get("id", ""))
	if id == "" or _gens.has(id):
		return
	var mini := bool(g.get("mini", false))
	var node := _make_generator_node(mini)
	add_child(node)
	var pos := Vector3(g.get("x", 0.0), g.get("y", 0.0), g.get("z", 0.0))
	node.global_position = pos
	var holder: Variant = g.get("holder")
	# Remaining energy floats above the unit
	var lbl := Label3D.new()
	lbl.text = str(int(g.get("energy", 0)))
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.font_size = 40
	lbl.outline_size = 10
	lbl.modulate = Color(0.55, 1.0, 0.7)
	lbl.position.y = 1.2 if mini else 1.8
	node.add_child(lbl)
	_gens[id] = {
		"node": node,
		"holder": str(holder) if holder is String else "",
		"carry": bool(g.get("carry", false)),
		"net_pos": pos,
		"label": lbl,
		"ring": node.get_node("HealRing"),
	}
	# Fresh generators FALL: whoever placed it (or whose corpse dropped it)
	# owns the physics drop and relays it — nobody's core hangs in the air.
	if str(g.get("owner", "")) == _self_id() and not (holder is String and holder != ""):
		if _settle_id != "" and _settle_id != id:
			_finish_settle(_settle_id, true)
		node.freeze = false
		node.sleeping = false
		_settle_id = id
		_settle_t = SETTLE_TIME + 1.0


## Nearest generator within `radius` — god menu delete tool. {} if none.
func nearest_deletable(pos: Vector3, radius := 4.0) -> Dictionary:
	var best := {}
	for id in _gens:
		var d: float = _gens[id]["node"].global_position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _gens[id]["node"].global_position}
	return best


# --- E interaction ----------------------------------------------------------

## E hauls a core on foot. In a vehicle E is the dismount, so the pickup
## is F — rack a core in range, press again to drop it.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo) \
			or get_viewport().gui_get_focus_owner() != null \
			or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			or player == null or player.godmode:
		return
	var towing := player.vehicle != null
	if event.keycode != (KEY_F if towing else KEY_E):
		return
	if _held_id != "":
		_drop_held(true)
		get_viewport().set_input_as_handled()
		return
	var anchor: Node3D = player.vehicle if towing else player
	var best_id := ""
	var best_d := TOW_RANGE if towing else GRAB_RANGE
	for id in _gens:
		if _gens[id]["holder"] != "" and _gens[id]["holder"] != _self_id():
			continue
		var d: float = _gens[id]["node"].global_position.distance_to(anchor.global_position)
		if d < best_d:
			best_d = d
			best_id = id
	if best_id != "":
		_grab(best_id)
		get_viewport().set_input_as_handled()


func _grab(id: String) -> void:
	if _settle_id == id:
		_settle_id = ""
	_held_id = id
	_gens[id]["holder"] = _self_id()
	var body: RigidBody3D = _gens[id]["node"]
	body.freeze = false
	body.sleeping = false
	_set_carry(player.vehicle != null)
	Net.emit_event("grabGenerator", {"id": id, "carry": _carrying})
	Sfx.boost(body.global_position, 0.4)


## Racked on a vehicle vs roped to a body. The mode can flip mid-hold (you
## dismount while loaded), so it's derived from where you are, told to the
## server for everyone else's rope drawing, and it drives both slowdowns.
func _set_carry(on: bool) -> void:
	if _held_id == "" or not _gens.has(_held_id):
		return
	_carrying = on
	_gens[_held_id]["carry"] = on
	if player:
		player.dragging_generator = not on
	# The loaded flag belongs to the hull we picked it up with, not to whatever
	# we happen to be sitting in now — bailing out has to unload the one we left.
	if is_instance_valid(_carry_veh):
		_carry_veh.carrying = false
	_carry_veh = player.vehicle if on and player else null
	if is_instance_valid(_carry_veh):
		_carry_veh.carrying = true
	var body: RigidBody3D = _gens[_held_id]["node"]
	# Racked: the mount owns its position, so physics stops fighting for it —
	# and it stops colliding, or the hull would ram its own cargo.
	body.freeze = on
	if on:
		if body.collision_layer != 0:
			_gen_layer = body.collision_layer
			_gen_mask = body.collision_mask
		body.collision_layer = 0
		body.collision_mask = 0
	else:
		body.collision_layer = _gen_layer
		body.collision_mask = _gen_mask
		body.sleeping = false


## Dropping doesn't stop it dead: it keeps tumbling for SETTLE_TIME (still
## relayed), then freezes in place and the server hold is released.
func _drop_held(tell_server: bool) -> void:
	if _held_id == "":
		return
	# Hands the core its physics and collision back (a racked one had neither)
	# before anything else lets go of it.
	_set_carry(false)
	var id := _held_id
	_held_id = ""
	if player:
		player.dragging_generator = false
	if not _gens.has(id):
		return
	# Let go of the rope the instant you press the key — the settle tumble
	# below is the core falling, not you still holding it.
	_gens[id]["holder"] = ""
	if tell_server:
		_settle_id = id
		_settle_t = SETTLE_TIME
	else:
		_finish_settle(id, false)


func _finish_settle(id: String, tell_server: bool) -> void:
	if _settle_id == id:
		_settle_id = ""
	if not _gens.has(id):
		return
	_gens[id]["holder"] = ""
	var body: RigidBody3D = _gens[id]["node"]
	body.freeze = true
	_gens[id]["net_pos"] = body.global_position
	if tell_server:
		Net.emit_event("generatorMoved", {
			"id": id,
			"x": body.global_position.x, "y": body.global_position.y, "z": body.global_position.z,
		})
		Net.emit_event("releaseGenerator", id)


func _physics_process(delta: float) -> void:
	# Dropped implicitly (death, godmode)
	if _held_id != "" and player and (player.godmode or player.dead):
		_drop_held(true)

	for id in _gens:
		var g: Dictionary = _gens[id]
		var body: RigidBody3D = g["node"]
		if id == _held_id and player:
			_drag_step(body, delta)
		elif id == _settle_id:
			pass  # free physics while it tumbles to rest
		else:
			# Remote-driven (dragged OR falling on its owner's client): chase
			# the relays. Parked units' net_pos is where they already are.
			body.global_position = body.global_position.lerp(g["net_pos"], 1.0 - exp(-NET_LERP * delta))

	# Just-released generator keeps tumbling briefly, then freezes + syncs
	if _settle_id != "":
		_settle_t -= delta
		var sbody: RigidBody3D = _gens[_settle_id]["node"] if _gens.has(_settle_id) else null
		if sbody and sbody.global_position.y < -20.0:
			sbody.global_position = player.respawn_point() + Vector3(0, 2, 0) if player else Vector3(0, 4, 0)
			sbody.linear_velocity = Vector3.ZERO
		if _settle_t <= 0.0:
			_finish_settle(_settle_id, true)

	var relay_id := _held_id if _held_id != "" else _settle_id
	if relay_id != "" and _gens.has(relay_id):
		_relay_cd -= delta
		if _relay_cd <= 0.0:
			_relay_cd = RELAY_INTERVAL
			var node: Node3D = _gens[relay_id]["node"]
			Net.emit_event("generatorMoved", {
				"id": relay_id,
				"x": node.global_position.x, "y": node.global_position.y, "z": node.global_position.z,
			})


## On foot the drag is FULL physics: the core is a heavy rigid body that
## tumbles and rolls; the rope only pulls when taut, the same tension yanks
## the hauler back, and because the pull is a FLAT force a 140 kg core barely
## creeps. Overstretch it and the rope snaps.
##
## In a vehicle there's no rope: the core rides a rack on the nose. It seats
## itself over a few frames instead of teleporting, so picking one up looks
## like scooping it rather than gluing it on.
func _drag_step(body: RigidBody3D, delta: float) -> void:
	var towing: bool = player.vehicle != null and is_instance_valid(player.vehicle)
	if towing != _carrying:
		# Mounted or bailed out while loaded: switch modes and re-tell the server
		# so remote clients stop (or start) drawing a rope to us.
		_set_carry(towing)
		Net.emit_event("grabGenerator", {"id": _held_id, "carry": _carrying})
	if towing:
		var veh: Node3D = player.vehicle
		var rack := veh.global_transform * CARRY_MOUNT
		body.global_position = body.global_position.lerp(rack, 1.0 - exp(-CARRY_SNAP * delta))
		body.linear_velocity = Vector3.ZERO
		return
	var anchor: Node3D = player
	var to_anchor := anchor.global_position - body.global_position
	var dist := to_anchor.length()
	if dist > ROPE_SNAP:
		_drop_held(true)
		return
	var stretch := clampf(dist - ROPE_LEN, 0.0, 6.0)
	if stretch > 0.0 and dist > 0.01:
		var dir := to_anchor / dist
		body.apply_central_force(dir * stretch * HAND_TENSION)
		player.velocity -= dir * stretch * PLAYER_PULL * body.mass * delta
	# Buried cores get dug out, and terrain keeps moving under them: anything
	# that ends up inside solid rock is pushed up until it's free again.
	var terrain: Node = get_tree().get_first_node_in_group("voxel_terrain")
	if terrain and terrain.density_at(body.global_position) > 0.55:
		body.global_position.y += 3.0 * delta
		body.linear_velocity.y = maxf(body.linear_velocity.y, 0.0)
	# Fell out of the world mid-drag: haul it back to a spawn
	if body.global_position.y < -20.0:
		body.global_position = player.respawn_point() + Vector3(0, 2, 0)
		body.linear_velocity = Vector3.ZERO


func _process(_delta: float) -> void:
	_draw_ropes()
	_update_prompt()
	_update_gen_visuals()


## The heal ring is ground furniture: it means nothing while the unit is in
## transit, so tethering hides it. The energy readout is only legible (and
## only worth reading) when you're standing at the generator.
func _update_gen_visuals() -> void:
	var eye := player.global_position if player else Vector3.ZERO
	for id in _gens:
		var g: Dictionary = _gens[id]
		var tethered: bool = g["holder"] != "" or id == _settle_id
		var ring: Node3D = g["ring"]
		ring.visible = not tethered
		# The ring is ground furniture, not part of the core: it's top-level so
		# a rolling core can't tip it on its side.
		ring.global_transform = Transform3D(
			Basis().scaled(Vector3(1.0, 0.06, 1.0)),
			g["node"].global_position + Vector3(0, -0.62, 0))
		g["label"].visible = player != null \
			and g["node"].global_position.distance_to(eye) < LABEL_RANGE


func _update_prompt() -> void:
	if _prompt == null or player == null:
		return
	if player.godmode or player.dead or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_prompt.visible = false
		return
	var towing: bool = player.vehicle != null and is_instance_valid(player.vehicle)
	_prompt_key.text = " F " if towing else " E "
	if _held_id != "":
		_prompt.visible = true
		_prompt_suffix.text = "release"
		return
	var anchor: Node3D = player.vehicle if towing else player
	var cam := get_viewport().get_camera_3d()
	var near := false
	for id in _gens:
		var g: Dictionary = _gens[id]
		if g["holder"] != "" and g["holder"] != _self_id():
			continue
		var node: Node3D = g["node"]
		if node.global_position.distance_to(anchor.global_position) > (TOW_RANGE if towing else GRAB_RANGE):
			continue
		# On foot you have to be looking at it; a scoop just needs proximity
		if cam and not towing:
			var to_gen: Vector3 = (node.global_position - cam.global_position).normalized()
			if to_gen.dot(-cam.global_transform.basis.z) < 0.5:
				continue
		near = true
		break
	_prompt.visible = near
	if near:
		_prompt_suffix.text = "carry" if towing else "drag"


## Rope lines between every held generator and its holder (self or remote).
func _draw_ropes() -> void:
	_rope_mesh.clear_surfaces()
	var any := false
	for id in _gens:
		var g: Dictionary = _gens[id]
		# A racked core has no rope to draw — it's sitting on the vehicle.
		if g["holder"] == "" or g.get("carry", false):
			continue
		var holder_pos: Vector3
		if g["holder"] == _self_id():
			if player == null:
				continue
			holder_pos = player.global_position
		else:
			var remotes: Dictionary = _sync.remotes() if _sync else {}
			if not remotes.has(g["holder"]):
				continue
			holder_pos = remotes[g["holder"]].global_position
		if not any:
			any = true
			_rope_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		# One taut line, hauler to core
		_rope_mesh.surface_add_vertex(holder_pos + Vector3(0, 0.4, 0))
		_rope_mesh.surface_add_vertex(g["node"].global_position + Vector3(0, 0.6, 0))
	if any:
		_rope_mesh.surface_end()


# --- Visuals ----------------------------------------------------------------

## A generator body: full rigid physics (it tumbles and rolls when dragged),
## frozen in place while parked so it never drifts out of sync. Minis are
## the corpse drops: smaller, quieter, higher-pitched.
func _make_generator_node(mini := false) -> RigidBody3D:
	var root := RigidBody3D.new()
	root.mass = MINI_MASS if mini else GEN_MASS
	root.freeze = true
	root.linear_damp = 0.6
	root.angular_damp = 1.0
	var scale_f := 0.55 if mini else 1.0
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.65 * scale_f
	shape.height = 1.4 * scale_f
	col.shape = shape
	col.position.y = 0.0
	root.add_child(col)

	# The body: an octagonal drum matching the collider exactly
	var drum := MeshInstance3D.new()
	drum.mesh = _octagon_mesh(0.65 * scale_f, 1.4 * scale_f)
	root.add_child(drum)

	# Glowing core ring
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.55
	torus.outer_radius = 0.72
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(0.4, 1.0, 0.6)
	glow.emission_enabled = true
	glow.emission = Color(0.4, 1.0, 0.6)
	glow.emission_energy_multiplier = 2.2
	torus.material = glow
	ring.mesh = torus
	ring.position.y = 0.15 * scale_f
	ring.scale = Vector3.ONE * scale_f
	root.add_child(ring)

	# The hum: positional loop; minis are quieter and pitched up
	var hum := AudioStreamPlayer3D.new()
	var stream: AudioStreamOggVorbis = HumStream.duplicate()
	stream.loop = true
	hum.stream = stream
	hum.volume_db = HUM_DB - (9.0 if mini else 0.0)
	hum.pitch_scale = 1.55 if mini else 1.0
	hum.unit_size = 6.0
	hum.max_distance = 18.0 if mini else 35.0
	hum.autoplay = true
	root.add_child(hum)

	# Heal range shown as a ring on the ground (hidden while it's tethered)
	var ring_r := MeshInstance3D.new()
	ring_r.name = "HealRing"
	var torus2 := TorusMesh.new()
	torus2.inner_radius = HEAL_RANGE - 0.18
	torus2.outer_radius = HEAL_RANGE
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(0.4, 1.0, 0.6, 0.45)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	torus2.material = ring_mat
	ring_r.mesh = torus2
	ring_r.top_level = true   # stays flat on the ground while the core rolls
	root.add_child(ring_r)

	return root


## An octagonal drum: flat-shaded sides plus caps, sized to the collider.
## Reads as machined metal without needing a model, and unlike a smooth
## cylinder you can see it spin when you drag it around.
func _octagon_mesh(radius: float, height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hy := height * 0.5
	var pts: Array = []
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0  # half-step so a flat face points forward
		pts.append(Vector2(cos(a) * radius, sin(a) * radius))
	for i in 8:
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % 8]
		var n := Vector3(p.x + q.x, 0, p.y + q.y).normalized()
		st.set_normal(n)
		for v in [
			Vector3(p.x, -hy, p.y), Vector3(q.x, hy, q.y), Vector3(p.x, hy, p.y),
			Vector3(p.x, -hy, p.y), Vector3(q.x, -hy, q.y), Vector3(q.x, hy, q.y),
		]:
			st.add_vertex(v)
		# Caps, fanned from the center
		st.set_normal(Vector3.UP)
		for v in [Vector3(0, hy, 0), Vector3(p.x, hy, p.y), Vector3(q.x, hy, q.y)]:
			st.add_vertex(v)
		st.set_normal(Vector3.DOWN)
		for v in [Vector3(0, -hy, 0), Vector3(q.x, -hy, q.y), Vector3(p.x, -hy, p.y)]:
			st.add_vertex(v)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.45, 0.5)
	mat.metallic = 0.6
	mat.roughness = 0.45
	st.set_material(mat)
	return st.commit()
