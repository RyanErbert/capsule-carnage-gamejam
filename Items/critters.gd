extends Node3D

## Ambient critter flocks with boid steering — crows that wheel overhead and
## dive-bomb, rats that swarm the ground and nip ankles. The server only
## stores each flock's anchor; every client simulates its own copy (they're
## scenery with teeth, not competitive state), and each client applies chip
## damage to ITS OWN player on contact via the existing selfDamage pipeline.

const CROWS := 11
const RATS := 9
const SEP_R := 1.4          # boid separation radius
const NEIGH_R := 5.0        # cohesion/alignment radius
const CROW_SPEED := 7.5
const CROW_DIVE_SPEED := 14.0
const RAT_SPEED := 4.2
const RAT_CHASE := 8.0      # rats within this of the player go for the ankles
const CROW_AGGRO := 24.0
const BITE_CD := 1.4        # seconds between nips per flock
const ANCHOR_R := 16.0      # how far a flock strays from home

# Machine-animal bots: a PILOTED crow-bot/rat-bot within this range becomes
# the flock's home — fly the bot away and the swarm comes with you.
const GUIDE_R := 30.0
const STRIKE_TIME := 3.5    # crow torrent duration after a swarmStrike
const STRIKE_BITE_CD := 0.6 # torrent bites land faster than ambient nips
# Guided swarms run hot enough to pace the machine leading them
const GUIDED_CROW_SPEED := 15.0   # a hair over CROWBOT_SPEED (14)
const GUIDED_RAT_SPEED := 12.0    # a hair over RATBOT_SPEED (11)
const HUNT_TIME := 10.0     # how long a rat-attack mark keeps the pack on someone

# Perching: crows tire of flying and settle on high edges (terrain rims, wall
# tops, tower caps) for a while. Anything that scrambles the flock — a
# piloted crow-bot, a strike, a grudge, a dive — puts them all back up.
const PERCH_MAX := 120.0    # longest a bird rests before taking off again
const PERCH_MIN_AIR := 12.0 # minimum airtime between perches
const PERCH_SEARCH_R := 26.0
const PERCH_TRIES := 14
const PERCH_MIN_DROP := 1.5  # how much a ledge must stand above its neighbour
# Sag while crawling a wall. Deliberately larger than the idle wander and
# smaller than a chase/hunt drive: ambient rats stay on the floor, but one
# with a reason to climb (prey or its pack home up a ledge) goes up.
const RAT_SLIDE := 1.5
const RAT_CLIMB := 3.0       # how hard an into-the-wall push converts to climb

# Combat: critters are shootable (one hit kills a boid) and hold a grudge —
# a flock that loses a member turns on whatever killed it for a while.
const HIT_R := {"crows": 1.0, "rats": 0.8}   # generous per-boid hit radius
const AGGRO_TIME := 12.0
const AGGRO_DIVE_CD := 2.2  # angry crows dive much more often
const GNAW_DMG := 4         # rats/crows chewing on a turret, per contact

@export var player: CharacterBody3D

var _flocks: Dictionary = {}   # id -> {kind, anchor, boids, bite_cd, dive_cd, aggro}
var _sync: Node


func _ready() -> void:
	add_to_group("world_critters")
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentFlocks":
			for id in _flocks:
				_free_flock(id)
			_flocks.clear()
			for f in data:
				_add_flock(f)
		"flockPlaced":
			_add_flock(data)
		"flockRemoved":
			var id := str(data)
			if _flocks.has(id):
				_free_flock(id)
				_flocks.erase(id)
		"swarmStrike":
			if data is Dictionary:
				_apply_strike(str(data.get("id", "")),
					Vector3(data.get("x", 0.0), data.get("y", 0.0), data.get("z", 0.0)))
		"swarmHunt":
			if data is Dictionary:
				_apply_hunt(str(data.get("id", "")), str(data.get("target", "")))
		"critterDied":
			if data is Dictionary:
				_kill_boid(str(data.get("id", "")), int(data.get("idx", -1)), data.get("src"))


