extends Node3D

## "Ball on a chain" third-person camera ported from the web version — PORT_BLUEPRINT.md §1.5.
## Sits as a child of the player but top_level, so it lags behind in world space.

const BASE_CHAIN_MIN := 2.0
const BASE_CHAIN_MAX := 20.0
const MOUSE_SENSITIVITY := 0.003
const CAM_PITCH_MIN := -1.4
const CAM_PITCH_MAX := 1.4
const CAM_DRAG_SPEED := 1.8       # auto-follow yaw rate
const CAM_TURN_BOOST := 1.5
const MOUSE_IDLE_DELAY := 0.6     # seconds before auto-follow kicks in
const POS_LERP_RATE := 6.0
const AUTO_FOLLOW_MIN_SPEED := 1.5
const CHAIN_SPEED_STRETCH := 0.4  # chain extends past walk speed
const ARM_RADIUS := 0.35     # the arm is a ball, not a thread, so it cannot
                             # slip through a corner or a hairline gap
# The sphere is the whole of the anti-clip fix, and it is enough. Two other
# guards were tried and both went back: a ray from the player to the rig that
# SET the rig onto whatever it hit (it snapped on and off in tunnels and at the
# fog edge), and a smoothing pass on the arm length (which only ever smoothed
# zoom and speed, and so did nothing about walls at all). SpringArm3D casts and
# clamps instantly by design; if that ever needs softening, it has to be the
# CAST result that is smoothed, not the requested length.
const TELEPORT_SNAP := 6.0   # a jump further than this is a respawn, not travel
const SPEED_SMOOTH := 8.0    # contact changes speed in one frame; the chain
                             # should not
const ACCEL_SMOOTH := 12.0   # ...and neither should the lean

@export var spring_arm: SpringArm3D

var yaw := PI
var pitch := 0.4
var base_chain_length := 4.5
var follow_target: Node3D = null  # god-mode drone override; null = the player
var _mouse_idle_timer := 999.0

@onready var _player: CharacterBody3D = get_parent()
@onready var _cam: Camera3D = spring_arm.get_node_or_null("Camera3D") if spring_arm else null

# --- Legacy camera (the web game's, kept as an option) -----------------------
# Godot's SpringArm casts and PLACES the camera at the hit, every frame, so a
# wall arriving or leaving is a hard cut. The web one never touched the camera
# with its ray: it moved the camera's GOAL and let the camera ease toward it, so
# the same event glides. Three elastic stages feed that goal -- the chain length,
# the look-at point, and the camera itself -- and the ray only ever shortens the
# goal, with a buffer so it never sits flush on the surface.
const LEG_CHAIN_RATE := 2.0    # the chain itself is elastic, and slow
const LEG_LOOK_RATE := 15.0    # ...the look-at point is snappier, which is what
                               # keeps ground jitter out of the vertical
const LEG_BUFFER := 0.3        # stand off the surface by this
const LEG_MIN := 0.5           # ...and never collapse closer than this
const LEG_EYE := 1.0           # look-at sits this far above the body
const LEG_LIFT := 0.5          # ...and the camera this much above that

var _leg_look := Vector3.ZERO
var _leg_chain := 4.5
var _leg_on := false


var _smooth_speed := 0.0
var _smooth_accel := Vector3.ZERO


func _ready() -> void:
	top_level = true
	global_position = _player.global_position
	if spring_arm:
		# A ray finds nothing when it threads a corner, and the camera ends up
		# inside the wall it just missed. A sphere has to fit through.
		var ball := SphereShape3D.new()
		ball.radius = ARM_RADIUS
		spring_arm.shape = ball
		spring_arm.add_excluded_object(_player.get_rid())


func _unhandled_input(event: InputEvent) -> void:
	var mouse_look: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		or (event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT)
	if event is InputEventMouseMotion and mouse_look:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch = clampf(pitch + event.relative.y * MOUSE_SENSITIVITY, CAM_PITCH_MIN, CAM_PITCH_MAX)
		_mouse_idle_timer = 0.0
	# (scroll belongs to the inventory / placement height now, not zoom)


