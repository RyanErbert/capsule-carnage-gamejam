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


## Battered wall: widest at the ground, tapering as it rises, with a coping
## that oversails the head. `skirt` runs below zero so sloping terrain never
## opens a gap under the run.
static func wall(half := 1.0, height := 6.0, skirt := 8.0, batter := 0.22,
		coping := 0.9) -> PackedVector2Array:
	var h := maxf(height, 1.0)
	var c := clampf(coping, 0.0, h * 0.4)
	var b := maxf(batter, 0.0)
	var o := 0.26                      # how far the coping stands proud
	var cb := maxf(c * 0.45, MIN_V)    # depth of the coping band itself
	return PackedVector2Array([
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
	])


## The same wall face, but closed off at the axis instead of mirrored: swept
## around a ring rail of the same radius this gives a solid tower, batter and
## coping included. The inner edge collapses onto the axis and its degenerate
## triangles are dropped by the sweep.
static func tower(radius := 3.2, height := 9.0, skirt := 8.0, batter := 0.3,
		coping := 0.9) -> PackedVector2Array:
	var h := maxf(height, 1.0)
	var c := clampf(coping, 0.0, h * 0.4)
	var b := maxf(batter, 0.0)
	var r := -maxf(radius, 0.5)
	var o := 0.26
	var cb := maxf(c * 0.45, MIN_V)
	return PackedVector2Array([
		Vector2(r, -skirt),
		Vector2(b, -skirt),
		Vector2(b, 0.0),
		Vector2(0.0, h - c),
		Vector2(o, h - c),
		Vector2(o, h - c + cb),
		Vector2(0.1, h),
		Vector2(r, h),
	])


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
