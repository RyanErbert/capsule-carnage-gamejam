extends PanelContainer

## Build drone menu (web §6.8, F4 — here on tilde/backtick per Ryan).
## Toggling it launches the drone: you fly it, the mouse is freed for the
## menu, remotes see your body as a 30% ghost, and the server hands the
## oddball off if you were holding it.

const GIVE_ITEMS := [
	"grapple", "launch_pad", "boost_pad", "teleporter",
	"machinegun", "rocket", "mines",
	"bridge_gun", "terragun",
]
const PED_TOOLS := [["green", "#44ff44"], ["red", "#ff4444"], ["yellow", "#ffff44"]]
const MARKER_TOOLS := [["spawn", "#7dedb0"], ["generator", "#6affc2"]]
const STRUCT_TOOLS := [["channel", "#66ccff"], ["castle", "#d8c9a3"], ["gate", "#d8c9a3"], ["tower", "#d8c9a3"]]
const NPC_TOOLS := [["turret", "#ff9d5c"], ["crows", "#9db4c9"], ["rats", "#b7a08c"]]
const PROPS := ["building_1.glb", "building_2.glb", "building_3.glb", "building_4.glb", "building_5.glb", "tree_1.glb", "cactus.glb", "grass.glb", "lamp.glb"]
const NO_SCALE := ["lamp.glb"]   # fixed-size props; scroll does nothing
const VEHICLE_TOOLS := [["ghost", "#b48cff"], ["drill", "#ffab4a"], ["crowbot", "#9adcff"], ["ratbot", "#ff9db4"]]
# Display names where the wire kind reads badly ('ratbot' stays the protocol kind)
const VEHICLE_NAMES := {"ratbot": "rat-attack"}
# Placement obeys terrain: steeper than ~45 degrees refuses surface items
const PLACE_MAX_SLOPE := 0.71   # minimum surface normal.y
# Terrain sculpting is god-mode only now (or the drill vehicle, in play)
const TERRAIN_TOOLS := [["dig", "#e0876a"], ["fill", "#8ac977"], ["smooth", "#9fd0ff"]]
const CARVE_SIZES := [3.0, 6.0, 10.0]   # scroll picks one while a terrain tool is armed
const CARVE_INTERVAL := 0.08
const CARVE_STRENGTH := 0.5
const ROT_STEP := PI / 4.0   # R turns any placement 45 degrees
const LIFT_STEP := 0.5       # scroll raises/lowers the placement height
const Style := preload("res://UI/ui_style.gd")

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
var _prop_ry := 0.0  # next prop's yaw, rolled up-front so the ghost matches
var _prop_scale := 1.0  # scroll scales props up/down
var _tower_h := 8.0  # scroll sets tower height while the tool is armed
var _lift := 0.0     # scroll offset on the placement height
# Click-select: with no tool armed, clicking an element highlights it for
# editing (castles: live height + punched holes) or deletion.
var _selected: Dictionary = {}
var _select_marker: MeshInstance3D
var _chain_preview: Node3D  # live castle/channel ghost while clicking points
var _chain_at := Vector3(1e9, 0, 0)
# Drone build mode (web: godmode build tools + the 9^3 grid-point cloud).
# Everything buildable now comes out of the collapse tileset (Items/wfc.gd):
# "wfc" drops a whole compound, so its ghost is a footprint, and every other
# button places ONE module on the tileset's own 6 m grid, so pieces laid by
# hand mate with each other and with the compounds already on the map.
const BUILD_TYPES := ["wfc"]
const WfcTiles := preload("res://Items/wfc.gd")
# Hovering next to a piece that is already there filters the palette down to
# the modules that actually mate with it: the same socket rule the collapse
# runs on, turned into a placement aid.
var _fit_kinds: Array = []      # kinds allowed at the hovered cell, [] = all
var _build_rot := 0   # in 45-degree steps, 0..7
var _build_target: Dictionary = {}
var _build_ghosts: Dictionary = {}
var _ghost_mat: StandardMaterial3D
var _ghost_mat_bad: StandardMaterial3D
var _grid_points: MultiMeshInstance3D
var _grid_center := Vector3(1e9, 0, 0)
# Dig/fill: hold LEFT mouse to carve continuously at the cursor
var _carve_hold := false
var _carve_cd := 0.0
var _carve_size := 0   # index into CARVE_SIZES
var _terrain_node: Node3D


func _ready() -> void:
	visible = false
	_build_ui()
	Net.event_received.connect(_on_net_event)
	_render_prop_icons.call_deferred()


