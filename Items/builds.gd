extends Node3D

## Server-placed build blocks (PORT_BLUEPRINT.md §4.2): block, wall, ramp,
## platform, bridge. Real StaticBody3D colliders — placement raycasts, player
## movement, and projectiles all interact with them automatically.
## (Web bridges were ray-only "thinPlatform"s; here a thin box collider gives
## the same walk-on behavior.)

## Channels (web §4.4): Ryan's parametric multi-point half-pipe "bridge" —
## anchors are relaxed at sharp corners, swept with a centripetal
## Catmull-Rom curve, ringed into a K-facet trough whose opening faces up.
const CHANNEL_RADIUS := 2.5
const CHANNEL_FACETS := 16
const CHANNEL_MAX_RELAX := 0.6
const CHANNEL_RING_SPACING := 1.5
const CHANNEL_MAX_RINGS := 260
## A trough that does not bank throws you out of every corner. The ring frame
## rolls into the turn by the angle a rider at CHANNEL_RIDE would need, which
## is what keeps them sitting in the groove instead of climbing the outer wall.
const CHANNEL_RIDE := 26.0     # the speed the banking is cut for
const CHANNEL_BANK_MAX := 1.05 # 60 degrees of roll and no further
const CHANNEL_HOOP := 7        # a structural hoop every N rings

## Bridge gun: a deck you roll onto. Both ends taper to nothing so a marble at
## speed slides on instead of slamming into a step, rims keep you aboard, and a
## truss hangs underneath so it reads as a structure from below.
const BRIDGE_W := 4.0
const BRIDGE_T := 0.34
const BRIDGE_RAMP := 3.2
const BRIDGE_RIM := 0.5

## WFC structures (Items/wfc.gd): the payload is just a seed, and every client
## collapses the identical building from it. Nothing but the seed travels.
const Wfc := preload("res://Items/wfc.gd")
const WFC_SIZE := 8            # tiles per side (8 x 6 m = a 48 m footprint)
## Compounds close enough to be worth linking get a walkway strung between
## them, at whatever angle the two happen to sit at. Nothing about this goes
## over the wire: every client has every seed, so every client draws the same
## spans from the same pairs.
const SPAN_MAX := 130.0
const SPAN_MIN := 26.0

var _builds: Dictionary = {}   # id -> StaticBody3D
var _channels: Dictionary = {}  # id -> StaticBody3D
var _compounds: Dictionary = {} # id -> {pos, seed, ry, style}
var _spans: Array = []          # StaticBody3D walkways, rebuilt as a set
var _relink := 0.0              # debounce: compounds arrive one event at a time
var _spots_sent: Dictionary = {}


func _ready() -> void:
	add_to_group("world_builds")
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"currentBuilds":
			for id in _builds:
				_builds[id].queue_free()
			_builds.clear()
			_compounds.clear()
			_spots_sent.clear()
			_relink = 0.35
			for b in data:
				_add_build(b)
		"buildPlaced":
			_add_build(data)
		"buildRemoved":
			var id := str(data)
			if _builds.has(id):
				_builds[id].queue_free()
				_builds.erase(id)
			if _compounds.erase(id):
				_relink = 0.35
		"currentChannels":
			for id in _channels:
				_channels[id].queue_free()
			_channels.clear()
			for c in data:
				_add_channel(c)
		"channelPlaced":
			_add_channel(data)
		"channelRemoved":
			var id := str(data)
			if _channels.has(id):
				_channels[id].queue_free()
				_channels.erase(id)


## Nearest build block within `radius` — god menu delete. {} if none.
func nearest_deletable(pos: Vector3, radius := 3.5) -> Dictionary:
	var best := {}
	for id in _builds:
		var d: float = _builds[id].position.distance_to(pos)
		if d < radius and (best.is_empty() or d < best["dist"]):
			best = {"id": id, "dist": d, "pos": _builds[id].position}
	return best


## Nearest channel (by anchor points) within `radius`. {} if none.
func nearest_channel(pos: Vector3, radius := 3.5) -> Dictionary:
	var best := {}
	for id in _channels:
		for a in _channels[id].get_meta("anchors", []):
			var d: float = (a as Vector3).distance_to(pos)
			if d < radius and (best.is_empty() or d < best["dist"]):
				best = {"id": id, "dist": d, "pos": a}
	return best


