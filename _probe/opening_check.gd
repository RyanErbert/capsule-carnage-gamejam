extends SceneTree

## Openings and arrises: does the head of a gateway actually curve, and does a
## chamfer actually change the silhouette?
##
## Both are claims about geometry, so both are measured on the geometry. The
## arch is read straight off the mesh -- the lowest vertex above the sill, in
## each slice across the opening, IS the soffit at that station -- and the
## chamfer is read off the section, where a cut corner has to be shorter than
## the square one it replaced.

const Registry := preload("res://Items/parametric/registry.gd")
const Profiles := preload("res://Items/parametric/profiles.gd")

const H := 10.0            # wall height for the test runs
const GATE_W := 4.0        # matches models/wall.gd
const SPRING := 4.5        # gate head with no arch (GATE_H), so the springing line

var _fails := 0


func _initialize() -> void:
	_arch()
	_chamfer()
	print("openings: %s" % ("all checks passed" if _fails == 0 else "%d FAILED" % _fails))
	quit()


func _arch() -> void:
	var flat := _soffits(_wall(0.0))
	var arch := _soffits(_wall(0.7))
	_check(not flat.is_empty() and not arch.is_empty(), "found the opening in both walls")
	if flat.is_empty() or arch.is_empty():
		return

	# A flat lintel is flat: every station across the span reads the same.
	var flat_span := _span(flat)
	_check(flat_span < 0.05, "arch 0 leaves a flat lintel: %.3f m of variation" % flat_span)

	# An arch is not: the crown stands proud of the springing by the full rise.
	var crown: float = arch[arch.size() / 2]
	var edge: float = minf(arch[0], arch[arch.size() - 1])
	_check(absf(edge - SPRING) < 0.35,
		"arch springs from the same line the lintel sat on: %.2f vs %.2f" % [edge, SPRING])
	_check(absf((crown - edge) - 0.7 * GATE_W * 0.5) < 0.2,
		"crown rises the arc's own radius: %.2f m over the springing" % (crown - edge))

	# And it is an ARC, not a gable: monotonic up to the crown, down after, with
	# no station dipping below its neighbours.
	var bad := 0
	for i in range(1, arch.size() / 2):
		if arch[i] < arch[i - 1] - 0.001:
			bad += 1
	for i in range(arch.size() / 2 + 1, arch.size()):
		if arch[i] > arch[i - 1] + 0.001:
			bad += 1
	_check(bad == 0, "rises to the crown and falls away, %d stations out of order" % bad)

	for a: float in [0.0, 0.4, 0.7, 1.0]:
		for c: float in [0.0, 0.3]:
			var oe := _open_edges(_wall(a, c))
			_check(oe == 0, "arch %.1f chamfer %.1f watertight (%d open)" % [a, c, oe])


func _chamfer() -> void:
	var square := Profiles.wall(1.0, 6.0, 8.0, 0.22, 0.9, 0.0)
	var cut := Profiles.wall(1.0, 6.0, 8.0, 0.22, 0.9, 0.25)
	_check(cut.size() > square.size(),
		"chamfer splits corners into edges: %d -> %d points" % [square.size(), cut.size()])
	# Only above ground: the foot of a wall is buried metres deep.
	var below_square := 0
	var below_cut := 0
	for p in square:
		if p.y <= 0.0:
			below_square += 1
	for p in cut:
		if p.y <= 0.0:
			below_cut += 1
	_check(below_square == below_cut, "buried corners left square: %d both" % below_cut)

	# A chamfered corner is a real cut, so the section it belongs to loses area.
	_check(_area(cut) < _area(square) - 0.01,
		"and takes material off: %.3f -> %.3f" % [_area(square), _area(cut)])

	# Degenerate cases must not fold the section through itself.
	var huge := Profiles.wall(1.0, 6.0, 8.0, 0.22, 0.9, 99.0)
	_check(_area(huge) > 0.0, "an absurd chamfer still leaves a valid section")
	_check(Profiles.chamfer(square, 0.0) == square, "zero chamfer is the identity")

	var walls := _mesh(_wall(0.7, 0.0))
	var chamfered := _mesh(_wall(0.7, 0.3))
	_check(chamfered.get_faces().size() > walls.get_faces().size(),
		"chamfered wall carries the extra faces: %d -> %d tris"
		% [walls.get_faces().size() / 3, chamfered.get_faces().size() / 3])
	var oe := _open_edges(_wall(0.7, 0.3))
	_check(oe == 0, "and is still watertight (%d open)" % oe)

	# Overlapping punches. Each opening claims GATE_W of rail either side of
	# where it was aimed, so holes closer together than that used to be swept as
	# separate openings on top of each other -- a row of arch soffits chewed
	# into one hole, and every face across the overlap drawn twice.
	var spread := _holed([Vector3(-14, 7, 0), Vector3(0, 7, 0), Vector3(14, 7, 0)])
	var tight := _holed([Vector3(-3, 7, 0), Vector3(-1, 7, 0), Vector3(1, 7, 0), Vector3(3, 7, 0)])
	_check(_open_edges(spread) == 0, "openings far apart stay separate (%d open)" % _open_edges(spread))
	_check(_open_edges(tight) == 0, "the merged opening is watertight (%d open)" % _open_edges(tight))
	# Four stacked arches gave four crowns chewed into one hole. One opening has
	# one: the soffit rises once and falls once, with nothing in between going
	# the wrong way. Counting coincident faces measured butt joints instead,
	# which two closed solids standing against each other always have.
	# Sample the whole merged span, not one gate's width, or the extra crowns
	# sit outside the window and the check passes on a wall that is still wrong.
	_check(_crowns(tight, 10.0) == 1,
		"and holes 2 m apart become ONE arch, not four (%d crowns)" % _crowns(tight, 10.0))
	# One wide opening has less geometry than four narrow ones stacked, which is
	# the cheapest way to say the arches are no longer duplicated.
	_check(_tri_count(tight) < _tri_count(spread),
		"one wide opening is fewer triangles than three separate ones (%d vs %d)" % [
			_tri_count(tight), _tri_count(spread)])


