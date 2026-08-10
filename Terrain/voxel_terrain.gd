extends Node3D

## Destructible voxel terrain for the Creative level.
##
## A scalar density field on a lattice (2 m spacing), meshed with naive
## SURFACE NETS — the dual-of-marching-cubes approach (one vertex per
## surface cell at the mean of its edge crossings, quads across sign-change
## lattice edges). Same family Astroneer uses: smooth, and editing is just
## "change density in a sphere, remesh the touched chunks". Normals come
## from the density gradient, so digging leaves smooth scoops.
##
## Geometry efficiency: the field is chunked; a brush edit only remeshes
## chunks whose lattice points changed. Each chunk is one ArrayMesh + one
## ConcavePolygonShape3D collider.

const VOXEL := 2.0                 # meters per lattice step
const NX := 64                     # cells along X  (world 128 m)
const NY := 12                     # cells along Y  (world 24 m: -8 .. +16)
const NZ := 64                     # cells along Z
const ORIGIN := Vector3(-64.0, -8.0, -64.0)
const ISO := 0.5
const CHUNK := 8                   # cells per chunk side (X/Z; Y is one chunk)

# Vertical layout: 4 m slabs. Bedrock [-8,-4] is implicit and uneditable;
# the 4 painted layers stack above it: ground [-4,0] (default solid, erased
# = pit), main [0,4], +1 [4,8], +2 [8,12]. A flat ground surface meshes out
# at y ~= 1.0 (density crossing + smoothing).
const SLAB := 4.0

# The world beyond the paintable 128x128 region: a flat unmodifiable plane
# level with the ground layer, so the map has no rim dropoff.
const FRAME_INNER := 60.0
const FRAME_OUTER := 512.0
const FRAME_TOP := 0.98            # a hair under the voxel floor's ~1.0
const FRAME_THICK := 9.0

# Lattice points are (NX+1) x (NY+1) x (NZ+1)
var _density := PackedFloat32Array()
var _chunks: Dictionary = {}       # Vector2i(cx,cz) -> {body, mesh_instance, shape}
var _material: StandardMaterial3D

# Cube edges: pairs of corner indices; corners are (x&1, y&1, z&1) bit order
const CORNER_OFFSETS := [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]
const EDGES := [
	[0, 1], [2, 3], [4, 5], [6, 7],   # X edges
	[0, 2], [1, 3], [4, 6], [5, 7],   # Y edges
	[0, 4], [1, 5], [2, 6], [3, 7],   # Z edges
]


func _ready() -> void:
	add_to_group("voxel_terrain")
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.78, 0.55, 0.38)  # canyon sandstone
	_material.roughness = 0.95
	_material.uv1_triplanar = true
	# Some quad windings come out flipped per axis; normals are from the
	# density gradient anyway, so render both sides instead of leaving cracks.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED


func _idx(x: int, y: int, z: int) -> int:
	return (y * (NZ + 1) + z) * (NX + 1) + x


func _d(x: int, y: int, z: int) -> float:
	if x < 0 or y < 0 or z < 0 or x > NX or y > NY or z > NZ:
		return 0.0
	return _density[_idx(x, y, z)]


## Build the field from the editor's layer stack: `layers` is 4 Arrays of 32
## ints (ground, main, +1, +2 — bottom to top), bit (31-col) = filled pixel.
## Each pixel is a 4x4 m column within its 4 m slab; bedrock fills [-8,-4]
## beneath everything regardless of paint.
func build_from_layers(layers: Array) -> void:
	_density.resize((NX + 1) * (NY + 1) * (NZ + 1))
	_density.fill(0.0)
	var points_per_pixel := int(4.0 / VOXEL)  # 2
	for y in NY + 1:
		# Lattice rows: 1-2 bedrock, 3-4 ground, 5-6 main, 7-8 (+1), 9-10 (+2)
		var bedrock := y >= 1 and y <= 2
		var li := ((y - 3) >> 1) if (y >= 3 and y <= 10) else -1
		if not bedrock and (li < 0 or li >= layers.size()):
			continue
		var rows: Array = layers[li] if li >= 0 else []
		for z in NZ + 1:
			var pz := clampi(z / points_per_pixel, 0, 31)
			for x in NX + 1:
				var px := clampi(x / points_per_pixel, 0, 31)
				var solid := bedrock
				if not solid and pz < rows.size():
					solid = (int(rows[pz]) >> (31 - px)) & 1
				if solid:
					_density[_idx(x, y, z)] = 1.0
	var t0 := Time.get_ticks_msec()
	_smooth_once()
	_seal_boundary()
	_build_frame()
	_remesh_all()
	var tris := 0
	for key in _chunks:
		var mi: MeshInstance3D = _chunks[key]["body"].get_child(0)
		tris += mi.mesh.surface_get_array_len(0) / 3
	print("[terrain] built %dx%dx%d field in %d ms — %d chunks, %d tris" % [
		NX, NY, NZ, Time.get_ticks_msec() - t0, _chunks.size(), tris])


