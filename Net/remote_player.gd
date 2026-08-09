extends Node3D

## Remote player ghost — pure visual, interpolated like the web client (lerp 0.3/frame
## at 60 fps, made frame-rate independent). No collision: players are non-solid in the
## web game (PORT_BLUEPRINT.md §3.6).

var player_id := ""
var player_name := ""
var target_position := Vector3.ZERO
var target_quat := Quaternion.IDENTITY
var is_godmode := false

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _name_label: Label3D = $NameLabel


func setup(id: String, data: Dictionary) -> void:
	player_id = id
	player_name = str(data.get("name", "???"))
	target_position = Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0))
	global_position = target_position
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(str(data.get("skinColor", data.get("color", "#ffffff"))))
	_mesh.material_override = mat
	_name_label.text = player_name


func apply_move(d: Dictionary) -> void:
	target_position = Vector3(d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0))
	target_quat = Quaternion(d.get("qx", 0.0), d.get("qy", 0.0), d.get("qz", 0.0), d.get("qw", 1.0)).normalized()
	var godmode: bool = d.get("godmode", false)
	if godmode != is_godmode:
		is_godmode = godmode
		_mesh.transparency = 0.7 if godmode else 0.0  # web: godmode players are 30% ghosts


func _process(delta: float) -> void:
	var t := 1.0 - pow(0.7, delta * 60.0)  # web: lerp factor 0.3 per 60fps frame
	global_position = global_position.lerp(target_position, t)
	_mesh.quaternion = _mesh.quaternion.slerp(target_quat, t)
