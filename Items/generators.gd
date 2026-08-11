extends Node3D

## Slayer heal generators: humming cylinders that restore +1 health per 2 s
## when you stand near one (the heal itself is server-side). Press E next to
## one to tie a rope and drag it (it slows you down a lot); E again drops it.
##
## Sync mirrors the vehicle pattern: the holder's client simulates the drag
## and relays generatorMoved ~10 Hz; everyone else interpolates. The rope is
## drawn on every client between the holder and the generator.

const GRAB_RANGE := 3.5
const ROPE_LEN := 3.0
const ROPE_SNAP := 12.0       # overstretched: the rope lets go
const GEN_MASS := 8.0         # it's HEAVY
const SPRING_F := 520.0       # rope tension force on the generator when taut
const PLAYER_PULL := 16.0     # ...and the weight yanking the player back
const SETTLE_TIME := 1.4      # after release it keeps tumbling before freezing
const RELAY_INTERVAL := 0.1
const NET_LERP := 8.0
const HEAL_RANGE := 4.5  # matches the server's GEN_HEAL_RANGE ring
const HUM_DB := 0.0
# CC0 loop from Kenney's Sci-Fi Sounds pack (kenney.nl, engineCircular_000)
const HumStream := preload("res://Audio/generator_hum.ogg")
# CC0 models from Kenney's Space Kit
const BigGenModel := preload("res://Models/kenney/machine_generatorLarge.glb")
const MiniGenModel := preload("res://Models/kenney/machine_generator.glb")
const VehicleScript := preload("res://Vehicles/vehicle.gd")  # for _model_aabb

@export var player: CharacterBody3D

var _gens: Dictionary = {}    # id -> {node, holder, net_pos}
var _held_id := ""            # generator I am dragging
var _settle_id := ""          # just dropped: still tumbling under physics
var _settle_t := 0.0
var _relay_cd := 0.0
var _sync: Node
var _rope: MeshInstance3D
var _rope_mesh: ImmediateMesh
var _prompt: PanelContainer
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
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.65)
	style.border_color = Color(1, 1, 1, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(6)
	_prompt.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_prompt.add_child(row)
	var key := Label.new()
	key.text = " E "
	key.add_theme_font_size_override("font_size", 18)
	row.add_child(key)
	_prompt_suffix = Label.new()
	_prompt_suffix.add_theme_font_size_override("font_size", 13)
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
		"net_pos": pos,
		"label": lbl,
	}


## Nearest generator within `radius` — god menu delete tool. {} if none.
func nearest_deletable(pos: Vector3, radius := 4.0) -> Dictionary:
	var best := {}
	for id in _gens:
		var d: float = _gens[id]["node"].global_position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _gens[id]["node"].global_position}
	return best


# --- E interaction ----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_E \
			and get_viewport().gui_get_focus_owner() == null \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and player != null and not player.godmode and player.vehicle == null:
		if _held_id != "":
			_drop_held(true)
			get_viewport().set_input_as_handled()
			return
		var best_id := ""
		var best_d := GRAB_RANGE
		for id in _gens:
			if _gens[id]["holder"] != "" and _gens[id]["holder"] != _self_id():
				continue
			var d: float = _gens[id]["node"].global_position.distance_to(player.global_position)
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
	player.dragging_generator = true
	Net.emit_event("grabGenerator", id)
	Sfx.boost(body.global_position, 0.4)


## Dropping doesn't stop it dead: it keeps tumbling for SETTLE_TIME (still
## relayed), then freezes in place and the server hold is released.
func _drop_held(tell_server: bool) -> void:
	if _held_id == "":
		return
	var id := _held_id
	_held_id = ""
	if player:
		player.dragging_generator = false
	if not _gens.has(id):
		return
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
	# Dropped implicitly (death, godmode, vehicle)
	if _held_id != "" and player and (player.godmode or player.vehicle != null or player.dead):
		_drop_held(true)

	for id in _gens:
		var g: Dictionary = _gens[id]
		var body: RigidBody3D = g["node"]
		if id == _held_id and player:
			_drag_step(body, delta)
		elif id == _settle_id:
			pass  # free physics while it tumbles to rest
		elif g["holder"] != "":
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


