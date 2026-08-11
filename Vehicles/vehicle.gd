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
const DRILL_HP_PER_TICK := 0.5  # ~5.5 health/s while the drill is eating

# Crash physics: a hard head-on stop knocks the vehicle into free rigid-body
# "wreck" physics — it can bounce, tumble, and settle upside down. Landing
# upright parks it again on its own; upside down it waits for an E-flip.
const CRASH_SPEED := 11.0     # planar speed you must shed in one hit
const CRASH_REMAINDER := 3.0

var id := ""
var kind := "ghost"
var driver_id := ""           # "" = parked
var driven_by_me := false
var camera_rig: Node3D        # set by world_vehicles while driven_by_me
var net_pos := Vector3.ZERO
var net_yaw := 0.0
var net_quat := Quaternion.IDENTITY   # full orientation, used while wrecked

var wrecked := false
var crashed := false          # one-shot flag world_vehicles picks up
var crash_vel := Vector3.ZERO # planar velocity the instant before the hit

var _visual: Node3D
var _col: CollisionShape3D
var _wreck_body: RigidBody3D  # only on the client simulating the wreck
var _drill_cone: MeshInstance3D
var _drill_cd := 0.0
var _drilling := false
var _drain_acc := 0.0
var _input_pitch := 0.0       # visual nose dip/lift


func setup(vehicle_id: String, vehicle_kind: String) -> void:
	id = vehicle_id
	kind = vehicle_kind


func seat_pos() -> Vector3:
	return global_position + global_transform.basis.y * 1.15


func _exit_tree() -> void:
	# The wreck sim body lives beside us, not under us — don't leak it
	if _wreck_body and is_instance_valid(_wreck_body):
		_wreck_body.queue_free()


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_col = CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 1.1, 3.2)
	_col.shape = box
	add_child(_col)
	_visual = _build_visual()
	add_child(_visual)


func _physics_process(delta: float) -> void:
	if wrecked:
		if _wreck_body and is_instance_valid(_wreck_body):
			# We simulate: the node just mirrors the rigid body
			global_transform = _wreck_body.global_transform
		else:
			# Remote wreck: chase the relayed full orientation
			var f := 1.0 - exp(-NET_LERP * delta)
			global_position = global_position.lerp(net_pos, f)
			quaternion = quaternion.slerp(net_quat, f)
		return
	if driven_by_me:
		_drive(delta)
	elif driver_id != "":
		# Someone else is driving: chase their relayed state.
		global_position = global_position.lerp(net_pos, 1.0 - exp(-NET_LERP * delta))
		rotation.y = lerp_angle(rotation.y, net_yaw, 1.0 - exp(-NET_LERP * delta))
	# Parked (driver_id == ""): frozen where the last driver left it.
	if _drill_cone:
		var spin_rate := 14.0 if _drilling else 1.5
		_drill_cone.rotate_object_local(Vector3.UP, spin_rate * delta)


# --- Wreck mode --------------------------------------------------------------

## Knock the vehicle into rigid-body physics. `sim` = this client owns the
## tumble (the crasher); remotes just render the relayed transform.
func enter_wreck(sim: bool, impact := Vector3.ZERO) -> void:
	if wrecked:
		return
	wrecked = true
	crashed = false
	velocity = Vector3.ZERO
	net_quat = quaternion
	if not sim:
		return
	_col.disabled = true
	_wreck_body = RigidBody3D.new()
	_wreck_body.mass = 90.0
	var c := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 1.1, 3.2)
	c.shape = box
	_wreck_body.add_child(c)
	get_parent().add_child(_wreck_body)
	_wreck_body.global_transform = global_transform
	# Bounce off the wall it just ate: some of the impact back, plus a pop
	_wreck_body.linear_velocity = -impact * 0.35 + Vector3(0, 4.5, 0)
	_wreck_body.angular_velocity = Vector3(
		randf_range(-4.0, 4.0), randf_range(-2.0, 2.0), randf_range(-4.0, 4.0))


func exit_wreck(pos: Vector3, yaw: float) -> void:
	wrecked = false
	crashed = false
	if _wreck_body and is_instance_valid(_wreck_body):
		_wreck_body.queue_free()
	_wreck_body = null
	if _col:
		_col.disabled = false
	global_position = pos
	rotation = Vector3(0, yaw, 0)
	net_pos = pos
	net_yaw = yaw
	net_quat = quaternion
	velocity = Vector3.ZERO


func wreck_settled() -> bool:
	return _wreck_body != null and is_instance_valid(_wreck_body) \
		and (_wreck_body.sleeping or (_wreck_body.linear_velocity.length() < 0.5
			and _wreck_body.angular_velocity.length() < 0.5))


func wreck_upright() -> bool:
	var b := _wreck_body.global_transform.basis if _wreck_body and is_instance_valid(_wreck_body) \
		else global_transform.basis
	return b.y.dot(Vector3.UP) > 0.65