func _kill_boid(id: String, idx: int, src: Variant) -> void:
	if not _flocks.has(id):
		return
	var flock: Dictionary = _flocks[id]
	var boids: Array = flock["boids"]
	if idx < 0 or idx >= boids.size() or bool(boids[idx].get("dead", false)):
		return
	var b: Dictionary = boids[idx]
	b["dead"] = true
	(b["node"] as Node3D).visible = false
	Sfx.jump(b["pos"])
	# The flock remembers: whoever did this becomes the target
	if src is Dictionary:
		flock["aggro"] = {"t": str(src.get("t", "player")), "id": str(src.get("id", "")), "left": AGGRO_TIME}


## One shootable boid within its kind's hit radius of `pos`. {} if none.
func hit_test(pos: Vector3) -> Dictionary:
	for id in _flocks:
		var flock: Dictionary = _flocks[id]
		var r: float = HIT_R.get(flock["kind"], 1.0)
		var boids: Array = flock["boids"]
		for i in boids.size():
			if bool(boids[i].get("dead", false)):
				continue
			if (boids[i]["pos"] as Vector3).distance_to(pos) < r:
				return {"id": id, "idx": i, "pos": boids[i]["pos"]}
	return {}


## Nearest living boid within `radius` — turret target acquisition.
func nearest_boid(pos: Vector3, radius: float) -> Dictionary:
	var best := {}
	for id in _flocks:
		var boids: Array = _flocks[id]["boids"]
		for i in boids.size():
			if bool(boids[i].get("dead", false)):
				continue
			var d: float = (boids[i]["pos"] as Vector3).distance_to(pos)
			if d < radius and (best.is_empty() or d < best["dist"]):
				best = {"id": id, "idx": i, "pos": boids[i]["pos"], "dist": d}
	return best


## Where the flock's grudge target is right now (null = gone, drop the aggro).
func _aggro_pos(flock: Dictionary) -> Variant:
	var ag: Variant = flock.get("aggro")
	if not ag is Dictionary or float(ag.get("left", 0.0)) <= 0.0:
		return null
	if ag["t"] == "turret":
		var wt: Node = get_tree().get_first_node_in_group("world_turrets")
		return wt.turret_pos(str(ag["id"])) if wt else null
	return _player_pos(str(ag["id"]))


## Where a player (ourselves or a remote) is right now, or null.
func _player_pos(pid: String) -> Variant:
	if _sync == null:
		_sync = get_tree().get_first_node_in_group("net_sync")
	if _sync and pid == str(_sync.self_id):
		return player.global_position if player and not player.dead else null
	if _sync and _sync.remotes().has(pid):
		return (_sync.remotes()[pid] as Node3D).global_position
	return null


## What a bite from this flock reads as on the death line.
static func _bite_cause(flock: Dictionary) -> String:
	return "crows" if str(flock.get("kind", "rats")) == "crows" else "rats"


## Contact damage against the grudge target: the local player hurts itself
## (the standing selfDamage pattern); a turret is gnawed by ITS OWNER's
## client only, so the damage isn't applied once per connected player.
func _aggro_bite(flock: Dictionary, pos: Vector3) -> void:
	if float(flock["bite_cd"]) > 0.0:
		return
	var ag: Dictionary = flock["aggro"]
	flock["bite_cd"] = BITE_CD
	if ag["t"] == "turret":
		var wt: Node = get_tree().get_first_node_in_group("world_turrets")
		if wt and wt.my_turret(str(ag["id"])):
			Net.emit_event("turretHit", {"id": str(ag["id"]), "dmg": GNAW_DMG})
		Sfx.boost(pos, 0.3)
	else:
		if _sync and str(ag["id"]) == str(_sync.self_id):
			Net.emit_event("selfDamage", {"n": 1, "cause": _bite_cause(flock)})
		Sfx.jump(pos)


