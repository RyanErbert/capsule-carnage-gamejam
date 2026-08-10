extends Node

## Build placement, child of the player (PORT_BLUEPRINT.md §4.2/§4.3).
## Active while slot 0 holds block/wall/ramp/platform: ghost preview snapped
## to the 4-unit grid, R rotates 90°, scroll adjusts reach (16, 4..100), left
## click places (hold + move = drag-build along a locked axis, like the web).
## bridge_gun is aim-and-click: a walkway from under you to the aim point.

const BUILD_TYPES := ["block", "wall", "ramp", "platform"]
const DEFAULT_REACH := 16.0
const MIN_REACH := 4.0
const MAX_REACH := 100.0
const BRIDGE_MAX := 100.0
const GHOST_OK := Color(0.3, 0.6, 1.0, 0.45)
const GHOST_BAD := Color(1.0, 0.2, 0.2, 0.45)

@onready var player: CharacterBody3D = get_parent()
@onready var _items: Node = get_parent().get_node("ItemController")

var reach := DEFAULT_REACH
var rotation_steps := 0
var can_place := false
var build_target: Dictionary = {}   # {x,y,z,ry,rx} of the current ghost

var _world_builds: Node
var _ghosts: Dictionary = {}   # type -> MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _dragging := false
var _drag_lock := {}           # {axis: "x"|"y"|"z", value: float}
var _last_cell := ""


func _ready() -> void:
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.albedo_color = GHOST_OK
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for type in BUILD_TYPES:
		var g := MeshInstance3D.new()
		g.top_level = true
		g.visible = false
		g.material_override = _ghost_mat
		match type:
			"ramp":
				g.mesh = preload("res://Items/builds.gd").wedge_mesh(4.0, 4.0, 4.0)
			"wall":
				var wb := BoxMesh.new(); wb.size = Vector3(4, 4, 1); g.mesh = wb
			"platform":
				var pb := BoxMesh.new(); pb.size = Vector3(4, 1, 4); g.mesh = pb
			_:
				var bb := BoxMesh.new(); bb.size = Vector3(4, 4, 4); g.mesh = bb
		add_child(g)
		_ghosts[type] = g


func active_build_type() -> String:
	if player.godmode or _items.inventory.is_empty():
		return ""
	var t: String = _items.inventory[0]["type"]
	return t if t in BUILD_TYPES else ""


func is_build_active() -> bool:
	return active_build_type() != "" and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dragging = false
		_drag_lock = {}
	if not is_build_active():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		rotation_steps = (rotation_steps + 1) % 4
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				reach = clampf(reach + 4.0, MIN_REACH, MAX_REACH)
			MOUSE_BUTTON_WHEEL_DOWN:
				reach = clampf(reach - 4.0, MIN_REACH, MAX_REACH)


## Called from ItemController.use_item() on left click with a build item.
func try_place() -> void:
	if not can_place or build_target.is_empty():
		return
	var type := active_build_type()
	if type == "":
		return
	# Drag-build: walls rail along their facing axis, everything else stays
	# on the clicked height (web mousedown axis lock).
	_dragging = true
	if type == "wall":
		_drag_lock = {"axis": "z", "value": build_target["z"]} if rotation_steps % 2 == 0 \
			else {"axis": "x", "value": build_target["x"]}
	else:
		_drag_lock = {"axis": "y", "value": build_target["y"]}
	_last_cell = _cell_key(build_target)
	Net.emit_event("placeBuild", build_target.merged({"type": type}))
	_items._use_ammo()


func fire_bridge_gun() -> void:
	var target: Variant = _items._aim_point()
	if target == null:
		return
	var origin: Vector3 = player.global_position + Vector3(0, -0.4, 0)
	var to: Vector3 = target
	var dist := origin.distance_to(to)
	if dist > BRIDGE_MAX:
		dist = BRIDGE_MAX
		to = origin + (to - origin).normalized() * BRIDGE_MAX
	var mid := origin.lerp(to, 0.5)
	var dir := (to - origin).normalized()
	Net.emit_event("placeBuild", {
		"type": "bridge", "x": mid.x, "y": mid.y, "z": mid.z,
		"ry": atan2(dir.x, dir.z), "rx": -asin(clampf(dir.y, -1.0, 1.0)),
		"length": dist,
	})
	_items._use_ammo()


func _cell_key(t: Dictionary) -> String:
	return "%s,%s,%s" % [t["x"], t["y"], t["z"]]


func _process(_delta: float) -> void:
	var type := active_build_type()
	for t in _ghosts:
		_ghosts[t].visible = t == type and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if type == "" or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		can_place = false
		return

	# Aim: camera-center ray vs level + builds, reach-limited (web hoverRaycaster)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * reach)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	var target_pt: Vector3
	if hit:
		target_pt = hit["position"] + hit["normal"] * 0.1
	else:
		target_pt = from + dir * reach

	# Snap to the 4-unit voxel grid: cell center = floor(p/4)*4 + 2
	var fx := floorf(target_pt.x / 4.0) * 4.0 + 2.0
	var fy := floorf(target_pt.y / 4.0) * 4.0 + 2.0
	var fz := floorf(target_pt.z / 4.0) * 4.0 + 2.0
	var rot_y := rotation_steps * (PI / 2.0)

	if type == "wall":
		match rotation_steps:
			0: fz -= 2.0
			1: fx -= 2.0
			2: fz += 2.0
			3: fx += 2.0
	elif type == "platform":
		fy -= 1.5

	if not _drag_lock.is_empty():
		match _drag_lock["axis"]:
			"x": fx = _drag_lock["value"]
			"y": fy = _drag_lock["value"]
			"z": fz = _drag_lock["value"]

	var pos := Vector3(fx, fy, fz)
	var ghost: MeshInstance3D = _ghosts[type]
	ghost.position = pos
	ghost.rotation = Vector3(0, rot_y, 0)
	build_target = {"x": fx, "y": fy, "z": fz, "ry": rot_y, "rx": 0.0}

	if _world_builds == null:
		_world_builds = get_tree().get_first_node_in_group("world_builds")
	var overlap: bool = _world_builds != null and _world_builds.has_build_at(pos, type, rot_y, 0.0)
	can_place = not overlap
	_ghost_mat.albedo_color = GHOST_OK if can_place else GHOST_BAD

	# Drag-build: keep placing as the ghost enters new cells while held
	if _dragging and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and can_place:
		var key := _cell_key(build_target)
		if key != _last_cell:
			_last_cell = key
			Net.emit_event("placeBuild", build_target.merged({"type": type}))
			_items._use_ammo()
			if _items.inventory.is_empty() or _items.inventory[0]["type"] != type:
				_dragging = false
				_drag_lock = {}