## The server owns drone health: bullets and blasts wear it down, and at zero
## the drone pops — view snaps back to the body (which just paid 10 health).
func _on_net_event(event: String, data: Variant) -> void:
	if not data is Dictionary:
		return
	var sync: Node = get_tree().get_first_node_in_group("net_sync")
	var self_id: String = sync.self_id if sync else ""
	if str(data.get("id", "")) != self_id:
		return
	if event == "droneHealth" and visible:
		_status.text = "DRONE %d" % int(data.get("hp", 0))
	elif event == "droneDestroyed" and visible:
		if _drone and is_instance_valid(_drone):
			_drone.queue_free()
		_drone = null
		toggle()


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
		elif event.keycode == KEY_R and visible:
			_build_rot = (_build_rot + 1) % 8
			_prop_ry = wrapf(_prop_ry + ROT_STEP, 0.0, TAU)
		elif visible and _chaining() \
				and event.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER]:
			# Any multi-point element finishes on Esc/Enter
			_set_tool("")
			get_viewport().set_input_as_handled()
		elif visible and not _selected.is_empty() \
				and event.keycode in [KEY_DELETE, KEY_BACKSPACE]:
			Net.emit_event(_selected["event"], _selected["id"])
			_select({})
			get_viewport().set_input_as_handled()
		elif visible and not _selected.is_empty() and event.keycode == KEY_ESCAPE:
			_select({})
			get_viewport().set_input_as_handled()
	# Scroll: brush size for the terrain tools, placement height for the rest
	if visible and _tool != "" and event is InputEventMouseButton and event.pressed:
		var dir := 0
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = 1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = -1
		if dir != 0:
			if _tool.begins_with("prop:"):
				# Props sit on the floor; scroll SCALES them instead
				if not _tool.substr(5) in NO_SCALE:
					_prop_scale = clampf(_prop_scale * (1.12 if dir > 0 else 1.0 / 1.12), 0.25, 5.0)
					_status.text = "x%.2f" % _prop_scale
			elif _tool == "tower":
				_tower_h = clampf(_tower_h + dir, 3.0, 20.0)
				_status.text = "H %d" % int(_tower_h)
			elif _tool.begins_with("build:part:"):
				# Scroll cycles the palette, skipping anything that would not mate
				# with the piece the cursor is up against.
				var ring: Array = Array(WfcTiles.PART_KINDS)
				if not _fit_kinds.is_empty():
					ring = _fit_kinds
				var at := maxi(0, ring.find(_tool.substr(11)))
				_set_tool("build:part:" + str(ring[wrapi(at + dir, 0, ring.size())]))
			elif _carving():
				_carve_size = clampi(_carve_size + dir, 0, CARVE_SIZES.size() - 1)
				_status.text = "%s  r%d" % [_tool.to_upper(), int(CARVE_SIZES[_carve_size])]
			else:
				_lift += LIFT_STEP * dir
	# Scroll with NOTHING armed: live height on a selected wall/tower
	if visible and _tool == "" and str(_selected.get("kind", "")) == "castle wall" \
			and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			Net.emit_event("updateCastle", {"id": _selected["id"], "dh": 0.5})
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			Net.emit_event("updateCastle", {"id": _selected["id"], "dh": -0.5})
	# Mouse release anywhere (UI included) ends a dig/fill stroke
	if event is InputEventMouseButton and not event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_carve_hold = false


func _chaining() -> bool:
	return _tool in ["castle", "gate", "channel"]


func _carving() -> bool:
	return _tool in ["dig", "fill", "smooth"]


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
		# One menu at a time: launching the drone closes the Esc menu
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


