extends Node3D

## Remote player ghost — pure visual, interpolated like the web client (lerp 0.3/frame
## at 60 fps, made frame-rate independent). No collision: players are non-solid in the
## web game (PORT_BLUEPRINT.md §3.6).

const RoundcubeVisualScene := preload("res://Player/roundcube_visual.tscn")

var player_id := ""
var player_name := ""
var target_position := Vector3.ZERO
var target_quat := Quaternion.IDENTITY
var is_godmode := false

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _name_label: Label3D = $NameLabel

var _cube: Node3D = null  # roundcube visual for web-shaped players


func setup(id: String, data: Dictionary) -> void:
	player_id = id
	player_name = str(data.get("name", "???"))
	target_position = Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0))
	global_position = target_position
	var color := Color(str(data.get("skinColor", data.get("color", "#ffffff"))))
	var shape := str(data.get("shape", data.get("type", "box")))
	if shape == "roundcube" or shape == "box" or shape == "cube":
		_mesh.visible = false
		_cube = RoundcubeVisualScene.instantiate()
		add_child(_cube)
		_cube.set_color(color)
		_cube.set_smoothing(float(data.get("smoothing", 0.25)))
	else:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		_mesh.material_override = mat
	_name_label.text = player_name


func apply_move(d: Dictionary) -> void:
	target_position = Vector3(d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0))
	target_quat = Quaternion(d.get("qx", 0.0), d.get("qy", 0.0), d.get("qz", 0.0), d.get("qw", 1.0)).normalized()
	if _cube and d.has("smoothing"):
		_cube.set_smoothing(float(d.get("smoothing", 0.25)))
	var godmode: bool = d.get("godmode", false)
	if godmode != is_godmode:
		is_godmode = godmode
		# Web: godmode players render as 30%-visible ghosts
		if _cube:
			_cube.set_alpha(0.09 if godmode else 0.3)
		else:
			_mesh.transparency = 0.7 if godmode else 0.0
	# Their god-mode drone, rendered where they reported it (shootable!)
	var dd: Variant = d.get("drone")
	if dd is Dictionary:
		_drone_target = Vector3(dd.get("x", 0.0), dd.get("y", 0.0), dd.get("z", 0.0))
		if _drone_vis == null:
			_make_drone_vis()
			_drone_vis.global_position = _drone_target
		if not _drone_vis.visible:
			_drone_vis.global_position = _drone_target
			set_drone_hp(int(DRONE_HP_MAX))
			_drone_vis.visible = true
	elif _drone_vis:
		_drone_vis.visible = false


# --- Remote drone (small body + a sliver of health above it) ----------------

const DRONE_HP_MAX := 30.0

var _drone_vis: Node3D
var _drone_target := Vector3.ZERO
var _drone_fill: MeshInstance3D


func drone_pos() -> Variant:
	return _drone_vis.global_position if _drone_vis and _drone_vis.visible else null


func set_drone_hp(hp: int) -> void:
	if _drone_fill:
		_drone_fill.scale.x = clampf(hp / DRONE_HP_MAX, 0.05, 1.0)


func clear_drone() -> void:
	if _drone_vis:
		_drone_vis.visible = false


func _make_drone_vis() -> void:
	_drone_vis = Node3D.new()
	_drone_vis.top_level = true
	add_child(_drone_vis)
	var body := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.25
	sphere.height = 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.18)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 0.4)
	mat.emission_energy_multiplier = 1.5
	sphere.material = mat
	body.mesh = sphere
	_drone_vis.add_child(body)
	# HP bar: a dark backing quad and a green fill that shrinks with damage
	var back := MeshInstance3D.new()
	var back_quad := QuadMesh.new()
	back_quad.size = Vector2(0.7, 0.09)
	var back_mat := StandardMaterial3D.new()
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_mat.albedo_color = Color(0, 0, 0, 0.6)
	back_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	back_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	back_mat.no_depth_test = true
	back_quad.material = back_mat
	back.mesh = back_quad
	back.position.y = 0.55
	_drone_vis.add_child(back)
	_drone_fill = MeshInstance3D.new()
	var fill_quad := QuadMesh.new()
	fill_quad.size = Vector2(0.66, 0.055)
	var fill_mat := StandardMaterial3D.new()
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.albedo_color = Color(0.35, 1.0, 0.55)
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.no_depth_test = true
	fill_quad.material = fill_mat
	_drone_fill.mesh = fill_quad
	_drone_fill.position.y = 0.55
	_drone_vis.add_child(_drone_fill)


var _is_holder := false
var _strobe_t := 0.0


func set_holder(holder: bool) -> void:
	_is_holder = holder
	if _cube:
		_cube.set_outline_visible(holder)  # web: white hull on the it-player
		return
	if not holder and _mesh.material_override is StandardMaterial3D:
		_mesh.material_override.emission_enabled = false


func _process(delta: float) -> void:
	var t := 1.0 - pow(0.7, delta * 60.0)  # web: lerp factor 0.3 per 60fps frame
	global_position = global_position.lerp(target_position, t)
	if _drone_vis and _drone_vis.visible:
		_drone_vis.global_position = _drone_vis.global_position.lerp(_drone_target, t)
	if _cube:
		_cube.quaternion = _cube.quaternion.slerp(target_quat, t)
	else:
		_mesh.quaternion = _mesh.quaternion.slerp(target_quat, t)

	# Holder strobes gold (web §1.9: sin(t*0.008) on ms — ~1.3 Hz)
	if _is_holder and not _cube and _mesh.material_override is StandardMaterial3D:
		_strobe_t += delta
		var mat: StandardMaterial3D = _mesh.material_override
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.1)
		mat.emission_energy_multiplier = 0.5 + 0.5 * sin(_strobe_t * 8.0)
