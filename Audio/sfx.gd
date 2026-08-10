extends Node

## World-positioned SFX (web §1.7). Autoload: Sfx.
## Web playWorldSound used a linear rolloff `gain * (1 - dist/50)`; here each
## shot is a one-off AudioStreamPlayer3D with max_distance 50 — close enough.

const JUMPS: Array = [
	preload("res://Audio/jump_1.wav"), preload("res://Audio/jump_2.wav"),
	preload("res://Audio/jump_3.wav"), preload("res://Audio/jump_4.wav"),
]
const BOMBS: Array = [
	preload("res://Audio/bomb_1.wav"), preload("res://Audio/bomb_2.wav"),
	preload("res://Audio/bomb_3.wav"), preload("res://Audio/bomb_4.wav"),
	preload("res://Audio/bomb_5.wav"), preload("res://Audio/bomb_6.wav"),
]
const BOOST := preload("res://Audio/boost.wav")


func play_world(stream: AudioStream, pos: Vector3, gain: float) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = linear_to_db(clampf(gain, 0.01, 4.0))
	p.max_distance = 50.0
	scene.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()


## Random jump grunt @ 0.5 (web playRandomJumpSound)
func jump(pos: Vector3) -> void:
	play_world(JUMPS[randi() % JUMPS.size()], pos, 0.5)


## Random explosion @ 2.0 (web playRandomBombSound)
func bomb(pos: Vector3) -> void:
	play_world(BOMBS[randi() % BOMBS.size()], pos, 2.0)


## boost.wav — the web's all-purpose whoosh (pads 1.0, grapple 0.8,
## coins 0.6, machinegun tracer 0.2 ...)
func boost(pos: Vector3, gain := 1.0) -> void:
	play_world(BOOST, pos, gain)
