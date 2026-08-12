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
const NY := 24                     # cells along Y  (world 48 m: -20 .. +28)
const ISO := 0.5
const CHUNK := 8                   # cells per chunk side (X/Z; Y is one chunk)

# Horizontal extent follows the painted grid (configure(w, h)): pixels are
# 4 m = 2 lattice cells each, plus the bowl margin per side. NX/NZ stay
# divisible by CHUNK as long as the pixel counts are multiples of 4.
var PX_W := 32                     # painted pixels across X
var PX_H := 32                     # painted pixels across Z
var NX := 80                       # cells along X  (world 160 m incl. the bowl)
var NZ := 80                       # cells along Z
var ORIGIN := Vector3(-80.0, -20.0, -80.0)
var FRAME_INNER_X := 78.0          # butts against the bowl's outer shelf
var FRAME_INNER_Z := 78.0

# Uneditable BOWL around the painted region: MARGIN cells (16 m) per side
# whose ground ramps from the adjacent edge pixel's height to ground level —
# pits at the rim rise from their own floor instead of opening into the
# void, flat ground gets a seamless apron. Brushes may sculpt the inner
# BRUSH_REACH cells of it; the rest is world boundary and stays locked.
const MARGIN := 8
const BRUSH_REACH := 3

# Vertical layout: 8 m slabs (tall extrusion). Bedrock [-20,-16] is implicit
# and uneditable; the 5 painted layers stack above it: basement [-16,-8]
# (default solid, erase it for cellars and canyon floors), ground [-8,0]
# (default solid, erased = a drop into the basement), main [0,8], +1 [8,16],
# +2 [16,24]. A flat ground surface meshes out at y ~= 1.0 (crossing +
# smoothing), unchanged by the basement going in underneath it.
const SLAB := 8.0

# The world beyond the paintable region: a flat unmodifiable CIRCULAR plain
# level with the ground layer, so the map has no rim dropoff. The fog
# boundary (creative.gd) turns players around long before the edge.
const STAGE_RADIUS := 640.0        # outer edge of the circular plain
const FRAME_TOP := 0.48            # a hair under the bowl apron's ~0.5 surface
const FRAME_SEGMENTS := 128

# Lattice points are (NX+1) x (NY+1) x (NZ+1)
var _density := PackedFloat32Array()
var _chunks: Dictionary = {}       # Vector2i(cx,cz) -> {body, mesh_instance, shape}
var _material: ShaderMaterial