## A real quadcopter: hull with a gimballed camera, four swept arms out to
## motor pods, and rotor discs that spin (drone.gd turns anything under
## "Rotors"). Nav lights green up front, red at the tail.
func _make_drone() -> CharacterBody3D:
	var drone := CharacterBody3D.new()
	drone.set_script(load("res://Player/drone.gd"))
	drone.add_to_group("god_drone")  # multiplayer_sync reports it as a target
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.4
	col.shape = shape
	drone.add_child(col)

	var body := Node3D.new()
	body.name = "Body"
	drone.add_child(body)
	var shell := StandardMaterial3D.new()
	shell.albedo_color = Color(0.13, 0.14, 0.17)
	shell.metallic = 0.8
	shell.roughness = 0.35
	var trim := StandardMaterial3D.new()
	trim.albedo_color = Color(0.3, 0.32, 0.36)
	trim.metallic = 0.6
	trim.roughness = 0.4

	_drone_box(body, Vector3(0.34, 0.12, 0.44), Vector3(0, 0, 0), shell)        # hull
	_drone_box(body, Vector3(0.22, 0.08, 0.2), Vector3(0, 0.09, -0.04), trim)   # avionics hump
	_drone_box(body, Vector3(0.14, 0.12, 0.12), Vector3(0, -0.08, -0.2), trim)  # camera gimbal
	_drone_box(body, Vector3(0.07, 0.07, 0.04), Vector3(0, -0.09, -0.27),
		_drone_glow(Color(0.35, 0.85, 1.0)))                                     # lens
	_drone_box(body, Vector3(0.05, 0.05, 0.05), Vector3(0, 0.06, 0.24),
		_drone_glow(Color(1.0, 0.25, 0.2)))                                      # tail light

	var rotors := Node3D.new()
	rotors.name = "Rotors"
	drone.add_child(rotors)
	var prop_mat := StandardMaterial3D.new()
	prop_mat.albedo_color = Color(0.5, 0.53, 0.6)
	prop_mat.metallic = 0.3
	prop_mat.roughness = 0.6
	for i in 4:
		var ax := -1.0 if i % 2 == 0 else 1.0
		var az := -1.0 if i < 2 else 1.0
		var at := Vector3(ax * 0.3, 0.02, az * 0.32)
		# Arm from the hull out to the pod
		var arm := _drone_box(body, Vector3(0.06, 0.05, 0.42), at * 0.5, shell)
		arm.rotation.y = atan2(at.x, at.z)   # swing the arm out toward its pod
		_drone_box(body, Vector3(0.1, 0.1, 0.1), at, trim)                       # motor pod
		# Front pods get the green nav lights
		if az < 0.0:
			_drone_box(body, Vector3(0.04, 0.04, 0.04), at + Vector3(0, -0.07, 0),
				_drone_glow(Color(0.3, 1.0, 0.4)))
		# Two crossed blades per rotor — no fake blur disc, they actually spin
		var pivot := Node3D.new()
		pivot.position = at + Vector3(0, 0.1, 0)
		rotors.add_child(pivot)
		var blade := BoxMesh.new()
		blade.size = Vector3(0.3, 0.012, 0.035)
		blade.material = prop_mat
		for b in 2:
			var blade_mi := MeshInstance3D.new()
			blade_mi.mesh = blade
			blade_mi.rotation.y = b * PI / 2.0
			pivot.add_child(blade_mi)
		_drone_box(pivot, Vector3(0.05, 0.03, 0.05), Vector3.ZERO, trim)   # hub
	return drone


