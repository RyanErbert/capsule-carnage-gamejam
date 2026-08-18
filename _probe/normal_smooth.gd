extends SceneTree

## How much does the surface normal TURN between two points a marble-step apart?
##
## The mesh's normals come from the snapped lattice gradient, which is constant
## across a whole 2 m cell and then jumps at the boundary -- that jump is the
## facet a rolling marble feels. surface_normal() interpolates instead. Walking
## a line across a slope and measuring the turn per step shows the difference
## without needing physics to have stepped.

const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")
const STEP := 0.25


func _initialize() -> void:
	var t := VoxelTerrain.new()
	get_root().add_child(t)
	t.configure(32, 32)
	var layers: Array = []
	for li in 5:
		var rows: Array = []
		for z in 32:
			var bits := 0
			for x in 32:
				if x < 28 - li * 5:     # each slab narrower than the one below: a stepped ramp
					bits |= 1 << (31 - x)
			rows.append(bits)
		layers.append(rows)
	t.build_from_layers(layers)

	var snapped := _walk(t, false)
	var interp := _walk(t, true)
	print("samples on the surface: %d" % int(snapped[2]))
	print("snapped gradient (what the mesh used)  worst %6.2f deg  mean %5.2f" % [snapped[0], snapped[1]])
	print("field normal    (what physics now gets) worst %6.2f deg  mean %5.2f" % [interp[0], interp[1]])
	print("worst-case jolt reduced %.1fx, average %.1fx" % [
		snapped[0] / maxf(interp[0], 0.001), snapped[1] / maxf(interp[1], 0.001)])
	quit()


## Find the surface by bisecting the density along Y, then read both normals.
func _walk(t: Node3D, interpolated: bool) -> Array:
	var prev := Vector3.ZERO
	var worst := 0.0
	var total := 0.0
	var n := 0
	var x := -24.0
	while x < 24.0:
		var p := _surface_y(t, x, 4.0)
		x += STEP
		if p == Vector3.ZERO:
			prev = Vector3.ZERO
			continue
		var nv: Vector3 = t.surface_normal(p) if interpolated else t.call("_gradient", p)
		if prev != Vector3.ZERO:
			var turn := rad_to_deg(prev.angle_to(nv))
			worst = maxf(worst, turn)
			total += turn
			n += 1
		prev = nv
	return [worst, total / maxf(float(n), 1.0), float(n)]


func _surface_y(t: Node3D, x: float, z: float) -> Vector3:
	var lo := -18.0
	var hi := 26.0
	if t.call("_sample", Vector3(x, lo, z)) < 0.5 or t.call("_sample", Vector3(x, hi, z)) > 0.5:
		return Vector3.ZERO
	for i in 24:
		var mid := (lo + hi) * 0.5
		if t.call("_sample", Vector3(x, mid, z)) > 0.5:
			lo = mid
		else:
			hi = mid
	return Vector3(x, (lo + hi) * 0.5, z)
