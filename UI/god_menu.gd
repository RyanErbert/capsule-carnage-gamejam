extends PanelContainer

## God menu (web §6.8, F4 — here on tilde/backtick per Ryan). Toggling it
## enters/leaves god mode: free-fly, mouse freed for the menu, remotes see
## you as a 30% ghost, and the server hands the oddball off if you held it.
##
## Controls while open: WASD fly (camera-relative), Space/E up, Shift/Q down,
## hold RIGHT mouse to look. GIVE buttons drop items straight into your
## inventory; with a pedestal tool armed, LEFT click places (or deletes) at
## the clicked spot.

const GIVE_ITEMS := [
	"grapple", "launch_pad", "boost_pad", "teleporter",
	"machinegun", "rocket", "mines",
	"block", "wall", "ramp", "platform", "bridge_gun",
]
const PED_TOOLS := [["green", "#44ff44"], ["red", "#ff4444"], ["yellow", "#ffff44"], ["channel", "#66ccff"], ["delete", "#aaaaaa"]]
const PROPS := ["building_1.glb", "building_2.glb", "building_3.glb", "building_4.glb", "building_5.glb", "tree_1.glb", "cactus.glb", "grass.glb"]

var _player: CharacterBody3D
var _world_items: Node
var _world_props: Node
var _tool := ""   # "", "green", "red", "yellow", "channel", "delete", "prop:<glb>"
var _tool_buttons: Dictionary = {}
var _status: Label
var _drone: CharacterBody3D
var _channel_nodes: Array = []
var _channel_markers: Array = []
# God build mode (web: godmode build tools + the 9^3 grid-point cloud)
const BUILD_TYPES := ["block", "wall", "ramp", "platform"]
var _build_rot := 0
var _build_target: Dictionary = {}
var _build_ghosts: Dictionary = {}
var _ghost_mat: StandardMaterial3D
var _grid_points: MultiMeshInstance3D
var _grid_center := Vector3(1e9, 0, 0)


func _ready() -> void:
	visible = false
	_build_ui()


func _find_refs() -> bool:
	if _player == null:
		var sync := get_tree().get_first_node_in_group("net_sync")
		if sync:
			_player = sync.player
	if _world_items == null and _player:
		_world_items = _player.get_parent().get_node_or_null("WorldItems")
	if _world_props == null and _player:
		_world_props = _player.get_parent().get_node_or_null("WorldProps")
	return _player != null


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and get_viewport().gui_get_focus_owner() == null:
		if event.keycode == KEY_QUOTELEFT:
			toggle()
		elif event.keycode == KEY_R and visible and _tool.begins_with("build:"):
			_build_rot = (_build_rot + 1) % 4


func toggle() -> void:
	if not _find_refs():
		return
	if visible:
		visible = false
		_player.set_godmode(false)
		if _player.camera_rig:
			_player.camera_rig.follow_target = null
		if _drone:
			_drone.queue_free()
			_drone = null
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		visible = true
		_player.set_godmode(true)  # body idles in place, still vulnerable
		Net.emit_event("godmodeEnter")  # server hands the oddball to someone else
		_drone = _make_drone()
		_player.get_parent().add_child(_drone)
		_drone.global_position = _player.global_position + Vector3(0, 2, 0)
		if _player.camera_rig:
			_player.camera_rig.follow_target = _drone
			_drone.camera_rig = _player.camera_rig
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_set_tool("")


func _make_drone() -> CharacterBody3D:
	var drone := CharacterBody3D.new()
	drone.set_script(load("res://Player/drone.gd"))
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.4
	col.shape = shape
	drone.add_child(col)
	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.25
	sphere.height = 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.18)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 0.4)
	mat.emission_energy_multiplier = 1.5
	sphere.material = mat
	mesh_inst.mesh = sphere
	drone.add_child(mesh_inst)
	return drone