static func _drone_box(root: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	root.add_child(mi)
	return mi


static func _drone_glow(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.5
	return m


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
	if not visible:
		return
	if _tool == "":
		_selection_click(event)
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _mouse_ray(event.position)
		if hit.is_empty():
			_status.text = "no surface"
			return
		if _slope_gated() and float(hit["normal"].y) < PLACE_MAX_SLOPE:
			_status.text = "too steep"
			return
		var lift := 0.0 if _tool.begins_with("prop:") else _lift
		var pos: Vector3 = hit["position"] + Vector3(0, lift, 0)
		if _tool == "delete":
			var target := _find_delete_target(pos)
			if target.is_empty():
				_status.text = "nothing there"
			else:
				Net.emit_event(target["event"], target["id"])
				_status.text = "%s removed" % target["kind"]
		elif _tool == "spawn":
			Net.emit_event("placeSpawn", {"x": pos.x, "y": pos.y, "z": pos.z})
			_status.text = "spawn"
		elif _tool == "generator":
			Net.emit_event("placeGenerator", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"x": pos.x, "y": pos.y + 0.7, "z": pos.z,
			})
			_status.text = "generator  [E - drag]"
		elif _tool == "tower":
			Net.emit_event("placeCastle", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"kind": "tower", "h": _tower_h,
				"nodes": [{"x": pos.x, "y": pos.y, "z": pos.z}],
			})
			_status.text = "tower  H %d" % int(_tower_h)
		elif _tool == "turret":
			Net.emit_event("placeTurret", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"x": pos.x, "y": pos.y, "z": pos.z,
			})
			_status.text = "turret"
		elif _tool == "crows" or _tool == "rats":
			Net.emit_event("placeFlock", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"kind": _tool, "x": pos.x, "y": pos.y, "z": pos.z,
			})
			_status.text = _tool
		elif _tool == "castle" or _tool == "gate":
			_castle_nodes.append(pos)
			_castle_markers.append(_channel_marker(pos))
			_status.text = "%d pts  [Enter - done]" % _castle_nodes.size()
		elif _tool == "channel":
			_channel_nodes.append(pos)
			_channel_markers.append(_channel_marker(pos))
			_status.text = "%d pts  [Enter - done]" % _channel_nodes.size()
		elif _carving():
			_carve_hold = true
			_carve_at(pos)
		elif _tool.begins_with("vehicle:"):
			var vkind := _tool.substr(8)
			Net.emit_event("placeVehicle", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"kind": vkind,
				"x": pos.x, "y": pos.y + (0.4 if vkind == "ratbot" else 1.6), "z": pos.z, "ry": 0.0,
			})
			_status.text = "%s  [E - %s]" % [VEHICLE_NAMES.get(vkind, vkind), "pilot" if vkind in ["crowbot", "ratbot"] else "mount"]
		elif _tool == "build:wfc":
			# Wave function collapse: the seed IS the building. Every client
			# collapses the same tileset from it (Items/wfc.gd).
			if not _build_target.is_empty():
				Net.emit_event("placeBuild", {
					"type": "wfc", "seed": randi(),
					"x": _build_target["x"], "y": _build_target["y"] - 2.0,
					"z": _build_target["z"], "ry": _build_target["ry"],
				})
				_status.text = "structure placed"
		elif _tool.begins_with("build:part:"):
			# One module of the collapse tileset, on its own grid.
			if not _build_target.is_empty():
				Net.emit_event("placeBuild", _build_target.merged({
					"type": "wfcpart", "part": _tool.substr(11)}))
		elif _tool.begins_with("build:"):
			if not _build_target.is_empty():
				Net.emit_event("placeBuild", _build_target.merged({"type": _tool.substr(6)}))
				_status.text = "%s placed" % _tool.substr(6)
		elif _tool.begins_with("prop:"):
			var pmodel := _tool.substr(5)
			Net.emit_event("placeModel", {
				"id": "%d-%d" % [Time.get_ticks_msec(), randi() % 10000],
				"model": pmodel,
				"x": pos.x, "y": pos.y, "z": pos.z, "ry": _prop_ry,
				"s": 1.0 if pmodel in NO_SCALE else _prop_scale,
			})
			_prop_ry = randf() * TAU  # reroll: the ghost previews the NEXT one
			_status.text = "%s placed" % pmodel.trim_suffix(".glb")
		else:
			Net.emit_event("placePedestal", {"x": pos.x, "y": pos.y, "z": pos.z, "ry": 0.0, "type": _tool})
			_status.text = "%s pedestal" % _tool


# --- Selection ---------------------------------------------------------------

## No tool armed: clicking an element selects it. A selected wall/tower takes
## live edits — scroll changes its height, clicking it again punches a hole
## through that spot, Del removes it. Anything else selected: Del removes.
func _selection_click(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var hit := _mouse_ray(event.position)
	if hit.is_empty():
		_select({})
		return
	var target := _find_delete_target(hit["position"])
	if not target.is_empty() and not _selected.is_empty() \
			and str(_selected.get("kind", "")) == "castle wall" \
			and str(target.get("id", "")) == str(_selected.get("id", "")):
		# Second click on the selected wall: punch a penetration right there
		var p: Vector3 = hit["position"]
		Net.emit_event("updateCastle", {"id": target["id"], "hole": {"x": p.x, "y": p.y, "z": p.z}})
		return
	_select(target)


func _select(target: Dictionary) -> void:
	_selected = target
	if target.is_empty():
		if _select_marker:
			_select_marker.visible = false
		if _status:
			_status.text = ""
		return
	if _select_marker == null:
		_select_marker = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 2.2
		sphere.height = 4.4
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.85, 0.2, 0.22)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		sphere.material = mat
		_select_marker.mesh = sphere
		_player.get_parent().add_child(_select_marker)
	_select_marker.visible = true
	_select_marker.global_position = target["pos"]
	var kind := str(target.get("kind", ""))
	if kind == "castle wall":
		_status.text = "WALL  [Scroll - Height]  [Click - Hole]  [Del - Delete]"
	else:
		_status.text = "%s  [Del - Delete]" % kind.to_upper()


## Terrain sculpting (god-mode dig/fill): carve at the cursor while the
## mouse is held. Same brush + sync path as the old in-play Q/F terraform.
func _terrain() -> Node3D:
	if _terrain_node == null or not is_instance_valid(_terrain_node):
		_terrain_node = get_tree().get_first_node_in_group("voxel_terrain")
	return _terrain_node


func _carve_at(pos: Vector3) -> void:
	var t := _terrain()
	if t == null:
		_status.text = "no terrain"
		return
	var radius: float = CARVE_SIZES[_carve_size]
	var s := -1.0 if _tool == "dig" else 1.0
	var hit: bool = t.smooth_brush(pos, radius, CARVE_STRENGTH) if _tool == "smooth" 		else t.apply_brush(pos, radius, s, CARVE_STRENGTH)
	if hit:
		Net.emit_event("terrainEdit", {
			"x": pos.x, "y": pos.y, "z": pos.z,
			"r": radius, "s": s, "st": CARVE_STRENGTH,
			"m": "smooth" if _tool == "smooth" else "add",
		})


