extends CharacterBody3D

## Hover vehicle with Halo-Ghost mechanics: a spring holds it off the ground,
## the nose chases the camera yaw, thrust is forward-biased, and lateral grip
## is deliberately weak so it drifts through turns. Shift boosts.
##
## kinds: "ghost" (pure hover), "drill" (also carves the voxel terrain at
## its nose while moving — the only way to terraform during normal play),
## and the remote-piloted machine animals "crowbot" (flies) / "ratbot"
## (scurries). Bots aren't ridden: the pilot's body stays where it was
## (drone-style) and nearby critter flocks follow the bot as an attractor.
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

# Machine-animal bots
const CROWBOT_SPEED := 14.0   # full-3D flight, camera-directed
const CROWBOT_ACCEL := 5.0    # velocity chase rate (soft, floaty)
const RATBOT_SPEED := 11.0
const RATBOT_STICK := 4.0     # adhesion pull along the surface normal
# Parked crow-bots don't freeze mid-air: they loiter on a lazy ring around the
# park spot. Client-local and cosmetic, like the boids — the synced park
# position is the ring's anchor, so every client watches the same patch of sky.
const AMBIENT_R := 2.6
const AMBIENT_RATE := 0.8     # rad/s around the loiter ring
const AMBIENT_SPEED := 4.0
const AMBIENT_LIFT := 2.2     # ring height above the ground

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
var _flap_speed := 0.0        # crowbot: wing rate follows apparent speed
var _last_pos := Vector3.ZERO
var _ambient_anchor := Vector3.INF   # INF = not loitering
var _ambient_t := 0.0
var _climb_n := Vector3.UP    # ratbot: the surface normal it's glued to
var _drill_cd := 0.0
var _drilling := false
var _drain_acc := 0.0
var _input_pitch := 0.0       # visual nose dip/lift


func setup(vehicle_id: String, vehicle_kind: String) -> void:
	id = vehicle_id
	kind = vehicle_kind


func is_bot() -> bool:
	return kind == "crowbot" or kind == "ratbot"


func seat_pos() -> Vector3:
	return global_position + global_transform.basis.y * 1.15


func _exit_tree() -> void:
	# The wreck sim body lives beside us, not under us — don't leak it
	if _wreck_body and is_instance_valid(_wreck_body):
		_wreck_body.queue_free()


func _ready() -> void:
	# Every kind is FLOATING — the rat-attack glues itself to walls/ceilings
	# with its own adhesion, so gravity-floor logic would just fight it
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_col = CollisionShape3D.new()
	var box := BoxShape3D.new()
	match kind:
		"crowbot": box.size = Vector3(1.0, 0.5, 1.2)
		"ratbot": box.size = Vector3(0.7, 0.45, 1.3)
		_: box.size = Vector3(2.4, 1.1, 3.2)
	_col.shape = box
	if kind == "ratbot":
		_col.position.y = 0.25  # feet at the node origin, so it sits ON ground
	add_child(_col)
	_visual = _build_visual()
	add_child(_visual)
	if kind == "crowbot":
		add_to_group("bot_crow")
	elif kind == "ratbot":
		add_to_group("bot_rat")


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
	if driver_id != "":
		_ambient_anchor = Vector3.INF  # a pilot took over: stop loitering
	if driven_by_me:
		match kind:
			"crowbot": _fly_bot(delta)
			"ratbot": _climb_bot(delta)
			_: _drive(delta)
	elif driver_id != "":
		# Someone else is driving: chase their relayed state. Rat-attacks
		# relay a full orientation (they ride walls and ceilings).
		var f := 1.0 - exp(-NET_LERP * delta)
		global_position = global_position.lerp(net_pos, f)
		if kind == "ratbot":
			quaternion = quaternion.slerp(net_quat, f)
		else:
			rotation.y = lerp_angle(rotation.y, net_yaw, f)
	elif kind == "crowbot":
		_ambient_fly(delta)  # parked crow-bots patrol their spot
	if _drill_cone:
		var spin_rate := 14.0 if _drilling else 1.5
		_drill_cone.rotate_object_local(Vector3.UP, spin_rate * delta)
	if kind == "crowbot":
		_flap_wings(delta)


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