## The drag is FULL physics: the generator is a heavy rigid body that
## tumbles and rolls; the rope only pulls when taut, and the same tension
## yanks the PLAYER back — its weight (plus it snagging on terrain and
## walls) is what slows you down. Overstretch it and the rope snaps.
func _drag_step(body: RigidBody3D, delta: float) -> void:
	var to_player := player.global_position - body.global_position
	var dist := to_player.length()
	if dist > ROPE_SNAP:
		_drop_held(true)
		return
	var stretch := clampf(dist - ROPE_LEN, 0.0, 6.0)
	if stretch > 0.0 and dist > 0.01:
		var dir := to_player / dist
		body.apply_central_force(dir * stretch * SPRING_F)
		player.velocity -= dir * stretch * PLAYER_PULL * delta
	# Fell out of the world mid-drag: haul it back to a spawn
	if body.global_position.y < -20.0:
		body.global_position = player.respawn_point() + Vector3(0, 2, 0)
		body.linear_velocity = Vector3.ZERO


func _process(_delta: float) -> void:
	_draw_ropes()
	_update_prompt()


func _update_prompt() -> void:
	if _prompt == null or player == null:
		return
	if player.godmode or player.dead or player.vehicle != null \
			or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_prompt.visible = false
		return
	if _held_id != "":
		_prompt.visible = true
		_prompt_suffix.text = "release"
		return
	var cam := get_viewport().get_camera_3d()
	var looking := false
	for id in _gens:
		var g: Dictionary = _gens[id]
		if g["holder"] != "" and g["holder"] != _self_id():
			continue
		var node: Node3D = g["node"]
		if node.global_position.distance_to(player.global_position) > GRAB_RANGE:
			continue
		if cam:
			var to_gen: Vector3 = (node.global_position - cam.global_position).normalized()
			if to_gen.dot(-cam.global_transform.basis.z) < 0.5:
				continue
		looking = true
		break
	_prompt.visible = looking
	if looking:
		_prompt_suffix.text = "drag"


## Rope lines between every held generator and its holder (self or remote).
func _draw_ropes() -> void:
	_rope_mesh.clear_surfaces()
	var any := false
	for id in _gens:
		var g: Dictionary = _gens[id]
		if g["holder"] == "":
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
		var a: Vector3 = holder_pos + Vector3(0, 0.4, 0)
		var b: Vector3 = g["node"].global_position + Vector3(0, 0.6, 0)
		# Slight sag: draw as two segments through a dipped midpoint
		var mid := (a + b) / 2.0 + Vector3(0, -0.35, 0)
		_rope_mesh.surface_add_vertex(a)
		_rope_mesh.surface_add_vertex(mid)
		_rope_mesh.surface_add_vertex(mid)
		_rope_mesh.surface_add_vertex(b)
	if any:
		_rope_mesh.surface_end()


# --- Visuals ----------------------------------------------------------------

## A generator body: full rigid physics (it tumbles and rolls when dragged),
## frozen in place while parked so it never drifts out of sync. Minis are
## the corpse drops: smaller, quieter, higher-pitched.
func _make_generator_node(mini := false) -> RigidBody3D:
	var root := RigidBody3D.new()
	root.mass = GEN_MASS * (0.4 if mini else 1.0)
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

	# Kenney machine model, normalized to the collider height and grounded
	var model: Node3D = (MiniGenModel if mini else BigGenModel).instantiate()
	root.add_child(model)
	var box: AABB = VehicleScript._model_aabb(model)
	if box.size.y > 0.01:
		var s := (1.4 * scale_f) / box.size.y
		var c := box.get_center()
		model.scale = Vector3.ONE * s
		# Recenter x/z too: Kenney GLB origins sit off-center
		model.position = Vector3(-c.x * s, -0.7 * scale_f - box.position.y * s, -c.z * s)

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

	# Heal range shown as a ring on the ground
	var ring_r := MeshInstance3D.new()
	var torus2 := TorusMesh.new()
	torus2.inner_radius = HEAL_RANGE - 0.18
	torus2.outer_radius = HEAL_RANGE
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(0.4, 1.0, 0.6, 0.45)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	torus2.material = ring_mat
	ring_r.mesh = torus2
	ring_r.scale.y = 0.06
	ring_r.position.y = -0.62
	root.add_child(ring_r)

	return root
