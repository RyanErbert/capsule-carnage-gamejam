extends Node3D

## Standing inside a bored tunnel, is the bury test fooled?
##
## The rescue calls you buried when a ray straight up crosses the surface an ODD
## number of times. That is exact for a closed, consistently wound mesh. An arch
## is a tunnel bored through solid massing, and if the bore leaves the ceiling
## missing, doubled, or facing the wrong way, the count inside the tunnel comes
## out odd -- and the rescue lifts you a metre, every few frames, up into the
## thing you were walking through.
##
## So: build the real arch and count crossings from inside it.

const Wfc := preload("res://Items/wfc.gd")

var ready_frames := 0


func _ready() -> void:
	var part: StaticBody3D = Wfc.build_part("arch")
	add_child(part)


func _crossings_up(space: PhysicsDirectSpaceState3D, from: Vector3) -> int:
	var at := from
	var top := from.y + 80.0
	var n := 0
	while at.y < top and n < 32:
		var q := PhysicsRayQueryParameters3D.create(at, Vector3(at.x, top, at.z))
		q.hit_back_faces = true
		q.collision_mask = 8      # terrain only, as creative.gd now asks
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		n += 1
		at = (hit["position"] as Vector3) + Vector3(0, 0.02, 0)
	return n


func _crossings_down(space: PhysicsDirectSpaceState3D, from: Vector3) -> int:
	var at := from
	var bottom := from.y - 80.0
	var n := 0
	while at.y > bottom and n < 32:
		var q := PhysicsRayQueryParameters3D.create(at, Vector3(at.x, bottom, at.z))
		q.hit_back_faces = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		n += 1
		at = (hit["position"] as Vector3) - Vector3(0, 0.02, 0)
	return n


func _physics_process(_delta: float) -> void:
	ready_frames += 1
	if ready_frames < 6:
		return
	var space := get_world_3d().direct_space_state
	var bad_up := 0
	var bad_both := 0
	var tested := 0
	print("=== inside the arch tunnel (ball centre heights) ===")
	for iz in 9:
		var z := lerpf(-Wfc.CELL * 0.5, Wfc.CELL * 0.5, float(iz) / 8.0)
		for h in [0.5, 1.0, 1.6]:
			# The bore runs along one axis; walk the middle of it.
			var p := Vector3(0.0, h, z)
			var up := _crossings_up(space, p)
			var dn := _crossings_down(space, p)
			tested += 1
			var up_says := up % 2 == 1
			var dn_says := dn % 2 == 1
			if up_says:
				bad_up += 1
			if up_says and dn_says:
				bad_both += 1
			if up_says:
				print("  z%6.2f y%4.2f   up %d  down %d   <-- UP CALLS THIS BURIED" % [
					z, h, up, dn])
	print("RESULT %d of %d points inside the tunnel read as buried by the up ray" % [
		bad_up, tested])
	print("       %d of %d if BOTH directions have to agree" % [bad_both, tested])
	get_tree().quit()