## World clicks (UI clicks never get here — buttons consume them first).
func _unhandled_input(event: InputEvent) -> void:
	if not visible or _tool == "":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return
		var mpos: Vector2 = event.position
		var from := cam.project_ray_origin(mpos)
		var to := from + cam.project_ray_normal(mpos) * 300.0
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = [_player.get_rid()]
		var hit := _player.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			_status.text = "no surface hit — aim at the map"
			return
		var pos: Vector3 = hit["position"]
		if _tool == "delete":
			var ped: String = _world_items.pedestal_near(pos) if _world_items else ""
			var prop: String = _world_props.prop_near(pos) if _world_props else ""
			if ped != "":
				Net.emit_event("removePedestal", ped)
				_status.text = "pedestal removed"
			elif prop != "":
				Net.emit_event("removeModel", prop)
				_status.text = "prop removed"
			else:
				_status.text = "nothing deletable near that spot"
		elif _tool == "channel":
			_channel_nodes.append(pos)
			_channel_markers.append(_channel_marker(pos))
			_status.text = "%d point%s — click CHANNEL again to finish" % [_channel_nodes.size(), "" if _channel_nodes.size() == 1 else "s"]
		elif _tool.begins_with("build:"):
			if not _build_target.is_empty():
				Net.emit_event("placeBuild", _build_target.merged({"type": _tool.substr(6)}))
				_status.text = "%s placed (R rotates)" % _tool.substr(6)
		elif _tool.begins_with("prop:"):
			Net.emit_event("placeModel", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"model": _tool.substr(5),
				"x": pos.x, "y": pos.y, "z": pos.z, "ry": randf() * TAU,
			})
			_status.text = "%s placed" % _tool.substr(5).trim_suffix(".glb")
		else:
			Net.emit_event("placePedestal", {"x": pos.x, "y": pos.y, "z": pos.z, "ry": 0.0, "type": _tool})
			_status.text = "%s pedestal placed" % _tool


## Ghost + floating grid-point cloud while a god build tool is armed
## (web: 9^3 points at 4 u around the build area).
func _process(_delta: float) -> void:
	var building := visible and _tool.begins_with("build:")
	if _grid_points:
		_grid_points.visible = building
	for t in _build_ghosts:
		_build_ghosts[t].visible = false
	if not building or _player == null:
		_build_target = {}
		return

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var mpos := get_viewport().get_mouse_position()
	var from := cam.project_ray_origin(mpos)
	var to := from + cam.project_ray_normal(mpos) * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [_player.get_rid()]
	var hit := _player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		_build_target = {}
		return
	var target: Vector3 = hit["position"] + hit["normal"] * 0.1
	var fx := floorf(target.x / 4.0) * 4.0 + 2.0
	var fy := floorf(target.y / 4.0) * 4.0 + 2.0
	var fz := floorf(target.z / 4.0) * 4.0 + 2.0
	var type := _tool.substr(6)
	if type == "wall":
		match _build_rot:
			0: fz -= 2.0
			1: fx -= 2.0
			2: fz += 2.0
			3: fx += 2.0
	elif type == "platform":
		fy -= 1.5
	_build_target = {"x": fx, "y": fy, "z": fz, "ry": _build_rot * (PI / 2.0), "rx": 0.0}

	if not _build_ghosts.has(type):
		_build_ghosts[type] = _make_build_ghost(type)
	var ghost: MeshInstance3D = _build_ghosts[type]
	ghost.visible = true
	ghost.global_position = Vector3(fx, fy, fz)
	ghost.rotation = Vector3(0, _build_rot * (PI / 2.0), 0)

	# Grid cloud re-centers when the aimed cell changes
	var center := Vector3(floorf(target.x / 4.0) * 4.0 + 2.0, floorf(target.y / 4.0) * 4.0 + 2.0, floorf(target.z / 4.0) * 4.0 + 2.0)
	if _grid_points == null:
		_grid_points = _make_grid_points()
	if center.distance_to(_grid_center) > 0.1:
		_grid_center = center
		var mm := _grid_points.multimesh
		var i := 0
		for gx in range(-4, 5):
			for gy in range(-4, 5):
				for gz in range(-4, 5):
					mm.set_instance_transform(i, Transform3D(Basis(), center + Vector3(gx, gy, gz) * 4.0 + Vector3(2, 2, 2)))
					i += 1


func _make_build_ghost(type: String) -> MeshInstance3D:
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.albedo_color = Color(0.3, 0.6, 1.0, 0.4)
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var g := MeshInstance3D.new()
	match type:
		"ramp":
			g.mesh = preload("res://Items/builds.gd").wedge_mesh(4.0, 4.0, 4.0)
		"wall":
			var wb := BoxMesh.new(); wb.size = Vector3(4, 4, 1); g.mesh = wb
		"platform":
			var pb := BoxMesh.new(); pb.size = Vector3(4, 1, 4); g.mesh = pb
		_:
			var bb := BoxMesh.new(); bb.size = Vector3(4, 4, 4); g.mesh = bb
	g.material_override = _ghost_mat
	_player.get_parent().add_child(g)
	return g


func _make_grid_points() -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var sphere := SphereMesh.new()
	sphere.radius = 0.07
	sphere.height = 0.14
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sphere.material = mat
	mm.mesh = sphere
	mm.instance_count = 9 * 9 * 9
	mmi.multimesh = mm
	_player.get_parent().add_child(mmi)
	return mmi