## Hover feedback: build ghost + grid-point cloud, and the delete tool's
## red highlight over whatever a click would remove (web behavior).
func _process(delta: float) -> void:
	_carve_cd = maxf(0.0, _carve_cd - delta)
	if _carve_hold and visible and _carving() and _carve_cd <= 0.0:
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
	_update_chain_preview()
	_update_brush_marker()
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
	var ry := _build_rot * ROT_STEP
	if type.begins_with("part:"):
		# The tileset has its own grid — 6 m cells, 3 m floors, quarter turns.
		# Snapping parts to the 4 m block grid would leave them unable to mate
		# with each other or with the compounds already on the map.
		fx = floorf(target.x / WfcTiles.CELL) * WfcTiles.CELL + WfcTiles.CELL * 0.5
		fz = floorf(target.z / WfcTiles.CELL) * WfcTiles.CELL + WfcTiles.CELL * 0.5
		fy = roundf(target.y / WfcTiles.LEVEL) * WfcTiles.LEVEL
		ry = float(_build_rot / 2) * PI * 0.5
		var armed := _refresh_fit(Vector3(fx, fy, fz), _build_rot / 2, type.substr(5))
		if armed != type.substr(5):
			_set_tool("build:part:" + armed)
			type = "part:" + armed
	_build_target = {"x": fx, "y": fy, "z": fz, "ry": ry, "rx": 0.0}

	if not _build_ghosts.has(type):
		_build_ghosts[type] = _make_build_ghost(type)
	var ghost: Node3D = _build_ghosts[type]
	ghost.visible = true
	ghost.global_position = Vector3(fx, fy, fz)
	ghost.rotation = Vector3(0, ry, 0)

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


var _brush_marker: MeshInstance3D

## Sphere at the cursor sized to the current brush, so the scrolled size is
## something you can see rather than guess.
func _update_brush_marker() -> void:
	var hit := _mouse_ray(get_viewport().get_mouse_position()) \
		if visible and _carving() and _player != null else {}
	if hit.is_empty():
		if _brush_marker:
			_brush_marker.visible = false
		return
	if _brush_marker == null:
		_brush_marker = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1, 1, 1, 0.16)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		sphere.material = mat
		_brush_marker.mesh = sphere
		_player.get_parent().add_child(_brush_marker)
	_brush_marker.visible = true
	_brush_marker.global_position = hit["position"]
	_brush_marker.scale = Vector3.ONE * float(CARVE_SIZES[_carve_size])


## Multi-point tools draw the thing they'd actually build, running through
## every point clicked so far plus the cursor, rebuilt as you move.
func _update_chain_preview() -> void:
	var pts: Array = _castle_nodes if _tool in ["castle", "gate"] else _channel_nodes
	if not visible or not _chaining() or pts.is_empty():
		if _chain_preview:
			_chain_preview.queue_free()
			_chain_preview = null
			_chain_at = Vector3(1e9, 0, 0)
		return
	var hit := _mouse_ray(get_viewport().get_mouse_position())
	if hit.is_empty():
		return
	var cursor: Vector3 = hit["position"] + Vector3(0, _lift, 0)
	if cursor.distance_to(_chain_at) < 0.3:
		return
	_chain_at = cursor
	if _chain_preview:
		_chain_preview.queue_free()
	var chain: Array = pts + [cursor]
	if _tool == "channel":
		_chain_preview = _polyline_preview(chain)
	else:
		var castles: Node = get_tree().get_first_node_in_group("world_castles")
		_chain_preview = castles.make_preview(chain, _tool == "gate") if castles else null


## Channels are a route, not a solid — preview them as the line they carve.
func _polyline_preview(pts: Array) -> Node3D:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	var mat := _ghost_material()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for p in pts:
		im.surface_add_vertex(p)
	im.surface_end()
	mi.mesh = im
	_player.get_parent().add_child(mi)
	return mi


