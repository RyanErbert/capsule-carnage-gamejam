extends Node3D

## The vampire gun's beam: a bright core with two dimmer strands coiling round
## it, drawn as camera-facing ribbons every frame. Shared by the local gun and
## the remote ghosts, so a beam looks the same whoever is firing it.
##
## `strength` is 0..1 and follows the heat: a fresh beam is thin and pink, an
## overheating one fat and white at the core.

const CORE_W := 0.05
const STRAND_W := 0.028
const COIL_R := 0.11          # how far the strands wander from the core
const COIL_TURNS := 2.4       # per 10 m of beam
const SPIN := 9.0             # rad/s the coil rotates
const SEGMENTS := 18
const CORE := Color(1.0, 0.36, 0.52)
const HOT := Color(1.0, 0.92, 0.95)
const STRAND := Color(0.72, 0.22, 0.95)

var _mesh: ImmediateMesh
var _t := 0.0
var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _strength := 0.0
var _on := false
var _tip: CPUParticles3D


func _ready() -> void:
	top_level = true
	_mesh = ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# Motes pulled off the target and up the beam
	_tip = CPUParticles3D.new()
	_tip.amount = 28
	_tip.lifetime = 0.5
	_tip.emitting = false
	_tip.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_tip.emission_sphere_radius = 0.45
	_tip.gravity = Vector3.ZERO
	_tip.initial_velocity_min = 1.5
	_tip.initial_velocity_max = 3.5
	_tip.scale_amount_min = 0.5
	_tip.scale_amount_max = 1.0
	var qm := QuadMesh.new()
	qm.size = Vector2(0.09, 0.09)
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = Color(1.0, 0.45, 0.6, 0.9)
	pm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.material = pm
	_tip.mesh = qm
	add_child(_tip)


## Draw from `from` to `to` this frame. Call every frame while firing.
func show_beam(from: Vector3, to: Vector3, strength: float, feeding := false) -> void:
	_from = from
	_to = to
	_strength = clampf(strength, 0.0, 1.0)
	_on = true
	_tip.global_position = to
	_tip.direction = (from - to).normalized()
	_tip.emitting = feeding


func hide_beam() -> void:
	_on = false
	_tip.emitting = false


func _process(delta: float) -> void:
	_t += delta
	_mesh.clear_surfaces()
	if not _on:
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam else _from + Vector3.UP
	var run := _to - _from
	var length := run.length()
	if length < 0.05:
		return
	var dir := run / length
	# A frame across the beam for the coil to turn in
	var ref := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var u := dir.cross(ref).normalized()
	var v := dir.cross(u)
	var core_c := CORE.lerp(HOT, _strength * _strength)
	core_c.a = 0.9
	_ribbon(_from, _to, CORE_W * (1.0 + _strength * 0.9), core_c, eye, Vector3.ZERO, Vector3.ZERO, 0.0, length)
	var strand_c := STRAND
	strand_c.a = 0.55 + 0.3 * _strength
	for k in 2:
		var phase := PI * k
		_ribbon(_from, _to, STRAND_W, strand_c, eye, u, v, phase, length)
	# Let the mesh shrink to nothing after release
	_on = false


## One camera-facing ribbon along the beam; with u/v set it coils instead.
func _ribbon(a: Vector3, b: Vector3, w: float, col: Color, eye: Vector3,
		u: Vector3, v: Vector3, phase: float, length: float) -> void:
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_mesh.surface_set_color(col)
	var prev := a
	var coil := u.length_squared() > 0.0
	for i in range(1, SEGMENTS + 1):
		var t := float(i) / float(SEGMENTS)
		var p := a.lerp(b, t)
		if coil:
			var ang := t * length * TAU * COIL_TURNS / 10.0 + _t * SPIN + phase
			# Taper: pinned to the core at both ends
			var r := COIL_R * sin(t * PI)
			p += (u * cos(ang) + v * sin(ang)) * r
		var seg := p - prev
		if seg.length() > 0.0001:
			var side := seg.normalized().cross((prev + p) * 0.5 - eye)
			side = Vector3.RIGHT * w if side.length() < 1e-5 else side.normalized() * w
			_mesh.surface_add_vertex(prev - side)
			_mesh.surface_add_vertex(p - side)
			_mesh.surface_add_vertex(prev + side)
			_mesh.surface_add_vertex(p - side)
			_mesh.surface_add_vertex(p + side)
			_mesh.surface_add_vertex(prev + side)
		prev = p
	_mesh.surface_end()
