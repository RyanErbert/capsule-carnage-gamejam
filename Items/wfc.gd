extends RefCounted

## Wave function collapse structures for the build drone.
##
## A tileset of terraced industrial modules — decks, railed edges, balconies
## and stairs — collapsed onto a square grid and meshed into one static body.
## The tileset is deliberately marble-friendly: a deck face only ever mates
## with another deck face AT THE SAME HEIGHT, so two neighbouring walkable
## cells are either level with each other or joined by a flight of stairs.
## There are no unannounced drops and no steps a rolling player can't take.
##
## Everything is a pure function of (seed, size): the client that places one
## sends nothing but the seed, and every other client collapses the identical
## structure locally. No per-tile sync, no mesh over the wire.

const CELL := 6.0        # meters per tile footprint
const LEVEL := 3.0       # meters per height step (one flight of stairs)
const LEVELS := 4        # floor heights 0..3
const SKIRT := 1.2       # how far the mass sinks below the placement plane
const RAIL_H := 1.1
const RAIL_T := 0.22

# Socket alphabet. A face is either a walkable floor edge at a known height
# (only mates with the same height), or it's "soft" — open air or a railing,
# which mate with each other freely.
const AIR := 0

# Module kinds, in the order the tileset is generated.
const K_VOID := "void"
const K_DECK := "deck"
const K_EDGE := "edge"      # railing on one face
const K_CORNER := "corner"  # railings on two adjacent faces
const K_CAP := "cap"        # railings on three: a dead-end balcony
const K_STAIR := "stair"    # h to h+1, railed down both sides
const K_MASS := "mass"      # a blank block: massing, not floor

static var _modules: Array = []


static func _solid(h: int) -> int:
	return 1 + h


static func _rail(h: int) -> int:
	return 10 + h


## A blank wall face. Soft like a railing as far as fitting goes — it will sit
## against air, a railing, or another wall — but it never opens onto a floor,
## so a mass block can't be mistaken for somewhere you can walk.
static func _wall(h: int) -> int:
	return 20 + h


static func _is_solid(s: int) -> bool:
	return s >= 1 and s <= LEVELS


## Two facing sockets fit if a floor meets the same floor, or if neither is a
## floor at all (air against air, railing against railing, either against the
## other). A floor never opens onto nothing.
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


## The tileset, built once. Lower floors are weighted heavier so structures
## sprawl before they tower.
static func modules() -> Array:
	if not _modules.is_empty():
		return _modules
	var out: Array = []
	# Void is what fragments a structure — too much of it and the collapse is a
	# scatter of disconnected plates that the island prune then eats.
	out.append({"kind": K_VOID, "h": 0, "rot": 0, "sk": [AIR, AIR, AIR, AIR], "w": 1.3})
	for h in LEVELS:
		var s := _solid(h)
		var r := _rail(h)
		var drop := 1.0 / (1.0 + h * 0.45)
		out.append({"kind": K_DECK, "h": h, "rot": 0, "sk": [s, s, s, s], "w": 3.0 * drop})
		for rot in 4:
			out.append({"kind": K_EDGE, "h": h, "rot": rot,
				"sk": _rotated([r, s, s, s], rot), "w": 2.0 * drop})
			out.append({"kind": K_CORNER, "h": h, "rot": rot,
				"sk": _rotated([r, r, s, s], rot), "w": 1.3 * drop})
			out.append({"kind": K_CAP, "h": h, "rot": rot,
				"sk": _rotated([r, r, s, r], rot), "w": 0.55 * drop})
		# Blank massing. Without it every gap in the walkable network is a hole
		# straight through to the sky; with it the gaps read as the plant the
		# walkways are threaded through.
		if h > 0:
			var wl := _wall(h)
			out.append({"kind": K_MASS, "h": h, "rot": 0,
				"sk": [wl, wl, wl, wl], "w": 2.2 * drop})
		# Stairs climb from this floor onto the next: the low end is a floor
		# edge at h, the high end a floor edge at h+1, the flanks are railed.
		if h < LEVELS - 1:
			for rot in 4:
				out.append({"kind": K_STAIR, "h": h, "rot": rot,
					"sk": _rotated([_solid(h + 1), r, s, r], rot), "w": 2.8 * drop})
	_modules = out
	return _modules


