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
## Picking is screen-space, from the crosshair when the mouse is captured and
## from the cursor when it is free. Screen-space beats raycasting thin geometry,
## which needs colliders either too fat to be precise or too thin to hit.
##
## The rig does not own the click. `self_input` is on for standalone use, but
## the build drone turns it off and calls click() itself, because the same
## button also selects and deletes and something has to decide which happens.

const Registry := preload("res://Items/parametric/registry.gd")
const Spec := preload("res://Items/parametric/spec.gd")

const PICK_PX := 44.0        # how near the aim point must be to grab a handle
const LINE_R := 0.09         # drawn line radius
const NODE_R := 0.34
const COL_IDLE := Color(0.55, 0.78, 1.0)
const COL_HOT := Color(1.0, 0.85, 0.3)
const COL_LIVE := Color(0.4, 1.0, 0.55)
const COL_EDGE := Color(0.1, 0.9, 1.0)
const OUTLINE_GROW := 0.07
const LABEL_LIFT := 0.55     # how far the readout floats off its handle

## Live during a drag, every frame, so every client sees it move.
signal param_changed(key: String, value: float)
signal node_changed(index: int, pos: Vector3)
## On release: the point at which it is worth telling the server.
signal edit_committed()

## Off when an owner arbitrates the click (see the header note).
var self_input := true
## Bodies a node drag must not land on: the structure being edited (it is right
## under the aim), and whatever the owner is flying. Set by the owner.
var ray_exclude: Array = []

var record: Dictionary = {}
var active := false

var _handles: Array = []           # the Spec dictionaries, rebuilt from record
var _bars: Array = []              # MeshInstance3D per handle, index-matched
var _outline: MeshInstance3D
var _label: Label3D
var _hot := -1                     # handle under the aim point
var _held := -1                    # handle being dragged
var _mat_idle: StandardMaterial3D
var _mat_hot: StandardMaterial3D
var _mat_live: StandardMaterial3D


func _ready() -> void:
	_mat_idle = _unlit(COL_IDLE)
	_mat_hot = _unlit(COL_HOT)
	_mat_live = _unlit(COL_LIVE)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0009
	_label.font_size = 48
	_label.outline_size = 10
	_label.outline_modulate = Color(0, 0, 0, 0.9)
	_label.no_depth_test = true
	_label.render_priority = 3
	_label.outline_render_priority = 2
	_label.visible = false
	add_child(_label)
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


## Point the rig at a record, or pass {} to put it away. `mesh` is the caller's
## already-built copy of the structure: the rig will build its own if none is
## offered, but the world node has just made one and building it twice is a
## whole mesh of pointless work on every selection.
func show_record(rec: Dictionary, mesh: Mesh = null) -> void:
	record = rec
	active = not rec.is_empty()
	visible = active
	_held = -1
	_hot = -1
	if not active:
		_clear()
		return
	_set_outline(mesh if mesh else _own_mesh())
	_rebuild_handles()


## Same record, changed contents: keep the drag alive while the geometry under
## it moves. Handle order is fixed per type, so the held index still means the
## same handle after the rebuild.
func refresh(rec: Dictionary, mesh: Mesh = null) -> void:
	if not active:
		return
	record = rec
	if mesh:
		_set_outline(mesh)
	var fresh := Registry.handles(rec)
	if fresh.size() == _handles.size():
		_handles = fresh
		_lay_out()
	else:
		# The node count changed under us; start over and drop the drag.
		_held = -1
		_rebuild_handles()


func is_dragging() -> bool:
	return _held >= 0


func hot_index() -> int:
	return _held if _held >= 0 else _hot


## What the aimed handle is, for a status line. "" when nothing is aimed.
func hot_label() -> String:
	var i := hot_index()
	return _readout(_handles[i]) if i >= 0 and i < _handles.size() else ""


