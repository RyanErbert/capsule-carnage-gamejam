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
const PED_TOOLS := [["green", "#44ff44"], ["red", "#ff4444"], ["yellow", "#ffff44"], ["delete", "#aaaaaa"]]

var _player: CharacterBody3D
var _world_items: Node
var _tool := ""   # "", "green", "red", "yellow", "delete"
var _tool_buttons: Dictionary = {}
var _status: Label


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
	return _player != null


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_QUOTELEFT \
			and get_viewport().gui_get_focus_owner() == null:
		toggle()


func toggle() -> void:
	if not _find_refs():
		return
	if visible:
		visible = false
		_player.set_godmode(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		visible = true
		_player.set_godmode(true)
		Net.emit_event("godmodeEnter")  # server hands the oddball to someone else
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_set_tool("")


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
			var id: String = _world_items.pedestal_near(pos) if _world_items else ""
			if id == "":
				_status.text = "no pedestal near that spot"
			else:
				Net.emit_event("removePedestal", id)
				_status.text = "pedestal removed"
		else:
			Net.emit_event("placePedestal", {"x": pos.x, "y": pos.y, "z": pos.z, "ry": 0.0, "type": _tool})
			_status.text = "%s pedestal placed" % _tool


func _set_tool(tool_name: String) -> void:
	_tool = tool_name
	for t in _tool_buttons:
		_tool_buttons[t].button_pressed = t == tool_name
	if _status:
		_status.text = ("tool: %s — left-click the map" % tool_name) if tool_name != "" else "GIVE an item, or arm a pedestal tool"


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

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.custom_minimum_size = Vector2(220, 0)
	root.add_child(_status)