func _process(delta: float) -> void:
	if _relink <= 0.0:
		return
	_relink -= delta
	if _relink <= 0.0:
		_rebuild_spans()


## String walkways between compounds that stand near each other. Each end is a
## real rim deck (Wfc.anchors), so a span lands on something you can stand on,
## and the angle between two compounds is whatever it is — the off-axis runs
## are the point, they cut across a map that is otherwise all right angles.
func _rebuild_spans() -> void:
	for s in _spans:
		if is_instance_valid(s):
			s.queue_free()
	_spans.clear()
	var ids: Array = _compounds.keys()
	ids.sort()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: Dictionary = _compounds[ids[i]]
			var b: Dictionary = _compounds[ids[j]]
			var gap: float = Vector2(a["pos"].x - b["pos"].x, a["pos"].z - b["pos"].z).length()
			if gap > SPAN_MAX or gap < SPAN_MIN:
				continue
			var link := _best_link(a, b)
			if link.is_empty():
				continue
			var from: Vector3 = link["from"]
			var to: Vector3 = link["to"]
			var run := to - from
			var span: StaticBody3D = Wfc.build_span(run.length())
			# Aim the walkway's local +X straight down the run, keeping its deck
			# as level as a sloped span can be.
			var bx := run.normalized()
			var bz := bx.cross(Vector3.UP)
			bz = Vector3.FORWARD if bz.length() < 0.001 else bz.normalized()
			span.transform = Transform3D(Basis(bx, bz.cross(bx).normalized(), bz), from)
			add_child(span)
			_spans.append(span)


## The closest pair of rim decks that actually face each other, so a walkway
## leaves one compound heading outward instead of clipping back through it.
func _best_link(a: Dictionary, b: Dictionary) -> Dictionary:
	var pa: Array = Wfc.anchors(int(a["seed"]), WFC_SIZE, str(a["style"]))
	var pb: Array = Wfc.anchors(int(b["seed"]), WFC_SIZE, str(b["style"]))
	if pa.is_empty() or pb.is_empty():
		return {}
	var ta := Transform3D(Basis(Vector3.UP, float(a["ry"])), a["pos"])
	var tb := Transform3D(Basis(Vector3.UP, float(b["ry"])), b["pos"])
	var best := {}
	var best_d := INF
	for ea in pa:
		var wa: Vector3 = ta * (ea["pos"] as Vector3)
		var da: Vector3 = ta.basis * (ea["dir"] as Vector3)
		for eb in pb:
			var wb: Vector3 = tb * (eb["pos"] as Vector3)
			var db: Vector3 = tb.basis * (eb["dir"] as Vector3)
			var run := wb - wa
			var flat := Vector3(run.x, 0, run.z).normalized()
			if da.dot(flat) < 0.75 or db.dot(-flat) < 0.75:
				continue
			var d := run.length()
			if d < best_d:
				best_d = d
				best = {"from": wa, "to": wb}
	return best


## Items live on the structures now, and only the client knows where the decks
## are: the collapse runs here, not on the server. First report per compound
## wins, so it does not matter how many of us are looking at the same seed.
func _report_spots(id: String, comp: Dictionary) -> void:
	if _spots_sent.has(id):
		return
	_spots_sent[id] = true
	var t := Transform3D(Basis(Vector3.UP, float(comp["ry"])), comp["pos"])
	var out: Array = []
	for p in Wfc.item_spots(int(comp["seed"]), WFC_SIZE, str(comp["style"])):
		var w: Vector3 = t * (p as Vector3)
		out.append({"x": w.x, "y": w.y, "z": w.z})
	if not out.is_empty():
		Net.emit_event("wfcSpots", {"id": id, "spots": out})


## The hand-placed tileset piece occupying a given cell, or {}. The drone asks
## this about the four cells around its cursor to work out what fits there.
func part_at(cell_pos: Vector3) -> Dictionary:
	for id in _builds:
		var b: StaticBody3D = _builds[id]
		if b.get_meta("build_type", "") != "wfcpart":
			continue
		if b.position.distance_to(cell_pos) > 0.6:
			continue
		return {"kind": b.get_meta("part_kind", "deck"), "rot": b.get_meta("part_rot", 0)}
	return {}


