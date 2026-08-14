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

# --- Contact, which is all there is instead of floor and wall ---------------
# There is no wall. The body runs in MOTION_MODE_FLOATING, where Godot has no
# floor, no wall and no ceiling: it never flattens the velocity, never snaps,
# and never cancels a run into a slope. Contact is ours, and it is one rule at
# every angle — A SURFACE CAN PUSH, IT CAN NEVER PULL. Holding you up on the
# flat, accelerating you downhill, throwing you off a lip and stopping you dead
# against something vertical are all that one line plus ordinary gravity, so
# nothing whatsoever happens at 45 degrees, or 58, or any other number.
#
# GROUND_ANGLE survives only as a LABEL, for the handful of things that really
# do need one: jumping, idle friction, the rolling animation.
const GROUND_ANGLE := 58.0   # degrees flat enough to call yourself standing
const GROUND_SNAP := 0.9     # ground this far under a lost contact still holds you
const SNAP_MAX_UP := 9.0     # rising faster than this is a throw, never a crest
const GROUND_LIFT_MAX := 2.5 # m/s of upward velocity one contact frame may add
const SLOPE_CAP_Y := 0.95    # steeper than 18 degrees and a walk becomes a ride
const SLOPE_CAP_MULT := 3.0  # ...which may carry this far past run speed, no further
const TURN_RATE := 4.0       # how fast momentum swings onto a new heading

