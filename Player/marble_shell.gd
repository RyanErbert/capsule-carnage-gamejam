extends Node3D

## The glass marble everybody rides around in.
##
## Two hemispheres: one tinted the player's colour, one an off-white milk
## glass. Rolling a plain sphere is invisible — every frame looks the same —
## so the seam between the halves is what makes the spin read, the same way a
## two-tone marble does. The shell rolls; whatever is INSIDE it does not, so
## the character stays the right way up while their ball tumbles.
##
## Used by the local player (Player/player.tscn CapsuleLogic) and by every
## remote ghost (Net/remote_player.gd), so both look like the same object.

# Matches the player's collider (SphereShape3D at 0.785 scale) so the glass
# sits exactly where the physics does, and so the roll rate is honest.
const RADIUS := 0.393
const OFFWHITE := Color(0.93, 0.92, 0.87)
const GLASS_A := 0.34        # how much of the model inside shows through
const MILK_A := 0.62         # the pale half is frostier, so the seam reads

var _shell: Node3D
var _tint: StandardMaterial3D


func _init() -> void:
	_shell = Node3D.new()
	add_child(_shell)
	# Top half in the player's colour, bottom half milk glass. A hemisphere
	# needs height == radius, or Godot squashes it into half an ellipsoid.
	for half in 2:
		var mi := MeshInstance3D.new()
		var dome := SphereMesh.new()
		dome.is_hemisphere = true
		dome.radius = RADIUS
		dome.height = RADIUS
		dome.radial_segments = 24
		dome.rings = 12
		var mat := _glass(OFFWHITE, MILK_A)
		if half == 0:
			_tint = mat
		mi.mesh = dome
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if half == 1:
			mi.rotation = Vector3(PI, 0, 0)
		_shell.add_child(mi)


## Polished, see-through, and lit on both faces — you look through the near
## side of the ball at the far side of it, so backface culling would hollow it.
func _glass(c: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(c.r, c.g, c.b, alpha)
	mat.metallic = 0.35
	mat.metallic_specular = 0.9
	mat.roughness = 0.06
	mat.clearcoat_enabled = true
	mat.clearcoat = 1.0
	mat.clearcoat_roughness = 0.0
	mat.rim_enabled = true
	mat.rim = 0.85
	mat.rim_tint = 0.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func set_color(c: Color) -> void:
	if _tint:
		_tint.albedo_color = Color(c.r, c.g, c.b, GLASS_A * (0.25 if _ghost else 1.0))


## Web godmode: players flying around as builders render as barely-there ghosts.
var _ghost := false

func set_ghost(on: bool) -> void:
	if _ghost == on:
		return
	_ghost = on
	for mi in _shell.get_children():
		var mat: StandardMaterial3D = (mi as MeshInstance3D).material_override
		mat.albedo_color.a *= 0.25 if on else 4.0
	for child in get_children():
		if child != _shell and child is Node3D:
			(child as Node3D).visible = not on


## Ride inside the glass: the model is parented to US, not to the shell, so it
## keeps its own orientation while the ball spins around it.
func hold(model: Node3D, fit := 0.85) -> void:
	add_child(model)
	var box: AABB = preload("res://Vehicles/vehicle.gd")._model_aabb(model)
	if box.size.y > 0.001:
		var s := (RADIUS * 2.0 * fit) / maxf(box.size.y, maxf(box.size.x, box.size.z))
		model.scale = Vector3.ONE * s
		var c := box.get_center() * s
		model.position = Vector3(-c.x, -c.y, -c.z)


## Rolling without slipping: omega = v / r about the axis across the travel.
## The passenger doesn't roll with it — they turn to face where they're going,
## like the local bear does inside its own ball.
func roll(vel: Vector3, delta: float) -> void:
	var flat := Vector3(vel.x, 0.0, vel.z)
	if flat.length() < 0.05:
		return
	_shell.rotate(Vector3.UP.cross(flat.normalized()).normalized(), (flat.length() / RADIUS) * delta)
	for child in get_children():
		if child != _shell and child is Node3D:
			(child as Node3D).rotation.y = -atan2(flat.z, flat.x) + PI
