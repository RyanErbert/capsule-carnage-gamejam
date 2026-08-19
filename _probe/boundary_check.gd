extends Node3D

## Can you walk back IN?
##
## Ryan reported an invisible wall at the edge of the modifiable terrain: step
## off it onto the outer plain and something stops you returning. This drives a
## sphere the size of the player's collider inward along +X at a range of
## heights and reports where each one is stopped, plus the ground profile it is
## walking over, so a wall shows up as a height it cannot get past.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const PLAYER_R := 0.5      # matches the SphereShape3D on the player

var _t: Node3D


func _ready() -> void:
	_t = VoxelTerrain.new()
	add_child(_t)
	_t.configure(32, 32)
	_t.build_from_layers(_flat_layers())
	await get_tree().physics_frame
	await get_tree().physics_frame
	_report()
	get_tree().quit()


## Every pixel of the ground layer filled, nothing above: the simplest map
## there is, so anything in the way is structural and not something painted.
func _flat_layers() -> Array:
	var out: Array = []
	for li in 5:
		var rows: Array = []
		for z in 32:
			rows.append(0xFFFFFFFF if li == 1 else 0)
		out.append(rows)
	return out


func _report() -> void:
	var hx: float = _t.paint_half_x()
	print("paint half-extent %.1f m, frame plain inner edge %.1f m, top y %.2f" % [
		hx, _t.FRAME_INNER_X, _t.FRAME_TOP])
	print("")
	print("  x       ground y   (ground profile across the boundary)")
	for i in 26:
		var x := hx - 10.0 + float(i) * 2.0
		print("  %6.1f  %s" % [x, _ground_text(x)])

	# The wall, measured as what it is: the biggest RISE you meet walking inward.
	# A sphere resting exactly on the floor cannot translate into anything at
	# all, so sweeping at zero clearance reports a wall wherever the ground is
	# not perfectly flat -- the step itself is the honest number.
	print("")
	var worst := 0.0
	var worst_at := 0.0
	var prev := -999.0
	var x := hx + 40.0
	while x > hx - 6.0:
		var g := _ground_at(x)
		if g > -900.0 and prev > -900.0 and g - prev > worst:
			worst = g - prev
			worst_at = x
		prev = g
		x -= 0.5
	print("biggest step UP walking inward: %.3f m, at x %.1f" % [worst, worst_at])
	print("player sphere radius is %.2f m, so anything under about %.2f is walkable" % [
		PLAYER_R, PLAYER_R * 0.5])
	print("verdict: %s" % ("walkable" if worst < PLAYER_R * 0.5 else "A WALL"))

	# ...and a body with real clearance drives straight through the seam.
	print("")
	print("  start x   clearance  travelled inward")
	for start: float in [hx + 6.0, hx + 14.0, hx + 30.0]:
		for c: float in [0.1, 0.4, 1.0]:
			var from := Vector3(start, _ground_at(start) + PLAYER_R + c, 0.0)
			var reach := _sweep_inward(from, 60.0)
			print("  %7.1f   %6.2f     %s" % [start, c,
				"clear all 60 m" if reach >= 59.9 else "STOPPED after %.1f m, at x %.1f" % [reach, start - reach]])


func _ground_at(x: float) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, 0), Vector3(x, -60, 0))
	var hit := space.intersect_ray(q)
	return -999.0 if hit.is_empty() else (hit["position"] as Vector3).y


func _ground_text(x: float) -> String:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 60, 0), Vector3(x, -60, 0))
	var hit := space.intersect_ray(q)
	return "none" if hit.is_empty() else "%8.2f" % (hit["position"] as Vector3).y


## Slide a player-sized sphere inward and report how far it got.
func _sweep_inward(from: Vector3, dist: float) -> float:
	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = PLAYER_R
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis(), from)
	q.motion = Vector3(-dist, 0, 0)
	var res := space.cast_motion(q)
	return dist * float(res[0]) if res.size() == 2 else dist
