extends Node

## Full-screen shader effects:
## - SCI-FI: cyan grade + scanlines + chromatic fringe + faint grid while
##   you're flying the god-mode drone (god_menu toggles it).
## - DATAMOSH: a REAL mosh — a feedback buffer holds the previous frame and
##   re-warps it every frame along per-block motion vectors (stale P-frames),
##   while only a few macroblocks refresh from the live image. The picture
##   genuinely melts and smears while you're taking damage, then heals.
## Everything sits below the HUD layer so menus stay readable.

const GLITCH_DECAY := 0.85   # slow decay: a big hit melts for ~4 s
const DEAD_HP := 0.35        # below this health fraction, dead pixels set in

var _scifi_rect: ColorRect
# Ping-pong feedback pair: reading the render target you're writing is
# undefined, so each frame ONE viewport renders while sampling the OTHER.
var _mosh_a: SubViewport
var _mosh_b: SubViewport
var _copy_vp: SubViewport       # 1-frame-delayed copy of the live screen
var _mosh_display: ColorRect    # on screen: shows the buffer while moshing
var _flip := false
var _was_active := false
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
	vec2 bsize = vec2(48.0, 27.0);
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
	// Sparse I-frame refresh: barely any blocks re-key while the mosh is hot,
	// so held frames drag long smears before the image heals
	float refresh = step(rnd(block + floor(t * 20.0)), mix(1.0, 0.012, amount));
	COLOR = vec4(mix(held, cur, max(refresh, 1.0 - amount)), 1.0);
}
"

## On the main screen: fade the mosh buffer in over the live image. The
## luminance guard falls back to the live frame if the buffer is dead.
## `dead` (0..1) permanently kills a scattering of macroblocks — stuck sensor
## pixels that stay on screen while your health is critical.
const MOSH_DISPLAY_SHADER := "
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D mosh_tex : filter_linear;
uniform float amount = 0.0;
uniform float dead = 0.0;
float rnd(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec3 live = texture(screen_tex, SCREEN_UV).rgb;
	vec3 mosh = texture(mosh_tex, SCREEN_UV).rgb;
	float ok = step(0.005, dot(mosh, vec3(1.0)));
	vec3 col = mix(live, mosh, clamp(amount * 2.2, 0.0, 1.0) * ok);
	// Dead pixels: a static mask of stuck blocks, flat corrupted color
	vec2 block = floor(SCREEN_UV * vec2(96.0, 54.0));
	float dp = step(1.0 - dead, rnd(block * 1.37));
	vec3 stuck = vec3(rnd(block), rnd(block + 4.2), rnd(block + 9.1));
	stuck = mix(vec3(0.02), stuck * vec3(0.5, 0.9, 0.4), step(0.6, stuck.g)) * 0.4;
	COLOR = vec4(mix(col, stuck, dp), 1.0);
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

	# The ping-pong pair FIRST in tree order: sibling viewports render in
	# attach order, so when a mosh pass samples the copy buffer below it,
	# that buffer still holds the PREVIOUS frame — real optical flow.
	_mosh_a = _make_mosh_vp(vp_size)
	_mosh_b = _make_mosh_vp(vp_size)
	_fb_mat(_mosh_a).set_shader_parameter("prev_tex", _mosh_b.get_texture())
	_fb_mat(_mosh_b).set_shader_parameter("prev_tex", _mosh_a.get_texture())

	# Live-frame history buffer (its texture lags the screen by one frame)
	_copy_vp = SubViewport.new()
	_copy_vp.size = vp_size
	_copy_vp.disable_3d = true
	_copy_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
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
	_fb_mat(_mosh_a).set_shader_parameter("prev_live_tex", _copy_vp.get_texture())
	_fb_mat(_mosh_b).set_shader_parameter("prev_live_tex", _copy_vp.get_texture())

	_mosh_display = _make_screen_rect(MOSH_DISPLAY_SHADER)
	(_mosh_display.material as ShaderMaterial).set_shader_parameter("mosh_tex", _mosh_a.get_texture())


func _make_mosh_vp(vp_size: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = vp_size
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var rect := ColorRect.new()
	rect.size = vp_size
	var shader := Shader.new()
	shader.code = MOSH_FEEDBACK_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("live_tex", get_viewport().get_texture())
	rect.material = mat
	vp.add_child(rect)
	return vp


func _fb_mat(vp: SubViewport) -> ShaderMaterial:
	return (vp.get_child(0) as ColorRect).material as ShaderMaterial


## `grade` tints the whole overlay: default cyan (drone/crow-bot), red for
## the rat-attack's hunter vision.
func set_scifi(on: bool, grade := Vector3(0.72, 1.05, 1.28)) -> void:
	if _scifi_rect:
		_scifi_rect.visible = on
		(_scifi_rect.material as ShaderMaterial).set_shader_parameter("grade", grade)


## Damage hit: kick the mosh up (0..1) — it decays back to a clean image.
func pulse(strength: float) -> void:
	_glitch_amount = clampf(maxf(_glitch_amount, strength), 0.0, 1.0)


## Health fraction (0..1). Critical health burns dead pixels into the screen;
## they stay until you heal back over the threshold.
var _health := 1.0

func set_health(frac: float) -> void:
	_health = clampf(frac, 0.0, 1.0)


func _dead_amount() -> float:
	return clampf((DEAD_HP - _health) / DEAD_HP, 0.0, 1.0) * 0.12


func _process(delta: float) -> void:
	if _mosh_display == null:
		return
	_t += delta
	_glitch_amount *= exp(-GLITCH_DECAY * delta)
	var dead := _dead_amount()
	var active := _glitch_amount > 0.03
	_mosh_display.visible = active or dead > 0.001
	(_mosh_display.material as ShaderMaterial).set_shader_parameter("dead", dead)
	if not active:
		_was_active = false
		_mosh_a.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_mosh_b.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_copy_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if _mosh_display.visible:
			# Dead pixels only: keep the melt off the live image
			(_mosh_display.material as ShaderMaterial).set_shader_parameter("amount", 0.0)
		return
	# Track window size so the buffers never stretch
	if _mosh_a.size != Vector2i(get_viewport().size):
		for vp: SubViewport in [_mosh_a, _mosh_b, _copy_vp]:
			vp.size = get_viewport().size
			(vp.get_child(0) as ColorRect).size = vp.size
	# Ping-pong: this frame's writer advects the other buffer's last frame
	_flip = not _flip
	var writer := _mosh_a if _flip else _mosh_b
	var reader := _mosh_b if _flip else _mosh_a
	writer.render_target_update_mode = SubViewport.UPDATE_ONCE
	reader.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_copy_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var fb := _fb_mat(writer)
	# Rising edge: seed the buffer with a clean copy of the screen (amount 0
	# forces a full I-frame refresh), THEN let it melt on following frames
	fb.set_shader_parameter("amount", _glitch_amount if _was_active else 0.0)
	fb.set_shader_parameter("t", _t)
	_was_active = true
	var disp := _mosh_display.material as ShaderMaterial
	disp.set_shader_parameter("amount", _glitch_amount)
	disp.set_shader_parameter("mosh_tex", writer.get_texture())
