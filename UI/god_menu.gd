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
const PED_TOOLS := [["green", "#44ff44"], ["red", "#ff4444"], ["yellow", "#ffff44"]]
const MARKER_TOOLS := [["spawn", "#7dedb0"], ["generator", "#6affc2"]]
const STRUCT_TOOLS := [["channel", "#66ccff"], ["castle", "#d8c9a3"], ["gate", "#d8c9a3"]]
const PROPS := ["building_1.glb", "building_2.glb", "building_3.glb", "building_4.glb", "building_5.glb", "tree_1.glb", "cactus.glb", "grass.glb"]
const VEHICLE_TOOLS := [["ghost", "#b48cff"], ["drill", "#ffab4a"]]
# Terrain sculpting is god-mode only now (or the drill vehicle, in play)
const TERRAIN_TOOLS := [["dig", "#e0876a"], ["fill", "#8ac977"]]
const CARVE_RADIUS := 3.0
const CARVE_INTERVAL := 0.08
const CARVE_STRENGTH := 0.5

var _player: CharacterBody3D
var _world_items: Node
var _world_props: Node
var _tool := ""   # "", "green", "red", "yellow", "channel", "delete", "prop:<glb>"
var _tool_buttons: Dictionary = {}
var _status: Label
var _drone: CharacterBody3D
var _channel_nodes: Array = []
var _channel_markers: Array = []
var _castle_nodes: Array = []
var _castle_markers: Array = []
var _hover_ghosts: Dictionary = {}  # tool -> ghost Node3D (blue placement preview)
# God build mode (web: godmode build tools + the 9^3 grid-point cloud)
const BUILD_TYPES := ["block", "wall", "ramp", "platform"]
var _build_rot := 0
var _build_target: Dictionary = {}
var _build_ghosts: Dictionary = {}
var _ghost_mat: StandardMaterial3D
var _grid_points: MultiMeshInstance3D
var _grid_center := Vector3(1e9, 0, 0)
# Dig/fill: hold LEFT mouse to carve continuously at the cursor
var _carve_hold := false
var _carve_cd := 0.0
var _terrain_node: Node3D


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
		if event.keycode == KEY_QUOTELEFT or event.keycode == KEY_Q:
			toggle()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_R and visible and _tool.begins_with("build:"):
			_build_rot = (_build_rot + 1) % 4
	# Mouse release anywhere (UI included) ends a dig/fill stroke
	if event is InputEventMouseButton and not event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_carve_hold = false


func toggle() -> void:
	if not _find_refs():
		return
	if visible:
		visible = false
		_set_tool("")  # finishes any pending channel/castle chain
		_player.set_godmode(false)
		if _player.camera_rig:
			_player.camera_rig.follow_target = null
		if _drone:
			_drone.return_to = _player  # flies home, then despawns
			_drone = null
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_set_scifi(false)
	else:
		# One menu at a time: opening god mode closes the Esc menu
		var hud := get_parent()
		if hud and hud.has_method("close_esc_menu"):
			hud.close_esc_menu()
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
		_set_scifi(true)


func _set_scifi(on: bool) -> void:
	var fx: Node = get_tree().get_first_node_in_group("screen_fx")
	if fx:
		fx.set_scifi(on)


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


## Mouse ray that ignores our own bodies — CRUCIALLY including the drone,
## which otherwise sits right in front of the camera and eats every ray.
func _mouse_ray(mpos: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _player == null:
		return {}
	var from := cam.project_ray_origin(mpos)
	var to := from + cam.project_ray_normal(mpos) * 300.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var excl: Array = [_player.get_rid()]
	if _drone:
		excl.append(_drone.get_rid())
	q.exclude = excl
	return _player.get_world_3d().direct_space_state.intersect_ray(q)


## World clicks (UI clicks never get here — buttons consume them first).
func _unhandled_input(event: InputEvent) -> void:
	if not visible or _tool == "":
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _mouse_ray(event.position)
		if hit.is_empty():
			_status.text = "no surface hit - aim at the map"
			return
		var pos: Vector3 = hit["position"]
		if _tool == "delete":
			var target := _find_delete_target(pos)
			if target.is_empty():
				_status.text = "nothing deletable near that spot"
			else:
				Net.emit_event(target["event"], target["id"])
				_status.text = "%s removed" % target["kind"]
		elif _tool == "spawn":
			Net.emit_event("placeSpawn", {"x": pos.x, "y": pos.y, "z": pos.z})
			_status.text = "spawn point placed"
		elif _tool == "generator":
			Net.emit_event("placeGenerator", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"x": pos.x, "y": pos.y + 0.7, "z": pos.z,
			})
			_status.text = "generator placed (E drags it)"
		elif _tool == "castle" or _tool == "gate":
			_castle_nodes.append(pos)
			_castle_markers.append(_channel_marker(pos))
			_status.text = "%d point%s - click %s again to finish" % [
				_castle_nodes.size(), "" if _castle_nodes.size() == 1 else "s", _tool.to_upper()]
		elif _tool == "channel":
			_channel_nodes.append(pos)
			_channel_markers.append(_channel_marker(pos))
			_status.text = "%d point%s - click CHANNEL again to finish" % [_channel_nodes.size(), "" if _channel_nodes.size() == 1 else "s"]
		elif _tool == "dig" or _tool == "fill":
			_carve_hold = true
			_carve_at(pos)
		elif _tool.begins_with("vehicle:"):
			Net.emit_event("placeVehicle", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"kind": _tool.substr(8),
				"x": pos.x, "y": pos.y + 1.6, "z": pos.z, "ry": 0.0,
			})
			_status.text = "%s placed (E mounts it)" % _tool.substr(8)
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


