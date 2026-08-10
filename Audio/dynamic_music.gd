extends Node

## Dynamic 8-bit soundtrack. Four chiptune stems (generated square/triangle/
## noise loops, same 2 bars at 112 BPM) run in lockstep inside an
## AudioStreamSynchronized; intensity fades layers in and out:
##   arp (always) -> bass -> percussion -> tension stabs
## Intensity rises as another player gets close and spikes when you take
## damage (game_hud calls damage_pulse on health drops).

# Ryan: current stems are placeholder-bad; system stays, disabled until the
# real loops are authored. Flip to true once Audio/music_*.wav are replaced.
const ENABLED := false

const STEMS := ["arp", "bass", "perc", "tension"]
const THRESH := [0.0, 0.22, 0.48, 0.72]
const PROX_RANGE := 45.0
const BASE_INTENSITY := 0.18
const FADE_RATE := 2.5
const MASTER_DB := -9.0

var sync_node: Node

var _stream: AudioStreamSynchronized
var _out: AudioStreamPlayer
var _damage := 0.0
var _vols := [1.0, 0.0, 0.0, 0.0]


func _ready() -> void:
	add_to_group("dynamic_music")
	if not ENABLED:
		set_process(false)
		return
	_stream = AudioStreamSynchronized.new()
	_stream.stream_count = STEMS.size()
	for i in STEMS.size():
		var wav: AudioStreamWAV = load("res://Audio/music_%s.wav" % STEMS[i]).duplicate()
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2  # 16-bit mono: frames = bytes / 2
		_stream.set_sync_stream(i, wav)
		_stream.set_sync_stream_volume(i, -60.0)
	_out = AudioStreamPlayer.new()
	_out.stream = _stream
	_out.volume_db = MASTER_DB
	add_child(_out)
	_out.play()


func damage_pulse() -> void:
	if not ENABLED:
		return
	_damage = 1.0


func _process(delta: float) -> void:
	_damage = maxf(0.0, _damage - delta * 0.25)  # ~4 s combat afterglow
	var prox := 0.0
	if sync_node and sync_node.player:
		var nearest := 1e9
		var remotes: Dictionary = sync_node.remotes()
		for id in remotes:
			nearest = minf(nearest, remotes[id].global_position.distance_to(sync_node.player.global_position))
		if nearest < PROX_RANGE:
			prox = 1.0 - nearest / PROX_RANGE
	var intensity := clampf(BASE_INTENSITY + prox * 0.55 + _damage * 0.45, 0.0, 1.0)
	for i in STEMS.size():
		var target := 1.0 if (i == 0 or intensity >= THRESH[i]) else 0.0
		_vols[i] = lerpf(_vols[i], target, minf(1.0, FADE_RATE * delta))
		_stream.set_sync_stream_volume(i, linear_to_db(maxf(_vols[i], 0.001)))
