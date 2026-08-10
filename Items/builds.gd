extends Node3D

## Server-placed build blocks (PORT_BLUEPRINT.md §4.2): block, wall, ramp,
## platform, bridge. Real StaticBody3D colliders — placement raycasts, player
## movement, and projectiles all interact with them automatically.
## (Web bridges were ray-only "thinPlatform"s; here a thin box collider gives
## the same walk-on behavior.)

var _builds: Dictionary = {}   # id -> StaticBody3D


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
