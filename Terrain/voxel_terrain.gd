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
const NY := 12                     # cells along Y  (world 24 m: -4 .. +20)
const NZ := 64                     # cells along Z
const ORIGIN := Vector3(-64.0, -4.0, -64.0)
const ISO := 0.5
const CHUNK := 8                   # cells per chunk side (X/Z; Y is one chunk)

const WALL_TOP_Y := 16.0           # extruded pixel-wall height
const FLOOR_TOP_Y := 0.0           # canyon floor level

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


## Build the field from the editor's pixel grid: `rows` is an Array of ints,
## bit (31-col) set = wall pixel. Each pixel is a 4x4 m column; walls rise to
## WALL_TOP_Y, everything sits on a floor slab from ORIGIN.y to FLOOR_TOP_Y.
func build_from_pixels(rows: Array) -> void:
	_density.resize((NX + 1) * (NY + 1) * (NZ + 1))
	_density.fill(0.0)
	var points_per_pixel := int(4.0 / VOXEL)  # 2
	for y in NY + 1:
		var wy := ORIGIN.y + y * VOXEL
		for z in NZ + 1:
			var pz := clampi(z / points_per_pixel, 0, 31)
			for x in NX + 1:
				var px := clampi(x / points_per_pixel, 0, 31)
				var solid := wy <= FLOOR_TOP_Y
				if not solid and wy <= WALL_TOP_Y and pz < rows.size():
					solid = (int(rows[pz]) >> (31 - px)) & 1
				if solid:
					_density[_idx(x, y, z)] = 1.0
	var t0 := Time.get_ticks_msec()
	_smooth_once()
	_seal_boundary()
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


# Lattice rows at or below this index are bedrock — brushes can't touch them,
# so you can dig trenches into the floor but never through it into the void.
const BEDROCK_Y := 2  # world y = 0 (the canyon floor's top)

## Astroneer-style brush: add (sign +1) or carve (sign -1) a falloff sphere.
## `strength` scales the per-call amount so held-button strokes carve
## gradually instead of stamping. Returns true if anything changed.
func apply_brush(center: Vector3, radius: float, sign_: float, strength := 1.0) -> bool:
	var changed := false
	var lo := ((center - Vector3.ONE * radius) - ORIGIN) / VOXEL
	var hi := ((center + Vector3.ONE * radius) - ORIGIN) / VOXEL
	var dirty := {}
	for y in range(maxi(BEDROCK_Y, floori(lo.y)), mini(NY - 1, ceili(hi.y)) + 1):
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