# --- Machine-animal bots ------------------------------------------------------

## Crow-bot: full-3D flight. Forward tracks the camera LOOK (pitch included,
## so you dive by looking down), strafe stays horizontal, Space/Shift nudge
## altitude. Soft velocity chase keeps it floaty, like a big mechanical bird.
func _fly_bot(delta: float) -> void:
	var typing := get_viewport().gui_get_focus_owner() != null
	var input_dir := Vector2.ZERO if typing else Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var yaw: float = camera_rig.yaw if camera_rig else rotation.y
	var pitch: float = camera_rig.pitch if camera_rig else 0.0
	rotation.y = lerp_angle(rotation.y, yaw, minf(1.0, YAW_RATE * delta))
	var look := Vector3(-cos(pitch) * sin(yaw), -sin(pitch), -cos(pitch) * cos(yaw))
	var right := Vector3(-look.z, 0.0, look.x).normalized() if absf(look.y) < 0.99 else Vector3.RIGHT
	var wish := look * (-input_dir.y) + right * input_dir.x
	if not typing:
		if Input.is_action_pressed("jump"):
			wish.y += 0.8
		if Input.is_action_pressed("sprint"):
			wish.y -= 0.8
	velocity = velocity.lerp(wish.limit_length(1.0) * CROWBOT_SPEED, minf(1.0, CROWBOT_ACCEL * delta))
	move_and_slide()
	# Bank into the turn
	if _visual:
		var lat := velocity.dot(right)
		_visual.rotation.z = lerpf(_visual.rotation.z, clampf(-lat * 0.05, -0.55, 0.55), minf(1.0, 6.0 * delta))
		_visual.rotation.x = lerpf(_visual.rotation.x, clampf(velocity.y * 0.04, -0.5, 0.5), minf(1.0, 6.0 * delta))


## Rat-attack: crawls over ANY surface — floors, walls, ceilings — glued on
## by an adhesion pull along the current surface normal. It cannot jump;
## crawling off into open air means falling until something is under it again.
func _climb_bot(delta: float) -> void:
	var typing := get_viewport().gui_get_focus_owner() != null
	var input_dir := Vector2.ZERO if typing else Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var yaw: float = camera_rig.yaw if camera_rig else rotation.y
	var cam_fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var cam_right := Vector3(-cam_fwd.z, 0, cam_fwd.x)
	var raw_wish := cam_fwd * (-input_dir.y) + cam_right * input_dir.x
	# Map the wish onto the surface: the part pushing INTO a wall becomes a
	# climb up it, pulling away becomes a descent
	var into := -raw_wish.dot(_climb_n)
	var wish := raw_wish - _climb_n * raw_wish.dot(_climb_n)
	var up_t := Vector3.UP - _climb_n * Vector3.UP.dot(_climb_n)
	if up_t.length() > 0.05:
		wish += up_t.normalized() * into
	wish = wish.limit_length(1.0)

	var space := get_world_3d().direct_space_state
	var attached := false
	# A surface right ahead of the crawl: adopt it (floor -> wall transition)
	if wish.length() > 0.1:
		var ahead := _climb_ray(space, global_position, global_position + wish.normalized() * 0.9)
		if not ahead.is_empty():
			_climb_n = ahead["normal"]
			attached = true
	# The surface we're riding
	if not attached:
		var down := _climb_ray(space, global_position + _climb_n * 0.3, global_position - _climb_n * 1.1)
		if not down.is_empty():
			_climb_n = down["normal"]
			attached = true
	# Outer corner: wrap around the edge we just crawled past
	if not attached and velocity.length() > 0.5:
		var lip := global_position - _climb_n * 0.7
		var back := _climb_ray(space, lip, lip - velocity.normalized() * 0.9)
		if not back.is_empty():
			_climb_n = back["normal"]
			attached = true

	if attached:
		velocity = velocity.lerp(wish * RATBOT_SPEED - _climb_n * RATBOT_STICK,
			minf(1.0, 10.0 * delta))
	else:
		# Airborne: normal gravity, weak air control, roll back upright
		_climb_n = _climb_n.slerp(Vector3.UP, minf(1.0, 3.0 * delta)).normalized()
		velocity.x = lerpf(velocity.x, raw_wish.x * RATBOT_SPEED * 0.6, minf(1.0, 3.0 * delta))
		velocity.z = lerpf(velocity.z, raw_wish.z * RATBOT_SPEED * 0.6, minf(1.0, 3.0 * delta))
		velocity.y -= GRAVITY * delta
	move_and_slide()

	# Body hugs the surface: local up = surface normal, nose along the crawl
	var fwd_t := velocity - _climb_n * velocity.dot(_climb_n)
	if fwd_t.length() < 0.3:
		var old_fwd := -global_transform.basis.z
		fwd_t = old_fwd - _climb_n * old_fwd.dot(_climb_n)
	if fwd_t.length() > 0.05:
		var target := Basis.looking_at(fwd_t.normalized(), _climb_n)
		global_transform.basis = global_transform.basis.slerp(target, minf(1.0, 8.0 * delta)).orthonormalized()