## One 3x3x3 box blur pass: turns the binary field into chamfered slopes so
## surface nets produces bevels instead of razor voxel edges.
func _smooth_once() -> void:
	var src := _density.duplicate()
	for y in range(1, NY):
		for z in range(1, NZ):
			for x in range(1, NX):
				var acc := 0.0
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						for dx in range(-1, 2):
							acc += src[_idx(x + dx, y + dy, z + dz)]
				_density[_idx(x, y, z)] = acc / 27.0


## Outermost lattice shell forced empty: every solid region is watertight,
## so there are no open faces (or missing colliders) at the world rim.
func _seal_boundary() -> void:
	for y in NY + 1:
		for z in NZ + 1:
			for x in NX + 1:
				if x == 0 or y == 0 or z == 0 or x == NX or y == NY or z == NZ:
					_density[_idx(x, y, z)] = 0.0


# Lattice rows at or below this index are bedrock (world y <= -4) — brushes
# can't touch them, so pits bottom out on the bedrock plane instead of
# opening into the void.
const BEDROCK_Y := 2


## The flat plane surrounding the paintable region: 4 box segments forming a
## ring from FRAME_INNER to FRAME_OUTER, level with the ground layer. Built
## once; survives map rebuilds untouched.
var _frame_built := false

func _build_frame() -> void:
	if _frame_built:
		return
	_frame_built = true
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.51, 0.37)  # a shade darker than the field
	mat.roughness = 0.95
	var mid := (FRAME_INNER + FRAME_OUTER) / 2.0
	var run := FRAME_OUTER - FRAME_INNER
	var segs := [
		[-mid, 0.0, run, FRAME_OUTER * 2.0],
		[mid, 0.0, run, FRAME_OUTER * 2.0],
		[0.0, -mid, FRAME_INNER * 2.0, run],
		[0.0, mid, FRAME_INNER * 2.0, run],
	]
	for s in segs:
		var body := StaticBody3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(s[2], FRAME_THICK, s[3])
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = shape.size
		bm.material = mat
		mi.mesh = bm
		body.add_child(mi)
		body.position = Vector3(s[0], FRAME_TOP - FRAME_THICK / 2.0, s[1])
		add_child(body)

## Density at a world position (nearest lattice point) — used to detect a
## player embedded by a fill brush so they can be popped out upward.
func density_at(pos: Vector3) -> float:
	var g := (pos - ORIGIN) / VOXEL
	return _d(clampi(roundi(g.x), 0, NX), clampi(roundi(g.y), 0, NY), clampi(roundi(g.z), 0, NZ))


## Astroneer-style brush: add (sign +1) or carve (sign -1) a falloff sphere.
## `strength` scales the per-call amount so held-button strokes carve
## gradually instead of stamping. Returns true if anything changed.
func apply_brush(center: Vector3, radius: float, sign_: float, strength := 1.0) -> bool:
	var changed := false
	var lo := ((center - Vector3.ONE * radius) - ORIGIN) / VOXEL
	var hi := ((center + Vector3.ONE * radius) - ORIGIN) / VOXEL
	var dirty := {}
	for y in range(maxi(BEDROCK_Y + 1, floori(lo.y)), mini(NY - 1, ceili(hi.y)) + 1):
		for z in range(maxi(1, floori(lo.z)), mini(NZ - 1, ceili(hi.z)) + 1):
			for x in range(maxi(1, floori(lo.x)), mini(NX - 1, ceili(hi.x)) + 1):
				var p := ORIGIN + Vector3(x, y, z) * VOXEL
				var dist := p.distance_to(center)
				if dist >= radius:
					continue
				var falloff := 1.0 - dist / radius
				var i := _idx(x, y, z)
				var v := clampf(_density[i] + sign_ * falloff * strength, 0.0, 1.0)
				if not is_equal_approx(v, _density[i]):
					_density[i] = v
					changed = true
					# lattice point (x,z) touches cells x-1..x / z-1..z -> chunks
					var cz0 := clampi((z - 1) / CHUNK, 0, NZ / CHUNK - 1)
					var cz1 := clampi(z / CHUNK, 0, NZ / CHUNK - 1)
					var cx0 := clampi((x - 1) / CHUNK, 0, NX / CHUNK - 1)
					var cx1 := clampi(x / CHUNK, 0, NX / CHUNK - 1)
					for cz in range(cz0, cz1 + 1):
						for cx in range(cx0, cx1 + 1):
							dirty[Vector2i(cx, cz)] = true
	for key in dirty:
		_remesh_chunk(key)
	return changed


func _remesh_all() -> void:
	for cz in NZ / CHUNK:
		for cx in NX / CHUNK:
			_remesh_chunk(Vector2i(cx, cz))


