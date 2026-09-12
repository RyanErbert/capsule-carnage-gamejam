extends Node

## The vampire gun: hold LMB and a beam leaves the muzzle. Land it on someone
## and their health trickles into yours, a point at a time.
##
## It runs on HEAT, not ammo. Firing builds heat over FIRE_TIME seconds; hit
## the top and the gun locks for OVERHEAT_CD seconds. Heat bleeds off faster
## than it builds, so a burst-and-release rhythm never locks it at all -- the
## cooldown is what you get for greed, not for use.
##
## The beam itself is client-side (Items/vampire_beam.gd); only the drain
## crosses the wire, as 'vampireTick {t}' pulses that the server turns into a
## one-point transfer. Everyone else sees the beam through 'vampireBeam'.

const ITEM := "vampire"
const FIRE_TIME := 10.0        # seconds of continuous fire to overheat
const COOL_FACTOR := 2.2       # heat leaves this much faster than it arrives
const OVERHEAT_CD := 5.0
const RANGE := 42.0
const LOCK_PERP := 2.2         # how far off the aim ray a target may sit
const DRAIN_INTERVAL := 0.25   # one point every quarter second: 4 hp/s
const RELAY_INTERVAL := 0.1
const MUZZLE := Vector3(0.34, 0.11, -0.9)   # weapon_rig MOUNT + the barrel, body space

var heat := 0.0                # 0..1
var overheated := false
var cooldown := 0.0            # seconds left locked out
var firing := false            # LMB is down and the gun is live

@onready var player: CharacterBody3D = get_parent()

var _items: Node
var _sync: Node
var _lmb := false
var _drain_cd := 0.0
var _relay_cd := 0.0
var _relayed_on := false
var _beam: Node3D
var _hum: AudioStreamPlayer3D
var _target_id := ""


func _ready() -> void:
	add_to_group("vampire_gun")
	# A probe scene parents this to a bare CharacterBody3D; nothing to do there
	if not player.has_method("set_godmode"):
		set_process(false)
		set_process_unhandled_input(false)
		return
	_beam = load("res://Items/vampire_beam.gd").new()
	add_child(_beam)
	_hum = AudioStreamPlayer3D.new()
	var stream: AudioStreamOggVorbis = load("res://Audio/generator_hum.ogg").duplicate()
	stream.loop = true
	_hum.stream = stream
	_hum.pitch_scale = 1.9
	_hum.volume_db = -14.0
	_hum.max_distance = 30.0
	player.add_child.call_deferred(_hum)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_lmb = event.pressed


func held() -> bool:
	if _items == null:
		_items = player.get_node_or_null("ItemController")
	return _items != null and _items.held_type() == ITEM \
		and not player.godmode and not player.dead \
		and player.vehicle == null and not player.piloting


## 0..1 for the HUD: heat while it builds, the cooldown draining while locked.
func gauge() -> float:
	if overheated:
		return cooldown / OVERHEAT_CD
	return heat


func _process(delta: float) -> void:
	var active := held() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and get_viewport().gui_get_focus_owner() == null
	if not active:
		_lmb = false
	var want := active and _lmb and not overheated
	firing = want
	if overheated:
		cooldown = maxf(0.0, cooldown - delta)
		if cooldown <= 0.0:
			overheated = false
			heat = 0.0
	elif firing:
		heat = minf(1.0, heat + delta / FIRE_TIME)
		if heat >= 1.0:
			overheated = true
			cooldown = OVERHEAT_CD
			firing = false
			Sfx.boost(player.global_position, 0.6)
	else:
		heat = maxf(0.0, heat - delta * COOL_FACTOR / FIRE_TIME)
	_publish()

	if not firing:
		_stop_beam()
		return

	# Where the beam lands: a player in the cone if there is one, otherwise
	# whatever the aim ray hits, otherwise thin air at range.
	var origin := player.global_position + Vector3(0, 0.4, 0)
	var dir := _aim_direction()
	var muzzle := player.global_position + player.global_transform.basis * MUZZLE
	var end := origin + dir * RANGE
	var hit := _ray(origin, end)
	if hit:
		end = hit["position"]
	_target_id = ""
	var lock := _lock_on(origin, dir, origin.distance_to(end) + 1.0)
	if lock != "":
		_target_id = lock
		end = _remotes()[lock].global_position
	_beam.show_beam(muzzle, end, heat, _target_id != "")
	if not _hum.playing:
		_hum.play()
	_hum.pitch_scale = 1.6 + heat * 0.9

	_drain_cd -= delta
	if _target_id != "" and _drain_cd <= 0.0:
		_drain_cd = DRAIN_INTERVAL
		Net.emit_event("vampireTick", {"t": _target_id})
	_relay_cd -= delta
	if _relay_cd <= 0.0:
		_relay_cd = RELAY_INTERVAL
		_relayed_on = true
		Net.emit_event("vampireBeam", {"on": true, "x": end.x, "y": end.y, "z": end.z,
			"h": heat, "f": _target_id != ""})


func _stop_beam() -> void:
	if _beam:
		_beam.hide_beam()
	if _hum and _hum.playing:
		_hum.stop()
	if _relayed_on:
		_relayed_on = false
		Net.emit_event("vampireBeam", {"on": false})


## Nearest ghost within LOCK_PERP of the aim ray, no further than the ray got.
func _lock_on(origin: Vector3, dir: Vector3, max_d: float) -> String:
	var best := ""
	var best_d := INF
	var remotes := _remotes()
	for id in remotes:
		var rp: Vector3 = remotes[id].global_position
		var proj := (rp - origin).dot(dir)
		if proj < 1.0 or proj > minf(RANGE, max_d):
			continue
		if (origin + dir * proj).distance_to(rp) < LOCK_PERP and proj < best_d:
			best_d = proj
			best = str(id)
	return best


func _remotes() -> Dictionary:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	return _sync.remotes() if _sync else {}


func _aim_direction() -> Vector3:
	if _items == null:
		_items = player.get_node_or_null("ItemController")
	return _items.aim_dir() if _items else -player.global_transform.basis.z


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	return player.get_world_3d().direct_space_state.intersect_ray(q)


## The slot's ammo field shows the heat as a percentage, like the terra gun
## shows its charge -- the HUD already knows how to draw that number.
func _publish() -> void:
	if _items and not _items.inventory.is_empty() and _items.inventory[0]["type"] == ITEM:
		var shown := int(round(gauge() * 100.0))
		if int(_items.inventory[0].get("ammo", -1)) != shown:
			_items.inventory[0]["ammo"] = shown
			_items.inventory_changed.emit(_items.inventory)
