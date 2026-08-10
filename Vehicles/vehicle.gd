extends CharacterBody3D

## Hover vehicle with Halo-Ghost mechanics: a spring holds it off the ground,
## the nose chases the camera yaw, thrust is forward-biased, and lateral grip
## is deliberately weak so it drifts through turns. Shift boosts.
##
## kinds: "ghost" (pure hover) and "drill" (also carves the voxel terrain at
## its nose while moving — the only way to terraform during normal play).
##
## Authority: the local driver simulates; everyone else interpolates to the
## last vehicleMoved state. Parked vehicles are frozen where they were left.

const HOVER_HEIGHT := 1.5     # target ride height over the ground
const HOVER_RANGE := 4.0      # spring engages when ground is within this
const HOVER_STIFF := 24.0
const HOVER_DAMP := 6.0
const GRAVITY := 20.0
const THRUST := 28.0          # forward acceleration
const STRAFE := 13.0
const BOOST_MULT := 1.9
const MAX_SPEED := 20.0
const BOOST_SPEED := 33.0
const LATERAL_GRIP := 1.5     # per-second lateral bleed — low = drifty
const DRAG := 0.5             # light overall drag; coasting carries
const YAW_RATE := 3.4         # rad/s the nose chases the camera
const NET_LERP := 10.0        # remote interpolation rate

const DRILL_RADIUS := 2.8
const DRILL_STRENGTH := 0.8
const DRILL_INTERVAL := 0.09
const DRILL_MIN_SPEED := 2.0

var id := ""
var kind := "ghost"
var driver_id := ""           # "" = parked
var driven_by_me := false
var camera_rig: Node3D        # set by world_vehicles while driven_by_me
var net_pos := Vector3.ZERO
var net_yaw := 0.0

var _visual: Node3D
var _drill_cone: MeshInstance3D
var _drill_cd := 0.0
var _input_pitch := 0.0       # visual nose dip/lift


func setup(vehicle_id: String, vehicle_kind: String) -> void:
	id = vehicle_id
	kind = vehicle_kind


func seat_pos() -> Vector3:
	return global_position + global_transform.basis.y * 1.15


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 1.1, 3.2)
	col.shape = box
	add_child(col)
	_visual = _build_visual()
	add_child(_visual)


func _physics_process(delta: float) -> void:
	if driven_by_me:
		_drive(delta)
	elif driver_id != "":
		# Someone else is driving: chase their relayed state.
		global_position = global_position.lerp(net_pos, 1.0 - exp(-NET_LERP * delta))
		rotation.y = lerp_angle(rotation.y, net_yaw, 1.0 - exp(-NET_LERP * delta))
	# Parked (driver_id == ""): frozen where the last driver left it.
	if _drill_cone:
		var spin_rate := 12.0 if (driven_by_me and velocity.length() > DRILL_MIN_SPEED) else 1.5
		_drill_cone.rotate_object_local(Vector3.UP, spin_rate * delta)


func _drive(delta: float) -> void:
	var typing := get_viewport().gui_get_focus_owner() != null
	var input_dir := Vector2.ZERO if typing else Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")

	# Nose chases the camera (Ghost steering: you drive where you look)
	var target_yaw: float = camera_rig.yaw if camera_rig else rotation.y
	rotation.y = lerp_angle(rotation.y, target_yaw, minf(1.0, YAW_RATE * delta))
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x

	var boosting := not typing and Input.is_action_pressed("sprint")
	var thrust := THRUST * (BOOST_MULT if boosting else 1.0)
	velocity += fwd * (-input_dir.y) * thrust * delta
	velocity += right * input_dir.x * STRAFE * delta

	# Hover spring vs gravity
	var ground := _ground_ray()
	if ground.is_empty():
		velocity.y -= GRAVITY * delta
	else:
		var height: float = global_position.y - ground["position"].y
		velocity.y += clampf(HOVER_STIFF * (HOVER_HEIGHT - height) - HOVER_DAMP * velocity.y, -60.0, 60.0) * delta

	# Drift model: forward speed persists, lateral speed bleeds off slowly
	var hvel := Vector3(velocity.x, 0.0, velocity.z)
	var f_speed := hvel.dot(fwd)
	var lateral := hvel - fwd * f_speed
	lateral *= exp(-LATERAL_GRIP * delta)
	hvel = fwd * f_speed + lateral
	hvel *= exp(-DRAG * delta)
	var cap := BOOST_SPEED if boosting else MAX_SPEED
	if hvel.length() > cap:
		hvel = hvel.normalized() * cap
	velocity.x = hvel.x
	velocity.z = hvel.z

	move_and_slide()

	# Visual lean: bank into lateral slide, dip the nose under thrust
	_input_pitch = lerpf(_input_pitch, -input_dir.y * 0.10, minf(1.0, 8.0 * delta))
	if _visual:
		var lat_speed := hvel.dot(right)
		_visual.rotation.z = lerpf(_visual.rotation.z, clampf(-lat_speed * 0.028, -0.4, 0.4), minf(1.0, 6.0 * delta))
		_visual.rotation.x = _input_pitch

	if kind == "drill":
		_drill(fwd, delta)