## Web overlap rejection: same cell (<0.1), same type, same rotation.
func has_build_at(pos: Vector3, type: String, ry: float, rx: float) -> bool:
	for id in _builds:
		var b: StaticBody3D = _builds[id]
		if b.position.distance_to(pos) < 0.1 \
				and b.get_meta("build_type", "") == type \
				and absf(wrapf(b.rotation.y - ry, -PI, PI)) < 0.1 \
				and absf(wrapf(b.rotation.x - rx, -PI, PI)) < 0.1:
			return true
	return false


func _add_build(b: Dictionary) -> void:
	var id := str(b.get("id", ""))
	if id == "" or _builds.has(id):
		return
	var type := str(b.get("type", "block"))
	if type == "wfc" or type == "wfcpart":
		# A whole collapsed compound from its seed, or one module of the same
		# tileset placed by hand off the drone.
		var style := str(b.get("style", "surface"))
		var seed_value := int(b.get("seed", 1))
		var struct: StaticBody3D = Wfc.build_part(str(b.get("part", "deck"))) \
			if type == "wfcpart" else Wfc.build(seed_value, WFC_SIZE, style)
		struct.position = Vector3(b.get("x", 0.0), b.get("y", 0.0), b.get("z", 0.0))
		struct.rotation.y = float(b.get("ry", 0.0))
		add_child(struct)
		if type == "wfc":
			_compounds[id] = {"pos": struct.position, "seed": seed_value,
				"ry": struct.rotation.y, "style": style}
			_relink = 0.35
			_report_spots(id, _compounds[id])
		else:
			# What this piece is and which way it faces, so the drone can tell
			# whether the next one would mate with it.
			struct.set_meta("part_kind", str(b.get("part", "deck")))
			struct.set_meta("part_rot", int(roundf(struct.rotation.y / (PI * 0.5))) & 3)
		_builds[id] = struct
		return
	var body: StaticBody3D
	if type == "bridge":
		body = bridge_body(clampf(float(b.get("length", 4.0)), 0.6, 120.0))
	else:
		body = StaticBody3D.new()
		body.set_meta("build_type", type)
		var mesh_inst := MeshInstance3D.new()
		var shape := CollisionShape3D.new()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.667, 0.667, 0.667)
		mat.roughness = 0.8
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # web used DoubleSide
		match type:
			"ramp":
				mesh_inst.mesh = wedge_mesh(4.0, 4.0, 4.0)
				var poly := ConvexPolygonShape3D.new()
				poly.points = wedge_points(4.0, 4.0, 4.0)
				shape.shape = poly
			_:
				var size := Vector3(4, 4, 4)
				if type == "wall":
					size = Vector3(4, 4, 1)
				elif type == "platform":
					size = Vector3(4, 1, 4)
				var box := BoxMesh.new()
				box.size = size
				mesh_inst.mesh = box
				var box_shape := BoxShape3D.new()
				box_shape.size = size
				shape.shape = box_shape
		mesh_inst.material_override = mat
		body.add_child(mesh_inst)
		body.add_child(shape)
	body.position = Vector3(b.get("x", 0.0), b.get("y", 0.0), b.get("z", 0.0))
	body.rotation_order = EULER_ORDER_YXZ
	body.rotation = Vector3(float(b.get("rx", 0.0)), float(b.get("ry", 0.0)), 0.0)
	add_child(body)
	_builds[id] = body


# --- Bridge gun -------------------------------------------------------------