## Blue placement preview at the cursor for every point-and-click tool
## (pedestals, markers, structures, props, vehicles). BUILD keeps its own
## snapped ghost; delete keeps its red highlight.
func _update_hover_preview() -> void:
	var previewing := visible and _player != null and _tool != "" \
		and not _tool.begins_with("build:") \
		and _tool != "delete" and not _carving()
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
	# Too-steep surface: the ghost goes red and the click will refuse
	var blocked := _slope_gated() and float(hit["normal"].y) < PLACE_MAX_SLOPE
	_ghost_all_meshes(ghost, _bad_ghost_material() if blocked else _ghost_material())
	ghost.global_position = hit["position"] 		+ Vector3(0, 0.0 if _tool.begins_with("prop:") else _lift, 0)
	# Props place with a random yaw (R nudges it) and the scrolled scale;
	# the ghost shows exactly what's coming
	ghost.rotation.y = _prop_ry if _tool.begins_with("prop:") else 0.0
	ghost.scale = Vector3.ONE * (_prop_scale if _tool.begins_with("prop:") and not _tool.substr(5) in NO_SCALE else 1.0)
	if ghost.has_meta("tower"):
		var body: Node3D = ghost.get_node("TowerBody")
		body.scale = Vector3(1, _tower_h, 1)
		body.position.y = _tower_h / 2.0


func _ghost_material() -> StandardMaterial3D:
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.albedo_color = Color(0.3, 0.6, 1.0, 0.4)
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ghost_mat


func _bad_ghost_material() -> StandardMaterial3D:
	if _ghost_mat_bad == null:
		_ghost_mat_bad = StandardMaterial3D.new()
		_ghost_mat_bad.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat_bad.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat_bad.albedo_color = Color(1.0, 0.22, 0.18, 0.45)
		_ghost_mat_bad.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ghost_mat_bad


## Tools that seat an object ON a surface obey the 45-degree slope rule.
## Chains (castle/gate/channel), grid builds, and carving are exempt.
func _slope_gated() -> bool:
	return _tool.begins_with("prop:") or _tool.begins_with("vehicle:") \
		or _tool in ["generator", "turret", "crows", "rats", "tower", "spawn", "green", "red", "yellow"]


func _make_hover_ghost(tool_name: String) -> Node3D:
	var root := Node3D.new()
	_player.get_parent().add_child(root)
	var mat := _ghost_material()
	if tool_name.begins_with("prop:"):
		# The actual model, ghosted blue
		var inst: Node3D = preload("res://Items/props.gd").instantiate_model(tool_name.substr(5))
		if inst:
			root.add_child(inst)
			_ghost_all_meshes(inst, mat)
			return root
	var mi := MeshInstance3D.new()
	if tool_name == "tower":
		# Unit-height cylinder; _update_hover_preview stretches it live
		var tcyl := CylinderMesh.new()
		tcyl.top_radius = 3.2
		tcyl.bottom_radius = 3.6
		tcyl.height = 1.0
		mi.mesh = tcyl
		mi.name = "TowerBody"
		root.set_meta("tower", true)
	elif tool_name == "turret":
		var ncyl := CylinderMesh.new()
		ncyl.top_radius = 0.55
		ncyl.bottom_radius = 0.8
		ncyl.height = 1.6
		mi.mesh = ncyl
		mi.position.y = 0.8
	elif tool_name.begins_with("vehicle:"):
		var vkind := tool_name.substr(8)
		var box := BoxMesh.new()
		match vkind:
			"crowbot": box.size = Vector3(1.0, 0.5, 1.2)
			"ratbot": box.size = Vector3(0.7, 0.45, 1.3)
			_: box.size = Vector3(2.4, 1.1, 3.2)
		mi.mesh = box
		mi.position.y = 1.2 if vkind in ["ghost", "drill"] else 0.6
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


## Look at the four tileset cells around the hovered one. If any of them holds
## a piece already, the palette narrows to the modules that mate with it, the
## ones that don't grey out, and an armed piece that no longer fits is swapped
## for one that does. Returns the kind that ends up armed.
func _refresh_fit(cell: Vector3, rot: int, want: String) -> String:
	var builds: Node = get_tree().get_first_node_in_group("world_builds")
	var near: Array = []
	if builds and builds.has_method("part_at"):
		for d in 4:
			var off := WfcTiles.DIRS[d]
			var found: Dictionary = builds.part_at(
				cell + Vector3(off.x, 0, off.y) * WfcTiles.CELL)
			if not found.is_empty():
				# We are on the far side of them: our direction, flipped.
				near.append({"kind": found["kind"], "rot": found["rot"], "d": (d + 2) % 4})
	var allowed: Array = []
	for kind in WfcTiles.PART_KINDS:
		var ok := true
		for n in near:
			if not WfcTiles.parts_fit(str(n["kind"]), str(kind), int(n["d"]),
					int(n["rot"]), rot):
				ok = false
				break
		if ok:
			allowed.append(kind)
	_fit_kinds = [] if near.is_empty() or allowed.size() == WfcTiles.PART_KINDS.size() \
		else allowed
	for kind in WfcTiles.PART_KINDS:
		var b: Button = _tool_buttons.get("build:part:" + str(kind))
		if b:
			b.modulate.a = 1.0 if _fit_kinds.is_empty() or kind in _fit_kinds else 0.3
	if _fit_kinds.is_empty() or want in _fit_kinds:
		return want
	return str(_fit_kinds[0]) if not _fit_kinds.is_empty() else want


