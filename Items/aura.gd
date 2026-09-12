extends Node3D

## What a player wears when they have swallowed a ball. Attached to a body
## (local or ghost) and driven by set_kind():
##
##   ""      nothing
##   "heal"  a corpse ball's energy is still ticking into them: a slow drift
##           of pale green motes and a faint cool cast
##   "ball"  the Fortwars game ball: electric blue, crackling, and a pillar of
##           light straight up into the sky so the whole map knows where it is
##
## The tint itself is applied by the owner (marble_shell / roundcube take a
## colour), because they know what they are made of; this node only knows how
## to glow, spark and beam.

const BLUE := Color(0.35, 0.75, 1.0)
const GREEN := Color(0.55, 1.0, 0.75)
const PILLAR_H := 140.0
const PILLAR_R := 0.55

var kind := ""
var _motes: CPUParticles3D
var _sparks: CPUParticles3D
var _pillar: MeshInstance3D
var _pillar_mat: StandardMaterial3D
var _glow: OmniLight3D
var _t := 0.0


func _ready() -> void:
	_motes = _particles(GREEN, 18, 1.6, 0.3, 0.9, Vector2(0.07, 0.07))
	_motes.gravity = Vector3(0, 0.6, 0)
	add_child(_motes)
	_sparks = _particles(BLUE, 46, 0.35, 3.0, 7.0, Vector2(0.14, 0.03))
	_sparks.gravity = Vector3.ZERO
	_sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_sparks.emission_sphere_radius = 0.5
	add_child(_sparks)
	_glow = OmniLight3D.new()
	_glow.light_color = BLUE
	_glow.omni_range = 7.0
	_glow.light_energy = 0.0
	_glow.shadow_enabled = false
	add_child(_glow)
	# The pillar: an additive tube, brightest at the body and fading with height
	_pillar = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = PILLAR_R * 0.6
	cm.bottom_radius = PILLAR_R
	cm.height = PILLAR_H
	cm.radial_segments = 14
	cm.rings = 1
	_pillar.mesh = cm
	_pillar_mat = StandardMaterial3D.new()
	_pillar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pillar_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pillar_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_pillar_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pillar_mat.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.22)
	_pillar_mat.emission_enabled = true
	_pillar_mat.emission = BLUE
	_pillar_mat.emission_energy_multiplier = 1.4
	_pillar.material_override = _pillar_mat
	_pillar.position.y = PILLAR_H * 0.5
	_pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pillar)
	set_kind("")


func set_kind(k: String) -> void:
	kind = k
	_motes.emitting = k == "heal"
	_sparks.emitting = k == "ball"
	_pillar.visible = k == "ball"
	_glow.light_energy = 2.2 if k == "ball" else (0.5 if k == "heal" else 0.0)
	_glow.light_color = GREEN if k == "heal" else BLUE


## The colour a body wearing this should be tinted, or the colour given.
static func tint_for(k: String, base: Color) -> Color:
	match k:
		"ball":
			return Color(0.25, 0.7, 1.0)
		"heal":
			return base.lerp(GREEN, 0.35)
	return base


func _process(delta: float) -> void:
	if kind != "ball":
		return
	_t += delta
	# The pillar breathes and the light flickers, like something electric
	var pulse := 0.85 + 0.15 * sin(_t * 6.0) + 0.06 * sin(_t * 23.0)
	_pillar_mat.albedo_color.a = 0.16 + 0.1 * pulse
	_glow.light_energy = 1.6 + 1.2 * pulse
	_pillar.scale.x = 0.9 + 0.2 * pulse
	_pillar.scale.z = _pillar.scale.x


static func _particles(c: Color, amount: int, life: float, v0: float, v1: float,
		size: Vector2) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.emitting = false
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.42
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = v0
	p.initial_velocity_max = v1
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.0
	var qm := QuadMesh.new()
	qm.size = size
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, 0.9)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.0
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.material = m
	p.mesh = qm
	return p
