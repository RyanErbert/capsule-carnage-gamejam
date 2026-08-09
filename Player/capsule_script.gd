extends Node3D

const capsuleCircumference = 3.14
var capsuleRPM := 0.0

@export var critterModel : Node3D
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	var velocity = get_parent().velocity
	if velocity.length() > 0.1:
		critterModel.rotation.y = -atan2(velocity.z,velocity.x)+3.141
	
	
	pass