# --- Solver -----------------------------------------------------------------

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Collapse a `size` x `size` grid. Returns a flat Array of module indices
## (row-major, -1 never appears — failures fall back to void).
static func solve(seed_value: int, size: int) -> Array:
	var mods := modules()
	var m := mods.size()
	var rng := RandomNumberGenerator.new()
	for attempt in 14:
		rng.seed = seed_value + attempt * 7919
		var wave: Array = []
		for i in size * size:
			var opts := PackedByteArray()
			opts.resize(m)
			opts.fill(1)
			wave.append(opts)
		# Outside the grid is open air, so a boundary cell can't present a
		# floor edge outward — the structure always closes itself off.
		var stack: Array = []
		for r in size:
			for c in size:
				var i := r * size + c
				for d in 4:
					var n := Vector2i(c, r) + DIRS[d]
					if n.x >= 0 and n.y >= 0 and n.x < size and n.y < size:
						continue
					for k in m:
						if wave[i][k] == 1 and _is_solid(mods[k]["sk"][d]):
							wave[i][k] = 0
				stack.append(i)
		if not _propagate(wave, stack, size, mods):
			continue
		var ok := true
		while true:
			var pick := _lowest_entropy(wave, mods, rng)
			if pick < 0:
				break
			if not _collapse(wave, pick, mods, rng):
				ok = false
				break
			if not _propagate(wave, [pick], size, mods):
				ok = false
				break
		if not ok:
			continue
		var grid: Array = []
		for i in size * size:
			grid.append(_only(wave[i]))
		_prune_islands(grid, size, mods)
		return grid
	var fallback: Array = []
	fallback.resize(size * size)
	fallback.fill(0)   # all void: better an empty pad than a broken one
	return fallback


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
static func _lowest_entropy(wave: Array, mods: Array, rng: RandomNumberGenerator) -> int:
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


static func _collapse(wave: Array, i: int, mods: Array, rng: RandomNumberGenerator) -> bool:
	var opts: PackedByteArray = wave[i]
	var total := 0.0
	for k in opts.size():
		if opts[k] == 1:
			total += float(mods[k]["w"])
	if total <= 0.0:
		return false
	var roll := rng.randf() * total
	var chosen := -1
	for k in opts.size():
		if opts[k] == 0:
			continue
		roll -= float(mods[k]["w"])
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
static func _propagate(wave: Array, stack: Array, size: int, mods: Array) -> bool:
	var work: Array = stack.duplicate()
	while not work.is_empty():
		var i: int = work.pop_back()
		var here := Vector2i(i % size, i / size)
		for d in 4:
			var n: Vector2i = here + DIRS[d]
			if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
				continue
			var ni: int = n.y * size + n.x
			var opp := (d + 2) % 4
			var changed := false
			for k in mods.size():
				if wave[ni][k] == 0:
					continue
				var want: int = mods[k]["sk"][opp]
				var fits := false
				for j in mods.size():
					if wave[i][j] == 1 and compatible(mods[j]["sk"][d], want):
						fits = true
						break
				if not fits:
					wave[ni][k] = 0
					changed = true
			if not changed:
				continue
			if _count(wave[ni]) == 0:
				return false
			work.append(ni)
	return true


## Anything a marble can't roll to gets removed. Walkable cells connect only
## through faces where BOTH sides are floor edges, so this is exactly the
## reachable set; the largest component survives and the rest becomes void.
static func _prune_islands(grid: Array, size: int, mods: Array) -> void:
	var seen := PackedInt32Array()
	seen.resize(size * size)
	seen.fill(-1)
	var groups: Array = []
	for start in grid.size():
		var kind := str(mods[grid[start]]["kind"])
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
				if not _is_solid(mods[grid[i]]["sk"][d]):
					continue
				if not _is_solid(mods[grid[ni]]["sk"][(d + 2) % 4]):
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

