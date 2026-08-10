extends Node

## Full-screen shader effects:
## - SCI-FI: cyan grade + scanlines + chromatic fringe + faint grid while
##   you're flying the god-mode drone (god_menu toggles it).
## - DATAMOSH: a REAL mosh — a feedback buffer holds the previous frame and
##   re-warps it every frame along per-block motion vectors (stale P-frames),
##   while only a few macroblocks refresh from the live image. The picture
##   genuinely melts and smears while you're taking damage, then heals.
## Everything sits below the HUD layer so menus stay readable.

const GLITCH_DECAY := 1.9

var _scifi_rect: ColorRect
var _mosh_vp: SubViewport
var _copy_vp: SubViewport       # 1-frame-delayed copy of the live screen
var _mosh_feedback: ColorRect   # inside the buffer: advects prev frame
var _mosh_display: ColorRect    # on screen: shows the buffer while moshing
var _glitch_amount := 0.0
var _t := 0.0

const SCIFI_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
void fragment() {
	vec2 uv = SCREEN_UV;
	float ab = 0.0016;
	vec3 col;
	col.r = texture(screen_tex, uv + vec2(ab, 0.0)).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - vec2(ab, 0.0)).b;
	col = mix(col, col * vec3(0.72, 1.05, 1.28), 0.55);
	col *= 0.93 + 0.07 * sin(uv.y * 800.0 + TIME * 8.0);
	vec2 g = fract(uv * vec2(48.0, 27.0));
	col *= 1.0 - 0.05 * step(0.95, max(g.x, g.y));
	float vig = 1.0 - 0.35 * pow(length(uv - 0.5) * 1.35, 2.0);
	col *= vig;
	COLOR = vec4(col, 1.0);
}
"

## Passthrough that copies the live screen into a viewport — sampling that
## viewport's texture next frame gives us the PREVIOUS live frame, which the
## mosh shader needs to estimate optical flow.
const COPY_SHADER := "
shader_type canvas_item;
uniform sampler2D live_tex : filter_linear;
void fragment() { COLOR = vec4(texture(live_tex, UV).rgb, 1.0); }
"

## The actual mosh, the way real datamoshing works: per-macroblock OPTICAL
## FLOW is estimated between the current and previous live frames
## (gradient/Lucas-Kanade step), and the feedback buffer — the held
## \"P-frames\" — is advected along that flow instead of refreshing. Only a
## few random macroblocks receive fresh \"I-frame\" data each frame, so the
## picture melts and smears along real motion until the effect decays.
const MOSH_FEEDBACK_SHADER := "
shader_type canvas_item;
uniform sampler2D live_tex : filter_linear;
uniform sampler2D prev_live_tex : filter_linear;
uniform sampler2D prev_tex : filter_linear;
uniform float amount = 0.0;
uniform float t = 0.0;
float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
float rnd(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = UV;
	vec2 bsize = vec2(64.0, 36.0);
	vec2 block = floor(uv * bsize);
	vec2 buv = (block + 0.5) / bsize;
	// One-step gradient optical flow at the macroblock center
	float e = 0.004;
	float gx = lum(texture(live_tex, buv + vec2(e, 0.0)).rgb) - lum(texture(live_tex, buv - vec2(e, 0.0)).rgb);
	float gy = lum(texture(live_tex, buv + vec2(0.0, e)).rgb) - lum(texture(live_tex, buv - vec2(0.0, e)).rgb);
	float gt = lum(texture(live_tex, buv).rgb) - lum(texture(prev_live_tex, buv).rgb);
	vec2 flow = -gt * vec2(gx, gy) / (gx * gx + gy * gy + 1e-4);
	flow = clamp(flow, vec2(-0.03), vec2(0.03));
	// P-frame step: carry the held image along the estimated motion
	vec3 held = texture(prev_tex, uv - flow).rgb;
	vec3 cur = texture(live_tex, uv).rgb;
	// Sparse I-frame refresh: a few blocks re-key each frame
	float refresh = step(rnd(block + floor(t * 20.0)), mix(1.0, 0.03, amount));
	COLOR = vec4(mix(held, cur, max(refresh, 1.0 - amount)), 1.0);
}
"

