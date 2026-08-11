extends Node3D

## Placeable props (web placeModel/currentModels): Ryan's buildings, trees,
## cactus, grass. Instanced from the imported .glb scenes with trimesh
## colliders, synced through the server's model registry.

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
const NO_COLLIDE := ["grass.glb"]

var _models: Dictionary = {}   # id -> Node3D


func _ready() -> void:
	add_to_group("world_props")
	Net.event_received.connect(_on_net_event)


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
	if id == "" or _models.has(id) or not MODEL_SCENES.has(model):
		return
	var inst: Node3D = MODEL_SCENES[model].instantiate()
	inst.position = Vector3(m.get("x", 0.0), m.get("y", 0.0), m.get("z", 0.0))
	inst.rotation.y = float(m.get("ry", 0.0))
	add_child(inst)
	if not model in NO_COLLIDE:
		_add_colliders(inst)
	_models[id] = inst


static func _add_colliders(node: Node) -> void:
	for child in node.get_children():
		_add_colliders(child)
	if node is MeshInstance3D:
		node.create_trimesh_collision()
