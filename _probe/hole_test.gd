extends Node3D

## Where are the holes, exactly.
##
## A closed surface uses every edge exactly twice, once from each of the two
## triangles that share it. An edge used ONCE is a boundary -- an actual hole in
## the mesh. So count them: no reasoning about which face was masked and which
## chamfer was skipped, just the arithmetic on the triangles that came out.
##
## Reports how many, and where, grouped so a pattern is visible rather than a
## thousand coordinates.

const Wfc := preload("res://Items/wfc.gd")
const SIZE := 8

var ready_frames := 0


func _ready() -> void:
	pass


func _key(a: Vector3, b: Vector3) -> String:
	# Quantised so two triangles that meet still agree on the edge between them.
	var qa := a.snapped(Vector3.ONE * 0.001)
	var qb := b.snapped(Vector3.ONE * 0.001)
	var first := qa
	var second := qb
	if qb.x < qa.x or (qb.x == qa.x and (qb.y < qa.y or (qb.y == qa.y and qb.z < qa.z))):
		first = qb
		second = qa
	return "%.3f,%.3f,%.3f|%.3f,%.3f,%.3f" % [
		first.x, first.y, first.z, second.x, second.y, second.z]


func _scan(tris: PackedVector3Array, label: String) -> void:
	var used: Dictionary = {}
	var where: Dictionary = {}
	var i := 0
	while i + 2 < tris.size():
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		for e in [[a, b], [b, c], [c, a]]:
			var k := _key(e[0], e[1])
			used[k] = int(used.get(k, 0)) + 1
			if not where.has(k):
				where[k] = (e[0] as Vector3 + e[1] as Vector3) * 0.5
		i += 3
	var open_edges := 0
	var heights: Dictionary = {}
	for k: String in used:
		if int(used[k]) == 1:
			open_edges += 1
			var y: float = (where[k] as Vector3).y
			var band := "y %+d" % int(round(y))
			heights[band] = int(heights.get(band, 0)) + 1
	print("%s: %d triangles, %d distinct edges, %d OPEN" % [
		label, tris.size() / 3, used.size(), open_edges])
	if open_edges > 0:
		var bands: Array = heights.keys()
		bands.sort()
		var line := "    open edges by height:"
		for b: String in bands:
			line += "  %s x%d" % [b, heights[b]]
		print(line)


func _physics_process(_delta: float) -> void:
	ready_frames += 1
	if ready_frames < 4:
		return
	for kind in ["deck", "mass", "ramp", "arch", "edge", "corner", "cap"]:
		var part: StaticBody3D = Wfc.build_part(kind)
		if part == null:
			continue
		var shape := _shape_of(part)
		if shape:
			_scan(shape.get_faces(), "part %-7s" % kind)
		part.queue_free()
	for seed_value in [11, 28, 45]:
		var c: StaticBody3D = Wfc.build(seed_value, SIZE, "surface")
		var sh := _shape_of(c)
		if sh:
			_scan(sh.get_faces(), "compound %d" % seed_value)
		c.queue_free()
	get_tree().quit()


func _shape_of(body: Node) -> ConcavePolygonShape3D:
	for ch in body.get_children():
		if ch is CollisionShape3D and (ch as CollisionShape3D).shape is ConcavePolygonShape3D:
			return (ch as CollisionShape3D).shape as ConcavePolygonShape3D
	return null
