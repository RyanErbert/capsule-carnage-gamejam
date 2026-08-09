extends Node

## Inventory + item use, child of the player (PORT_BLUEPRINT.md §1.8, §4.6–4.8).
## Web rules: 3 slots, slot 0 is active, left click uses it, 2/3 swap slots.
## Green items implemented here; weapons/builds (red/yellow) land in phases 5/6.

signal inventory_changed(items: Array)

const MAX_INVENTORY := 3
# Ammo granted on pedestal pickup (web game.js:4050). Missing = 0 = single use.
const PICKUP_AMMO := {"machinegun": 100, "rocket": 3, "bridge_gun": 3, "wall": 3, "ramp": 3, "platform": 3}
const GRAPPLE_SPEED := 40.0
const PLACE_RANGE := 10.0   # pads/mines must be placed within 10 u (web)
const AIM_RANGE := 200.0

var inventory: Array = []   # of {type: String, ammo: int}
var is_grappling := false
var grapple_target := Vector3.ZERO
var pending_teleporter: Variant = null  # first click position, or null

@onready var player: CharacterBody3D = get_parent()

var _grapple_line: MeshInstance3D


func _ready() -> void:
	Net.event_received.connect(_on_net_event)
	_grapple_line = MeshInstance3D.new()
	_grapple_line.top_level = true
	_grapple_line.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 1.0, 0.3)
	_grapple_line.material_override = mat
	add_child(_grapple_line)


func _on_net_event(event: String, data: Variant) -> void:
	if event == "itemPickedUp":
		var item := str(data)
		if inventory.size() < MAX_INVENTORY and item != "":
			inventory.append({"type": item, "ammo": int(PICKUP_AMMO.get(item, 0))})
			print("[items] picked up %s — inventory: %s" % [item, inventory])
			inventory_changed.emit(inventory)
	elif event == "gameEnded" or event == "kicked":
		inventory.clear()
		is_grappling = false
		pending_teleporter = null
		inventory_changed.emit(inventory)


func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		use_item()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_2:
			swap_to_first(1)
		elif event.keycode == KEY_3:
			swap_to_first(2)


func swap_to_first(index: int) -> void:
	if index <= 0 or index >= inventory.size():
		return
	var tmp = inventory[0]
	inventory[0] = inventory[index]
	inventory[index] = tmp
	inventory_changed.emit(inventory)


## Web consumeItem(): dispatch on the active slot's item type.
func use_item() -> void:
	if inventory.is_empty():
		return
	var item: String = inventory[0]["type"]
	var target: Variant = _aim_point()
	match item:
		"grapple":
			if target == null:
				return
			grapple_target = target
			is_grappling = true
			_use_ammo()
		"launch_pad", "boost_pad":
			if target == null or player.global_position.distance_to(target) > PLACE_RANGE:
				return
			var cam := get_viewport().get_camera_3d()
			var dir := -cam.global_transform.basis.z
			dir.y = 0.0
			dir = dir.normalized()
			Net.emit_event("placePad", {
				"x": target.x, "y": target.y, "z": target.z,
				"type": item, "dx": dir.x, "dz": dir.z,
			})
			_shift_inventory()
		"teleporter":
			if target == null:
				return
			if pending_teleporter == null:
				pending_teleporter = target  # first click: ghost, no consume
				return
			Net.emit_event("placeTeleporter", {
				"a": {"x": pending_teleporter.x, "y": pending_teleporter.y, "z": pending_teleporter.z},
				"b": {"x": target.x, "y": target.y, "z": target.z},
			})
			pending_teleporter = null
			_shift_inventory()
		_:
			# machinegun/rocket/mines (phase 5) and builds (phase 6): keep the item.
			print("[items] '%s' not usable yet — comes in a later port phase" % item)


## Raycast from the camera center (mouse is captured; web used mouse NDC).
func _aim_point() -> Variant:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.global_position
	var to := from + (-cam.global_transform.basis.z) * AIM_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"] if hit else null


func _use_ammo() -> void:
	inventory[0]["ammo"] = int(inventory[0]["ammo"]) - 1
	if int(inventory[0]["ammo"]) <= 0:
		_shift_inventory()
	else:
		inventory_changed.emit(inventory)


func _shift_inventory() -> void:
	if inventory.is_empty():
		return
	var item = inventory.pop_front()
	print("[items] consumed %s" % item["type"])
	inventory_changed.emit(inventory)


func _process(_delta: float) -> void:
	var im: ImmediateMesh = _grapple_line.mesh
	im.clear_surfaces()
	if is_grappling:
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_add_vertex(player.global_position)
		im.surface_add_vertex(grapple_target)
		im.surface_end()
