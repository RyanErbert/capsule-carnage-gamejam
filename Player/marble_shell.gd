extends Node3D

## The glass marble everybody rides around in.
##
## One sphere, two colours: the top half tinted the player's colour, the
## bottom half an off-white milk glass. Rolling a plain sphere is invisible —
## every frame looks the same — so the seam between the halves is what makes
## the spin read, the same way a two-tone marble does. The shell rolls;
## whatever is INSIDE it does not, so the character stays the right way up
## while their ball tumbles.
##
## The split is a SHADER, not two hemisphere meshes: SphereMesh.is_hemisphere
## caps each dome with a flat disc, and through glass you see that disc lying
## across the middle of the ball like a plate.
##
## Used by the local player (Player/player.tscn CapsuleLogic) and by every
## remote ghost (Net/remote_player.gd), so both look like the same object.

# Matches the player's collider (SphereShape3D at 0.785 scale) so the glass
# sits exactly where the physics does, and so the roll rate is honest.
const RADIUS := 0.393
const OFFWHITE := Color(0.93, 0.92, 0.87)
const GLASS_A := 0.34        # how much of the model inside shows through
const MILK_A := 0.62         # the pale half is frostier, so the seam reads

# Front faces ONLY. Drawing the inside of the glass as well puts the far half
# of the shell behind the near half, and the two equator seams line up into
# what looks like a solid plate lying across the middle of the ball.
#
# The object-space height of the fragment picks which half of the glass it is,
# so the seam spins with the mesh.
const GLASS_SHADER := "
shader_type spatial;
render_mode blend_mix, specular_schlick_ggx;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec4 milk : source_color = vec4(1.0);
uniform float tint_alpha = 0.34;
uniform float milk_alpha = 0.62;
varying vec3 local_pos;
void vertex() {
	local_pos = VERTEX;
}
void fragment() {
	bool upper = local_pos.y > 0.0;
	ALBEDO = upper ? tint.rgb : milk.rgb;
	ALPHA = upper ? tint_alpha : milk_alpha;
	METALLIC = 0.35;
	SPECULAR = 0.9;
	ROUGHNESS = 0.06;
	RIM = 0.85;
	RIM_TINT = 0.4;
	CLEARCOAT = 1.0;
	CLEARCOAT_ROUGHNESS = 0.0;
}
"

var _shell: Node3D
var _glass: ShaderMaterial
var _color := Color.WHITE


func _init() -> void:
	_shell = Node3D.new()
	add_child(_shell)
	var shader := Shader.new()
	shader.code = GLASS_SHADER
	_glass = ShaderMaterial.new()
	_glass.shader = shader
	_glass.set_shader_parameter("milk", OFFWHITE)
	var mi := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = RADIUS
	ball.height = RADIUS * 2.0
	ball.radial_segments = 32
	ball.rings = 16
	mi.mesh = ball
	mi.material_override = _glass
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.add_child(mi)
	_apply_alpha()


func set_color(c: Color) -> void:
	_color = c
	_glass.set_shader_parameter("tint", c)


## Web godmode: players flying around as builders render as barely-there ghosts.
var _ghost := false

func set_ghost(on: bool) -> void:
	if _ghost == on:
		return
	_ghost = on
	_apply_alpha()
	for child in get_children():
		if child != _shell and child is Node3D:
			(child as Node3D).visible = not on


func _apply_alpha() -> void:
	var f := 0.25 if _ghost else 1.0
	_glass.set_shader_parameter("tint_alpha", GLASS_A * f)
	_glass.set_shader_parameter("milk_alpha", MILK_A * f)


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
