extends Node3D

## Creative level: paint a 32x32 pixel matrix across 5 stacked LAYERS
## (scroll wheel changes the active layer), GENERATE extrudes the stack into
## a 128x128 m world of 4 m slabs — basement and ground (both default solid;
## erase the basement for cellars, the ground for a drop into them), then
## main, +1, +2 — sitting on an uneditable bedrock plane, surrounded by a
## flat unmodifiable plain instead of a rim dropoff (voxel_terrain.gd).
##
## The canvas doesn't start blank. The server rolls a seeded world (canyons,
## plateaus, spires, tunnels) and then runs a game of SNAKE on the pixel grid
## to decide who may sculpt what: you are always moving, you can only turn, and
## the only way to take ground is to close a loop against your own trail. Cut
## someone else's trail and they are out and the rest of the board is yours.
## When that clock stops, everything you don't own fogs over and the edit
## timer starts.
##
## Multiplayer: the pixel grid and every brush stroke go through the server
## ('creativeGrid' / 'terrainEdit'); joiners get a snapshot on connect, so
## everyone sculpts the same world.
##
## Terraforming is gated: god mode has DIG/FILL tools (god_menu.gd) and the
## drill vehicle carves while driving — no free sculpting during normal play.

# Layer 0 is the BASEMENT (solid by default; erase it to hollow out a cellar),
# layer 1 the ground you walk on, 2..4 the slabs stacked over it.
const LAYERS := 5
const GROUND := 1
const LAYER_NAMES := ["BASEMENT", "GROUND", "MAIN", "+1", "+2"]  # bottom up
const BRUSH_RADIUS := 3.0       # default radius for replayed edits
const KILL_Y := -30.0           # below the world: instant respawn backstop

# Painted grid size in pixels — server-authoritative (gameSettings gridW/gridH,
# and every layers payload carries its gs [w, h]). Rows are packed uint32
# bitmask words, (PX_W+31)/32 of them per row, laid out flat row-major.
var PX_W := 32
var PX_H := 32

# Stage bounds: a base haze sits over the whole world, visible fog banks
# stand just outside the play area, and the closer you get to the edge the
# thicker it reads — full white ~38 m out, where you're turned around to
# face the center. Derived from the grid size when the world generates.
const FOG_MARGIN := 8.0    # metres past the painted edge before it thickens
const FOG_RAMP := 36.0     # ...and how much further to a full whiteout
const FOG_BASE := 0.0015   # always-on depth-fog density inside the arena

# Unshaded white haze sheet for the boundary fog banks: solid near the
# ground, fading out toward the top so it reads as weather, not a fence.
const FOG_WALL_SHADER := "
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform float alpha_max = 0.1;
void fragment() {
	float fade = smoothstep(0.02, 0.55, UV.y);
	ALBEDO = vec3(1.0);
	ALPHA = alpha_max * fade;
}
"
# Spawn zones: each painter can claim one. The 5x5-pixel block around a claim
# is a DEADZONE — unpaintable here, unsculptable in play — so respawns always
# land on known ground. No claims = no deadzones. Mirrors server DEADZONE_R.
const DEADZONE_PX := 2          # pixels either side of the claimed pixel

# Confined spaces duck the wind and fade in a cave drone; venturing past the
# bounds ramps in a gale over the top of it.
const PROBE_DIRS := [
	Vector3(0, 1, 0), Vector3(0.6, 0.8, 0), Vector3(-0.6, 0.8, 0),
	Vector3(0, 0.8, 0.6), Vector3(0, 0.8, -0.6),
]
const PROBE_DIST := 16.0
const AMBIENCE_LERP := 1.4      # how fast the mix follows the space you're in

# Claim phase: territory colors by player index (mirrors the server's ids
# array order). Yours is always drawn brighter than everyone else's.
const CLAIM_COLORS := ["#7dedb0", "#7fb2ff", "#ffd54a", "#ff8a7d", "#c58aff", "#7dede0"]
const CLAIM_FREE := -1      # nobody's
const FOG := Color("#05060a")

const FILL_ON := Color("#ff9a2e")   # armed FILL, impossible to miss
const Style := preload("res://UI/ui_style.gd")
const PlayerScene := preload("res://Player/player.tscn")
const HudScene := preload("res://UI/game_hud.tscn")
const VoxelTerrain := preload("res://Terrain/voxel_terrain.gd")

var terrain: Node3D
var player: CharacterBody3D
var _playing := false
var _layers: Array = []        # 4 x (32 ints), bit (31-col) = filled
var _active_layer := 2         # painting target; 2 = MAIN
var _layer_buttons: Array = []
var _brush := 1                # painter brush size, in cells across
var _fill_mode := false        # clicks work the whole column, not one layer
var _zones: Dictionary = {}    # socket id -> [r, c]; one spawn zone each
var _cursors: Dictionary = {}  # socket id -> {r, c, t}; co-painters' hovers
var _hover_px := Vector2i(-1, -1)
var _hover_sent := Vector2i(-1, -1)
var _cursor_send_cd := 0.0
var _spawn_mode := false       # SPAWN chip armed: clicks claim your zone
var _spawn_button: Button
# --- Claim phase ---
var _claim_phase := ""         # "" none | "claim" land grab | "edit" fogged
var _claim_own := PackedInt32Array()   # per cell: -2 edge, -1 free, else index
var _claim_ids: Array = []
var _claim_pos: Array = []     # [[r, c], ...] parallel to _claim_ids
var _claim_dead: Array = []    # ...and whether each one is out of the round
var _claim_trail: Dictionary = {}      # cell index -> player index
var _claim_left := 0.0         # seconds on the clock, counted down locally
var _claim_dir := Vector2i.ZERO
var _claim_banner: Label
var _hint: Label
var _brush_row: Control
var _layer_col: Control
var _start_button: Button
var _end_claim_button: Button
var _vote_row: Control          # START GAME poll, while one is running
var _vote_label: Label
var _vote: Variant = null       # {voters, yes, no} from the server
var _editor_layer: CanvasLayer
var _painter: Control
var _status: Label
var _fog_rect: ColorRect
var _env_ref: Environment
var _wind: AudioStreamPlayer    # base ambience
var _gale: AudioStreamPlayer    # boundary wind, ramps in past the bounds
var _cave: AudioStreamPlayer    # low drone for confined spaces
var _motes: CPUParticles3D      # cave dust, fades in with confinement
var _confine := 0.0             # 0 open sky .. 1 fully enclosed
var _probe_cd := 0.0


