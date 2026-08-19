extends RefCounted

## Cross sections, in (u, v): u runs across the rail from its centreline, v runs
## up from it. Wound counter-clockwise so ops.sweep can read an outward normal
## straight off each edge.
##
## These are generators rather than literal arrays because every number in them
## is a parameter something else drives -- thickness, batter, coping depth all
## come off the model record and end up here. When a profile editor arrives it
## edits the output of these, and the generators become the presets.

const MIN_V := 0.05   ## nothing thinner than this survives the sweep anyway


## Cut every outward corner off a section. One function rather than a chamfered
## variant of each profile, because an arris belongs to the CORNER, not to the
## wall it happens to be on -- and because a chamfer in the section is a real
## change of silhouette, where a shader that only bends the normal still reads
## as a sharp edge exactly where you look for one.
##
## Corners at or below `above` keep their point: the foot of a wall is buried
## metres deep and cutting it would only cost triangles nobody sees.
static func chamfer(loop: PackedVector2Array, amount: float, above := 0.0) -> PackedVector2Array:
	var a := maxf(amount, 0.0)
	var n := loop.size()
	if a < 0.01 or n < 3:
		return loop
	# Winding decides which way a corner has to turn to be convex, and these
	# sections are not all wound the same way once a model mirrors one.
	var area := 0.0
	for i in n:
		var p := loop[i]
		var q := loop[(i + 1) % n]
		area += p.x * q.y - q.x * p.y
	var wind := 1.0 if area >= 0.0 else -1.0
	var out := PackedVector2Array()
	for i in n:
		var p := loop[i]
		var e0 := p - loop[(i - 1 + n) % n]
		var e1 := loop[(i + 1) % n] - p
		var l0 := e0.length()
		var l1 := e1.length()
		if p.y <= above or l0 < 0.01 or l1 < 0.01 or e0.cross(e1) * wind <= 0.0:
			out.append(p)
			continue
		# Never eat more than half an edge, or two neighbouring chamfers meet
		# in the middle and the section folds through itself.
		out.append(p - e0 / l0 * minf(a, l0 * 0.45))
		out.append(p + e1 / l1 * minf(a, l1 * 0.45))
	return out


## Battered wall: widest at the ground, tapering as it rises, with a coping
## that oversails the head. `skirt` runs below zero so sloping terrain never
## opens a gap under the run.
static func wall(half := 1.0, height := 6.0, skirt := 8.0, batter := 0.22,
		coping := 0.9, cham := 0.0) -> PackedVector2Array:
	var h := maxf(height, 1.0)
	var c := clampf(coping, 0.0, h * 0.4)
	var b := maxf(batter, 0.0)
	var o := 0.26                      # how far the coping stands proud
	var cb := maxf(c * 0.45, MIN_V)    # depth of the coping band itself
	# No coping means no coping. Drawing the band anyway at zero depth folds the
	# outline back through itself -- the lip runs out to `o`, up by the band's
	# floor thickness and back in to a point already on the top edge -- and a
	# section that touches itself sweeps into a solid with holes in it.
	if c < MIN_V:
		return chamfer(PackedVector2Array([
			Vector2(-(half + b), -skirt),
			Vector2(half + b, -skirt),
			Vector2(half + b, 0.0),
			Vector2(half, h),
			Vector2(-half, h),
			Vector2(-(half + b), 0.0),
		]), cham)
	return chamfer(PackedVector2Array([
		Vector2(-(half + b), -skirt),
		Vector2(half + b, -skirt),
		Vector2(half + b, 0.0),
		Vector2(half, h - c),
		Vector2(half + o, h - c),
		Vector2(half + o, h - c + cb),
		Vector2(half + 0.1, h),
		Vector2(-(half + 0.1), h),
		Vector2(-(half + o), h - c + cb),
		Vector2(-(half + o), h - c),
		Vector2(-half, h - c),
		Vector2(-(half + b), 0.0),
	]), cham)


## The same wall face, but closed off at the axis instead of mirrored: swept
## around a ring rail of the same radius this gives a solid tower, batter and
## coping included. The inner edge collapses onto the axis and its degenerate
## triangles are dropped by the sweep.
static func tower(radius := 3.2, height := 9.0, skirt := 8.0, batter := 0.3,
		coping := 0.9, cham := 0.0) -> PackedVector2Array:
	var h := maxf(height, 1.0)
	var c := clampf(coping, 0.0, h * 0.4)
	var b := maxf(batter, 0.0)
	var r := -maxf(radius, 0.5)
	var o := 0.26
	var cb := maxf(c * 0.45, MIN_V)
	if c < MIN_V:
		return chamfer(PackedVector2Array([
			Vector2(r, -skirt),
			Vector2(b, -skirt),
			Vector2(b, 0.0),
			Vector2(0.0, h),
			Vector2(r, h),
		]), cham)
	return chamfer(PackedVector2Array([
		Vector2(r, -skirt),
		Vector2(b, -skirt),
		Vector2(b, 0.0),
		Vector2(0.0, h - c),
		Vector2(o, h - c),
		Vector2(o, h - c + cb),
		Vector2(0.1, h),
		Vector2(r, h),
	]), cham)


## Plain rectangle between two u values and two v values. Merlons, kerbs,
## string courses and lintels are all this, placed by the model.
static func rect(u0: float, u1: float, v0: float, v1: float) -> PackedVector2Array:
	var a := minf(u0, u1)
	var b := maxf(u0, u1)
	var lo := minf(v0, v1)
	var hi := maxf(v0, v1)
	if b - a < 0.01 or hi - lo < MIN_V:
		return PackedVector2Array()
	return PackedVector2Array([
		Vector2(a, lo), Vector2(b, lo), Vector2(b, hi), Vector2(a, hi),
	])


