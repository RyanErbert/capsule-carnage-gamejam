extends Node3D

## Before and after on the join: the same wall on the same rolling ground, once
## with the flat stone material it used to have and once with the blend. Set
## PROBE_SHOT; two files land beside it. Windowed, because headless never draws.

const Registry := preload("res://Items/parametric/registry.gd")
const Terrain := preload("res://Terrain/voxel_terrain.gd")

var _wall: Node3D


func _ready() -> void:
	_ground()
	_stage()
	_shoot()


## A rolling plane under the wall, wearing the terrain's own shader, so the
## blend is judged against the material it is blending into.
func _ground() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 60
	var step := 3.0
	for gz in n:
		for gx in n:
			var p: Array = []
			for c: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
				var x := (float(gx) + c.x - n * 0.5) * step
				var z := (float(gz) + c.y - n * 0.5) * step
				p.append(Vector3(x, _h(x, z), z))
			for tri in [[0, 2, 1], [0, 3, 2]]:
				var a: Vector3 = p[tri[0]]
				var b: Vector3 = p[tri[1]]
				var c2: Vector3 = p[tri[2]]
				var nr := (b - a).cross(c2 - a).normalized()
				for v: Vector3 in [a, b, c2]:
					st.set_color(Color.WHITE)     # terrain reads COLOR.r as AO
					st.set_normal(nr)
					st.add_vertex(v)
	var shader := Shader.new()
	shader.code = Terrain.TERRAIN_SHADER
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
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)


static func _h(x: float, z: float) -> float:
	return sin(x * 0.055) * 2.4 + cos(z * 0.07) * 1.7 + sin((x + z) * 0.021) * 3.0


func _build(mat: Material) -> Node3D:
	# Nodes every few metres, the way a wall actually gets clicked. Spanning 15 m
	# at a time the straight rail floats over a metre above a dipping ground, and
	# the join floats with it.
	var pts: Array = []
	for i in 13:
		var x := -30.0 + 5.0 * i
		pts.append(Vector3(x, _h(x, 0.0), 0.0))
	return Registry.build({
		"type": "wall",
		"nodes": Registry.to_wire(pts),
		"holes": Registry.to_wire([Vector3(-8, _h(-8, 0) + 5.0, 0)]),
		"params": {"height": 8.0, "thickness": 2.4, "batter": 0.22, "coping": 0.9,
			"tooth": 1.1, "chamfer": 0.18, "arch": 0.7},
	}, mat, false)


## The material structures used before the blend existed: flat triplanar stone,
## meeting the ground at a hard line.
static func _old_stone() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://Terrain/textures/rock.jpg")
	mat.albedo_color = Color(0.78, 0.76, 0.72)
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(0.22, 0.22, 0.22)
	mat.roughness = 1.0
	return mat


## The baked ground factor, straight out as greyscale: black at the ground line,
## white once clear of the band. Eyeballing the blended result guesses at this;
## this shows it.
static func _factor_view() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "shader_type spatial;
varying float g;
" 		+ "void vertex() { g = COLOR.r; }
" 		+ "void fragment() { ALBEDO = vec3(g); EMISSION = vec3(g); }"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for pass_name in ["before", "after", "factor", "stoneonly"]:
		if _wall:
			_wall.queue_free()
		var mat: Material = Registry.stone()
		if pass_name == "before":
			mat = _old_stone()
		elif pass_name == "factor":
			mat = _factor_view()
		elif pass_name == "stoneonly":
			(mat as ShaderMaterial).set_shader_parameter("blend_on", 0.0)
		_wall = _build(mat)
		add_child(_wall)
		for i in 6:
			await RenderingServer.frame_post_draw
		if base != "":
			get_viewport().get_texture().get_image().save_png(
				base.replace(".png", "_%s.png" % pass_name))
	get_tree().quit()


func _stage() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(6, 3.4, 15)
	cam.look_at(Vector3(-10, 1.6, 0))
	cam.fov = 62.0
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-40, 28, 0)
	sun.light_energy = 1.25
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.47, 0.60, 0.72)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.58, 0.61, 0.67)
	e.ambient_light_energy = 0.95
	env.environment = e
	add_child(env)