# --- Fixtures ----------------------------------------------------------------

## A straight run through the origin with a hole punched low at its middle, so
## the opening sits at x = 0 and can be sliced across without any rail maths.
func _wall(arch: float, cham := 0.14) -> Node3D:
	return Registry.build({
		"type": "wall",
		"nodes": Registry.to_wire([Vector3(-20, 0, 0), Vector3(20, 0, 0)]),
		"holes": Registry.to_wire([Vector3(0, 2.2, 0)]),
		"params": {"height": H, "thickness": 2.0, "batter": 0.0, "coping": 0.9,
			"tooth": 0.0, "chamfer": cham, "arch": arch, "opening": 4.0, "head": 4.5},
	}, null, false)


## The same wall with penetrations punched at the given points and no gate.
func _holed(holes: Array) -> Node3D:
	return Registry.build({
		"type": "wall",
		"nodes": Registry.to_wire([Vector3(-20, 0, 0), Vector3(20, 0, 0)]),
		"holes": Registry.to_wire(holes),
		"params": {"height": H, "thickness": 2.0, "batter": 0.0, "coping": 0.9,
			"tooth": 0.0, "chamfer": 0.14, "arch": 0.7, "opening": 4.0, "head": 4.5},
	}, null, false)


# --- Measuring ---------------------------------------------------------------


## How many times the soffit turns from rising to falling across the opening:
## one arch has one crown, four stacked in the same hole have four.
func _crowns(body: Node3D, wide := GATE_W) -> int:
	var ys := _soffits(body, wide)
	var crowns := 0
	var rising := true
	for i in range(1, ys.size()):
		var d := float(ys[i]) - float(ys[i - 1])
		if absf(d) < 0.05:
			continue
		if rising and d < 0.0:
			crowns += 1
		rising = d > 0.0
	return crowns


## Triangles landing on exactly the same three corners: two sweeps over one
## stretch of rail, which is what an unmerged overlap produces.
func _dupes(body: Node3D) -> int:
	var mesh := _mesh(body)
	if mesh == null:
		return -1
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var seen := {}
	var dupes := 0
	var i := 0
	while i + 2 < idx.size():
		var key: Array = []
		for k in 3:
			key.append(_key(verts[idx[i + k]]))
		key.sort()
		var sk := str(key)
		if seen.has(sk):
			dupes += 1
		seen[sk] = true
		i += 3
	return dupes


func _tri_count(body: Node3D) -> int:
	var mesh := _mesh(body)
	return 0 if mesh == null else mesh.get_faces().size() / 3

## The underside of the opening at each station across it: in a thin slice of x,
## the lowest vertex clear of the sill is the soffit there.
func _soffits(body: Node3D, wide_arg := 0.0) -> Array:
	var mesh := _mesh(body)
	if mesh == null:
		return []
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# Bin by x rather than sampling at guessed positions: the sweep puts its
	# stations where it likes and a sample between two of them finds nothing.
	var bins := 15
	var span := GATE_W if wide_arg <= 0.0 else wide_arg
	var lo := -span * 0.5 - 0.05
	var wide := span + 0.1
	var low := []
	for i in bins:
		low.append(INF)
	for v in verts:
		if v.y <= 1.0 or v.y >= H - 0.1 or v.x < lo or v.x > lo + wide:
			continue
		var b := clampi(int((v.x - lo) / wide * float(bins)), 0, bins - 1)
		low[b] = minf(float(low[b]), v.y)
	# A flat lintel has stations only at the jambs, so empty bins between them
	# are the expected answer, not a failure.
	var out: Array = []
	for i in bins:
		if float(low[i]) != INF:
			out.append(low[i])
	return out if out.size() >= 2 else []


func _span(vals: Array) -> float:
	var lo := INF
	var hi := -INF
	for v in vals:
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
	return hi - lo


static func _area(loop: PackedVector2Array) -> float:
	var a := 0.0
	for i in loop.size():
		var p := loop[i]
		var q := loop[(i + 1) % loop.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5


func _mesh(body: Node3D) -> ArrayMesh:
	if body == null:
		return null
	for c in body.get_children():
		if c is MeshInstance3D:
			return (c as MeshInstance3D).mesh as ArrayMesh
	return null


## An edge used by exactly one triangle is a hole in the solid. An edge used by
## four is two solids meeting along a shared face -- the buried foot of a wall
## against the buried sill of its own gateway -- which is not a hole and must
## not be counted as one.
func _open_edges(body: Node3D) -> int:
	var mesh := _mesh(body)
	if mesh == null:
		return -1
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var seen := {}
	var i := 0
	while i + 2 < idx.size():
		for e in [[0, 1], [1, 2], [2, 0]]:
			var ka := _key(verts[idx[i + e[0]]])
			var kb := _key(verts[idx[i + e[1]]])
			seen[(ka + "|" + kb) if ka < kb else (kb + "|" + ka)] = \
				int(seen.get((ka + "|" + kb) if ka < kb else (kb + "|" + ka), 0)) + 1
		i += 3
	var open := 0
	for k in seen:
		if int(seen[k]) == 1:
			open += 1
	return open


static func _key(v: Vector3) -> String:
	return "%d,%d,%d" % [roundi(v.x * 64.0), roundi(v.y * 64.0), roundi(v.z * 64.0)]


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