func _physics_process(delta: float) -> void:
	_mouse_idle_timer += delta

	var target: Node3D = follow_target if is_instance_valid(follow_target) else _player
	var vel: Vector3 = target.velocity if target is CharacterBody3D else Vector3.ZERO
	var h_speed := Vector2(vel.x, vel.z).length()
	_smooth_speed = lerpf(_smooth_speed, h_speed, minf(1.0, SPEED_SMOOTH * delta))

	if _death_left > 0.0:
		_spring_camera()          # the death arc is driven off the rig
		_death_step(delta)
		return

	# Auto-follow: swing behind the movement direction when the mouse is idle (web §1.5)
	if h_speed > AUTO_FOLLOW_MIN_SPEED and _mouse_idle_timer > MOUSE_IDLE_DELAY and not _player.godmode:
		var target_yaw := atan2(vel.x, vel.z) + PI
		var diff := absf(wrapf(target_yaw - yaw, -PI, PI))
		var rate := CAM_DRAG_SPEED * (1.0 + minf(1.0, diff / (PI / 2.0)) * CAM_TURN_BOOST) * delta
		yaw = lerp_angle(yaw, target_yaw, minf(1.0, rate))

	if Settings.camera_mode == "legacy":
		_legacy_step(delta, target, vel)
		return
	_spring_camera()

	# Chain stretches when moving past walk speed (sprint/explosions). Off the
	# SMOOTHED speed: hitting anything changes the real one in a single frame,
	# and the chain jerking in and out on every scrape reads as camera jitter.
	base_chain_length = Settings.camera_zoom
	var want_chain := clampf(
		base_chain_length + maxf(0.0, _smooth_speed - 9.0) * CHAIN_SPEED_STRETCH,
		BASE_CHAIN_MIN, BASE_CHAIN_MAX)
	if spring_arm:
		# Straight through, the way it always was. The arm-length smoothing that
		# used to sit here only ever smoothed want_chain -- zoom and speed, which
		# know nothing about walls -- so it did none of the work its comment
		# claimed. The sphere below is what actually stops the clipping.
		spring_arm.spring_length = want_chain

	# Lagged position follow, damped less at high speed (web: 1-exp(-6*dt) * (1 - speedFactor*0.4))
	var anchor := target.global_position + Vector3(0, 1, 0)
	var speed_factor := minf(1.0, _smooth_speed / 18.0)
	var t := (1.0 - exp(-POS_LERP_RATE * delta)) * (1.0 - speed_factor * 0.4)
	# A respawn moves the body across the map. Lerping to it flies the camera
	# through everything in between, so a jump that big is followed, not chased.
	if global_position.distance_to(anchor) > TELEPORT_SNAP:
		global_position = anchor
	else:
		global_position = global_position.lerp(anchor, t)

	rotation.y = yaw
	rotation.x = -pitch
	rotation.z = _wobble(delta, vel)


## Monkey Ball leans the world under the ball, and you never see the world
## lean. The camera rolling a few degrees against your sideways acceleration is
## what puts that back — off entirely in every other movement mode.
const WOBBLE_MAX := 0.08     # radians
const WOBBLE_RATE := 5.0
const WOBBLE_GAIN := 0.011

var _roll := 0.0
var _prev_vel := Vector3.ZERO


func _wobble(delta: float, vel: Vector3) -> float:
	# Contact rewrites velocity in a single frame, so the raw derivative spikes
	# to hundreds of m/s^2 every time you so much as scrape a wall, and the lean
	# snaps with it. Lean off a smoothed acceleration and only real cornering
	# survives.
	var raw := (vel - _prev_vel) / maxf(delta, 0.0001)
	_prev_vel = vel
	_smooth_accel = _smooth_accel.lerp(raw, minf(1.0, ACCEL_SMOOTH * delta))
	var accel := _smooth_accel
	var want := 0.0
	if bool(Net.game_settings.get("monkey", true)):
		var right := Vector3(cos(yaw), 0.0, -sin(yaw))
		want = clampf(-accel.dot(right) * WOBBLE_GAIN, -WOBBLE_MAX, WOBBLE_MAX)
	_roll = lerpf(_roll, want, minf(1.0, WOBBLE_RATE * delta))
	return _roll




# --- Death cam --------------------------------------------------------------
## Dying should show you what happened, then where you are going: hold on
## whoever did it, climb to a look at the whole thing, and come down on the spawn
## exactly as the countdown runs out, so you are already looking at the ground
## you land on.
const DEATH_HOLD := 0.35     # of the countdown spent watching the killer
const DEATH_RISE := 0.80     # ...up to here climbing; the rest is the descent
const DEATH_HIGH := 20.0     # how far overhead the top of the arc sits

var _death_left := 0.0
var _death_len := 0.0
var _death_at := Vector3.ZERO
var _killer_at := Vector3.ZERO
var _spawn_at := Vector3.ZERO


func begin_death(death_at: Vector3, killer_at: Vector3, spawn_at: Vector3,
		secs: float) -> void:
	_death_len = maxf(0.4, secs)
	_death_left = _death_len
	_death_at = death_at
	_killer_at = killer_at
	_spawn_at = spawn_at


func end_death() -> void:
	_death_left = 0.0