## A crow-bot pilot clicked a target: every crow flock that bot is currently
## guiding surges there for a few seconds.
func _apply_strike(pilot_id: String, point: Vector3) -> void:
	var bot := _pilot_bot("bot_crow", pilot_id)
	if bot == null:
		return
	for id in _flocks:
		var flock: Dictionary = _flocks[id]
		if flock["kind"] != "crows":
			continue
		if _flock_center(flock).distance_to(bot.global_position) < GUIDE_R:
			flock["strike"] = point
			flock["strike_t"] = STRIKE_TIME


## A rat-attack pilot marked a player: every rat pack that bot is currently
## guiding hunts the target until the mark runs out.
func _apply_hunt(pilot_id: String, target_id: String) -> void:
	var bot := _pilot_bot("bot_rat", pilot_id)
	if bot == null or target_id == "":
		return
	for id in _flocks:
		var flock: Dictionary = _flocks[id]
		if flock["kind"] != "rats":
			continue
		if _flock_center(flock).distance_to(bot.global_position) < GUIDE_R:
			flock["hunt"] = {"id": target_id, "left": HUNT_TIME}


## The bot in `group` this pilot is currently driving, or null.
func _pilot_bot(group: String, pilot_id: String) -> Node3D:
	for n in get_tree().get_nodes_in_group(group):
		if n is Node3D and str(n.get("driver_id")) == pilot_id:
			return n
	return null


func _flock_center(flock: Dictionary) -> Vector3:
	var c := Vector3.ZERO
	var n := 0
	for b in flock["boids"]:
		if not bool(b.get("dead", false)):
			c += b["pos"] as Vector3
			n += 1
	return c / n if n > 0 else flock["anchor"] as Vector3


## Nearest PILOTED bot of the matching kind within guide range. Remote pilots
## count too (driver_id relays through vehicleDriver), so everyone's local
## flock copy follows the same machine.
func _guide_bot(group: String, near: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := GUIDE_R
	for n in get_tree().get_nodes_in_group(group):
		if not (n is Node3D) or str(n.get("driver_id")) == "":
			continue
		var d: float = (n as Node3D).global_position.distance_to(near)
		if d < best_d:
			best_d = d
			best = n
	return best


func _free_flock(id: String) -> void:
	for b in _flocks[id]["boids"]:
		if is_instance_valid(b["node"]):
			(b["node"] as Node3D).queue_free()


## Nearest flock anchor within `radius` — god menu delete/select. {} if none.
func nearest_deletable(pos: Vector3, radius := 6.0) -> Dictionary:
	var best := {}
	for id in _flocks:
		var d: float = (_flocks[id]["anchor"] as Vector3).distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _flocks[id]["anchor"]}
	return best


func _add_flock(f: Variant) -> void:
	if not f is Dictionary:
		return
	var id := str(f.get("id", ""))
	if id == "" or _flocks.has(id):
		return
	var kind := str(f.get("kind", "crows"))
	var anchor := Vector3(f.get("x", 0.0), f.get("y", 0.0), f.get("z", 0.0))
	var boids: Array = []
	var n := CROWS if kind == "crows" else RATS
	var dead: Array = f.get("dead", []) if f.get("dead") is Array else []
	for i in n:
		var node := _make_crow() if kind == "crows" else _make_rat()
		add_child(node)
		var off := Vector3(randf_range(-4, 4), randf_range(4, 9) if kind == "crows" else 0.3, randf_range(-4, 4))
		node.global_position = anchor + off
		var is_dead := dead.has(i) or dead.has(float(i))  # JSON numbers arrive as floats
		node.visible = not is_dead
		boids.append({
			"node": node,
			"pos": node.global_position,
			"vel": Vector3(randf_range(-2, 2), 0, randf_range(-2, 2)),
			"diving": false,
			"dead": is_dead,
			# Per-bird flight personality, so a flock spreads out instead of
			# orbiting as one ring
			"ring_r": randf_range(0.45, 1.25),
			"ring_y": randf_range(-5.0, 6.0),
			"spin": 1.0 if randf() < 0.7 else -1.0,
			"bob": randf_range(0.15, 0.5),
			"phase": randf() * TAU,
			"perch": null,
			"perch_to": null,
			"perch_t": 0.0,
			"perch_cd": randf_range(4.0, 30.0),
		})
	_flocks[id] = {"kind": kind, "anchor": anchor, "boids": boids, "bite_cd": 0.0, "dive_cd": randf_range(3.0, 7.0)}


