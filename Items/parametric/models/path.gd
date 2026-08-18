extends RefCounted

## A pathway: a thin crowned ribbon following the ground. The rail curves and
## each frame sits at the height it was clicked, so a path laid across a slope
## rolls with it instead of standing on a plinth.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")
const Spec := preload("res://Items/parametric/spec.gd")


static func spec() -> Array:
	return [
		Spec.param("width", "WIDTH", 0.6, 10.0, 2.0, 0.2),
		Spec.param("thick", "DEPTH", 0.1, 2.0, 0.35, 0.05),
		Spec.param("crown", "CROWN", 0.0, 0.6, 0.09, 0.01),
	]


static func min_nodes() -> int:
	return 2


static func build(nodes: Array, params: Dictionary, mat: Material,
		collide := true, _holes := []) -> Node3D:
	var s := spec()
	var body := StaticBody3D.new()
	var frames := Ops.curve_frames(nodes, {"spacing": 1.4})
	if frames.size() < 2:
		return body
	var st := Ops.surface()
	var hulls: Array = []
	Ops.sweep(st, frames, Profiles.path(
		Spec.value(s, params, "width") * 0.5,
		Spec.value(s, params, "thick"),
		Spec.value(s, params, "crown")), hulls, {"caps": true})
	Ops.attach(body, st, hulls, mat, collide)
	return body


static func handles(nodes: Array, params: Dictionary) -> Array:
	var s := spec()
	var out: Array = []
	for i in nodes.size():
		out.append(Spec.node_handle(i, nodes[i]))
	var frames := Ops.curve_frames(nodes, {"spacing": 1.4})
	if frames.size() < 2:
		return out
	var mid: Dictionary = frames[frames.size() / 2]
	out.append(Spec.axis_handle(s, params, "width", mid["p"], mid["r"], 0.5))
	return out
