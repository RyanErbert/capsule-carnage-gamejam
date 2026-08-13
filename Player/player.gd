extends CharacterBody3D

## Player movement ported from the web version (game.js) — see PORT_BLUEPRINT.md §3.
## Numbers are 1:1 with the web game: 1 unit = 1 m, mass = 1.

# --- Movement (web §1.1 / §3.2) ---
const MOVE_ACCEL := 60.0          # walking force (mass 1 → accel)
const MAX_SPEED := 9.0            # walk speed cap
const SPEED_CAP_LERP_RATE := 5.0  # soft cap approach rate per second
const LINEAR_DAMPING := 0.1       # cannon body damping equivalent
const FLOOR_FRICTION := 6.0       # approximates cannon ground contact friction 0.7
const GRAVITY := 20.0             # web world gravity (not the project default 9.8)
const BOOST_MULT := 2.0           # what a full boost slider adds on top of walking

# --- Ground handling (shared by every movement mode) ---
# A hillside gets steeper by degrees and the handling has to follow it by
# degrees, or the ground drops out from under you at one particular angle:
#   up to FLOOR_ANGLE   you stand on it and steer it
#   up to RIDE_MIN_Y    you no longer stand, but you still roll on the face
#   past that           it is a wall: it stops you, and in monkey ball it bounces
const FLOOR_ANGLE := 58.0    # degrees still counted as ground, not wall
const RIDE_MIN_Y := 0.28     # 74 degrees: past this a face is a wall, not a ride
const GROUND_SNAP := 0.9     # ground this far under a lost floor still holds you
const SNAP_MAX_UP := 7.0     # rising faster than this is a jump, never a crest
const SLOPE_PULL := 1.0      # gravity in the plane of the slope, in full
const LAUNCH_MAX := 20.0     # ceiling on the throw a lip can give you
const CLIMB_RISE := 30.0     # how fast the measured climb rate tracks the ramp
const CLIMB_FADE := 18.0     # ...and how slowly it forgets, in m/s per second
const SLOPE_CAP_Y := 0.95    # steeper than 18 degrees and a walk becomes a ride
const SLOPE_CAP_MULT := 3.0  # ...which may carry this far past run speed, no further
const TURN_RATE := 4.0       # how fast momentum swings onto a new heading
const MB_TURN_RATE := 1.6    # ...and the same in monkey ball, where drift is the point

# --- Jump charge system (web §3.4) ---
const JUMP_IMPULSE := 9.6         # 1.2x the web's 8
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

# (God mode flies a separate drone now — see Player/drone.gd)

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
var spawn_points: Array = []  # optional; respawns pick randomly (web randomSpawn)
# Scene-provided respawn hook (creative: a random point inside YOUR spawn
# zone). Returning null falls through to spawn_points.
var respawn_provider := Callable()
var godmode := false
var vehicle: Node3D = null    # riding: body glued to the seat, collider off
var piloting := false         # flying a machine-animal bot: body stays, idles
var dragging_generator := false  # rope-tied to a generator: heavy slowdown
var dead := false             # Slayer: exploded, waiting out the countdown
var dead_timer := 0.0
var _no_snap := 0.0           # seconds left where the ground may not grab us back
var riding := false           # inside a channel: its wall is our floor (§4.4)
var _builds: Node
var _climb := 0.0             # how fast the ground itself is lifting us, m/s


func respawn_point() -> Vector3:
	if respawn_provider.is_valid():
		var p: Variant = respawn_provider.call()
		if p is Vector3:
			return p
	if not spawn_points.is_empty():
		return spawn_points.pick_random()
	return spawn_position + Vector3(0, 0.5, 0)

# Player model: bear marble (default) or the ported web roundcube.
# Interim selector until the character menu (phase 7): FRIENDSLOP_MODEL=cube
var use_cube := false
var smoothing := 1.0  # sent to the server; bear reads as a full sphere
var _sprint_morph_t := 0.0
var _shell: Node3D    # the glass marble, when we're not playing the cube