func _climb_ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	return space.intersect_ray(q)


## Parked crow-bot: take off and fly a lazy loiter ring over the park spot,
## bobbing and scanning. Pure ambience — the moment anyone pilots it (any
## client), the ring is abandoned.
func _ambient_fly(delta: float) -> void:
	if wrecked:
		return
	if _ambient_anchor == Vector3.INF:
		_ambient_anchor = global_position
		var g := _ground_ray()
		if not g.is_empty():
			_ambient_anchor.y = maxf(_ambient_anchor.y, float(g["position"].y) + AMBIENT_LIFT)
		_ambient_t = randf() * TAU
	_ambient_t += AMBIENT_RATE * delta
	var target := _ambient_anchor + Vector3(
		cos(_ambient_t) * AMBIENT_R,
		sin(_ambient_t * 2.3) * 0.5,
		sin(_ambient_t) * AMBIENT_R)
	velocity = velocity.lerp((target - global_position).limit_length(4.0) * (AMBIENT_SPEED / 4.0),
		minf(1.0, 2.0 * delta))
	move_and_slide()
	var prev_yaw := rotation.y
	if velocity.length() > 0.4:
		rotation.y = lerp_angle(rotation.y, atan2(-velocity.x, -velocity.z), minf(1.0, 3.0 * delta))
	if _visual:
		# Bank into the turn, nose follows the bob
		var yaw_rate := angle_difference(prev_yaw, rotation.y) / maxf(delta, 0.001)
		_visual.rotation.z = lerpf(_visual.rotation.z, clampf(yaw_rate * 0.3, -0.4, 0.4), minf(1.0, 3.0 * delta))
		_visual.rotation.x = lerpf(_visual.rotation.x, clampf(-velocity.y * 0.08, -0.3, 0.3), minf(1.0, 3.0 * delta))