func _physics_process(delta: float) -> void:
	for id in _flocks:
		var flock: Dictionary = _flocks[id]
		flock["bite_cd"] = maxf(0.0, float(flock["bite_cd"]) - delta)
		var ag: Variant = flock.get("aggro")
		if ag is Dictionary:
			ag["left"] = float(ag["left"]) - delta
			if float(ag["left"]) <= 0.0:
				flock.erase("aggro")
		var hu: Variant = flock.get("hunt")
		if hu is Dictionary:
			hu["left"] = float(hu["left"]) - delta
			if float(hu["left"]) <= 0.0:
				flock.erase("hunt")
		if flock["kind"] == "crows":
			_tick_crows(flock, delta)
		else:
			_tick_rats(flock, delta)


## Classic three-rule boids plus an anchor pull; one crow at a time breaks
## formation to dive at the player, then climbs back into the wheel. Birds
## that have been up a while go look for a high edge to PERCH on, sit there
## for up to PERCH_MAX, then take off again — so a flock reads as scattered
## individuals rather than one synchronized ring.
func _tick_crows(flock: Dictionary, delta: float) -> void:
	var boids: Array = flock["boids"]
	var anchor: Vector3 = flock["anchor"]
	# A piloted crow-bot near the flock replaces home — the wheel follows it
	var bot := _guide_bot("bot_crow", _flock_center(flock))
	var home: Vector3 = bot.global_position + Vector3(0, 2.5, 0) if bot \
		else anchor + Vector3(0, 8.0, 0)
	flock["strike_t"] = maxf(0.0, float(flock.get("strike_t", 0.0)) - delta)
	var striking: bool = flock["strike_t"] > 0.0
	var strike_p: Vector3 = flock.get("strike", Vector3.ZERO)
	flock["dive_cd"] = float(flock["dive_cd"]) - delta
	# A grudge target (whoever shot a flock member) replaces the usual prey
	var grudge: Variant = _aggro_pos(flock)
	var dive_at: Variant = grudge
	if dive_at == null and player != null and not player.dead and not player.godmode \
			and not player.piloting and player.global_position.distance_to(home) < CROW_AGGRO:
		dive_at = player.global_position
	var can_aggro: bool = dive_at != null
	if flock["dive_cd"] <= 0.0 and can_aggro and not striking:
		flock["dive_cd"] = randf_range(1.5, AGGRO_DIVE_CD + 1.0) if grudge != null else randf_range(4.0, 9.0)
		var alive: Array = boids.filter(func(x): return not bool(x.get("dead", false)))
		if not alive.is_empty():
			var pick: Dictionary = alive.pick_random()
			pick["diving"] = true
	# Anything that scrambles the flock (a bot, a strike, a grudge, a dive)
	# also puts every perched bird back in the air.
	var scramble: bool = bot != null or striking or can_aggro
	for b in boids:
		if bool(b.get("dead", false)):
			continue
		var pos: Vector3 = b["pos"]
		var vel: Vector3 = b["vel"]
		# --- Perching: sit still on a found spot until the rest timer runs out
		if b.get("perch") != null and not scramble:
			b["perch_t"] = float(b.get("perch_t", 0.0)) - delta
			var seat: Vector3 = b["perch"]
			pos = pos.lerp(seat, minf(1.0, 4.0 * delta))
			b["pos"] = pos
			b["vel"] = Vector3.ZERO
			var pnode: Node3D = b["node"]
			pnode.global_position = pos
			# Idle fidget: the odd hop of the head, wings folded
			var wl0: Node3D = pnode.get_node("WingL")
			var fold := -0.15 + sin(Time.get_ticks_msec() / 1000.0 * 0.7 + pos.x) * 0.05
			wl0.rotation.z = fold
			(pnode.get_node("WingR") as Node3D).rotation.z = -fold
			if float(b["perch_t"]) <= 0.0:
				b["perch"] = null
				b["vel"] = Vector3(randf_range(-3, 3), 3.0, randf_range(-3, 3))
				b["perch_cd"] = randf_range(PERCH_MIN_AIR, PERCH_MIN_AIR * 2.5)
			continue
		if b.get("perch") != null and scramble:
			b["perch"] = null
			b["perch_cd"] = randf_range(6.0, 14.0)
			b["vel"] = Vector3(randf_range(-4, 4), 4.0, randf_range(-4, 4))
		# Been flying a while: go look for somewhere high to sit
		b["perch_cd"] = float(b.get("perch_cd", 8.0)) - delta
		if not scramble and float(b["perch_cd"]) <= 0.0 and b.get("perch_to") == null:
			var spot: Variant = _find_perch(pos)
			if spot != null:
				b["perch_to"] = spot
			else:
				b["perch_cd"] = randf_range(4.0, 9.0)  # nothing nearby, try later
		if b.get("perch_to") != null and scramble:
			b["perch_to"] = null
		var accel := Vector3.ZERO
		# Separation / cohesion / alignment
		var center := Vector3.ZERO
		var heading := Vector3.ZERO
		var mates := 0
		for o in boids:
			if o == b or bool(o.get("dead", false)) or o.get("perch") != null:
				continue
			var d: float = pos.distance_to(o["pos"])
			if d < SEP_R and d > 0.001:
				accel += (pos - o["pos"]) / d * 6.0
			if d < NEIGH_R:
				center += o["pos"]
				heading += o["vel"]
				mates += 1
		if mates > 0:
			accel += (center / mates - pos) * 0.8
			accel += (heading / mates - vel) * 0.6
		var speed := CROW_SPEED
		if b.get("perch_to") != null and not scramble:
			# Glide in and land: close enough and slow enough = perched
			var seat_to: Vector3 = b["perch_to"]
			accel += (seat_to - pos).normalized() * 14.0
			speed = CROW_SPEED * 0.8
			if pos.distance_to(seat_to) < 1.0:
				b["perch"] = seat_to
				b["perch_to"] = null
				b["perch_t"] = randf_range(PERCH_MAX * 0.25, PERCH_MAX)
		elif striking:
			# Torrent: the whole flock funnels into the strike point
			b["diving"] = false
			accel += (strike_p - pos).normalized() * 30.0
			speed = CROW_DIVE_SPEED + 3.0
			if pos.distance_to(strike_p) < 1.8 and player != null \
					and not player.dead and not player.godmode \
					and player.global_position.distance_to(strike_p) < 2.4 \
					and float(flock["bite_cd"]) <= 0.0:
				flock["bite_cd"] = STRIKE_BITE_CD
				Net.emit_event("selfDamage", {"n": 1, "cause": "crows"})
				Sfx.jump(pos)
		elif b["diving"] and can_aggro:
			var target: Vector3 = (dive_at as Vector3) + Vector3(0, 0.8, 0)
			accel += (target - pos).normalized() * 22.0
			speed = CROW_DIVE_SPEED
			if pos.distance_to(target) < 1.6:
				b["diving"] = false
				if grudge != null:
					_aggro_bite(flock, pos)  # revenge hit (player or turret)
				elif float(flock["bite_cd"]) <= 0.0:
					flock["bite_cd"] = BITE_CD
					Net.emit_event("selfDamage", {"n": 1, "cause": "crows"})
					Sfx.jump(pos)  # sharp flap-snap on the hit
		else:
			b["diving"] = false
			# Wheel around home. Each bird keeps its OWN ring radius, height
			# offset and orbit direction (rolled at spawn), so a loose flock
			# drifts around the area instead of collapsing into one halo. A
			# guided flock tightens up so it visibly obeys the bot.
			var out := pos - home - Vector3(0, float(b.get("ring_y", 0.0)), 0)
			var ring: float = 6.0 if bot else ANCHOR_R * float(b.get("ring_r", 1.0))
			if out.length() > ring:
				accel += -out.normalized() * (16.0 if bot else 10.0)
			elif not bot and out.length() < ring * 0.45:
				accel += out.normalized() * 4.0   # don't pile into the middle
			accel += Vector3(-out.z, 0, out.x).normalized() * 3.0 * float(b.get("spin", 1.0))
			# Lazy vertical wander so they aren't all on one plane
			var want_y: float = home.y + float(b.get("ring_y", 0.0)) \
				+ sin(Time.get_ticks_msec() / 1000.0 * float(b.get("bob", 0.3)) + float(b.get("phase", 0.0))) * 3.0
			accel.y += clampf(want_y - pos.y, -6.0 if bot else -4.0, 6.0 if bot else 4.0)
			if bot:
				speed = GUIDED_CROW_SPEED  # match the machine's pace
		vel += accel * delta
		vel = vel.limit_length(speed)
		# Crows obey the level: clip the step against terrain/walls and slide
		var clip := _clip_move(pos, pos + vel * delta)
		if clip.is_empty():
			pos += vel * delta
		else:
			pos = (clip["position"] as Vector3) + (clip["normal"] as Vector3) * 0.3
			vel = vel.slide(clip["normal"])
		b["pos"] = pos
		b["vel"] = vel
		var node: Node3D = b["node"]
		node.global_position = pos
		if vel.length() > 0.5:
			node.rotation.y = atan2(-vel.x, -vel.z)
			node.rotation.x = clampf(-vel.y * 0.12, -0.7, 0.7)
		# Wing flap
		var t := Time.get_ticks_msec() / 1000.0 + pos.x
		var flap := sin(t * (18.0 if b["diving"] else 9.0)) * 0.55
		(node.get_node("WingL") as Node3D).rotation.z = flap
		(node.get_node("WingR") as Node3D).rotation.z = -flap