func _ready() -> void:
	_setup_environment()
	var gs0 := _settings_gs()
	PX_W = gs0.x
	PX_H = gs0.y
	_layers = _default_layers()
	_zones = Net.spawn_zones.duplicate()
	_build_editor_ui()
	Net.event_received.connect(_on_net_event)
	# A land grab may already be running (the snapshot lands on connect, long
	# before this scene exists) — pick it up before announcing ourselves.
	if Net.claim_state != null:
		_apply_claim_state(Net.claim_state)
	if Net.start_vote != null:
		_apply_start_vote(Net.start_vote)
	Net.emit_event("editing", true)   # counts us in the generate/clear votes
	# Someone already sculpted a world this session? Join it as-is.
	var live := _norm_layers(Net.creative_grid)
	var painting := _norm_layers(Net.paint_rows)
	if not live.is_empty():
		_adopt_size(live["gs"])
		_start_play(live["layers"], Net.terrain_edits.duplicate(), false)
	elif OS.get_environment("FRIENDSLOP_AUTOJOIN") == "1":
		_start_play.call_deferred(_layers, [], true)  # headless testing
	elif not painting.is_empty():
		# Someone is mid-painting: adopt their canvas
		_adopt_size(painting["gs"])
		_adopt_paint(painting["layers"])


## Each axis picks its own size (mirrors the server's GRID_SIZES).
const GRID_SIZES := [24, 32, 40, 48, 56, 64, 80, 96]


static func _valid_gs(gs: Vector2i) -> Vector2i:
	return Vector2i(gs.x if gs.x in GRID_SIZES else 32, gs.y if gs.y in GRID_SIZES else 32)


## The size the server currently wants.
static func _settings_gs() -> Vector2i:
	return _valid_gs(Vector2i(
		int(Net.game_settings.get("gridW", 32)), int(Net.game_settings.get("gridH", 32))))


## Words per bitmask row.
func _wc() -> int:
	return (PX_W + 31) >> 5


func _bit_at(rows: Array, r: int, c: int) -> bool:
	return bool((int(rows[r * _wc() + (c >> 5)]) >> (31 - (c & 31))) & 1)


## The canvas (and the world) changed size: fresh layers at the new size.
func _adopt_size(gs: Vector2i) -> void:
	gs = _valid_gs(gs)
	if gs == Vector2i(PX_W, PX_H):
		return
	PX_W = gs.x
	PX_H = gs.y
	_layers = _default_layers()
	if _painter:
		_painter.fit()
		_painter.queue_redraw()


## Back to the menu, or any other exit: stop counting toward editor votes.
func _exit_tree() -> void:
	Net.emit_event("editing", false)