## One span, `length` long, running down local +Z with its middle at the
## origin — the same placement the old flat slab used, so nothing upstream
## changes. Both ends wedge down to nothing, which is the whole point: you
## roll onto it rather than colliding with its edge.
static func bridge_body(length: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("build_type", "bridge")
	var deck := StandardMaterial3D.new()
	deck.albedo_color = Color(0.10, 0.13, 0.17)
	deck.metallic = 0.55
	deck.roughness = 0.42
	var strut := StandardMaterial3D.new()
	strut.albedo_color = Color(0.16, 0.19, 0.23)
	strut.metallic = 0.7
	strut.roughness = 0.5
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.35, 0.95, 1.0)
	glow.emission_enabled = true
	glow.emission = Color(0.0, 0.72, 0.85)
	glow.emission_energy_multiplier = 2.6
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var ramp := clampf(length * 0.3, 0.4, BRIDGE_RAMP)
	var run := maxf(0.6, length - ramp * 2.0)
	var half := BRIDGE_W * 0.5

	_bx(body, Vector3(BRIDGE_W, BRIDGE_T, run), Vector3.ZERO, Vector3.ZERO, deck, true)
	_bx(body, Vector3(0.6, 0.05, run * 0.99), Vector3(0, BRIDGE_T * 0.5, 0),
		Vector3.ZERO, glow, false)
	for s: float in [-1.0, 1.0]:
		var rim_x: float = s * (half - 0.13)
		_bx(body, Vector3(0.26, BRIDGE_RIM, run), Vector3(rim_x, BRIDGE_RIM * 0.5, 0),
			Vector3.ZERO, deck, true)
		_bx(body, Vector3(0.3, 0.05, run), Vector3(rim_x, BRIDGE_RIM, 0),
			Vector3.ZERO, glow, false)
		# Approach wedge: the tip lands flush with whatever is under it
		var w := MeshInstance3D.new()
		w.mesh = wedge_mesh(BRIDGE_W, BRIDGE_T, ramp)
		w.position = Vector3(0, 0, s * (run + ramp) * 0.5)
		w.rotation.y = 0.0 if s > 0.0 else PI
		w.material_override = deck
		body.add_child(w)
		var wc := CollisionShape3D.new()
		var poly := ConvexPolygonShape3D.new()
		poly.points = wedge_points(BRIDGE_W, BRIDGE_T, ramp)
		wc.shape = poly
		wc.position = w.position
		wc.rotation.y = w.rotation.y
		body.add_child(wc)

	# Truss: two spine beams and a V of struts every few metres. No colliders —
	# it hangs below the deck and is there to be looked at.
	for s: float in [-1.0, 1.0]:
		_bx(body, Vector3(0.2, 0.44, run), Vector3(s * (half - 0.5), -BRIDGE_T * 0.5 - 0.22, 0),
			Vector3.ZERO, strut, false)
	var ties := maxi(1, int(run / 5.0))
	for i in ties:
		var z := -run * 0.5 + run * (float(i) + 0.5) / float(ties)
		_bx(body, Vector3(BRIDGE_W - 0.9, 0.14, 0.14), Vector3(0, -1.05, z),
			Vector3.ZERO, strut, false)
		for s: float in [-1.0, 1.0]:
			_bx(body, Vector3(0.12, 1.0, 0.12), Vector3(s * (half - 0.75), -0.62, z),
				Vector3(0, 0, s * 0.42), strut, false)
	return body


static func _bx(root: Node3D, size: Vector3, pos: Vector3, rot: Vector3,
		mat: StandardMaterial3D, collide: bool) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	root.add_child(mi)
	if not collide:
		return
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = pos
	col.rotation = rot
	root.add_child(col)


# --- Channels ---------------------------------------------------------------

## Web relaxChannelAnchors: no pull under ~25°, full 0.6 pull past ~125°.
static func _relax_anchors(points: Array) -> Array:
	if points.size() <= 2:
		return points.duplicate()
	var out: Array = [points[0]]
	for i in range(1, points.size() - 1):
		var v1: Vector3 = points[i] - points[i - 1]
		var v2: Vector3 = points[i + 1] - points[i]
		if v1.length_squared() < 1e-8 or v2.length_squared() < 1e-8:
			out.append(points[i])
			continue
		var angle := acos(clampf(v1.normalized().dot(v2.normalized()), -1.0, 1.0))
		var t := clampf((angle - PI / 7.0) / (PI * 0.6), 0.0, 1.0) * CHANNEL_MAX_RELAX
		var mid: Vector3 = (points[i - 1] + points[i + 1]) * 0.5
		out.append(points[i].lerp(mid, t))
	out.append(points[points.size() - 1])
	return out


