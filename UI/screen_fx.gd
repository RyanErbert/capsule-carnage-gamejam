extends Node

## Full-screen shader effects:
## - SCI-FI: cyan grade + scanlines + chromatic fringe + faint grid while
##   you're flying the build drone (god_menu toggles it); red for the
##   rat-attack's hunter vision.
## - DATAMOSH: taking damage tears the picture into macroblocks that grab a
##   motion vector and HOLD it — smearing along it, chroma planes pulling
##   apart, whole scan rows slipping sideways, a few blocks flattening to a
##   lost DC coefficient. It decays back to a clean image over a few seconds.
##
## The mosh is a single screen-space pass. The old version bounced the frame
## between two SubViewports to build real optical flow; it was fragile, hard
## to verify, and most of the time you couldn't tell it had fired. Holding a
## per-block motion vector across many frames reproduces the part of real
## datamoshing you actually SEE, and it either draws or it doesn't.
## Everything sits below the HUD layer so menus stay readable.

const GLITCH_DECAY := 0.75   # a solid hit stays legible for ~4 s
const MIN_VISIBLE := 0.02

var _scifi_rect: ColorRect
var _mosh_rect: ColorRect
var _glitch_amount := 0.0
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


func _ready() -> void:
	add_to_group("screen_fx")
	_scifi_rect = _make_screen_rect(SCIFI_SHADER)
	_mosh_rect = _make_screen_rect(MOSH_SHADER)


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


## Current mosh strength (headless tests read this).
func glitch_amount() -> float:
	return _glitch_amount


func _process(delta: float) -> void:
	if _mosh_rect == null:
		return
	_t += delta
	_glitch_amount *= exp(-GLITCH_DECAY * delta)
	if _glitch_amount < MIN_VISIBLE:
		_glitch_amount = 0.0
	_mosh_rect.visible = _glitch_amount > 0.0
	if not _mosh_rect.visible:
		return
	var mat := _mosh_rect.material as ShaderMaterial
	mat.set_shader_parameter("amount", _glitch_amount)
	mat.set_shader_parameter("t", _t)