## Build the whole structure: grey mass, yellow rails and pipes, green pads,
## and one concave collider over the lot. Origin is the center of the pad,
## with floor level 0 at y = 0.
static func build(seed_value: int, size: int) -> StaticBody3D:
	var mods := modules()
	var grid := solve(seed_value, size)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x5f3a91

	var mass := SurfaceTool.new()
	var trim := SurfaceTool.new()
	var pads := SurfaceTool.new()
	mass.begin(Mesh.PRIMITIVE_TRIANGLES)
	trim.begin(Mesh.PRIMITIVE_TRIANGLES)
	pads.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := PackedVector3Array()

	# How tall each cell's mass stands, so a face only gets drawn where there's
	# actually air on the other side of it.
	var mass_top := PackedFloat32Array()
	mass_top.resize(size * size)
	for i in grid.size():
		var mod: Dictionary = mods[grid[i]]
		mass_top[i] = BURIED if str(mod["kind"]) == K_VOID else int(mod["h"]) * LEVEL

	var half := size * CELL * 0.5
	for r in size:
		for c in size:
			var mod: Dictionary = mods[grid[r * size + c]]
			if str(mod["kind"]) == K_VOID:
				continue
			var at := Vector3(-half + c * CELL + CELL * 0.5, 0.0, -half + r * CELL + CELL * 0.5)
			var h: int = mod["h"]
			var top := h * LEVEL
			var walls := _wall_mask(mass_top, size, r, c)
			if str(mod["kind"]) == K_STAIR:
				_stair(mass, tris, at, top, int(mod["rot"]), walls)
			elif str(mod["kind"]) == K_MASS:
				# Blank block: mass and a roof, no railings and no pads — the
				# grey the walkways are strung through.
				_box(mass, tris, at + Vector3(0, (top - SKIRT) * 0.5, 0),
					Vector3(CELL, top + SKIRT, CELL), walls | (1 << F_TOP))
				continue
			else:
				_box(mass, tris, at + Vector3(0, (top - SKIRT) * 0.5, 0),
					Vector3(CELL, top + SKIRT, CELL), walls | (1 << F_TOP))
				# A green service pad now and then, and the odd overhead pipe:
				# the two bits of colour the grey needs to read as a machine.
				if rng.randf() < 0.16:
					_pad(pads, at + Vector3(0, top + 0.03, 0))
				elif rng.randf() < 0.18:
					_pipe(trim, tris, at, top, rng.randi() % 2)
			# Railings on every soft face — except along the outside of the
			# ground floor, which is how a marble gets in.
			for d in 4:
				if _is_solid(mod["sk"][d]):
					continue
				var edge := Vector2i(c, r) + DIRS[d]
				var outside := edge.x < 0 or edge.y < 0 or edge.x >= size or edge.y >= size
				if outside and h == 0:
					continue
				_rail_seg(trim, tris, at, top, d)

	var body := StaticBody3D.new()
	body.set_meta("build_type", "wfc")
	body.add_child(_surface(mass, _mat(Color(0.52, 0.54, 0.57), 0.25, 0.7)))
	body.add_child(_surface(trim, _mat(Color(0.95, 0.72, 0.12), 0.35, 0.45)))
	var pad_mat := _mat(Color(0.35, 0.95, 0.5), 0.0, 0.5)
	pad_mat.emission_enabled = true
	pad_mat.emission = Color(0.3, 1.0, 0.45)
	pad_mat.emission_energy_multiplier = 1.4
	body.add_child(_surface(pads, pad_mat))
	if not tris.is_empty():
		var col := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(tris)
		col.shape = shape
		body.add_child(col)
	return body