# Triplanar sand/rock shader over real tiled textures (CC0, Poly Haven:
# sand_01 + rock_face), slope-blended, with per-vertex cavity AO baked into
# COLOR.r during meshing and a low-frequency noise tint that breaks up
# texture tiling — dug/filled ground reads as 3D instead of flat orange.
const TERRAIN_SHADER := "
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
varying vec3 wpos;
varying vec3 wnrm;
varying float vao;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vao = COLOR.r;
}
vec3 triplanar(sampler2D tex, vec3 p, vec3 w, float s) {
	return texture(tex, p.zy * s).rgb * w.x
	     + texture(tex, p.xz * s).rgb * w.y
	     + texture(tex, p.xy * s).rgb * w.z;
}
void fragment() {
	// Projection weights from the actual polygon (screen-space derivatives),
	// not the density-gradient normal: on thin spires the gradient goes bad
	// and picks a grazing projection plane, smearing the texture.
	vec3 gnrm = normalize(cross(dFdx(wpos), dFdy(wpos)));
	vec3 w = abs(gnrm);
	w = pow(w, vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 sand = triplanar(sand_tex, wpos, w, 0.09) * vec3(1.12, 0.98, 0.82);
	vec3 rock = triplanar(rock_tex, wpos, w, 0.06) * vec3(1.05, 0.95, 0.88);
	float slope = clamp(1.0 - wnrm.y, 0.0, 1.0);
	vec3 col = mix(sand, rock, smoothstep(0.25, 0.6, slope));
	// large-scale tint variation so the tiling never reads as a grid
	float n2 = texture(noise_tex, wpos.xz * 0.007).r;
	col *= 0.88 + 0.24 * n2;
	col *= vao;
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
}
"

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
	# Some quad windings come out flipped per axis; normals are from the
	# density gradient anyway, so the shader renders both sides (cull_disabled)
	# instead of leaving cracks.
	var shader := Shader.new()
	shader.code = TERRAIN_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.03
	noise.fractal_octaves = 4
	var ntex := NoiseTexture2D.new()
	ntex.noise = noise
	ntex.seamless = true
	ntex.width = 256
	ntex.height = 256
	_material.set_shader_parameter("noise_tex", ntex)
	_material.set_shader_parameter("sand_tex", load("res://Terrain/textures/sand.jpg"))
	_material.set_shader_parameter("rock_tex", load("res://Terrain/textures/rock.jpg"))


## Size the lattice to a painted grid of `w` x `h` pixels. Call before
## build_from_layers; a size change throws away every chunk and the frame.
func configure(w: int, h: int) -> void:
	if w == PX_W and h == PX_H and not _chunks.is_empty():
		return
	PX_W = w
	PX_H = h
	NX = w * 2 + 2 * MARGIN
	NZ = h * 2 + 2 * MARGIN
	var half_x := float(w * 2) + MARGIN * VOXEL
	var half_z := float(h * 2) + MARGIN * VOXEL
	ORIGIN = Vector3(-half_x, -20.0, -half_z)
	FRAME_INNER_X = half_x - 2.0
	FRAME_INNER_Z = half_z - 2.0
	for key in _chunks:
		_chunks[key]["body"].queue_free()
	_chunks.clear()
	if _frame_body and is_instance_valid(_frame_body):
		_frame_body.queue_free()
	_frame_body = null
	_frame_built = false


## Half-extents of the painted (brushable) region in meters — world queries
## like the grass scatter size themselves off these.
func paint_half_x() -> float:
	return PX_W * 2.0


func paint_half_z() -> float:
	return PX_H * 2.0


func _idx(x: int, y: int, z: int) -> int:
	return (y * (NZ + 1) + z) * (NX + 1) + x


func _d(x: int, y: int, z: int) -> float:
	if x < 0 or y < 0 or z < 0 or x > NX or y > NY or z > NZ:
		return 0.0
	return _density[_idx(x, y, z)]


## Build the field from the editor's layer stack: `layers` is 4 flat Arrays
## of PX rows x (PX+31)/32 uint32 words (ground, main, +1, +2 — bottom to
## top), bit (31 - col&31) = filled pixel. Each pixel is a 4x4 m column
## within its 8 m slab; bedrock fills [-20,-16] beneath everything regardless
## of paint. What's painted is what you get, floating slabs included — SPIRE
## MODE in the painter fills the columns underneath at paint time instead
## (creative.gd), so the canvas never lies.
func build_from_layers(layers: Array) -> void:
	var eff: Array = layers
	_density.resize((NX + 1) * (NY + 1) * (NZ + 1))
	_density.fill(0.0)
	var points_per_pixel := int(4.0 / VOXEL)  # 2
	var w := (PX_W + 31) >> 5   # bitmask words per pixel row
	# Bowl heights around the rim: per edge pixel, the topmost solid row
	var bowl_top := _bowl_tops(eff)
	for y in NY + 1:
		# Lattice rows: 1-2 bedrock, then 4 rows per slab: 3-6 basement,
		# 7-10 ground, 11-14 main, 15-18 (+1), 19-22 (+2); 23-24 air for the seal.
		var bedrock := y >= 1 and y <= 2
		var li := ((y - 3) >> 2) if (y >= 3 and y <= 22) else -1
		for z in NZ + 1:
			var dz := maxi(MARGIN - z, z - (NZ - MARGIN))
			var pz := clampi((z - MARGIN) / points_per_pixel, 0, PX_H - 1)
			for x in NX + 1:
				var dx := maxi(MARGIN - x, x - (NX - MARGIN))
				var d := maxi(dx, dz)
				var solid := bedrock
				if d > 0:
					# Bowl band: solid up to a row that blends from the edge
					# pixel's own top toward ground level (row 6) outward.
					if not solid and y >= 1:
						var px_e := clampi((x - MARGIN) / points_per_pixel, 0, PX_W - 1)
						var top: int = bowl_top[pz * PX_W + px_e]
						var band := roundi(lerpf(float(top), 10.0, clampf(d / float(MARGIN), 0.0, 1.0)))
						solid = y <= band
				elif not solid and li >= 0 and li < eff.size():
					var rows: Array = eff[li]
					var px := clampi((x - MARGIN) / points_per_pixel, 0, PX_W - 1)
					var wi := pz * w + (px >> 5)
					if wi < rows.size():
						solid = (int(rows[wi]) >> (31 - (px & 31))) & 1
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


## Topmost solid lattice row per pixel (bedrock top 2 if fully erased) — the
## bowl ramps outward from these, so a rim pit rises from its own floor.
func _bowl_tops(eff: Array) -> PackedInt32Array:
	var w := (PX_W + 31) >> 5
	var tops := PackedInt32Array()
	tops.resize(PX_W * PX_H)
	tops.fill(BEDROCK_Y)
	for li in range(mini(4, eff.size()) - 1, -1, -1):
		var rows: Array = eff[li]
		for pz in PX_H:
			for px in PX_W:
				var wi := pz * w + (px >> 5)
				if wi >= rows.size():
					continue
				if tops[pz * PX_W + px] == BEDROCK_Y and (int(rows[wi]) >> (31 - (px & 31))) & 1:
					tops[pz * PX_W + px] = 6 + li * 4
	return tops


## One 3x3x3 box blur pass, run SEPARABLY (three 3-tap passes): identical
## chamfered slopes, but 9 reads per point instead of 27 — the difference
## between seconds and half a minute on the big grid sizes.
func _smooth_once() -> void:
	var src := _density.duplicate()
	for y in range(1, NY):
		for z in range(1, NZ):
			for x in range(1, NX):
				var i := _idx(x, y, z)
				_density[i] = (src[i - 1] + src[i] + src[i + 1]) / 3.0
	src = _density.duplicate()
	var zstride := NX + 1
	for y in range(1, NY):
		for z in range(1, NZ):
			for x in range(1, NX):
				var i := _idx(x, y, z)
				_density[i] = (src[i - zstride] + src[i] + src[i + zstride]) / 3.0
	src = _density.duplicate()
	var ystride := (NZ + 1) * (NX + 1)
	for y in range(1, NY):
		for z in range(1, NZ):
			for x in range(1, NX):
				var i := _idx(x, y, z)
				_density[i] = (src[i - ystride] + src[i] + src[i + ystride]) / 3.0


## Outermost lattice shell forced empty: every solid region is watertight,
## so there are no open faces (or missing colliders) at the world rim.
func _seal_boundary() -> void:
	for y in NY + 1:
		for z in NZ + 1:
			for x in NX + 1:
				if x == 0 or y == 0 or z == 0 or x == NX or y == NY or z == NZ:
					_density[_idx(x, y, z)] = 0.0


# Lattice rows at or below this index are bedrock (world y <= -8) — brushes
# can't touch them, so pits bottom out on the bedrock plane instead of
# opening into the void.
const BEDROCK_Y := 2


## The flat plain surrounding the paintable region: an annulus mesh with a
## square inner hole (hugging the voxel region) and a circular outer edge.
## Built once per size; survives same-size map rebuilds untouched.
var _frame_built := false
var _frame_body: StaticBody3D

## Point on the square inner perimeter in the direction of angle `a`.
func _square_point(a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	# Rectangle, not square: whichever axis the ray leaves through wins
	var t := minf(FRAME_INNER_X / maxf(absf(c), 0.0001), FRAME_INNER_Z / maxf(absf(s), 0.0001))
	return Vector3(c * t, FRAME_TOP, s * t)


func _build_frame() -> void:
	if _frame_built:
		return
	_frame_built = true
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for i in FRAME_SEGMENTS:
		var a0 := TAU * i / FRAME_SEGMENTS
		var a1 := TAU * (i + 1) / FRAME_SEGMENTS
		var in0 := _square_point(a0)
		var in1 := _square_point(a1)
		var out0 := Vector3(cos(a0) * STAGE_RADIUS, FRAME_TOP, sin(a0) * STAGE_RADIUS)
		var out1 := Vector3(cos(a1) * STAGE_RADIUS, FRAME_TOP, sin(a1) * STAGE_RADIUS)
		for v in [in0, out0, out1, in0, out1, in1]:
			verts.append(v)
			normals.append(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)  # same sand shader as the field
	var body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	shape.backface_collision = true
	col.shape = shape
	body.add_child(col)
	add_child(body)
	_frame_body = body

## Density at a world position (nearest lattice point) — used to detect a
## player embedded by a fill brush so they can be popped out upward.
func density_at(pos: Vector3) -> float:
	var g := (pos - ORIGIN) / VOXEL
	return _d(clampi(roundi(g.x), 0, NX), clampi(roundi(g.y), 0, NY), clampi(roundi(g.z), 0, NZ))


## Each spawn base sits in a protected square (creative.gd sets the centres
## from the claimed pixels): no brush may reach into one, so a base can't be
## dug out from under or buried. Mirrors the server's check.
var deadzone_centers: Array = [Vector3(2, 0, 2)]
const DEADZONE_R := 10.0

func in_deadzone(center: Vector3, radius := 0.0) -> bool:
	for h in deadzone_centers:
		if maxf(absf(center.x - h.x), absf(center.z - h.z)) <= DEADZONE_R + radius:
			return true
	return false


## Astroneer-style brush: add (sign +1) or carve (sign -1) a falloff sphere.
## `strength` scales the per-call amount so held-button strokes carve
## gradually instead of stamping. Returns true if anything changed.
func apply_brush(center: Vector3, radius: float, sign_: float, strength := 1.0) -> bool:
	if in_deadzone(center, radius):
		return false
	var changed := false
	var lo := ((center - Vector3.ONE * radius) - ORIGIN) / VOXEL
	var hi := ((center + Vector3.ONE * radius) - ORIGIN) / VOXEL
	var dirty := {}
	# Brushes reach a little past the painted region; the outer bowl is locked
	var e0 := MARGIN - BRUSH_REACH
	for y in range(maxi(BEDROCK_Y + 1, floori(lo.y)), mini(NY - 1, ceili(hi.y)) + 1):
		for z in range(maxi(e0, floori(lo.z)), mini(NZ - e0, ceili(hi.z)) + 1):
			for x in range(maxi(e0, floori(lo.x)), mini(NX - e0, ceili(hi.x)) + 1):
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
					_mark_dirty(x, z, dirty)
	for key in dirty:
		_remesh_chunk(key)
	return changed


## Lattice point (x,z) touches cells x-1..x / z-1..z, hence up to 4 chunks.
func _mark_dirty(x: int, z: int, dirty: Dictionary) -> void:
	var cz0 := clampi((z - 1) / CHUNK, 0, NZ / CHUNK - 1)
	var cz1 := clampi(z / CHUNK, 0, NZ / CHUNK - 1)
	var cx0 := clampi((x - 1) / CHUNK, 0, NX / CHUNK - 1)
	var cx1 := clampi(x / CHUNK, 0, NX / CHUNK - 1)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			dirty[Vector2i(cx, cz)] = true


## Blender's smooth brush: pull each lattice point toward the average of its
## six neighbours, by the brush falloff. Relaxes lumps and stair-steps without
## adding or removing material. Targets come off the pre-stroke field so the
## result doesn't depend on iteration order.
func smooth_brush(center: Vector3, radius: float, strength := 1.0) -> bool:
	if in_deadzone(center, radius):
		return false
	var lo := ((center - Vector3.ONE * radius) - ORIGIN) / VOXEL
	var hi := ((center + Vector3.ONE * radius) - ORIGIN) / VOXEL
	var targets: Array = []   # [Vector3i, new value]
	var e0 := MARGIN - BRUSH_REACH
	for y in range(maxi(BEDROCK_Y + 1, floori(lo.y)), mini(NY - 1, ceili(hi.y)) + 1):
		for z in range(maxi(e0, floori(lo.z)), mini(NZ - e0, ceili(hi.z)) + 1):
			for x in range(maxi(e0, floori(lo.x)), mini(NX - e0, ceili(hi.x)) + 1):
				var p := ORIGIN + Vector3(x, y, z) * VOXEL
				var dist := p.distance_to(center)
				if dist >= radius:
					continue
				var avg := (_d(x - 1, y, z) + _d(x + 1, y, z) + _d(x, y - 1, z)
					+ _d(x, y + 1, z) + _d(x, y, z - 1) + _d(x, y, z + 1)) / 6.0
				var t := clampf((1.0 - dist / radius) * strength, 0.0, 1.0)
				targets.append([Vector3i(x, y, z), lerpf(_density[_idx(x, y, z)], avg, t)])
	var changed := false
	var dirty := {}
	for entry in targets:
		var c: Vector3i = entry[0]
		var i := _idx(c.x, c.y, c.z)
		if is_equal_approx(entry[1], _density[i]):
			continue
		_density[i] = entry[1]
		changed = true
		_mark_dirty(c.x, c.z, dirty)
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


## Cavity ambient occlusion at a surface point: how buried it is in nearby
## density. Crevices and crater bottoms darken; open ground stays bright.
func _ao_at(p: Vector3) -> float:
	var occ := density_at(p + Vector3(2.5, 0, 0)) \
		+ density_at(p + Vector3(-2.5, 0, 0)) \
		+ density_at(p + Vector3(0, 0, 2.5)) \
		+ density_at(p + Vector3(0, 0, -2.5)) \
		+ density_at(p + Vector3(0, 2.5, 0)) * 2.0
	return 1.0 - clampf((occ / 6.0 - 0.25) * 1.4, 0.0, 0.55)


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
	var colors := PackedColorArray()
	colors.resize(verts.size())
	var ao_cache := {}
	for i in verts.size():
		var ck := verts[i].snapped(Vector3(0.25, 0.25, 0.25))
		var ao: float
		if ao_cache.has(ck):
			ao = ao_cache[ck]
		else:
			ao = _ao_at(verts[i])
			ao_cache[ck] = ao
		colors[i] = Color(ao, ao, ao)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
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