@onready var _cube_visual: Node3D = get_node_or_null("CubeVisual")
@onready var _capsule_logic: Node3D = get_node_or_null("CapsuleLogic")
@onready var _items: Node = get_node_or_null("ItemController")


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Ground the engine will actually hold you to. The defaults call anything
	# past 45 degrees a wall, which is what had a rolling ball popping into the
	# air every time it crossed a seam between two terrain triangles.
	floor_max_angle = deg_to_rad(FLOOR_ANGLE)
	floor_snap_length = GROUND_SNAP
	floor_block_on_wall = false
	# Without this, Godot re-slides the velocity onto the surface on every
	# grounded frame, and a body working its way up a ramp bleeds speed to the
	# geometry rather than to gravity. With it on, the only thing that slows a
	# climb is the in-plane gravity the movement code applies itself.
	floor_constant_speed = true
	safe_margin = 0.02
	spawn_position = global_position
	if devInfoLabel:
		devInfoLabel.visible = false
	use_cube = Settings.model == "cube"
	if use_cube and _cube_visual:
		smoothing = IDLE_SMOOTHING
		_cube_visual.visible = true
		_cube_visual.set_color(Settings.color)
		if _capsule_logic:
			_capsule_logic.visible = false
	elif _capsule_logic:
		# Two-tone glass marble around the bear, replacing the plain shell the
		# scene ships with: it rolls, so you can actually see yourself moving.
		var old: Node = _capsule_logic.get_node_or_null("CapsuleModel")
		if old:
			old.visible = false
		_shell = load("res://Player/marble_shell.gd").new()
		_shell.set_color(Settings.color)
		_capsule_logic.add_child(_shell)


## Anything that takes the body out of your hands puts the world's floor back
## under it: a channel's wall is only "down" while you are actually riding.
func _stand_up() -> void:
	riding = false
	up_direction = Vector3.UP


## Multiplayer sync calls this when the oddball holder changes (web: white
## outline hull on the it-player, including yourself).
func set_it(is_it: bool) -> void:
	if use_cube and _cube_visual:
		_cube_visual.set_outline_visible(is_it)


## Riding a vehicle: the body sits on the seat and the vehicle's physics
## drive everything. world_vehicles.gd owns mount/dismount and server sync.
func enter_vehicle(v: Node3D) -> void:
	vehicle = v
	velocity = Vector3.ZERO
	air_time = 0.0
	charging_jump = false
	_stand_up()
	if _items:
		_items.is_grappling = false
	if capsuleCollider:
		capsuleCollider.disabled = true


func exit_vehicle() -> void:
	# Dying in the seat: die_slayer already moved the body to the respawn
	# zone — don't drag the corpse back beside the vehicle or wake its collider
	if dead:
		vehicle = null
		return
	if vehicle and is_instance_valid(vehicle):
		global_position = vehicle.global_position \
			+ vehicle.global_transform.basis.x * 2.2 + Vector3(0, 1.0, 0)
		velocity = vehicle.velocity
	if capsuleCollider:
		capsuleCollider.disabled = false
	vehicle = null


## Self-destruct (K or /kill). Slayer: the server zeroes your health and the
## normal death flow runs (explosion, scorch, countdown). Sandbox: blow up,
## shed score as coins, instant respawn.
func suicide() -> void:
	if godmode or piloting or vehicle != null or dead:
		return
	if bool(Net.game_settings.get("slayer", true)):
		Net.emit_event("suicide")
		return
	Net.emit_event("triggerExplosion", {
		"x": global_position.x, "y": global_position.y, "z": global_position.z,
		"cause": "blast",
	})
	global_position = respawn_point()
	velocity = Vector3.ZERO
	air_time = 0.0


## Slayer death: hide + freeze through the countdown, then pop up at a spawn
## point. The server restores health on its own matching timer.
func die_slayer(respawn_secs: float) -> void:
	if dead:
		return
	dead = true
	dead_timer = respawn_secs
	_stand_up()
	velocity = Vector3.ZERO
	air_time = 0.0
	charging_jump = false
	dragging_generator = false
	if _items:
		_items.is_grappling = false
	visible = false
	if capsuleCollider:
		capsuleCollider.disabled = true
	# Move to the respawn spot now so remotes see one clean jump, not a corpse
	global_position = respawn_point()


func _dead_tick(delta: float) -> void:
	dead_timer -= delta
	if dead_timer <= 0.0:
		dead = false
		visible = true
		if capsuleCollider:
			capsuleCollider.disabled = false
		velocity = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_K \
			and get_viewport().gui_get_focus_owner() == null \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		suicide()


