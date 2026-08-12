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
const STRIKE_CD := 4.0    # crow-bot strike / rat-attack hunt cooldown
const HUNT_RANGE := 30.0  # rat-attack: how far a target can be marked from
const HUNT_CONE := 0.75   # dot(camera fwd, to-target) to count as "in front"
const RAM_SPEED := 9.0    # planar speed at which the hull starts hurting
const RAM_RANGE := 3.4
const RAM_CD := 1.2       # seconds before the same hull can hit again
const VehicleScript := preload("res://Vehicles/vehicle.gd")

@export var player: CharacterBody3D

var _vehicles: Dictionary = {}   # id -> vehicle node
var _mounted: CharacterBody3D = null
var _piloting := false           # _mounted is a bot flown drone-style
var _pending_pilot_id := ""      # weapon-deployed bot: pilot it on vehiclePlaced
var _wrecking: Dictionary = {}   # id -> vehicle whose wreck WE are simulating
var _relay_cd := 0.0
var _strike_cd := 0.0
var _ram_cd := 0.0
var _sync: Node
# Rat-attack hunter vision: red overlays on enemies, one of them selected
var _marks: Dictionary = {}      # remote id -> overlay MeshInstance3D
var _hunt_target := ""           # selected enemy id, "" = none in the cone
var _mark_mat: StandardMaterial3D
var _mark_mat_sel: StandardMaterial3D


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
			_wrecking.clear()
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
			_wrecking.erase(id)
			if _vehicles.has(id):
				_vehicles[id].queue_free()
				_vehicles.erase(id)
		"vehicleMoved":
			if data is Dictionary:
				var id := str(data.get("id", ""))
				var veh: CharacterBody3D = _vehicles.get(id)
				if veh and not veh.driven_by_me and not _wrecking.has(id):
					veh.net_pos = Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0))
					veh.net_yaw = float(data.get("ry", 0.0))
					if data.has("qx"):  # wreck tumbles carry a full orientation
						veh.net_quat = Quaternion(
							float(data.get("qx", 0.0)), float(data.get("qy", 0.0)),
							float(data.get("qz", 0.0)), float(data.get("qw", 1.0))).normalized()
		"vehicleDriver":
			if data is Dictionary:
				_on_driver_changed(str(data.get("id", "")), data.get("driver"))
		"vehicleWrecked":
			var wid := str(data)
			var wveh: CharacterBody3D = _vehicles.get(wid)
			if wveh and not _wrecking.has(wid):
				wveh.enter_wreck(false)
		"vehicleRighted":
			if data is Dictionary:
				var rid := str(data.get("id", ""))
				var rveh: CharacterBody3D = _vehicles.get(rid)
				if rveh:
					rveh.exit_wreck(
						Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0)),
						float(data.get("ry", 0.0)))
				_wrecking.erase(rid)
		"mapRebuilt":
			if _mounted:
				_dismount(false)
			_wrecking.clear()
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
	if bool(v.get("wrecked", false)):
		veh.enter_wreck(false)
	_vehicles[id] = veh
	# A bot WE deployed as a weapon: take the stick the moment it exists
	if id == _pending_pilot_id:
		_pending_pilot_id = ""
		if veh.is_bot() and _mounted == null and player \
				and not player.godmode and not player.dead:
			_pilot(veh)


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
	if get_viewport().gui_get_focus_owner() != null \
			or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			or player == null or player.godmode or player.dead:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_E:
		if _mounted:
			_dismount(true)
			get_viewport().set_input_as_handled()
		elif _try_flip():
			get_viewport().set_input_as_handled()
		elif _try_mount():
			get_viewport().set_input_as_handled()
	# Bot pilot clicks. Crow-bot: send the guided flock at whatever the
	# crosshair is on. Rat-attack: mark the selected enemy for the pack.
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and _piloting and _mounted:
		if _mounted.kind == "crowbot":
			_swarm_strike()
			get_viewport().set_input_as_handled()
		elif _mounted.kind == "ratbot" and _hunt_target != "":
			_swarm_hunt()
			get_viewport().set_input_as_handled()


