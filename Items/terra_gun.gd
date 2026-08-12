extends Node

## The terraformer: the god menu's dig/fill/smooth brushes, handed to a player
## as a weapon with a real cost.
##
##   LMB          build ground up
##   RMB          cut it away
##   both         smooth, at roughly half the drain
##
## It runs off a charge cell, not ammo. Firing empties it; letting go tops it
## back up over REFILL_TIME — and the refill is paid for in HEALTH. Stop early
## and you pay the going rate; run the cell dry and the whole refill costs
## DRY_PENALTY times as much, so there's a real decision in every stroke.
##
## Terrain edits themselves go through the same 'terrainEdit' event the drone
## uses, so they replay to late joiners and land inside spawn deadzones never.

const CHARGE_MAX := 100.0
const DRAIN_CARVE := 34.0     # per second holding a button — ~3 s from full
const DRAIN_SMOOTH := 16.0    # smoothing is the cheap one
const REFILL_DELAY := 0.5     # beat after you let go before it starts filling
const REFILL_TIME := 5.0      # empty to full, per Ryan
const HP_PER_CHARGE := 0.10   # a full 100-charge refill costs 10 health
const DRY_PENALTY := 1.5      # ...times that, if you ran the cell to nothing
const CARVE_INTERVAL := 0.08
const CARVE_RADIUS := 5.0
const CARVE_STRENGTH := 0.5
const RANGE := 140.0
# Nothing inside this gets sculpted. The brush is 5 m across: fired at your own
# feet it scoops the floor out from under you (or buries you), which is the
# "glitchy up close" — so the ray starts beyond arm's reach and the brush is
# refused if it would still reach the body.
const MIN_RANGE := 7.0
const SELF_CLEARANCE := CARVE_RADIUS + 1.5
const ITEM := "terragun"

var charge := CHARGE_MAX
var dry := false              # ran to empty: this refill is the expensive one

@onready var player: CharacterBody3D = get_parent()

var _items: Node
# Button state is tracked from real events rather than polled: polling reports
# the OS mouse, which stays "down" through focus changes and menu clicks and
# leaves the gun quietly firing at nothing.
var _lmb := false
var _rmb := false
var _idle := 0.0              # seconds since the last shot
var _cd := 0.0
var _hp_owed := 0.0           # fractional health, banked until it's worth sending
var _marker: MeshInstance3D


func _ready() -> void:
	add_to_group("terra_gun")
	_build_marker()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		_lmb = event.pressed
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_rmb = event.pressed


## Charge left, 0..1 — the HUD reads this for the held gun's meter.
func charge_frac() -> float:
	return charge / CHARGE_MAX


## Anywhere in the inventory, not necessarily in hand: the cell keeps topping
## itself up (and charging you for it) from a back slot, but drop the gun
## entirely and it stops costing you anything.
func owned() -> bool:
	if _items == null:
		_items = player.get_node_or_null("ItemController")
	if _items == null:
		return false
	for it in _items.inventory:
		if str(it["type"]) == ITEM:
			return true
	return false


func held() -> bool:
	if _items == null:
		_items = player.get_node_or_null("ItemController")
	return _items != null and _items.held_type() == ITEM \
		and not player.godmode and not player.dead \
		and player.vehicle == null and not player.piloting


func _process(delta: float) -> void:
	_cd = maxf(0.0, _cd - delta)
	if not owned():
		charge = CHARGE_MAX
		dry = false
		_hp_owed = 0.0
		if _marker:
			_marker.visible = false
		return
	var active := held() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and get_viewport().gui_get_focus_owner() == null
	if _marker:
		_marker.visible = false
	if not active:
		_lmb = false
		_rmb = false
		_recharge(delta)
		return

	var lmb := _lmb
	var rmb := _rmb
	var hit := _aim_hit()
	if not hit.is_empty():
		_show_marker(hit["position"])
	if (not lmb and not rmb) or charge <= 0.0 or hit.is_empty():
		_recharge(delta)
		return

	# Both buttons is the smooth tool, and it's the cheap one.
	var mode := "smooth" if (lmb and rmb) else ("add" if lmb else "cut")
	var rate: float = DRAIN_SMOOTH if mode == "smooth" else DRAIN_CARVE
	charge = maxf(0.0, charge - rate * delta)
	if charge <= 0.0:
		dry = true
	_idle = 0.0
	if _cd <= 0.0:
		_cd = CARVE_INTERVAL
		_carve(hit["position"], mode)
	_publish()


