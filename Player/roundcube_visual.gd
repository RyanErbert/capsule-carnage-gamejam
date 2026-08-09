extends Node3D

## The web "cube" player visual (PORT_BLUEPRINT.md — createPlayerVisual
## 'roundcube'): glassy morphing cube + white it-player outline hull.
## Used by both the local player (FRIENDSLOP_MODEL=cube) and remote ghosts.

@onready var _body: MeshInstance3D = $Body
@onready var _outline: MeshInstance3D = $Outline

var _body_mat: ShaderMaterial
var _outline_mat: ShaderMaterial


func _ready() -> void:
	# Unique materials per instance so color/morph don't leak between players.
	_body_mat = _body.material_override.duplicate()
	_body.material_override = _body_mat
	_outline_mat = _outline.material_override.duplicate()
	_outline.material_override = _outline_mat
	_outline.visible = false


func set_color(c: Color) -> void:
	var cur: Color = _body_mat.get_shader_parameter("albedo")
	_body_mat.set_shader_parameter("albedo", Color(c.r, c.g, c.b, cur.a))


func set_alpha(a: float) -> void:
	var cur: Color = _body_mat.get_shader_parameter("albedo")
	_body_mat.set_shader_parameter("albedo", Color(cur.r, cur.g, cur.b, a))


func set_smoothing(s: float) -> void:
	s = clampf(s, 0.0, 1.0)
	_body_mat.set_shader_parameter("smoothing", s)
	_outline_mat.set_shader_parameter("smoothing", s)


func set_outline_visible(v: bool) -> void:
	_outline.visible = v
