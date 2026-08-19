extends Node

## Does the camera keep up, or does it give up and teleport?
##
## The follow is a lag: each frame the rig lerps a fraction of the way to the
## body, so at a steady speed it settles a fixed distance behind. The rig also
## has a teleport detector -- "a jump further than TELEPORT_SNAP is a respawn,
## not travel" -- which snaps the camera onto the body instead of chasing it.
##
## Those two meet badly. The lag grows with speed, and the detector measures
## HOW FAR BEHIND THE CAMERA IS rather than how far the body moved, so above
## some speed ordinary running trips the respawn detector every frame. This
## walks the speed range and reports where that line is.

const Rig := preload("res://Player/camera_rig.gd")
const DT := 1.0 / 60.0
const FRAMES := 600


func _ready() -> void:
	print("TELEPORT_SNAP %.1f m, POS_LERP_RATE %.1f, damping at speed x%.2f" % [
		Rig.TELEPORT_SNAP, Rig.POS_LERP_RATE, 0.6])
	print("")
	print("  speed   settled lag   snaps in %d frames" % FRAMES)
	var first_bad := -1.0
	for speed: float in [6.0, 9.0, 11.7, 15.0, 18.0, 21.0, 25.0, 34.0, 45.0, 56.9]:
		var r := _run(speed)
		var lag: float = r[0]
		var snaps: int = r[1]
		print("  %5.1f   %8.2f m   %s" % [speed, lag,
			"-" if snaps == 0 else "%d  <-- every frame" % snaps if snaps > FRAMES - 5 else str(snaps)])
		if snaps > 0 and first_bad < 0.0:
			first_bad = speed
	print("")
	if first_bad > 0.0:
		print("teleport detector first fires at %.1f m/s of ORDINARY RUNNING" % first_bad)
	else:
		print("teleport detector never fires on ordinary running")
	# Sprint really does reach these speeds: the monkey-ball cap is
	# MAX_SPEED * speedScale * (1 + BOOST_MULT * boostScale).
	print("walk is %.1f m/s and sprint tops out at %.1f m/s with stock sliders" % [
		9.0 * 1.3, 9.0 * 1.3 * (1.0 + 2.0 * 1.93)])
	# ...and the thing the detector is actually FOR must still be caught.
	var prev := Vector3.ZERO
	var far := Vector3(120, 0, 0)
	print("a real respawn (120 m in one frame) still snaps: %s" % [
		"yes" if prev.distance_to(far) > Rig.TELEPORT_SNAP else "NO"])
	print("lag is capped at %.1f m, so the body never leaves the frame" % Rig.MAX_LAG)
	get_tree().quit()


## March a body at constant speed and run the rig's own follow law behind it.
func _run(speed: float) -> Array:
	var body := Vector3.ZERO
	var cam := Vector3.ZERO
	var smooth := speed          # already up to speed
	var prev := Vector3.INF
	var snaps := 0
	for i in FRAMES:
		body.x += speed * DT
		var speed_factor := minf(1.0, smooth / 18.0)
		var t := (1.0 - exp(-Rig.POS_LERP_RATE * DT)) * (1.0 - speed_factor * 0.4)
		# The rig's own law: the jump test is on the BODY's step, and the lag is
		# clamped rather than cut.
		if prev != Vector3.INF and prev.distance_to(body) > Rig.TELEPORT_SNAP:
			cam = body
			snaps += 1
		else:
			cam = Rig._lag_follow(cam, body, t)
		prev = body
	return [body.distance_to(cam), snaps]
