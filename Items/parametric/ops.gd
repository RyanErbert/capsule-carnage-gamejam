extends RefCounted

## Geometry operations shared by every parametric model.
##
## The whole system is one idea: a model is a RAIL (where it runs) crossed with
## a PROFILE (its cross section). Walls, kerbs, bridge decks, pathways, tower
## shafts and handrails are all that same sweep with different inputs, so they
## share one code path and one set of bugs.
##
## A rail comes back as frames, each {p, t, r, u, k}:
##   p  the point on the rail
##   t  tangent, the direction the rail runs
##   r  right, across the rail and (for level rails) horizontal
##   u  up, perpendicular to both
##   k  width scale, >1 at a mitred corner so the profile keeps its thickness
##      through the turn instead of pinching
##
## A profile is a closed loop of Vector2 in (u, v): u runs across the rail from
## the centreline, v runs up from it. Wound counter-clockwise, which is what
## lets the sweep derive an outward normal per edge without guessing.
##
## Every function here is pure. Two clients holding the same parameter record
## build the identical mesh and the identical collision without a single vertex
## crossing the wire, which is the entire reason the records are what we sync.

const MIN_MITRE := 0.30   ## a corner sharper than ~145 degrees stops widening
const CURVE_SUBDIV := 12  ## Catmull-Rom samples per anchor span


# --- Rails -------------------------------------------------------------------

## Straight runs with sharp mitred corners: a wall between two clicks is dead
## straight and turns on a dime. One frame per anchor, `r` on the angle
## bisector so both segments meet in a single plane with no gap and no post.
static func mitre_frames(anchors: Array, level := true) -> Array:
	var pts := _dedupe(anchors)
	if pts.size() < 2:
		return []
	var dirs: Array = []
	for i in pts.size() - 1:
		var d: Vector3 = (pts[i + 1] as Vector3) - (pts[i] as Vector3)
		if level:
			d.y = 0.0
		dirs.append(d.normalized() if d.length_squared() > 1e-8 else Vector3.FORWARD)

	var frames: Array = []
	for i in pts.size():
		var d0: Vector3 = dirs[maxi(i - 1, 0)]
		var d1: Vector3 = dirs[mini(i, dirs.size() - 1)]
		var r0 := _right_of(d0)
		var r1 := _right_of(d1)
		var r: Vector3 = r0 + r1
		r = r0 if r.length_squared() < 1e-8 else r.normalized()
		var t: Vector3 = d0 + d1
		t = d1 if t.length_squared() < 1e-8 else t.normalized()
		var up: Vector3 = Vector3.UP if level else t.cross(r).normalized()
		frames.append({
			"p": pts[i], "t": t, "r": r, "u": up,
			# |offset| * cos(half angle) has to stay equal to the half width,
			# and cos(half angle) is exactly how far the bisector leans off
			# either segment's own right vector. Clamped so a hairpin bulges
			# instead of shooting off to infinity.
			"k": 1.0 / maxf(MIN_MITRE, r0.dot(r)),
		})
	return frames


## Smooth arc-spaced frames through the anchors: pathways, channels, anything
## that should read as a curve rather than a folded polyline. `bank` rolls the
## frame into turns (0 leaves it level, 1 banks like the half-pipes do).
static func curve_frames(anchors: Array, opts := {}) -> Array:
	var pts := _dedupe(anchors)
	if pts.size() < 2:
		return []
	var spacing := float(opts.get("spacing", 1.5))
	var max_rings := int(opts.get("max_rings", 260))
	var bank := float(opts.get("bank", 0.0))
	var relax := float(opts.get("relax", 0.6))
	var closed := bool(opts.get("closed", false))

	var an := _relax(pts, relax)
	var dense: Array = []
	for i in an.size() - 1:
		var p0: Vector3 = an[maxi(i - 1, 0)]
		var p1: Vector3 = an[i]
		var p2: Vector3 = an[i + 1]
		var p3: Vector3 = an[mini(i + 2, an.size() - 1)]
		for s in CURVE_SUBDIV:
			dense.append(_cr_point(p0, p1, p2, p3, float(s) / CURVE_SUBDIV))
	dense.append(an[an.size() - 1])

	var samples := _arc_space(dense, spacing, max_rings)
	var tans: Array = []
	for i in samples.size():
		var tangent: Vector3
		if i == 0:
			tangent = (samples[1] as Vector3) - (samples[0] as Vector3)
		elif i == samples.size() - 1:
			tangent = (samples[i] as Vector3) - (samples[i - 1] as Vector3)
		else:
			tangent = (samples[i + 1] as Vector3) - (samples[i - 1] as Vector3)
		if tangent.length_squared() < 1e-8:
			tangent = Vector3.FORWARD
		tans.append(tangent.normalized())

	var roll := _bank_angles(samples, tans, bank) if bank > 0.001 else []
	var frames: Array = []
	for i in samples.size():
		var t: Vector3 = tans[i]
		var rt := _right_of(t)
		var up := t.cross(rt).normalized()
		if not roll.is_empty():
			var a: float = roll[i]
			var rr: Vector3 = rt * cos(a) - up * sin(a)
			up = up * cos(a) + rt * sin(a)
			rt = rr
		frames.append({"p": samples[i], "t": t, "r": rt, "u": up, "k": 1.0})
	if closed and frames.size() > 2:
		frames[frames.size() - 1]["p"] = frames[0]["p"]
	return frames