## Aim the rig at a point. The rig looks along its own -Z, so this is the yaw
## and pitch that put that axis on the target -- set rather than snapped, so
## handing control back at the end is seamless.
func _aim_at(from: Vector3, to: Vector3) -> Array:
	var d := to - from
	if d.length() < 0.01:
		return [yaw, pitch]
	var flat := Vector2(d.x, d.z).length()
	return [atan2(-d.x, -d.z), -atan2(d.y, maxf(flat, 0.01))]


func _death_step(delta: float) -> void:
	_death_left = maxf(0.0, _death_left - delta)
	var u := 1.0 - _death_left / _death_len
	var eye := _death_at + Vector3(0, 1.5, 0)
	var high := _death_at + Vector3(0, DEATH_HIGH, 0)
	var want_yaw := yaw
	var want_pitch := pitch
	var pivot := eye
	if u < DEATH_HOLD:
		# Whoever did it, if the server named them; the spot itself if not.
		if _killer_at != Vector3.ZERO:
			var aim := _aim_at(eye, _killer_at)
			want_yaw = aim[0]
			want_pitch = aim[1]
	elif u < DEATH_RISE:
		var k := (u - DEATH_HOLD) / (DEATH_RISE - DEATH_HOLD)
		pivot = eye.lerp(high, k * k * (3.0 - 2.0 * k))
		want_pitch = lerpf(want_pitch, CAM_PITCH_MAX * 0.9, k)
	else:
		var k := (u - DEATH_RISE) / (1.0 - DEATH_RISE)
		k = k * k * (3.0 - 2.0 * k)
		pivot = high.lerp(_spawn_at + Vector3(0, 1, 0), k)
		want_pitch = lerpf(CAM_PITCH_MAX * 0.9, 0.4, k)
	global_position = global_position.lerp(pivot, 1.0 - exp(-6.0 * delta))
	yaw = lerp_angle(yaw, want_yaw, minf(1.0, 3.0 * delta))
	pitch = lerpf(pitch, want_pitch, minf(1.0, 3.0 * delta))
	rotation.y = yaw
	rotation.x = -pitch
	rotation.z = 0.0


## Hand the camera back to the spring arm, undoing the legacy takeover.
func _spring_camera() -> void:
	if _cam == null or not _leg_on:
		return
	_leg_on = false
	_cam.top_level = false
	_cam.position = Vector3.ZERO
	_cam.rotation = Vector3.ZERO


## The web camera, port of updateCamera() in friendslop-web/public/game.js.
func _legacy_step(delta: float, target: Node3D, vel: Vector3) -> void:
	if _cam == null:
		return
	if not _leg_on:
		# Taking the camera off the arm: from here we place it ourselves, so the
		# arm's instant clamp never gets a say.
		_leg_on = true
		_cam.top_level = true
		_leg_look = target.global_position + Vector3(0, LEG_EYE, 0)
		_leg_chain = Settings.camera_zoom
	var want := clampf(
		Settings.camera_zoom + maxf(0.0, _smooth_speed - 9.0) * CHAIN_SPEED_STRETCH,
		BASE_CHAIN_MIN, BASE_CHAIN_MAX)
	_leg_chain = lerpf(_leg_chain, want, minf(1.0, LEG_CHAIN_RATE * delta))
	# Stage two: the look-at point chases the head faster than the camera chases
	# anything, which is what stops ground jitter reaching the picture.
	var head := target.global_position + Vector3(0, LEG_EYE, 0)
	_leg_look = _leg_look.lerp(head, 1.0 - exp(-LEG_LOOK_RATE * delta))
	var off := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * _leg_chain
	# Height comes off the SMOOTHED point, x and z off the raw one: bob killed,
	# without making the camera lag sideways.
	var desired := Vector3(
		target.global_position.x + off.x,
		_leg_look.y + LEG_LIFT + off.y,
		target.global_position.z + off.z)
	var d := desired - _leg_look
	var dist := d.length()
	if dist > 0.1:
		var dir := d / dist
		var q := PhysicsRayQueryParameters3D.create(_leg_look, _leg_look + dir * dist)
		q.exclude = [_player.get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit:
			var reach := (hit["position"] as Vector3).distance_to(_leg_look) - LEG_BUFFER
			desired = _leg_look + dir * maxf(LEG_MIN, reach)
	var speed_factor := minf(1.0, _smooth_speed / 18.0)
	var t := (1.0 - exp(-POS_LERP_RATE * delta)) * (1.0 - speed_factor * 0.4)
	if _cam.global_position.distance_to(desired) > TELEPORT_SNAP:
		_cam.global_position = desired
	else:
		_cam.global_position = _cam.global_position.lerp(desired, t)
	_cam.look_at(_leg_look, Vector3.UP)
	# ...and the lean we added since, which is the one thing the web never had.
	_cam.rotate_object_local(Vector3.FORWARD, _wobble(delta, vel))
	rotation.y = yaw
	rotation.x = -pitch
