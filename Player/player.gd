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


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	spawn_position = global_position


func _physics_process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if is_on_floor():
		last_grounded_time = now

	# --- Input (camera-relative, like the web's camera.getWorldDirection) ---
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var cam_yaw: float = camera_rig.yaw if camera_rig else 0.0
	var forward := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
	var right := Vector3(-forward.z, 0, forward.x)
	var wish_dir := (right * input_dir.x - forward * input_dir.y).limit_length(1.0)
	var input_mag := wish_dir.length()

	# --- Sprint stamina ---
	var wants_sprint := Input.is_action_pressed("sprint") and input_mag > 0.0
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
	if h_vel.length() > speed_cap:
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

	if Input.is_action_pressed("jump") and jump_cooldown <= 0.0:
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

	_update_dev_info()
	move_and_slide()


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