## Terrain sculpting (god-mode dig/fill): carve at the cursor while the
## mouse is held. Same brush + sync path as the old in-play Q/F terraform.
func _terrain() -> Node3D:
	if _terrain_node == null or not is_instance_valid(_terrain_node):
		_terrain_node = get_tree().get_first_node_in_group("voxel_terrain")
	return _terrain_node


func _carve_at(pos: Vector3) -> void:
	var t := _terrain()
	if t == null:
		_status.text = "no sculptable terrain on this map"
		return
	var s := -1.0 if _tool == "dig" else 1.0
	if t.apply_brush(pos, CARVE_RADIUS, s, CARVE_STRENGTH):
		Net.emit_event("terrainEdit", {
			"x": pos.x, "y": pos.y, "z": pos.z,
			"r": CARVE_RADIUS, "s": s, "st": CARVE_STRENGTH,
		})


## Hover feedback: build ghost + grid-point cloud, and the delete tool's
## red highlight over whatever a click would remove (web behavior).
func _process(delta: float) -> void:
	_carve_cd = maxf(0.0, _carve_cd - delta)
	if _carve_hold and visible and (_tool == "dig" or _tool == "fill") and _carve_cd <= 0.0:
		var carve_hit := _mouse_ray(get_viewport().get_mouse_position())
		if not carve_hit.is_empty():
			_carve_cd = CARVE_INTERVAL
			_carve_at(carve_hit["position"])
	var building := visible and _tool.begins_with("build:")
	if _grid_points:
		_grid_points.visible = building
	for t in _build_ghosts:
		_build_ghosts[t].visible = false
	_update_delete_highlight()
	_update_hover_preview()
	if not building or _player == null:
		_build_target = {}
		return

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var mpos := get_viewport().get_mouse_position()
	var hit := _mouse_ray(mpos)
	var target: Vector3
	if hit.is_empty():
		# Nothing under the cursor: float the ghost 24 u out so it's always visible
		target = cam.project_ray_origin(mpos) + cam.project_ray_normal(mpos) * 24.0
	else:
		target = hit["position"] + hit["normal"] * 0.1
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


## Blue placement preview at the cursor for every point-and-click tool
## (pedestals, markers, structures, props, vehicles). BUILD keeps its own
## snapped ghost; delete keeps its red highlight.
func _update_hover_preview() -> void:
	var previewing := visible and _player != null and _tool != "" \
		and not _tool.begins_with("build:") \
		and _tool != "delete" and _tool != "dig" and _tool != "fill"
	for t in _hover_ghosts:
		_hover_ghosts[t].visible = false
	if not previewing:
		return
	var hit := _mouse_ray(get_viewport().get_mouse_position())
	if hit.is_empty():
		return
	var ghost: Node3D = _hover_ghosts.get(_tool)
	if ghost == null:
		ghost = _make_hover_ghost(_tool)
		_hover_ghosts[_tool] = ghost
	ghost.visible = true
	ghost.global_position = hit["position"]


func _ghost_material() -> StandardMaterial3D:
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.albedo_color = Color(0.3, 0.6, 1.0, 0.4)
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ghost_mat


