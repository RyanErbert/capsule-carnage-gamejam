extends CharacterBody3D

## God-mode drone: the camera flies THIS, while the player's body stays where
## it was — visible, taggable, and blast-able. Slower than the old free-fly
## (15 vs 40) and moved with move_and_slide, so it can't pass through walls.

const FLY_SPEED := 15.0

var camera_rig: Node3D


func _physics_process(_delta: float) -> void:
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