## On the main screen: fade the mosh buffer in over the live image. The
## luminance guard falls back to the live frame if the buffer is dead.
const MOSH_DISPLAY_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D mosh_tex : filter_linear;
uniform float amount = 0.0;
void fragment() {
	vec3 live = texture(screen_tex, SCREEN_UV).rgb;
	vec3 mosh = texture(mosh_tex, SCREEN_UV).rgb;
	float ok = step(0.005, dot(mosh, vec3(1.0)));
	COLOR = vec4(mix(live, mosh, clamp(amount * 1.6, 0.0, 1.0) * ok), 1.0);
}
"


func _ready() -> void:
	add_to_group("screen_fx")
	_scifi_rect = _make_screen_rect(SCIFI_SHADER)
	_build_mosh.call_deferred()


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


func _build_mosh() -> void:
	var vp_size: Vector2i = get_viewport().size

	# Live-frame history buffer (its texture lags the screen by one frame)
	_copy_vp = SubViewport.new()
	_copy_vp.size = vp_size
	_copy_vp.disable_3d = true
	_copy_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_copy_vp)
	var copy_rect := ColorRect.new()
	copy_rect.size = vp_size
	var copy_shader := Shader.new()
	copy_shader.code = COPY_SHADER
	var copy_mat := ShaderMaterial.new()
	copy_mat.shader = copy_shader
	copy_mat.set_shader_parameter("live_tex", get_viewport().get_texture())
	copy_rect.material = copy_mat
	_copy_vp.add_child(copy_rect)

	# The mosh buffer itself (feedback: reads its own last frame)
	_mosh_vp = SubViewport.new()
	_mosh_vp.size = vp_size
	_mosh_vp.disable_3d = true
	_mosh_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_mosh_vp)
	_mosh_feedback = ColorRect.new()
	_mosh_feedback.size = vp_size
	var fb_shader := Shader.new()
	fb_shader.code = MOSH_FEEDBACK_SHADER
	var fb_mat := ShaderMaterial.new()
	fb_mat.shader = fb_shader
	fb_mat.set_shader_parameter("live_tex", get_viewport().get_texture())
	fb_mat.set_shader_parameter("prev_live_tex", _copy_vp.get_texture())
	fb_mat.set_shader_parameter("prev_tex", _mosh_vp.get_texture())  # feedback
	_mosh_feedback.material = fb_mat
	_mosh_vp.add_child(_mosh_feedback)

	_mosh_display = _make_screen_rect(MOSH_DISPLAY_SHADER)
	(_mosh_display.material as ShaderMaterial).set_shader_parameter("mosh_tex", _mosh_vp.get_texture())


func set_scifi(on: bool) -> void:
	if _scifi_rect:
		_scifi_rect.visible = on


## Damage hit: kick the mosh up (0..1) — it decays back to a clean image.
func pulse(strength: float) -> void:
	_glitch_amount = clampf(maxf(_glitch_amount, strength), 0.0, 1.0)


func _process(delta: float) -> void:
	if _mosh_display == null:
		return
	_t += delta
	_glitch_amount *= exp(-GLITCH_DECAY * delta)
	var active := _glitch_amount > 0.03
	_mosh_display.visible = active
	var mode := SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	_mosh_vp.render_target_update_mode = mode
	_copy_vp.render_target_update_mode = mode
	if active:
		var fb := _mosh_feedback.material as ShaderMaterial
		fb.set_shader_parameter("amount", _glitch_amount)
		fb.set_shader_parameter("t", _t)
		(_mosh_display.material as ShaderMaterial).set_shader_parameter("amount", _glitch_amount)
		# Track window size so the buffer never stretches
		if _mosh_vp.size != Vector2i(get_viewport().size):
			_mosh_vp.size = get_viewport().size
			_mosh_feedback.size = _mosh_vp.size
			_copy_vp.size = _mosh_vp.size