## Centripetal Catmull-Rom (Barry–Goldman), matching THREE's 'centripetal'.
static func _cr_point(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t0 := 0.0
	var t1 := t0 + maxf(sqrt(p0.distance_to(p1)), 1e-4)
	var t2 := t1 + maxf(sqrt(p1.distance_to(p2)), 1e-4)
	var t3 := t2 + maxf(sqrt(p2.distance_to(p3)), 1e-4)
	var tt := lerpf(t1, t2, t)
	var a1 := p0.lerp(p1, (tt - t0) / (t1 - t0))
	var a2 := p1.lerp(p2, (tt - t1) / (t2 - t1))
	var a3 := p2.lerp(p3, (tt - t2) / (t3 - t2))
	var b1 := a1.lerp(a2, (tt - t0) / (t2 - t0))
	var b2 := a2.lerp(a3, (tt - t1) / (t3 - t1))
	return b1.lerp(b2, (tt - t1) / (t2 - t1))


## The swept skeleton of a channel: arc-spaced centre points, each with a
## banked basis. The mesh, the trim and the physics of riding one all come off
## this single array, so they can never disagree about where the trough is.
## Each entry is {p, t, r, u} — point, tangent, right, and the trough's own up.
static func channel_frames(anchors_in: Array) -> Array:
	var anchors := _relax_anchors(anchors_in)
	var dense: Array = []
	for i in anchors.size() - 1:
		var p0: Vector3 = anchors[maxi(i - 1, 0)]
		var p1: Vector3 = anchors[i]
		var p2: Vector3 = anchors[i + 1]
		var p3: Vector3 = anchors[mini(i + 2, anchors.size() - 1)]
		for s in 12:
			dense.append(_cr_point(p0, p1, p2, p3, s / 12.0))
	dense.append(anchors[anchors.size() - 1])

	var length := 0.0
	for i in dense.size() - 1:
		length += dense[i].distance_to(dense[i + 1])
	var n := clampi(ceili(length / CHANNEL_RING_SPACING), 2, CHANNEL_MAX_RINGS)

	# Evenly arc-spaced ring centers
	var samples: Array = [dense[0]]
	var step := length / n
	var acc := 0.0
	var di := 0
	for k in range(1, n):
		var want := k * step
		while di < dense.size() - 1:
			var seg: float = dense[di].distance_to(dense[di + 1])
			if acc + seg >= want:
				samples.append(dense[di].lerp(dense[di + 1], (want - acc) / maxf(seg, 1e-6)))
				break
			acc += seg
			di += 1
		if samples.size() <= k:
			samples.append(dense[dense.size() - 1])
	samples.append(dense[dense.size() - 1])

	# Unbanked frame first: tangent, level right, and the up that follows
	var tans: Array = []
	for i in samples.size():
		var tangent: Vector3
		if i == 0:
			tangent = samples[1] - samples[0]
		elif i == samples.size() - 1:
			tangent = samples[i] - samples[i - 1]
		else:
			tangent = samples[i + 1] - samples[i - 1]
		if tangent.length_squared() < 1e-8:
			tangent = Vector3(0, 0, 1)
		tans.append(tangent.normalized())

	# How hard each point turns, smoothed so the roll does not chatter, then
	# tapered to nothing at both mouths so entering one is not a lurch.
	var lean: Array = []
	lean.resize(samples.size())
	for i in samples.size():
		var raw := 0.0
		if i > 0 and i < samples.size() - 1:
			var dt: Vector3 = (tans[i + 1] - tans[i - 1]) / (2.0 * maxf(step, 0.01))
			var rt0: Vector3 = Vector3.UP.cross(tans[i])
			rt0 = Vector3(1, 0, 0) if rt0.length_squared() < 1e-6 else rt0.normalized()
			var kappa := dt.length()
			raw = signf(dt.dot(rt0)) * atan(CHANNEL_RIDE * CHANNEL_RIDE * kappa / 20.0)
		lean[i] = clampf(raw, -CHANNEL_BANK_MAX, CHANNEL_BANK_MAX)
	var smooth: Array = []
	smooth.resize(lean.size())
	for i in lean.size():
		var sum := 0.0
		var cnt := 0
		for k in range(maxi(0, i - 3), mini(lean.size(), i + 4)):
			sum += float(lean[k])
			cnt += 1
		var edge := minf(1.0, minf(float(i), float(lean.size() - 1 - i)) / 4.0)
		smooth[i] = (sum / float(cnt)) * edge

	var frames: Array = []
	for i in samples.size():
		var t: Vector3 = tans[i]
		var rt := Vector3.UP.cross(t)
		rt = Vector3(1, 0, 0) if rt.length_squared() < 1e-6 else rt.normalized()
		var up := t.cross(rt).normalized()
		# Roll the pair about the tangent: the floor tips toward the turn, which
		# is what holds a rider in the groove instead of up the outer wall.
		var roll: float = smooth[i]
		frames.append({
			"p": samples[i], "t": t,
			"r": rt * cos(roll) - up * sin(roll),
			"u": up * cos(roll) + rt * sin(roll),
		})
	return frames


static func _channel_ring(f: Dictionary, radius: float, j: int) -> Vector3:
	var a := -PI / 2.0 + (float(j) / CHANNEL_FACETS) * PI
	return (f["p"] as Vector3) + (f["r"] as Vector3) * radius * sin(a) \
		+ (f["u"] as Vector3) * radius * (1.0 - cos(a))


## Half-pipe triangles swept along the smoothed anchor polyline (web
## buildChannelGeometry).
static func channel_tris(frames: Array, radius: float) -> PackedVector3Array:
	var tris := PackedVector3Array()
	for i in frames.size() - 1:
		for j in CHANNEL_FACETS:
			var a0 := _channel_ring(frames[i], radius, j)
			var a1 := _channel_ring(frames[i + 1], radius, j)
			var b0 := _channel_ring(frames[i], radius, j + 1)
			var b1 := _channel_ring(frames[i + 1], radius, j + 1)
			tris.append(a0); tris.append(a1); tris.append(b0)
			tris.append(a1); tris.append(b1); tris.append(b0)
	return tris


## The lit lines a rider actually steers by: one down the groove and one along
## each lip. Ribbons laid a few centimetres proud of the trough, unshaded, so
## the run reads at distance and in the dark.
static func _channel_trim(frames: Array, radius: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid := CHANNEL_FACETS / 2
	for lane in [0, mid, CHANNEL_FACETS]:
		for i in frames.size() - 1:
			var f0: Dictionary = frames[i]
			var f1: Dictionary = frames[i + 1]
			var n0: Vector3 = ((f0["p"] as Vector3) + (f0["u"] as Vector3) * radius
				- _channel_ring(f0, radius, lane)).normalized()
			var n1: Vector3 = ((f1["p"] as Vector3) + (f1["u"] as Vector3) * radius
				- _channel_ring(f1, radius, lane)).normalized()
			var w0: Vector3 = (f0["t"] as Vector3).cross(n0).normalized() * 0.16
			var w1: Vector3 = (f1["t"] as Vector3).cross(n1).normalized() * 0.16
			var a := _channel_ring(f0, radius, lane) + n0 * 0.04
			var b := _channel_ring(f1, radius, lane) + n1 * 0.04
			st.add_vertex(a - w0); st.add_vertex(b - w1); st.add_vertex(a + w0)
			st.add_vertex(b - w1); st.add_vertex(b + w1); st.add_vertex(a + w0)
	st.generate_normals()
	return st.commit()


## Structural hoops on the outside, every few rings. They never touch the
## rider — they are there so a channel looks built rather than extruded.
static func _channel_hoops(frames: Array, radius: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var i := CHANNEL_HOOP
	while i < frames.size() - 1:
		var f: Dictionary = frames[i]
		var t: Vector3 = (f["t"] as Vector3) * 0.16
		for j in CHANNEL_FACETS:
			var o0 := _channel_ring(f, radius, j)
			var o1 := _channel_ring(f, radius, j + 1)
			var d0: Vector3 = (o0 - (f["p"] as Vector3) - (f["u"] as Vector3) * radius).normalized() * 0.3
			var d1: Vector3 = (o1 - (f["p"] as Vector3) - (f["u"] as Vector3) * radius).normalized() * 0.3
			for s: float in [-1.0, 1.0]:
				var a := o0 + d0 + t * s
				var b := o1 + d1 + t * s
				var c := o1 + t * s
				var d := o0 + t * s
				st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
				st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
			st.add_vertex(o0 + d0 - t); st.add_vertex(o1 + d1 - t); st.add_vertex(o1 + d1 + t)
			st.add_vertex(o0 + d0 - t); st.add_vertex(o1 + d1 + t); st.add_vertex(o0 + d0 + t)
		i += CHANNEL_HOOP
	st.generate_normals()
	return st.commit()


func _add_channel(c: Dictionary) -> void:
	var id := str(c.get("id", ""))
	if id == "" or _channels.has(id):
		return
	var anchors: Array = []
	for nd in c.get("nodes", []):
		anchors.append(Vector3(nd.get("x", 0.0), nd.get("y", 0.0), nd.get("z", 0.0)))
	if anchors.size() < 2:
		return
	var radius := float(c.get("radius", CHANNEL_RADIUS))
	var frames := channel_frames(anchors)
	var tris := channel_tris(frames, radius)
	if tris.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in tris:
		st.add_vertex(v)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.23, 0.25, 0.3)
	mat.metallic = 0.5
	mat.roughness = 0.38
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var body := StaticBody3D.new()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = st.commit()
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	var lit := StandardMaterial3D.new()
	lit.albedo_color = Color(0.4, 0.95, 1.0)
	lit.emission_enabled = true
	lit.emission = Color(0.0, 0.7, 0.85)
	lit.emission_energy_multiplier = 2.8
	lit.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lit.cull_mode = BaseMaterial3D.CULL_DISABLED
	var trim := MeshInstance3D.new()
	trim.mesh = _channel_trim(frames, radius)
	trim.material_override = lit
	body.add_child(trim)

	var ribs := StandardMaterial3D.new()
	ribs.albedo_color = Color(0.27, 0.3, 0.36)
	ribs.metallic = 0.8
	ribs.roughness = 0.45
	ribs.cull_mode = BaseMaterial3D.CULL_DISABLED
	var hoops := MeshInstance3D.new()
	hoops.mesh = _channel_hoops(frames, radius)
	hoops.material_override = ribs
	body.add_child(hoops)

	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	shape.backface_collision = true
	col.shape = shape
	body.add_child(col)
	var box := AABB((frames[0] as Dictionary)["p"], Vector3.ZERO)
	for f: Dictionary in frames:
		box = box.expand(f["p"])
	body.set_meta("anchors", anchors)
	body.set_meta("frames", frames)
	body.set_meta("radius", radius)
	body.set_meta("bounds", box.grow(radius * 1.2))
	add_child(body)
	_channels[id] = body


## Where in a channel a point is, if it is in one at all. The player asks this
## every tick: inside the trough its own "down" is the wall, not the world.
## Returns {axis, t, r, u, radius} — the axis is the line the trough curls
## around, so (pos - axis) IS which way gravity should point for a rider.
func ride_frame(pos: Vector3) -> Dictionary:
	var best := {}
	var best_d := INF
	for id in _channels:
		var body: StaticBody3D = _channels[id]
		var bounds: AABB = body.get_meta("bounds", AABB())
		if not bounds.has_point(pos):
			continue
		var frames: Array = body.get_meta("frames", [])
		var radius: float = body.get_meta("radius", CHANNEL_RADIUS)
		for f: Dictionary in frames:
			var d: float = (f["p"] as Vector3).distance_squared_to(pos)
			if d < best_d:
				best_d = d
				best = {"f": f, "radius": radius}
	if best.is_empty() or best_d > 64.0:
		return {}
	var f: Dictionary = best["f"]
	var radius: float = best["radius"]
	var t: Vector3 = f["t"]
	var u: Vector3 = f["u"]
	var axis: Vector3 = (f["p"] as Vector3) + u * radius
	var off := pos - axis
	axis += t * off.dot(t)          # slide the axis point alongside the rider
	off -= t * off.dot(t)
	var dist := off.length()
	# Inside the bowl, off the very bottom, and not already through the wall
	if dist < radius * 0.3 or dist > radius * 1.06 or off.dot(u) > radius * 0.25:
		return {}
	return {"axis": axis, "t": t, "r": f["r"], "u": u, "radius": radius}


## Right wedge matching the web's createRightWedgeGeometry: flat bottom,
## vertical back (-Z), slope from the front-bottom edge up to the back-top.
static func wedge_points(w: float, h: float, d: float) -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-w / 2, -h / 2,  d / 2), Vector3(w / 2, -h / 2,  d / 2),
		Vector3(w / 2, -h / 2, -d / 2), Vector3(-w / 2, -h / 2, -d / 2),
		Vector3(-w / 2,  h / 2, -d / 2), Vector3(w / 2,  h / 2, -d / 2),
	])


static func wedge_mesh(w: float, h: float, d: float) -> ArrayMesh:
	var v := wedge_points(w, h, d)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [
		[0, 2, 1], [0, 3, 2],       # bottom
		[3, 4, 5], [3, 5, 2],       # back (vertical)
		[0, 4, 3],                  # left
		[1, 2, 5],                  # right
		[0, 1, 5], [0, 5, 4],       # slope
	]:
		st.add_vertex(v[tri[0]])
		st.add_vertex(v[tri[1]])
		st.add_vertex(v[tri[2]])
	st.generate_normals()
	return st.commit()