func _make_hover_ghost(tool_name: String) -> Node3D:
	var root := Node3D.new()
	_player.get_parent().add_child(root)
	var mat := _ghost_material()
	if tool_name.begins_with("prop:"):
		# The actual model, ghosted blue
		var scenes: Dictionary = preload("res://Items/props.gd").MODEL_SCENES
		var model := tool_name.substr(5)
		if scenes.has(model):
			var inst: Node3D = scenes[model].instantiate()
			root.add_child(inst)
			_ghost_all_meshes(inst, mat)
			return root
	var mi := MeshInstance3D.new()
	if tool_name.begins_with("vehicle:"):
		var box := BoxMesh.new()
		box.size = Vector3(2.4, 1.1, 3.2)
		mi.mesh = box
		mi.position.y = 1.2
	elif tool_name == "generator":
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.6
		cyl.bottom_radius = 0.68
		cyl.height = 1.4
		mi.mesh = cyl
		mi.position.y = 0.7
	elif tool_name in ["green", "red", "yellow"]:
		var ped := CylinderMesh.new()
		ped.top_radius = 0.7
		ped.bottom_radius = 0.9
		ped.height = 1.0
		mi.mesh = ped
		mi.position.y = 0.5
	else:
		# spawn / channel / castle / gate: a simple point marker
		var sph := SphereMesh.new()
		sph.radius = 0.6
		sph.height = 1.2
		mi.mesh = sph
		mi.position.y = 0.6
	mi.material_override = mat
	root.add_child(mi)
	return root


func _ghost_all_meshes(node: Node, mat: StandardMaterial3D) -> void:
	for child in node.get_children():
		_ghost_all_meshes(child, mat)
	if node is MeshInstance3D:
		node.material_override = mat


var _delete_marker: MeshInstance3D

func _update_delete_highlight() -> void:
	var active := visible and _tool == "delete" and _player != null
	if not active:
		if _delete_marker:
			_delete_marker.visible = false
		return
	var hit := _mouse_ray(get_viewport().get_mouse_position())
	var target := _find_delete_target(hit["position"]) if not hit.is_empty() else {}
	if target.is_empty():
		if _delete_marker:
			_delete_marker.visible = false
		return
	if _delete_marker == null:
		_delete_marker = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 2.4
		sphere.height = 4.8
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.15, 0.1, 0.3)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		sphere.material = mat
		_delete_marker.mesh = sphere
		_player.get_parent().add_child(_delete_marker)
	_delete_marker.visible = true
	_delete_marker.global_position = target["pos"]


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


## Everything the delete tool can target, nearest-first.
func _find_delete_target(pos: Vector3) -> Dictionary:
	var world_builds: Node = get_tree().get_first_node_in_group("world_builds")
	var candidates: Array = []
	if _world_items:
		var ped: Dictionary = _world_items.nearest_deletable(pos)
		if not ped.is_empty():
			candidates.append(ped.merged({"event": "removePedestal", "kind": "pedestal"}))
		var sp: Dictionary = _world_items.nearest_spawn(pos)
		if not sp.is_empty():
			candidates.append(sp.merged({"event": "removeSpawn", "kind": "spawn point"}))
	if _world_props:
		var prop: Dictionary = _world_props.nearest_deletable(pos)
		if not prop.is_empty():
			candidates.append(prop.merged({"event": "removeModel", "kind": "prop"}))
	if world_builds:
		var build: Dictionary = world_builds.nearest_deletable(pos)
		if not build.is_empty():
			candidates.append(build.merged({"event": "removeBuild", "kind": "build"}))
		var chan: Dictionary = world_builds.nearest_channel(pos)
		if not chan.is_empty():
			candidates.append(chan.merged({"event": "removeChannel", "kind": "channel"}))
	var castles: Node = get_tree().get_first_node_in_group("world_castles")
	if castles:
		var cw: Dictionary = castles.nearest_deletable(pos)
		if not cw.is_empty():
			candidates.append(cw.merged({"event": "removeCastle", "kind": "castle wall"}))
	var vehicles: Node = get_tree().get_first_node_in_group("world_vehicles")
	if vehicles:
		var vh: Dictionary = vehicles.nearest_deletable(pos)
		if not vh.is_empty():
			candidates.append(vh.merged({"event": "removeVehicle", "kind": "vehicle"}))
	var gens: Node = get_tree().get_first_node_in_group("world_generators")
	if gens:
		var gn: Dictionary = gens.nearest_deletable(pos)
		if not gn.is_empty():
			candidates.append(gn.merged({"event": "removeGenerator", "kind": "generator"}))
	var best: Dictionary = {}
	for c in candidates:
		if best.is_empty() or c["dist"] < best["dist"]:
			best = c
	return best


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


## Castle walls chain through every clicked point, channel-style.
func _finish_castle(arch: bool) -> void:
	if _castle_nodes.size() >= 2:
		var nodes: Array = []
		for p in _castle_nodes:
			nodes.append({"x": p.x, "y": p.y, "z": p.z})
		Net.emit_event("placeCastle", {
			"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
			"nodes": nodes, "arch": arch,
		})
		_status.text = "castle wall placed (%d points)%s" % [_castle_nodes.size(), " with gates" if arch else ""]
	for m in _castle_markers:
		m.queue_free()
	_castle_markers.clear()
	_castle_nodes.clear()