## A closed circular rail whose right vector points outward, so sweeping a wall
## profile around it gives a tower shaft: one op, two structures.
static func ring_frames(center: Vector3, radius: float, segments := 16) -> Array:
	var n := maxi(3, segments)
	var frames: Array = []
	for i in n:
		var a := TAU * float(i) / float(n)
		var out := Vector3(cos(a), 0.0, sin(a))
		frames.append({
			"p": center + out * radius,
			"t": Vector3(-sin(a), 0.0, cos(a)),
			"r": out, "u": Vector3.UP,
			# A polygon inscribed on the circle sits inside it; widening each
			# frame by 1/cos(half step) puts the flat mid-span back on radius.
			"k": 1.0 / cos(PI / float(n)),
		})
	return frames


# --- Sweeping ----------------------------------------------------------------

## Run `profile` along `frames`, writing triangles into `st` and one convex
## hull per span into `hulls`. Hulls rather than a trimesh because a trimesh is
## a shell with no interior, and the player physics needs to know what is solid.
##
## `opts.profiles` gives a DIFFERENT section at every frame -- one array entry
## per frame, all with the same vertex count so the quads still pair up. That is
## what turns a flat lintel into an arch: the opening's head is a different
## height at every station across the span, and the section is the only thing
## that changes. Anything that varies smoothly along a run is this.
static func sweep(st: SurfaceTool, frames: Array, profile: PackedVector2Array,
		hulls: Array, opts := {}) -> void:
	if frames.size() < 2 or profile.size() < 3:
		return
	var closed := bool(opts.get("closed", false))
	var caps := bool(opts.get("caps", true)) and not closed
	var hull := bool(opts.get("hulls", true))
	var loops := _loops_for(frames, profile, opts.get("profiles", []))
	if loops.is_empty():
		return

	var rings: Array = []
	for i in frames.size():
		rings.append(_ring(frames[i], loops[i]))
	if closed:
		rings.append(rings[0])
		loops.append(loops[0])

	for i in rings.size() - 1:
		var a: PackedVector3Array = rings[i]
		var b: PackedVector3Array = rings[i + 1]
		var loop: PackedVector2Array = loops[i]
		for j in loop.size():
			var j2 := (j + 1) % loop.size()
			var e := loop[j2] - loop[j]
			if e.length_squared() < 1e-10:
				continue
			# Outward normal of a CCW edge is the edge turned -90 degrees,
			# lifted into the frame's own plane.
			var no := Vector2(e.y, -e.x).normalized()
			var f: Dictionary = frames[i]
			var n: Vector3 = ((f["r"] as Vector3) * no.x + (f["u"] as Vector3) * no.y).normalized()
			_quad(st, a[j], a[j2], b[j2], b[j], n)
		if hull:
			var pts := PackedVector3Array(a)
			pts.append_array(b)
			hulls.append(pts)

	if caps:
		_cap(st, frames[0], loops[0], rings[0], true)
		var last := frames.size() - 1
		_cap(st, frames[last], loops[last], rings[last], false)


## One wound loop per frame: the same section repeated, or the per-frame list
## when one was given. A varying section whose vertex count wanders would leave
## the quads unpaired, so that is refused rather than half-built.
static func _loops_for(frames: Array, profile: PackedVector2Array, varying: Variant) -> Array:
	var out: Array = []
	if varying is Array and (varying as Array).size() == frames.size():
		var want := -1
		for p in varying:
			var loop := _ccw(p)
			if want == -1:
				want = loop.size()
			if loop.size() != want or loop.size() < 3:
				return []
			out.append(loop)
		return out
	var one := _ccw(profile)
	for i in frames.size():
		out.append(one)
	return out


