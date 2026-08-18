extends Node3D

## The visible, grabbable half of a parametric structure.
##
## A parameter here is a distance from somewhere in some direction, so the
## honest way to show one is as the LINE it measures: the height handle is a
## line from the middle of the wall up to its top, and dragging its end is
## dragging the height. A sphere floating near the wall would say "something is
## adjustable"; the line says which measurement it is and which way it runs.
##
## Selection is an inverse hull -- the structure's own mesh, front faces culled
## and grown along its normals, drawn behind it. That reads as an outline on any
## silhouette, including the holes punched through it, with no screen-space pass
## and no second camera.
##
## The mouse is captured in game, so picking is from the crosshair rather than a
## cursor: handles are projected to the screen and the one nearest the aim point
## wins. Screen-space picking also beats raycasting thin geometry, which needs
## colliders either too fat to be precise or too thin to hit.

const Registry := preload("res://Items/parametric/registry.gd")
const Spec := preload("res://Items/parametric/spec.gd")

const PICK_PX := 44.0        # how near the crosshair must be to grab a handle
const LINE_R := 0.09         # drawn line radius
const NODE_R := 0.34
const COL_IDLE := Color(0.55, 0.78, 1.0)
const COL_HOT := Color(1.0, 0.85, 0.3)
const COL_LIVE := Color(0.4, 1.0, 0.55)
const COL_EDGE := Color(0.1, 0.9, 1.0)
const OUTLINE_GROW := 0.07

## Live during a drag, every frame, so every client sees it move.
signal param_changed(key: String, value: float)
signal node_changed(index: int, pos: Vector3)
## On release: the point at which it is worth telling the server.
signal edit_committed()

var record: Dictionary = {}
var active := false

var _handles: Array = []           # the Spec dictionaries, rebuilt from record
var _bars: Array = []              # MeshInstance3D per handle, index-matched
var _outline: MeshInstance3D
var _hot := -1                     # handle under the crosshair
var _held := -1                    # handle being dragged
var _mat_idle: StandardMaterial3D
var _mat_hot: StandardMaterial3D
var _mat_live: StandardMaterial3D


func _ready() -> void:
	_mat_idle = _unlit(COL_IDLE)
	_mat_hot = _unlit(COL_HOT)
	_mat_live = _unlit(COL_LIVE)
	set_process(true)
	set_process_unhandled_input(true)


static func _unlit(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	# Handles read through the wall they belong to. Editing something is exactly
	# when you need to see the far side of it.
	m.no_depth_test = true
	m.render_priority = 2
	return m


## Point the rig at a record, or pass {} to put it away.
func show_record(rec: Dictionary) -> void:
	record = rec
	active = not rec.is_empty()
	visible = active
	_held = -1
	_hot = -1
	if not active:
		_clear()
		return
	_rebuild_outline()
	_rebuild_handles()


func _clear() -> void:
	for b in _bars:
		(b as Node).queue_free()
	_bars.clear()
	_handles.clear()
	if _outline:
		_outline.queue_free()
		_outline = null


## The structure mesh, inside out and grown: an outline that follows the real
## silhouette rather than a box around it.
func _rebuild_outline() -> void:
	if _outline:
		_outline.queue_free()
		_outline = null
	var built: Node3D = Registry.build(record, _mat_idle, false)
	if built == null:
		return
	var src: MeshInstance3D = null
	for c in built.get_children():
		if c is MeshInstance3D:
			src = c
			break
	if src == null:
		built.queue_free()
		return
	_outline = MeshInstance3D.new()
	_outline.mesh = src.mesh
	var m := _unlit(COL_EDGE)
	m.cull_mode = BaseMaterial3D.CULL_FRONT
	m.grow = true
	m.grow_amount = OUTLINE_GROW
	m.no_depth_test = false
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.85)
	_outline.material_override = m
	add_child(_outline)
	built.queue_free()


func _rebuild_handles() -> void:
	for b in _bars:
		(b as Node).queue_free()
	_bars.clear()
	_handles = Registry.handles(record)
	for h in _handles:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		mi.material_override = _mat_idle
		add_child(mi)
		_bars.append(mi)
	_lay_out()


