extends RefCounted

## Type name to model script, and the one place anything asks a model a
## question. Adding a structure is a file in models/ and a line here; the
## network payload, the save file, the god-menu readout and the handles all come
## off the spec that file declares.

const Spec := preload("res://Items/parametric/spec.gd")

const MODELS := {
	"wall": preload("res://Items/parametric/models/wall.gd"),
	"tower": preload("res://Items/parametric/models/tower.gd"),
	"bridge": preload("res://Items/parametric/models/bridge.gd"),
	"path": preload("res://Items/parametric/models/path.gd"),
}


static func types() -> Array:
	return MODELS.keys()


static func has(type: String) -> bool:
	return MODELS.has(type)


static func spec(type: String) -> Array:
	return MODELS[type].spec() if MODELS.has(type) else []


static func min_nodes(type: String) -> int:
	return MODELS[type].min_nodes() if MODELS.has(type) else 2


static func defaults(type: String) -> Dictionary:
	return Spec.defaults(spec(type))


## Build from a record: {type, nodes, params}. Returns a StaticBody3D the caller
## parents and owns, or null for a type nobody knows.
static func build(rec: Dictionary, mat: Material, collide := true) -> Node3D:
	var type := str(rec.get("type", ""))
	if not MODELS.has(type):
		return null
	var nodes := to_points(rec.get("nodes", []))
	if nodes.size() < min_nodes(type):
		return null
	var params := Spec.sanitize(spec(type), rec.get("params", {}))
	return MODELS[type].build(nodes, params, mat, collide, to_points(rec.get("holes", [])))


static func handles(rec: Dictionary) -> Array:
	var type := str(rec.get("type", ""))
	if not MODELS.has(type):
		return []
	var nodes := to_points(rec.get("nodes", []))
	if nodes.size() < min_nodes(type):
		return []
	var raw: Array = MODELS[type].handles(nodes, Spec.sanitize(spec(type), rec.get("params", {})))
	var out: Array = []
	for h in raw:
		if not (h as Dictionary).is_empty():
			out.append(h)
	return out


## Records arrive off the wire as arrays of {x,y,z} dictionaries and are held
## in-engine as Vector3. One conversion, in one place.
static func to_points(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for n in raw:
			if n is Vector3:
				out.append(n)
			elif n is Dictionary:
				out.append(Vector3(n.get("x", 0.0), n.get("y", 0.0), n.get("z", 0.0)))
	return out


## Structure stone, and the join where it meets the ground.
##
## Every sweep bakes how far above its own ground line each vertex sits into
## COLOR.r (Ops.sweep). That is all this needs: near the line it fades to the
## TERRAIN's own sand and rock, using the same textures the ground does, so the
## join reads as earth piled against a wall rather than a brown gradient painted
## on one. The line wanders with world-space noise, because a straight band at a
## fixed height is the one thing that would give it away.
##
## The alternative was doing it in the terrain instead -- deforming the field up
## to meet each structure -- which is real geometry, costs a remesh on every
## handle drag, and fights the 8 m skirt that already closes the actual gap.
##
## KNOWN LIMIT: the band is measured from the RAIL, not from the ground. The
## rail runs straight between clicked nodes while the ground curves under it, so
## on a long span over a dip the join floats above the earth it is meant to meet.
## Nodes a few metres apart hide it; the fix, if it ever matters, is to hand the
## sweep a ground probe the way bridge piers already get one.
const STRUCTURE_SHADER := "
shader_type spatial;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec3 stone_tint = vec3(0.78, 0.76, 0.72);
uniform float blend_on = 1.0;
varying vec3 wpos;
varying vec3 wnrm;
varying float vground;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vground = COLOR.r;
}
vec3 triplanar(sampler2D tex, vec3 p, vec3 w, float s) {
	return texture(tex, p.zy * s).rgb * w.x
	     + texture(tex, p.xz * s).rgb * w.y
	     + texture(tex, p.xy * s).rgb * w.z;
}
void fragment() {
	// Swept normals are exact, so the projection weights come straight off them
	// -- no need for the screen-space derivative trick the terrain needs.
	vec3 w = pow(abs(wnrm), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 stone = triplanar(rock_tex, wpos, w, 0.22) * stone_tint;
	// The ground's own mix, at the ground's own scales.
	vec3 sand = triplanar(sand_tex, wpos, w, 0.09) * vec3(1.12, 0.98, 0.82);
	vec3 rock = triplanar(rock_tex, wpos, w, 0.06) * vec3(1.05, 0.95, 0.88);
	vec3 ground = mix(sand, rock, 0.42);
	// Two planes of noise, not one. Sampled on xz alone every point in a
	// vertical column reads the same value, and the join comes out as stripes
	// running UP the wall instead of a ragged line across it.
	float n = texture(noise_tex, wpos.xz * 0.42).r * 0.55
	        + texture(noise_tex, (wpos.xy + wpos.zy) * 0.23).r * 0.45;
	// The noise wanders the ENDS of the band, and the top end stays below 1.
	// Jittering the value instead leaves a permanent offset once vground has
	// clamped, so the columns that drew a low number never resolve to stone and
	// the join runs up the whole wall as a stain.
	float lo = 0.02 + n * 0.20;
	float hi = 0.50 + n * 0.30;
	float k = mix(1.0, smoothstep(lo, hi, vground), blend_on);
	vec3 col = mix(ground, stone, k);
	// Contact shade: the last hand-width against the earth sits in its own dark.
	col *= mix(0.76, 1.0, smoothstep(0.0, 0.35, vground));
	ALBEDO = col;
	ROUGHNESS = 0.97;
	SPECULAR = 0.2;
}
"


## How a structure looks, kept here rather than in each caller: the god menu,
## the world node and the probes were all making their own copy of the same
## material, which is three chances to drift and no batching.
static func stone() -> Material:
	var shader := Shader.new()
	shader.code = STRUCTURE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.03
	noise.fractal_octaves = 4
	var ntex := NoiseTexture2D.new()
	ntex.noise = noise
	ntex.seamless = true
	ntex.width = 256
	ntex.height = 256
	mat.set_shader_parameter("noise_tex", ntex)
	mat.set_shader_parameter("sand_tex", load("res://Terrain/textures/sand.jpg"))
	mat.set_shader_parameter("rock_tex", load("res://Terrain/textures/rock.jpg"))
	return mat


## A placement preview: what you are about to build, before you build it.
static func ghost() -> Material:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.6, 1.0, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func to_wire(points: Array) -> Array:
	var out: Array = []
	for p in points:
		var v: Vector3 = p
		out.append({"x": v.x, "y": v.y, "z": v.z})
	return out
