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


var _is_holder := false
var _strobe_t := 0.0


func set_holder(holder: bool) -> void:
	_is_holder = holder
	if not holder and _mesh.material_override is StandardMaterial3D:
		_mesh.material_override.emission_enabled = false


func _process(delta: float) -> void:
	var t := 1.0 - pow(0.7, delta * 60.0)  # web: lerp factor 0.3 per 60fps frame
	global_position = global_position.lerp(target_position, t)
	_mesh.quaternion = _mesh.quaternion.slerp(target_quat, t)

	# Holder strobes gold (web §1.9: sin(t*0.008) on ms — ~1.3 Hz)
	if _is_holder and _mesh.material_override is StandardMaterial3D:
		_strobe_t += delta
		var mat: StandardMaterial3D = _mesh.material_override
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.1)
		mat.emission_energy_multiplier = 0.5 + 0.5 * sin(_strobe_t * 8.0)