## Wings beat with apparent speed on EVERY client (remotes estimate speed
## from position deltas, since only the pilot has a real velocity). The
## feather tips trail the main flap, and the head scans while unpiloted.
func _flap_wings(delta: float) -> void:
	var spd := velocity.length() if driven_by_me \
		else global_position.distance_to(_last_pos) / maxf(delta, 0.001)
	_last_pos = global_position
	var active := not wrecked  # loitering counts as flying now
	_flap_speed = lerpf(_flap_speed, (6.0 + spd * 0.8) if active else 0.0, minf(1.0, 5.0 * delta))
	var wl: Node3D = _visual.get_node_or_null("WingL") if _visual else null
	if wl == null:
		return
	var wr: Node3D = _visual.get_node("WingR")
	var amp := 0.5 if driver_id != "" else 0.32   # lazier beat on patrol
	var flap := sin(Time.get_ticks_msec() / 1000.0 * _flap_speed) * amp if active else -0.25
	wl.rotation.z = flap
	wr.rotation.z = -flap
	var tip_l: Node3D = wl.get_node_or_null("Tip")
	if tip_l:
		tip_l.rotation.z = flap * 0.7
		(wr.get_node("Tip") as Node3D).rotation.z = -flap * 0.7
	var head: Node3D = _visual.get_node_or_null("Head")
	if head:
		var scan := 0.0 if driver_id != "" else sin(Time.get_ticks_msec() / 1000.0 * 1.3) * 0.45
		head.rotation.y = lerpf(head.rotation.y, scan, minf(1.0, 4.0 * delta))


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
	if kind == "crowbot":
		return _build_crowbot()
	if kind == "ratbot":
		return _build_ratbot()
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


# --- Bot bodies: mechanical takes on the critters, ~2.5x their size ----------

static func _bot_plate() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.22, 0.24, 0.28)
	m.metallic = 0.85
	m.roughness = 0.35
	return m