## E next to a wreck rights it: the server reparks it where it lies.
func _try_flip() -> bool:
	for id in _vehicles:
		var veh: CharacterBody3D = _vehicles[id]
		if veh.wrecked and veh.global_position.distance_to(player.global_position) < MOUNT_RANGE:
			Net.emit_event("flipVehicle", id)
			Sfx.boost(veh.global_position, 0.6)
			return true
	return false


func _try_mount() -> bool:
	var best: CharacterBody3D = null
	var best_d := MOUNT_RANGE
	for id in _vehicles:
		var veh: CharacterBody3D = _vehicles[id]
		if veh.wrecked:
			continue  # flip it first
		if veh.driver_id != "" and veh.driver_id != _self_id():
			continue  # someone's in it
		var d: float = veh.global_position.distance_to(player.global_position)
		if d < best_d:
			best_d = d
			best = veh
	if best == null:
		return false
	if best.is_bot():
		_pilot(best)
		return true
	_mounted = best
	best.driver_id = _self_id()
	best.driven_by_me = true
	best.camera_rig = player.camera_rig
	player.enter_vehicle(best)
	if player.camera_rig:
		player.camera_rig.follow_target = best
	Net.emit_event("mountVehicle", best.id)
	Sfx.boost(best.global_position, 0.5)
	return true


## Bots aren't ridden — they're flown drone-style: the body stays where it
## stands (vulnerable), the camera and inputs move to the machine, and the
## drone's sci-fi overlay comes up.
func _pilot(veh: CharacterBody3D) -> void:
	_mounted = veh
	_piloting = true
	veh.driver_id = _self_id()
	veh.driven_by_me = true
	veh.camera_rig = player.camera_rig
	player.set_piloting(true)
	if player.camera_rig:
		player.camera_rig.follow_target = veh
	_set_scifi(true, veh.kind == "ratbot")  # rat-attack hunts in red
	Net.emit_event("mountVehicle", veh.id)
	Sfx.boost(veh.global_position, 0.5)


func _set_scifi(on: bool, red := false) -> void:
	var fx: Node = get_tree().get_first_node_in_group("screen_fx")
	if fx:
		fx.set_scifi(on, Vector3(1.5, 0.55, 0.5) if red else Vector3(0.72, 1.05, 1.28))


## Deploy a bot just ahead of the player (weapon activation) and pilot it as
## soon as the server echoes it back.
func deploy_bot(kind: String) -> void:
	if _mounted != null or player == null:
		return
	var yaw: float = player.camera_rig.yaw if player.camera_rig else 0.0
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var pos: Vector3 = player.global_position + fwd * 2.5 \
		+ Vector3(0, 2.2 if kind == "crowbot" else 0.5, 0)
	_pending_pilot_id = "%d-%d" % [Time.get_ticks_msec(), randi() % 10000]
	Net.emit_event("placeVehicle", {
		"id": _pending_pilot_id, "kind": kind,
		"x": pos.x, "y": pos.y, "z": pos.z, "ry": yaw,
	})


func _swarm_strike() -> void:
	if _strike_cd > 0.0:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var dir := -cam.global_transform.basis.z
	var to := cam.global_position + dir * 80.0
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, to)
	q.exclude = [_mounted.get_rid(), player.get_rid()]
	var hit := _mounted.get_world_3d().direct_space_state.intersect_ray(q)
	var target: Vector3 = hit["position"] if hit else cam.global_position + dir * 40.0
	_strike_cd = STRIKE_CD
	Net.emit_event("swarmStrike", {"x": target.x, "y": target.y, "z": target.z})
	Sfx.boost(_mounted.global_position, 0.9)


## Rat-attack: sic every guided rat pack on the selected enemy.
func _swarm_hunt() -> void:
	if _strike_cd > 0.0:
		return
	_strike_cd = STRIKE_CD
	Net.emit_event("swarmHunt", {"t": _hunt_target})
	Sfx.boost(_mounted.global_position, 0.9)