## Each bar spans origin -> pos, which for a parameter IS the measurement. Node
## handles have no length, so they get a cube on the point instead.
func _lay_out() -> void:
	for i in _handles.size():
		var h: Dictionary = _handles[i]
		var mi: MeshInstance3D = _bars[i]
		var box: BoxMesh = mi.mesh
		if int(h["node"]) >= 0:
			box.size = Vector3.ONE * NODE_R * 2.0
			mi.global_position = h["pos"]
			mi.global_basis = Basis()
			continue
		var a: Vector3 = h["origin"]
		var b: Vector3 = h["pos"]
		var span := b - a
		var span_len := span.length()
		box.size = Vector3(LINE_R * 2.0, LINE_R * 2.0, maxf(span_len, 0.05))
		if span_len > 0.001:
			mi.look_at_from_position((a + b) * 0.5, b, _least_aligned(span / span_len))
		else:
			mi.global_position = a


## look_at needs an up vector that is not parallel to the direction.
static func _least_aligned(dir: Vector3) -> Vector3:
	return Vector3.RIGHT if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP


func _process(_dt: float) -> void:
	if not active or _handles.is_empty():
		return
	if _held >= 0:
		_drag()
		return
	_hot = _pick()
	for i in _bars.size():
		(_bars[i] as MeshInstance3D).material_override = _mat_hot if i == _hot else _mat_idle


## Crosshair when the mouse is captured, cursor when it is not.
func _aim_px() -> Vector2:
	var vp := get_viewport()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return vp.get_visible_rect().size * 0.5
	return vp.get_mouse_position()


## Nearest handle to the aim point in screen space, or -1. Distance is to the
## whole bar, not its centre, so a long height line is grabbable anywhere along
## it rather than only in the middle.
func _pick() -> int:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return -1
	var aim := _aim_px()
	var best := -1
	var best_d := PICK_PX
	for i in _handles.size():
		var h: Dictionary = _handles[i]
		var a3: Vector3 = h["origin"] if int(h["node"]) < 0 else h["pos"]
		var b3: Vector3 = h["pos"]
		if cam.is_position_behind(a3) or cam.is_position_behind(b3):
			continue
		var d := _dist_to_segment(aim, cam.unproject_position(a3), cam.unproject_position(b3))
		if d < best_d:
			best_d = d
			best = i
	return best


static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-6:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _unhandled_input(e: InputEvent) -> void:
	if not active:
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and _hot >= 0:
			_held = _hot
			(_bars[_held] as MeshInstance3D).material_override = _mat_live
			get_viewport().set_input_as_handled()
		elif not e.pressed and _held >= 0:
			_held = -1
			edit_committed.emit()
			get_viewport().set_input_as_handled()


func _drag() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var aim := _aim_px()
	var ro := cam.project_ray_origin(aim)
	var rd := cam.project_ray_normal(aim)
	var h: Dictionary = _handles[_held]

	if int(h["node"]) >= 0:
		var hit := _ground_or_plane(ro, rd, (h["pos"] as Vector3).y)
		_handles[_held]["pos"] = hit
		node_changed.emit(int(h["node"]), hit)
		_lay_out()
		return

	var on_axis := _closest_on_axis(h["origin"], h["axis"], ro, rd)
	var v := Spec.value_at(h, on_axis)
	_handles[_held]["value"] = v
	_handles[_held]["pos"] = (h["origin"] as Vector3) + (h["axis"] as Vector3) * v * float(h["scale"])
	param_changed.emit(str(h["key"]), v)
	_lay_out()


## Where along the handle's own line the crosshair is pointing: the closest
## point between two skew lines. Sighting straight down the axis has no answer,
## so the value stays where it was rather than snapping somewhere arbitrary.
static func _closest_on_axis(origin: Vector3, axis: Vector3, ro: Vector3, rd: Vector3) -> Vector3:
	var w0 := ro - origin
	var b := rd.dot(axis)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-5:
		return origin
	return origin + axis * ((axis.dot(w0) - b * rd.dot(w0)) / denom)


## Nodes drag onto whatever is under the crosshair, and onto the horizontal
## plane they already sit on when that is nothing -- so a node pulled out over a
## void lands somewhere sane instead of flinging itself at the horizon.
func _ground_or_plane(ro: Vector3, rd: Vector3, y: float) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(ro, ro + rd * 4000.0)
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		return hit["position"]
	if absf(rd.y) < 1e-4:
		return ro + rd * 50.0
	return ro + rd * maxf((y - ro.y) / rd.y, 1.0)
