extends RefCounted

## Loading a Blender export as a level, shared by the campaign and by any
## deathmatch map dropped into res://maps/. Everything the game wants from
## the file rides on object NAMES:
##
##   <anything>-col        a mesh Godot gives trimesh collision on import
##   Spawn, Spawn_3        spawn points (empties)
##   Pedestal_red_2        an item pedestal spot (red = weapons, green = movement)
##   NPC_key / Crate_x / Checkpoint_X / QuestBoard   campaign markers
##
## A file with no -col names at all still has to be walkable, so every mesh
## gets a trimesh body when the import produced none.

const MARKER_PREFIXES := ["Spawn", "NPC_", "Crate_", "Checkpoint_", "QuestBoard", "Pedestal_"]


## First existing path wins; FRIENDSLOP_WORLD overrides.
static func pick(paths: Array) -> String:
	var forced := OS.get_environment("FRIENDSLOP_WORLD")
	if forced != "" and ResourceLoader.exists(forced):
		return forced
	for p in paths:
		if ResourceLoader.exists(str(p)):
			return str(p)
	return ""


static func instantiate(path: String) -> Node3D:
	var packed: PackedScene = load(path)
	var world := packed.instantiate() as Node3D
	world.name = "World"
	return world


## Trimesh bodies for every mesh, unless the author marked collision themself.
static func ensure_collision(root: Node) -> int:
	for n in all_nodes(root):
		if n is StaticBody3D:
			return 0
	var made := 0
	for mi in meshes(root):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		col.shape = m.mesh.create_trimesh_shape()
		body.add_child(col)
		m.add_child(body)
		made += 1
	return made


## Every Node3D whose name starts with one of the marker prefixes.
static func markers(root: Node) -> Array:
	var out: Array = []
	for n in all_nodes(root):
		if not (n is Node3D):
			continue
		for p in MARKER_PREFIXES:
			if (n as Node3D).name.begins_with(p):
				out.append(n)
				break
	return out


## The markers of one kind, e.g. "Spawn" -> [Spawn, Spawn_1, Spawn.001 ...]
static func of_kind(marks: Array, prefix: String) -> Array:
	var out: Array = []
	for m in marks:
		if (m as Node3D).name.begins_with(prefix):
			out.append(m)
	return out


## The Blender-side name without a ".001" suffix.
static func base_name(n: Node3D) -> String:
	return n.name.get_slice(".", 0)


static func all_nodes(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(all_nodes(c))
	return out


static func meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(meshes(c))
	return out


## Height of the highest surface under a point once physics is live, or 0.
static func top_at(world: World3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 300, 0), p + Vector3(0, -300, 0))
	var hit := world.direct_space_state.intersect_ray(q)
	return float(hit["position"].y) if hit else 0.0
