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
const FOLLOW_RATE := 4.0      # drag spring: how hard it chases the rope point
const RELAY_INTERVAL := 0.1
const NET_LERP := 8.0
const HUM_DB := 2.0
const HumStream := preload("res://Audio/generator_hum.wav")

@export var player: CharacterBody3D

var _gens: Dictionary = {}    # id -> {node, holder, net_pos}
var _held_id := ""            # generator I am dragging
var _relay_cd := 0.0
var _sync: Node
var _rope: MeshInstance3D
var _rope_mesh: ImmediateMesh


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


func _add_gen(g: Variant) -> void:
	if not g is Dictionary:
		return
	var id := str(g.get("id", ""))
	if id == "" or _gens.has(id):
		return
	var node := _make_generator_node()
	add_child(node)
	var pos := Vector3(g.get("x", 0.0), g.get("y", 0.0), g.get("z", 0.0))
	node.global_position = pos
	var holder: Variant = g.get("holder")
	_gens[id] = {
		"node": node,
		"holder": str(holder) if holder is String else "",
		"net_pos": pos,
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
	_held_id = id
	_gens[id]["holder"] = _self_id()
	player.dragging_generator = true
	Net.emit_event("grabGenerator", id)
	Sfx.boost(_gens[id]["node"].global_position, 0.4)


func _drop_held(tell_server: bool) -> void:
	if _held_id == "":
		return
	var id := _held_id
	_held_id = ""
	if player:
		player.dragging_generator = false
	if _gens.has(id):
		_gens[id]["holder"] = ""
		var node: Node3D = _gens[id]["node"]
		_gens[id]["net_pos"] = node.global_position
		if tell_server:
			Net.emit_event("generatorMoved", {
				"id": id,
				"x": node.global_position.x, "y": node.global_position.y, "z": node.global_position.z,
			})
			Net.emit_event("releaseGenerator", id)


func _process(delta: float) -> void:
	# Dropped implicitly (death, godmode, vehicle)
	if _held_id != "" and player and (player.godmode or player.vehicle != null or player.dead):
		_drop_held(true)

	for id in _gens:
		var g: Dictionary = _gens[id]
		var node: Node3D = g["node"]
		if id == _held_id and player:
			# Drag physics: chase a point ROPE_LEN behind the player, hug the ground
			var to_gen: Vector3 = node.global_position - player.global_position
			to_gen.y = 0.0
			if to_gen.length() < 0.2:
				to_gen = Vector3(0, 0, 1)
			var target: Vector3 = player.global_position + to_gen.normalized() * ROPE_LEN
			var floor_y := _ground_y(target, node.global_position.y)
			target.y = floor_y + 0.75
			node.global_position = node.global_position.lerp(target, 1.0 - exp(-FOLLOW_RATE * delta))
			node.rotate_y(delta * 0.8)  # lazy spin while dragged
		elif g["holder"] != "":
			node.global_position = node.global_position.lerp(g["net_pos"], 1.0 - exp(-NET_LERP * delta))

	if _held_id != "":
		_relay_cd -= delta
		if _relay_cd <= 0.0:
			_relay_cd = RELAY_INTERVAL
			var node: Node3D = _gens[_held_id]["node"]
			Net.emit_event("generatorMoved", {
				"id": _held_id,
				"x": node.global_position.x, "y": node.global_position.y, "z": node.global_position.z,
			})

	_draw_ropes()


func _ground_y(pos: Vector3, fallback: float) -> float:
	if player == null:
		return fallback
	var from := pos + Vector3(0, 2.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -8.0, 0))
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if hit else fallback


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

func _make_generator_node() -> Node3D:
	var root := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.65
	shape.height = 1.4
	col.shape = shape
	col.position.y = 0.0
	root.add_child(col)

	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 0.68
	cyl.height = 1.4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.4, 0.45)
	mat.metallic = 0.8
	mat.roughness = 0.35
	cyl.material = mat
	body.mesh = cyl
	root.add_child(body)

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
	ring.position.y = 0.15
	root.add_child(ring)

	# The hum: positional, audible within ~35 m
	var hum := AudioStreamPlayer3D.new()
	var stream: AudioStreamWAV = HumStream.duplicate()
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = stream.data.size() / 2  # 16-bit mono: frames = bytes/2
	hum.stream = stream
	hum.volume_db = HUM_DB
	hum.unit_size = 6.0
	hum.max_distance = 35.0
	hum.autoplay = true
	root.add_child(hum)

	return root
