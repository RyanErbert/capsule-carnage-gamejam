extends SceneTree

## Round-trips the handle drag. For a target value, work out where that handle
## would sit, sight at that point from an arbitrary camera position, run the
## ray-to-axis math, and check the value that comes back is the one we aimed at.
##
## Sighting from several angles matters: the closest-point-between-skew-lines
## solution degenerates as the view lines up with the axis, and a formula with a
## sign error still looks right from straight on.

const Registry := preload("res://Items/parametric/registry.gd")
const Spec := preload("res://Items/parametric/spec.gd")
const Rig := preload("res://Items/parametric/handle_rig.gd")

const EYES := [
	Vector3(30, 18, 40), Vector3(-35, 9, 25), Vector3(5, 40, 12),
	Vector3(-20, 3, -30), Vector3(48, 6, -8),
]


func _initialize() -> void:
	var rec := {
		"type": "wall",
		"nodes": Registry.to_wire([Vector3(-14, 0, -4), Vector3(6, 0, -4), Vector3(16, 1, 6)]),
		"params": Registry.defaults("wall"),
	}
	var handles := Registry.handles(rec)
	var fails := 0
	var checked := 0
	for h in handles:
		var d: Dictionary = h
		if int(d["node"]) >= 0:
			continue
		var lo := float(d["min"])
		var hi := float(d["max"])
		for frac: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var want: float = lo + (hi - lo) * frac
			var step := float(d["step"])
			if step > 0.0:
				want = roundf(want / step) * step
			var target: Vector3 = (d["origin"] as Vector3) \
				+ (d["axis"] as Vector3) * want * float(d["scale"])
			for eye in EYES:
				var rd: Vector3 = (target - eye).normalized()
				# Nearly sighting down the axis has no answer; the rig leaves the
				# value alone there, so it is not a failure to skip it.
				if absf(rd.dot(d["axis"])) > 0.985:
					continue
				var on := Rig._closest_on_axis(d["origin"], d["axis"], eye, rd)
				var got := Spec.value_at(d, on)
				checked += 1
				if absf(got - want) > maxf(step, 0.01):
					fails += 1
					if fails <= 4:
						print("  MISS %s want %.2f got %.2f from %v" % [d["key"], want, got, eye])
	print("drag round-trip: %d checks, %d failed" % [checked, fails])

	# A handle placed from a value must read that value back at its own position.
	var bad := 0
	for h in handles:
		var d: Dictionary = h
		if int(d["node"]) < 0 and absf(Spec.value_at(d, d["pos"]) - float(d["value"])) > 1e-3:
			bad += 1
	print("placement inverts cleanly: %s" % ("yes" if bad == 0 else "NO (%d)" % bad))

	# Screen-space segment distance, used for picking.
	var seg := Rig._dist_to_segment(Vector2(50, 0), Vector2(0, 0), Vector2(100, 0))
	var off := Rig._dist_to_segment(Vector2(50, 12), Vector2(0, 0), Vector2(100, 0))
	var past := Rig._dist_to_segment(Vector2(130, 0), Vector2(0, 0), Vector2(100, 0))
	print("pick distance: on-line %.1f, offset %.1f, past-end %.1f" % [seg, off, past])
	print("handles on this wall: %d" % handles.size())
	quit()