## Rats: 2D boids pinned to the ground, mobbing the player when close.
## A piloted rat-bot nearby becomes the pack's home — it scurries after it.
func _tick_rats(flock: Dictionary, delta: float) -> void:
	var boids: Array = flock["boids"]
	var anchor: Vector3 = flock["anchor"]
	var bot := _guide_bot("bot_rat", _flock_center(flock))
	var home: Vector3 = bot.global_position if bot else anchor
	var grudge: Variant = _aggro_pos(flock)
	# A rat-attack mark: the whole pack runs down one player until it expires
	var hunt: Variant = flock.get("hunt")
	var hunt_p: Variant = _player_pos(str((hunt as Dictionary)["id"])) if hunt is Dictionary else null
	if hunt is Dictionary and hunt_p == null:
		flock.erase("hunt")  # target died or left: drop the mark
	var hunting_me: bool = hunt is Dictionary and _sync \
		and str((hunt as Dictionary)["id"]) == str(_sync.self_id)
	var chase: bool = player != null and not player.dead and not player.godmode \
		and not player.piloting and player.global_position.distance_to(home) < RAT_CHASE + ANCHOR_R
	for b in boids:
		if bool(b.get("dead", false)):
			continue
		var pos: Vector3 = b["pos"]
		var vel: Vector3 = b["vel"]
		var accel := Vector3.ZERO
		for o in boids:
			if o == b or bool(o.get("dead", false)):
				continue
			var d: float = pos.distance_to(o["pos"])
			if d < SEP_R * 0.6 and d > 0.001:
				accel += (pos - o["pos"]) / d * 8.0
		if hunt_p != null:
			var hp := hunt_p as Vector3
			accel += (hp - pos).normalized() * 18.0
			if hunting_me and hp.distance_to(pos) < 1.2 and float(flock["bite_cd"]) <= 0.0:
				flock["bite_cd"] = STRIKE_BITE_CD
				Net.emit_event("selfDamage", {"n": 1, "cause": "rats"})
				Sfx.boost(pos, 0.3)
		elif grudge != null and (grudge as Vector3).distance_to(pos) < RAT_CHASE * 2.5:
			# Revenge mob: swarm whatever shot the pack (player or turret)
			var gp := grudge as Vector3
			accel += (gp - pos).normalized() * 16.0
			if gp.distance_to(pos) < 1.6:
				_aggro_bite(flock, pos)
		elif chase and player.global_position.distance_to(pos) < RAT_CHASE:
			accel += (player.global_position - pos).normalized() * 14.0
			if player.global_position.distance_to(pos) < 1.0 and float(flock["bite_cd"]) <= 0.0:
				flock["bite_cd"] = BITE_CD
				Net.emit_event("selfDamage", {"n": 1, "cause": "rats"})
				Sfx.boost(pos, 0.3)
		else:
			# Guided packs hug the bot much tighter than they'd hold home turf
			var out := pos - home
			if out.length() > (3.5 if bot else 10.0):
				accel += -out.normalized() * (14.0 if bot else 8.0)
			# Idle scurry: wander noise
			accel += Vector3(randf_range(-3, 3), 0, randf_range(-3, 3))
		# Rats climb like the rat-attack: they crawl in the plane of whatever
		# surface they're on (walls and ceilings included), and the part of
		# their drive pushing INTO a surface becomes a climb UP it. Gravity
		# along the surface pulls them back down when they stop pushing, so
		# they don't end up living on the ceiling.
		var n: Vector3 = b.get("n", Vector3.UP)
		var up_t := Vector3.UP - n * Vector3.UP.dot(n)
		if up_t.length() > 0.05:
			up_t = up_t.normalized()
			var into := -accel.dot(n)
			if into > 0.0:
				accel += up_t * into * RAT_CLIMB
			accel -= up_t * RAT_SLIDE   # sag back down the wall
		vel += accel * delta
		# Guided or on a hunt: run hot enough to pace the machine
		var cap := GUIDED_RAT_SPEED if (bot or hunt_p != null) else RAT_SPEED
		vel = (vel - n * vel.dot(n)).limit_length(cap)
		var clip := _clip_move(pos + n * 0.25, pos + n * 0.25 + vel * delta)
		if not clip.is_empty():
			n = clip["normal"]
			b["n"] = n
			vel = vel.slide(n)
		pos += vel * delta
		# Re-seat on the surface along -n; nothing there = back to open ground
		var sq := PhysicsRayQueryParameters3D.create(pos + n * 0.6, pos - n * 1.4)
		if player:
			sq.exclude = [player.get_rid()]
		var seat := get_world_3d().direct_space_state.intersect_ray(sq)
		if seat.is_empty():
			b["n"] = Vector3.UP
			pos.y = _ground_y(pos) + 0.12
		else:
			b["n"] = seat["normal"]
			pos = (seat["position"] as Vector3) + (seat["normal"] as Vector3) * 0.12
		b["pos"] = pos
		b["vel"] = vel
		var node: Node3D = b["node"]
		node.global_position = pos
		if vel.length() > 0.3:
			var nn: Vector3 = b.get("n", Vector3.UP)
			var f := vel - nn * vel.dot(nn)
			if f.length() > 0.05 and absf(f.normalized().dot(nn)) < 0.99:
				node.global_transform.basis = Basis.looking_at(f.normalized(), nn)


