extends Node3D

## Energy is the referee.
##
## With no key pressed, the only things acting on the ball are gravity and
## contact. Gravity is already in the ledger as height. Contact can only ever
## TAKE energy -- sliding takes, landing takes, friction takes. So
##
##     E = 0.5 * |v|^2 + g * h
##
## must never increase. Any frame where it does is a bug, with no threshold to
## argue about and no opinion of mine about what a jump looks like. Every
## detector before this one encoded my guess and then agreed with me: rise
## flagged landings, the kick log quoted its own clamp, the topology probe
## counted its own respawn. This one cannot do that.
##
## It drives the REAL world -- surface-nets terrain and WFC compounds -- from a
## grid of start points, headings and speeds, and ranks what it finds.

const Wfc := preload("res://Items/wfc.gd")
const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const PlayerScene := preload("res://Player/player.tscn")
const PX := 40
const G := 20.0                # player.gd GRAVITY
const TRIAL_FRAMES := 100      # ~1.7 s per run
const SETTLE := 12             # frames to let it seat before judging
const NOISE := 0.05            # J/kg per frame of float slop, ignored

var player: CharacterBody3D
var terrain: Node3D
var trials: Array = []         # [start, heading, speed]
var t := -1
var frame := 0
var prev_e := 0.0
var worst_frame := 0.0
var gained := 0.0
var prev_v := Vector3.ZERO
var prev_p := Vector3.ZERO
var worst: Dictionary = {}     # the frame itself, not where the trial ended
var hits: Array = []           # every trial that gained energy
var started := false


func _ready() -> void:
	Settings.movement = "default"
	_settings()
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = Sky.new()
	e.sky.sky_material = ProceduralSkyMaterial.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment = e
	add_child(env)

	terrain = VoxelTerrain.new()
	add_child(terrain)
	terrain.configure(PX, PX)
	terrain.deadzone_centers = []
	terrain.build_from_layers(_layers())
	var style := OS.get_environment("STYLE") if OS.has_environment("STYLE") else "surface"
	for i in 3:
		var c: StaticBody3D = Wfc.build(11 + i * 17, 8, style)
		c.position = [Vector3(-26, 0, -22), Vector3(24, 0, 20), Vector3(-20, 0, 26)][i]
		add_child(c)

	player = PlayerScene.instantiate()
	add_child(player)
	player.global_position = Vector3(0, 40, 0)


func _settings() -> void:
	# Reasserted every frame: Net overwrites game_settings from the server, which
	# is how an earlier probe ran monkey ball while claiming it was off.
	Net.game_settings = {
		"speedScale": 0.7, "accelScale": 3.0, "turnScale": 1.0, "boostScale": 1.0,
		"jumpScale": 0.58, "gravityScale": 1.0, "monkey": true,
		"infiniteAmmo": true, "slayer": false,
	}


func _layers() -> Array:
	var w := (PX + 31) >> 5
	var out: Array = []
	for li in 5:
		var rows: Array = []
		rows.resize(PX * w)
		rows.fill(0)
		out.append(rows)
	for pz in PX:
		for px in PX:
			var fx := float(px) / float(PX)
			var fz := float(pz) / float(PX)
			var h := 2.1 + 1.9 * sin(fx * TAU * 1.1) * cos(fz * TAU * 0.9) \
				+ 0.9 * sin(fx * TAU * 2.7 + 1.0) + 0.6 * cos(fz * TAU * 3.3 + 2.0)
			for li in clampi(int(roundf(h)), 0, 4) + 1:
				out[li][pz * w + (px >> 5)] |= 1 << (31 - (px & 31))
	return out


## Where the ground actually is, so every trial starts ON something.
func _ground_at(x: float, z: float) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, z), Vector3(x, -40, z))
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	return (hit["position"] as Vector3) + Vector3(0, 0.5, 0) if hit else Vector3.ZERO


func _plan() -> void:
	var span := PX * 1.7
	for ix in 9:
		for iz in 9:
			var x := lerpf(-span * 0.5, span * 0.5, float(ix) / 8.0)
			var z := lerpf(-span * 0.5, span * 0.5, float(iz) / 8.0)
			var at := _ground_at(x, z)
			if at == Vector3.ZERO:
				continue
			for h in 4:
				var a := TAU * float(h) / 4.0
				trials.append([at, Vector3(cos(a), 0, sin(a)), 22.0])
	print("[energy] %d trials over the real world" % trials.size())


func _energy() -> float:
	return 0.5 * player.velocity.length_squared() + G * player.global_position.y


func _next() -> void:
	if not hits.is_empty() and t >= 0:
		pass
	t += 1
	if t >= trials.size():
		_report()
		return
	frame = 0
	worst_frame = 0.0
	gained = 0.0
	worst = {}
	var tr: Array = trials[t]
	player.global_position = tr[0]
	player.velocity = (tr[1] as Vector3) * float(tr[2])
	player.air_time = 0.0
	prev_e = _energy()
	prev_v = player.velocity
	prev_p = player.global_position


func _report() -> void:
	hits.sort_custom(func(a, b): return float(a["gain"]) > float(b["gain"]))
	print("\n=== %d of %d trials gained energy ===" % [hits.size(), trials.size()])
	for i in mini(12, hits.size()):
		var h: Dictionary = hits[i]
		print("  +%7.2f J/kg  worst frame +%6.2f at %v  |v|%5.1f  dv%v  dp%v  touching%s
        around:%s" % [
			h["gain"], h["frame"], (h["at"] as Vector3).round(), h["v"],
			(h["dv"] as Vector3).round(), (h["dp"] as Vector3).snapped(Vector3.ONE * 0.01),
			h["faces"], h["near"]])
	get_tree().quit()


func _physics_process(_delta: float) -> void:
	_settings()
	if not started:
		# One frame to let the world settle before raycasting for ground.
		frame += 1
		if frame < 8:
			return
		started = true
		_plan()
		_next()
		return
	if t >= trials.size():
		return
	frame += 1
	var e := _energy()
	if frame > SETTLE and player.touching:
		var d := e - prev_e
		if d > NOISE:
			gained += d
			if d > worst_frame:
				# Capture the VIOLATION, not wherever the trial happened to stop.
				# Reporting the end state is how every earlier probe pointed at the
				# wrong geometry. dv is the velocity jump, dp the position jump.
				worst_frame = d
				var faces := ""
				for i in player.get_slide_collision_count():
					faces += " %.0f" % rad_to_deg(acos(clampf(
						player.get_slide_collision(i).get_normal().y, -1.0, 1.0)))
				worst = {
					"at": player.global_position, "near": player._nearby(),
					"dv": player.velocity - prev_v, "dp": player.global_position - prev_p,
					"v": player.velocity.length(), "faces": faces,
				}
	prev_e = e
	prev_v = player.velocity
	prev_p = player.global_position
	if frame >= TRIAL_FRAMES:
		if gained > 0.0 and not worst.is_empty():
			worst["gain"] = gained
			worst["frame"] = worst_frame
			hits.append(worst)
		_next()