## Nothing being fired: after a beat the cell starts filling again, and every
## point of charge it takes back is bought with health.
func _recharge(delta: float) -> void:
	if charge >= CHARGE_MAX:
		dry = false
		_publish()
		return
	_idle += delta
	if _idle < REFILL_DELAY:
		return
	# Refilling is free while you're dead or the mode doesn't track health.
	var gain := minf(CHARGE_MAX - charge, CHARGE_MAX / REFILL_TIME * delta)
	charge += gain
	_hp_owed += gain * HP_PER_CHARGE * (DRY_PENALTY if dry else 1.0)
	if charge >= CHARGE_MAX:
		charge = CHARGE_MAX
		dry = false
		# Settle up at the top: without this the last fraction of a point is
		# never charged, and a full dry refill quietly costs 1.4x instead of 1.5.
		_hp_owed = roundf(_hp_owed)
	_bill()
	_publish()


## Health is server-side and integral, so the fractional cost banks up here and
## is sent a point at a time. It never takes your LAST point: an empty cell
## stalls instead of killing you where you stand.
func _bill() -> void:
	if _hp_owed < 1.0 or player == null or player.dead:
		return
	var hp := int(_hp_owed)
	_hp_owed -= float(hp)
	var have := _health()
	if have <= 1:
		charge = minf(charge, CHARGE_MAX * 0.02)   # stalled: nothing left to spend
		_hp_owed = 0.0
		return
	hp = mini(hp, have - 1)
	if hp > 0:
		Net.emit_event("selfDamage", {"n": hp, "cause": "terra"})


func _health() -> int:
	var sync: Node = get_tree().get_first_node_in_group("net_sync")
	if sync == null:
		return 100
	return int(sync.scores.get(sync.self_id, 100))


## The HUD reads the slot's ammo field, so the charge lives there too.
func _publish() -> void:
	if _items and not _items.inventory.is_empty() and _items.inventory[0]["type"] == ITEM:
		var shown := int(round(charge))
		if int(_items.inventory[0].get("ammo", -1)) != shown:
			_items.inventory[0]["ammo"] = shown
			_items.inventory_changed.emit(_items.inventory)


func _carve(at: Vector3, mode: String) -> void:
	var terrain: Node = get_tree().get_first_node_in_group("voxel_terrain")
	if terrain == null:
		return
	var s := 1.0 if mode == "add" else -1.0
	var hit: bool = terrain.smooth_brush(at, CARVE_RADIUS, CARVE_STRENGTH) if mode == "smooth" \
		else terrain.apply_brush(at, CARVE_RADIUS, s, CARVE_STRENGTH)
	if not hit:
		return
	Net.emit_event("terrainEdit", {
		"x": at.x, "y": at.y, "z": at.z,
		"r": CARVE_RADIUS, "s": s, "st": CARVE_STRENGTH,
		"m": "smooth" if mode == "smooth" else "add",
	})
	Sfx.boost(at, 0.25)


## Where the shot lands. The ray is aimed like every other weapon (camera look,
## corrected back to the body so the muzzle and the crosshair agree) but it
## STARTS a few metres out — otherwise a third-person camera sitting inside a
## hillside carves whatever the lens is buried in rather than what you can see.
func _aim_hit() -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return {}
	var origin := player.global_position + Vector3(0, 0.4, 0)
	var look := -cam.global_transform.basis.z
	# Aim through the point the camera is looking at, so the crosshair is honest
	var focus := cam.global_position + look * RANGE
	var dir := (focus - origin).normalized()
	var from := origin + dir * MIN_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, origin + dir * RANGE)
	q.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	# Never sculpt a hole you're standing in
	if hit and (hit["position"] as Vector3).distance_to(player.global_position) < SELF_CLEARANCE:
		return {}
	return hit


# --- Brush marker ------------------------------------------------------------

## Same wireframe sphere the drone's terrain tools use, so the brush footprint
## is visible before you commit to a stroke.
func _build_marker() -> void:
	_marker = MeshInstance3D.new()
	_marker.top_level = true
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.6, 0.9, 1.0, 0.07)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	sphere.material = mat
	_marker.mesh = sphere
	_marker.visible = false
	add_child(_marker)


func _show_marker(at: Vector3) -> void:
	if _marker == null:
		return
	_marker.visible = true
	_marker.global_position = at
	_marker.scale = Vector3.ONE * CARVE_RADIUS
