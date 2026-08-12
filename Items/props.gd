extends Node3D

## Placeable props (web placeModel/currentModels): Ryan's buildings, trees,
## cactus, grass, plus a procedural cave lamp. Instanced from the imported
## .glb scenes with trimesh colliders, synced through the server's model
## registry.
##
## Props live ON the topology: grass clumps scatter procedurally when a map
## generates, and every non-building prop is re-seated on the surface as the
## terrain deforms — a slope too steep to stand on makes the prop vanish.

const MODEL_SCENES := {
	"building_1.glb": preload("res://Models/building_1.glb"),
	"building_2.glb": preload("res://Models/building_2.glb"),
	"building_3.glb": preload("res://Models/building_3.glb"),
	"building_4.glb": preload("res://Models/building_4.glb"),
	"building_5.glb": preload("res://Models/building_5.glb"),
	"cactus.glb": preload("res://Models/cactus.glb"),
	"grass.glb": preload("res://Models/grass.glb"),
	"tree_1.glb": preload("res://Models/tree_1.glb"),
}

# Scenery you walk straight through
const NO_COLLIDE := ["grass.glb", "lamp.glb"]

const RESEAT_INTERVAL := 0.7   # how often props re-check the ground under them
const MAX_SLOPE_Y := 0.72      # surface normal.y below this = too steep to live
const GRASS_CLUMPS := 30

var _models: Dictionary = {}   # id -> Node3D
var _decor: Array = []         # local grass clumps (never synced)
var _reseat_cd := 0.0


func _ready() -> void:
	add_to_group("world_props")
	Net.event_received.connect(_on_net_event)
	if Net.creative_grid != null:
		# Terrain is being built this frame; scatter once its colliders exist
		get_tree().create_timer(0.6).timeout.connect(_scatter_grass)


## Instance any placeable model, including the procedural ones.
static func instantiate_model(model: String) -> Node3D:
	if model == "lamp.glb":
		return make_lamp()
	if MODEL_SCENES.has(model):
		return MODEL_SCENES[model].instantiate()
	return null


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentModels":
			for id in _models:
				_models[id].queue_free()
			_models.clear()
			for m in data:
				_add_model(m)
		"modelPlaced":
			_add_model(data)
		"modelRemoved":
			var id := str(data)
			if _models.has(id):
				_models[id].queue_free()
				_models.erase(id)
		"creativeGrid":
			# Fresh map: fresh grass, once the new terrain has settled in
			get_tree().create_timer(0.6).timeout.connect(_scatter_grass)


## Nearest prop within `radius` — god menu delete tool. {} if none.
func nearest_deletable(pos: Vector3, radius := 4.0) -> Dictionary:
	var best := {}
	for id in _models:
		var d: float = _models[id].global_position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _models[id].global_position}
	return best


func _add_model(m: Dictionary) -> void:
	var id := str(m.get("id", ""))
	var model := str(m.get("model", ""))
	if id == "" or _models.has(id):
		return
	var inst := instantiate_model(model)
	if inst == null:
		return
	inst.position = Vector3(m.get("x", 0.0), m.get("y", 0.0), m.get("z", 0.0))
	inst.rotation.y = float(m.get("ry", 0.0))
	inst.scale = Vector3.ONE * clampf(float(m.get("s", 1.0)), 0.2, 6.0)
	inst.set_meta("model", model)
	add_child(inst)
	if not model in NO_COLLIDE:
		_add_colliders(inst)
	_models[id] = inst


static func _add_colliders(node: Node) -> void:
	for child in node.get_children():
		_add_colliders(child)
	if node is MeshInstance3D:
		node.create_trimesh_collision()


# --- Cave lamp (procedural: a lantern sitting on the floor + a real light) ---
# No post: it's a lamp you set down. The light itself does the work — big
# range and enough energy to actually open up a dug-out cavern.

