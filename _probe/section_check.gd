extends SceneTree

## Which section is malformed? clip() and floor_at() have to hand the sweep a
## simple polygon, wound the same way at every station, with the SAME vertex
## count -- a varying sweep pairs vertex j with vertex j, so any station that
## disagrees tears the surface open.

const Profiles := preload("res://Items/parametric/profiles.gd")
const Ops := preload("res://Items/parametric/ops.gd")

func _initialize() -> void:
	var face := Profiles.wall(1.0, 6.0, 8.0, 0.22, 0.9, 0.14)
	print("face: %d points, area %.3f" % [face.size(), _area(face)])

	print("-- clip --")
	for band: Array in [[-8.0, 0.0], [-8.0, 1.5], [-8.0, 4.5], [4.5, 6.0]]:
		var c := Profiles.clip(face, band[0], band[1])
		print("  [%.1f,%.1f] pts %2d area %8.3f tri %s" % [band[0], band[1],
			c.size(), _area(c), "ok" if not Geometry2D.triangulate_polygon(c).is_empty() else "FAIL"])

	print("-- floor_at across an arch --")
	var want := -1
	var bad := 0
	for i in 13:
		var soffit := 4.35 + 1.4 * sqrt(maxf(0.0, 1.0 - pow(2.0 * (float(i) / 12.0) - 1.0, 2.0)))
		var f := Profiles.floor_at(face, soffit)
		if want == -1:
			want = f.size()
		var a := _area(f)
		var tri := not Geometry2D.triangulate_polygon(f).is_empty()
		if f.size() != want or a <= 0.0:
			bad += 1
		print("  y %5.2f pts %2d area %8.3f tri %s" % [soffit, f.size(), a, "ok" if tri else "FAIL"])
	print("stations disagreeing on count or winding: %d" % bad)

	# The bridge Ryan walked on: a ConvexPolygonShape3D takes the CONVEX HULL of
	# what it is handed, so a deck with kerbs given over whole comes back as a
	# filled slab -- the kerbs are visible but you walk along the tops of them.
	print("-- deck collision --")
	var deck := Profiles.deck(1.5, 0.6, 0.45)
	var parts := Ops._convex_parts(deck)
	var channel := Vector2(0.0, 0.45)      # between the kerbs, above the deck
	var solid := Vector2(0.0, -0.3)        # inside the slab
	var kerb := Vector2(1.3, 0.2)          # inside a kerb
	var hull := Geometry2D.convex_hull(deck)
	print("  section splits into %d convex pieces" % parts.size())
	var fails := 0
	for probe: Array in [[channel, false, "the channel between the kerbs is OPEN"],
			[solid, true, "the deck slab is SOLID"], [kerb, true, "the kerb is SOLID"]]:
		var inside := false
		for part: PackedVector2Array in parts:
			if Geometry2D.is_point_in_polygon(probe[0], part):
				inside = true
		var ok: bool = inside == bool(probe[1])
		if not ok:
			fails += 1
		print("  %s %s" % ["ok  " if ok else "FAIL", probe[2]])
	var was := Geometry2D.is_point_in_polygon(channel, hull)
	print("  %s and one hull would have filled it (%s)" % [
		"ok  " if was else "FAIL", "yes" if was else "no"])
	if not was:
		fails += 1
	print("sections: %s" % ("all checks passed" if fails == 0 and bad == 0 else "FAILED"))
	quit()


static func _area(loop: PackedVector2Array) -> float:
	var a := 0.0
	for i in loop.size():
		var p := loop[i]
		var q := loop[(i + 1) % loop.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5
