extends Node3D

## The weapon in your hands, mounted on the body. The rig swings to face
## wherever the aim ray points — yaw AND pitch — with the gun held off to the
## right of that line so it reads as shouldered instead of swallowed by the
## marble. Non-weapon items (pads, blocks, mines) holster it entirely.
##
## The local player drives this from item_controller; remotes get the held
## type and aim direction piggybacked on playerMoved and drive their own copy,
## so everyone sees the same gun pointed the same way.

const MOUNT := Vector3(0.34, -0.04, -0.42)   # right of, and ahead of, the body
const HELD := ["machinegun", "rocket", "grapple", "bridge_gun", "terragun"]
const TURN := 16.0    # rad/s the rig chases a new aim direction
const MODEL_SCALE := 0.62   # guns are modelled full size, worn at bear scale

var _kind := ""
var _holstered := false
var _model: Node3D
var _aim := Vector3.FORWARD


func set_weapon(kind: String) -> void:
	if kind == _kind:
		return
	_kind = kind
	if _model:
		_model.queue_free()
		_model = null
	_apply_visible()
	if not (kind in HELD):
		return
	_model = build_model(kind)
	_model.position = MOUNT
	_model.scale = Vector3.ONE * MODEL_SCALE
	add_child(_model)


## Riding, piloting, flying the build drone or dead: no gun on the body.
func set_holstered(on: bool) -> void:
	if on == _holstered:
		return
	_holstered = on
	_apply_visible()


func _apply_visible() -> void:
	visible = not _holstered and (_kind in HELD)


func aim(dir: Vector3) -> void:
	if dir.length_squared() > 0.0001:
		_aim = dir.normalized()


func _process(delta: float) -> void:
	if not visible:
		return
	# Straight up or down would make looking_at degenerate
	var up := Vector3.UP if absf(_aim.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var target := Basis.looking_at(_aim, up)
	basis = basis.slerp(target, minf(1.0, TURN * delta)).orthonormalized()


# --- Models ------------------------------------------------------------------
# Low-poly boxes in the same language as the bots, all modelled facing -Z.

static func build_model(kind: String) -> Node3D:
	match kind:
		"rocket":
			return _rocket_launcher()
		"grapple":
			return _grapple_gun()
		"bridge_gun":
			return _bridge_gun()
		"terragun":
			return _terra_gun()
		_:
			return _machinegun()


static func _steel() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.38, 0.4, 0.45)
	m.metallic = 0.45
	m.roughness = 0.5
	return m


static func _grip_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.19, 0.18, 0.2)
	m.roughness = 0.85
	return m


