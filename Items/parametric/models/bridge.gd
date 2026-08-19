extends RefCounted

## A bridge: a kerbed deck swept along a smooth rail, with piers dropped at
## intervals to whatever is under them. The rail curves rather than folding,
## because a marble at speed reads a kink as a wall.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")
const Spec := preload("res://Items/parametric/spec.gd")

const PIER_DROP := 40.0    # how far a pier reaches for the ground before giving up
const PIER_W := 1.1


static func spec() -> Array:
	return [
		Spec.param("width", "WIDTH", 1.5, 12.0, 3.0, 0.25),
		Spec.param("thick", "DECK", 0.2, 3.0, 0.6, 0.05),
		Spec.param("kerb", "KERB", 0.0, 2.0, 0.45, 0.05),
		Spec.param("pier", "PIERS", 0.0, 1.0, 1.0, 1.0, ""),
		Spec.param("span", "SPAN", 4.0, 40.0, 16.0, 1.0),
	]


static func min_nodes() -> int:
	return 2


static func build(nodes: Array, params: Dictionary, mat: Material,
		collide := true, _holes := []) -> Node3D:
	var s := spec()
	var body := StaticBody3D.new()
	var frames := Ops.curve_frames(nodes, {"spacing": 1.8})
	if frames.size() < 2:
		return body

	var half := Spec.value(s, params, "width") * 0.5
	var thick := Spec.value(s, params, "thick")
	var st := Ops.surface()
	var hulls: Array = []
	# A deck is in the air, and its piers meet the ground at their own feet
	# rather than at the rail, so neither takes the ground blend.
	Ops.sweep(st, frames, Profiles.deck(half, thick,
		Spec.value(s, params, "kerb")), hulls, {"caps": true, "ground": false})

	if Spec.flag(s, params, "pier"):
		var drop := _ground_finder(body)
		for d in Ops.repeat_distances(frames, Spec.value(s, params, "span")):
			_pier(st, hulls, Ops.slice(frames, float(d) - PIER_W * 0.5,
				float(d) + PIER_W * 0.5), thick, drop)

	Ops.attach(body, st, hulls, mat, collide)
	return body


## Piers reach down from the deck soffit. Without a world to cast against (a
## ghost preview, a thumbnail) they fall back to a stub, so the shape still
## reads as a bridge rather than a floating plank.
static func _pier(st: SurfaceTool, hulls: Array, span: Array, thick: float,
		drop: Callable) -> void:
	if span.size() < 2:
		return
	var top: Vector3 = span[0]["p"]
	var depth: float = drop.call(top)
	if depth < 0.4:
		return
	Ops.sweep(st, span, Profiles.rect(-PIER_W * 0.5, PIER_W * 0.5,
		-thick - depth, -thick + 0.05), hulls, {"caps": true, "ground": false})


static func _ground_finder(body: Node3D) -> Callable:
	var world := body.get_world_3d() if body.is_inside_tree() else null
	if world == null:
		return func(_at: Vector3) -> float: return 6.0
	var space := world.direct_space_state
	return func(at: Vector3) -> float:
		var q := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * PIER_DROP)
		var hit := space.intersect_ray(q)
		return at.distance_to(hit["position"]) if not hit.is_empty() else 6.0


static func handles(nodes: Array, params: Dictionary) -> Array:
	var s := spec()
	var out: Array = []
	for i in nodes.size():
		out.append(Spec.node_handle(i, nodes[i]))
	var frames := Ops.curve_frames(nodes, {"spacing": 1.8})
	if frames.size() < 2:
		return out
	var mid: Dictionary = frames[frames.size() / 2]
	var at: Vector3 = mid["p"]
	out.append(Spec.axis_handle(s, params, "width", at, mid["r"], 0.5))
	out.append(Spec.axis_handle(s, params, "kerb", at + (mid["r"] as Vector3) *
		Spec.value(s, params, "width") * 0.5, Vector3.UP))
	return out
