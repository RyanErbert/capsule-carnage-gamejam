extends RefCounted

## Wave function collapse structures: adobe compounds built for deathmatch.
##
## A tileset of terraced clay massing — decks, parapets, ramps and arched
## tunnels — collapsed onto a square grid and meshed into one static body.
## The tileset is marble-first: a deck face only ever mates with another deck
## face AT THE SAME HEIGHT, floors are joined by ramps rather than steps, and
## every parapet sits INSIDE its own cell, so nothing clips the piece next door.
##
## Density comes from a height field of a few random peaks, so a compound reads
## as a forest of towers with low ground threaded between them instead of one
## flat puck. Foundations are separate pillars sunk to varying depths: dig under
## a structure and you find its roots, not a slab.
##
## Everything is a pure function of (seed, size, style): the client that places
## one sends nothing but the seed, and every other client collapses the identical
## structure locally. No per-tile sync, no mesh over the wire.

const CELL := 6.0        # meters per tile footprint
const LEVEL := 3.0       # meters per height step (one ramp's rise)
const LEVELS := 5        # floor heights 0..4
const BEVEL := 0.26      # chamfer on every exposed edge: adobe, not crates
const DECK := 0.8        # thickness of a walkable slab
const INSET := 0.07      # freestanding blocks shrink this much per side, so two
                         # neighbours never present coplanar faces to z-fight
const KERB_H := 0.62     # parapet height: stops a marble (r 0.39), clears a jump
const KERB_T := 0.55
const ARCH_H := 2.35     # headroom through a tunnel
const ARCH_W := 3.4      # ...and how wide its mouth is
const BASE_Y := -2.2     # massing runs down to here, then the pillars take over
const BURIED := -1.0e9   # the 'column top' of a cell with nothing standing in it
const CEIL_H := 2.7      # headroom under a silo hallway's ceiling
const SPAN_W := 3.6      # width of a walkway between compounds

# Socket alphabet. A face is either a walkable floor edge at a known height
# (only mates with the same height), or it's "soft" — open air, a parapet or a
# blank wall, which mate with each other freely.
const AIR := 0

# Module kinds, in the order the tileset is generated.
const K_VOID := "void"
const K_DECK := "deck"
const K_EDGE := "edge"      # parapet on one face
const K_CORNER := "corner"  # parapets on two adjacent faces
const K_CAP := "cap"        # parapets on three: a dead-end balcony
const K_RAMP := "ramp"      # h to h+1, kerbed down both flanks
const K_MASS := "mass"      # a blank block: massing, not floor
const K_ARCH := "arch"      # massing with a tunnel bored through it

const SOCK_MAX := 32     # socket ids run 0 (air), 1..LEVELS, 10.., 20..

static var _modules: Array = []
static var _flat: Dictionary = {}   # solver-friendly views of _modules
static var _fit: Array = []         # [face][socket] -> PackedByteArray of modules
static var _solved_cache: Dictionary = {}
static var _field_cache: Dictionary = {}


static func _solid(h: int) -> int:
	return 1 + h


static func _rail(h: int) -> int:
	return 10 + h


## A blank wall face. Soft like a parapet as far as fitting goes — it will sit
## against air, a parapet, or another wall — but it never opens onto a floor,
## so a mass block can't be mistaken for somewhere you can walk.
static func _wall(h: int) -> int:
	return 20 + h


static func _is_solid(s: int) -> bool:
	return s >= 1 and s <= LEVELS


## Two facing sockets fit if a floor meets the same floor, or if neither is a
## floor at all. A floor never opens onto nothing.
static func compatible(a: int, b: int) -> bool:
	if _is_solid(a) or _is_solid(b):
		return a == b
	return true


## Sockets are listed N, E, S, W for an unrotated module; a rotation of `rot`
## quarter-turns moves each face `rot` steps clockwise.
static func _rotated(sk: Array, rot: int) -> Array:
	var out := [0, 0, 0, 0]
	for i in 4:
		out[(i + rot) % 4] = sk[i]
	return out


## The tileset, built once. Weights here are the SHAPE preference only — how
## tall a given cell wants to be is decided per-structure by the height field.
static func modules() -> Array:
	if not _modules.is_empty():
		return _modules
	var out: Array = []
	out.append({"kind": K_VOID, "h": 0, "rot": 0, "sk": [AIR, AIR, AIR, AIR], "w": 1.0})
	for h in LEVELS:
		var s := _solid(h)
		var r := _rail(h)
		var wl := _wall(h)
		# Open plaza is cheap; the pieces that CLOSE a terrace off are what let
		# a hole survive next to it, so they carry most of the weight.
		out.append({"kind": K_DECK, "h": h, "rot": 0, "sk": [s, s, s, s], "w": 1.5})
		for rot in 4:
			out.append({"kind": K_EDGE, "h": h, "rot": rot,
				"sk": _rotated([r, s, s, s], rot), "w": 2.4})
			out.append({"kind": K_CORNER, "h": h, "rot": rot,
				"sk": _rotated([r, r, s, s], rot), "w": 2.2})
			out.append({"kind": K_CAP, "h": h, "rot": rot,
				"sk": _rotated([r, r, s, r], rot), "w": 1.3})
		# Blank massing. Without it every gap in the walkable network is a hole
		# straight through to the sky; with it the gaps read as the plant the
		# walkways are threaded through.
		out.append({"kind": K_MASS, "h": h, "rot": 0,
			"sk": [wl, wl, wl, wl], "w": 2.8})
		# The penetrable one: mass you can roll straight through. Only two
		# distinct orientations — a tunnel looks the same from either mouth.
		for rot in 2:
			out.append({"kind": K_ARCH, "h": h, "rot": rot,
				"sk": _rotated([s, wl, s, wl], rot), "w": 1.1})
		# Ramps climb from this floor onto the next: the high end is a floor
		# edge at h+1, the low end a floor edge at h, the flanks are kerbed.
		if h < LEVELS - 1:
			for rot in 4:
				out.append({"kind": K_RAMP, "h": h, "rot": rot,
					"sk": _rotated([_solid(h + 1), r, s, r], rot), "w": 2.6})
	_modules = out
	_build_tables()
	return _modules


