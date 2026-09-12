extends Node3D

## A quest target you reach by standing on it. A faint ring on the ground;
## when the player is inside it, the server hears "questReach <target>" once
## and any open quest pointed at that target completes.

const RADIUS := 2.6
const REPORT_EVERY := 8.0

var target := ""
var player: CharacterBody3D
var _cd := 0.0
var _ring: MeshInstance3D
var _t := 0.0


func _ready() -> void:
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = RADIUS - 0.25
	torus.outer_radius = RADIUS
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.85, 0.4, 0.55)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.4)
	torus.material = m
	_ring.mesh = torus
	_ring.scale = Vector3(1, 0.12, 1)
	_ring.position.y = 0.12
	add_child(_ring)


func _process(delta: float) -> void:
	_t += delta
	_ring.scale.x = 1.0 + 0.04 * sin(_t * 2.5)
	_ring.scale.z = _ring.scale.x
	_cd = maxf(0.0, _cd - delta)
	if player == null or _cd > 0.0 or player.dead:
		return
	var d := player.global_position - global_position
	if Vector2(d.x, d.z).length() < RADIUS and absf(d.y) < 3.0:
		_cd = REPORT_EVERY
		Net.emit_event("questReach", target)