func _set_tool(tool_name: String) -> void:
	if _tool == "channel" and tool_name != "channel":
		_finish_channel()
	if (_tool == "castle" or _tool == "gate") and tool_name != _tool:
		_finish_castle(_tool == "gate")
	_tool = tool_name
	for t in _tool_buttons:
		_tool_buttons[t].button_pressed = t == tool_name
	if _status:
		if tool_name == "channel":
			_status.text = "click points along the route, then click CHANNEL again to finish"
		elif tool_name == "dig" or tool_name == "fill":
			_status.text = "hold LEFT mouse on the terrain to %s" % tool_name
		elif tool_name != "":
			_status.text = "tool: %s - left-click the map" % tool_name.trim_prefix("prop:").trim_prefix("vehicle:").trim_suffix(".glb")
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


## One labeled row of toggle tools (the standard god-menu section shape).
func _tool_row(root: VBoxContainer, label_text: String, tools: Array) -> void:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	root.add_child(row)
	for entry in tools:
		var b := _mk_button(entry[0], Color(entry[1]))
		b.toggle_mode = true
		b.pressed.connect(_on_tool_pressed.bind(entry[0]))
		row.add_child(b)
		_tool_buttons[entry[0]] = b


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
	title.text = "GOD MODE  (Q or ~ to exit)"
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	title.add_theme_font_size_override("font_size", 16)
	root.add_child(title)

	var help := Label.new()
	help.text = "fly: WASD + Space/E up, Shift down\nlook: hold RIGHT mouse and drag"
	help.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	help.add_theme_font_size_override("font_size", 11)
	root.add_child(help)

	# GIVE section is collapsed by default (housekeeping request)
	var give_toggle := Button.new()
	give_toggle.text = "▸ GIVE ITEM"
	give_toggle.focus_mode = Control.FOCUS_NONE
	give_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	give_toggle.add_theme_font_size_override("font_size", 12)
	root.add_child(give_toggle)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.visible = false
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	root.add_child(grid)
	give_toggle.pressed.connect(func():
		grid.visible = not grid.visible
		give_toggle.text = ("▾ GIVE ITEM" if grid.visible else "▸ GIVE ITEM"))
	for item in GIVE_ITEMS:
		var color := Color("#44ff44")
		if item in ["machinegun", "rocket", "mines"]:
			color = Color("#ff4444")
		elif item in ["block", "wall", "ramp", "platform", "bridge_gun"]:
			color = Color("#ffff44")
		var b := _mk_button(item.replace("_", " "), color)
		b.pressed.connect(func(): Net.emit_event("godmodeGive", item))
		grid.add_child(b)

	_tool_row(root, "PEDESTALS", PED_TOOLS)
	_tool_row(root, "MARKERS", MARKER_TOOLS)
	_tool_row(root, "STRUCTURES (multi-click, reclick tool to finish)", STRUCT_TOOLS)

	var build_label := Label.new()
	build_label.text = "BUILD (free - click cells, R rotates)"
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

	var terrain_label := Label.new()
	terrain_label.text = "TERRAIN (hold LEFT mouse)"
	terrain_label.add_theme_font_size_override("font_size", 12)
	terrain_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(terrain_label)

	var terrain_row := HBoxContainer.new()
	terrain_row.add_theme_constant_override("separation", 6)
	root.add_child(terrain_row)
	for entry in TERRAIN_TOOLS:
		var tb := _mk_button(entry[0], Color(entry[1]))
		tb.toggle_mode = true
		tb.pressed.connect(_on_tool_pressed.bind(entry[0]))
		terrain_row.add_child(tb)
		_tool_buttons[entry[0]] = tb

	var veh_label := Label.new()
	veh_label.text = "VEHICLES (E mounts)"
	veh_label.add_theme_font_size_override("font_size", 12)
	veh_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(veh_label)

	var veh_row := HBoxContainer.new()
	veh_row.add_theme_constant_override("separation", 6)
	root.add_child(veh_row)
	for entry in VEHICLE_TOOLS:
		var tool_id: String = "vehicle:" + str(entry[0])
		var vb := _mk_button(entry[0], Color(entry[1]))
		vb.toggle_mode = true
		vb.pressed.connect(_on_tool_pressed.bind(tool_id))
		veh_row.add_child(vb)
		_tool_buttons[tool_id] = vb

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

	var del := _mk_button("✕ DELETE (hover highlights red)", Color("#ff7060"))
	del.toggle_mode = true
	del.pressed.connect(_on_tool_pressed.bind("delete"))
	root.add_child(del)
	_tool_buttons["delete"] = del

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.custom_minimum_size = Vector2(220, 0)
	root.add_child(_status)
