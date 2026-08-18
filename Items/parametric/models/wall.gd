extends RefCounted

## A wall: the profile carried along a mitred rail through the clicked nodes.
##
## Corners close themselves because the rail mitres, so there is no post to hide
## a gap, and a run up a slope is a ramp rather than a stack of steps. Openings
## break the rail into stretches and each takes a lintel; merlons are sliced off
## the real rail so one straddling a corner turns with it.

const Ops := preload("res://Items/parametric/ops.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")
const Spec := preload("res://Items/parametric/spec.gd")

const SKIRT := 8.0        # buried below the run so sloping ground shows no gap
const GATE_W := 4.0
const GATE_H := 4.5
const TOOTH_L := 1.6      # merlon length, and the same again for the gap
const WINDOW_H := 3.0     # vertical extent of a punched penetration
const SILL_MIN := 0.4     # thinner than this and the sill is not worth keeping


static func spec() -> Array:
	return [
		Spec.param("height", "HEIGHT", 2.0, 24.0, 6.0, 0.5),
		Spec.param("thickness", "THICK", 0.6, 6.0, 2.0, 0.1),
		Spec.param("batter", "BATTER", 0.0, 1.2, 0.22, 0.02),
		Spec.param("coping", "COPING", 0.0, 2.5, 0.9, 0.05),
		Spec.param("tooth", "TEETH", 0.0, 3.0, 1.1, 0.1),
		Spec.param("gate", "GATE", 0.0, 1.0, 0.0, 1.0, ""),
	]


static func min_nodes() -> int:
	return 2


static func build(nodes: Array, params: Dictionary, mat: Material,
		collide := true, holes := []) -> Node3D:
	var s := spec()
	var body := StaticBody3D.new()
	var frames := Ops.mitre_frames(nodes)
	if frames.size() < 2:
		return body
	var total := Ops.rail_length(frames)
	if total < 1.0:
		return body

	var h := Spec.value(s, params, "height")
	var half := Spec.value(s, params, "thickness") * 0.5
	var batter := Spec.value(s, params, "batter")
	var coping := Spec.value(s, params, "coping")
	var tooth := Spec.value(s, params, "tooth")

	var st := Ops.surface()
	var hulls: Array = []
	var face := Profiles.wall(half, h, SKIRT, batter, coping)

	var opens := _openings(frames, total, Spec.flag(s, params, "gate"), holes, half, h)
	var cursor := 0.0
	for op in opens:
		var d := float(op["d"])
		if d - GATE_W * 0.5 - cursor > 0.05:
			Ops.sweep(st, Ops.slice(frames, cursor, d - GATE_W * 0.5), face, hulls, {"caps": true})
		# The opening's own stretch is not a void: it is the wall MINUS a slot,
		# so it keeps a sill under the hole and a lintel over it. A gate has its
		# sill at ground level and so gets none; a window punched at head height
		# gets both, which is the whole difference between a window and a hole
		# torn to the floor.
		var span := Ops.slice(frames, d - GATE_W * 0.5, d + GATE_W * 0.5)
		var y0 := float(op["y0"])
		var y1 := float(op["y1"])
		if y0 > SILL_MIN:
			Ops.sweep(st, span, Profiles.rect(-half, half, -SKIRT, y0), hulls, {"caps": true})
		else:
			Ops.sweep(st, span, Profiles.rect(-half, half, -SKIRT, 0.0), hulls, {"caps": true})
		if y1 < h - 0.05:
			Ops.sweep(st, span, Profiles.rect(-half, half, y1, h), hulls, {"caps": true})
		cursor = d + GATE_W * 0.5
	if total - cursor > 0.05:
		Ops.sweep(st, Ops.slice(frames, cursor, total), face, hulls, {"caps": true})

	if tooth > 0.05:
		var head := Ops.lift(frames, h)
		for side: float in [-1.0, 1.0]:
			crenellate(st, hulls, head, Profiles.merlon(half, side, 0.5, tooth), TOOTH_L)

	Ops.attach(body, st, hulls, mat, collide)
	return body


## Distances along the run where the wall is open: the gate at the middle, plus
## every punched hole that lands near enough to the line to count.
static func _openings(frames: Array, total: float, gate: bool, holes: Array,
		half: float, h: float) -> Array:
	var opens: Array = []
	if gate and total > GATE_W + 2.0:
		opens.append({"d": total * 0.5, "y0": 0.0, "y1": minf(GATE_H, h - 0.8)})
	for hp in holes:
		var pr := Ops.project(frames, hp)
		var d := float(pr["d"])
		if d < GATE_W * 0.5 + 0.5 or d > total - GATE_W * 0.5 - 0.5:
			continue
		# Lateral, not 3D: a hole is aimed AT the face, and the face is metres
		# above the rail it was swept from.
		if float(pr["lat"]) > half * 3.2:
			continue
		# A penetration is punched AT a height. Ignoring that is what turned
		# every window into a gateway: the hole was cut from the ground up
		# regardless of where it was aimed.
		var rail_y: float = (pr["point"] as Vector3).y
		var mid := clampf((hp as Vector3).y - rail_y, 0.0, h)
		var y0 := maxf(0.0, mid - WINDOW_H * 0.5)
		var y1 := minf(h, maxf(y0 + 1.0, mid + WINDOW_H * 0.5))
		opens.append({"d": d, "y0": y0, "y1": y1})
	opens.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	return opens


## Alternating teeth along a head rail, each sliced off the real rail rather
## than dropped on as a box.
static func crenellate(st: SurfaceTool, hulls: Array, head: Array,
		tooth: PackedVector2Array, spacing: float) -> void:
	if tooth.is_empty():
		return
	var i := 0
	for d in Ops.repeat_distances(head, spacing):
		i += 1
		if i % 2 == 0:
			continue
		Ops.sweep(st, Ops.slice(head, float(d) - spacing * 0.45,
			float(d) + spacing * 0.45), tooth, hulls, {"caps": true})


## Where you grab it: every node on the ground, height up off the middle of the
## run, thickness out across it.
static func handles(nodes: Array, params: Dictionary) -> Array:
	var s := spec()
	var out: Array = []
	for i in nodes.size():
		out.append(Spec.node_handle(i, nodes[i]))
	var frames := Ops.mitre_frames(nodes)
	if frames.size() < 2:
		return out
	var mid := Ops.frame_at(frames, Ops.rail_length(frames) * 0.5)
	if mid.is_empty():
		return out
	var at: Vector3 = mid["p"]
	var right: Vector3 = mid["r"]
	out.append(Spec.axis_handle(s, params, "height", at, Vector3.UP))
	out.append(Spec.axis_handle(s, params, "thickness", at, right, 0.5))
	return out
