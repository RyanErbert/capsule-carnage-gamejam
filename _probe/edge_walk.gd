extends Node3D

## Ryan can leave the map but not get back in. This walks a player-sized sphere
## along the ground from outside the paintable region inward, and reports every
## place it is blocked and how tall the blockage is -- rather than reasoning
## about which of the bowl, the seal and the frame plain ought to line up.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const RADIUS := 0.5            # the player capsule's own half-width
const STEP := 0.5

var _t: Node3D


func _ready() -> void:
	_t = VoxelTerrain.new()
	add_child(_t)
	_t.configure(32, 32)
	# TALL right up to the map edge. The apron blends from the edge pixel's own
	# top down to the rim over MARGIN cells, so the taller the edge is painted
	# the steeper that apron gets -- which is the thing to measure.
	var fill := int(OS.get_environment("EDGE_FILL")) if OS.get_environment("EDGE_FILL") != "" else 5
	var layers: Array = []
	for li in 5:
		var rows: Array = []
		for z in 32:
			var bits := 0
			if li < fill:
				for x in 32:
					bits |= 1 << (31 - x)
			rows.append(bits)
		layers.append(rows)
	_t.build_from_layers(layers)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_walk()
	get_tree().quit()


func _walk() -> void:
	var half: float = _t.paint_half_x()
	print("paint half-extent %.1f m, frame top %.2f, frame inner %.1f" % [
		half, float(_t.FRAME_TOP), float(_t.FRAME_INNER_X)])
	var space := get_world_3d().direct_space_state
	print("%8s %8s %8s   %s" % ["x", "ground", "step", "note"])
	var prev := INF
	var steepest := 0.0
	var steep_x := 0.0
	var x := half + 30.0
	while x > half - 30.0:
		var g := _ground_at(space, x)
		var note := ""
		if g == INF:
			note = "NO GROUND"
		elif prev != INF:
			var rise := g - prev          # walking INWARD, so a rise is a wall
			if rise > 0.35:
				note = "STEP UP %.2f m  <-- blocks re-entry" % rise
			elif rise < -0.35:
				note = "step down %.2f m" % -rise
		if note != "":
			print("%8.1f %8.2f %8s   %s" % [x, g if g != INF else -99.0,
				"--" if prev == INF or g == INF else "%.2f" % (g - prev), note])
		if prev != INF and g != INF:
			var slope := rad_to_deg(atan2(g - prev, STEP))
			if slope > steepest:
				steepest = slope
				steep_x = x
		prev = g
		x -= STEP
	print("steepest inward climb: %.1f deg at x %.1f  (%s)" % [steepest, steep_x,
		"CANNOT be walked back up" if steepest > 50.0 else "climbable"])
	print("edge walk: done")


## Highest solid surface under a point on the +X axis, by ray.
func _ground_at(space: PhysicsDirectSpaceState3D, x: float) -> float:
	var from := Vector3(x, 60.0, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -120.0, 0))
	var hit := space.intersect_ray(q)
	return INF if hit.is_empty() else float((hit["position"] as Vector3).y)