## Evenly spaced transforms along a rail: merlons on a parapet, piers under a
## bridge, posts along a fence. `phase` in 0..1 slides the pattern.
static func repeat_along(frames: Array, spacing: float, phase := 0.0) -> Array:
	if frames.size() < 2 or spacing <= 0.01:
		return []
	var total := 0.0
	var runs: Array = []
	for i in frames.size() - 1:
		var d: float = (frames[i]["p"] as Vector3).distance_to(frames[i + 1]["p"])
		runs.append(d)
		total += d
	var count := int(floor(total / spacing))
	var out: Array = []
	for i in count:
		var want := (float(i) + 0.5 + phase) * spacing
		if want > total:
			break
		out.append(_at_distance(frames, runs, want))
	return out


## Where the repeats land, as distances along the rail, so a caller can slice a
## real sub-rail out for each one instead of settling for a point.
static func repeat_distances(frames: Array, spacing: float, phase := 0.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if frames.size() < 2 or spacing <= 0.01:
		return out
	var total := rail_length(frames)
	var count := int(floor(total / spacing))
	for i in count:
		var want := (float(i) + 0.5 + phase) * spacing
		if want > total:
			break
		out.append(want)
	return out


## The stretch of rail between two distances, as its own frame array: the two
## ends interpolated, every real frame in between kept. A merlon cut this way
## mitres round a corner instead of shearing through it.
static func slice(frames: Array, from_d: float, to_d: float) -> Array:
	if frames.size() < 2 or to_d - from_d < 0.01:
		return []
	var runs := _runs(frames)
	var out: Array = [_at_distance(frames, runs, from_d)]
	var acc := 0.0
	for i in runs.size():
		acc += float(runs[i])
		if acc > from_d + 0.02 and acc < to_d - 0.02:
			out.append(frames[i + 1])
	out.append(_at_distance(frames, runs, to_d))
	return out


## The same rail as `n` evenly spaced frames. A section that varies along a run
## needs stations to vary AT, and a straight stretch between two nodes has only
## its two ends -- an arch drawn on those is a triangle.
static func resample(frames: Array, n: int) -> Array:
	if frames.size() < 2 or n < 2:
		return frames
	var runs := _runs(frames)
	var total := 0.0
	for r in runs:
		total += float(r)
	var out: Array = []
	for i in n:
		out.append(_at_distance(frames, runs, total * float(i) / float(n - 1)))
	return out


## One interpolated frame at a distance along the rail. Handles hang off this:
## asking slice() for a hair-thin stretch instead loses the width to floating
## point once the rail is a few tens of metres long, and the handle vanishes.
static func frame_at(frames: Array, dist: float) -> Dictionary:
	if frames.size() < 2:
		return {}
	return _at_distance(frames, _runs(frames), dist)


## Move a whole rail along its own up vector: the head of a wall is its rail
## lifted by the wall height, which is where the merlons ride.
static func lift(frames: Array, amount: float) -> Array:
	var out: Array = []
	for f in frames:
		var g: Dictionary = (f as Dictionary).duplicate()
		g["p"] = (f["p"] as Vector3) + (f["u"] as Vector3) * amount
		out.append(g)
	return out


## Closest point on the rail to `pos`: how far along it lies (`d`) and how far
## off it sits (`off`). Punched openings, handle picking and any "which part of
## this did I click" question all resolve through here.
## Where a point falls on the rail: how far along it, how far off it, and the
## rail point itself. `off` is the true distance; `lat` is the same thing with
## height thrown away, and `lat` is the one a swept model wants. A wall IS its
## rail extruded upward, so whether a point is on the wall is a question about
## the plan, not the section -- measured in 3D, a window aimed at head height on
## a fifteen metre wall reads as fifteen metres off the rail and is discarded.
static func project(frames: Array, pos: Vector3) -> Dictionary:
	var best := {"d": 0.0, "off": INF, "lat": INF, "point": Vector3.ZERO}
	var acc := 0.0
	for i in frames.size() - 1:
		var a: Vector3 = frames[i]["p"]
		var b: Vector3 = frames[i + 1]["p"]
		var ab := b - a
		var span := ab.length()
		var t := 0.0 if span < 1e-6 else clampf((pos - a).dot(ab) / (span * span), 0.0, 1.0)
		var on := a + ab * t
		var lat := Vector2(pos.x - on.x, pos.z - on.z).length()
		if lat < float(best["lat"]):
			best = {"d": acc + span * t, "off": pos.distance_to(on), "lat": lat, "point": on}
		acc += span
	return best


static func _runs(frames: Array) -> Array:
	var runs: Array = []
	for i in frames.size() - 1:
		runs.append((frames[i]["p"] as Vector3).distance_to(frames[i + 1]["p"]))
	return runs


## The frame `dist` metres along the rail, interpolated between the two it
## falls between. Placement, riding and trim all read positions this way.
static func _at_distance(frames: Array, runs: Array, dist: float) -> Dictionary:
	var acc := 0.0
	for i in runs.size():
		var seg: float = runs[i]
		if acc + seg >= dist or i == runs.size() - 1:
			var t := clampf((dist - acc) / maxf(seg, 1e-6), 0.0, 1.0)
			var a: Dictionary = frames[i]
			var b: Dictionary = frames[i + 1]
			return {
				"p": (a["p"] as Vector3).lerp(b["p"], t),
				"t": ((a["t"] as Vector3).lerp(b["t"], t)).normalized(),
				"r": ((a["r"] as Vector3).lerp(b["r"], t)).normalized(),
				"u": ((a["u"] as Vector3).lerp(b["u"], t)).normalized(),
				"k": lerpf(float(a["k"]), float(b["k"]), t),
			}
		acc += seg
	return frames[frames.size() - 1]


## Total rail length, for sizing repeats and for status readouts.
static func rail_length(frames: Array) -> float:
	var total := 0.0
	for i in frames.size() - 1:
		total += (frames[i]["p"] as Vector3).distance_to(frames[i + 1]["p"])
	return total


# --- Assembly ----------------------------------------------------------------

## Finish a surface and hang it, with its hulls, off a body. One MeshInstance
## for the whole run instead of a node per box.
static func attach(body: Node3D, st: SurfaceTool, hulls: Array,
		mat: Material, collide := true) -> void:
	st.index()
	var mesh := st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	# Ghosts and thumbnails are plain Node3Ds with nothing to collide against.
	if not collide or not (body is StaticBody3D):
		return
	for pts in hulls:
		var shape := ConvexPolygonShape3D.new()
		shape.points = pts
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)


