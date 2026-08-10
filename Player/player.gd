extends CharacterBody3D

## Player movement ported from the web version (game.js) — see PORT_BLUEPRINT.md §3.
## Numbers are 1:1 with the web game: 1 unit = 1 m, mass = 1.

# --- Movement (web §1.1 / §3.2) ---
const MOVE_ACCEL := 60.0          # walking force (mass 1 → accel)
const SPRINT_ACCEL := 120.0
const MAX_SPEED := 9.0            # walk speed cap
const SPRINT_SPEED := 18.0        # sprint speed cap
const SPEED_CAP_LERP_RATE := 2.5  # soft cap approach rate per second
const LINEAR_DAMPING := 0.1       # cannon body damping equivalent
const FLOOR_FRICTION := 6.0       # approximates cannon ground contact friction 0.7
const GRAVITY := 20.0             # web world gravity (not the project default 9.8)

# --- Jump charge system (web §3.4) ---
const JUMP_IMPULSE := 8.0
const CHARGE_RATE := 3.0          # charge multiplier growth per second held
const MAX_CHARGE_MULT := 4.0
const COYOTE_TIME := 0.28
const JUMP_BUFFER_TIME := 0.25

# --- Sprint stamina (web §1.1 / §3.3) ---
const SPRINT_DURATION := 4.0      # seconds of stamina
const SPRINT_REFILL_TIME := 6.0   # empty → full

# --- Fall respawn (web §1.10) ---
const FALL_RESPAWN_AIRTIME := 10.0

# --- Roundcube ball morph (web: sprintMorphT ±3/s, smoothing 0.25 -> 1.0) ---
const MORPH_RATE := 3.0
const IDLE_SMOOTHING := 0.25

# --- God mode (web §6.8: free-fly at 40, no gravity/collisions) ---
const GOD_FLY_SPEED := 40.0

# --- Source-style movement (Settings.movement == "source") ---
# 1:1 port of the Source SDK ground-friction / Accelerate / AirAccelerate
# step (gamemovement.cpp lineage — the same math GoldGdt recreates), scaled
# at SRC_U meters per Hammer unit so the 320 HU/s run speed lands on this
# map's 18 u/s sprint. Bunny-hopping and air-strafing work: friction is
# skipped on the frame you jump, and there is no horizontal speed cap.
const SRC_U := 0.05625
const SRC_GRAVITY := 800.0 * SRC_U       # 45.0
const SRC_FRICTION := 4.0
const SRC_STOPSPEED := 100.0 * SRC_U     # 5.625
const SRC_ACCEL := 10.0
const SRC_AIRACCEL := 10.0
const SRC_AIRCAP := 30.0 * SRC_U         # 1.6875 — the air-strafe magic number
const SRC_WALKSPEED := 190.0 * SRC_U     # 10.7
const SRC_RUNSPEED := 320.0 * SRC_U      # 18.0
const SRC_JUMP := 268.3 * SRC_U          # 15.1 (sqrt(2*800*45) HU/s)

@export var camera_rig: Node3D
@export var capsuleCollider: CollisionShape3D
@export var devInfoLabel: Label

var speed_cap := MAX_SPEED
var sprinting := false
var sprint_stamina := SPRINT_DURATION
var sprint_exhausted := false

var jump_charge := 1.0
var charging_jump := false
var jump_cooldown := 0.0
var jump_cooldown_max := 1.0
var jump_buffer := 0.0
var last_grounded_time := -1000.0

var air_time := 0.0
var spawn_position := Vector3.ZERO
var godmode := false

# Player model: bear marble (default) or the ported web roundcube.
# Interim selector until the character menu (phase 7): FRIENDSLOP_MODEL=cube
var use_cube := false
var smoothing := 1.0  # sent to the server; bear reads as a full sphere
var _sprint_morph_t := 0.0

@onready var _cube_visual: Node3D = get_node_or_null("CubeVisual")
@onready var _capsule_logic: Node3D = get_node_or_null("CapsuleLogic")
@onready var _items: Node = get_node_or_null("ItemController")


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	spawn_position = global_position
	use_cube = Settings.model == "cube"
	if use_cube and _cube_visual:
		smoothing = IDLE_SMOOTHING
		_cube_visual.visible = true
		_cube_visual.set_color(Settings.color)
		if _capsule_logic:
			_capsule_logic.visible = false


## Multiplayer sync calls this when the oddball holder changes (web: white
## outline hull on the it-player, including yourself).
func set_it(is_it: bool) -> void:
	if use_cube and _cube_visual:
		_cube_visual.set_outline_visible(is_it)


func set_godmode(on: bool) -> void:
	godmode = on
	velocity = Vector3.ZERO
	air_time = 0.0
	charging_jump = false
	if _items:
		_items.is_grappling = false


