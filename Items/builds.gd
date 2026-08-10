extends Node3D

## Server-placed build blocks (PORT_BLUEPRINT.md §4.2): block, wall, ramp,
## platform, bridge. Real StaticBody3D colliders — placement raycasts, player
## movement, and projectiles all interact with them automatically.
## (Web bridges were ray-only "thinPlatform"s; here a thin box collider gives
## the same walk-on behavior.)

## Channels (web §4.4): Ryan's parametric multi-point half-pipe "bridge" —
## anchors are relaxed at sharp corners, swept with a centripetal
## Catmull-Rom curve, ringed into a K-facet trough whose opening faces up.
const CHANNEL_RADIUS := 2.5
const CHANNEL_FACETS := 12
const CHANNEL_MAX_RELAX := 0.6
const CHANNEL_RING_SPACING := 1.5
const CHANNEL_MAX_RINGS := 260

var _builds: Dictionary = {}   # id -> StaticBody3D
var _channels: Dictionary = {}  # id -> StaticBody3D


func _ready() -> void:
	add_to_group("world_builds")
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentBuilds":
			for id in _builds:
				_builds[id].queue_free()
			_builds.clear()
			for b in data:
				_add_build(b)
		"buildPlaced":
			_add_build(data)
		"buildRemoved":
			var id := str(data)
			if _builds.has(id):
				_builds[id].queue_free()
				_builds.erase(id)
		"currentChannels":
			for id in _channels:
				_channels[id].queue_free()
			_channels.clear()
			for c in data:
				_add_channel(c)
		"channelPlaced":
			_add_channel(data)
		"channelRemoved":
			var id := str(data)
			if _channels.has(id):
				_channels[id].queue_free()
				_channels.erase(id)


## Web overlap rejection: same cell (<0.1), same type, same rotation.
func has_build_at(pos: Vector3, type: String, ry: float, rx: float) -> bool:
	for id in _builds:
		var b: StaticBody3D = _builds[id]
		if b.position.distance_to(pos) < 0.1 \
				and b.get_meta("build_type", "") == type \
				and absf(wrapf(b.rotation.y - ry, -PI, PI)) < 0.1 \
				and absf(wrapf(b.rotation.x - rx, -PI, PI)) < 0.1:
			return true
	return false


func _add_build(b: Dictionary) -> void:
	var id := str(b.get("id", ""))
	if id == "" or _builds.has(id):
		return
	var type := str(b.get("type", "block"))
	var body := StaticBody3D.new()
	body.set_meta("build_type", type)

	var mesh_inst := MeshInstance3D.new()
	var shape := CollisionShape3D.new()
	var is_bridge := type == "bridge"

	var mat := StandardMaterial3D.new()
	if is_bridge:
		mat.albedo_color = Color(0.0, 1.0, 1.0, 0.6)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(0.0, 0.5, 0.5)
	else:
		mat.albedo_color = Color(0.667, 0.667, 0.667)
		mat.roughness = 0.8
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # web used DoubleSide

	match type:
		"ramp":
			mesh_inst.mesh = wedge_mesh(4.0, 4.0, 4.0)
			var poly := ConvexPolygonShape3D.new()
			poly.points = wedge_points(4.0, 4.0, 4.0)
			shape.shape = poly
		_:
			var size := Vector3(4, 4, 4)
			if type == "wall":
				size = Vector3(4, 4, 1)
			elif type == "platform":
				size = Vector3(4, 1, 4)
			elif is_bridge:
				size = Vector3(4, 0.2, clampf(float(b.get("length", 4.0)), 0.1, 100.0))
			var box := BoxMesh.new()
			box.size = size
			mesh_inst.mesh = box
			var box_shape := BoxShape3D.new()
			box_shape.size = size
			shape.shape = box_shape
	mesh_inst.material_override = mat

	body.add_child(mesh_inst)
	body.add_child(shape)
	body.position = Vector3(b.get("x", 0.0), b.get("y", 0.0), b.get("z", 0.0))
	body.rotation_order = EULER_ORDER_YXZ
	body.rotation = Vector3(float(b.get("rx", 0.0)), float(b.get("ry", 0.0)), 0.0)
	add_child(body)
	_builds[id] = body


# --- Channels ---------------------------------------------------------------

## Web relaxChannelAnchors: no pull under ~25°, full 0.6 pull past ~125°.
static func _relax_anchors(points: Array) -> Array:
	if points.size() <= 2:
		return points.duplicate()
	var out: Array = [points[0]]
	for i in range(1, points.size() - 1):
		var v1: Vector3 = points[i] - points[i - 1]
		var v2: Vector3 = points[i + 1] - points[i]
		if v1.length_squared() < 1e-8 or v2.length_squared() < 1e-8:
			out.append(points[i])
			continue
		var angle := acos(clampf(v1.normalized().dot(v2.normalized()), -1.0, 1.0))
		var t := clampf((angle - PI / 7.0) / (PI * 0.6), 0.0, 1.0) * CHANNEL_MAX_RELAX
		var mid: Vector3 = (points[i - 1] + points[i + 1]) * 0.5
		out.append(points[i].lerp(mid, t))
	out.append(points[points.size() - 1])
	return out


