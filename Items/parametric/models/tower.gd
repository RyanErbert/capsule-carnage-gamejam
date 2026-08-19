extends RefCounted

## A tower is a wall bent onto a circle. Same profile, same crenellation, same
## code path -- the only difference is a ring rail instead of a mitred one, and
## a cross section closed off at the axis so the result is solid rather than a
## hoop. `sides` is a real parameter, so the same model gives you a round keep
## or a hexagonal bastion.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")
const Spec := preload("res://Items/parametric/spec.gd")
const Wall := preload("res://Items/parametric/models/wall.gd")

const SKIRT := 8.0


static func spec() -> Array:
	return [
		Spec.param("height", "HEIGHT", 3.0, 40.0, 9.0, 0.5),
		Spec.param("radius", "RADIUS", 1.2, 12.0, 3.2, 0.1),
		Spec.param("batter", "BATTER", 0.0, 1.5, 0.35, 0.02),
		Spec.param("coping", "COPING", 0.0, 2.5, 0.9, 0.05),
		Spec.param("tooth", "TEETH", 0.0, 3.0, 1.1, 0.1),
		Spec.param("chamfer", "CHAMFER", 0.0, 0.8, 0.14, 0.02),
		Spec.param("sides", "SIDES", 5.0, 32.0, 14.0, 1.0, ""),
	]


static func min_nodes() -> int:
	return 1


static func build(nodes: Array, params: Dictionary, mat: Material,
		collide := true, _holes := []) -> Node3D:
	var s := spec()
	var body := StaticBody3D.new()
	if nodes.is_empty():
		return body
	var at: Vector3 = nodes[0]
	var h := Spec.value(s, params, "height")
	var r := Spec.value(s, params, "radius")
	var sides := int(roundf(Spec.value(s, params, "sides")))
	var tooth := Spec.value(s, params, "tooth")

	var frames := Ops.ring_frames(at, r, sides)
	var st := Ops.surface()
	var hulls: Array = []
	var cham := Spec.value(s, params, "chamfer")
	Ops.sweep(st, frames, Profiles.tower(r, h, SKIRT,
		Spec.value(s, params, "batter"), Spec.value(s, params, "coping"), cham),
		hulls, {"closed": true})

	if tooth > 0.05:
		# Reopen the ring into a rail covering the full circle, so a merlon can
		# be sliced off the seam like any other stretch of head.
		var head := Ops.lift(frames, h)
		head.append(head[0])
		var spacing := maxf(TAU * r / maxf(float(sides), 4.0), 0.6)
		Wall.crenellate(st, hulls, head,
			Profiles.chamfer(Profiles.rect(-0.5, 0.1, 0.0, tooth), cham), spacing, h)

	Ops.attach(body, st, hulls, mat, collide)
	return body


static func handles(nodes: Array, params: Dictionary) -> Array:
	var s := spec()
	if nodes.is_empty():
		return []
	var at: Vector3 = nodes[0]
	return [
		Spec.node_handle(0, at),
		Spec.axis_handle(s, params, "height", at, Vector3.UP),
		Spec.axis_handle(s, params, "radius", at, Vector3.RIGHT),
	]