func wreck_transform() -> Transform3D:
	return _wreck_body.global_transform if _wreck_body and is_instance_valid(_wreck_body) \
		else global_transform


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

	var pre_vel := velocity
	var pre_speed := hvel.length()
	move_and_slide()

	# Crash check: a lot of speed gone in one hit against something vertical
	var post_speed := Vector2(velocity.x, velocity.z).length()
	if pre_speed > CRASH_SPEED and post_speed < CRASH_REMAINDER:
		for ci in get_slide_collision_count():
			if absf(get_slide_collision(ci).get_normal().y) < 0.5:
				crashed = true
				crash_vel = pre_vel
				break

	# Visual lean: bank into lateral slide, dip the nose under thrust
	_input_pitch = lerpf(_input_pitch, -input_dir.y * 0.10, minf(1.0, 8.0 * delta))
	if _visual:
		var lat_speed := hvel.dot(right)
		_visual.rotation.z = lerpf(_visual.rotation.z, clampf(-lat_speed * 0.028, -0.4, 0.4), minf(1.0, 6.0 * delta))
		_visual.rotation.x = _input_pitch

	if kind == "drill":
		_drill(typing, delta)


## The drill eats terrain while you HOLD LEFT MOUSE, along where the camera
## points — face up and it bores upward. Each bite costs health (the drill
## runs on your life). Owner-authoritative, same pipeline as weapon craters.
func _drill(typing: bool, delta: float) -> void:
	_drill_cd = maxf(0.0, _drill_cd - delta)
	var wants := not typing and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var p: float = camera_rig.pitch if camera_rig else 0.0
	if _drill_cone:
		_drill_cone.rotation.x = -PI / 2.0 - p  # nose follows the camera pitch
	_drilling = false
	if not wants or _drill_cd > 0.0:
		return
	var terrain: Node = get_tree().get_first_node_in_group("voxel_terrain")
	if terrain == null:
		return
	var yaw := rotation.y
	var aim := Vector3(-cos(p) * sin(yaw), -sin(p), -cos(p) * cos(yaw)).normalized()
	var nose := global_position + aim * 2.8
	_drill_cd = DRILL_INTERVAL
	if terrain.apply_brush(nose, DRILL_RADIUS, -1.0, DRILL_STRENGTH):
		_drilling = true
		Net.emit_event("terrainEdit", {
			"x": nose.x, "y": nose.y, "z": nose.z,
			"r": DRILL_RADIUS, "s": -1.0, "st": DRILL_STRENGTH,
		})
		# Drilling burns your life at a medium clip
		_drain_acc += DRILL_HP_PER_TICK
		if _drain_acc >= 1.0:
			_drain_acc -= 1.0
			Net.emit_event("selfDamage", 1)


func _ground_ray() -> Dictionary:
	var from := global_position + Vector3(0, 0.5, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -(HOVER_RANGE + 0.5), 0))
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


# --- Visuals (Kenney Space Kit, CC0: craft_speederA / craft_miner) ---------

const GhostModel := preload("res://Models/kenney/craft_speederA.glb")
const DrillModel := preload("res://Models/kenney/craft_miner.glb")

## Merged AABB of every mesh under `node`, in `node`'s local space (works
## before the node enters the tree — transforms are accumulated manually).
static func _model_aabb(node: Node) -> AABB:
	var out: Array = [AABB(), true]
	_merge_aabb(node, Transform3D(), out)
	return out[0]


static func _merge_aabb(n: Node, xf: Transform3D, out: Array) -> void:
	if n is Node3D:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var box: AABB = xf * (n as MeshInstance3D).mesh.get_aabb()
		out[0] = box if out[1] else (out[0] as AABB).merge(box)
		out[1] = false
	for child in n.get_children():
		_merge_aabb(child, xf, out)


func _build_visual() -> Node3D:
	var root := Node3D.new()
	var is_drill := kind == "drill"

	var model: Node3D = (DrillModel if is_drill else GhostModel).instantiate()
	root.add_child(model)
	# Normalize the kit model to ~3.4 m of hull, resting under the seat.
	# Kenney GLB origins sit off-center, so recenter x/z on the collider too.
	var box := _model_aabb(model)
	if box.size.z > 0.01:
		var s := 3.4 / maxf(box.size.z, box.size.x)
		var c := box.get_center()
		model.scale = Vector3.ONE * s
		# The PI yaw flip below mirrors x/z, hence the positive offsets
		model.position = Vector3(c.x * s, -0.55 - box.position.y * s, c.z * s)
	# Kenney crafts model forward as +Z; our vehicles drive -Z
	model.rotation.y = PI

	if is_drill:
		_drill_cone = MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.8
		cone.height = 2.0
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