## Hunter vision while flying the rat-attack: every enemy gets a red overlay
## (read through walls, machine-vision style); the one most in front of the
## camera within range is SELECTED — brighter — and LMB sends the pack at them.
func _update_hunter_vision() -> void:
	var hunting: bool = _piloting and _mounted != null and is_instance_valid(_mounted) \
		and _mounted.kind == "ratbot"
	for rid in _marks.keys():
		if not is_instance_valid(_marks[rid]):
			_marks.erase(rid)
		else:
			_marks[rid].visible = false
	if not hunting:
		_hunt_target = ""
		return
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	var remotes: Dictionary = _sync.remotes() if _sync else {}
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_transform.basis.z if cam else Vector3.FORWARD
	_hunt_target = ""
	var best_dot := HUNT_CONE
	for rid in remotes:
		var node: Node3D = remotes[rid]
		if not is_instance_valid(node):
			continue
		var mark := _mark_for(str(rid))
		mark.visible = true
		mark.global_position = node.global_position
		mark.material_override = _mark_material(false)
		if cam and node.global_position.distance_to(_mounted.global_position) < HUNT_RANGE:
			var d := fwd.dot((node.global_position - cam.global_position).normalized())
			if d > best_dot:
				best_dot = d
				_hunt_target = str(rid)
	if _hunt_target != "" and _marks.has(_hunt_target):
		_marks[_hunt_target].material_override = _mark_material(true)


func _mark_for(rid: String) -> MeshInstance3D:
	var m: MeshInstance3D = _marks.get(rid)
	if m and is_instance_valid(m):
		return m
	m = MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.55
	cap.height = 1.9
	m.mesh = cap
	add_child(m)
	_marks[rid] = m
	return m


func _mark_material(selected: bool) -> StandardMaterial3D:
	if selected:
		if _mark_mat_sel == null:
			_mark_mat_sel = _make_mark_mat(Color(1.0, 0.15, 0.1, 0.55))
		return _mark_mat_sel
	if _mark_mat == null:
		_mark_mat = _make_mark_mat(Color(1.0, 0.25, 0.2, 0.22))
	return _mark_mat


static func _make_mark_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.no_depth_test = true   # hunter vision reads through everything
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _dismount(tell_server: bool) -> void:
	var veh := _mounted
	var was_piloting := _piloting
	_mounted = null
	_piloting = false
	if was_piloting:
		_set_scifi(false)
		if player:
			player.set_piloting(false)
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
		if not was_piloting:
			player.exit_vehicle()  # piloting never moved the body
		if player.camera_rig:
			player.camera_rig.follow_target = null


func _process(delta: float) -> void:
	_relay_cd -= delta
	_strike_cd = maxf(0.0, _strike_cd - delta)
	var relay := _relay_cd <= 0.0
	if relay:
		_relay_cd = RELAY_INTERVAL
	_tick_wrecks(relay)
	_update_hunter_vision()
	if _mounted == null:
		return
	if not is_instance_valid(_mounted):
		_mounted = null
		if player:
			player.exit_vehicle()
		return
	# Slamming into a wall: hop out, hand the hull to rigid-body physics.
	if _mounted.crashed:
		_crash(_mounted)
		return
	# Entering drone/god mode (or dying) hops you out first.
	if player and (player.godmode or player.dead):
		_dismount(true)
		return
	# Fell out of the world: rescue vehicle and driver to a spawn point.
	# A piloted bot instead pops back up beside its pilot's body.
	if _mounted.global_position.y < RESCUE_Y:
		_mounted.global_position = (player.global_position + Vector3(0, 2.5, 0)) if _piloting \
			else (player.respawn_point() + Vector3(0, 2.5, 0))
		_mounted.velocity = Vector3.ZERO
	_ram_cd = maxf(0.0, _ram_cd - delta)
	if not _piloting and _ram_cd <= 0.0:
		_check_ram()
	if relay:
		var out := {
			"id": _mounted.id,
			"x": _mounted.global_position.x, "y": _mounted.global_position.y,
			"z": _mounted.global_position.z, "ry": _mounted.rotation.y,
		}
		# Rat-attacks ride walls and ceilings: relay the full orientation
		if _mounted.kind == "ratbot":
			var q: Quaternion = _mounted.quaternion
			out["qx"] = q.x
			out["qy"] = q.y
			out["qz"] = q.z
			out["qw"] = q.w
		Net.emit_event("vehicleMoved", out)