static func _glow(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.6
	return m


static func _box(root: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D,
		pitch := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	mi.rotation.x = pitch
	root.add_child(mi)
	return mi


static func _tube(root: Node3D, radius: float, length: float, pos: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = length
	cm.radial_segments = 10
	cm.material = mat
	mi.mesh = cm
	mi.position = pos
	mi.rotation.x = PI / 2.0   # lie the barrel down the -Z axis
	root.add_child(mi)
	return mi


static func _machinegun() -> Node3D:
	var root := Node3D.new()
	var steel := _steel()
	var grip := _grip_mat()
	_box(root, Vector3(0.11, 0.14, 0.46), Vector3(0, 0, 0), steel)          # receiver
	_box(root, Vector3(0.06, 0.06, 0.46), Vector3(0, 0.02, -0.44), steel)   # barrel
	_box(root, Vector3(0.09, 0.09, 0.07), Vector3(0, 0.02, -0.68), grip)    # muzzle brake
	_box(root, Vector3(0.05, 0.05, 0.16), Vector3(0, 0.09, -0.3), grip)     # gas block
	_box(root, Vector3(0.08, 0.2, 0.11), Vector3(0, -0.16, 0.0), grip)      # magazine
	_box(root, Vector3(0.06, 0.15, 0.07), Vector3(0, -0.13, 0.18), grip, 0.25)  # pistol grip
	_box(root, Vector3(0.07, 0.1, 0.24), Vector3(0, -0.01, 0.33), steel)    # stock
	_box(root, Vector3(0.025, 0.05, 0.025), Vector3(0, 0.11, -0.16), grip)  # rear sight
	_box(root, Vector3(0.025, 0.05, 0.025), Vector3(0, 0.08, -0.6), grip)   # front post
	return root


static func _rocket_launcher() -> Node3D:
	var root := Node3D.new()
	var steel := _steel()
	var grip := _grip_mat()
	_tube(root, 0.1, 0.95, Vector3(0, 0.03, -0.15), steel)                  # tube
	_tube(root, 0.13, 0.14, Vector3(0, 0.03, 0.3), grip)                    # blast cone
	_tube(root, 0.12, 0.08, Vector3(0, 0.03, -0.58), grip)                  # muzzle ring
	_box(root, Vector3(0.05, 0.05, 0.05), Vector3(0, 0.03, -0.63), _glow(Color(1.0, 0.45, 0.2)))
	_box(root, Vector3(0.07, 0.12, 0.18), Vector3(0, 0.14, -0.05), steel)   # optic housing
	_box(root, Vector3(0.05, 0.05, 0.05), Vector3(0, 0.16, -0.15), _glow(Color(0.4, 0.9, 1.0)))
	_box(root, Vector3(0.06, 0.16, 0.08), Vector3(0, -0.11, 0.06), grip, 0.2)   # grip
	_box(root, Vector3(0.06, 0.12, 0.08), Vector3(0, -0.08, -0.3), grip, -0.2)  # fore grip
	return root


static func _grapple_gun() -> Node3D:
	var root := Node3D.new()
	var steel := _steel()
	var grip := _grip_mat()
	_box(root, Vector3(0.1, 0.13, 0.3), Vector3(0, 0, 0), steel)            # body
	_box(root, Vector3(0.06, 0.06, 0.22), Vector3(0, 0.02, -0.24), steel)   # launch rail
	_box(root, Vector3(0.06, 0.14, 0.07), Vector3(0, -0.13, 0.06), grip, 0.25)  # grip
	# Hook prongs splayed off the nose
	for side: float in [-1.0, 1.0]:
		var prong := _box(root, Vector3(0.025, 0.025, 0.14), Vector3(side * 0.05, 0.02, -0.38), grip)
		prong.rotation.y = side * 0.45
	_box(root, Vector3(0.025, 0.025, 0.14), Vector3(0, -0.03, -0.38), grip)
	_box(root, Vector3(0.09, 0.09, 0.06), Vector3(0, 0.02, -0.06),
		_glow(Color(0.25, 1.0, 0.4)))                                       # spool light
	return root


## Terraformer: a wide-mouthed earth shaper with a charge cell slung under it.
## The flared nozzle is what tells it apart from the guns at bear scale.
static func _terra_gun() -> Node3D:
	var root := Node3D.new()
	var steel := _steel()
	var grip := _grip_mat()
	_box(root, Vector3(0.13, 0.15, 0.34), Vector3(0, 0, 0), steel)          # body
	_tube(root, 0.07, 0.26, Vector3(0, 0.01, -0.26), steel)                 # throat
	_tube(root, 0.16, 0.1, Vector3(0, 0.01, -0.43), grip)                   # flared nozzle
	_tube(root, 0.12, 0.03, Vector3(0, 0.01, -0.47),
		_glow(Color(0.85, 0.65, 0.25)))                                     # emitter face
	# Charge cell: the thing your health is going into
	_tube(root, 0.07, 0.22, Vector3(0, -0.14, 0.06), grip).rotation = Vector3(0, 0, PI / 2.0)
	_box(root, Vector3(0.16, 0.03, 0.03), Vector3(0, -0.14, -0.04),
		_glow(Color(0.35, 1.0, 0.55)))                                      # charge bar
	_box(root, Vector3(0.05, 0.14, 0.07), Vector3(0, -0.13, 0.13), grip, 0.25)  # grip
	_box(root, Vector3(0.04, 0.09, 0.05), Vector3(0, 0.11, -0.1), grip)     # sight
	return root


static func _bridge_gun() -> Node3D:
	var root := Node3D.new()
	var steel := _steel()
	var grip := _grip_mat()
	_box(root, Vector3(0.16, 0.16, 0.34), Vector3(0, 0, 0), steel)          # emitter block
	_box(root, Vector3(0.2, 0.2, 0.06), Vector3(0, 0, -0.2), grip)          # aperture ring
	_box(root, Vector3(0.13, 0.13, 0.03), Vector3(0, 0, -0.24),
		_glow(Color(0.4, 0.8, 1.0)))                                        # aperture
	for side: float in [-1.0, 1.0]:
		_box(root, Vector3(0.03, 0.1, 0.3), Vector3(side * 0.1, 0.12, 0.02), grip)
	_box(root, Vector3(0.06, 0.15, 0.08), Vector3(0, -0.14, 0.1), grip, 0.25)   # grip
	return root
