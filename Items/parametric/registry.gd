extends RefCounted

## Type name to model script, and the one place anything asks a model a
## question. Adding a structure is a file in models/ and a line here; the
## network payload, the save file, the god-menu readout and the handles all come
## off the spec that file declares.

const Spec := preload("res://Items/parametric/spec.gd")

const MODELS := {
	"wall": preload("res://Items/parametric/models/wall.gd"),
	"tower": preload("res://Items/parametric/models/tower.gd"),
	"bridge": preload("res://Items/parametric/models/bridge.gd"),
	"path": preload("res://Items/parametric/models/path.gd"),
}


static func types() -> Array:
	return MODELS.keys()


static func has(type: String) -> bool:
	return MODELS.has(type)


static func spec(type: String) -> Array:
	return MODELS[type].spec() if MODELS.has(type) else []


static func min_nodes(type: String) -> int:
	return MODELS[type].min_nodes() if MODELS.has(type) else 2


static func defaults(type: String) -> Dictionary:
	return Spec.defaults(spec(type))


## Build from a record: {type, nodes, params}. Returns a StaticBody3D the caller
## parents and owns, or null for a type nobody knows.
static func build(rec: Dictionary, mat: Material, collide := true) -> Node3D:
	var type := str(rec.get("type", ""))
	if not MODELS.has(type):
		return null
	var nodes := to_points(rec.get("nodes", []))
	if nodes.size() < min_nodes(type):
		return null
	var params := Spec.sanitize(spec(type), rec.get("params", {}))
	return MODELS[type].build(nodes, params, mat, collide, to_points(rec.get("holes", [])))


static func handles(rec: Dictionary) -> Array:
	var type := str(rec.get("type", ""))
	if not MODELS.has(type):
		return []
	var nodes := to_points(rec.get("nodes", []))
	if nodes.size() < min_nodes(type):
		return []
	var raw: Array = MODELS[type].handles(nodes, Spec.sanitize(spec(type), rec.get("params", {})))
	var out: Array = []
	for h in raw:
		if not (h as Dictionary).is_empty():
			out.append(h)
	return out


## Records arrive off the wire as arrays of {x,y,z} dictionaries and are held
## in-engine as Vector3. One conversion, in one place.
static func to_points(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for n in raw:
			if n is Vector3:
				out.append(n)
			elif n is Dictionary:
				out.append(Vector3(n.get("x", 0.0), n.get("y", 0.0), n.get("z", 0.0)))
	return out


## How a structure looks, kept here rather than in each caller: the god menu,
## the world node and the probes were all making their own copy of the same
## material, which is three chances to drift and no batching.
static func stone() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://Terrain/textures/rock.jpg")
	mat.albedo_color = Color(0.78, 0.76, 0.72)
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(0.22, 0.22, 0.22)
	mat.roughness = 1.0
	return mat


## A placement preview: what you are about to build, before you build it.
static func ghost() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func to_wire(points: Array) -> Array:
	var out: Array = []
	for p in points:
		var v: Vector3 = p
		out.append({"x": v.x, "y": v.y, "z": v.z})
	return out
