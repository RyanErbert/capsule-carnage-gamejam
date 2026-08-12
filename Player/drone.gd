extends CharacterBody3D

## Build drone: the camera flies THIS, while the player's body stays where it
## was — visible, taggable, and blast-able. Slower than the old free-fly
## (15 vs 40) and moved with move_and_slide, so it can't pass through walls.

const FLY_SPEED := 15.0
const RETURN_SPEED := 42.0
const ROTOR_IDLE := 26.0     # rad/s with the sticks centered
const ROTOR_GAIN := 2.2      # ...plus this per m/s of airspeed

var camera_rig: Node3D
var return_to: Node3D = null  # set on god-mode exit: fly home, then despawn

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


func _physics_process(_delta: float) -> void:
	if return_to != null:
		if not is_instance_valid(return_to):
			queue_free()
			return
		var to: Vector3 = return_to.global_position + Vector3(0, 1.5, 0) - global_position
		if to.length() < 1.2:
			queue_free()
			return
		# Straight flight home, no collisions — it always makes it back
		global_position += to.normalized() * minf(RETURN_SPEED * _delta, to.length())
		return
	if get_viewport().gui_get_focus_owner() != null:
		velocity = Vector3.ZERO
		return
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var yaw: float = camera_rig.yaw if camera_rig else 0.0
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var right := Vector3(-forward.z, 0, forward.x)
	var dir := right * input_dir.x - forward * input_dir.y
	if Input.is_action_pressed("jump") or Input.is_key_pressed(KEY_E):
		dir.y += 1.0
	if Input.is_action_pressed("sprint"):
		dir.y -= 1.0
	velocity = dir.limit_length(1.0) * FLY_SPEED
	move_and_slide()