## Centripetal Catmull-Rom (Barry–Goldman), matching THREE's 'centripetal'.
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


## Half-pipe triangles swept along the smoothed anchor polyline (web
## buildChannelGeometry): dense-sample the spline, resample to ~1.5 u rings,
## sweep a K-facet arc with a non-banking frame (opening faces world up).
static func channel_tris(anchors_in: Array, radius: float) -> PackedVector3Array:
	var anchors := _relax_anchors(anchors_in)
	var dense: Array = []
	for i in anchors.size() - 1:
		var p0: Vector3 = anchors[maxi(i - 1, 0)]
		var p1: Vector3 = anchors[i]
		var p2: Vector3 = anchors[i + 1]
		var p3: Vector3 = anchors[mini(i + 2, anchors.size() - 1)]
		for s in 12:
			dense.append(_cr_point(p0, p1, p2, p3, s / 12.0))
	dense.append(anchors[anchors.size() - 1])

	var length := 0.0
	for i in dense.size() - 1:
		length += dense[i].distance_to(dense[i + 1])
	var n := clampi(ceili(length / CHANNEL_RING_SPACING), 2, CHANNEL_MAX_RINGS)

	# Evenly arc-spaced ring centers
	var samples: Array = [dense[0]]
	var step := length / n
	var acc := 0.0
	var di := 0
	for k in range(1, n):
		var want := k * step
		while di < dense.size() - 1:
			var seg: float = dense[di].distance_to(dense[di + 1])
			if acc + seg >= want:
				samples.append(dense[di].lerp(dense[di + 1], (want - acc) / maxf(seg, 1e-6)))
				break
			acc += seg
			di += 1
		if samples.size() <= k:
			samples.append(dense[dense.size() - 1])
	samples.append(dense[dense.size() - 1])

	var rings: Array = []
	for i in samples.size():
		var tangent: Vector3
		if i == 0:
			tangent = samples[1] - samples[0]
		elif i == samples.size() - 1:
			tangent = samples[i] - samples[i - 1]
		else:
			tangent = samples[i + 1] - samples[i - 1]
		if tangent.length_squared() < 1e-8:
			tangent = Vector3(0, 0, 1)
		tangent = tangent.normalized()
		var rt := Vector3.UP.cross(tangent)
		rt = Vector3(1, 0, 0) if rt.length_squared() < 1e-6 else rt.normalized()
		var up := tangent.cross(rt).normalized()
		var ring: Array = []
		for j in CHANNEL_FACETS + 1:
			var a := -PI / 2.0 + (float(j) / CHANNEL_FACETS) * PI
			ring.append(samples[i] + rt * radius * sin(a) + up * radius * (1.0 - cos(a)))
		rings.append(ring)

	var tris := PackedVector3Array()
	for i in rings.size() - 1:
		for j in CHANNEL_FACETS:
			var a0: Vector3 = rings[i][j]
			var a1: Vector3 = rings[i + 1][j]
			var b0: Vector3 = rings[i][j + 1]
			var b1: Vector3 = rings[i + 1][j + 1]
			tris.append(a0); tris.append(a1); tris.append(b0)
			tris.append(a1); tris.append(b1); tris.append(b0)
	return tris


func _add_channel(c: Dictionary) -> void:
	var id := str(c.get("id", ""))
	if id == "" or _channels.has(id):
		return
	var anchors: Array = []
	for nd in c.get("nodes", []):
		anchors.append(Vector3(nd.get("x", 0.0), nd.get("y", 0.0), nd.get("z", 0.0)))
	if anchors.size() < 2:
		return
	var tris := channel_tris(anchors, float(c.get("radius", CHANNEL_RADIUS)))
	if tris.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in tris:
		st.add_vertex(v)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.78, 0.85)
	mat.roughness = 0.55
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var body := StaticBody3D.new()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = st.commit()
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	col.shape = shape
	body.add_child(col)
	add_child(body)
	_channels[id] = body


## Right wedge matching the web's createRightWedgeGeometry: flat bottom,
## vertical back (-Z), slope from the front-bottom edge up to the back-top.
static func wedge_points(w: float, h: float, d: float) -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-w / 2, -h / 2,  d / 2), Vector3(w / 2, -h / 2,  d / 2),
		Vector3(w / 2, -h / 2, -d / 2), Vector3(-w / 2, -h / 2, -d / 2),
		Vector3(-w / 2,  h / 2, -d / 2), Vector3(w / 2,  h / 2, -d / 2),
	])


static func wedge_mesh(w: float, h: float, d: float) -> ArrayMesh:
	var v := wedge_points(w, h, d)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [
		[0, 2, 1], [0, 3, 2],       # bottom
		[3, 4, 5], [3, 5, 2],       # back (vertical)
		[0, 4, 3],                  # left
		[1, 2, 5],                  # right
		[0, 1, 5], [0, 5, 4],       # slope
	]:
		st.add_vertex(v[tri[0]])
		st.add_vertex(v[tri[1]])
		st.add_vertex(v[tri[2]])
	st.generate_normals()
	return st.commit()