## Free-fly: WASD camera-relative, Space/E up, Shift/Q down (web fly @ 40).
func _god_fly(delta: float) -> void:
	if get_viewport().gui_get_focus_owner() != null:
		return
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var cam_yaw: float = camera_rig.yaw if camera_rig else 0.0
	var forward := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
	var right := Vector3(-forward.z, 0, forward.x)
	var dir := right * input_dir.x - forward * input_dir.y
	if Input.is_action_pressed("jump") or Input.is_key_pressed(KEY_E):
		dir.y += 1.0
	if Input.is_action_pressed("sprint") or Input.is_key_pressed(KEY_Q):
		dir.y -= 1.0
	global_position += dir.limit_length(1.0) * GOD_FLY_SPEED * delta


func _physics_process(delta: float) -> void:
	if godmode:
		_god_fly(delta)
		_update_dev_info()
		return

	var now := Time.get_ticks_msec() / 1000.0
	if is_on_floor():
		last_grounded_time = now

	# --- Input (camera-relative, like the web's camera.getWorldDirection) ---
	# Ignore gameplay keys while a Control (chat input) has keyboard focus.
	var typing := get_viewport().gui_get_focus_owner() != null
	var input_dir := Vector2.ZERO if typing else Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var cam_yaw: float = camera_rig.yaw if camera_rig else 0.0
	var forward := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
	var right := Vector3(-forward.z, 0, forward.x)
	var wish_dir := (right * input_dir.x - forward * input_dir.y).limit_length(1.0)
	var input_mag := wish_dir.length()

	# --- Sprint stamina ---
	var wants_sprint := not typing and Input.is_action_pressed("sprint") and input_mag > 0.0
	sprinting = wants_sprint and not sprint_exhausted
	if sprinting:
		sprint_stamina = maxf(0.0, sprint_stamina - delta)
		if sprint_stamina <= 0.0:
			sprint_exhausted = true
			sprinting = false
	else:
		sprint_stamina = minf(SPRINT_DURATION, sprint_stamina + (SPRINT_DURATION / SPRINT_REFILL_TIME) * delta)
		if sprint_exhausted and sprint_stamina >= SPRINT_DURATION:
			sprint_exhausted = false

	var grappling: bool = _items != null and _items.is_grappling

	if Settings.movement == "source":
		_source_step(delta, wish_dir, typing)
	else:
		# --- Horizontal acceleration ---
		var accel := SPRINT_ACCEL if sprinting else MOVE_ACCEL
		velocity.x += wish_dir.x * accel * delta
		velocity.z += wish_dir.z * accel * delta

		# --- Damping (cannon linearDamping 0.1 on all axes) ---
		var damp := exp(-LINEAR_DAMPING * delta)
		velocity.x *= damp
		velocity.z *= damp

		# --- Ground friction when idle (approximates contact friction 0.7) ---
		if is_on_floor() and input_mag == 0.0:
			var floor_damp := exp(-FLOOR_FRICTION * delta)
			velocity.x *= floor_damp
			velocity.z *= floor_damp

		# --- Soft speed cap (web §3.2 — keep the lerp; explosions/pads push past it) ---
		var cap_target := SPRINT_SPEED if sprinting else MAX_SPEED
		speed_cap = lerpf(speed_cap, cap_target, minf(1.0, SPEED_CAP_LERP_RATE * delta))
		var h_vel := Vector2(velocity.x, velocity.z)
		if h_vel.length() > speed_cap and not grappling:  # web: grapple bypasses the cap
			h_vel = h_vel.normalized() * speed_cap
			velocity.x = h_vel.x
			velocity.z = h_vel.y

		# --- Gravity ---
		if not is_on_floor():
			velocity.y -= GRAVITY * delta

		# --- Jump: hold to charge, release to fire (web §3.4) ---
		jump_cooldown = maxf(0.0, jump_cooldown - delta)
		jump_buffer = maxf(0.0, jump_buffer - delta)
		var can_jump := (now - last_grounded_time) < COYOTE_TIME

		if not typing and Input.is_action_pressed("jump") and jump_cooldown <= 0.0:
			if not charging_jump:
				charging_jump = true
				jump_charge = 1.0
			jump_charge = minf(MAX_CHARGE_MULT, jump_charge + CHARGE_RATE * delta)
		elif charging_jump:
			charging_jump = false
			if can_jump:
				velocity.y = JUMP_IMPULSE * jump_charge
				jump_cooldown = jump_charge
				jump_cooldown_max = jump_charge
				last_grounded_time = -1000.0
				Sfx.jump(global_position)
				Net.emit_event("jump")  # others hear it via playerJumped
			else:
				jump_buffer = JUMP_BUFFER_TIME
			jump_charge = 1.0

		# Buffered jump fires flat on landing (web: velocity.y = 8, 1 s cooldown)
		if jump_buffer > 0.0 and is_on_floor() and jump_cooldown <= 0.0:
			velocity.y = JUMP_IMPULSE
			jump_cooldown = 1.0
			jump_cooldown_max = 1.0
			jump_buffer = 0.0
			last_grounded_time = -1000.0
			Sfx.jump(global_position)
			Net.emit_event("jump")

	# --- Floor snap: off while ascending so jumps aren't eaten ---
	floor_snap_length = 0.0 if velocity.y > 0.0 else 0.3

	# --- Fall respawn (web §1.10: >10 s falling → random spawn) ---
	if not is_on_floor() and velocity.y < 0.0:
		air_time += delta
		if air_time > FALL_RESPAWN_AIRTIME:
			global_position = spawn_position + Vector3(0, 0.5, 0)
			velocity = Vector3.ZERO
			air_time = 0.0
	else:
		air_time = 0.0

	# --- Grapple (web §4.8): velocity set directly to dir*40, all axes; ---
	# release when close (<2), on jump press, or with a buffered jump.
	if grappling:
		var to_target: Vector3 = _items.grapple_target - global_position
		if to_target.length() < 2.0 or (not typing and Input.is_action_pressed("jump")) or jump_buffer > 0.0:
			_items.is_grappling = false
		else:
			velocity = to_target.normalized() * _items.GRAPPLE_SPEED

	# --- Roundcube ball morph while sprinting (web updateSprintMorph) ---
	if use_cube and _cube_visual:
		_sprint_morph_t = clampf(_sprint_morph_t + (MORPH_RATE if sprinting else -MORPH_RATE) * delta, 0.0, 1.0)
		smoothing = IDLE_SMOOTHING + (1.0 - IDLE_SMOOTHING) * _sprint_morph_t
		_cube_visual.set_smoothing(smoothing)

		# Roll with movement like the web's cannon body did: rolling without
		# slipping, ω = v/r around the axis perpendicular to travel.
		var h_roll := Vector3(velocity.x, 0.0, velocity.z)
		if h_roll.length() > 0.3 and is_on_floor():
			var axis := Vector3.UP.cross(h_roll.normalized()).normalized()
			_cube_visual.global_rotate(axis, (h_roll.length() / 0.5) * delta)

	_update_dev_info()
	move_and_slide()