## Ground layer full (the flat plain you walk on), everything above empty.
func _default_layers() -> Array:
	var w := _wc()
	var out := []
	for li in LAYERS:
		var rows := []
		for _r in PX_H:
			for wi in w:
				var bits := mini(32, PX_W - wi * 32)
				# Basement AND ground start solid, everything above them empty
				rows.append((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF if li <= GROUND else 0)
		out.append(rows)
	return out


## Validate + int-normalize a {layers, gs:[w,h]} payload. Returns {} when the
## shape is wrong, else {"gs": Vector2i, "layers": Array}.
func _norm_layers(data: Variant) -> Dictionary:
	if not data is Dictionary:
		return {}
	var raw: Variant = data.get("gs", [32, 32])
	if not (raw is Array) or (raw as Array).size() != 2:
		return {}
	var gs := _valid_gs(Vector2i(int(raw[0]), int(raw[1])))
	var layers: Variant = data.get("layers")
	if not (layers is Array) or layers.size() != LAYERS:
		return {}
	var expect := gs.y * ((gs.x + 31) >> 5)
	var out := []
	for rows in layers:
		if not (rows is Array) or rows.size() != expect:
			return {}
		var ints := []
		for v in rows:
			ints.append(int(v))
		out.append(ints)
	return {"gs": gs, "layers": out}


func _grid_payload() -> Dictionary:
	return {"layers": _layers, "gs": [PX_W, PX_H]}


func _adopt_paint(layers: Array) -> void:
	_layers = layers
	if _painter:
		_painter.queue_redraw()


## Painter calls this on every stroke; sends are throttled in _process.
var _paint_dirty := false
var _paint_send_cd := 0.0

func _on_painted() -> void:
	_paint_dirty = true


func _process(delta: float) -> void:
	if _playing:
		return
	if _claim_phase != "":
		_claim_left = maxf(0.0, _claim_left - delta)
		_update_banner()
		if _claim_phase == "claim":
			_poll_claim_input()
	_paint_send_cd = maxf(0.0, _paint_send_cd - delta)
	if _paint_dirty and _paint_send_cd <= 0.0:
		_paint_dirty = false
		_paint_send_cd = 0.12
		Net.emit_event("creativePaint", _grid_payload())
	# Hover cursor, relayed so co-painters can see where you are
	_cursor_send_cd = maxf(0.0, _cursor_send_cd - delta)
	if _cursor_send_cd <= 0.0 and _hover_px.x >= 0 and _hover_px != _hover_sent:
		_cursor_send_cd = 0.1
		_hover_sent = _hover_px
		Net.emit_event("editCursor", {"r": _hover_px.y, "c": _hover_px.x})
	if not _cursors.is_empty() and _painter:
		_painter.queue_redraw()  # keeps stale cursors fading out


func _on_hover(r: int, c: int) -> void:
	_hover_px = Vector2i(c, r)


# --- Claim phase -------------------------------------------------------------

## Full board: sent when a loop closes, when someone joins or leaves, and once
## when the phase flips. `own` packs one char per cell (see server claimBoard).
func _apply_claim_state(data: Variant) -> void:
	if not data is Dictionary:
		_claim_phase = ""
		_refresh_phase_ui()
		return
	var raw: Variant = data.get("gs", [PX_W, PX_H])
	if raw is Array and (raw as Array).size() == 2:
		_adopt_size(Vector2i(int(raw[0]), int(raw[1])))
	_claim_phase = str(data.get("phase", ""))
	_claim_ids = data.get("ids", []) if data.get("ids") is Array else []
	_claim_pos = data.get("pos", []) if data.get("pos") is Array else []
	_claim_dead = data.get("dead", []) if data.get("dead") is Array else []
	_claim_left = float(data.get("t", 0)) / 1000.0
	var own := str(data.get("own", ""))
	_claim_own.resize(PX_W * PX_H)
	for i in mini(own.length(), _claim_own.size()):
		_claim_own[i] = own.unicode_at(i) - 50
	_claim_trail.clear()
	var trail: Variant = data.get("trail", [])
	if trail is Array:
		for i in range(0, (trail as Array).size() - 1, 2):
			_claim_trail[int(trail[i])] = int(trail[i + 1])
	_refresh_phase_ui()
	if _painter:
		_painter.queue_redraw()


## 10 Hz delta while the land grab runs: cursors, the cells they just painted
## in, and anyone whose trail was cut out from under them.
func _apply_claim_tick(data: Variant) -> void:
	if not data is Dictionary or _claim_phase != "claim":
		return
	_claim_left = float(data.get("t", 0)) / 1000.0
	if data.get("pos") is Array:
		_claim_pos = data["pos"]
	var add: Variant = data.get("add", [])
	if add is Array:
		for i in range(0, (add as Array).size() - 1, 2):
			_claim_trail[int(add[i])] = int(add[i + 1])
	if _painter:
		_painter.queue_redraw()


## Snake steering: you are ALWAYS moving and can only turn. Letting go of the
## keys does nothing — we send a direction when you press one and never send a
## stop. Diagonals collapse to one axis or a trail can't enclose ground, and
## the server refuses a straight reversal onto the block you just laid.
func _poll_claim_input() -> void:
	if get_viewport().gui_get_focus_owner() != null:
		return
	var v := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var dir := Vector2i.ZERO
	if absf(v.x) > absf(v.y) and absf(v.x) > 0.3:
		dir = Vector2i(0, 1 if v.x > 0.0 else -1)
	elif absf(v.y) > 0.3:
		dir = Vector2i(1 if v.y > 0.0 else -1, 0)
	if dir == Vector2i.ZERO or dir == _claim_dir:
		return
	_claim_dir = dir
	Net.emit_event("claimDir", {"dr": dir.x, "dc": dir.y})


func _update_banner() -> void:
	if _claim_banner == null:
		return
	var mins := int(_claim_left) / 60
	var secs := int(_claim_left) % 60
	var clock := "%d:%02d" % [mins, secs]
	if _claim_phase == "claim":
		var me := _my_claim_index()
		if me >= 0 and me < _claim_dead.size() and bool(_claim_dead[me]):
			_claim_banner.text = "OUT   %s" % clock
			_claim_banner.add_theme_color_override("font_color", Color("#ff8a7d"))
			return
		_claim_banner.text = "CLAIM   %s   [WASD]" % clock
		_claim_banner.add_theme_color_override("font_color", Color("#ffd54a"))
	else:
		_claim_banner.text = "EDIT   %s" % clock
		_claim_banner.add_theme_color_override("font_color", Color("#7dedb0"))


## Sculpting tools only exist once the land is divided; during the grab the
## board is a game, not a canvas.
func _refresh_phase_ui() -> void:
	var grabbing := _claim_phase == "claim"
	if _claim_banner:
		_claim_banner.visible = _claim_phase != ""
	if _hint:
		_hint.visible = not grabbing
	if _brush_row:
		_brush_row.visible = not grabbing
	if _layer_col:
		_layer_col.visible = not grabbing
	if _start_button:
		_start_button.visible = not grabbing and _vote == null
	if _end_claim_button:
		_end_claim_button.visible = grabbing
	if _vote_row:
		_vote_row.visible = not grabbing and _vote != null
	_update_banner()
	_update_hint()


## Cutting the sculpting short takes everyone: START GAME opens a poll and the
## button becomes the tally until it passes, fails, or nobody answers and the
## edit clock starts the match on its own.
func _apply_start_vote(data: Variant) -> void:
	_vote = data if data is Dictionary else null
	if _vote != null and _vote_label:
		var voters: Array = _vote.get("voters", []) if _vote.get("voters") is Array else []
		var yes: Array = _vote.get("yes", []) if _vote.get("yes") is Array else []
		_vote_label.text = "START?  %d/%d" % [yes.size(), voters.size()]
	_refresh_phase_ui()


## Our slot in the server's ids array; -1 before we're counted in.
func _my_claim_index() -> int:
	return _claim_ids.find(Net.socket_id)


## Do we own this pixel? Everything is communal until the land is divided.
func _claim_mine(r: int, c: int) -> bool:
	if _claim_phase != "edit":
		return true
	var me := _my_claim_index()
	return me >= 0 and _claim_own.size() > r * PX_W + c and _claim_own[r * PX_W + c] == me


static func _claim_color(idx: int) -> Color:
	return Color(CLAIM_COLORS[idx % CLAIM_COLORS.size()])


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"creativePaint":
			var painted := _norm_layers(data)
			if not _playing and not painted.is_empty():
				_adopt_size(painted["gs"])
				if not _same_layers(painted["layers"]):
					_adopt_paint(painted["layers"])
		"paintCleared":
			if not _playing:
				# A size change also lands here; pick up the new size first
				_adopt_size(_settings_gs())
				_adopt_paint(_default_layers())
		"gameSettings":
			if not _playing:
				_adopt_size(_settings_gs())
		"spawnZones":
			_zones = data if data is Dictionary else {}
			if _painter:
				_painter.queue_redraw()
			if _playing:
				_make_deadzone_marker()
		"startVote":
			_apply_start_vote(data)
		"claimState":
			_apply_claim_state(data)
		"claimTick":
			_apply_claim_tick(data)
		"editCursor":
			if not _playing and data is Dictionary:
				_cursors[str(data.get("id", ""))] = {
					"r": int(data.get("r", 0)), "c": int(data.get("c", 0)),
					"t": Time.get_ticks_msec(),
				}
		"creativeGrid":
			var grid := _norm_layers(data)
			if not grid.is_empty() and (not _playing or not _same_layers(grid["layers"])):
				_adopt_size(grid["gs"])
				_start_play(grid["layers"], [], false)
		"gameEnded":
			# Full wipe, grid included: everyone goes back to the lobby so the
			# next map starts from a blank canvas.
			get_tree().change_scene_to_file("res://UI/main_menu.tscn")
		"terrainEdit":
			if _playing and data is Dictionary and terrain:
				_replay_edit(data)


## One replayed brush stroke from the server (or the join snapshot).
func _replay_edit(e: Dictionary) -> void:
	var at := Vector3(e.get("x", 0.0), e.get("y", 0.0), e.get("z", 0.0))
	var r := float(e.get("r", BRUSH_RADIUS))
	var st := float(e.get("st", 1.0))
	if str(e.get("m", "add")) == "smooth":
		terrain.smooth_brush(at, r, st)
	else:
		terrain.apply_brush(at, r, float(e.get("s", -1.0)), st)


## JSON round-trips ints as floats — compare numerically, not by hash.
func _same_layers(other: Array) -> bool:
	if other.size() != _layers.size():
		return false
	for li in _layers.size():
		var a: Array = _layers[li]
		var b: Array = other[li]
		if a.size() != b.size():
			return false
		for i in a.size():
			if int(a[i]) != int(b[i]):
				return false
	return true


func _start_play(layers: Array, edits: Array, announce: bool) -> void:
	_layers = layers
	_status.text = "generating terrain..."
	await get_tree().process_frame  # let the label paint before the long build
	if terrain == null:
		terrain = VoxelTerrain.new()
		add_child(terrain)
	terrain.configure(PX_W, PX_H)
	terrain.deadzone_centers = _home_pixels().map(_px_world)
	terrain.build_from_layers(_layers)
	_make_deadzone_marker()
	for e in edits:
		if e is Dictionary:
			_replay_edit(e)
	if announce:
		Net.emit_event("creativeGrid", _grid_payload())
	_editor_layer.visible = false
	Net.emit_event("editing", false)
	if not _playing:
		_playing = true
		_spawn_gameplay()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Instantiate the same gameplay stack testworld wires in its scene file.
func _spawn_gameplay() -> void:
	player = PlayerScene.instantiate()
	player.name = "player"
	var spawns := _spawn_points()
	player.spawn_points = spawns
	player.respawn_provider = _zone_respawn
	var zp: Variant = _zone_respawn()
	player.position = zp if zp is Vector3 else spawns.pick_random()
	add_child(player)

	var sync := Node.new()
	sync.name = "MultiplayerSync"
	sync.set_script(load("res://Net/multiplayer_sync.gd"))
	sync.player = player
	add_child(sync)

	var items := Node3D.new()
	items.name = "WorldItems"
	items.set_script(load("res://Items/world_items.gd"))
	items.player = player
	add_child(items)

	var proj := Node3D.new()
	proj.name = "WorldProjectiles"
	proj.set_script(load("res://Items/projectiles.gd"))
	proj.player = player
	add_child(proj)

	var builds := Node3D.new()
	builds.name = "WorldBuilds"
	builds.set_script(load("res://Items/builds.gd"))
	add_child(builds)

	var props := Node3D.new()
	props.name = "WorldProps"
	props.set_script(load("res://Items/props.gd"))
	add_child(props)

	var castles := Node3D.new()
	castles.name = "WorldCastles"
	castles.set_script(load("res://Items/castle.gd"))
	add_child(castles)

	var vehicles := Node3D.new()
	vehicles.name = "WorldVehicles"
	vehicles.set_script(load("res://Vehicles/world_vehicles.gd"))
	vehicles.player = player
	add_child(vehicles)

	var generators := Node3D.new()
	generators.name = "WorldGenerators"
	generators.set_script(load("res://Items/generators.gd"))
	generators.player = player
	add_child(generators)

	var turrets := Node3D.new()
	turrets.name = "WorldTurrets"
	turrets.set_script(load("res://Items/turrets.gd"))
	turrets.player = player
	add_child(turrets)

	var critters := Node3D.new()
	critters.name = "WorldCritters"
	critters.set_script(load("res://Items/critters.gd"))
	critters.player = player
	add_child(critters)

	var hud := HudScene.instantiate()
	hud.sync_node = sync
	add_child(hud)

	# Dust motes: drift around the player while enclosed, catching the light
	# where a cave opens up (the Compatibility renderer has no real volumetrics)
	_motes = CPUParticles3D.new()
	_motes.amount = 70
	_motes.lifetime = 7.0
	_motes.preprocess = 3.0
	_motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_motes.emission_box_extents = Vector3(8, 4.5, 8)
	_motes.gravity = Vector3(0, -0.05, 0)
	_motes.direction = Vector3(0, 0, 0)
	_motes.spread = 180.0
	_motes.initial_velocity_min = 0.05
	_motes.initial_velocity_max = 0.35
	var mote_mesh := QuadMesh.new()
	mote_mesh.size = Vector2(0.05, 0.05)
	var mote_mat := StandardMaterial3D.new()
	mote_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote_mat.albedo_color = Color(1.0, 0.97, 0.85, 0.4)
	mote_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mote_mesh.material = mote_mat
	_motes.mesh = mote_mesh
	_motes.emitting = false
	add_child(_motes)

	# White-out overlay for the fog boundary (above the 3D world, below the HUD)
	var fog_layer := CanvasLayer.new()
	fog_layer.layer = 0
	add_child(fog_layer)
	_fog_rect = ColorRect.new()
	_fog_rect.color = Color(1, 1, 1, 0.0)
	_fog_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fog_layer.add_child(_fog_rect)
	_make_fog_shells()


## Fake volumetric fog outside the play bounds: nested rectangular shells of
## translucent white haze (the Compatibility renderer has no FogVolume).
## From inside they read as a distant fog bank; walking out you pass through
## shell after shell, so the whiteout builds gradually instead of snapping on.
func _make_fog_shells() -> void:
	var shader := Shader.new()
	shader.code = FOG_WALL_SHADER
	var wall_h := 90.0
	var wall_y := wall_h * 0.5 - 16.0  # from below the slabs up past their tops
	# Banks offset from EACH axis of the painted rectangle, so a 96x48 map gets
	# an oblong of fog around it instead of a square drawn on its longest side.
	# [offset past the edge, opacity] — denser the deeper into the fog you are
	# (the first bank stands just past the boundary bowl's rim at +16).
	for ring in [[18.0, 0.05], [26.0, 0.08], [34.0, 0.12], [43.0, 0.16], [56.0, 0.24]]:
		var m: float = ring[0]
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("alpha_max", ring[1])
		for i in 4:
			# Sides 0/2 stand off the Z edges and span X; 1/3 the other way.
			var across: float = (_half_x() if i % 2 == 0 else _half_z()) + m
			var out: float = (_half_z() if i % 2 == 0 else _half_x()) + m
			var mi := MeshInstance3D.new()
			var quad := QuadMesh.new()
			quad.size = Vector2(across * 2.0 + 10.0, wall_h)
			mi.mesh = quad
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.rotation.y = i * PI / 2.0
			mi.position = Vector3(0, wall_y, 0) + Basis(Vector3.UP, i * PI / 2.0) * Vector3(0, 0, -out)
			add_child(mi)


## Spawn points ARE the markers placed in the map creator — no scatter. Each
## sits on its own pixel's painted surface (the claim carved that column open,
## so it's always daylight). Everyone gets one automatically, so this is only
## empty if the map was made before markers existed.
func _spawn_points() -> Array:
	var points: Array = []
	for h in _home_pixels():
		var r := int(h[0])
		var c := int(h[1])
		points.append(Vector3(-_half_x() + c * 4.0 + 2.0, _surface_y(r, c) + 1.0,
			-_half_z() + r * 4.0 + 2.0))
	if points.is_empty():
		points.append(Vector3(0.0, _surface_y(PX_H / 2, PX_W / 2) + 1.0, 0.0))
	return points


## Half-extents of the painted region in meters (pixels are 4 m).
func _half_x() -> float:
	return PX_W * 2.0


func _half_z() -> float:
	return PX_H * 2.0


# --- Home base deadzone ------------------------------------------------------

## Every claimed spawn pixel (possibly none).
func _home_pixels() -> Array:
	var out: Array = []
	for id in _zones:
		var z: Array = _zones[id]
		out.append([int(z[0]), int(z[1])])
	return out


## Our own claim, or null if we haven't placed one yet.
func _my_px() -> Variant:
	var z: Variant = _zones.get(Net.socket_id)
	return [int(z[0]), int(z[1])] if z is Array else null


func _px_world(h: Array) -> Vector3:
	return Vector3(-_half_x() + int(h[1]) * 4.0 + 2.0, 0.0, -_half_z() + int(h[0]) * 4.0 + 2.0)


func _in_deadzone(r: int, c: int) -> bool:
	for h in _home_pixels():
		if absi(r - int(h[0])) <= DEADZONE_PX and absi(c - int(h[1])) <= DEADZONE_PX:
			return true
	return false


## Same test, but blind to everyone else's zones — the painter uses this so a
## rival's deadzone tint can't leak their spawn through the fog. Their ground
## is already unpaintable to you (it isn't yours), so nothing is lost.
func _in_own_deadzone(r: int, c: int) -> bool:
	var mine: Variant = _my_px()
	return mine is Array and absi(r - int(mine[0])) <= DEADZONE_PX \
		and absi(c - int(mine[1])) <= DEADZONE_PX


## Respawns land somewhere random inside YOUR zone. The zone is edit-protected,
## so the painted layer stack is still the truth about its surface height.
## Returns null with no claim — respawn_point() falls back to spawn_points.
func _zone_respawn() -> Variant:
	var mine: Variant = _my_px()
	if not mine is Array or _layers.is_empty():
		return null
	for _i in 16:
		var rr := clampi(int(mine[0]) + randi_range(-DEADZONE_PX, DEADZONE_PX), 0, PX_H - 1)
		var cc := clampi(int(mine[1]) + randi_range(-DEADZONE_PX, DEADZONE_PX), 0, PX_W - 1)
		# Any floor will do — a sunk map's is the basement, not the ground slab
		if _surface_y(rr, cc) < -14.0:
			continue  # pit
		return Vector3(-_half_x() + cc * 4.0 + 2.0, _surface_y(rr, cc) + 1.0, -_half_z() + rr * 4.0 + 2.0)
	return null


## Painted surface height at a pixel: 8 m slabs, surface ~1 m into the slab.
func _surface_y(r: int, c: int) -> float:
	if _layers.is_empty():
		return 1.0
	var top := -1
	for li in LAYERS:
		if _bit_at(_layers[li], r, c):
			top = li
	if top < 0:
		return -15.0
	if top < GROUND:
		return -7.0
	return float(top - GROUND) * 8.0 + 1.0


## In play a zone is just the patch respawns land on — no monolith. A faint
## boundary line on the ground marks where terrain tools stop working.
var _deadzone_node: Node3D

func _make_deadzone_marker() -> void:
	if _deadzone_node:
		_deadzone_node.queue_free()
	_deadzone_node = Node3D.new()
	add_child(_deadzone_node)
	if terrain:
		terrain.deadzone_centers = _home_pixels().map(_px_world)
	for h in _home_pixels():
		var at := _px_world(h)
		at.y = _surface_y(int(h[0]), int(h[1]))
		_deadzone_edge(at)


func _deadzone_edge(at: Vector3) -> void:
	var size := VoxelTerrain.DEADZONE_R * 2.0
	var edge_mat := StandardMaterial3D.new()
	edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge_mat.albedo_color = Color(0.55, 1.0, 0.75, 0.2)
	edge_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var h := VoxelTerrain.DEADZONE_R
	for side in 4:
		var band := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(size + 0.6, 0.6)
		band.mesh = quad
		band.material_override = edge_mat
		band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		band.rotation = Vector3(-PI / 2.0, side * PI / 2.0, 0)
		band.position = at + Vector3(0, 0.08, 0) \
			+ Basis(Vector3.UP, side * PI / 2.0) * Vector3(0, 0, -h)
		_deadzone_node.add_child(band)


# --- World backstops --------------------------------------------------------
# (riding a vehicle: world_vehicles.gd rescues the vehicle + driver instead)

func _physics_process(delta: float) -> void:
	if not _playing or player == null:
		return
	_update_fog_bounds()
	_update_ambience(delta)
	if player.vehicle != null:
		return
	# Backstop: anything that slips below the world snaps back to a spawn
	if player.global_position.y < KILL_Y:
		player.global_position = player.respawn_point()
		player.velocity = Vector3.ZERO
	# Filled-in terrain can embed the player (remote FILL strokes); the
	# depenetration then shoves them through the floor. Pop upward instead.
	var _bury_d: float = terrain.density_at(
		player.global_position + Vector3(0, 0.2, 0)) if terrain else 0.0
	if _bury_d > 0.55:
		player.global_position.y += 1.0
		player.velocity.y = maxf(player.velocity.y, 0.0)
		player.mark_bury(_bury_d, 1.0)


## Distance-based white-out past FOG_START; at FOG_WHITE the screen is fully
## white and the player (or their vehicle) is turned to face the center.
func _update_fog_bounds() -> void:
	if _fog_rect == null:
		return
	var hpos := Vector2(player.global_position.x, player.global_position.z)
	# How far OUTSIDE the painted rectangle you are, per axis: on a 96x48 map
	# the boundary has to be an oblong like the map is, not a square drawn
	# around its longest side.
	var d := maxf(absf(hpos.x) - _half_x(), absf(hpos.y) - _half_z())
	var f := clampf((d - FOG_MARGIN) / FOG_RAMP, 0.0, 1.0)
	if player.godmode or player.dead:
		f = 0.0
	_fog_f = f
	_fog_rect.color.a = f * f  # eases in, hits solid white right at the bound
	if _env_ref:
		# Thicken the ever-present base haze; the sky whites out with it
		_env_ref.fog_density = FOG_BASE + f * 0.05
		_env_ref.fog_sky_affect = 0.1 + 0.9 * f
	if f < 1.0 or hpos.length() < 1.0:
		return
	# Whited out: about-face toward the center (camera too, so W walks back)
	var dir := Vector3(-hpos.x, 0.0, -hpos.y).normalized()
	var yaw := atan2(-dir.x, -dir.z)
	if player.camera_rig:
		player.camera_rig.yaw = yaw
	if player.vehicle != null and is_instance_valid(player.vehicle):
		var veh: CharacterBody3D = player.vehicle
		var vspd := maxf(Vector2(veh.velocity.x, veh.velocity.z).length(), 12.0)
		veh.velocity.x = dir.x * vspd
		veh.velocity.z = dir.z * vspd
		veh.rotation.y = yaw
	else:
		var pspd := maxf(Vector2(player.velocity.x, player.velocity.z).length(), 8.0)
		player.velocity.x = dir.x * pspd
		player.velocity.z = dir.z * pspd


# --- Environment ------------------------------------------------------------

func _setup_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.95, 0.85)  # warm sun makes slopes read
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.55  # lower ambient: shading carries the shape
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Base haze: always on, so the boundary fog is a thickening of something
	# already there instead of an effect that snaps on at the edge
	e.fog_enabled = true
	e.fog_light_color = Color(1, 1, 1)
	e.fog_density = FOG_BASE
	e.fog_sky_affect = 0.1
	env.environment = e
	_env_ref = e
	add_child(env)
	_setup_ambience()


