shader_type spatial;
render_mode unshaded, cull_front;

// Inverted-hull outline for the "it" player (web createOutlineMesh: white
// back-side clone scaled 1.15). Morphs with the same smoothing as the body.
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float smoothing : hint_range(0.0, 1.0) = 0.25;
uniform float outline_scale = 1.15;

void vertex() {
	vec3 sph = normalize(VERTEX) * 0.5;
	VERTEX = mix(VERTEX, sph, smoothing) * outline_scale;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