static func surface() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


# --- Internals ---------------------------------------------------------------

static func _ring(f: Dictionary, loop: PackedVector2Array) -> PackedVector3Array:
	var p: Vector3 = f["p"]
	var r: Vector3 = f["r"]
	var u: Vector3 = f["u"]
	var k := float(f.get("k", 1.0))
	var out := PackedVector3Array()
	for pt in loop:
		out.append(p + r * (pt.x * k) + u * pt.y)
	return out


static func _cap(st: SurfaceTool, f: Dictionary, loop: PackedVector2Array,
		ring: PackedVector3Array, start: bool) -> void:
	var idx := Geometry2D.triangulate_polygon(loop)
	if idx.is_empty():
		return
	var n: Vector3 = -(f["t"] as Vector3) if start else (f["t"] as Vector3)
	var i := 0
	while i + 2 < idx.size():
		_tri(st, ring[idx[i]], ring[idx[i + 1]], ring[idx[i + 2]], n)
		i += 3


static func _right_of(dir: Vector3) -> Vector3:
	var r := Vector3.UP.cross(dir)
	return Vector3.RIGHT if r.length_squared() < 1e-8 else r.normalized()


## Godot treats clockwise as front, and _tri reverses to match. _quad flips its
## diagonal when the winding disagrees with the normal it was handed, which is
## what keeps a swept surface from turning inside out at a corner.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).dot(n) < 0.0:
		var t := b
		b = d
		d = t
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).length_squared() < 1e-10:
		return
	st.set_normal(n)
	for v in [a, c, b]:
		st.add_vertex(v)


## Shoelace: a negative area means the loop was wound clockwise, and every
## outward normal in the sweep would point into the solid.
static func _ccw(loop: PackedVector2Array) -> PackedVector2Array:
	var area := 0.0
	for i in loop.size():
		var a := loop[i]
		var b := loop[(i + 1) % loop.size()]
		area += a.x * b.y - b.x * a.y
	if area >= 0.0:
		return loop
	var out := PackedVector2Array()
	for i in range(loop.size() - 1, -1, -1):
		out.append(loop[i])
	return out


