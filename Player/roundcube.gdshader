shader_type spatial;
render_mode blend_mix, depth_draw_always;

// Web "roundcube" player (game.js smoothRoundcube): each vertex of a unit box
// is lerped toward the r=0.5 sphere by `smoothing` (0.25 idle -> 1.0 sprint ball).
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 0.3);
uniform float smoothing : hint_range(0.0, 1.0) = 0.25;

void vertex() {
	vec3 sph = normalize(VERTEX) * 0.5;
	VERTEX = mix(VERTEX, sph, smoothing);
	NORMAL = normalize(mix(NORMAL, normalize(VERTEX), smoothing));
}

void fragment() {
	// Web material: MeshPhysical opacity 0.3, metalness 0.8, roughness 0.05, clearcoat 1
	ALBEDO = albedo.rgb;
	ALPHA = albedo.a;
	METALLIC = 0.8;
	ROUGHNESS = 0.05;
	CLEARCOAT = 1.0;
	CLEARCOAT_ROUGHNESS = 0.05;
}
