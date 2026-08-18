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

	var opens := _openings(frames, total, Spec.flag(s, params, "gate"), holes, half)
	var gate_h := minf(GATE_H, h - 0.8)
	var lintel := Profiles.rect(-half, half, gate_h, h)
	var cursor := 0.0
	for t_v in opens + [total + GATE_W * 0.5]:
		var stop: float = minf(float(t_v) - GATE_W * 0.5, total)
		if stop - cursor > 0.05:
			Ops.sweep(st, Ops.slice(frames, cursor, stop), face, hulls, {"caps": true})
		cursor = maxf(cursor, float(t_v) + GATE_W * 0.5)
	for t_v in opens:
		Ops.sweep(st, Ops.slice(frames, float(t_v) - GATE_W * 0.5,
			float(t_v) + GATE_W * 0.5), lintel, hulls, {"caps": true})

	if tooth > 0.05:
		var head := Ops.lift(frames, h)
		for side: float in [-1.0, 1.0]:
			crenellate(st, hulls, head, Profiles.merlon(half, side, 0.5, tooth), TOOTH_L)

	Ops.attach(body, st, hulls, mat, collide)
	return body


## Distances along the run where the wall is open: the gate at the middle, plus
## every punched hole that lands near enough to the line to count.
static func _openings(frames: Array, total: float, gate: bool, holes: Array,
		half: float) -> Array:
	var opens: Array = []
	if gate and total > GATE_W + 2.0:
		opens.append(total * 0.5)
	for hp in holes:
		var pr := Ops.project(frames, hp)
		var d := float(pr["d"])
		if d < GATE_W * 0.5 + 0.5 or d > total - GATE_W * 0.5 - 0.5:
			continue
		if float(pr["off"]) > half * 3.2:
			continue
		opens.append(d)
	opens.sort()
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