# --- Ambience ----------------------------------------------------------------
# Three beds, mixed live: open-air wind, a low cave drone that swaps in when
# you're enclosed, and a gale that ramps up as you push past the boundary.

func _looping_player(path: String, pitch: float, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var stream: AudioStreamOggVorbis = load(path).duplicate()
	stream.loop = true
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = db
	p.autoplay = true
	add_child(p)
	return p


func _setup_ambience() -> void:
	# CC0 wind loop (opengameart.org/content/wind-whoosh-loop)
	_wind = _looping_player("res://Audio/ambient_wind.ogg", 1.0, -16.0)
	# Same loop, slowed and detuned: the boundary gale over the top of it
	_gale = _looping_player("res://Audio/ambient_wind.ogg", 0.78, -60.0)
	# Cave drone: generated brown noise, so there's nothing tonal in it to
	# oscillate — just a low, slow rush.
	_cave = AudioStreamPlayer.new()
	_cave.stream = _make_cave_noise()
	_cave.volume_db = -60.0
	_cave.autoplay = true
	add_child(_cave)


## Brown noise (integrated white noise, then heavily low-passed) rendered to a
## looping 16-bit sample at load. The tail is cross-faded into the head so the
## loop point is inaudible.
func _make_cave_noise() -> AudioStreamWAV:
	var rate := 22050
	var total := rate * 8
	var fade := rate * 2
	var loop_len := total - fade
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260810
	var buf := PackedFloat32Array()
	buf.resize(total)
	var brown := 0.0
	var slow := 0.0
	for i in total:
		brown = clampf(brown * 0.995 + rng.randf_range(-1.0, 1.0) * 0.03, -1.0, 1.0)
		slow += (brown - slow) * 0.03   # only the lowest band survives
		buf[i] = slow
	for i in fade:
		var t := float(i) / float(fade)
		buf[i] = buf[i] * t + buf[loop_len + i] * (1.0 - t)
	var peak := 0.0001
	for i in loop_len:
		peak = maxf(peak, absf(buf[i]))
	var data := PackedByteArray()
	data.resize(loop_len * 2)
	for i in loop_len:
		var v := int(clampf(buf[i] / peak, -1.0, 1.0) * 32000.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = loop_len
	return wav


## Roof/wall probes from the head: the share that hit something nearby is how
## enclosed you are. Cheap enough at 6 Hz, and it reacts to dug-out caves and
## built structures alike because it's just raycasts against the world.
func _probe_confinement() -> void:
	var space := player.get_world_3d().direct_space_state
	var from := player.global_position + Vector3(0, 1.0, 0)
	var blocked := 0
	for dir in PROBE_DIRS:
		var q := PhysicsRayQueryParameters3D.create(from, from + dir.normalized() * PROBE_DIST)
		q.exclude = [player.get_rid()]
		if not space.intersect_ray(q).is_empty():
			blocked += 1
	var target := float(blocked) / float(PROBE_DIRS.size())
	# Only a real roof counts as a cave; one wall nearby shouldn't muffle you
	_confine_target = smoothstep(0.35, 1.0, target)


var _confine_target := 0.0
var _fog_f := 0.0

func _update_ambience(delta: float) -> void:
	if _wind == null or player == null:
		return
	_probe_cd -= delta
	if _probe_cd <= 0.0:
		_probe_cd = 0.16
		_probe_confinement()
	_confine = lerpf(_confine, _confine_target, minf(1.0, AMBIENCE_LERP * delta))
	# Wind drops away indoors, and lifts a little out in the open boundary
	_wind.volume_db = lerpf(-16.0 + 4.0 * _fog_f, -34.0, _confine)
	_cave.volume_db = -60.0 if _confine < 0.02 else lerpf(-40.0, -13.0, _confine)
	# The gale ignores confinement: outside the bounds there's nothing to hide in
	_gale.volume_db = -60.0 if _fog_f < 0.01 else lerpf(-30.0, -5.0, _fog_f)
	# Dust hangs in enclosed air
	if _motes:
		_motes.emitting = _confine > 0.35
		_motes.global_position = player.global_position


# --- Editor UI ---------------------------------------------------------------

func _build_editor_ui() -> void:
	_editor_layer = CanvasLayer.new()
	add_child(_editor_layer)
	var bg := ColorRect.new()
	bg.color = Color("#0c0e12")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_editor_layer.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_editor_layer.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "MAP CREATOR"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(title)

	# Phase clock: the land grab's countdown, then the sculpting one
	_claim_banner = Label.new()
	_claim_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_claim_banner.add_theme_font_size_override("font_size", 20)
	_claim_banner.visible = false
	box.add_child(_claim_banner)

	_hint = Label.new()
	_hint.text = HINT_PAINT
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 16)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(_hint)

	# Brush size + spire mode, above the canvas
	var opts := HBoxContainer.new()
	opts.alignment = BoxContainer.ALIGNMENT_CENTER
	opts.add_theme_constant_override("separation", 6)
	box.add_child(opts)
	_brush_row = opts
	var brush_lbl := Label.new()
	brush_lbl.text = "BRUSH"
	brush_lbl.add_theme_font_size_override("font_size", 16)
	brush_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	opts.add_child(brush_lbl)
	var brush_group := ButtonGroup.new()
	for shape in [1, 2, 3, 4]:
		var bb := Button.new()
		bb.text = "%d" % shape
		bb.toggle_mode = true
		bb.button_group = brush_group
		bb.focus_mode = Control.FOCUS_NONE
		bb.custom_minimum_size = Vector2(34, 28)
		bb.button_pressed = shape == _brush
		bb.pressed.connect(func(): _brush = shape)
		opts.add_child(bb)
	# FILL: the whole column at once, for shaping a seeded world fast. Off it
	# sits greyed out of the way; armed it goes bright orange, because with it
	# on every click does something far bigger than a brush stroke.
	var fill := Button.new()
	fill.text = "FILL"
	fill.toggle_mode = true
	fill.focus_mode = Control.FOCUS_NONE
	fill.button_pressed = _fill_mode
	fill.custom_minimum_size = Vector2(110, 28)
	# A toggled Button draws its label with font_pressed_color, so every state
	# has to be set or the "on" look only survives until the mouse moves.
	var tint := func(on: bool) -> void:
		var c := Color("#1a1006") if on else Color(1, 1, 1, 0.32)
		for slot in ["font_color", "font_pressed_color", "font_hover_color",
				"font_hover_pressed_color", "font_focus_color"]:
			fill.add_theme_color_override(slot, c)
		for slot in ["normal", "pressed", "hover", "focus"]:
			if on:
				fill.add_theme_stylebox_override(slot, Style.panel_box(FILL_ON, 4))
			else:
				fill.remove_theme_stylebox_override(slot)
	fill.toggled.connect(func(on: bool):
		_fill_mode = on
		tint.call(on)
		_update_hint())
	tint.call(_fill_mode)
	opts.add_child(fill)

	var canvas_row := HBoxContainer.new()
	canvas_row.alignment = BoxContainer.ALIGNMENT_CENTER
	canvas_row.add_theme_constant_override("separation", 14)
	box.add_child(canvas_row)

	# Chat docked beside the canvas, so painters talk in the same column
	var chat := PanelContainer.new()
	chat.set_script(load("res://UI/chat_box.gd"))
	chat.custom_minimum_size = Vector2(250, 0)
	canvas_row.add_child(chat)

	_painter = PixelPainter.new()
	_painter.owner_scene = self
	_painter.fit()
	canvas_row.add_child(_painter)

	# Layer chips beside the canvas, top slab first; click or scroll to switch
	var layer_col := VBoxContainer.new()
	layer_col.alignment = BoxContainer.ALIGNMENT_CENTER
	layer_col.add_theme_constant_override("separation", 6)
	canvas_row.add_child(layer_col)
	_layer_col = layer_col
	_layer_buttons.resize(LAYERS)
	for li in range(LAYERS - 1, -1, -1):
		var lb := Button.new()
		lb.text = LAYER_NAMES[li]
		lb.toggle_mode = true
		lb.focus_mode = Control.FOCUS_NONE
		lb.custom_minimum_size = Vector2(88, 34)
		lb.add_theme_color_override("font_color", Color(PixelPainter.LAYER_FILL[li]))
		lb.pressed.connect(func(): _set_layer(li))
		layer_col.add_child(lb)
		_layer_buttons[li] = lb
	var bedrock_chip := Label.new()
	bedrock_chip.text = "BEDROCK"
	bedrock_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bedrock_chip.custom_minimum_size = Vector2(88, 0)
	bedrock_chip.add_theme_font_size_override("font_size", 16)
	bedrock_chip.add_theme_color_override("font_color", Color(1, 1, 1, 0.3))
	layer_col.add_child(bedrock_chip)

	# SPAWN chip: click the canvas to drop the spawn (a building generates there)
	_spawn_button = Button.new()
	_spawn_button.text = "⌂ SPAWN"
	_spawn_button.toggle_mode = true
	_spawn_button.focus_mode = Control.FOCUS_NONE
	_spawn_button.custom_minimum_size = Vector2(88, 34)
	_spawn_button.add_theme_color_override("font_color", Color("#7dedb0"))
	_spawn_button.pressed.connect(func():
		_spawn_mode = _spawn_button.button_pressed
		if _painter:
			_painter.queue_redraw())
	layer_col.add_child(_spawn_button)
	_set_layer(_active_layer)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var gen := Button.new()
	gen.text = "START GAME"
	gen.custom_minimum_size = Vector2(220, 40)
	gen.pressed.connect(func(): Net.emit_event("requestGenerate"))
	buttons.add_child(gen)
	_start_button = gen

	# Mid-grab, START GAME is replaced by the one that stops the grab.
	var stop := Button.new()
	stop.text = "END GRAB"
	stop.custom_minimum_size = Vector2(220, 40)
	stop.visible = false
	stop.pressed.connect(func(): Net.emit_event("endClaim"))
	buttons.add_child(stop)
	_end_claim_button = stop

	# ...and while the room is being polled on it, by the poll itself.
	var vote := HBoxContainer.new()
	vote.alignment = BoxContainer.ALIGNMENT_CENTER
	vote.add_theme_constant_override("separation", 8)
	vote.visible = false
	buttons.add_child(vote)
	_vote_row = vote
	_vote_label = Label.new()
	_vote_label.add_theme_font_size_override("font_size", 20)
	_vote_label.add_theme_color_override("font_color", Color("#ffd54a"))
	_vote_label.custom_minimum_size = Vector2(160, 40)
	_vote_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vote.add_child(_vote_label)
	for opt in [["YES", true, Color("#7dedb0")], ["NO", false, Color("#ff8a7d")]]:
		var vb := Button.new()
		vb.text = str(opt[0])
		vb.focus_mode = Control.FOCUS_NONE
		vb.custom_minimum_size = Vector2(90, 40)
		vb.add_theme_color_override("font_color", opt[2])
		vb.pressed.connect(func(): Net.emit_event("startVoteCast", bool(opt[1])))
		vote.add_child(vb)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color("#7dedb0"))
	box.add_child(_status)