## Press or release the grab button. True means the rig used it, so the caller
## should not also select, punch or delete with the same click.
func click(pressed: bool) -> bool:
	if not active:
		return false
	if pressed:
		if _hot < 0:
			return false
		_held = _hot
		(_bars[_held] as MeshInstance3D).material_override = _mat_live
		return true
	if _held < 0:
		return false
	_held = -1
	edit_committed.emit()
	return true


func _clear() -> void:
	for b in _bars:
		(b as Node).queue_free()
	_bars.clear()
	_handles.clear()
	if _label:
		_label.visible = false
	if _outline:
		_outline.queue_free()
		_outline = null


## A throwaway build, only for its mesh: used when the caller has none to lend.
func _own_mesh() -> Mesh:
	var built: Node3D = Registry.build(record, _mat_idle, false)
	if built == null:
		return null
	var out: Mesh = null
	for c in built.get_children():
		if c is MeshInstance3D:
			out = (c as MeshInstance3D).mesh
			break
	built.queue_free()
	return out


## The structure mesh, inside out and grown: an outline that follows the real
## silhouette rather than a box around it.
func _set_outline(mesh: Mesh) -> void:
	if mesh == null:
		if _outline:
			_outline.queue_free()
			_outline = null
		return
	if _outline == null:
		_outline = MeshInstance3D.new()
		var m := _unlit(COL_EDGE)
		m.cull_mode = BaseMaterial3D.CULL_FRONT
		m.grow = true
		m.grow_amount = OUTLINE_GROW
		m.no_depth_test = false
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(COL_EDGE.r, COL_EDGE.g, COL_EDGE.b, 0.85)
		_outline.material_override = m
		add_child(_outline)
	_outline.mesh = mesh


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
	if _held < 0:
		_hot = _pick()
	else:
		_drag()
	for i in _bars.size():
		var mat := _mat_idle
		if i == _held:
			mat = _mat_live
		elif i == _hot and _held < 0:
			mat = _mat_hot
		(_bars[i] as MeshInstance3D).material_override = mat
	_show_label()


## The readout floats over whichever handle is live, so the number you are
## changing is next to the thing you are changing it with.
func _show_label() -> void:
	var i := hot_index()
	if i < 0 or i >= _handles.size():
		_label.visible = false
		return
	var h: Dictionary = _handles[i]
	_label.text = _readout(h)
	_label.modulate = COL_LIVE if _held >= 0 else COL_HOT
	_label.global_position = (h["pos"] as Vector3) + Vector3.UP * LABEL_LIFT
	_label.visible = true


static func _readout(h: Dictionary) -> String:
	if int(h["node"]) >= 0:
		return "NODE %d" % int(h["node"])
	var unit := str(h.get("unit", ""))
	# A count reads as a count: 14 sides, not 14.0 sides.
	if unit == "" and absf(float(h["step"]) - 1.0) < 0.001:
		return "%s %d" % [h["label"], int(roundf(float(h["value"])))]
	return "%s %.2f%s" % [h["label"], float(h["value"]), unit]


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
	if not self_input or not active:
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if click(e.pressed):
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


## Where along the handle's own line the aim is pointing: the closest point
## between two skew lines. Sighting straight down the axis has no answer, so the
## value stays where it was rather than snapping somewhere arbitrary.
static func _closest_on_axis(origin: Vector3, axis: Vector3, ro: Vector3, rd: Vector3) -> Vector3:
	var w0 := ro - origin
	var b := rd.dot(axis)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-5:
		return origin
	return origin + axis * ((axis.dot(w0) - b * rd.dot(w0)) / denom)


## Nodes drag onto whatever is under the aim, and onto the horizontal plane they
## already sit on when that is nothing -- so a node pulled out over a void lands
## somewhere sane instead of flinging itself at the horizon.
func _ground_or_plane(ro: Vector3, rd: Vector3, y: float) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(ro, ro + rd * 4000.0)
	q.exclude = ray_exclude
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		return hit["position"]
	if absf(rd.y) < 1e-4:
		return ro + rd * 50.0
	return ro + rd * maxf((y - ro.y) / rd.y, 1.0)