## Surface-nets vertex for one cell: mean of its edge crossings (null if the
## cell has no sign change).
func _cell_vertex(cx: int, cy: int, cz: int, cache: Dictionary) -> Variant:
	var key := Vector3i(cx, cy, cz)
	if cache.has(key):
		return cache[key]
	var d := []
	d.resize(8)
	var mask := 0
	for i in 8:
		var o: Vector3i = CORNER_OFFSETS[i]
		var v := _d(cx + o.x, cy + o.y, cz + o.z)
		d[i] = v
		if v > ISO:
			mask |= 1 << i
	if mask == 0 or mask == 255:
		cache[key] = null
		return null
	var acc := Vector3.ZERO
	var n := 0
	for e in EDGES:
		var a: int = e[0]
		var b: int = e[1]
		var da: float = d[a]
		var db: float = d[b]
		if (da > ISO) == (db > ISO):
			continue
		var t := (ISO - da) / (db - da)
		var pa := Vector3(CORNER_OFFSETS[a])
		var pb := Vector3(CORNER_OFFSETS[b])
		acc += pa.lerp(pb, t)
		n += 1
	var vert: Vector3 = ORIGIN + (Vector3(cx, cy, cz) + acc / n) * VOXEL
	cache[key] = vert
	return vert


func _gradient(p: Vector3) -> Vector3:
	var g := (p - ORIGIN) / VOXEL
	var x := clampi(roundi(g.x), 1, NX - 1)
	var y := clampi(roundi(g.y), 1, NY - 1)
	var z := clampi(roundi(g.z), 1, NZ - 1)
	var n := Vector3(
		_d(x - 1, y, z) - _d(x + 1, y, z),
		_d(x, y - 1, z) - _d(x, y + 1, z),
		_d(x, y, z - 1) - _d(x, y, z + 1),
	)
	return n.normalized() if n.length() > 0.0001 else Vector3.UP


func _remesh_chunk(key: Vector2i) -> void:
	var x0 := key.x * CHUNK
	var z0 := key.y * CHUNK
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var cache := {}

	# For every lattice edge owned by this chunk (base point inside the cell
	# range), a sign change emits a quad between the 4 cells around the edge.
	for y in range(0, NY + 1):
		for z in range(z0, z0 + CHUNK):
			for x in range(x0, x0 + CHUNK):
				var d0 := _d(x, y, z)
				var s0 := d0 > ISO
				# X-, Y-, Z-directed edges from this point
				for axis in 3:
					var bx := x + (1 if axis == 0 else 0)
					var by := y + (1 if axis == 1 else 0)
					var bz := z + (1 if axis == 2 else 0)
					if bx > NX or by > NY or bz > NZ:
						continue
					var s1 := _d(bx, by, bz) > ISO
					if s0 == s1:
						continue
					var quad := _edge_cells(x, y, z, axis)
					if quad.is_empty():
						continue
					var vs := []
					var ok := true
					for c in quad:
						var v: Variant = _cell_vertex(c.x, c.y, c.z, cache)
						if v == null:
							ok = false
							break
						vs.append(v)
					if not ok:
						continue
					if s0:  # solid at base -> flip winding so the face looks outward
						vs.reverse()
					for tri in [[0, 1, 2], [0, 2, 3]]:
						for i in tri:
							verts.append(vs[i])
							normals.append(_gradient(vs[i]))

	# Swap in the rebuilt chunk
	if _chunks.has(key):
		_chunks[key]["body"].queue_free()
		_chunks.erase(key)
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	shape.backface_collision = true  # concave shapes are one-sided by default
	col.shape = shape
	body.add_child(col)
	add_child(body)
	_chunks[key] = {"body": body}


## The 4 cells sharing the lattice edge starting at (x,y,z) along `axis`,
## wound as a loop. Empty if any cell is outside the grid.
func _edge_cells(x: int, y: int, z: int, axis: int) -> Array:
	var cells: Array = []
	match axis:
		0:  # X edge: cells vary in y-1..y, z-1..z
			cells = [Vector3i(x, y - 1, z - 1), Vector3i(x, y, z - 1), Vector3i(x, y, z), Vector3i(x, y - 1, z)]
		1:  # Y edge: cells vary in x-1..x, z-1..z (loop order flipped for winding)
			cells = [Vector3i(x - 1, y, z - 1), Vector3i(x - 1, y, z), Vector3i(x, y, z), Vector3i(x, y, z - 1)]
		2:  # Z edge: cells vary in x-1..x, y-1..y
			cells = [Vector3i(x - 1, y - 1, z), Vector3i(x, y - 1, z), Vector3i(x, y, z), Vector3i(x - 1, y, z)]
	for c in cells:
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= NX or c.y >= NY or c.z >= NZ:
			return []
	return cells