func _make_build_ghost(type: String) -> Node3D:
	if _ghost_mat == null:
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.albedo_color = Color(0.3, 0.6, 1.0, 0.4)
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if type.begins_with("part:"):
		# The ghost IS the part, in ghost blue: with nine of them on a scroll
		# wheel, a generic box tells you nothing about what you're about to
		# drop. The collider comes off — this one is scenery until it's placed.
		var part: Node3D = WfcTiles.build_part(type.substr(5))
		for child in part.get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).material_override = _ghost_mat
			elif child is CollisionShape3D:
				child.queue_free()
		_player.get_parent().add_child(part)
		return part
	# The collapsed structure is a whole compound, so its ghost is a FOOTPRINT —
	# a slab you line up with the ground, not a block.
	var g := MeshInstance3D.new()
	var fb := BoxMesh.new()
	var side: float = preload("res://Items/builds.gd").WFC_SIZE * WfcTiles.CELL
	fb.size = Vector3(side, 0.4, side)
	g.mesh = fb
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
	var turrets: Node = get_tree().get_first_node_in_group("world_turrets")
	if turrets:
		var tr: Dictionary = turrets.nearest_deletable(pos)
		if not tr.is_empty():
			candidates.append(tr.merged({"event": "removeTurret", "kind": "turret"}))
	var critters: Node = get_tree().get_first_node_in_group("world_critters")
	if critters:
		var fl: Dictionary = critters.nearest_deletable(pos)
		if not fl.is_empty():
			candidates.append(fl.merged({"event": "removeFlock", "kind": "flock"}))
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
		_status.text = "channel placed"
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
		_status.text = "wall placed"
	for m in _castle_markers:
		m.queue_free()
	_castle_markers.clear()
	_castle_nodes.clear()


func _set_tool(tool_name: String) -> void:
	if _tool == "channel" and tool_name != "channel":
		_finish_channel()
	if (_tool == "castle" or _tool == "gate") and tool_name != _tool:
		_finish_castle(_tool == "gate")
	_select({})  # arming a tool drops any selection
	_tool = tool_name
	_lift = 0.0
	for t in _tool_buttons:
		_tool_buttons[t].button_pressed = t == tool_name
	if _status:
		if tool_name.begins_with("build:part:"):
			_status.text = tool_name.substr(11).to_upper()
		else:
			_status.text = tool_name.trim_prefix("prop:").trim_prefix("vehicle:") \
				.trim_prefix("build:").trim_suffix(".glb").to_upper()


func _on_tool_pressed(tool_name: String) -> void:
	if tool_name.begins_with("prop:"):
		_prop_ry = randf() * TAU
	_set_tool("" if _tool == tool_name else tool_name)


# --- UI construction (code-built to keep the scene file simple) -----------

