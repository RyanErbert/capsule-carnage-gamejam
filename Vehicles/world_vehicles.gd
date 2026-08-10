extends Node3D

## Synced vehicle registry + the E interaction (E is the global action key:
## press it near a parked vehicle to mount, press it again to hop out).
##
## Mounting is optimistic: we take the seat locally and ask the server; if
## someone else already holds it the server re-asserts the real driver and we
## roll back. While mounted, this node relays vehicleMoved at ~20 Hz.

const RELAY_INTERVAL := 0.05
const MOUNT_RANGE := 4.0
const RESCUE_Y := -20.0   # vehicle fell out of the world: teleport it back up
const VehicleScript := preload("res://Vehicles/vehicle.gd")

@export var player: CharacterBody3D

var _vehicles: Dictionary = {}   # id -> vehicle node
var _mounted: CharacterBody3D = null
var _relay_cd := 0.0
var _sync: Node


func _ready() -> void:
	add_to_group("world_vehicles")
	Net.event_received.connect(_on_net_event)


func _self_id() -> String:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	return _sync.self_id if _sync else ""


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentVehicles":
			if _mounted:
				_dismount(false)
			for id in _vehicles:
				_vehicles[id].queue_free()
			_vehicles.clear()
			for v in data:
				_add_vehicle(v)
		"vehiclePlaced":
			_add_vehicle(data)
		"vehicleRemoved":
			var id := str(data)
			if _mounted and _mounted.id == id:
				_dismount(false)
			if _vehicles.has(id):
				_vehicles[id].queue_free()
				_vehicles.erase(id)
		"vehicleMoved":
			if data is Dictionary:
				var id := str(data.get("id", ""))
				var veh: CharacterBody3D = _vehicles.get(id)
				if veh and not veh.driven_by_me:
					veh.net_pos = Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0))
					veh.net_yaw = float(data.get("ry", 0.0))
		"vehicleDriver":
			if data is Dictionary:
				_on_driver_changed(str(data.get("id", "")), data.get("driver"))
		"mapRebuilt":
			if _mounted:
				_dismount(false)
			for id in _vehicles:
				_vehicles[id].queue_free()
			_vehicles.clear()


func _on_driver_changed(id: String, driver: Variant) -> void:
	var veh: CharacterBody3D = _vehicles.get(id)
	if veh == null:
		return
	var driver_id := str(driver) if driver is String else ""
	# Server says our seat belongs to someone else: roll the mount back.
	if _mounted == veh and driver_id != _self_id():
		_dismount(false)
	veh.driver_id = driver_id


func _add_vehicle(v: Variant) -> void:
	if not v is Dictionary:
		return
	var id := str(v.get("id", ""))
	var kind := str(v.get("kind", "ghost"))
	if id == "" or _vehicles.has(id):
		return
	var veh: CharacterBody3D = VehicleScript.new()
	veh.setup(id, kind)
	add_child(veh)
	var pos := Vector3(v.get("x", 0.0), v.get("y", 0.0), v.get("z", 0.0))
	veh.global_position = pos
	veh.net_pos = pos
	veh.rotation.y = float(v.get("ry", 0.0))
	veh.net_yaw = veh.rotation.y
	var drv: Variant = v.get("driver")
	veh.driver_id = str(drv) if drv is String else ""
	_vehicles[id] = veh


## Nearest vehicle within `radius` — god menu delete tool. {} if none.
func nearest_deletable(pos: Vector3, radius := 5.0) -> Dictionary:
	var best := {}
	for id in _vehicles:
		var d: float = _vehicles[id].global_position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _vehicles[id].global_position}
	return best


# --- Mounting ---------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_E \
			and get_viewport().gui_get_focus_owner() == null \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and player != null and not player.godmode:
		if _mounted:
			_dismount(true)
		else:
			_try_mount()


func _try_mount() -> void:
	var best: CharacterBody3D = null
	var best_d := MOUNT_RANGE
	for id in _vehicles:
		var veh: CharacterBody3D = _vehicles[id]
		if veh.driver_id != "" and veh.driver_id != _self_id():
			continue  # someone's in it
		var d: float = veh.global_position.distance_to(player.global_position)
		if d < best_d:
			best_d = d
			best = veh
	if best == null:
		return
	_mounted = best
	best.driver_id = _self_id()
	best.driven_by_me = true
	best.camera_rig = player.camera_rig
	player.enter_vehicle(best)
	if player.camera_rig:
		player.camera_rig.follow_target = best
	Net.emit_event("mountVehicle", best.id)
	Sfx.boost(best.global_position, 0.5)


func _dismount(tell_server: bool) -> void:
	var veh := _mounted
	_mounted = null
	if veh and is_instance_valid(veh):
		veh.driven_by_me = false
		veh.camera_rig = null
		veh.driver_id = ""
		veh.net_pos = veh.global_position
		veh.net_yaw = veh.rotation.y
		veh.velocity = Vector3.ZERO
		if tell_server:
			# Final position so everyone parks it in the same spot.
			Net.emit_event("vehicleMoved", {
				"id": veh.id,
				"x": veh.global_position.x, "y": veh.global_position.y,
				"z": veh.global_position.z, "ry": veh.rotation.y,
			})
			Net.emit_event("dismountVehicle", veh.id)
	if player:
		player.exit_vehicle()
		if player.camera_rig:
			player.camera_rig.follow_target = null


func _process(delta: float) -> void:
	if _mounted == null:
		return
	if not is_instance_valid(_mounted):
		_mounted = null
		if player:
			player.exit_vehicle()
		return
	# Entering drone/god mode hops you out first.
	if player and player.godmode:
		_dismount(true)
		return
	# Fell out of the world: rescue vehicle and driver to a spawn point.
	if _mounted.global_position.y < RESCUE_Y:
		_mounted.global_position = player.respawn_point() + Vector3(0, 2.5, 0)
		_mounted.velocity = Vector3.ZERO
	_relay_cd -= delta
	if _relay_cd <= 0.0:
		_relay_cd = RELAY_INTERVAL
		Net.emit_event("vehicleMoved", {
			"id": _mounted.id,
			"x": _mounted.global_position.x, "y": _mounted.global_position.y,
			"z": _mounted.global_position.z, "ry": _mounted.rotation.y,
		})
