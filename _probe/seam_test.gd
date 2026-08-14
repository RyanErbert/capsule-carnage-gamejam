extends Node3D

## Two planes and an angle. Nothing else.
##
## No generated level, no driving, no luck. Build a ramp out of the REAL terrain
## system -- plain trimesh planes cannot show this, because the rule under
## suspicion reads a voxel density field that plain planes do not have -- then
## ask one question with no physics in it at all:
##
##   put a ball exactly where it would REST on this slope. What does
##   density_at(centre + 0.2 up) say?
##
## Over 0.55 and creative.gd lifts you a metre. If a resting ball trips that on
## an ordinary slope, the bug is proved before anything even moves, and the
## steepest tripping angle is the spawn point for the visual repro.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const PX := 32
const SAMPLE := 0.2
const TRIP := 0.55
const BALL := 0.41

var terrain: Node3D
var ready_frames := 0
var rise := 1        # layers climbed per K pixels: sets the slope angle
var run := 4


func _ready() -> void:
	rise = int(OS.get_environment("RISE")) if OS.has_environment("RISE") else 1
	run = int(OS.get_environment("RUN")) if OS.has_environment("RUN") else 4
	terrain = VoxelTerrain.new()
	add_child(terrain)
	terrain.configure(PX, PX)
	terrain.deadzone_centers = []
	terrain.build_from_layers(_layers())


## A single straight ramp across X: height rises `rise` layers every `run`
## pixels, so the angle is set by the pair and nothing else varies.
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
			var top := clampi((px / run) * rise, 0, 4)
			for li in top + 1:
				out[li][pz * w + (px >> 5)] |= 1 << (31 - (px & 31))
	return out


## Parity, not normals. Walk straight up counting surface crossings: an odd
## number means the point started inside the solid. Convention-independent, so
## it does not care which way Godot decides to report a normal.
func _up_says_inside(space: PhysicsDirectSpaceState3D, from: Vector3) -> bool:
	var at := from
	var top := from.y + 80.0
	var crossings := 0
	while at.y < top and crossings < 32:
		var q := PhysicsRayQueryParameters3D.create(at, Vector3(at.x, top, at.z))
		q.hit_back_faces = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		crossings += 1
		at = (hit["position"] as Vector3) + Vector3(0, 0.02, 0)
	return crossings % 2 == 1


func _physics_process(_delta: float) -> void:
	ready_frames += 1
	if ready_frames < 6:
		return
	var space := get_world_3d().direct_space_state
	var worst := {}
	var tripped := 0
	var tested := 0
	var rows: Array[String] = []
	for i in 46:
		var x := lerpf(-PX * 0.9, PX * 0.9, float(i) / 45.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, 0), Vector3(x, -40, 0))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		var ang := rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))
		# Where the ball actually sits: on the surface, along its normal.
		var centre: Vector3 = (hit["position"] as Vector3) + n * BALL
		var d: float = terrain.density_at(centre + Vector3(0, SAMPLE, 0))
		var d0: float = terrain.density_at(centre)
		tested += 1
		if d > TRIP:
			tripped += 1
			if worst.is_empty() or d > float(worst["d"]):
				worst = {"d": d, "ang": ang, "at": centre}
		rows.append("  slope %5.1f deg   at centre %.3f   0.2 m up %.3f%s" % [
			ang, d0, d, "   <-- OLD RULE LIFTS YOU" if d > TRIP else ""])
	print("=== ramp rise %d per %d px ===" % [rise, run])
	for r in rows:
		print(r)
	print("RESULT %d of %d resting positions trip the bury rule" % [tripped, tested])
	# ...and what a GENUINELY buried body reads, which is what the rule is for.
	var deep: Array[String] = []
	for i in 46:
		var x := lerpf(-PX * 0.9, PX * 0.9, float(i) / 45.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, 0), Vector3(x, -40, 0))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var surf: Vector3 = hit["position"]
		for depth in [0.5, 1.0, 1.5, 2.5]:
			var d: float = terrain.density_at(surf - Vector3(0, depth, 0))
			deep.append("  buried %.1f m -> density %.3f" % [depth, d])
	var by_depth := {}
	for line in deep:
		var k: String = line.split(" -> ")[0]
		var v := float(line.split("density ")[1])
		if not by_depth.has(k) or v < float(by_depth[k]):
			by_depth[k] = v
	print("LOWEST density seen at each burial depth (the rule must still catch these):")
	for k: String in by_depth:
		print("%s -> %.3f" % [k, by_depth[k]])
	# Density cannot separate the two cases. Geometry can: inside solid, a ray
	# cast UP leaves through the shell and reports an outward (upward) normal.
	# In open air it hits nothing; under a cave roof the normal points back down.
	print("
UP-RAY TEST  (inside solid => first hit normal points UP)")
	var rest_wrong := 0
	var rest_n := 0
	var deep_wrong := 0
	var deep_n := 0
	for i in 46:
		var x := lerpf(-PX * 0.9, PX * 0.9, float(i) / 45.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, 0), Vector3(x, -40, 0))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		var surf: Vector3 = hit["position"]
		rest_n += 1
		if _up_says_inside(space, surf + n * BALL):
			rest_wrong += 1
		for depth in [0.6, 1.0, 1.5, 2.5]:
			deep_n += 1
			if not _up_says_inside(space, surf - Vector3(0, depth, 0)):
				deep_wrong += 1
	print("  resting balls called BURIED: %d of %d   (want 0)" % [rest_wrong, rest_n])
	print("  buried balls MISSED:        %d of %d   (want 0)" % [deep_wrong, deep_n])
	if not worst.is_empty():
		print("WORST slope %.1f deg, density %.3f, spawn at %v" % [
			worst["ang"], worst["d"], worst["at"]])
	get_tree().quit()