func _mk_button(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE  # keep WASD/Space for flying
	b.add_theme_color_override("font_color", color)
	b.add_theme_font_size_override("font_size", 16)
	return b


## One labeled row of toggle tools (the standard god-menu section shape).
func _tool_row(root: VBoxContainer, label_text: String, tools: Array) -> void:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 16)
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
	add_theme_stylebox_override("panel", Style.panel_box())

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "BUILD DRONE"
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	title.add_theme_font_size_override("font_size", 16)
	root.add_child(title)

	var keys := Label.new()
	keys.text = "[R - Rotate]  [Scroll - Z edit]  [Space - Up, Shift - Down]"
	keys.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	keys.add_theme_font_size_override("font_size", 16)
	root.add_child(keys)

	# GIVE section is collapsed by default (housekeeping request)
	var give_toggle := Button.new()
	give_toggle.text = "▸ GIVE ITEM"
	give_toggle.focus_mode = Control.FOCUS_NONE
	give_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	give_toggle.add_theme_font_size_override("font_size", 16)
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
		elif item in ["bridge_gun", "terragun"]:
			color = Color("#ffff44")
		var b := _mk_button(item.replace("_", " "), color)
		b.pressed.connect(func(): Net.emit_event("godmodeGive", item))
		grid.add_child(b)

	_tool_row(root, "PEDESTALS", PED_TOOLS)
	_tool_row(root, "MARKERS", MARKER_TOOLS)
	_tool_row(root, "STRUCTURES", STRUCT_TOOLS)
	_tool_row(root, "NPCS", NPC_TOOLS)

	var build_label := Label.new()
	build_label.text = "BUILD"
	build_label.add_theme_font_size_override("font_size", 16)
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

	var parts_grid := GridContainer.new()
	parts_grid.columns = 3
	parts_grid.add_theme_constant_override("h_separation", 6)
	parts_grid.add_theme_constant_override("v_separation", 6)
	root.add_child(parts_grid)
	for kind in WfcTiles.PART_KINDS:
		var tool_id: String = "build:part:" + str(kind)
		var pb := _mk_button(str(kind), Color("#7fb2ff"))
		pb.toggle_mode = true
		pb.expand_icon = true
		pb.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pb.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		pb.custom_minimum_size = Vector2(64, 64)
		pb.pressed.connect(_on_tool_pressed.bind(tool_id))
		parts_grid.add_child(pb)
		_tool_buttons[tool_id] = pb

	var terrain_label := Label.new()
	terrain_label.text = "TERRAIN"
	terrain_label.add_theme_font_size_override("font_size", 16)
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
	veh_label.text = "VEHICLES"
	veh_label.add_theme_font_size_override("font_size", 16)
	veh_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	root.add_child(veh_label)

	var veh_row := HBoxContainer.new()
	veh_row.add_theme_constant_override("separation", 6)
	root.add_child(veh_row)
	for entry in VEHICLE_TOOLS:
		var tool_id: String = "vehicle:" + str(entry[0])
		var vb := _mk_button(VEHICLE_NAMES.get(entry[0], entry[0]), Color(entry[1]))
		vb.toggle_mode = true
		vb.pressed.connect(_on_tool_pressed.bind(tool_id))
		veh_row.add_child(vb)
		_tool_buttons[tool_id] = vb

	var props_label := Label.new()
	props_label.text = "PROPS"
	props_label.add_theme_font_size_override("font_size", 16)
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

	var del := _mk_button("✕ DELETE", Color("#ff7060"))
	del.toggle_mode = true
	del.pressed.connect(_on_tool_pressed.bind("delete"))
	root.add_child(del)
	_tool_buttons["delete"] = del

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.custom_minimum_size = Vector2(220, 0)
	root.add_child(_status)


## Little 3D renders on the prop buttons, framed from each model's AABB so
## the whole thing is in shot.
func _render_prop_icons() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(96, 96)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 35.0
	vp.add_child(cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 35, 0)
	key.light_energy = 1.3
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, -140, 0)
	fill.light_energy = 0.5
	vp.add_child(fill)
	# Tileset parts first: nine near-identical slabs of clay are impossible to
	# tell apart by name, and a name is all a button has otherwise.
	for kind in WfcTiles.PART_KINDS:
		if not _tool_buttons.has("build:part:" + str(kind)) or not is_inside_tree():
			continue
		var part: Node3D = WfcTiles.build_part(str(kind))
		vp.add_child(part)
		var pbox: AABB = preload("res://Vehicles/vehicle.gd")._model_aabb(part)
		var pc := pbox.get_center()
		cam.global_position = pc + Vector3(0.75, 0.6, 1.0).normalized() \
			* maxf(pbox.size.length() * 0.5, 0.01) * 2.2
		cam.look_at(pc)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		if not is_inside_tree():
			return
		var pimg: Image = vp.get_texture().get_image()
		part.queue_free()
		var pbtn: Button = _tool_buttons["build:part:" + str(kind)]
		pbtn.icon = ImageTexture.create_from_image(pimg)
		pbtn.add_theme_constant_override("icon_max_width", 44)

	var props_script := preload("res://Items/props.gd")
	for model in PROPS:
		if not _tool_buttons.has("prop:" + str(model)) or not is_inside_tree():
			continue
		var inst: Node3D = props_script.instantiate_model(str(model))
		if inst == null:
			continue
		vp.add_child(inst)
		var box: AABB = preload("res://Vehicles/vehicle.gd")._model_aabb(inst)
		var c := box.get_center()
		var r := maxf(box.size.length() * 0.5, 0.01)
		cam.global_position = c + Vector3(0.55, 0.45, 1.0).normalized() * (r * 2.7)
		cam.look_at(c)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		if not is_inside_tree():
			return
		var img: Image = vp.get_texture().get_image()
		inst.queue_free()
		var b: Button = _tool_buttons["prop:" + str(model)]
		b.icon = ImageTexture.create_from_image(img)
		b.add_theme_constant_override("icon_max_width", 44)
		b.custom_minimum_size = Vector2(0, 50)
	vp.queue_free()