func _channel_marker(pos: Vector3) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.4
	sphere.height = 0.8
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sphere.material = mat
	marker.mesh = sphere
	_player.get_parent().add_child(marker)
	marker.global_position = pos
	return marker


func _finish_channel() -> void:
	if _channel_nodes.size() >= 2:
		var nodes: Array = []
		for p in _channel_nodes:
			nodes.append({"x": p.x, "y": p.y, "z": p.z})
		Net.emit_event("placeChannel", {
			"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
			"nodes": nodes, "radius": 2.5,
		})
		_status.text = "channel placed (%d points)" % _channel_nodes.size()
	for m in _channel_markers:
		m.queue_free()
	_channel_markers.clear()
	_channel_nodes.clear()


func _set_tool(tool_name: String) -> void:
	if _tool == "channel" and tool_name != "channel":
		_finish_channel()
	_tool = tool_name
	for t in _tool_buttons:
		_tool_buttons[t].button_pressed = t == tool_name
	if _status:
		if tool_name == "channel":
			_status.text = "click points along the route, then click CHANNEL again to finish"
		elif tool_name != "":
			_status.text = "tool: %s — left-click the map" % tool_name.trim_prefix("prop:").trim_suffix(".glb")
		else:
			_status.text = "GIVE an item, or arm a tool"


func _on_tool_pressed(tool_name: String) -> void:
	_set_tool("" if _tool == tool_name else tool_name)


# --- UI construction (code-built to keep the scene file simple) -----------

func _mk_button(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE  # keep WASD/Space for flying
	b.add_theme_color_override("font_color", color)
	b.add_theme_font_size_override("font_size", 12)
	return b


func _build_ui() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.07, 0.92)
	style.border_color = Color("#ffd54a")
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	add_theme_stylebox_override("panel", style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "GOD MODE  (~ to exit)"
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	title.add_theme_font_size_override("font_size", 16)
	root.add_child(title)

	var help := Label.new()
	help.text = "fly: WASD + Space/E up, Shift/Q down\nlook: hold RIGHT mouse and drag"
	help.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	help.add_theme_font_size_override("font_size", 11)
	root.add_child(help)

	var give_label := Label.new()
	give_label.text = "GIVE ITEM"
	give_label.add_theme_font_size_override("font_size", 12)
	give_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(give_label)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	root.add_child(grid)
	for item in GIVE_ITEMS:
		var color := Color("#44ff44")
		if item in ["machinegun", "rocket", "mines"]:
			color = Color("#ff4444")
		elif item in ["block", "wall", "ramp", "platform", "bridge_gun"]:
			color = Color("#ffff44")
		var b := _mk_button(item.replace("_", " "), color)
		b.pressed.connect(func(): Net.emit_event("godmodeGive", item))
		grid.add_child(b)

	var ped_label := Label.new()
	ped_label.text = "PEDESTALS"
	ped_label.add_theme_font_size_override("font_size", 12)
	ped_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(ped_label)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	root.add_child(tools)
	for entry in PED_TOOLS:
		var b := _mk_button(entry[0], Color(entry[1]))
		b.toggle_mode = true
		b.pressed.connect(_on_tool_pressed.bind(entry[0]))
		tools.add_child(b)
		_tool_buttons[entry[0]] = b

	var build_label := Label.new()
	build_label.text = "BUILD (free — click cells, R rotates)"
	build_label.add_theme_font_size_override("font_size", 12)
	build_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(build_label)

	var build_row := HBoxContainer.new()
	build_row.add_theme_constant_override("separation", 6)
	root.add_child(build_row)
	for btype in BUILD_TYPES:
		var tool_id: String = "build:" + str(btype)
		var bb := _mk_button(str(btype), Color("#7fb2ff"))
		bb.toggle_mode = true
		bb.pressed.connect(_on_tool_pressed.bind(tool_id))
		build_row.add_child(bb)
		_tool_buttons[tool_id] = bb

	var props_label := Label.new()
	props_label.text = "PROPS"
	props_label.add_theme_font_size_override("font_size", 12)
	props_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(props_label)

	var props_grid := GridContainer.new()
	props_grid.columns = 4
	props_grid.add_theme_constant_override("h_separation", 6)
	props_grid.add_theme_constant_override("v_separation", 6)
	root.add_child(props_grid)
	for model in PROPS:
		var tool_id: String = "prop:" + str(model)
		var pb := _mk_button(str(model).trim_suffix(".glb").replace("_", " "), Color("#c7e5a0"))
		pb.toggle_mode = true
		pb.pressed.connect(_on_tool_pressed.bind(tool_id))
		props_grid.add_child(pb)
		_tool_buttons[tool_id] = pb

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.custom_minimum_size = Vector2(220, 0)
	root.add_child(_status)