## Dictionary lookups inside the propagation loop were most of the solve time.
## Everything the solver touches gets copied into flat arrays once.
##
## The fit table is keyed by SOCKET, not by module: whether a neighbour fits
## depends only on the socket value facing it, and there are two dozen socket
## values against a hundred modules. Unioning over the sockets a cell can still
## present turns the propagation step from O(modules squared) into O(modules),
## which is the difference between a compound appearing and the map hanging.
static func _build_tables() -> void:
	var m := _modules.size()
	var sk := PackedInt32Array()
	sk.resize(m * 4)
	var hs := PackedInt32Array()
	hs.resize(m)
	var ws := PackedFloat32Array()
	ws.resize(m)
	var kinds := PackedStringArray()
	kinds.resize(m)
	var rots := PackedInt32Array()
	rots.resize(m)
	for k in m:
		var mod: Dictionary = _modules[k]
		for d in 4:
			sk[k * 4 + d] = int(mod["sk"][d])
		hs[k] = int(mod["h"])
		ws[k] = float(mod["w"])
		kinds[k] = str(mod["kind"])
		rots[k] = int(mod["rot"])
	_flat = {"sk": sk, "h": hs, "w": ws, "kind": kinds, "rot": rots, "m": m}
	_fit = []
	for face in 4:
		var per: Array = []
		for a in SOCK_MAX:
			var row := PackedByteArray()
			row.resize(m)
			for k in m:
				row[k] = 1 if compatible(a, sk[k * 4 + face]) else 0
			per.append(row)
		_fit.append(per)


# --- Solver -----------------------------------------------------------------

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## A few soft peaks: cells near one want to tower, cells far from every peak
## want to be open ground. This is what turns a uniform pad into a compound
## with nodes in it.
static func _height_field(rng: RandomNumberGenerator, size: int) -> PackedFloat32Array:
	var peaks: Array = []
	for i in 2 + rng.randi() % 2:
		peaks.append([Vector2(rng.randf() * size, rng.randf() * size),
			rng.randf_range(LEVELS * 0.32, LEVELS * 0.66),
			rng.randf_range(0.8, 1.5)])
	var out := PackedFloat32Array()
	out.resize(size * size)
	for r in size:
		for c in size:
			var best := 0.0
			for pk in peaks:
				var d: float = Vector2(c + 0.5, r + 0.5).distance_to(pk[0])
				var falloff: float = pk[2]
				best = maxf(best, float(pk[1]) * exp(-(d * d) / (2.0 * falloff * falloff)))
			out[r * size + c] = best
	return out


## Collapse a `size` x `size` grid. Returns a flat Array of module indices
## (row-major, -1 never appears — failures fall back to void).
static func solve(seed_value: int, size: int, style := "surface") -> Array:
	modules()
	var m: int = _flat["m"]
	var sk: PackedInt32Array = _flat["sk"]
	var rng := RandomNumberGenerator.new()
	for attempt in 12:
		rng.seed = seed_value + attempt * 7919
		var field := _height_field(rng, size)
		var wave: Array = []
		for i in size * size:
			var opts := PackedByteArray()
			opts.resize(m)
			opts.fill(1)
			wave.append(opts)
		# Outside the grid is open air, so a boundary cell can't present a
		# floor edge outward — the structure always closes itself off. The rim
		# is also held to the bottom two floors: a compound ringed by a nine
		# metre cliff is scenery, and a marble needs somewhere to roll on.
		var hs: PackedInt32Array = _flat["h"]
		var kinds: PackedStringArray = _flat["kind"]
		var stack: Array = []
		for r in size:
			for c in size:
				var i := r * size + c
				var rim := r == 0 or c == 0 or r == size - 1 or c == size - 1
				for d in 4:
					var n := Vector2i(c, r) + DIRS[d]
					if n.x >= 0 and n.y >= 0 and n.x < size and n.y < size:
						continue
					for k in m:
						if wave[i][k] == 1 and _is_solid(sk[k * 4 + d]):
							wave[i][k] = 0
				if rim:
					for k in m:
						if wave[i][k] == 1 and hs[k] > 1 and kinds[k] != K_VOID:
							wave[i][k] = 0
				stack.append(i)
		if not _propagate(wave, stack, size, m):
			continue
		# Plant the peaks before anything else. Left to weights alone the first
		# cell to collapse drags the whole walkable network to its own height —
		# floors only ever mate with the same floor — and every compound comes
		# out one storey tall. Forcing the tallest cell first makes the rest of
		# the collapse ramp DOWN to meet the ground, which is the shape wanted.
		var ok := _plant_peaks(wave, field, size, m)
		while ok:
			var pick := _lowest_entropy(wave, rng)
			if pick < 0:
				break
			if not _collapse(wave, pick, rng, field[pick], style):
				ok = false
				break
			if not _propagate(wave, [pick], size, m):
				ok = false
				break
		if not ok:
			continue
		var grid: Array = []
		for i in size * size:
			grid.append(_only(wave[i]))
		_prune_islands(grid, size)
		_field_cache["%d:%d:%s" % [seed_value, size, style]] = field
		return grid
	var fallback: Array = []
	fallback.resize(size * size)
	fallback.fill(0)   # all void: better an empty pad than a broken one
	return fallback