const HINT_PAINT := "[LMB - Paint]  [RMB - Erase]  [Scroll - Layer]"
const HINT_FILL := "[LMB - Fill]  [RMB - Strip]  [Scroll - Layer]"

func _update_hint() -> void:
	if _hint:
		_hint.text = HINT_FILL if _fill_mode else HINT_PAINT


func _set_layer(li: int) -> void:
	_active_layer = clampi(li, 0, LAYERS - 1)
	_spawn_mode = false
	if _spawn_button:
		_spawn_button.button_pressed = false
	for i in LAYERS:
		if _layer_buttons[i]:
			_layer_buttons[i].button_pressed = i == _active_layer
	if _painter:
		_painter.queue_redraw()


func disarm_spawn() -> void:
	_spawn_mode = false
	if _spawn_button:
		_spawn_button.button_pressed = false
	if _painter:
		_painter.queue_redraw()


func change_layer(dir: int) -> void:
	_set_layer(_active_layer + dir)


## Brush footprints, in cells relative to the cursor: a single pixel, a plus,
## then filled discs 5 and 7 pixels across.
func brush_offsets() -> Array:
	if _brush <= 1:
		return [Vector2i(0, 0)]
	if _brush == 2:
		return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var rad := 2 if _brush == 3 else 3
	var limit := (rad + 0.5) * (rad + 0.5)
	var out: Array = []
	for dy in range(-rad, rad + 1):
		for dx in range(-rad, rad + 1):
			if dx * dx + dy * dy <= limit:
				out.append(Vector2i(dx, dy))
	return out