static func _mat(albedo: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.metallic = metallic
	mat.roughness = roughness
	return mat


static func _surface(st: SurfaceTool, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi


# Box faces in the order _box() emits them, and where each direction lands in
# that order. Buried faces are skipped rather than drawn: two solids meeting
# flush would otherwise put two coplanar surfaces at the same depth, and the
# z-fighting reads as diagonal stripes across every terrace.
const FACES := [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4],
	[2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
# Normals go on explicitly, per face. SurfaceTool.generate_normals() averages
# across shared positions, and a box's corners are shared by three faces, so
# generated normals point off into the corner and the flat tops read unlit.
const FACE_N := [Vector3.BACK * -1.0, Vector3.BACK, Vector3.DOWN,
	Vector3.UP, Vector3.LEFT, Vector3.RIGHT]
const DIR_FACE := [0, 5, 1, 4]   # N, E, S, W
const F_TOP := 3
const F_ALL := 63
const BURIED := -1.0e9           # "mass top" of a cell with nothing in it


## An axis-aligned box, added to both the render surface and the collider.
## `mask` selects which of the six faces to emit (bit per FACES entry).
static func _box(st: SurfaceTool, tris: PackedVector3Array, at: Vector3, size: Vector3,
		mask := F_ALL) -> void:
	var e := size * 0.5
	var v: Array = []
	for i in 8:
		v.append(at + Vector3(
			e.x if (i & 1) else -e.x, e.y if (i & 2) else -e.y, e.z if (i & 4) else -e.z))
	for fi in FACES.size():
		if not (mask & (1 << fi)):
			continue
		var face: Array = FACES[fi]
		st.set_normal(FACE_N[fi])
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for k in tri:
				st.add_vertex(v[face[k]])
				tris.append(v[face[k]])


## Which of a cell's four walls face open air. A neighbour standing as tall as
## us (or taller) buries the seam, so neither side draws it.
static func _wall_mask(mass_top: PackedFloat32Array, size: int, r: int, c: int) -> int:
	var mine := mass_top[r * size + c]
	var mask := 0
	for d in 4:
		var n := Vector2i(c, r) + DIRS[d]
		var theirs := BURIED
		if n.x >= 0 and n.y >= 0 and n.x < size and n.y < size:
			theirs = mass_top[n.y * size + n.x]
		if theirs < mine:
			mask |= 1 << int(DIR_FACE[d])
	return mask


## A flight climbing from `top` to `top + LEVEL` in the direction `rot` faces,
## cut as discrete steps so it reads as stairs and a marble can take it.
##
## Each tread is a full-depth slab rising off the cell floor, so consecutive
## steps nest inside one another: only the tread and the riser are ever drawn,
## and the buried faces between them never get the chance to z-fight.
static func _stair(st: SurfaceTool, tris: PackedVector3Array, at: Vector3, top: float,
		rot: int, walls: int) -> void:
	_box(st, tris, at + Vector3(0, (top - SKIRT) * 0.5, 0), Vector3(CELL, top + SKIRT, CELL), walls)
	var steps := 6
	var fwd: Vector3 = Vector3(DIRS[rot].x, 0, DIRS[rot].y)
	var depth := CELL / float(steps)
	var sides: int = walls & ~(1 << int(DIR_FACE[rot])) & ~(1 << int(DIR_FACE[(rot + 2) % 4]))
	var low_face: int = 1 << int(DIR_FACE[(rot + 2) % 4])
	for i in steps:
		var rise := LEVEL * (i + 1) / float(steps)
		# Step i sits `i` slots back from the low end, which is the face
		# OPPOSITE the direction this module climbs toward.
		var along := -fwd * (CELL * 0.5 - depth * (i + 0.5))
		# Tread on top, riser toward the low end, plus whichever flanks are
		# open. The high-end face is always buried in the next step.
		_box(st, tris, at + along + Vector3(0, top + rise * 0.5, 0),
			Vector3(depth, rise, CELL) if absf(fwd.x) > 0.5 else Vector3(CELL, rise, depth),
			(1 << F_TOP) | low_face | sides)


## Guard rail along one face of a cell: a top bar on two posts.
static func _rail_seg(st: SurfaceTool, tris: PackedVector3Array, at: Vector3, top: float, d: int) -> void:
	var n := Vector3(DIRS[d].x, 0, DIRS[d].y)
	var along := Vector3(-n.z, 0.0, n.x)
	var base := at + n * (CELL * 0.5 - RAIL_T * 0.5) + Vector3(0, top, 0)
	var bar_size := Vector3(CELL, RAIL_T, RAIL_T) if absf(n.z) > 0.5 else Vector3(RAIL_T, RAIL_T, CELL)
	_box(st, tris, base + Vector3(0, RAIL_H, 0), bar_size)
	for s in [-1.0, 1.0]:
		_box(st, tris, base + along * (s * (CELL * 0.5 - RAIL_T)) + Vector3(0, RAIL_H * 0.5, 0),
			Vector3(RAIL_T, RAIL_H, RAIL_T))


## An overhead service pipe crossing the cell on two stubby legs.
static func _pipe(st: SurfaceTool, tris: PackedVector3Array, at: Vector3, top: float, axis: int) -> void:
	var run := Vector3(CELL, 0.42, 0.42) if axis == 0 else Vector3(0.42, 0.42, CELL)
	var y := top + 2.1
	_box(st, tris, at + Vector3(0, y, 0), run)
	var along := Vector3(1, 0, 0) if axis == 0 else Vector3(0, 0, 1)
	for s in [-1.0, 1.0]:
		_box(st, tris, at + along * (s * CELL * 0.32) + Vector3(0, top + (y - top) * 0.5, 0),
			Vector3(0.26, y - top, 0.26))


static func _pad(st: SurfaceTool, at: Vector3) -> void:
	var e := CELL * 0.28
	st.set_normal(Vector3.UP)
	for tri in [[Vector3(-e, 0, -e), Vector3(e, 0, -e), Vector3(e, 0, e)],
			[Vector3(-e, 0, -e), Vector3(e, 0, e), Vector3(-e, 0, e)]]:
		for v in tri:
			st.add_vertex(at + v)