## Pin the cells the height field wants tallest to a deck at that height, in
## descending order, propagating after each. A pin that no longer fits is
## skipped rather than failed: by then a neighbouring pin has usually claimed
## the same plateau, which is the outcome we were after anyway.
static func _plant_peaks(wave: Array, field: PackedFloat32Array, size: int, m: int) -> bool:
	var kinds: PackedStringArray = _flat["kind"]
	var hs: PackedInt32Array = _flat["h"]
	var order: Array = []
	for i in field.size():
		if field[i] > 1.2:
			order.append(i)
	order.sort_custom(func(a, b): return field[a] > field[b])
	var planted := 0
	for i in order:
		if planted >= 4:
			break
		var want: int = clampi(int(round(field[i])), 1, LEVELS - 1)
		var pick := -1
		for k in m:
			if wave[i][k] == 1 and kinds[k] == K_DECK and hs[k] == want:
				pick = k
				break
		if pick < 0:
			continue
		for k in m:
			wave[i][k] = 1 if k == pick else 0
		if not _propagate(wave, [i], size, m):
			return false
		planted += 1
	return true


## Solved grids get reused — build(), item_spots() and anchors() all want the
## same collapse, and re-solving one per call showed up as a hitch on map load.
static func solved(seed_value: int, size: int, style := "surface") -> Array:
	var key := "%d:%d:%s" % [seed_value, size, style]
	if not _solved_cache.has(key):
		if _solved_cache.size() > 24:
			_solved_cache.clear()
		_solved_cache[key] = solve(seed_value, size, style)
	return _solved_cache[key]


static func _only(opts: PackedByteArray) -> int:
	for k in opts.size():
		if opts[k] == 1:
			return k
	return 0


static func _count(opts: PackedByteArray) -> int:
	var n := 0
	for k in opts.size():
		n += opts[k]
	return n


## Fewest remaining options wins, ties broken by a deterministic jitter.
static func _lowest_entropy(wave: Array, rng: RandomNumberGenerator) -> int:
	var best := -1
	var best_score := INF
	for i in wave.size():
		var n := _count(wave[i])
		if n <= 1:
			continue
		var score := float(n) + rng.randf() * 0.6
		if score < best_score:
			best_score = score
			best = i
	return best


## Weighted pick, with the cell's height target from the field folded in: a
## module whose floor is near what this spot wants is far likelier than one
## three storeys off, and void is likeliest where the field is flat.
static func _collapse(wave: Array, i: int, rng: RandomNumberGenerator,
		target: float, style: String) -> bool:
	var opts: PackedByteArray = wave[i]
	var hs: PackedInt32Array = _flat["h"]
	var ws: PackedFloat32Array = _flat["w"]
	var kinds: PackedStringArray = _flat["kind"]
	var silo := style == "silo"
	var bias := PackedFloat32Array()
	bias.resize(opts.size())
	var total := 0.0
	for k in opts.size():
		if opts[k] == 0:
			continue
		var w := float(ws[k])
		var kind := kinds[k]
		if kind == K_VOID:
			w *= 0.25 + 5.0 * exp(-target * target * 1.4)
			if silo:
				w *= 0.3
		elif kind == K_MASS:
			w *= 0.7 + 2.6 * target
			if silo:
				w *= 1.9
		else:
			var d := float(hs[k]) - target
			w *= exp(-d * d * 0.55)
			if silo:
				if kind == K_ARCH:
					w *= 3.2
				elif kind == K_DECK:
					w *= 0.55
		bias[k] = w
		total += w
	if total <= 0.0:
		return false
	var roll := rng.randf() * total
	var chosen := -1
	for k in opts.size():
		if opts[k] == 0:
			continue
		roll -= bias[k]
		if roll <= 0.0:
			chosen = k
			break
	if chosen < 0:
		chosen = _only(opts)
	for k in opts.size():
		opts[k] = 1 if k == chosen else 0
	return true


## AC-3: a neighbour may keep an option only while some surviving option here
## still fits it. Returns false on a contradiction (a cell with nothing left).
static func _propagate(wave: Array, stack: Array, size: int, m: int) -> bool:
	var sk: PackedInt32Array = _flat["sk"]
	var work: Array = stack.duplicate()
	var allowed := PackedByteArray()
	allowed.resize(m)
	var present := PackedByteArray()
	present.resize(SOCK_MAX)
	while not work.is_empty():
		var i: int = work.pop_back()
		var here := Vector2i(i % size, i / size)
		var opts: PackedByteArray = wave[i]
		for d in 4:
			var n: Vector2i = here + DIRS[d]
			if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
				continue
			var ni: int = n.y * size + n.x
			var them: PackedByteArray = wave[ni]
			# Every socket this cell can still show on face d...
			present.fill(0)
			for j in m:
				if opts[j] == 1:
					present[sk[j * 4 + d]] = 1
			# ...and everything that fits any one of them.
			allowed.fill(0)
			var per: Array = _fit[(d + 2) % 4]
			for a in SOCK_MAX:
				if present[a] == 0:
					continue
				var row: PackedByteArray = per[a]
				for k in m:
					if row[k] == 1:
						allowed[k] = 1
			var changed := false
			var left := 0
			for k in m:
				if them[k] == 0:
					continue
				if allowed[k] == 0:
					them[k] = 0
					changed = true
				else:
					left += 1
			if not changed:
				continue
			if left == 0:
				return false
			work.append(ni)
	return true