static func _bot_glow(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 2.5
	return m


static func _bot_box(root: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D, box_name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if box_name != "":
		mi.name = box_name
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	root.add_child(mi)
	return mi


## Crow-bot body: a proper mech corvid — deep chest, swept tail boom, a
## scanning head on a neck pivot, two-segment wings whose feather tips trail
## the flap, a fanned tail, and folded talon struts.
func _build_crowbot() -> Node3D:
	var root := Node3D.new()
	var plate := _bot_plate()
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.13, 0.14, 0.17)
	dark.metallic = 0.9
	dark.roughness = 0.3
	var eye := _bot_glow(Color(0.4, 0.9, 1.0))

	# Fuselage
	_bot_box(root, Vector3(0.46, 0.36, 0.6), Vector3(0, 0, -0.08), plate)       # chest
	var boom := _bot_box(root, Vector3(0.3, 0.24, 0.55), Vector3(0, 0.05, 0.38), plate)
	boom.rotation.x = -0.12                                                      # tail sweeps up
	_bot_box(root, Vector3(0.16, 0.08, 0.7), Vector3(0, 0.2, 0.06), dark)       # spine ridge
	_bot_box(root, Vector3(0.34, 0.1, 0.2), Vector3(0, -0.2, -0.24), dark)      # chin plate
	_bot_box(root, Vector3(0.28, 0.04, 0.04), Vector3(0, 0.0, -0.39), _bot_glow(Color(0.25, 0.65, 1.0)))  # chest vent

	# Head on a neck pivot (named: it scans while the bot patrols)
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.22, -0.34)
	root.add_child(head)
	_bot_box(head, Vector3(0.16, 0.14, 0.18), Vector3(0, 0.0, -0.02), dark)     # neck
	_bot_box(head, Vector3(0.28, 0.22, 0.3), Vector3(0, 0.12, -0.18), plate)    # skull
	_bot_box(head, Vector3(0.09, 0.07, 0.3), Vector3(0, 0.1, -0.44), dark)      # upper beak
	_bot_box(head, Vector3(0.07, 0.045, 0.2), Vector3(0, 0.03, -0.4), plate)    # lower beak
	_bot_box(head, Vector3(0.03, 0.16, 0.03), Vector3(0, 0.3, -0.08), dark)     # antenna
	_bot_box(head, Vector3(0.05, 0.05, 0.05), Vector3(0, 0.4, -0.08), eye)      # antenna tip
	for side: float in [-1.0, 1.0]:
		_bot_box(head, Vector3(0.06, 0.09, 0.09), Vector3(side * 0.15, 0.13, -0.24), eye)   # eyes
		_bot_box(head, Vector3(0.04, 0.12, 0.16), Vector3(side * 0.15, 0.15, -0.1), dark)   # brow plates

	# Wings: shoulder pivot -> armored inner panel -> hinged feather tip
	for side: float in [-1.0, 1.0]:
		var wing := Node3D.new()
		wing.name = "WingL" if side < 0 else "WingR"
		wing.position = Vector3(side * 0.22, 0.14, 0.02)
		root.add_child(wing)
		_bot_box(wing, Vector3(0.62, 0.06, 0.5), Vector3(side * 0.31, 0, 0), plate)
		_bot_box(wing, Vector3(0.5, 0.03, 0.34), Vector3(side * 0.3, 0.05, 0.1), dark)
		var tip := Node3D.new()
		tip.name = "Tip"
		tip.position = Vector3(side * 0.62, 0, 0)
		wing.add_child(tip)
		# Staggered feather plates, sweeping back and thinning outward
		_bot_box(tip, Vector3(0.5, 0.04, 0.42), Vector3(side * 0.25, 0, 0.02), plate)
		_bot_box(tip, Vector3(0.36, 0.03, 0.3), Vector3(side * 0.4, -0.01, 0.16), dark)
		_bot_box(tip, Vector3(0.22, 0.03, 0.2), Vector3(side * 0.5, -0.02, 0.28), plate)

	# Tail fan: three plates hinged at the boom, fanned in yaw
	var tail := Node3D.new()
	tail.name = "Tail"
	tail.position = Vector3(0, 0.1, 0.64)
	root.add_child(tail)
	for k in 3:
		var pivot := Node3D.new()
		tail.add_child(pivot)
		pivot.rotation.y = (k - 1) * 0.28
		_bot_box(pivot, Vector3(0.15, 0.03, 0.44), Vector3(0, 0, 0.22),
			dark if k == 1 else plate)

	# Folded talon struts
	for side: float in [-1.0, 1.0]:
		var leg := _bot_box(root, Vector3(0.06, 0.26, 0.06), Vector3(side * 0.14, -0.24, 0.06), dark)
		leg.rotation.x = 0.5
		_bot_box(root, Vector3(0.09, 0.05, 0.18), Vector3(side * 0.14, -0.32, 0.16), plate)

	var jet := _bot_box(root, Vector3(0.18, 0.08, 0.18), Vector3(0, -0.16, 0.3), _bot_glow(Color(0.4, 0.9, 1.0)))
	jet.name = "Jet"
	return root


func _build_ratbot() -> Node3D:
	var root := Node3D.new()
	var plate := _bot_plate()
	var eye := _bot_glow(Color(1.0, 0.35, 0.25))
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.24
	cap.height = 1.1
	cap.material = plate
	body.mesh = cap
	body.rotation.x = PI / 2.0   # lie flat, nose forward
	body.position.y = 0.24
	root.add_child(body)
	_bot_box(root, Vector3(0.24, 0.2, 0.26), Vector3(0, 0.3, -0.52), plate)   # head wedge
	for side: float in [-1.0, 1.0]:
		_bot_box(root, Vector3(0.06, 0.06, 0.06), Vector3(side * 0.07, 0.34, -0.63), eye)
		_bot_box(root, Vector3(0.12, 0.2, 0.5), Vector3(side * 0.26, 0.1, 0.0), plate)  # tread skirts
		# Ear plates
		_bot_box(root, Vector3(0.1, 0.14, 0.03), Vector3(side * 0.11, 0.46, -0.46), plate)
	# Antenna tail with a glowing tip
	_bot_box(root, Vector3(0.03, 0.03, 0.5), Vector3(0, 0.32, 0.62), plate)
	_bot_box(root, Vector3(0.06, 0.06, 0.06), Vector3(0, 0.32, 0.9), eye)
	return root
