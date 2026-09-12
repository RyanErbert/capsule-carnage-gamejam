extends Node3D

## A lava surface: any mesh in the world whose name starts with "Lava" and
## does not carry a -col suffix. It has no collider (you fall INTO it), and
## the moment the player's ball dips below its top face inside its footprint
## they are sent back to the last checkpoint. The mesh itself is left as the
## artist made it; this node only watches.

const DIP := 0.25   # how far below the lava's top the ball's centre may go

var mesh: MeshInstance3D
var player: CharacterBody3D
var _box: AABB
var _cd := 0.0
var _glow_t := 0.0
var _mat: StandardMaterial3D


func _ready() -> void:
	if mesh == null:
		return
	# World-space footprint of the mesh, top face included
	var local: AABB = mesh.get_aabb()
	var xf := mesh.global_transform
	_box = AABB(xf * local.position, Vector3.ZERO)
	for i in 8:
		_box = _box.expand(xf * local.get_endpoint(i))
	# Make sure it reads as lava even if the export shipped a flat colour
	if mesh.get_surface_override_material_count() > 0 or mesh.mesh:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(1.0, 0.42, 0.08)
		_mat.emission_enabled = true
		_mat.emission = Color(1.0, 0.35, 0.05)
		_mat.emission_energy_multiplier = 2.2
		_mat.roughness = 0.6
		mesh.material_override = _mat
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.45, 0.1)
	light.omni_range = maxf(8.0, _box.size.length() * 0.5)
	light.light_energy = 1.2
	light.shadow_enabled = false
	add_child(light)
	global_position = _box.get_center() + Vector3(0, 1.5, 0)


func _process(delta: float) -> void:
	_glow_t += delta
	if _mat:
		_mat.emission_energy_multiplier = 2.0 + 0.5 * sin(_glow_t * 1.7)
	_cd = maxf(0.0, _cd - delta)
	if player == null or player.dead or _cd > 0.0:
		return
	var p := player.global_position
	var top := _box.position.y + _box.size.y
	if p.x >= _box.position.x and p.x <= _box.end.x and p.z >= _box.position.z and p.z <= _box.end.z \
			and p.y < top - DIP and p.y > _box.position.y - 4.0:
		_cd = 1.0
		var scene: Node = get_parent()
		if scene and scene.has_method("burn"):
			scene.burn(p)