## The drill nose eats terrain while moving. Owner-authoritative, same
## pipeline as weapon craters: carve locally, log the edit on the server.
func _drill(fwd: Vector3, delta: float) -> void:
	_drill_cd = maxf(0.0, _drill_cd - delta)
	if _drill_cd > 0.0 or velocity.length() < DRILL_MIN_SPEED:
		return
	var terrain: Node = get_tree().get_first_node_in_group("voxel_terrain")
	if terrain == null:
		return
	var nose := global_position + fwd * 2.6
	_drill_cd = DRILL_INTERVAL
	if terrain.apply_brush(nose, DRILL_RADIUS, -1.0, DRILL_STRENGTH):
		Net.emit_event("terrainEdit", {
			"x": nose.x, "y": nose.y, "z": nose.z,
			"r": DRILL_RADIUS, "s": -1.0, "st": DRILL_STRENGTH,
		})


func _ground_ray() -> Dictionary:
	var from := global_position + Vector3(0, 0.5, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -(HOVER_RANGE + 0.5), 0))
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


# --- Visuals (primitive-built, no assets needed) ---------------------------

func _build_visual() -> Node3D:
	var root := Node3D.new()
	var is_drill := kind == "drill"
	var body_color := Color(0.95, 0.55, 0.15) if is_drill else Color(0.45, 0.3, 0.85)
	var trim_color := Color(0.35, 0.35, 0.4)

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	body_mat.metallic = 0.6
	body_mat.roughness = 0.35
	var trim_mat := StandardMaterial3D.new()
	trim_mat.albedo_color = trim_color
	trim_mat.metallic = 0.8
	trim_mat.roughness = 0.3

	# Main hull: flattened sphere
	var hull := MeshInstance3D.new()
	var hull_mesh := SphereMesh.new()
	hull_mesh.radius = 1.2
	hull_mesh.height = 1.1
	hull_mesh.material = body_mat
	hull.mesh = hull_mesh
	hull.scale = Vector3(1.0, 1.0, 1.35)  # stretched along travel
	root.add_child(hull)

	# Cockpit hump behind center
	var hump := MeshInstance3D.new()
	var hump_mesh := SphereMesh.new()
	hump_mesh.radius = 0.55
	hump_mesh.height = 0.9
	hump_mesh.material = trim_mat
	hump.mesh = hump_mesh
	hump.position = Vector3(0, 0.55, 0.7)
	root.add_child(hump)

	# Twin front prongs (the Ghost's wings/cannons)
	for side in [-1.0, 1.0]:
		var prong := MeshInstance3D.new()
		var pm := CapsuleMesh.new()
		pm.radius = 0.22
		pm.height = 1.9
		pm.material = trim_mat
		prong.mesh = pm
		prong.rotation.x = PI / 2.0
		prong.position = Vector3(side * 0.85, -0.1, -1.35)
		root.add_child(prong)

	if is_drill:
		_drill_cone = MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.95
		cone.height = 2.2
		var cone_mat := StandardMaterial3D.new()
		cone_mat.albedo_color = Color(0.75, 0.75, 0.8)
		cone_mat.metallic = 0.9
		cone_mat.roughness = 0.2
		cone.material = cone_mat
		_drill_cone.mesh = cone
		_drill_cone.rotation.x = -PI / 2.0  # point the tip forward (-Z)
		_drill_cone.position = Vector3(0, 0.1, -2.3)
		root.add_child(_drill_cone)

	# Engine glow underneath
	var glow := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.7
	disc.bottom_radius = 0.7
	disc.height = 0.12
	var glow_mat := StandardMaterial3D.new()
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.albedo_color = Color(1.0, 0.6, 0.2) if is_drill else Color(0.35, 0.75, 1.0)
	glow_mat.emission_enabled = true
	glow_mat.emission = glow_mat.albedo_color
	glow_mat.emission_energy_multiplier = 2.0
	disc.material = glow_mat
	glow.mesh = disc
	glow.position = Vector3(0, -0.55, 0.2)
	root.add_child(glow)

	return root
