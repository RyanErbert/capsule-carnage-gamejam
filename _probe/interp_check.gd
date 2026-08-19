extends Node3D

## Does a remote ghost move smoothly at sprint speed?
##
## Packets land at 20 Hz. Drive the real RemotePlayer with a target running in a
## straight line at sprint speed, step it a frame at a time, and look at the
## SPREAD of its per-frame speed. A ghost that eases to the last packet and
## stalls swings between nearly zero and a lurch; one that carries the speed
## holds it. The mean is the same either way -- it is the swing that reads as
## rubberbanding.

const Remote := preload("res://Net/remote_player.tscn")
const SPRINT := 18.0      # u/s, the map's sprint speed
const FPS := 60.0
const HZ := 20.0


func _ready() -> void:
	var r: Node3D = Remote.instantiate()
	add_child(r)
	var dt := 1.0 / FPS
	var per_packet := int(round(FPS / HZ))
	var t := 0.0
	var speeds: Array = []
	var prev: Vector3 = r.global_position
	for f in 240:
		if f % per_packet == 0:
			r.call("apply_move", {"x": SPRINT * t, "y": 0.0, "z": 0.0,
				"qx": 0.0, "qy": 0.0, "qz": 0.0, "qw": 1.0})
		r.call("_process", dt)
		t += dt
		if f > 60:      # let it settle before measuring
			speeds.append((r.global_position - prev).length() / dt)
		prev = r.global_position
	var lo := INF
	var hi := -INF
	var sum := 0.0
	for v in speeds:
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
		sum += float(v)
	var mean := sum / maxf(float(speeds.size()), 1.0)
	var dev := 0.0
	for v in speeds:
		dev += pow(float(v) - mean, 2.0)
	dev = sqrt(dev / maxf(float(speeds.size()), 1.0))
	print("target %.1f u/s over %d frames" % [SPRINT, speeds.size()])
	print("  ghost speed  mean %5.2f  min %5.2f  max %5.2f" % [mean, lo, hi])
	print("  swing %.2f u/s (%.0f%% of mean), std dev %.2f" % [
		hi - lo, 100.0 * (hi - lo) / maxf(mean, 0.01), dev])
	print("interp: %s" % ("smooth" if (hi - lo) < mean * 0.35 else "STUTTERS"))
	get_tree().quit()
