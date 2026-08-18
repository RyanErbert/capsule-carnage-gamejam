extends Node

## The death timeline, without a renderer: the sort has to slam on, hold while
## the death camera is out there, and be gone by the time you respawn -- coming
## back to a corrupted picture would be worse than never tearing it.

const SPAN := 4.0

var _fx: Node
var _fails := 0
var _t := 0.0
var _at_hold := -1.0
var _peak_mosh := 0.0
var _done := false


func _ready() -> void:
	_fx = Node.new()
	_fx.set_script(load("res://UI/screen_fx.gd"))
	add_child(_fx)
	await get_tree().process_frame
	_check(float(_fx.call("sort_amount")) == 0.0, "quiet before anything happens")
	_fx.call("death", SPAN)
	_check(float(_fx.call("glitch_amount")) > 0.9, "death kicks the mosh too")


func _process(delta: float) -> void:
	if _done or _fx == null:
		return
	_t += delta
	var sort := float(_fx.call("sort_amount"))
	_peak_mosh = maxf(_peak_mosh, float(_fx.call("glitch_amount")))
	# Sampled at the end of the hold: still full, because the camera is still out
	# there looking at whoever did it.
	if _at_hold < 0.0 and _t >= SPAN * 0.4:
		_at_hold = sort
	if _t < SPAN:
		return
	_done = true
	_check(_at_hold > 0.95, "holds through the death camera: %.2f at 40%% in" % _at_hold)
	_check(sort < 0.05, "gone by the respawn: %.3f" % sort)
	_check(_peak_mosh > 0.5, "the mosh rode along under it: peak %.2f" % _peak_mosh)

	# An early respawn drops it rather than leaving the screen torn.
	_fx.call("death", SPAN)
	await get_tree().process_frame
	_check(float(_fx.call("sort_amount")) > 0.9, "re-armed")
	_fx.call("clear_death")
	# By elapsed time, not by frame count: headless runs the loop as fast as it
	# likes and forty frames there is a fraction of a second.
	var waited := 0.0
	while waited < 1.5:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check(float(_fx.call("sort_amount")) == 0.0,
		"clear_death lets go inside a second: %.3f" % float(_fx.call("sort_amount")))
	print("death fx: %s" % ("all checks passed" if _fails == 0 else "%d FAILED" % _fails))
	get_tree().quit()


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
