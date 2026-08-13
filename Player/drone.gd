extends CharacterBody3D

## Build drone: the camera flies THIS, while the player's body stays where it
## was — visible, taggable, and blast-able. Slower than the old free-fly
## (15 vs 40) and moved with move_and_slide, so it can't pass through walls.
##
## It flies like a quad, not like a cursor: the sticks ask for a speed and the
## motors take time to get there, the nose swings onto whatever you are looking
## at, and the frame leans into its own acceleration.

const FLY_SPEED := 15.0
const FLY_ACCEL := 46.0      # thrust toward the stick, m/s2
const FLY_BRAKE := 30.0      # ...and what it can shed with the sticks centered
const RETURN_SPEED := 42.0
const ROTOR_IDLE := 26.0     # rad/s with the sticks centered
const ROTOR_GAIN := 2.2      # ...plus this per m/s of airspeed
const YAW_RATE := 8.0        # how fast the nose comes round to your view
const TILT_MAX := 0.45       # how far the frame may lean into its acceleration
const TILT_GAIN := 0.010
const TILT_RATE := 7.0
const WOBBLE := 0.035        # airframe jitter, scaled by how fast it's moving

var camera_rig: Node3D
var return_to: Node3D = null  # set on god-mode exit: fly home, then despawn

var _pitch := 0.0
var _roll := 0.0
var _wob := 0.0

@onready var _rotors: Node3D = get_node_or_null("Rotors")


## Props spin with airspeed; alternate pairs turn opposite ways, like a real
## quad. Purely cosmetic.
func _process(delta: float) -> void:
	if _rotors == null:
		return
	var rate := ROTOR_IDLE + velocity.length() * ROTOR_GAIN
	var kids := _rotors.get_children()
	for i in kids.size():
		(kids[i] as Node3D).rotate_y(rate * delta * (1.0 if i % 2 == 0 else -1.0))


func _physics_process(delta: float) -> void:
	if return_to != null:
		if not is_instance_valid(return_to):
			queue_free()
			return
		var to: Vector3 = return_to.global_position + Vector3(0, 1.5, 0) - global_position
		if to.length() < 1.2:
			queue_free()
			return
		# Straight flight home, no collisions — it always makes it back
		global_position += to.normalized() * minf(RETURN_SPEED * delta, to.length())
		return

	var yaw: float = camera_rig.yaw if camera_rig else 0.0
	var dir := Vector3.ZERO
	if get_viewport().gui_get_focus_owner() == null:
		var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
		var forward := Vector3(-sin(yaw), 0, -cos(yaw))
		var right := Vector3(-forward.z, 0, forward.x)
		dir = right * input_dir.x - forward * input_dir.y
		if Input.is_action_pressed("jump") or Input.is_key_pressed(KEY_E):
			dir.y += 1.0
		if Input.is_action_pressed("sprint"):
			dir.y -= 1.0

	var want := dir.limit_length(1.0) * FLY_SPEED
	var before := velocity
	velocity = velocity.move_toward(want,
		(FLY_ACCEL if want.length_squared() > 0.0001 else FLY_BRAKE) * delta)
	move_and_slide()
	_fly_pose(delta, (velocity - before) / maxf(delta, 0.0001), yaw)


## The frame, not the flight: nothing here moves the drone. It yaws onto your
## view, leans into whatever it is accelerating toward, and shivers a little
## once it is actually moving.
func _fly_pose(delta: float, accel: Vector3, yaw: float) -> void:
	rotation.y = lerp_angle(rotation.y, yaw, minf(1.0, YAW_RATE * delta))
	var forward := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var right := Vector3(-forward.z, 0.0, forward.x)
	var t := minf(1.0, TILT_RATE * delta)
	_pitch = lerpf(_pitch, clampf(accel.dot(forward) * TILT_GAIN, -TILT_MAX, TILT_MAX), t)
	_roll = lerpf(_roll, clampf(-accel.dot(right) * TILT_GAIN, -TILT_MAX, TILT_MAX), t)
	_wob += delta
	var jitter := minf(1.0, velocity.length() / FLY_SPEED) * WOBBLE
	rotation.x = _pitch + sin(_wob * 6.3) * jitter
	rotation.z = _roll + sin(_wob * 4.7 + 1.3) * jitter * 1.4