## Running someone down. The driver's client owns the collision test (same
## authority rule as bullets); the server applies the damage and names the
## hull on the death line.
func _check_ram() -> void:
	var v: Vector3 = _mounted.velocity
	var spd := Vector2(v.x, v.z).length()
	if spd < RAM_SPEED:
		return
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	var remotes: Dictionary = _sync.remotes() if _sync else {}
	for rid in remotes:
		var node: Node3D = remotes[rid]
		if not is_instance_valid(node):
			continue
		if node.global_position.distance_to(_mounted.global_position) > RAM_RANGE:
			continue
		_ram_cd = RAM_CD
		# Punt them along the hull's heading, with some lift so they tumble
		var dir := (Vector3(v.x, 0.0, v.z).normalized() + Vector3.UP * 0.7).normalized()
		Net.emit_event("ramPlayer", {
			"t": str(rid), "kind": _mounted.kind, "dmg": int(spd * 1.6),
			"dir": {"x": dir.x, "y": dir.y, "z": dir.z},
		})
		Sfx.bomb(node.global_position)
		return


## Eject the driver but KEEP server authority (the driver slot) so our tumble
## relays keep flowing until the wreck resolves.
func _crash(veh: CharacterBody3D) -> void:
	_mounted = null
	veh.driven_by_me = false
	veh.camera_rig = null
	if player:
		player.exit_vehicle()
		if player.camera_rig:
			player.camera_rig.follow_target = null
	veh.enter_wreck(true, veh.crash_vel)
	_wrecking[veh.id] = veh
	Net.emit_event("wreckVehicle", veh.id)
	Sfx.bomb(veh.global_position)


## Relay + resolve the wrecks we simulate. Upright & settled -> parked again;
## settled upside down -> hand the seat back and wait for someone's E-flip.
func _tick_wrecks(relay: bool) -> void:
	for id in _wrecking.keys():
		var veh: CharacterBody3D = _wrecking[id]
		if not is_instance_valid(veh) or not veh.wrecked:
			_wrecking.erase(id)
			continue
		var xf: Transform3D = veh.wreck_transform()
		# Wreck fell out of the world: park it back at a spawn, upright
		if xf.origin.y < RESCUE_Y and player:
			var back: Vector3 = player.respawn_point() + Vector3(0, 2.0, 0)
			_resolve_wreck(veh, back, 0.0)
			continue
		if relay:
			var q := xf.basis.get_rotation_quaternion()
			Net.emit_event("vehicleMoved", {
				"id": id, "x": xf.origin.x, "y": xf.origin.y, "z": xf.origin.z,
				"ry": xf.basis.get_euler().y,
				"qx": q.x, "qy": q.y, "qz": q.z, "qw": q.w,
			})
		if not veh.wreck_settled():
			continue
		if veh.wreck_upright():
			_resolve_wreck(veh, xf.origin, xf.basis.get_euler().y)
		else:
			# Stays belly-up: final state, release the seat, await a flip
			Net.emit_event("dismountVehicle", id)
			_wrecking.erase(id)


func _resolve_wreck(veh: CharacterBody3D, pos: Vector3, yaw: float) -> void:
	veh.exit_wreck(pos, yaw)
	Net.emit_event("vehicleMoved", {
		"id": veh.id, "x": pos.x, "y": pos.y, "z": pos.z, "ry": yaw,
	})
	Net.emit_event("vehicleRighted", {
		"id": veh.id, "x": pos.x, "y": pos.y, "z": pos.z, "ry": yaw,
	})
	Net.emit_event("dismountVehicle", veh.id)
	_wrecking.erase(veh.id)