## One tick of Source movement: gravity, hop, friction, accelerate.
## Hold Space to auto-hop on landing — the friction step is skipped on jump
## frames, which is exactly what makes bunny-hopping conserve speed.
func _source_step(delta: float, wish_dir: Vector3, typing: bool) -> void:
	charging_jump = false
	jump_cooldown = maxf(0.0, jump_cooldown - delta)
	if not is_on_floor():
		velocity.y -= SRC_GRAVITY * delta
	elif not typing and Input.is_action_pressed("jump") and jump_cooldown <= 0.0:
		velocity.y = SRC_JUMP
		jump_cooldown = 0.1  # debounce so one landing = one hop
		jump_cooldown_max = 0.1
		Sfx.jump(global_position)
		Net.emit_event("jump")
	else:
		_source_friction(delta)

	var maxspeed := SRC_RUNSPEED if sprinting else SRC_WALKSPEED
	var wish_speed := wish_dir.length() * maxspeed
	if wish_speed > 0.001:
		var dirn := wish_dir.normalized()
		if is_on_floor():
			_source_accelerate(dirn, wish_speed, wish_speed, SRC_ACCEL, delta)
		else:
			_source_accelerate(dirn, wish_speed, SRC_AIRCAP, SRC_AIRACCEL, delta)


func _source_friction(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < 0.001:
		return
	var control := maxf(speed, SRC_STOPSPEED)
	var drop := control * SRC_FRICTION * delta
	var scale := maxf(speed - drop, 0.0) / speed
	velocity.x *= scale
	velocity.z *= scale


## Source's Accelerate/AirAccelerate quirk, kept intact: the ADD limit uses
## the capped wishspeed, but the acceleration RATE uses the uncapped one.
func _source_accelerate(wishdir: Vector3, wish_speed: float, cap: float, accel: float, delta: float) -> void:
	var wishspd := minf(wish_speed, cap)
	var current := velocity.x * wishdir.x + velocity.z * wishdir.z
	var add_speed := wishspd - current
	if add_speed <= 0.0:
		return
	var accel_speed := minf(accel * wish_speed * delta, add_speed)
	velocity.x += accel_speed * wishdir.x
	velocity.z += accel_speed * wishdir.z


## Rotation sent over the network: the rolling cube's orientation when
## playing the cube, else the body (bears don't tumble in their marble).
func visual_quat() -> Quaternion:
	if use_cube and _cube_visual:
		return _cube_visual.global_transform.basis.get_rotation_quaternion()
	return global_transform.basis.get_rotation_quaternion()


func _update_dev_info() -> void:
	if not devInfoLabel:
		return
	devInfoLabel.text = "POS x:%.2f y:%.2f z:%.2f\nVEL x:%.2f y:%.2f z:%.2f\nSPD %.1f / cap %.1f%s\nSTAMINA %.1f%s   CHARGE %.2f   CD %.1f" % [
		position.x, position.y, position.z,
		velocity.x, velocity.y, velocity.z,
		Vector2(velocity.x, velocity.z).length(), speed_cap,
		" SPRINT" if sprinting else "",
		sprint_stamina, " EXHAUSTED" if sprint_exhausted else "",
		jump_charge, jump_cooldown,
	]