## A section cut to a horizontal band.
##
## Openings used to sweep a bare rectangle, which threw away the batter, the
## coping and the chamfer: the wall's face stepped in at every jamb, and its top
## course stopped dead at the arch and started again after it. Clipping the REAL
## section keeps all three running through the opening.
static func clip(loop: PackedVector2Array, lo: float, hi: float) -> PackedVector2Array:
	# A corner sitting exactly ON the cut line is emitted twice -- once as a
	# vertex that survives, once as the crossing point -- and a section with a
	# repeated point will not triangulate, so its cap silently fails to build
	# and the piece comes out with a hole where its end should be.
	var out := _tidy(_clip_half(_clip_half(loop, lo, true), hi, false))
	return out if out.size() >= 3 else PackedVector2Array()


## Consecutive duplicates dropped, including the wrap from last back to first.
static func _tidy(loop: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in loop:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > 1e-10:
			out.append(p)
	while out.size() >= 2 and out[0].distance_squared_to(out[out.size() - 1]) < 1e-10:
		out.resize(out.size() - 1)
	return out


## Sutherland-Hodgman against one horizontal line.
static func _clip_half(loop: PackedVector2Array, y: float, keep_above: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := loop.size()
	if n < 3:
		return out
	for i in n:
		var a := loop[i]
		var b := loop[(i + 1) % n]
		var a_in := (a.y >= y) if keep_above else (a.y <= y)
		var b_in := (b.y >= y) if keep_above else (b.y <= y)
		if a_in:
			out.append(a)
		if a_in != b_in:
			out.append(_cross_y(a, b, y))
	return out


## The same section with its floor raised to `y`: everything below collapses
## onto the outline where it crosses that height.
##
## This is what an arch needs, and clip() cannot do it. A varying sweep pairs
## vertex j of one station with vertex j of the next, so every station must have
## the SAME vertex count -- and a clip's count changes with which edges the line
## happens to cross. Collapsing instead keeps the count and the indices exactly,
## at the cost of some zero-length edges, which the sweep already drops.
static func floor_at(loop: PackedVector2Array, y: float) -> PackedVector2Array:
	var n := loop.size()
	if n < 3:
		return loop
	var below := 0
	for p in loop:
		if p.y < y:
			below += 1
	if below == 0:
		return loop
	if below == n:
		return PackedVector2Array()
	# The below-y vertices are one contiguous run around the loop for any
	# section that is a single upright outline, but the run wraps, so find where
	# it starts rather than assuming index 0.
	var start := -1
	for i in n:
		if loop[i].y < y and loop[(i - 1 + n) % n].y >= y:
			start = i
			break
	if start < 0:
		return loop
	var last := start
	while loop[(last + 1) % n].y < y:
		last = (last + 1) % n
	var enter := _cross_y(loop[(start - 1 + n) % n], loop[start], y)
	var leave := _cross_y(loop[last], loop[(last + 1) % n], y)
	var out := loop.duplicate()
	for k in below:
		out[(start + k) % n] = enter if k * 2 < below else leave
	return out


static func _cross_y(a: Vector2, b: Vector2, y: float) -> Vector2:
	var dy := b.y - a.y
	if absf(dy) < 1e-9:
		return Vector2(a.x, y)
	return Vector2(a.x + (b.x - a.x) * ((y - a.y) / dy), y)


## One merlon course, sitting on the head of a wall of half-width `half`.
## `side` is -1 or 1; the walkway is the gap left between the two.
static func merlon(half: float, side: float, depth := 0.5, height := 1.1) -> PackedVector2Array:
	var outer := half + 0.1
	var inner := outer - maxf(depth, 0.1)
	return rect(side * outer, side * inner, 0.0, height)


## Bridge or walkway deck: a slab with a raised kerb down each edge, so a
## marble at speed is turned back in instead of launched off.
static func deck(half := 3.0, thick := 0.6, kerb := 0.45, kerb_w := 0.4) -> PackedVector2Array:
	var w := maxf(half, 0.6)
	var kw := clampf(kerb_w, 0.1, w * 0.45)
	var t := maxf(thick, MIN_V)
	var k := maxf(kerb, 0.0)
	if k < MIN_V:
		return rect(-w, w, -t, 0.0)
	return PackedVector2Array([
		Vector2(-w, -t),
		Vector2(w, -t),
		Vector2(w, k),
		Vector2(w - kw, k),
		Vector2(w - kw, 0.0),
		Vector2(-(w - kw), 0.0),
		Vector2(-(w - kw), k),
		Vector2(-w, k),
	])


## Pathway: thin, crowned in the middle so it sheds into the ground at both
## edges rather than standing on a visible lip.
static func path(half := 2.0, thick := 0.35, crown := 0.09) -> PackedVector2Array:
	var w := maxf(half, 0.3)
	var t := maxf(thick, MIN_V)
	var c := maxf(crown, 0.0)
	return PackedVector2Array([
		Vector2(-w, -t),
		Vector2(w, -t),
		Vector2(w, -0.02),
		Vector2(w * 0.55, c),
		Vector2(-w * 0.55, c),
		Vector2(-w, -0.02),
	])


## Half-pipe channel, faceted. Kept here so the existing riding surface and any
## new parametric run agree on what a trough is.
static func trough(radius := 2.5, facets := 16) -> PackedVector2Array:
	var n := maxi(facets, 4)
	var out := PackedVector2Array()
	for i in n + 1:
		var a := -PI / 2.0 + (float(i) / float(n)) * PI
		out.append(Vector2(radius * sin(a), radius * (1.0 - cos(a))))
	# Close the loop back under the floor so the trough is a solid, not a shell
	out.append(Vector2(radius, -0.5))
	out.append(Vector2(-radius, -0.5))
	return out