## Anything a marble can't roll to gets removed. Walkable cells connect only
## through faces where BOTH sides are floor edges, so this is exactly the
## reachable set; the largest component survives and the rest becomes void.
static func _prune_islands(grid: Array, size: int) -> void:
	var sk: PackedInt32Array = _flat["sk"]
	var kinds: PackedStringArray = _flat["kind"]
	var seen := PackedInt32Array()
	seen.resize(size * size)
	seen.fill(-1)
	var groups: Array = []
	for start in grid.size():
		var kind := kinds[grid[start]]
		# Massing isn't walkable, so it's neither a seed nor something to prune:
		# a blank block standing on its own is scenery, not a marooned platform.
		if seen[start] != -1 or kind == K_VOID or kind == K_MASS:
			continue
		var gi := groups.size()
		var cells: Array = [start]
		seen[start] = gi
		var qi := 0
		while qi < cells.size():
			var i: int = cells[qi]
			qi += 1
			var here := Vector2i(i % size, i / size)
			for d in 4:
				var n: Vector2i = here + DIRS[d]
				if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
					continue
				var ni: int = n.y * size + n.x
				if seen[ni] != -1:
					continue
				if not _is_solid(sk[grid[i] * 4 + d]):
					continue
				if not _is_solid(sk[grid[ni] * 4 + (d + 2) % 4]):
					continue
				seen[ni] = gi
				cells.append(ni)
		groups.append(cells)
	if groups.is_empty():
		return
	var biggest := 0
	for gi in groups.size():
		if groups[gi].size() > groups[biggest].size():
			biggest = gi
	for gi in groups.size():
		if gi == biggest:
			continue
		for i in groups[gi]:
			grid[i] = 0


# --- Geometry ---------------------------------------------------------------

# Faces are (axis, sign) pairs: +X, -X, +Y, -Y, +Z, -Z. A mask has one bit per
# face; a face left out is never drawn AND never chamfered, so two solids that
# meet flush have no seam to z-fight and no groove opening onto darkness.
const F_PX := 1
const F_NX := 2
const F_PY := 4
const F_NY := 8
const F_PZ := 16
const F_NZ := 32
const F_ALL := 63
const DIR_FACE := [F_NZ, F_PX, F_PZ, F_NX]   # N, E, S, W


static func _face_bit(axis: int, sign: float) -> int:
	return 1 << (axis * 2 + (0 if sign > 0.0 else 1))


static func _drawn(mask: int, axis: int, sign: float) -> bool:
	return (mask & _face_bit(axis, sign)) != 0


## The chamfered corner (sx, sy, sz) as face `axis` sees it: full extent along
## that axis, pulled in by the bevel on the others — but only where the
## neighbouring face is actually being drawn.
static func _corner(at: Vector3, e: Vector3, bev: float, mask: int,
		s: Vector3, axis: int) -> Vector3:
	var p := Vector3.ZERO
	for k in 3:
		var sk_: float = s[k]
		if k == axis:
			p[k] = sk_ * e[k]
		else:
			p[k] = sk_ * (e[k] - (bev if _drawn(mask, k, sk_) else 0.0))
	return at + p


## One triangle, wound so Godot lights it from the outside. Godot renders
## CLOCKWISE-wound triangles as the front face, the opposite of the right-hand
## rule these corner orders read as, so the emitted order is reversed.
static func _emit_tri(st: SurfaceTool, tris: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).length_squared() < 1e-10:
		return
	st.set_normal(n)
	for v in [a, c, b]:
		st.add_vertex(v)
		tris.append(v)


## A quad given in ring order, oriented by its outward normal so callers never
## have to reason about which way round they listed the corners.
static func _quad(st: SurfaceTool, tris: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).dot(n) < 0.0:
		var t := b
		b = d
		d = t
	_emit_tri(st, tris, a, b, c, n)
	_emit_tri(st, tris, a, c, d, n)


