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
const TOOTH_L := 1.6      # merlon length, and the same again for the gap
const SILL_MIN := 0.4     # thinner than this and the sill is not worth keeping
const ARCH_STEPS := 13    # stations across an opening; an arc needs somewhere to bend
const ARCH_HEAD := 0.25   # solid left between the crown and the underside of the coping
const ARCH_MIN := 0.35    # below this rise it is a lintel, not an arch
const HEAD_MIN := 1.5     # an opening still worth having after the arch takes its room


static func spec() -> Array:
	return [
		# Minimum leaves room for an opening and its arch to exist at all.
		Spec.param("height", "HEIGHT", 4.0, 24.0, 6.0, 0.5),
		Spec.param("thickness", "THICK", 0.6, 6.0, 2.0, 0.1),
		Spec.param("batter", "BATTER", 0.0, 1.2, 0.22, 0.02),
		Spec.param("coping", "COPING", 0.0, 2.5, 0.9, 0.05),
		Spec.param("tooth", "TEETH", 0.0, 3.0, 1.1, 0.1),
		Spec.param("chamfer", "CHAMFER", 0.0, 0.8, 0.14, 0.02),
		Spec.param("arch", "ARCH", 0.0, 1.0, 0.7, 0.05, ""),
		# An opening is a width and a head height, which is all a gate ever was:
		# aim one low and it is a gateway, aim it high and narrow and it is a
		# window. There is no gate flag any more because there was nothing left
		# for it to mean.
		Spec.param("opening", "OPENING", 0.8, 8.0, 4.0, 0.2),
		Spec.param("head", "HEAD", 1.0, 12.0, 4.5, 0.25),
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
	var cham := Spec.value(s, params, "chamfer")
	var arch := Spec.value(s, params, "arch")

	var st := Ops.surface()
	var hulls: Array = []
	var face := Profiles.wall(half, h, SKIRT, batter, coping, cham)

	# An arch stops UNDER the coping. Letting the crown rise into it is wrong
	# twice over: a cornice does not get eaten by the opening below it, and the
	# section's topology changes partway up the lip -- the overhang means a
	# vertex that collapsed onto the left of the soffit at one station collapses
	# onto the right at the next, and the sweep pairs them into a twisted face.
	# Every torn wall in the matrix was an arch reaching into its own coping.
	var ceiling := h - coping - ARCH_HEAD
	var opens := _openings(frames, total, holes, half, h, ceiling,
		Spec.value(s, params, "opening"), Spec.value(s, params, "head"))
	var cursor := 0.0
	for op in opens:
		var d0 := float(op["d0"])
		var d1 := float(op["d1"])
		var y1 := float(op["y1"])
		# Keep the arc CIRCULAR. Squashing it into whatever headroom is left is
		# what made a short wall read as a squeezed ellipse. Drop the head to
		# make room first, and narrow the opening only if that is still not
		# enough -- the shape stays right and the hole gives way instead.
		if arch > 0.01 and ceiling > HEAD_MIN:
			var want := arch * (d1 - d0) * 0.5
			if want > ceiling - y1:
				y1 = maxf(HEAD_MIN, ceiling - want)
			var room := ceiling - y1
			if want > room:
				var mid_d := (d0 + d1) * 0.5
				var w := maxf(0.8, 2.0 * room / arch)
				d0 = mid_d - w * 0.5
				d1 = mid_d + w * 0.5
		if d0 - cursor > 0.05:
			Ops.sweep(st, Ops.slice(frames, cursor, d0), face, hulls, {"caps": true})
		# The opening's own stretch is not a void: it is the wall MINUS a slot,
		# so it keeps a sill under the hole and a head over it. Both are the
		# REAL section clipped, not a bare rectangle -- a rectangle threw away
		# the batter, the coping and the chamfer, so the face stepped in at
		# every jamb and the top course stopped dead at the arch and started
		# again after it.
		var span := Ops.slice(frames, d0, d1)
		var y0 := float(op["y0"])
		var sill := Profiles.clip(face, -SKIRT, y0 if y0 > SILL_MIN else 0.0)
		if sill.size() >= 3:
			Ops.sweep(st, span, sill, hulls, {"caps": true})
		if y1 < h - 0.05:
			_head(st, hulls, span, face, y1, ceiling, arch, d1 - d0)
		cursor = d1
	if total - cursor > 0.05:
		Ops.sweep(st, Ops.slice(frames, cursor, total), face, hulls, {"caps": true})

	if tooth > 0.05:
		var head := Ops.lift(frames, h)
		for side: float in [-1.0, 1.0]:
			crenellate(st, hulls, head,
				Profiles.chamfer(Profiles.merlon(half, side, 0.5, tooth), cham), TOOTH_L, h)

	Ops.attach(body, st, hulls, mat, collide)
	return body


## What sits over an opening. Flat, that is one lintel; arched, the head is an
## arc and so the section's underside is at a different height at every station
## across the span -- which is a varying profile, not a shape the sweep could
## otherwise make. The arc is a segment of a circle on the opening's own width,
## scaled by `arch`: 0 is a flat lintel and 1 a full semicircle.
static func _head(st: SurfaceTool, hulls: Array, span: Array,
		face: PackedVector2Array, y1: float, ceiling: float, arch: float, width: float) -> void:
	# The rise follows the opening's OWN width, so a wide one gets a wide arch
	# rather than the same small hump a single punch would have made. The caller
	# has already made room for it under the coping, so this never has to squash.
	var rise := minf(arch * width * 0.5, ceiling - y1)
	if rise < ARCH_MIN:
		Ops.sweep(st, span, Profiles.floor_at(face, y1), hulls, {"caps": true})
		return
	var arc := Ops.resample(span, ARCH_STEPS)
	var profs: Array = []
	for i in arc.size():
		var t := float(i) / float(arc.size() - 1)
		var soffit := y1 + rise * sqrt(maxf(0.0, 1.0 - pow(2.0 * t - 1.0, 2.0)))
		profs.append(Profiles.floor_at(face, soffit))
	Ops.sweep(st, arc, profs[0], hulls, {"caps": true, "profiles": profs})


## Distances along the run where the wall is open: one stretch per punched hole,
## `width` wide and `head` tall, sitting where it was aimed.
static func _openings(frames: Array, total: float, holes: Array,
		half: float, h: float, ceiling: float, width: float, head: float) -> Array:
	var opens: Array = []
	for hp in holes:
		var pr := Ops.project(frames, hp)
		var d := float(pr["d"])
		if d < width * 0.5 + 0.5 or d > total - width * 0.5 - 0.5:
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
		# Aim low and the sill lands on the ground, which is a gateway; aim high
		# with a narrow opening and it is a window. Same hole either way.
		var y0 := maxf(0.0, mid - head * 0.5)
		var y1 := minf(ceiling, maxf(y0 + 0.5, y0 + head))
		opens.append({"d": d, "y0": y0, "y1": y1})
	opens.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	return _merge(opens, total, width)


## Each opening claims its own width of rail either side of where it was aimed,
## so two punched closer together than that claim overlapping stretches -- and
## swept separately
## that is two arches hung in the same hole, which is the row of teeth chewed
## out of the opening in Ryan's screenshot, plus fifty faces drawn twice.
##
## Overlapping openings are ONE opening. Punching a row of holes to make a wide
## doorway is a reasonable thing to do, so it should build a wide doorway.
static func _merge(opens: Array, total: float, width: float) -> Array:
	var out: Array = []
	for op in opens:
		var d := float(op["d"])
		var span := {
			"d0": maxf(0.0, d - width * 0.5),
			"d1": minf(total, d + width * 0.5),
			"y0": float(op["y0"]), "y1": float(op["y1"]),
		}
		if out.is_empty() or float(span["d0"]) > float(out[out.size() - 1]["d1"]) + 0.05:
			out.append(span)
			continue
		# Swallowed: the merged opening takes the lowest sill and the highest
		# head of everything in it, so a window beside a gateway opens to the
		# ground rather than leaving a sill hanging across the doorway.
		var prev: Dictionary = out[out.size() - 1]
		prev["d1"] = maxf(float(prev["d1"]), float(span["d1"]))
		prev["y0"] = minf(float(prev["y0"]), float(span["y0"]))
		prev["y1"] = maxf(float(prev["y1"]), float(span["y1"]))
	return out


## Alternating teeth along a head rail, each sliced off the real rail rather
## than dropped on as a box.
## `base` is how high the head rail was lifted, so a merlon knows it is at the
## top of a wall and not sitting in the dirt.
static func crenellate(st: SurfaceTool, hulls: Array, head: Array,
		tooth: PackedVector2Array, spacing: float, base := 0.0) -> void:
	if tooth.is_empty():
		return
	var i := 0
	for d in Ops.repeat_distances(head, spacing):
		i += 1
		if i % 2 == 0:
			continue
		Ops.sweep(st, Ops.slice(head, float(d) - spacing * 0.45,
			float(d) + spacing * 0.45), tooth, hulls, {"caps": true, "v_base": base})


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
