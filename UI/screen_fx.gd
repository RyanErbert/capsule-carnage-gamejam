extends Node

## Full-screen shader effects:
## - SCI-FI: cyan grade + scanlines + chromatic fringe + faint grid while
##   you're flying the build drone (god_menu toggles it); red for the
##   rat-attack's hunter vision.
## - DATAMOSH: taking damage tears the picture into macroblocks that grab a
##   motion vector and HOLD it — smearing along it, chroma planes pulling
##   apart, whole scan rows slipping sideways, a few blocks flattening to a
##   lost DC coefficient. It decays back to a clean image over a few seconds.
## - SORT: dying drags the bright pixels down their columns, so the picture
##   comes apart into vertical runs and stays apart while the death camera
##   watches, then knits back together as the respawn countdown ends. It draws
##   on top of the mosh and reads the moshed frame, so a death is both.
##
## The mosh is a single screen-space pass. The old version bounced the frame
## between two SubViewports to build real optical flow; it was fragile, hard
## to verify, and most of the time you couldn't tell it had fired. Holding a
## per-block motion vector across many frames reproduces the part of real
## datamoshing you actually SEE, and it either draws or it doesn't.
## Everything sits below the HUD layer so menus stay readable.

const GLITCH_DECAY := 0.75   # a solid hit stays legible for ~4 s
const MIN_VISIBLE := 0.02
## How much of the countdown the sort holds at full before it starts knitting
## back. You come back to a clean picture, not a corrupted one.
const DEATH_HOLD := 0.45
const DEATH_MOSH := 0.6      # mosh carried along under the sort while dead

var _scifi_rect: ColorRect
var _mosh_rect: ColorRect
var _sort_rect: ColorRect
var _glitch_amount := 0.0
var _sort_amount := 0.0
var _death_left := 0.0
var _death_span := 0.0
var _t := 0.0

const SCIFI_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform vec3 grade = vec3(0.72, 1.05, 1.28);
void fragment() {
	vec2 uv = SCREEN_UV;
	float ab = 0.0016;
	vec3 col;
	col.r = texture(screen_tex, uv + vec2(ab, 0.0)).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - vec2(ab, 0.0)).b;
	col = mix(col, col * grade, 0.55);
	col *= 0.93 + 0.07 * sin(uv.y * 800.0 + TIME * 8.0);
	vec2 g = fract(uv * vec2(48.0, 27.0));
	col *= 1.0 - 0.05 * step(0.95, max(g.x, g.y));
	float vig = 1.0 - 0.35 * pow(length(uv - 0.5) * 1.35, 2.0);
	col *= vig;
	COLOR = vec4(col, 1.0);
}
"