func _ground_y(pos: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 4, 0), pos + Vector3(0, -12, 0))
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if hit else pos.y


## Hunt for somewhere high to sit near `pos`: sample points around the bird,
## drop a ray, and take a hit that is an EDGE — flat-ish on top, with open air
## just beside it (a wall cap, a rim, a tower top), well above the ground
## below it. Returns a seat position, or null when nothing suitable is close.
func _find_perch(pos: Vector3) -> Variant:
	var space := get_world_3d().direct_space_state
	var best: Variant = null
	var best_h := PERCH_MIN_DROP   # must stand this far above its surroundings
	for _i in PERCH_TRIES:
		var a := randf() * TAU
		var d := randf_range(4.0, PERCH_SEARCH_R)
		var probe := pos + Vector3(cos(a) * d, 0, sin(a) * d)
		var from := probe + Vector3(0, 6.0, 0)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -40.0, 0))
		if player:
			q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or float(hit["normal"].y) < 0.6:
			continue   # nothing there, or too steep to stand on
		var top: Vector3 = hit["position"]
		# Is it an EDGE? Sample the four neighbours and take the BIGGEST drop —
		# one side falling away is what makes a ledge, wall cap or rim.
		var drop := 0.0
		for step: Vector3 in [Vector3(1.6, 0, 0), Vector3(-1.6, 0, 0), Vector3(0, 0, 1.6), Vector3(0, 0, -1.6)]:
			var nf := top + step + Vector3(0, 1.0, 0)
			var nq := PhysicsRayQueryParameters3D.create(nf, nf + Vector3(0, -40.0, 0))
			if player:
				nq.exclude = [player.get_rid()]
			var nh := space.intersect_ray(nq)
			drop = maxf(drop, top.y - float(nh["position"].y) if nh else 40.0)
		if drop > best_h:
			best_h = drop
			best = top + Vector3(0, 0.16, 0)
	return best