# --- Grapple: the hook is an anchor, not a destination ---
const GRAPPLE_PULL := 26.0   # how hard the rope hauls you along its own line
const GRAPPLE_REEL := 2.0    # ...and how fast it shortens while you hold on
const GRAPPLE_TAUT := 45.0   # the snap back when a swing tries to stretch it
const GRAPPLE_MIN := 1.6     # arrived: any closer and it lets go on its own
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
var touching := false         # in contact with a surface, at any angle at all
var grounded := false         # ...and it is flat enough to stand on and jump from
var _surf_n := Vector3.UP     # the most supporting surface we are touching
var _pop_cd := 0.0            # rate limit on the ejection report
var _bounce_cd := 0.0         # so one hard face cannot kick you over and over
var _kick_cd := 0.0           # rate limit on the upward-velocity report
var _loop_age := 0.0          # how long the current bouncing-on-the-spot window is
var _loop_takeoffs := 0       # ...and how many times we have left the ground in it
var _loop_gain := 0.0
var _loop_cd := 0.0
var _stick_cd := 0.0          # rate limit on the ground-snap report
var _stick_grace := 0.0       # seconds the reel may keep closing a gap for
var _pop_total := 0           # ...and how many there have been in total
var _pop_logged := 0          # lines written to user://pop.log this session
var _rope_len := 0.0          # what the grapple was paid out to when it bit
var _jump_eaten := false      # the press that let go of a rope must not jump


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
	# No floor, no wall, no ceiling — see the contact block at the top. Godot's
	# grounded mode DELETES the vertical velocity of anything it decides is
	# standing on a floor (measured: a body on a 70 degree face slid 0.15 m in a
	# whole second and ended at vy 0.00), which is what forces a threshold angle
	# to exist at all. Floating mode has no such opinion, so neither do we.
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	# Floating mode still refuses to slide along anything it meets closer to
	# head-on than this, and stops dead instead. A marble always slides.
	wall_min_slide_angle = 0.0
	safe_margin = 0.02
	spawn_position = global_position
	_log_session()
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
	_rope_len = 0.0
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
	velocity.y -= GRAVITY * delta
	var damp := exp(-FLOOR_FRICTION * delta)
	velocity.x *= damp
	velocity.z *= damp
	var was_touching := touching
	move_and_slide()
	_resolve_contact()
	_stick(was_touching)


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
	if grounded:
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
	_bounce_cd = maxf(0.0, _bounce_cd - delta)
	_kick_cd = maxf(0.0, _kick_cd - delta)
	_loop_cd = maxf(0.0, _loop_cd - delta)
	_stick_cd = maxf(0.0, _stick_cd - delta)

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
		if grounded and input_mag == 0.0:
			var floor_damp := exp(-FLOOR_FRICTION * delta)
			velocity.x *= floor_damp
			velocity.z *= floor_damp

		# --- Soft speed cap (web §3.2 — keep the lerp; explosions/pads push past it) ---
		var cap_target := MAX_SPEED * spd * boost
		speed_cap = lerpf(speed_cap, cap_target, minf(1.0, SPEED_CAP_LERP_RATE * delta))
		var h_vel := Vector2(velocity.x, velocity.z)
		# A real slope is a ride, not a walk: the cap opens up to whatever you
		# carry, so a trough gives the speed back at the bottom. It opens only
		# so far, though — a long descent used to ratchet this with no ceiling
		# and hand back speeds nothing else in the game could match.
		if touching and _surf_n.y < SLOPE_CAP_Y:
			speed_cap = maxf(speed_cap, minf(h_vel.length(), cap_target * SLOPE_CAP_MULT))
		if h_vel.length() > speed_cap and not grappling:  # web: grapple bypasses the cap
			h_vel = h_vel.normalized() * speed_cap
			velocity.x = h_vel.x
			velocity.z = h_vel.y

		# --- Gravity, whole and unconditional. The contact takes back exactly
		# the part of it the ground is holding up, and what survives is the run
		# downhill — at every angle, with no case for any of them.
		velocity.y -= GRAVITY * grv * delta

		_charge_jump(delta, typing, jmp, now)

	# --- Fall respawn (web §1.10: >10 s falling → random spawn) ---
	if not touching and velocity.y < 0.0:
		air_time += delta
		if air_time > FALL_RESPAWN_AIRTIME:
			global_position = respawn_point()
			velocity = Vector3.ZERO
			air_time = 0.0
	else:
		air_time = 0.0

	# --- Grapple (web §4.8, rewritten): a rope, not a rail ---
	if grappling:
		if not typing and Input.is_action_pressed("jump"):
			_items.is_grappling = false
			_jump_eaten = true       # this press let go; it does not also jump
			jump_buffer = 0.0
			charging_jump = false
		else:
			_grapple_swing(delta)
	elif _rope_len > 0.0:
		_rope_len = 0.0

	# --- Roundcube ball morph while sprinting (web updateSprintMorph) ---
	if use_cube and _cube_visual:
		_sprint_morph_t = clampf(_sprint_morph_t + (MORPH_RATE if sprinting else -MORPH_RATE) * delta, 0.0, 1.0)
		smoothing = IDLE_SMOOTHING + (1.0 - IDLE_SMOOTHING) * _sprint_morph_t
		_cube_visual.set_smoothing(smoothing)

		# Roll with movement like the web's cannon body did: rolling without
		# slipping, ω = v/r around the axis perpendicular to travel.
		var h_roll := Vector3(velocity.x, 0.0, velocity.z)
		if h_roll.length() > 0.3 and grounded:
			var axis := Vector3.UP.cross(h_roll.normalized()).normalized()
			_cube_visual.global_rotate(axis, (h_roll.length() / 0.5) * delta)
	elif _shell and touching:
		_shell.roll(velocity, delta)

	var was_touching := touching
	var was_grounded := grounded
	var pre_pos := global_position
	var pre_vel := velocity
	var pre_n := _surf_n
	move_and_slide()
	# Floating mode slides the MOTION but leaves the velocity alone, so the
	# whole of contact is this call. Hitting a face too steep to hold gives some
	# of the impact back instead of just eating it.
	_resolve_contact(_bounce_off(was_touching, pre_vel, pre_n), MB_BOUNCE)
	_curb_ejection(pre_pos, pre_vel, delta)
	_stick(was_touching)
	_watch_loop(delta, was_grounded)


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