## A chamfered box: six faces pulled in by `bev`, twelve edge strips and eight
## corner triangles filling the gaps. `mask` selects which faces exist; an edge
## appears only where both its faces do, a corner only where all three do.
static func _rbox(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		size: Vector3, mask := F_ALL, bev := BEVEL) -> void:
	var e := size * 0.5
	bev = minf(bev, minf(e.x, minf(e.y, e.z)) * 0.45)
	if e.x <= 0.001 or e.y <= 0.001 or e.z <= 0.001:
		return
	for axis in 3:
		for sgn in [1.0, -1.0]:
			if not _drawn(mask, axis, sgn):
				continue
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			var ring: Array = []
			for pair in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
				var s := Vector3.ZERO
				s[axis] = sgn
				s[u] = pair[0]
				s[v] = pair[1]
				ring.append(_corner(at, e, bev, mask, s, axis))
			var n := Vector3.ZERO
			n[axis] = sgn
			_quad(st, tris, ring[0], ring[1], ring[2], ring[3], n)
	# Edge chamfers
	for a1 in 3:
		for a2 in range(a1 + 1, 3):
			var w := 3 - a1 - a2
			for s1 in [1.0, -1.0]:
				for s2 in [1.0, -1.0]:
					if not _drawn(mask, a1, s1) or not _drawn(mask, a2, s2):
						continue
					var lo := Vector3.ZERO
					lo[a1] = s1
					lo[a2] = s2
					lo[w] = -1.0
					var hi := lo
					hi[w] = 1.0
					var n := Vector3.ZERO
					n[a1] = s1
					n[a2] = s2
					_quad(st, tris,
						_corner(at, e, bev, mask, lo, a1),
						_corner(at, e, bev, mask, lo, a2),
						_corner(at, e, bev, mask, hi, a2),
						_corner(at, e, bev, mask, hi, a1), n.normalized())
	# Corner triangles
	for sx in [1.0, -1.0]:
		for sy in [1.0, -1.0]:
			for sz in [1.0, -1.0]:
				var s := Vector3(sx, sy, sz)
				if not (_drawn(mask, 0, sx) and _drawn(mask, 1, sy) and _drawn(mask, 2, sz)):
					continue
				_emit_tri(st, tris,
					_corner(at, e, bev, mask, s, 0),
					_corner(at, e, bev, mask, s, 1),
					_corner(at, e, bev, mask, s, 2), s.normalized())


# --- Materials ---------------------------------------------------------------
# The same sand the terrain is textured with, triplanar so nothing needs UVs.
# Adobe reads as the ground it was dug out of; the trim is the same clay fired
# darker, which is all the contrast a parapet needs to be legible.

const ADOBE_SHADER := "
shader_type spatial;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 tint = vec3(1.0);
uniform float scale = 0.09;
varying vec3 wpos;
varying vec3 wnrm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 w = pow(abs(wnrm), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 c = texture(sand_tex, wpos.zy * scale).rgb * w.x
	       + texture(sand_tex, wpos.xz * scale).rgb * w.y
	       + texture(sand_tex, wpos.xy * scale).rgb * w.z;
	// Faces looking up catch the sun; the undersides of terraces go to shadow.
	c *= 0.72 + 0.34 * clamp(wnrm.y * 0.5 + 0.5, 0.0, 1.0);
	ALBEDO = c * tint;
	ROUGHNESS = 0.92;
	SPECULAR = 0.15;
}
"

static var _adobe_shader: Shader


static func _clay(tint: Color, scale := 0.09) -> ShaderMaterial:
	if _adobe_shader == null:
		_adobe_shader = Shader.new()
		_adobe_shader.code = ADOBE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _adobe_shader
	mat.set_shader_parameter("sand_tex", load("res://Terrain/textures/sand.jpg"))
	mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("scale", scale)
	return mat


