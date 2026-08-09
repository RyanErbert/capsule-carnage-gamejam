extends CharacterBody3D


const SPEED = 0.1
const JUMP_VELOCITY = 4.5
const FRICTION_COEFFICIENT = 0.05
const BOUNCE_COEFFECIENT = 1
const WEIGHT = 1

var calculatedVelocityY := 0;

var mouse_sensitivity := 0.1
var rotation_x := 0.0
var rotation_y := 0.0
var world_tilt := Vector2(0.0,0.0)
var input_tilt := Vector2(0.0,0.0)


@export var camera : Node3D
@export var cameraTilter : Node3D
@export var capsuleCollider : CollisionShape3D
@export var playerModel : MeshInstance3D
@export var devInfoLabel : Label


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor(): 
		velocity += get_gravity() * delta
	else:		
		velocity.x -= velocity.normalized().x * FRICTION_COEFFICIENT * cos(get_floor_angle())
		velocity.z -= velocity.normalized().z * FRICTION_COEFFICIENT * cos(get_floor_angle())
		
	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	direction = direction.rotated(Vector3(0,1,0),deg_to_rad(camera.rotation_degrees.y))
	if direction && velocity.length_squared() < 100:
		velocity.x += direction.x * SPEED
		velocity.z += direction.z * SPEED
	if velocity.y > 0:
		floor_snap_length = 0
	else:
		floor_snap_length = .3
	#camera.rotation_degrees.x = -input_dir.y*6
	#camera.rotation_degrees.z = input_dir.x*6
	updateDevInfo()
	move_and_slide()
	

func _unhandled_input(event: InputEvent)-> void:
		if event is InputEventMouseMotion:
			rotation_y += event.relative.x * -mouse_sensitivity
			camera.rotation_degrees.y = rotation_y

func updateDevInfo()-> void:
	devInfoLabel.text = "POS x:%f,y:%f,z:%f\rVEL:x:%f,y:%f,z:%f" % [position.x,position.y,position.z,velocity.x,velocity.y,velocity.z]
	