## Segment cast for a boid step (with a little skin), ignoring our own player
## so dives can still reach them. {} = path clear.
func _clip_move(from: Vector3, to: Vector3) -> Dictionary:
	var dir := to - from
	if dir.length_squared() < 0.000001:
		return {}
	var q := PhysicsRayQueryParameters3D.create(from, to + dir.normalized() * 0.3)
	if player:
		q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


# --- Bodies (procedural, matching the blocky look) ---------------------------

func _make_crow() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.1)
	mat.roughness = 0.9
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.16, 0.12, 0.42)
	bm.material = mat
	body.mesh = bm
	root.add_child(body)
	var beak := MeshInstance3D.new()
	var beak_mesh := BoxMesh.new()
	beak_mesh.size = Vector3(0.05, 0.05, 0.12)
	var beak_mat := StandardMaterial3D.new()
	beak_mat.albedo_color = Color(0.9, 0.75, 0.3)
	beak_mesh.material = beak_mat
	beak.mesh = beak_mesh
	beak.position = Vector3(0, 0.02, -0.25)
	root.add_child(beak)
	for side in [-1.0, 1.0]:
		var wing := MeshInstance3D.new()
		wing.name = "WingL" if side < 0 else "WingR"
		var wm := BoxMesh.new()
		wm.size = Vector3(0.55, 0.02, 0.28)
		wm.material = mat
		wing.mesh = wm
		wing.position = Vector3(side * 0.33, 0.04, 0.02)
		root.add_child(wing)
	return root


func _make_rat() -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.4, 0.38)
	mat.roughness = 0.95
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.09
	cap.height = 0.4
	cap.material = mat
	body.mesh = cap
	body.rotation.x = PI / 2.0  # lie flat, nose forward
	body.position.y = 0.09
	root.add_child(body)
	var tail := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.025, 0.025, 0.3)
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.7, 0.5, 0.45)
	tm.material = tail_mat
	tail.mesh = tm
	tail.position = Vector3(0, 0.07, 0.32)
	root.add_child(tail)
	return root