static func make_lamp() -> Node3D:
	var root := Node3D.new()
	var base := MeshInstance3D.new()
	var plate := CylinderMesh.new()
	plate.top_radius = 0.22
	plate.bottom_radius = 0.28
	plate.height = 0.12
	var plate_mat := StandardMaterial3D.new()
	plate_mat.albedo_color = Color(0.16, 0.15, 0.14)
	plate_mat.metallic = 0.5
	plate.material = plate_mat
	base.mesh = plate
	base.position.y = 0.06
	root.add_child(base)
	var lantern := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 0.5, 0.4)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(1.0, 0.86, 0.6)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.8, 0.45)
	glow.emission_energy_multiplier = 4.5
	box.material = glow
	lantern.mesh = box
	lantern.position.y = 0.37
	root.add_child(lantern)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.58)
	light.light_energy = 6.0
	light.omni_range = 44.0
	light.omni_attenuation = 0.9   # slow falloff: lights a whole chamber
	light.position.y = 0.55
	light.shadow_enabled = false  # cheap: these get sprinkled through caves
	root.add_child(light)
	return root


# --- Grass clumps + topology re-seating --------------------------------------

## Deterministic scatter (seeded from the painted grid) so every client grows
## the same field. Clumps of 3-6 tufts, seated on whatever the ray hits.
func _scatter_grass() -> void:
	if not is_inside_tree():
		return
	for n in _decor:
		if is_instance_valid(n):
			n.queue_free()
	_decor.clear()
	if Net.creative_grid == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(Net.creative_grid))
	# Scatter across whatever the painted region actually spans
	var t: Node = get_tree().get_first_node_in_group("voxel_terrain")
	var hx: float = (t.paint_half_x() if t else 64.0) - 2.0
	var hz: float = (t.paint_half_z() if t else 64.0) - 2.0
	for _i in GRASS_CLUMPS:
		var cx := rng.randf_range(-hx, hx)
		var cz := rng.randf_range(-hz, hz)
		for _j in rng.randi_range(3, 6):
			var x := cx + rng.randf_range(-2.4, 2.4)
			var z := cz + rng.randf_range(-2.4, 2.4)
			var hit := _ground_at(Vector3(x, 60.0, z))
			if hit.is_empty() or hit["normal"].y < MAX_SLOPE_Y:
				continue
			var tuft: Node3D = MODEL_SCENES["grass.glb"].instantiate()
			tuft.rotation.y = rng.randf_range(0.0, TAU)
			tuft.scale = Vector3.ONE * rng.randf_range(0.7, 1.4)
			add_child(tuft)
			tuft.global_position = hit["position"]
			_decor.append(tuft)


func _ground_at(from: Vector3, exclude: Array = []) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 130.0)
	q.exclude = exclude
	return get_world_3d().direct_space_state.intersect_ray(q)


func _physics_process(delta: float) -> void:
	_reseat_cd -= delta
	if _reseat_cd > 0.0:
		return
	_reseat_cd = RESEAT_INTERVAL
	_reseat()


## Deforming terrain carries props with it. Buildings are architecture and
## stay put; everything else follows the surface or, on a slope too steep,
## disappears.
func _reseat() -> void:
	for i in range(_decor.size() - 1, -1, -1):
		var tuft: Node3D = _decor[i]
		if not is_instance_valid(tuft):
			_decor.remove_at(i)
			continue
		if not _reseat_node(tuft, []):
			tuft.queue_free()
			_decor.remove_at(i)
	for id in _models.keys():
		var node: Node3D = _models[id]
		if not is_instance_valid(node):
			continue
		if str(node.get_meta("model", "")).begins_with("building"):
			continue
		var rids: Array = []
		_body_rids(node, rids)
		if not _reseat_node(node, rids):
			Net.emit_event("removeModel", id)  # idempotent; removal echoes back


## Snap a prop back onto the surface under it. Returns false when there is no
## survivable ground there anymore. The ray starts just above the prop, NOT in
## the sky — a lamp in a cave must seat on the cave floor, not pop up through
## the ceiling onto the overworld.
func _reseat_node(node: Node3D, exclude: Array) -> bool:
	var pos := node.global_position
	var hit := _ground_at(pos + Vector3(0, 2.5, 0), exclude)
	if hit.is_empty() or hit["normal"].y < MAX_SLOPE_Y:
		return false
	if absf(hit["position"].y - pos.y) > 0.06:
		node.global_position.y = hit["position"].y
	return true


static func _body_rids(node: Node, out: Array) -> void:
	if node is CollisionObject3D:
		out.append(node.get_rid())
	for child in node.get_children():
		_body_rids(child, out)