## Everything the ground does to you, in one rule at every angle: a surface can
## push, it can never pull. Whatever part of the velocity is driving into a face
## is the part that face cancels — and what is left over is the slide.
##
## That single line replaces floor_max_angle, the wall cancel, the velocity
## flattening, constant floor speed, the ramp launch and the mount. Gravity is
## applied whole and unconditionally by every movement mode; on the flat this
## takes all of it, on a slope it takes the normal part and leaves g·sin(angle)
## running downhill, and at a lip there is nothing to take so you simply carry
## on. Nobody has to know what angle anything is.
##
## `restitution` is how much the surface hands BACK on top of that — 0 for
## ordinary contact, more for a face hit too hard to hold (monkey ball).
## `bounce_n` is the ONE face that earned a restitution, and it gets it alone.
## Handing the scalar to every contact meant that clipping a wall made the floor
## you were standing on 42% bouncy for that frame, so the throw came off the
## GROUND, pointing up, and you landed and it happened again: the repeating
## teleport-up-and-drop, always found next to something steep. A face also only
## gets one impulse however many times move_and_slide lists it.
func _resolve_contact(bounce_n := Vector3.ZERO, restitution := 0.0) -> void:
	var before := velocity
	touching = false
	var best := -2.0
	var bounced := false
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		var into := velocity.dot(n)
		if into < 0.0:
			var give := 0.0
			if not bounced and n.dot(bounce_n) > 0.999:
				give = restitution
				bounced = true
			velocity -= n * (into * (1.0 + give))
		touching = true
		var d := n.dot(up_direction)
		if d > best:
			best = d
			_surf_n = n
	if not touching:
		grounded = false
		_surf_n = up_direction
		return
	grounded = best > cos(deg_to_rad(GROUND_ANGLE))
	# A ball does not track every seam in the ground. Its contact patch averages
	# the micro-relief, so rolling over a 13 degree facet at speed makes it
	# FOLLOW the ground, not leave it. Projecting onto each facet the instant it
	# arrives does the opposite: at 43 m/s that facet tipped 9.2 m/s of the run
	# straight up, which is three metres of air off a bump you can barely see,
	# and then it lands and does it again. So limit how fast contact may turn
	# the run upward. A real ramp is a gradual turn and passes through
	# untouched; a seam is a step change and gets absorbed over a few frames.
	# Measure the lift BEFORE clamping it. Reporting the post-clamp figure meant
	# every kick in the log read `before + 2.5` — the instrument was quoting its
	# own limiter back at me and hiding how hard the ground was actually pushing.
	var raw := velocity.dot(up_direction) - before.dot(up_direction)
	if grounded and _no_snap <= 0.0 and raw > GROUND_LIFT_MAX:
		velocity -= up_direction * (raw - GROUND_LIFT_MAX)
	_watch_kick(before, restitution if bounced else 0.0, raw)


## A body that is already overlapping geometry gets shoved back out, and that
## shove is not something the player earned — it is the one thing that can move
## you further in a frame than your own velocity allows. Sliding cannot: the
## most a collision can take off your intended motion is the motion itself, so
## |displacement - velocity*dt| <= |velocity|*dt on every honest frame. Past
## that is depenetration, and it is what reads as being teleported up a few
## units, dropped, and teleported again. Let it out at a trickle instead: deep
## overlaps still escape, over several frames rather than in one jump.
const EJECT_SLACK := 0.05    # metres per frame of numerical give

func _curb_ejection(pre_pos: Vector3, pre_vel: Vector3, delta: float) -> void:
	var resid := (global_position - pre_pos) - pre_vel * delta
	var over := resid.length()
	var allowed := pre_vel.length() * delta + EJECT_SLACK
	if over <= allowed:
		return
	global_position -= resid * (1.0 - allowed / over)
	_pop_total += 1
	_pop_cd -= delta
	if _pop_cd > 0.0:
		return
	_pop_cd = 0.5
	# What we are overlapping is the whole question, so name it by its place in
	# the tree — that says terrain vs builds vs wfc vs props without guessing.
	var who := ""
	for i in get_slide_collision_count():
		var c: Object = get_slide_collision(i).get_collider()
		if c is Node:
			who += " " + str((c as Node).get_path()).replace("/root/", "")
	_log_pop("[pop] #%d ejected %.2f m (allowed %.2f) at %v dir(%.2f,%.2f,%.2f) |v|%.1f %s hit:%s" % [
		_pop_total, over, allowed, global_position.round(),
		resid.x / over, resid.y / over, resid.z / over, velocity.length(),
		"ground" if grounded else ("face" if touching else "air"), who])


## Both to the editor Output and to user://pop.log, so a session can be read
## back afterwards instead of copied out of a scrolling panel.
const POP_LOG := "user://pop.log"
const POP_LOG_MAX := 200