func set_godmode(on: bool) -> void:
	godmode = on
	velocity = Vector3.ZERO
	air_time = 0.0
	charging_jump = false
	_stand_up()
	if _items:
		_items.is_grappling = false


## Remote-piloting a crow-bot/rat-bot: same deal as the drone — the body
## stands here under gravity, fully vulnerable, ignoring input.
func set_piloting(on: bool) -> void:
	piloting = on
	velocity = Vector3.ZERO
	air_time = 0.0
	charging_jump = false
	_stand_up()
	if _items:
		_items.is_grappling = false


## While the god-mode DRONE is out, the body just stands here — under
## gravity, physical, and fully vulnerable. No input reaches it.
func _god_idle(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	var damp := exp(-FLOOR_FRICTION * delta)
	velocity.x *= damp
	velocity.z *= damp
	move_and_slide()


func _physics_process(delta: float) -> void:
	if dead:
		_dead_tick(delta)
		return
	if vehicle != null:
		if is_instance_valid(vehicle):
			global_position = vehicle.seat_pos()
			velocity = vehicle.velocity
			return
		vehicle = null
		if capsuleCollider:
			capsuleCollider.disabled = false
	if godmode or piloting:
		_god_idle(delta)
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

	# Global tuning sliders (Esc menu, server-synced)
	var spd := clampf(float(Net.game_settings.get("speedScale", 0.7)), 0.05, 3.0)
	var acc := clampf(float(Net.game_settings.get("accelScale", 1.0)), 0.05, 3.0)
	var trn := clampf(float(Net.game_settings.get("turnScale", 1.0)), 0.05, 3.0)
	var bst := clampf(float(Net.game_settings.get("boostScale", 1.0)), 0.05, 3.0)
	var jmp := clampf(float(Net.game_settings.get("jumpScale", 0.58)), 0.05, 3.0)
	var grv := clampf(float(Net.game_settings.get("gravityScale", 1.0)), 0.05, 3.0)
	# (dragging the generator slows you via real rope tension — generators.gd)
	var boost := 1.0 + BOOST_MULT * bst if sprinting else 1.0
	_no_snap = maxf(0.0, _no_snap - delta)

	# Riding a channel replaces every other movement mode while it lasts: down
	# is the trough's wall, not the world's floor.
	var ride: Dictionary = _ride_frame() if _no_snap <= 0.0 else {}
	riding = not ride.is_empty()
	if ride.is_empty() and not up_direction.is_equal_approx(Vector3.UP):
		up_direction = Vector3.UP

	if not ride.is_empty():
		_channel_step(delta, wish_dir, typing, ride, acc, boost, grv, jmp, now)
	elif Settings.movement == "source":
		_source_step(delta, wish_dir, typing)
	elif bool(Net.game_settings.get("monkey", true)):
		_monkey_step(delta, wish_dir, typing, spd, acc, trn, boost, grv, jmp, now)
	else:
		# --- Steering: swing the momentum you already have onto the new
		# heading instead of waiting for the accel to cancel it. This is what
		# the turn slider buys, and it is why a ball can corner at speed. ---
		_steer(delta, wish_dir, TURN_RATE * trn)

		# --- Horizontal acceleration ---
		var accel := MOVE_ACCEL * acc * boost
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

		# --- Marble slide: a slope too steep to walk plays like a marble run.
		# Gravity's in-plane component accelerates you downslope, and the soft
		# cap rides up so the momentum CARRIES at the bottom instead of being
		# clipped back to run speed.
		var marble_n := get_wall_normal() if not is_on_floor() and is_on_wall() else Vector3.ZERO
		var marbling := marble_n.y > RIDE_MIN_Y and marble_n.y < 0.95

		# --- Soft speed cap (web §3.2 — keep the lerp; explosions/pads push past it) ---
		var cap_target := MAX_SPEED * spd * boost
		speed_cap = lerpf(speed_cap, cap_target, minf(1.0, SPEED_CAP_LERP_RATE * delta))
		var h_vel := Vector2(velocity.x, velocity.z)
		# A real slope is a ride, not a walk: the cap opens up to whatever you
		# carry, so a trough gives the speed back at the bottom. It opens only
		# so far, though — a long descent used to ratchet this with no ceiling
		# and hand back speeds nothing else in the game could match.
		if marbling or _on_slope(SLOPE_CAP_Y):
			speed_cap = maxf(speed_cap, minf(h_vel.length(), cap_target * SLOPE_CAP_MULT))
		if h_vel.length() > speed_cap and not grappling:  # web: grapple bypasses the cap
			h_vel = h_vel.normalized() * speed_cap
			velocity.x = h_vel.x
			velocity.z = h_vel.y

		# --- Gravity ---
		if not is_on_floor():
			velocity.y -= GRAVITY * grv * delta
		if marbling:
			var down_slope := Vector3.DOWN - marble_n * Vector3.DOWN.dot(marble_n)
			velocity += down_slope * GRAVITY * grv * 0.8 * delta
		_ride_slope(delta, grv)

		_charge_jump(delta, typing, jmp, now)

	# --- Floor snap: off while ascending so jumps aren't eaten ---
	floor_snap_length = 0.0 if velocity.dot(up_direction) > 0.0 or _no_snap > 0.0 \
		else GROUND_SNAP

	# --- Fall respawn (web §1.10: >10 s falling → random spawn) ---
	if not is_on_floor() and velocity.y < 0.0:
		air_time += delta
		if air_time > FALL_RESPAWN_AIRTIME:
			global_position = respawn_point()
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
	elif _shell and is_on_floor():
		_shell.roll(velocity, delta)

	var was_floor := is_on_floor()
	var pre_pos := global_position
	var pre_vel := velocity
	var pre_n := get_floor_normal() if was_floor else up_direction
	move_and_slide()
	_mount_steep(was_floor, pre_vel, pre_n)
	# How fast the ground is actually lifting us. A ramp raises you by MOVING
	# you, never by giving you upward velocity — move_and_slide deletes that on
	# every grounded frame — so this measurement is the only honest record of
	# what the slope gave, and the only number that can hand it back at the lip
	# without inventing energy out of the geometry.
	#
	# It rises with the ramp and fades slowly. An average that tracked both ways
	# got dragged to nothing by the two or three frames where you are already
	# past the lip but the snap has not let go yet — precisely when it is read.
	var lift := (global_position - pre_pos).dot(up_direction) / maxf(delta, 0.0001)
	var target := lift if was_floor else 0.0
	if target >= _climb:
		_climb = lerpf(_climb, target, minf(1.0, CLIMB_RISE * delta))
	else:
		_climb = maxf(target, _climb - CLIMB_FADE * delta)
	_settle_ground(was_floor)
	if bool(Net.game_settings.get("monkey", true)):
		_monkey_bounce(pre_vel)


# --- Channel riding (Items/builds.gd §4.4) ----------------------------------
# Inside a trough the world's floor stops mattering: the wall you are on IS the
# floor, which is what lets a channel loop, bank and climb. Holding boost turns
# one into fast travel.
const CH_HOLD := 0.95      # how hard the trough pins you to itself, x gravity
const CH_ACCEL := 26.0     # push along the run
const CH_SIDE := 26.0      # ...and across it, to climb the wall on purpose
const CH_CENTER := 22.0    # the groove easing you back to the middle
const CH_DRAG := 0.12
const CH_MAX := 75.0


func _ride_frame() -> Dictionary:
	if _builds == null or not is_instance_valid(_builds):
		_builds = get_tree().get_first_node_in_group("world_builds")
	return _builds.ride_frame(global_position) if _builds else {}


func _channel_step(delta: float, wish_dir: Vector3, typing: bool, ride: Dictionary,
		acc: float, boost: float, grv: float, jmp: float, now: float) -> void:
	var t: Vector3 = ride["t"]
	var r: Vector3 = ride["r"]
	var out: Vector3 = global_position - (ride["axis"] as Vector3)
	out -= t * out.dot(t)
	out = out.normalized() if out.length() > 0.001 else -(ride["u"] as Vector3)
	up_direction = -out

	var g := GRAVITY * grv
	velocity += out * (g * CH_HOLD) * delta               # down is the wall
	velocity += t * (Vector3.DOWN.dot(t) * g) * delta      # ...but the run still falls
	velocity -= r * (out.dot(r) * CH_CENTER) * delta       # and the groove holds you
	velocity += t * (wish_dir.dot(t) * CH_ACCEL * acc * boost) * delta
	velocity += r * (wish_dir.dot(r) * CH_SIDE * acc) * delta

	velocity *= exp(-CH_DRAG * delta)
	if velocity.length() > CH_MAX:
		velocity = velocity.normalized() * CH_MAX
	speed_cap = maxf(speed_cap, Vector2(velocity.x, velocity.z).length())
	_charge_jump(delta, typing, jmp, now)


# --- Ground handling, shared by every movement mode ------------------------

## Something threw us — a jump, a pad, a blast. Hands off for a moment: the
## ground snap must not reel us straight back in.
func launched(secs := 0.3) -> void:
	_no_snap = maxf(_no_snap, secs)


func _on_slope(min_y := 0.985) -> bool:
	return is_on_floor() and get_floor_normal().y < min_y


## Swing the momentum you already carry onto the heading you are asking for.
## Without this a ball at speed can only turn as fast as the accel can cancel
## what it had, which reads as stiff no matter how strong the accel is.
func _steer(delta: float, wish_dir: Vector3, rate: float) -> void:
	if wish_dir.length_squared() < 0.0001:
		return
	var h := Vector3(velocity.x, 0.0, velocity.z)
	var speed := h.length()
	if speed < 0.6:
		return
	var swung := h.lerp(wish_dir.normalized() * speed, minf(1.0, rate * delta))
	if swung.length() < 0.001:
		return
	# The lerp cuts the corner and loses length; give most of it back, so
	# cornering costs a little speed instead of scrubbing it all off.
	swung = swung.normalized() * lerpf(swung.length(), speed, 0.8)
	velocity.x = swung.x
	velocity.z = swung.z


## Gravity in the plane of the ground you are standing on. A trough takes speed
## off you on the way up and hands it back on the way down, which is the whole
## reason a fully-carved half-pipe can throw you over the lip.
func _ride_slope(delta: float, grv: float) -> void:
	if not _on_slope():
		return
	var n := get_floor_normal()
	velocity += (Vector3.DOWN - n * Vector3.DOWN.dot(n)) * GRAVITY * grv * SLOPE_PULL * delta


## The moment a grounded body meets anything past floor_max_angle, Godot cancels
## the WHOLE component of the velocity pointing into it — right for a walker
## meeting a wall, and a dead stop for a ball rolling up a hillside that has
## merely got steeper than FLOOR_ANGLE. It cost 22 m/s in a single frame on a
## curve that only steepens by a degree per metre.
##
## So mount it instead. Anything still shallow enough to ride takes the speed
## onto its face and we go up it as a body in contact, with gravity doing what
## gravity does. Nothing special happens at 58 degrees, or at any other angle:
## the hillside just keeps steepening until it is a wall.
func _mount_steep(was_floor: bool, pre_vel: Vector3, pre_n: Vector3) -> void:
	# Only a body Godot considers grounded gets its velocity cancelled like
	# this. In the air an ordinary slide is already the right answer, and the
	# rebuild below would turn a fall into a climb.
	if not was_floor or _no_snap > 0.0:
		return
	var speed := pre_vel.length()
	# A quarter of the speed gone inside one frame is 1300 m/s2. No force in the
	# game does that; only the wall cancel does.
	if speed < 2.0 or velocity.length() > speed * 0.75:
		return
	# The face that stopped us is the one Godot called a wall. It does not turn
	# up among the slide collisions — those report the floor we were riding —
	# so ask for it by name.
	var faces: Array[Vector3] = []
	if is_on_wall():
		faces.append(get_wall_normal())
	for i in get_slide_collision_count():
		faces.append(get_slide_collision(i).get_normal())
	# The velocity we were handed points the wrong way: every grounded frame
	# flattens it onto the horizontal. Only its LENGTH survives that, so put it
	# back up the slope we were actually riding before turning it onto the new
	# face. Then a hillside that steepens smoothly costs nothing, while running
	# flat out into a sudden kink still sheds what the kink takes.
	var real := pre_vel - pre_n * pre_vel.dot(pre_n)
	real = real.normalized() * speed if real.length() > 0.001 else pre_vel
	for n in faces:
		var up_dot := n.dot(up_direction)
		if up_dot >= cos(deg_to_rad(FLOOR_ANGLE)) or up_dot <= RIDE_MIN_Y:
			continue                 # a floor we can hold, or a wall we cannot
		var along := real - n * real.dot(n)
		if along.length() < 0.5:
			continue
		velocity = along
		floor_snap_length = 0.0
		launched(0.1)                # the snap must not reel us straight back down
		return


## Off the lip, hand back exactly the climb the ramp was measured to have. It
## used to be reconstructed as |h|·tan t from the last floor normal, which is
## the same number only if |velocity| is the horizontal speed — it is the speed
## ALONG the surface, so that overpaid by 1/cos t, and at the steep end of
## FLOOR_ANGLE it overpaid by nearly double. Measuring the lift cannot do that.
func _ramp_launch() -> void:
	if _climb < 1.5:
		return                       # flat ground, or too slow to be a launch
	velocity += up_direction * minf(_climb, LAUNCH_MAX)
	_climb = 0.0
	launched(0.2)


## Crossing the crest of a ramp must not throw you; leaving the lip of a
## half-pipe must; and rolling into a face too steep to stand on must do
## neither. Only open air past the lip is a launch — treating a steep face as
## one is what made a gradual cliffside throw you into the sky on every pass.
func _settle_ground(was_floor: bool) -> void:
	if is_on_floor() or not was_floor or _no_snap > 0.0 \
			or velocity.dot(up_direction) > SNAP_MAX_UP:
		return
	var down := -up_direction
	var floor_dot := cos(deg_to_rad(FLOOR_ANGLE))
	# Probe where we are ABOUT to be, not where we are. A crest still has deck
	# in front of it and a lip has nothing, and that is the whole difference
	# between being reeled back down and being thrown.
	var h := velocity - up_direction * velocity.dot(up_direction)
	var ahead := global_transform
	if h.length() > 1.0:
		ahead = ahead.translated(h.normalized() * clampf(h.length() * 0.05, 0.35, 1.2))
	var probe := KinematicCollision3D.new()
	if not test_move(ahead, down * GROUND_SNAP, probe):
		_ramp_launch()   # nothing ahead: the ramp ran out and the climb carries
		return
	if probe.get_normal().dot(up_direction) < floor_dot:
		return           # a steeper face is a hill to keep climbing, not a lip
	var hit := KinematicCollision3D.new()
	if not test_move(global_transform, down * GROUND_SNAP, hit) \
			or hit.get_normal().dot(up_direction) < floor_dot:
		return
	global_position += down * hit.get_travel().length()
	var n := hit.get_normal()
	var speed := velocity.length()
	var along := velocity - n * velocity.dot(n)
	velocity = along.normalized() * speed if along.length() > 0.001 else Vector3.ZERO
	apply_floor_snap()


## Leave the ground. Standing on the world it is a plain vertical set, the way
## the web game did it; inside a channel it fires off whatever wall you are on.
func _jump_impulse(speed: float) -> void:
	if up_direction.is_equal_approx(Vector3.UP):
		velocity.y = speed
	else:
		velocity += up_direction * speed


## Jump: hold to charge, release to fire (web §3.4). Shared by the default
## movement and by Monkey Ball, which keeps the jump it never had.
func _charge_jump(delta: float, typing: bool, jmp: float, now: float) -> void:
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
			_jump_impulse(JUMP_IMPULSE * jump_charge * jmp)
			jump_cooldown = jump_charge
			jump_cooldown_max = jump_charge
			last_grounded_time = -1000.0
			launched()
			Sfx.jump(global_position)
			Net.emit_event("jump")  # others hear it via playerJumped
		else:
			jump_buffer = JUMP_BUFFER_TIME
		jump_charge = 1.0

	# Buffered jump fires flat on landing (web: velocity.y = 8, 1 s cooldown)
	if jump_buffer > 0.0 and is_on_floor() and jump_cooldown <= 0.0:
		_jump_impulse(JUMP_IMPULSE * jmp)
		jump_cooldown = 1.0
		jump_cooldown_max = 1.0
		jump_buffer = 0.0
		last_grounded_time = -1000.0
		launched()
		Sfx.jump(global_position)
		Net.emit_event("jump")


# --- Monkey Ball (gameSettings.monkey) ---------------------------------------
# You never push the ball. The stick TILTS THE WORLD under it and gravity does
# the rest, which is why the feel is all momentum: slow to wind up, slow to
# shed, and a slope is free speed instead of something to walk down.
# Reference: github.com/sndrec/WebMonkeyBall.
const MB_TILT := 0.401     # 23 degrees: how far the stage leans at full stick
const MB_ROLL := 0.714     # 5/7 — a solid sphere rolling, not a box sliding
const MB_DRAG := 0.25      # rolling resistance per second: barely there
const MB_AIR := 0.16       # how much of the lean survives once you leave the floor
const MB_TOP := 6.0        # terminal speed as a multiple of the walk cap
const MB_BOUNCE := 0.42    # how much of the impact a wall too steep to hold gives back
const MB_BOUNCE_MIN := 9.0 # ...and how hard you have to hit it before it does


func _monkey_step(delta: float, wish_dir: Vector3, typing: bool, spd: float,
		acc: float, trn: float, boost: float, grv: float, jmp: float, now: float) -> void:
	var g := GRAVITY * grv
	var grounded := is_on_floor()
	var n := get_floor_normal() if grounded else Vector3.UP
	if n.length_squared() < 0.5:
		n = Vector3.UP
	# A hill too steep to stand on is still a hill to roll on. Without this the
	# floor drops out from under you at one exact angle and the ball goes into
	# freefall against a face it is plainly still touching, which is what made
	# climbing a gradual cliffside feel like hitting a cliff.
	var facing := false
	if not grounded and is_on_wall():
		var wn := get_wall_normal()
		if wn.y > RIDE_MIN_Y and wn.y < 0.95:
			n = wn
			facing = true
	_steer(delta, wish_dir, MB_TURN_RATE * trn)
	var lean := wish_dir.length()
	var accel := Vector3.ZERO
	if lean > 0.001:
		# Holding boost leans the stage harder — the only way to lean it is the
		# stick, so that is where a speed boost has to live.
		var tilt := minf(1.4, MB_TILT * lean * boost)
		accel = (wish_dir / lean) * (MB_ROLL * g * sin(tilt) * acc)
	if grounded:
		accel -= n * accel.dot(n)               # the lean rides the floor plane
		accel += (Vector3.DOWN - n * Vector3.DOWN.dot(n)) * (MB_ROLL * g)
	elif facing:
		accel -= n * accel.dot(n)   # still gripping, so the lean keeps its full say
		velocity.y -= g * delta     # ...and the slide down the face is gravity's
	else:
		accel *= MB_AIR
		velocity.y -= g * delta
	velocity += accel * delta

	if grounded or facing:
		var damp := exp(-MB_DRAG * delta)
		velocity.x *= damp
		velocity.z *= damp
	var top := MAX_SPEED * spd * MB_TOP * boost
	var h := Vector2(velocity.x, velocity.z)
	if h.length() > top:
		h = h.normalized() * top
		velocity.x = h.x
		velocity.z = h.y
	# Nothing else may clip this back to run speed: the speed IS the mode.
	speed_cap = maxf(h.length(), MAX_SPEED)
	_charge_jump(delta, typing, jmp, now)


## Roll into a face the ball has no chance of holding — a kerb, the side of a
## ramp, a wall you met at an angle — and it kicks back at you with sparks,
## instead of the silent full stop a slide gives you. Anything shallower than
## RIDE_MIN_Y is a face you can still roll on, so it gets ridden, not bounced.
func _monkey_bounce(pre_vel: Vector3) -> void:
	var floor_n := get_floor_normal() if is_on_floor() else up_direction
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var n := c.get_normal()
		if n.dot(floor_n) > 0.72 or n.dot(up_direction) > RIDE_MIN_Y:
			continue                       # riding it, one way or the other
		var hit_speed := -pre_vel.dot(n)   # how much of the run went into the face
		if hit_speed < MB_BOUNCE_MIN:
			continue
		velocity += n * (hit_speed * MB_BOUNCE)
		launched(0.12)
		Sfx.boost(c.get_position(), 0.35)
		_sparks(c.get_position(), n)
		return


func _sparks(at: Vector3, n: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.top_level = true
	p.emitting = false
	p.one_shot = true
	p.amount = 14
	p.lifetime = 0.45
	p.explosiveness = 1.0
	p.direction = n
	p.spread = 42.0
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 13.0
	p.gravity = Vector3(0, -22, 0)
	p.scale_amount_min = 0.05
	p.scale_amount_max = 0.12
	p.color = Color(1.0, 0.86, 0.45)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	var box := BoxMesh.new()
	box.size = Vector3(0.06, 0.06, 0.34)
	box.material = mat
	p.mesh = box
	add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(1.0).timeout.connect(p.queue_free)


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


# (POS/VEL/SPD debug readout removed — the HUD's connection pill replaced it)