static func _surface(st: SurfaceTool, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi


static func _finish(mass: SurfaceTool, trim: SurfaceTool, tris: PackedVector3Array,
		tag: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("build_type", tag)
	body.add_child(_surface(mass, _clay(Color(1.06, 0.94, 0.76))))
	body.add_child(_surface(trim, _clay(Color(0.78, 0.58, 0.42), 0.16)))
	if not tris.is_empty():
		var col := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(tris)
		col.shape = shape
		body.add_child(col)
	return body


# --- Cell pieces -------------------------------------------------------------

## A cell's massing: one solid column from the bedrock line up to its floor.
## Terraces are the point — a raised deck reads as a block you can stand on top
## of, not a slab hovering over daylight. A face is drawn only where the
## neighbour stands lower, so two flush columns never z-fight along their seam,
## and the chamfer follows the same rule: it only ever cuts a visible edge.
static func _column(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		top: float, col: PackedFloat32Array, size: int, r: int, c: int) -> void:
	var mask := _wall_mask(col, size, r, c) | F_NY | F_PY
	var height := top - BASE_Y
	_rbox(st, tris, at + Vector3(0, BASE_Y + height * 0.5, 0), Vector3(CELL, height, CELL), mask)


## Which of a cell's four walls face open air. A neighbour standing as tall as
## us (or taller) buries the seam, so neither side draws it.
static func _wall_mask(col: PackedFloat32Array, size: int, r: int, c: int) -> int:
	var mine: float = col[r * size + c]
	var mask := 0
	for d in 4:
		var n := Vector2i(c, r) + DIRS[d]
		var theirs := BURIED
		if n.x >= 0 and n.y >= 0 and n.x < size and n.y < size:
			theirs = col[n.y * size + n.x]
		if theirs < mine:
			mask |= int(DIR_FACE[d])
	return mask


## Parapet along one face, sitting wholly inside the cell — the old rail
## straddled the boundary on posts, which is what left bars hanging in the air
## wherever the neighbour was a different height.
static func _kerb(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		top: float, d: int) -> void:
	var n := Vector3(DIRS[d].x, 0, DIRS[d].y)
	var size := Vector3(CELL, KERB_H, KERB_T) if absf(n.z) > 0.5 else Vector3(KERB_T, KERB_H, CELL)
	_rbox(st, tris, at + n * (CELL * 0.5 - KERB_T * 0.5) + Vector3(0, top + KERB_H * 0.5, 0),
		size, F_ALL, 0.12)


## A ramp climbing from `top` to `top + LEVEL` toward `rot`: one unbroken
## inclined slab a marble can roll, standing on its own massing down to the
## bedrock line. Nothing here is a tread, so nothing here has an open side.
static func _ramp(st: SurfaceTool, tris: PackedVector3Array, tr: SurfaceTool,
		at: Vector3, top: float, rot: int, sk: Array) -> void:
	var fwd := Vector3(DIRS[rot].x, 0, DIRS[rot].y)
	var side := Vector3(-fwd.z, 0, fwd.x)
	var hw := CELL * 0.5 - INSET
	var corners: Dictionary = {}
	for s: float in [-1.0, 1.0]:
		for t: float in [-1.0, 1.0]:
			var y: float = top + (t * 0.5 + 0.5) * LEVEL
			corners["%d,%d" % [int(s), int(t)]] = at + side * (s * hw) + fwd * (t * hw) + Vector3(0, y, 0)
	var tl: Vector3 = corners["-1,-1"]
	var tr_: Vector3 = corners["1,-1"]
	var th: Vector3 = corners["1,1"]
	var thl: Vector3 = corners["-1,1"]
	var bl := Vector3(tl.x, BASE_Y, tl.z)
	var br := Vector3(tr_.x, BASE_Y, tr_.z)
	var bh := Vector3(th.x, BASE_Y, th.z)
	var bhl := Vector3(thl.x, BASE_Y, thl.z)
	var up_n := (fwd * -LEVEL + Vector3(0, CELL, 0)).normalized()
	_quad(st, tris, tl, tr_, th, thl, up_n)
	_quad(st, tris, bl, br, bh, bhl, Vector3.DOWN)
	_quad(st, tris, tr_, th, bh, br, side)
	_quad(st, tris, tl, thl, bhl, bl, -side)
	_quad(st, tris, tl, tr_, br, bl, -fwd)
	_quad(st, tris, thl, th, bh, bhl, fwd)
	for s in [-1.0, 1.0]:
		var d := (rot + 1) % 4 if s > 0.0 else (rot + 3) % 4
		if _is_solid(sk[d]):
			continue
		_ramp_kerb(tr, tris, at, top, fwd, side, s)


## Kerb riding the slope of a ramp: an extruded prism, not a bar on posts.
static func _ramp_kerb(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		top: float, fwd: Vector3, side: Vector3, s: float) -> void:
	var hw := CELL * 0.5 - INSET
	var pts: Array = []
	for t: float in [-1.0, 1.0]:
		var y: float = top + (t * 0.5 + 0.5) * LEVEL
		for off in [hw - KERB_T, hw]:
			pts.append(at + side * (s * off) + fwd * (t * hw) + Vector3(0, y, 0))
	# pts: [lo-in, lo-out, hi-in, hi-out]
	var up := Vector3(0, KERB_H, 0)
	var lo_in: Vector3 = pts[0]
	var lo_out: Vector3 = pts[1]
	var hi_in: Vector3 = pts[2]
	var hi_out: Vector3 = pts[3]
	var out_n := side * s
	_quad(st, tris, lo_in + up, hi_in + up, hi_out + up, lo_out + up, Vector3.UP)
	_quad(st, tris, lo_in, hi_in, hi_in + up, lo_in + up, -out_n)
	_quad(st, tris, lo_out, hi_out, hi_out + up, lo_out + up, out_n)
	_quad(st, tris, lo_in, lo_out, lo_out + up, lo_in + up, -fwd)
	_quad(st, tris, hi_in, hi_out, hi_out + up, hi_in + up, fwd)


## Massing with a tunnel bored through it: two haunches and a lintel standing on
## the cell's own column. The one tile you go THROUGH instead of around.
static func _arch(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		top: float, rot: int, lintel: float) -> void:
	var axis := Vector3(DIRS[rot].x, 0, DIRS[rot].y)
	var side := Vector3(-axis.z, 0, axis.x)
	var haunch := (CELL - ARCH_W) * 0.5
	for s in [-1.0, 1.0]:
		_rbox(st, tris,
			at + side * (s * (CELL * 0.5 - haunch * 0.5)) + Vector3(0, top + ARCH_H * 0.5, 0),
			Vector3(haunch, ARCH_H, CELL) if absf(side.x) > 0.5 \
				else Vector3(CELL, ARCH_H, haunch))
	_rbox(st, tris, at + Vector3(0, top + ARCH_H + lintel * 0.5, 0),
		Vector3(CELL - INSET * 2.0, lintel, CELL - INSET * 2.0))


## Foundations: pillars, not a slab. Most cells get one, depths vary wildly and
## a quarter of them go deep, so digging under a compound finds roots and gaps
## rather than one even floor.
static func _foundation(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		rng: RandomNumberGenerator, heavy: bool) -> void:
	var roll := rng.randf()
	var w := rng.randf_range(2.1, 3.4)
	var off := Vector3(rng.randf_range(-1.1, 1.1), 0, rng.randf_range(-1.1, 1.1))
	var deep := rng.randf() < 0.28
	var depth := rng.randf_range(7.0, 15.0) if deep else rng.randf_range(1.8, 5.0)
	if not heavy and roll > 0.55:
		return
	_rbox(st, tris, at + off + Vector3(0, BASE_Y - depth * 0.5, 0), Vector3(w, depth, w))


# --- Build -------------------------------------------------------------------

## The whole compound: adobe massing, clay parapets, and one concave collider
## over the lot. Origin is the center of the pad, with floor level 0 at y = 0.
##
## Two passes. The first settles how tall every cell's massing stands, because
## a cell cannot know which of its walls to draw until its neighbours have
## decided; the second cuts the geometry.
static func build(seed_value: int, size: int, style := "surface") -> StaticBody3D:
	var grid := solved(seed_value, size, style)
	var field: PackedFloat32Array = _field_cache.get(
		"%d:%d:%s" % [seed_value, size, style], PackedFloat32Array())
	if field.size() != grid.size():
		field.resize(grid.size())
	var kinds: PackedStringArray = _flat["kind"]
	var hs: PackedInt32Array = _flat["h"]
	var rots: PackedInt32Array = _flat["rot"]
	var skf: PackedInt32Array = _flat["sk"]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x5f3a91

	var mass := SurfaceTool.new()
	var trim := SurfaceTool.new()
	mass.begin(Mesh.PRIMITIVE_TRIANGLES)
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := PackedVector3Array()

	var silo := style == "silo"
	var half := size * CELL * 0.5
	var col := PackedFloat32Array()
	col.resize(size * size)
	var extra := PackedFloat32Array()
	extra.resize(size * size)
	for i in grid.size():
		var kind := kinds[grid[i]]
		var top: float = hs[grid[i]] * LEVEL
		match kind:
			K_VOID:
				col[i] = BURIED
			K_MASS:
				# Blank blocks are the towers: how far one rises follows the same
				# height field the collapse used, so they bunch into nodes rather
				# than sprinkling evenly and reading as rubble.
				extra[i] = LEVEL * clampf(0.6 + field[i] * 1.3, 0.6, 4.5) \
					* rng.randf_range(0.75, 1.25)
				col[i] = top + extra[i]
			K_ARCH:
				extra[i] = LEVEL * rng.randf_range(0.5, 1.6)
				col[i] = top + ARCH_H + extra[i]
			K_RAMP:
				# The low end only: a neighbour that buries itself against the
				# high end would leave a hole where the ramp has climbed away.
				col[i] = top
			_:
				col[i] = top

	for r in size:
		for c in size:
			var i := r * size + c
			var mi: int = grid[i]
			var kind := kinds[mi]
			if kind == K_VOID:
				continue
			var at := Vector3(-half + c * CELL + CELL * 0.5, 0.0, -half + r * CELL + CELL * 0.5)
			var h: int = hs[mi]
			var top := h * LEVEL
			var sk: Array = [skf[mi * 4], skf[mi * 4 + 1], skf[mi * 4 + 2], skf[mi * 4 + 3]]
			if kind == K_RAMP:
				_ramp(mass, tris, trim, at, top, rots[mi], sk)
			else:
				var stack := col[i]
				if kind == K_ARCH:
					stack = top   # the column stops at the tunnel floor
				_column(mass, tris, at, stack, col, size, r, c)
				if kind == K_ARCH:
					_arch(mass, tris, at, top, rots[mi], extra[i])
			if kind != K_MASS and kind != K_ARCH and kind != K_RAMP:
				for d in 4:
					if _is_solid(sk[d]):
						continue
					# The ground floor's outer edge is left open: that gap is
					# how a marble gets in off the sand.
					var edge := Vector2i(c, r) + DIRS[d]
					var outside := edge.x < 0 or edge.y < 0 or edge.x >= size or edge.y >= size
					if outside and h == 0:
						continue
					_kerb(trim, tris, at, top, d)
				if silo:
					_ceiling(mass, tris, at, top, sk)
			_foundation(mass, tris, at, rng, kind == K_MASS or kind == K_ARCH)
	return _finish(mass, trim, tris, "wfc")


## Silo style roofs its walkways over, which is what turns open terraces into
## corridors. Ramps stay open — they are the stairwells between floors.
static func _ceiling(st: SurfaceTool, tris: PackedVector3Array, at: Vector3,
		top: float, sk: Array) -> void:
	var mask := F_PY | F_NY
	for d in 4:
		if not _is_solid(sk[d]):
			mask |= int(DIR_FACE[d])
	_rbox(st, tris, at + Vector3(0, top + CEIL_H + DECK * 0.5, 0),
		Vector3(CELL, DECK, CELL), mask)


# --- Queries -----------------------------------------------------------------

## Local positions on this compound worth putting an item on: balconies and
## dead ends rather than the middle of a plaza, spread out so two pickups never
## share a terrace. Deterministic, so every client agrees where they are.
static func item_spots(seed_value: int, size: int, style := "surface") -> Array:
	var grid := solved(seed_value, size, style)
	var kinds: PackedStringArray = _flat["kind"]
	var hs: PackedInt32Array = _flat["h"]
	var half := size * CELL * 0.5
	var out: Array = []
	var cands: Array = []
	for r in size:
		for c in size:
			var mi: int = grid[r * size + c]
			var kind := kinds[mi]
			if kind != K_CAP and kind != K_CORNER and kind != K_EDGE:
				continue
			cands.append({"r": r, "c": c, "h": hs[mi],
				"score": (3 if kind == K_CAP else (2 if kind == K_CORNER else 1)) + hs[mi]})
	cands.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	for cd in cands:
		if out.size() >= 4:
			break
		var p := Vector3(-half + int(cd["c"]) * CELL + CELL * 0.5,
			int(cd["h"]) * LEVEL, -half + int(cd["r"]) * CELL + CELL * 0.5)
		var clear := true
		for q in out:
			if p.distance_to(q) < CELL * 1.9:
				clear = false
				break
		if clear:
			out.append(p)
	return out


## Where a walkway could tie into this compound from outside: deck cells on the
## rim, with the direction they face out to. Used to string spans between
## neighbouring compounds.
static func anchors(seed_value: int, size: int, style := "surface") -> Array:
	var grid := solved(seed_value, size, style)
	var kinds: PackedStringArray = _flat["kind"]
	var hs: PackedInt32Array = _flat["h"]
	var half := size * CELL * 0.5
	var out: Array = []
	for r in size:
		for c in size:
			var mi: int = grid[r * size + c]
			var kind := kinds[mi]
			if kind == K_VOID or kind == K_MASS or kind == K_RAMP:
				continue
			for d in 4:
				var n := Vector2i(c, r) + DIRS[d]
				var open := n.x < 0 or n.y < 0 or n.x >= size or n.y >= size
				if not open:
					open = kinds[grid[n.y * size + n.x]] == K_VOID
				if not open:
					continue
				var dir := Vector3(DIRS[d].x, 0, DIRS[d].y)
				out.append({
					"pos": Vector3(-half + c * CELL + CELL * 0.5, int(hs[mi]) * LEVEL,
						-half + r * CELL + CELL * 0.5) + dir * (CELL * 0.5),
					"dir": dir,
				})
	return out


# --- Single parts ------------------------------------------------------------
# The same tileset, one piece at a time, for building by hand off the drone.
# Every part is drawn around the origin with its walking surface at y = 0, so
# whatever the placement grid hands us is where you stand.

const PART_KINDS := ["deck", "edge", "corner", "cap", "ramp", "arch", "mass", "pillar", "span"]

## Which faces of a deck get a parapet, by part. Faces are N, E, S, W, and the
## piece is placed unrotated — the build tool spins the whole node instead.
const PART_RAILS := {"deck": [], "edge": [0], "corner": [0, 1], "cap": [0, 1, 3]}

## What each part offers on each face, so the drone can only stand a piece next
## to another one it actually mates with. Index order is N, E, S, W; "f" is a
## floor edge, "w" blank wall, "-" open air.
const PART_FACES := {
	"deck": ["f", "f", "f", "f"],
	"edge": ["-", "f", "f", "f"],
	"corner": ["-", "-", "f", "f"],
	"cap": ["-", "-", "f", "-"],
	"ramp": ["u", "-", "f", "-"],   # u: floor one level UP
	"arch": ["f", "w", "f", "w"],
	"mass": ["w", "w", "w", "w"],
	"pillar": ["-", "-", "-", "-"],
	"span": ["f", "-", "f", "-"],
}


## Can `b` sit directly `d` (N/E/S/W) of `a`? A floor only ever opens onto the
## same floor; everything soft mates with everything soft.
static func parts_fit(a: String, b: String, d: int, a_rot: int, b_rot: int) -> bool:
	var fa: Array = PART_FACES.get(a, ["-", "-", "-", "-"])
	var fb: Array = PART_FACES.get(b, ["-", "-", "-", "-"])
	var mine: String = fa[(d - a_rot + 8) % 4]
	var theirs: String = fb[((d + 2) % 4 - b_rot + 8) % 4]
	if mine == "f" or theirs == "f" or mine == "u" or theirs == "u":
		return mine == theirs
	return true


static func build_part(kind: String) -> StaticBody3D:
	var mass := SurfaceTool.new()
	var trim := SurfaceTool.new()
	mass.begin(Mesh.PRIMITIVE_TRIANGLES)
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := PackedVector3Array()
	var at := Vector3.ZERO
	var open: Array = [AIR, AIR, AIR, AIR]
	# By hand, a piece is a plinth thick enough to stand on rather than a whole
	# column: you are stacking these, not growing them out of the ground.
	var plinth := Vector3(CELL, DECK, CELL)
	match kind:
		"ramp":
			_ramp(mass, tris, trim, at, 0.0, 0, open)
		"arch":
			_rbox(mass, tris, at + Vector3(0, -DECK * 0.5, 0), plinth)
			_arch(mass, tris, at, 0.0, 0, LEVEL)
		"mass":
			_rbox(mass, tris, at + Vector3(0, (LEVEL - DECK) * 0.5, 0),
				Vector3(CELL - INSET * 2.0, LEVEL + DECK, CELL - INSET * 2.0))
		"pillar":
			_rbox(mass, tris, at + Vector3(0, -DECK - 3.0, 0), Vector3(2.8, 6.0, 2.8))
		"span":
			_span_geo(mass, trim, tris, CELL)
		_:
			_rbox(mass, tris, at + Vector3(0, -DECK * 0.5, 0), plinth)
			for d in PART_RAILS.get(kind, []):
				_kerb(trim, tris, at, 0.0, int(d))
	return _finish(mass, trim, tris, "wfcpart")


## A walkway running along +X from the origin: the piece that ties one compound
## to the next, at whatever angle the two happen to sit at.
static func _span_geo(mass: SurfaceTool, trim: SurfaceTool, tris: PackedVector3Array,
		length: float) -> void:
	_rbox(mass, tris, Vector3(length * 0.5, -DECK * 0.5, 0),
		Vector3(length, DECK, SPAN_W))
	for s in [-1.0, 1.0]:
		_rbox(trim, tris,
			Vector3(length * 0.5, KERB_H * 0.5, s * (SPAN_W * 0.5 - KERB_T * 0.5)),
			Vector3(length, KERB_H, KERB_T), F_ALL, 0.12)


static func build_span(length: float) -> StaticBody3D:
	var mass := SurfaceTool.new()
	var trim := SurfaceTool.new()
	mass.begin(Mesh.PRIMITIVE_TRIANGLES)
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := PackedVector3Array()
	_span_geo(mass, trim, tris, maxf(2.0, length))
	return _finish(mass, trim, tris, "wfcspan")
