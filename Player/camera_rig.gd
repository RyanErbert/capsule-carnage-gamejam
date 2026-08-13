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

@export var spring_arm: SpringArm3D

var yaw := PI
var pitch := 0.4
var base_chain_length := 4.5
var follow_target: Node3D = null  # god-mode drone override; null = the player
var _mouse_idle_timer := 999.0

@onready var _player: CharacterBody3D = get_parent()


func _ready() -> void:
	top_level = true
	global_position = _player.global_position


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

	# Auto-follow: swing behind the movement direction when the mouse is idle (web §1.5)
	if h_speed > AUTO_FOLLOW_MIN_SPEED and _mouse_idle_timer > MOUSE_IDLE_DELAY and not _player.godmode:
		var target_yaw := atan2(vel.x, vel.z) + PI
		var diff := absf(wrapf(target_yaw - yaw, -PI, PI))
		var rate := CAM_DRAG_SPEED * (1.0 + minf(1.0, diff / (PI / 2.0)) * CAM_TURN_BOOST) * delta
		yaw = lerp_angle(yaw, target_yaw, minf(1.0, rate))

	# Chain stretches when moving past walk speed (sprint/explosions).
	# The resting length is the local player's zoom slider (Esc gear).
	base_chain_length = Settings.camera_zoom
	var chain := clampf(base_chain_length + maxf(0.0, h_speed - 9.0) * CHAIN_SPEED_STRETCH, BASE_CHAIN_MIN, BASE_CHAIN_MAX)
	if spring_arm:
		spring_arm.spring_length = chain

	# Lagged position follow, damped less at high speed (web: 1-exp(-6*dt) * (1 - speedFactor*0.4))
	var speed_factor := minf(1.0, h_speed / 18.0)
	var t := (1.0 - exp(-POS_LERP_RATE * delta)) * (1.0 - speed_factor * 0.4)
	global_position = global_position.lerp(target.global_position + Vector3(0, 1, 0), t)

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
	var accel := (vel - _prev_vel) / maxf(delta, 0.0001)
	_prev_vel = vel
	var want := 0.0
	if bool(Net.game_settings.get("monkey", false)):
		var right := Vector3(cos(yaw), 0.0, -sin(yaw))
		want = clampf(-accel.dot(right) * WOBBLE_GAIN, -WOBBLE_MAX, WOBBLE_MAX)
	_roll = lerpf(_roll, want, minf(1.0, WOBBLE_RATE * delta))
	return _roll