## One canvas cell. Normally that's a single bit on the active layer; with FILL
## armed a click works the whole column instead — left builds the cell solid
## from basement to roof, right takes the sky back off it and leaves the ground
## and the basement standing. The home deadzone refuses paint entirely.
func paint_cell(r: int, c: int, fill: bool) -> void:
	if _in_deadzone(r, c) or not _claim_mine(r, c):
		return
	var i := r * _wc() + (c >> 5)
	var bit := 1 << (31 - (c & 31))
	if _fill_mode:
		for li in LAYERS:
			if fill or li <= GROUND:
				_layers[li][i] = int(_layers[li][i]) | bit
			else:
				_layers[li][i] = int(_layers[li][i]) & ~bit
		return
	var rows: Array = _layers[_active_layer]
	if fill:
		rows[i] = int(rows[i]) | bit
	else:
		rows[i] = int(rows[i]) & ~bit


class PixelPainter extends Control:
	# Fill colors bottom-up: ground, main, +1, +2 (lighter = higher)
	const LAYER_FILL := ["#4a3226", "#8a5a3a", "#c78b5e", "#dfa878", "#f0cb96"]
	const BG := Color("#1a2030")
	const PIT := Color("#07080c")
	const GHOST_ALPHA := 0.3
	# Claim-phase drawing (an inner class can't see the outer script's consts)
	const FOG_COL := Color("#05060a")
	const OWN_FREE := -1
	var owner_scene: Node
	var cell := 14.0   # canvas cell size, shrinks to fit big grids on screen
	var _paint_value := -1  # -1 idle, 1 fill, 0 erase

	## Size the canvas to the CURRENT grid: big maps get smaller cells so the
	## whole board still fits the screen. Call after owner_scene is set and
	## whenever the grid size changes.
	func fit() -> void:
		var w: int = owner_scene.PX_W if owner_scene else 32
		var h: int = owner_scene.PX_H if owner_scene else 32
		cell = maxf(5.0, floorf(560.0 / maxi(w, h)))
		custom_minimum_size = Vector2(w * cell, h * cell)

	func _col(v: float) -> int:
		return clampi(int(v / cell), 0, (owner_scene.PX_W if owner_scene else 32) - 1)

	func _row(v: float) -> int:
		return clampi(int(v / cell), 0, (owner_scene.PX_H if owner_scene else 32) - 1)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
				owner_scene.change_layer(-1)
				accept_event()
				return
			if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				owner_scene.change_layer(1)
				accept_event()
				return
			if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				_paint_value = 1
			elif event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
				_paint_value = 0
			elif not event.pressed:
				_paint_value = -1
			_paint_at(event.position)
		elif event is InputEventMouseMotion:
			owner_scene._on_hover(_row(event.position.y), _col(event.position.x))
			if _paint_value != -1:
				_paint_at(event.position)

	func _paint_at(pos: Vector2) -> void:
		# During the land grab the board is a game, not a canvas: mouse is dead.
		if _paint_value == -1 or owner_scene._claim_phase == "claim":
			return
		var c := _col(pos.x)
		var r := _row(pos.y)
		if owner_scene._spawn_mode:
			# The server owns zones: it rejects overlaps and broadcasts the set
			Net.emit_event("setSpawn", {"r": r, "c": c} if _paint_value == 1 else null)
			owner_scene.disarm_spawn()   # one click, one spawn
			return
		var w: int = owner_scene.PX_W
		var h: int = owner_scene.PX_H
		for off: Vector2i in owner_scene.brush_offsets():
			var rr := r + off.y
			var cc := c + off.x
			if rr >= 0 and rr < h and cc >= 0 and cc < w:
				owner_scene.paint_cell(rr, cc, _paint_value == 1)
		owner_scene._on_painted()
		queue_redraw()

	func _bit(li: int, r: int, c: int) -> bool:
		return owner_scene._bit_at(owner_scene._layers[li], r, c)

	## Highest solid layer in this column, -1 for a hole clean through.
	func _top(r: int, c: int) -> int:
		for li in range(LAYERS - 1, -1, -1):
			if _bit(li, r, c):
				return li
		return -1

	## Three layers, three different languages, so a glance tells you where you
	## are in the stack:
	##
	##   the floor below you   a dim fill, like ground seen through a grating
	##   the layer you edit    solid colour, the only saturated thing on screen
	##   the roof above you    an inset outline, drawn INSIDE the cell
	##
	## Nothing else is drawn. Stacking every layer as a ghost was the problem —
	## five translucent washes read as one muddy colour and you cannot tell a
	## floor under your feet from a slab over your head.
	##
	## During the claim phase, territory tints the whole board and live trails
	## draw over it. Once the land is divided the fog IS the territory line, so
	## the wash comes off and the colour goes back to describing terrain.
	func _draw() -> void:
		var active: int = owner_scene._active_layer
		var CELL := cell
		var phase: String = owner_scene._claim_phase
		var own: PackedInt32Array = owner_scene._claim_own
		var me: int = owner_scene._my_claim_index()
		var fogging := phase == "edit"
		var inset := maxf(1.0, CELL * 0.22)
		for r in owner_scene.PX_H:
			for c in owner_scene.PX_W:
				var rect := Rect2(c * CELL, r * CELL, CELL - 1, CELL - 1)
				var idx: int = r * owner_scene.PX_W + c
				var holder: int = own[idx] if idx < own.size() else OWN_FREE
				if fogging and holder != me:
					draw_rect(rect, FOG_COL)
					continue
				var here := _bit(active, r, c)
				var below := active > 0 and _bit(active - 1, r, c)
				var col := BG
				if here:
					col = Color(LAYER_FILL[active])
				elif below:
					col = BG.lerp(Color(LAYER_FILL[active - 1]), 0.42)
				elif _top(r, c) < 0:
					col = PIT              # nothing under you for the whole stack
				# Territory wash, during the grab only
				if holder >= 0 and phase == "claim":
					col = col.lerp(owner_scene._claim_color(holder), 0.5 if holder == me else 0.3)
				# Home deadzone: off-limits to the brush, in play as well. Only
				# ever YOUR OWN — a rival's red block would give their spawn
				# away, fog or no fog, and the fog lifts the moment the map
				# generates.
				if owner_scene._in_own_deadzone(r, c):
					col = col.lerp(Color(1.0, 0.25, 0.25), 0.35)
				draw_rect(rect, col)
				# Roof: an outline INSIDE the cell, never a fill, so a slab over
				# your head cannot be mistaken for one under your feet.
				if active < LAYERS - 1 and _bit(active + 1, r, c):
					draw_rect(rect.grow(-inset), Color(LAYER_FILL[active + 1]), false,
						maxf(1.0, CELL * 0.12))
		if phase == "claim":
			_draw_claim(CELL, me)
		# Spawn zones: only ever your own. Where the others chose to land is
		# theirs to know — the fog hides it during the edit phase, and this
		# keeps hiding it through the moment the fog lifts and the map goes up.
		var mine: Variant = owner_scene._my_px()
		if mine is Array:
			var srect := Rect2(int(mine[1]) * CELL, int(mine[0]) * CELL, CELL - 1, CELL - 1)
			draw_rect(srect, Color("#7dedb0"))
			draw_rect(srect.grow(-3), Color("#0c2018"))
			draw_rect(srect.grow(-5), Color("#7dedb0"))
		# Co-painters' live cursors: an outline where they're hovering (the
		# claim phase draws its own, so don't double up)
		var now := Time.get_ticks_msec()
		if phase == "claim":
			return
		for cid in owner_scene._cursors:
			var cur: Dictionary = owner_scene._cursors[cid]
			var age := now - int(cur["t"])
			if age > 2500:
				continue
			var ccol := Color("#7fb2ff", clampf(1.0 - age / 2500.0 * 0.6, 0.0, 1.0))
			draw_rect(Rect2(int(cur["c"]) * CELL, int(cur["r"]) * CELL, CELL - 1, CELL - 1),
				ccol, false, 2.0)

	## Live trails and cursors during the land grab. A trail is the fragile
	## part — anyone who touches it, its owner included, wipes it out — so it
	## draws brighter and thinner than the ground it will become.
	func _draw_claim(CELL: float, me: int) -> void:
		var w: int = owner_scene.PX_W
		for idx in owner_scene._claim_trail:
			var pi: int = owner_scene._claim_trail[idx]
			var col: Color = owner_scene._claim_color(pi)
			var rect := Rect2((int(idx) % w) * CELL, (int(idx) / w) * CELL, CELL - 1, CELL - 1)
			draw_rect(rect, col.lightened(0.25))
			draw_rect(rect.grow(-maxf(1.0, CELL * 0.28)), Color(1, 1, 1, 0.85))
		var dead: Array = owner_scene._claim_dead
		for pi in owner_scene._claim_pos.size():
			var p: Variant = owner_scene._claim_pos[pi]
			if not p is Array or (p as Array).size() != 2 or int(p[0]) < 0:
				continue
			if pi < dead.size() and bool(dead[pi]):
				continue   # out of the round: no head on the board
			var crect := Rect2(int(p[1]) * CELL, int(p[0]) * CELL, CELL - 1, CELL - 1)
			draw_rect(crect, owner_scene._claim_color(pi))
			draw_rect(crect, Color.WHITE if pi == me else Color(0, 0, 0, 0.75), false, 2.0)