## The mosh. `amount` (0..1) drives how much of the frame is corrupted, how
## far it smears, and how violently rows slip.
const MOSH_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount = 0.0;
uniform float t = 0.0;
const vec2 GRID = vec2(44.0, 26.0);
float rnd(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
vec2 safe(vec2 uv) { return clamp(uv, vec2(0.002), vec2(0.998)); }
void fragment() {
	float a = clamp(amount, 0.0, 1.0);
	vec2 uv = SCREEN_UV;
	vec2 block = floor(uv * GRID);

	// Each macroblock re-keys on its own stagger and HOLDS its motion vector
	// in between — that hold is what drags the image instead of shimmering it.
	float key = floor(t * 2.5 + rnd(block) * 3.0);
	vec2 mv = (vec2(rnd(block + key), rnd(block + key + 31.7)) - 0.5) * 2.0;
	// Most blocks go bad at high amount; a few always survive, so the frame
	// stays readable enough to keep playing through it.
	float sick = step(1.0 - a, rnd(block * 1.31 + floor(key * 0.5)) * 0.85 + 0.15);
	vec2 off = mv * 0.12 * a * sick;

	// Smear: taps trailing back along the motion vector
	vec3 col = vec3(0.0);
	for (int i = 0; i < 5; i++)
		col += texture(screen_tex, safe(uv + off * float(i) * 0.28)).rgb;
	col *= 0.2;

	// Chroma planes pull apart inside a corrupted block
	float cs = 0.018 * a * sick;
	col.r = texture(screen_tex, safe(uv + off + vec2(cs, 0.0))).r;
	col.b = texture(screen_tex, safe(uv + off - vec2(cs, 0.0))).b;

	// Whole scan rows slip sideways for a frame or two
	float row = floor(uv.y * 120.0);
	float tick = floor(t * 12.0);
	if (step(0.97 - a * 0.14, rnd(vec2(row, tick))) > 0.5) {
		float d = (rnd(vec2(row + 5.0, tick)) - 0.5) * 0.3 * a;
		col = texture(screen_tex, safe(uv + vec2(d, 0.0))).rgb;
	}

	// Lost DC coefficient: the odd block flattens to one washed-out color
	float flat_block = step(0.995 - a * 0.045, rnd(block + floor(t * 4.0)));
	col = mix(col, texture(screen_tex, (block + 0.5) / GRID).rgb * 1.3, flat_block);

	COLOR = vec4(col, 1.0);
}
"


## Pseudo pixel sort. A real sort orders a whole run of pixels, which is many
## passes; this takes the EXTREME of a run in one, which makes the same bright
## vertical streaks -- the part of the effect you actually see. `amount` (0..1)
## drives how many columns tear, how far they drag, and how far the colour
## drains out of them.
const SORT_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float amount = 0.0;
uniform float t = 0.0;
const int TAPS = 22;
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float rnd(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	float a = clamp(amount, 0.0, 1.0);
	vec2 uv = SCREEN_UV;
	vec3 col = texture(screen_tex, uv).rgb;

	// One key per column, held for a beat, so the frame tears into ragged
	// vertical bands instead of shimmering all over at once. A few columns
	// always survive, so the picture stays a picture.
	float cx = floor(uv.x / max(SCREEN_PIXEL_SIZE.x * 2.0, 0.0005));
	float key = rnd(vec2(cx, floor(t * 2.0)));
	float active = step(1.0 - a * 0.92, key * 0.85 + 0.06);
	float reach = (8.0 + key * 84.0) * a;

	// Drag the brightest pixel in the RUN back down its own column. A run ends
	// where the picture does: walk until the luminance leaves the band it
	// started in, and stop. Without that the sky, being the brightest thing on
	// screen, gets dragged down through every wall below it and the frame
	// dissolves instead of melting.
	float seed = luma(col);
	float tol = 0.09 + 0.20 * key;
	vec3 best = col;
	float bl = seed;
	for (int i = 1; i <= TAPS; i++) {
		vec2 s = uv - vec2(0.0, reach * (float(i) / float(TAPS)) * SCREEN_PIXEL_SIZE.y);
		vec3 c = texture(screen_tex, clamp(s, vec2(0.001), vec2(0.999))).rgb;
		float l = luma(c);
		if (abs(l - seed) > tol) break;
		if (l > bl) { bl = l; best = c; }
	}
	col = mix(col, best, a * active);
	col = mix(col, vec3(luma(col)), a * 0.45 * active);
	COLOR = vec4(col, 1.0);
}
"


func _ready() -> void:
	add_to_group("screen_fx")
	_scifi_rect = _make_screen_rect(SCIFI_SHADER)
	_mosh_rect = _make_screen_rect(MOSH_SHADER)
	# Last, so it draws last and reads the already-moshed frame.
	_sort_rect = _make_screen_rect(SORT_SHADER)


func _make_screen_rect(code: String) -> ColorRect:
	var layer := CanvasLayer.new()
	layer.layer = 0  # below the HUD (layer 1)
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	rect.material = mat
	rect.visible = false
	layer.add_child(rect)
	return rect


## `grade` tints the whole overlay: default cyan (build drone / crow-bot),
## red for the rat-attack's hunter vision.
func set_scifi(on: bool, grade := Vector3(0.72, 1.05, 1.28)) -> void:
	if _scifi_rect:
		_scifi_rect.visible = on
		(_scifi_rect.material as ShaderMaterial).set_shader_parameter("grade", grade)


## Damage hit: kick the mosh up (0..1) — it decays back to a clean image.
func pulse(strength: float) -> void:
	_glitch_amount = clampf(maxf(_glitch_amount, strength), 0.0, 1.0)


## Death: the picture comes apart and stays apart for the countdown, then puts
## itself back together in time for the respawn.
func death(secs: float) -> void:
	_death_span = maxf(secs, 0.5)
	_death_left = _death_span
	pulse(1.0)


## Respawned early, or the round ended under you: drop it now.
func clear_death() -> void:
	_death_left = 0.0


## Current mosh strength (headless tests read this).
func glitch_amount() -> float:
	return _glitch_amount


## Current sort strength (headless tests read this).
func sort_amount() -> float:
	return _sort_amount


func _process(delta: float) -> void:
	if _mosh_rect == null:
		return
	_t += delta
	_glitch_amount *= exp(-GLITCH_DECAY * delta)
	_tick_death(delta)
	if _glitch_amount < MIN_VISIBLE:
		_glitch_amount = 0.0
	_drive(_mosh_rect, _glitch_amount)
	_drive(_sort_rect, _sort_amount)


## The sort slams on at full and holds while the death camera does its work,
## then eases out over the rest of the countdown. The mosh is held up under it
## the whole time, so a death is not just a tidier version of a flesh wound.
func _tick_death(delta: float) -> void:
	if _death_left <= 0.0:
		_sort_amount = maxf(_sort_amount - delta * 2.0, 0.0)
		if _sort_amount < MIN_VISIBLE:
			_sort_amount = 0.0
		return
	_death_left = maxf(_death_left - delta, 0.0)
	var gone := 1.0 - _death_left / _death_span
	_sort_amount = 1.0 - smoothstep(DEATH_HOLD, 1.0, gone)
	_glitch_amount = maxf(_glitch_amount, _sort_amount * DEATH_MOSH)


func _drive(rect: ColorRect, amount: float) -> void:
	if rect == null:
		return
	rect.visible = amount > 0.0
	if not rect.visible:
		return
	var mat := rect.material as ShaderMaterial
	mat.set_shader_parameter("amount", amount)
	mat.set_shader_parameter("t", _t)