static func _dedupe(anchors: Array) -> Array:
	var out: Array = []
	for a in anchors:
		var p: Vector3 = a
		if out.is_empty() or (out[out.size() - 1] as Vector3).distance_squared_to(p) > 1e-6:
			out.append(p)
	return out


## Pull sharp corners toward the midpoint so a curved rail does not kink. The
## sharper the turn the more it gives, up to `amount`.
static func _relax(points: Array, amount: float) -> Array:
	if points.size() <= 2 or amount <= 0.001:
		return points.duplicate()
	var out: Array = [points[0]]
	for i in range(1, points.size() - 1):
		var v1: Vector3 = (points[i] as Vector3) - (points[i - 1] as Vector3)
		var v2: Vector3 = (points[i + 1] as Vector3) - (points[i] as Vector3)
		if v1.length_squared() < 1e-8 or v2.length_squared() < 1e-8:
			out.append(points[i])
			continue
		var angle := acos(clampf(v1.normalized().dot(v2.normalized()), -1.0, 1.0))
		var t := clampf((angle - PI / 7.0) / (PI * 0.6), 0.0, 1.0) * amount
		var mid: Vector3 = ((points[i - 1] as Vector3) + (points[i + 1] as Vector3)) * 0.5
		out.append((points[i] as Vector3).lerp(mid, t))
	out.append(points[points.size() - 1])
	return out


## Centripetal Catmull-Rom (Barry-Goldman), same parameterisation the channels
## use, so a pathway and a half-pipe drawn through the same clicks agree.
static func _cr_point(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t0 := 0.0
	var t1 := t0 + maxf(sqrt(p0.distance_to(p1)), 1e-4)
	var t2 := t1 + maxf(sqrt(p1.distance_to(p2)), 1e-4)
	var t3 := t2 + maxf(sqrt(p2.distance_to(p3)), 1e-4)
	var tt := lerpf(t1, t2, t)
	var a1 := p0.lerp(p1, (tt - t0) / (t1 - t0))
	var a2 := p1.lerp(p2, (tt - t1) / (t2 - t1))
	var a3 := p2.lerp(p3, (tt - t2) / (t3 - t2))
	var b1 := a1.lerp(a2, (tt - t0) / (t2 - t0))
	var b2 := a2.lerp(a3, (tt - t1) / (t3 - t1))
	return b1.lerp(b2, (tt - t1) / (t2 - t1))


static func _arc_space(dense: Array, spacing: float, max_rings: int) -> Array:
	var length := 0.0
	for i in dense.size() - 1:
		length += (dense[i] as Vector3).distance_to(dense[i + 1])
	var n := clampi(ceili(length / maxf(spacing, 0.05)), 2, max_rings)
	var samples: Array = [dense[0]]
	var step := length / float(n)
	var acc := 0.0
	var di := 0
	for k in range(1, n):
		var want := float(k) * step
		while di < dense.size() - 1:
			var seg: float = (dense[di] as Vector3).distance_to(dense[di + 1])
			if acc + seg >= want:
				samples.append((dense[di] as Vector3).lerp(dense[di + 1], (want - acc) / maxf(seg, 1e-6)))
				break
			acc += seg
			di += 1
		if samples.size() <= k:
			samples.append(dense[dense.size() - 1])
	samples.append(dense[dense.size() - 1])
	return samples


## Roll each frame into its turn, smoothed so the bank does not chatter and
## tapered at both mouths so entering a run is not a lurch.
static func _bank_angles(samples: Array, tans: Array, amount: float) -> Array:
	var step := 1.0
	if samples.size() > 1:
		step = maxf((samples[0] as Vector3).distance_to(samples[1]), 0.01)
	var raw: Array = []
	raw.resize(samples.size())
	for i in samples.size():
		var lean := 0.0
		if i > 0 and i < samples.size() - 1:
			var dt: Vector3 = ((tans[i + 1] as Vector3) - (tans[i - 1] as Vector3)) / (2.0 * step)
			var rt := _right_of(tans[i])
			lean = signf(dt.dot(rt)) * atan(34.0 * dt.length()) * amount
		raw[i] = clampf(lean, -1.05, 1.05)
	var out: Array = []
	out.resize(raw.size())
	for i in raw.size():
		var sum := 0.0
		var cnt := 0
		for k in range(maxi(0, i - 3), mini(raw.size(), i + 4)):
			sum += float(raw[k])
			cnt += 1
		var edge := minf(1.0, minf(float(i), float(raw.size() - 1 - i)) / 4.0)
		out[i] = (sum / float(cnt)) * edge
	return out