func _log_pop(text: String) -> void:
	print(text)
	if _pop_logged >= POP_LOG_MAX:
		return
	var f := FileAccess.open(POP_LOG, FileAccess.READ_WRITE) if FileAccess.file_exists(POP_LOG) \
		else FileAccess.open(POP_LOG, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	_pop_logged += 1
	f.store_line(text)
	if _pop_logged == POP_LOG_MAX:
		f.store_line("[log] ...capped at %d lines for this session" % POP_LOG_MAX)
	f.close()


## Written the moment a body spawns, whether or not anything goes wrong, so a
## silent log means "played and nothing fired" rather than "never ran".
func _log_session() -> void:
	var stamp := FileAccess.get_modified_time("res://Player/player.gd")
	_log_pop("=== %s  monkey=%s  %s  player.gd built %s ===" % [
		Time.get_datetime_string_from_system(), Net.game_settings.get("monkey", true),
		Settings.player_name, Time.get_datetime_string_from_unix_time(int(stamp))])


## Where the upward velocity actually comes from. A landing is not this: it ends
## at rest against the floor, not climbing. This is the frame where you were not
## going up and suddenly are, which is what reads as being thrown.
const KICK_MIN := 2.5

func _watch_kick(before: Vector3, restitution: float, raw_lift: float) -> void:
	if before.dot(up_direction) > 0.5 or velocity.dot(up_direction) < KICK_MIN:
		return
	if _kick_cd > 0.0:
		return
	_kick_cd = 0.35
	_log_pop("[kick] +%.1f up (asked %.1f, was %.1f) |v| %.1f -> %.1f  bounce=%.2f  at %v  %s%s" % [
		velocity.dot(up_direction), raw_lift, before.dot(up_direction), before.length(),
		velocity.length(), restitution, global_position.round(),
		"ground" if grounded else ("face" if touching else "air"), _contact_report()])


## Every face we are touching, its angle from upright, and the node it belongs
## to — which is the difference between "a ramp" and "something overlapping me".
func _contact_report() -> String:
	var out := "  %d faces:" % get_slide_collision_count()
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var n := c.get_normal()
		var who: Object = c.get_collider()
		out += " [%.0fdeg n(%.2f,%.2f,%.2f) %s]" % [
			rad_to_deg(acos(clampf(n.dot(up_direction), -1.0, 1.0))), n.x, n.y, n.z,
			str((who as Node).get_path()).replace("/root/", "") if who is Node else "?"]
	return out


## Bouncing on the spot. Standing still and leaving the ground over and over is
## not something the movement code can do on its own, so when it happens, say
## everything about where we are and what is under us.
const LOOP_WINDOW := 3.0     # seconds the takeoffs have to fall within
const LOOP_TAKEOFFS := 3     # ...and how many of them counts as a loop
const LOOP_STILL := 2.5      # horizontal speed below which we are "not moving"

func _watch_loop(delta: float, was_grounded: bool) -> void:
	_loop_age += delta
	if _loop_age > LOOP_WINDOW:
		_loop_age = 0.0
		_loop_takeoffs = 0
		_loop_gain = 0.0
	if Vector2(velocity.x, velocity.z).length() > LOOP_STILL:
		_loop_takeoffs = 0        # actually going somewhere: not a loop
		return
	if was_grounded and not grounded:
		_loop_takeoffs += 1
		_loop_gain = maxf(_loop_gain, velocity.dot(up_direction))
	if _loop_takeoffs < LOOP_TAKEOFFS or _loop_cd > 0.0:
		return
	_loop_cd = 3.0
	_log_pop("[loop] left the ground %d times in %.1fs while standing still, best +%.1f up, at %v%s" % [
		_loop_takeoffs, _loop_age, _loop_gain, global_position.round(), _contact_report()])


## Terrain is a mesh of flat triangles, so following it exactly means popping
## into the air at every seam. If there is surface within reach underneath, take
## it — and take the velocity onto it too, which is the same push-never-pull
## rule applied to a contact we went looking for. Anything that deliberately
## threw us (a jump, a pad, a blast, a rope) says so with launched().
const SNAP_RATE := 9.0       # m/s the reel may close a gap at, never in one jump

func _stick(was_touching: bool) -> void:
	_stick_grace = maxf(0.0, _stick_grace - get_physics_process_delta_time())
	if touching or not (was_touching or _stick_grace > 0.0) or _no_snap > 0.0 \
			or velocity.dot(up_direction) > SNAP_MAX_UP:
		return
	var down := -up_direction
	var hit := KinematicCollision3D.new()
	if not test_move(global_transform, down * GROUND_SNAP, hit):
		return                       # genuinely off the end of something
	if hit.get_normal().dot(up_direction) < cos(deg_to_rad(GROUND_ANGLE)):
		return                       # too steep to be worth reeling us onto
	# Close the gap at a rate, never in one jump. Teleporting the whole 0.9 m
	# in a frame is a 53 m/s drop that never touches the velocity, so nothing
	# else could see it: you crest a bump, rise half a metre, and get yanked
	# flat instead of arcing. Reeling takes a few frames and is invisible.
	var gap := hit.get_travel().length()
	var drop := minf(gap, SNAP_RATE * get_physics_process_delta_time())
	global_position += down * drop
	if drop < gap - 0.001:
		_stick_grace = 0.2       # still reeling: keep the right to finish next frame
		return
	_stick_grace = 0.0
	var n := hit.get_normal()
	var into := velocity.dot(n)
	if into < 0.0:
		velocity -= n * into
	touching = true
	grounded = true
	_surf_n = n
	# This moves the body without touching its velocity, so it shows up as
	# neither a pop nor a kick. On a crest it can reel you down most of a metre
	# in one frame, which on its own would read as being dropped.
	if drop > 0.25 and _stick_cd <= 0.0:
		_stick_cd = 0.4
		_log_pop("[stick] reeled down %.2f m in one frame at %v  |v|%.1f%s" % [
			drop, global_position.round(), velocity.length(), _contact_report()])


## A hook that has bitten is an anchor, not a destination. Gravity and the
## momentum you arrived with keep running; the rope only adds a pull along its
## own line, and it refuses to stretch. So a hook thrown past a corner swings
## you around it, and letting go at the bottom of the arc keeps every bit of
## the speed the swing built.
func _grapple_swing(delta: float) -> void:
	var to: Vector3 = _items.grapple_target - global_position
	var dist := to.length()
	# Arrived, either by swinging in or by reeling the rope all the way home.
	if dist < GRAPPLE_MIN or (_rope_len > 0.0 and _rope_len <= GRAPPLE_MIN):
		_items.is_grappling = false
		return
	if _rope_len <= 0.0:
		_rope_len = dist
	var dir := to / dist
	velocity += dir * GRAPPLE_PULL * delta
	_rope_len = maxf(GRAPPLE_MIN, minf(_rope_len, dist) - GRAPPLE_REEL * delta)
	if dist > _rope_len:
		var out := -velocity.dot(dir)
		if out > 0.0:
			velocity += dir * out          # a rope pulls; it never pushes
		velocity += dir * (dist - _rope_len) * GRAPPLE_TAUT * delta
	launched(0.1)                          # the ground may not glue a swing down
	speed_cap = maxf(speed_cap, Vector2(velocity.x, velocity.z).length())


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
	# A press spent letting go of the grapple is spent: it may not charge a jump
	# on the way out, and it may not sit in the buffer waiting to fire on landing.
	if _jump_eaten:
		if not Input.is_action_pressed("jump"):
			_jump_eaten = false
		charging_jump = false
		jump_charge = 1.0
		jump_buffer = 0.0
		return
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
	if jump_buffer > 0.0 and grounded and jump_cooldown <= 0.0:
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
const MB_BOUNCE := 0.42     # how much of the impact a face too steep to hold gives back
const MB_BOUNCE_MIN := 9.0  # ...how hard you have to hit it before it does
const MB_BOUNCE_HOLD := 0.3 # ...how far from upright it has to be to count at all
const MB_BOUNCE_GAP := 0.3  # ...and how long before another one can fire


func _monkey_step(delta: float, wish_dir: Vector3, typing: bool, spd: float,
		acc: float, trn: float, boost: float, grv: float, jmp: float, now: float) -> void:
	var g := GRAVITY * grv
	_steer(delta, wish_dir, MB_TURN_RATE * trn)
	var lean := wish_dir.length()
	var accel := Vector3.ZERO
	if lean > 0.001:
		# Holding boost leans the stage harder — the only way to lean it is the
		# stick, so that is where a speed boost has to live.
		var tilt := minf(1.4, MB_TILT * lean * boost)
		accel = (wish_dir / lean) * (MB_ROLL * g * sin(tilt) * acc)
	if touching:
		accel -= _surf_n * accel.dot(_surf_n)   # the lean rides whatever face it is
	else:
		accel *= MB_AIR
	velocity += accel * delta
	# Gravity entire, at every angle. A ball in contact is rolling, not sliding,
	# so it answers to 5/7 of it — the rest is going into the spin. The contact
	# takes back whatever the surface is holding up and leaves the run downhill,
	# which is why there is no slope case here at all.
	velocity.y -= g * (MB_ROLL if touching else 1.0) * delta

	if touching:
		var damp := exp(-MB_DRAG * delta)
		velocity.x *= damp
		velocity.z *= damp
	# Boost leans the stage harder, which is already how it makes you faster.
	# Multiplying the CEILING by it as well stacked 6x onto 3x for an 18x walk
	# speed, and at the 78 m/s that reaches, the body crosses a 2 m terrain
	# facet every one and a half frames and moves 1.3 m per step: it cannot roll
	# on ground at all, it skips off it. Measured on an undulating deck, 22% of
	# the run was spent airborne at 78 m/s and NONE of it at 38.
	var top := MAX_SPEED * spd * MB_TOP
	var h := Vector2(velocity.x, velocity.z)
	if h.length() > top:
		h = h.normalized() * top
		velocity.x = h.x
		velocity.z = h.y
	# Nothing else may clip this back to run speed: the speed IS the mode.
	speed_cap = maxf(h.length(), MAX_SPEED)
	_charge_jump(delta, typing, jmp, now)


## Roll into a face the ball has no chance of holding — a kerb, the side of a
## ramp, a wall met at an angle — and it kicks back at you with sparks instead
## of just eating the speed. This decides how much the contact hands back; the
## contact itself does the giving. It is about the IMPACT, not about angles in
## the world: what matters is how sharply this face turns away from the one you
## were already riding, and how hard you arrived.
## Returns the normal of the face that may throw you back, or ZERO for none.
## The normal, not a bare number: only the face steep enough to earn a bounce is
## allowed to give one.
func _bounce_off(was_touching: bool, pre_vel: Vector3, pre_n: Vector3) -> Vector3:
	if not was_touching or _bounce_cd > 0.0 or not bool(Net.game_settings.get("monkey", true)):
		return Vector3.ZERO
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var n := c.get_normal()
		# You cannot bounce off something you could roll on. What throws you
		# back is a face too steep to hold AT ALL, and that is measured against
		# gravity — not against whatever you happened to be riding a frame ago.
		# Judging it by the change in angle meant rolling off flat ground onto a
		# 45 degree ramp read as an impact (cos 45 is 0.707, the old cutoff was
		# 0.72) and fired a 0.42 restitution kick straight up the ramp face:
		# 24 m/s of run became 18.7 m/s of lift, every single time you tried it.
		if n.dot(up_direction) > MB_BOUNCE_HOLD:
			continue
		if n.dot(pre_n) > 0.72:
			continue                       # already sliding along this one
		var hit_speed := -pre_vel.dot(n)   # how much of the run went into the face
		if hit_speed < MB_BOUNCE_MIN:
			continue
		_bounce_cd = MB_BOUNCE_GAP
		launched(0.12)
		Sfx.boost(c.get_position(), 0.35)
		_sparks(c.get_position(), n)
		return n
	return Vector3.ZERO


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
	velocity.y -= SRC_GRAVITY * delta
	if grounded:
		if not typing and Input.is_action_pressed("jump") and jump_cooldown <= 0.0:
			velocity.y = SRC_JUMP
			jump_cooldown = 0.1  # debounce so one landing = one hop
			jump_cooldown_max = 0.1
			launched()
			Sfx.jump(global_position)
			Net.emit_event("jump")
		else:
			_source_friction(delta)

	var maxspeed := SRC_RUNSPEED if sprinting else SRC_WALKSPEED
	var wish_speed := wish_dir.length() * maxspeed
	if wish_speed > 0.001:
		var dirn := wish_dir.normalized()
		if grounded:
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
