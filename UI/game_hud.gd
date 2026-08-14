extends CanvasLayer

## In-game HUD (PORT_BLUEPRINT.md §6.3/§6.4): health/sprint/jump meters,
## inventory, "YOU'RE IT" banner, hold-Tab scoreboard, chat (T to talk).

@export var sync_node: Node

@onready var _it_label: Label = $ItLabel
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _scoreboard_rows: VBoxContainer = $Scoreboard/Margin/Rows
@onready var _version_label: Label = $VersionLabel
@onready var _update_banner: Label = $UpdateBanner
@onready var _chat_log: VBoxContainer = $ChatLog
@onready var _chat_input: LineEdit = $ChatInput
@onready var _inventory_hud: HBoxContainer = $InventoryHud

const CHAT_MAX_ROWS := 8      # web: chatLog keeps the last 8 rows
const CHAT_LIFETIME := 120.0  # seconds a row lingers on screen
const CHAT_HISTORY := 100     # rows kept for the scrollback
const CMD_COLOR := Color("#ffd54a")
const Style := preload("res://UI/ui_style.gd")
const SettingsPanel := preload("res://UI/settings_panel.gd")
# Web getColorForItem: category border colors
const ITEM_COLORS := {
	"grapple": "#44ff44", "launch_pad": "#44ff44", "boost_pad": "#44ff44", "teleporter": "#44ff44",
	"machinegun": "#ff4444", "rocket": "#ff4444", "mines": "#ff4444", "crowbot": "#ff4444",
	"block": "#ffff44", "wall": "#ffff44", "ramp": "#ffff44", "platform": "#ffff44", "bridge_gun": "#ffff44",
	"terragun": "#ffff44",
}

## Render deploy hook — kicks a server redeploy (used when the server is the
## stale side). Owners consider this key non-sensitive for this project.
const DEPLOY_HOOK := "https://api.render.com/deploy/srv-d9s2kkegekts73faq3vg?key=psfptLVM8D4"

var _offer_pull := false
var _offer_server_kick := false
var _meters: VBoxContainer
var _meter_fills: Array = []
var _esc_menu: PanelContainer
var _conn_pill: PanelContainer
var _conn_style: StyleBoxFlat
var _settings_box: PanelContainer
var _gear_btn: Button
var _health_label: Label
var _death_label: Label
var _last_hp := -1
var _chat_history: Array = []   # bbcode rows, oldest first
var _chat_scroll: PanelContainer
var _chat_scroll_rows: VBoxContainer
var _kills: Dictionary = {}     # id -> confirmed kills (server-authoritative)


func _ready() -> void:
	_it_label.visible = false
	_scoreboard.visible = false
	_update_banner.visible = false
	_version_label.text = "%s  %s" % [Net.version_text(), Net.git_commit()]
	if sync_node:
		sync_node.scores_changed.connect(_refresh)
		sync_node.holder_changed.connect(func(_id): _refresh(sync_node.scores))
		sync_node.version_mismatch.connect(_on_version_mismatch)
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_input.text_changed.connect(_on_chat_text_changed)
	_chat_input.focus_exited.connect(_close_chat)
	Net.event_received.connect(_on_net_event)
	if sync_node and sync_node.player:
		var items: Node = sync_node.player.get_node_or_null("ItemController")
		if items:
			items.inventory_changed.connect(_refresh_inventory)
	_build_meters()
	_build_esc_menu()
	_build_conn_pill()
	_build_slayer_hud()
	_build_scrollback()
	_build_vote_row()
	_refresh_vote(Net.end_vote)
	# Newest row sits against the input and the column grows UPWARD, so a long
	# kill feed runs off the top of the screen instead of over the input box.
	_chat_log.alignment = BoxContainer.ALIGNMENT_END
	_hydrate_chat()
	# Full-screen shader effects (sci-fi drone view, damage datamosh)
	var fx := Node.new()
	fx.name = "ScreenFX"
	fx.set_script(load("res://UI/screen_fx.gd"))
	add_child(fx)
	# Dynamic 8-bit soundtrack: intensity follows proximity + damage
	var music := Node.new()
	music.name = "DynamicMusic"
	music.set_script(load("res://Audio/dynamic_music.gd"))
	music.sync_node = sync_node
	add_child(music)


func _on_version_mismatch(server_build: String, _client_build: String) -> void:
	_update_banner.visible = true
	_update_banner.text = "Version differs from server - checking who's behind..."
	# Let the banner render before blocking on git.
	await get_tree().process_frame
	_diagnose_mismatch(server_build)


## Uses commit ancestry to determine WHO is out of date:
## server's commit is an ancestor of ours -> the server is behind (offer F10);
## ours is an ancestor of the server's   -> we are behind (offer F9).
func _diagnose_mismatch(server_build: String) -> void:
	var dir := ProjectSettings.globalize_path("res://")
	OS.execute("git", ["-C", dir, "fetch", "--quiet", "origin"], [], true)
	var server_is_old := OS.execute("git", ["-C", dir, "merge-base", "--is-ancestor", server_build, "HEAD"], [], true) == 0
	var we_are_old := OS.execute("git", ["-C", dir, "merge-base", "--is-ancestor", "HEAD", server_build], [], true) == 0
	if server_is_old:
		_offer_server_kick = true
		_update_banner.text = "SERVER IS OUT OF DATE (server %s, you %s)\nPress F10 to trigger a server redeploy (~2 min) - you'll be reconnected automatically." % [server_build, Net.git_commit()]
	elif we_are_old:
		_offer_pull = true
		_update_banner.text = "YOUR GAME IS OUT OF DATE (you %s, server %s)\nPress F9 to update (runs git pull), then restart the game." % [Net.git_commit(), server_build]
	else:
		_offer_pull = true
		_update_banner.text = "Your copy and the server have DIVERGED (you %s, server %s)\nPress F9 to try updating - if that fails, sort it out in git together." % [Net.git_commit(), server_build]


func _hotkey_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if _chat_input.visible:
			# LineEdit handles typing + Enter; we only intercept Esc to close.
			if event.keycode == KEY_ESCAPE:
				_close_chat()
				get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_T and not event.echo:
			_open_chat()
			get_viewport().set_input_as_handled()  # don't type the opening "t"
		elif _offer_pull and event.keycode == KEY_F9:
			_run_git_pull()
		elif _offer_server_kick and event.keycode == KEY_F10:
			_trigger_server_deploy()


# --- Chat (web §6.5: T to talk, Enter sends, Esc/unfocus closes) ---

func _open_chat() -> void:
	_chat_input.visible = true
	_chat_input.text = ""
	_on_chat_text_changed("")
	_chat_input.call_deferred("grab_focus")
	_show_scrollback(true)
	# Free the mouse so the scrollback can actually be scrolled
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_chat() -> void:
	if not _chat_input.visible:
		return
	_chat_input.visible = false
	_chat_input.release_focus()
	_show_scrollback(false)
	var god: Node = get_node_or_null("GodMenu")
	if not _esc_menu.visible and not (god and god.visible):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Ending a match is a poll, and typing an answer to it mid-fight is no good.
## The vote lives at the bottom of the chat column with two buttons on it, so
## answering costs one click and nothing covers the screen.
var _vote_row: HBoxContainer
var _vote_tally: Label


func _build_vote_row() -> void:
	_vote_row = HBoxContainer.new()
	_vote_row.visible = false
	_vote_row.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_vote_row.offset_left = -372
	_vote_row.offset_right = -12
	_vote_row.offset_top = -152
	_vote_row.offset_bottom = -120
	_vote_row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_vote_row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_vote_row.add_theme_constant_override("separation", 6)
	_vote_tally = Label.new()
	_vote_tally.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vote_tally.add_theme_font_size_override("font_size", 16)
	_vote_tally.add_theme_color_override("font_color", Style.ACCENT)
	_vote_row.add_child(_vote_tally)
	for entry in [["YES", true, Color("#7dedb0")], ["NO", false, Color("#ff7060")]]:
		var b := Button.new()
		b.text = str(entry[0])
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(56, 0)
		b.add_theme_font_size_override("font_size", 16)
		b.add_theme_color_override("font_color", entry[2])
		b.pressed.connect(func(): Net.emit_event("castVote", entry[1]))
		_vote_row.add_child(b)
	add_child(_vote_row)


func _refresh_vote(state: Variant) -> void:
	if _vote_row == null:
		return
	var live := state is Dictionary
	_vote_row.visible = live
	# The live rows shuffle up out of the way while it is on screen, and so does
	# the scrollback, which occupies exactly the same column.
	_chat_log.offset_bottom = -152 if live else -120
	if _chat_scroll:
		_chat_scroll.offset_bottom = -152 if live else -120
	if live:
		var d: Dictionary = state
		_vote_tally.text = "END GAME?  %d/%d" % [int(d.get("yes", 0)), int(d.get("needed", 0))]


## Scrollable history of everything said this session, shown while typing.
func _build_scrollback() -> void:
	_chat_scroll = PanelContainer.new()
	_chat_scroll.visible = false
	_chat_scroll.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# Exactly where the live rows sit, so opening it swaps one for the other
	# instead of laying a panel over the top of them and the input box.
	_chat_scroll.offset_left = -430
	_chat_scroll.offset_right = -12
	_chat_scroll.offset_top = -424
	_chat_scroll.offset_bottom = -120
	_chat_scroll.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_chat_scroll.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chat_scroll.add_theme_stylebox_override("panel", Style.panel_box(Color(0, 0, 0, 0.7), 8))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_scroll.add_child(scroll)
	_chat_scroll_rows = VBoxContainer.new()
	_chat_scroll_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_chat_scroll_rows)
	add_child(_chat_scroll)


func _show_scrollback(on: bool) -> void:
	_chat_scroll.visible = on
	_chat_log.visible = not on   # one stream, one place on screen
	if not on:
		return
	for child in _chat_scroll_rows.get_children():
		child.free()
	for bb in _chat_history:
		var row := RichTextLabel.new()
		row.bbcode_enabled = true
		row.fit_content = true
		row.scroll_active = false
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_font_size_override("normal_font_size", 16)
		row.text = str(bb)
		_chat_scroll_rows.add_child(row)
	# Land at the newest message
	await get_tree().process_frame
	var scroll: ScrollContainer = _chat_scroll.get_child(0)
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)


func _on_chat_text_changed(text: String) -> void:
	# Commands render yellow while typing, like the web input.
	_chat_input.add_theme_color_override("font_color", CMD_COLOR if text.begins_with("/") else Color.WHITE)


func _on_chat_submitted(text: String) -> void:
	var msg := text.strip_edges().left(200)
	if msg != "":
		if msg.begins_with("/"):
			_run_chat_command(msg)
		else:
			Net.emit_event("chat", msg)
	_close_chat()


func _run_chat_command(msg: String) -> void:
	var parts := msg.substr(1).split(" ", false)
	var cmd := parts[0].to_lower() if parts.size() > 0 else ""
	var arg := parts[1].to_lower() if parts.size() > 1 else ""
	match cmd:
		"vote":
			if arg == "yes" or arg == "y":
				Net.emit_event("castVote", true)
			elif arg == "no" or arg == "n":
				Net.emit_event("castVote", false)
			else:
				Net.emit_event("startEndVote")
		"end":
			Net.emit_event("startEndVote")
		"kill":
			if sync_node and sync_node.player:
				sync_node.player.suicide()
		"drone", "god":
			var god: Node = get_node_or_null("GodMenu")
			if god:
				god.toggle()
		"help":
			_add_system_row("/vote yes|no  /end  /kill [K]  /drone [Q]")
		_:
			_add_system_row("Unknown command: /" + cmd)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"chatMessage":
			if data is Dictionary and str(data.get("text", "")) != "":
				_add_chat_row(str(data.get("name", "Player")), str(data.get("color", "#ffffff")), str(data.get("text", "")))
		"systemMessage":
			if data is Dictionary and str(data.get("text", "")) != "":
				_add_system_row(str(data.get("text", "")))
		"endVote":
			_refresh_vote(data)
		"kills":
			if data is Dictionary:
				_kills = data
				if sync_node:
					_refresh(sync_node.scores)
		"gameEnded":
			_add_system_row("Game ended.")
		"gameSettings":
			# (the settings panel wires itself to this event)
			_refresh_inventory(_last_inventory)  # ammo display may flip to ∞


func _bb_escape(s: String) -> String:
	return s.replace("[", "[lb]")


## Everything said before this scene existed (lobby and editor included). The
## scrollback gets all of it; only the last few rows go back on screen, so
## dropping into a match doesn't paint the whole session over the crosshair.
const HYDRATE_ON_SCREEN := 4

func _hydrate_chat() -> void:
	var past: Array = Net.chat_log
	for i in past.size():
		var row: Variant = past[i]
		if not row is Dictionary or str(row.get("text", "")) == "":
			continue
		var bb: String
		if bool(row.get("sys", false)):
			bb = "[color=#ffd54a]%s[/color]" % _bb_escape(str(row.get("text")))
		else:
			var col := str(row.get("color", "#ffffff"))
			if not col.begins_with("#"):
				col = "#ffffff"
			bb = "[color=%s]%s:[/color] %s" % [
				col, _bb_escape(str(row.get("name", "Player"))), _bb_escape(str(row.get("text")))]
		_chat_history.append(bb)
		if i >= past.size() - HYDRATE_ON_SCREEN:
			_screen_row(bb)
	while _chat_history.size() > CHAT_HISTORY:
		_chat_history.pop_front()


func _add_chat_row(pname: String, color_hex: String, text: String) -> void:
	if not color_hex.begins_with("#"):
		color_hex = "#ffffff"
	_push_chat_row("[color=%s]%s:[/color] %s" % [color_hex, _bb_escape(pname), _bb_escape(text)])


func _add_system_row(text: String) -> void:
	_push_chat_row("[color=#ffd54a]%s[/color]" % _bb_escape(text))


func _push_chat_row(bbcode: String) -> void:
	_chat_history.append(bbcode)
	while _chat_history.size() > CHAT_HISTORY:
		_chat_history.pop_front()
	_screen_row(bbcode)
	if _chat_scroll and _chat_scroll.visible:
		_show_scrollback(true)   # keep the open log live as messages land


func _screen_row(bbcode: String) -> void:
	var row := RichTextLabel.new()
	row.bbcode_enabled = true
	row.fit_content = true
	row.scroll_active = false
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_font_size_override("normal_font_size", 16)
	row.add_theme_color_override("font_outline_color", Color.BLACK)
	row.add_theme_constant_override("outline_size", 6)
	row.text = "[right]%s[/right]" % bbcode
	row.set_meta("born", Time.get_ticks_msec())
	_chat_log.add_child(row)
	while _chat_log.get_child_count() > CHAT_MAX_ROWS:
		_chat_log.get_child(0).free()


## On-screen rows time out; the scrollback (T) keeps the full log.
func _expire_chat_rows() -> void:
	var now := Time.get_ticks_msec()
	for row in _chat_log.get_children():
		if now - int(row.get_meta("born", now)) > int(CHAT_LIFETIME * 1000.0):
			row.free()


func _run_git_pull() -> void:
	_offer_pull = false
	_update_banner.text = "Updating (git pull)..."
	var output: Array = []
	var code := OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "pull", "--ff-only"], output, true)
	var result := "".join(output).strip_edges()
	if code == 0:
		if result.contains("Already up to date"):
			_update_banner.text = "You already have the latest - nothing to pull."
		else:
			# Self-restart on the new code: spawn a fresh instance with the
			# same command line, then quit this one.
			_update_banner.text = "UPDATED - restarting on the new build..."
			await get_tree().create_timer(1.5).timeout
			OS.create_process(OS.get_executable_path(), OS.get_cmdline_args())
			get_tree().quit()
	else:
		_offer_pull = true
		_update_banner.text = "Update failed (local changes? git missing?) - press F9 to retry\n%s" % result.left(200)


func _trigger_server_deploy() -> void:
	_offer_server_kick = false
	_update_banner.text = "Triggering server redeploy..."
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, code, _h, _b):
		if code >= 200 and code < 300:
			_update_banner.text = "Server redeploy started - give it ~2 minutes; you'll be reconnected automatically."
		else:
			_offer_server_kick = true
			_update_banner.text = "Deploy hook failed (HTTP %d) - check the Render dashboard.\nPress F10 to retry." % code
		req.queue_free()
	)
	if req.request(DEPLOY_HOOK) != OK:
		_offer_server_kick = true
		_update_banner.text = "Could not reach the deploy hook - check your connection. Press F10 to retry."


## Blocky 8x8 icons, drawn from a text mask and blown up nearest-neighbour so
## they sit in the same pixel world as the font.
const ICON_MASKS := {
	"heart": [
		".##.##.",
		"#######",
		"#######",
		".#####.",
		"..###..",
		"...#...",
	],
	"bolt": [
		"...##..",
		"..##...",
		".####..",
		"...##..",
		"..##...",
		".##....",
	],
	"jump": [
		"...#...",
		"..###..",
		".#####.",
		"...#...",
		"...#...",
		".#####.",
	],
}

## Loose 8x8 pixel glyphs for the inventory, in the same blown-up nearest
## -neighbour style as the meter icons. Anything unknown falls back to a box.
const ITEM_ICON_MASKS := {
	"machinegun": [
		"........", "........", "#######.", ".#######",
		"...##..#", "...##...", "...##...", "........",
	],
	"rocket": [
		"......##", ".....###", "....####", "...####.",
		"..####..", ".####...", "###.#...", "#..##...",
	],
	"mines": [
		"..#..#..", "...##...", "..####..", ".######.",
		"########", ".######.", "........", "........",
	],
	"grapple": [
		"...##...", "...##...", "...##...", "...##...",
		"#..##..#", "#.####.#", ".######.", "..####..",
	],
	"launch_pad": [
		"...##...", "..####..", ".######.", "...##...",
		"...##...", "........", "########", "########",
	],
	"boost_pad": [
		"..#..#..", ".##.##..", "###.###.", ".##.##..",
		"..#..#..", "........", "########", "########",
	],
	"teleporter": [
		"..####..", ".#....#.", "#..##..#", "#.####.#",
		"#.####.#", "#..##..#", ".#....#.", "..####..",
	],
	"crowbot": [
		"........", "..##....", ".###....", "#######.",
		".#####..", "..###...", "..#.#...", "........",
	],
	"block": [
		"........", ".######.", ".#....#.", ".#....#.",
		".#....#.", ".#....#.", ".######.", "........",
	],
	"wall": [
		"########", "#..#..#.", "########", ".#..#..#",
		"########", "#..#..#.", "########", "........",
	],
	"ramp": [
		".......#", "......##", ".....###", "....####",
		"...#####", "..######", ".#######", "########",
	],
	"platform": [
		"........", "........", "########", "########",
		"..#..#..", "..#..#..", "..#..#..", "........",
	],
	"bridge_gun": [
		"........", ".#....#.", ".#....#.", ".#....#.",
		".######.", "...##...", "..####..", "........",
	],
	# Terraformer: a nozzle over a ground line pushed into a mound
	"terragun": [
		"..####..", "..####..", "...##...", "...##...",
		"........", "...##...", "..####..", "########",
	],
}


func _item_icon(item: String, color: Color) -> TextureRect:
	return _mask_texture(ITEM_ICON_MASKS.get(item, ITEM_ICON_MASKS["block"]), color)


func _icon(name: String, color: Color) -> TextureRect:
	var tex := _mask_texture(ICON_MASKS[name], color)
	tex.custom_minimum_size = Vector2(18, 14)
	return tex


func _mask_texture(mask: Array, color: Color) -> TextureRect:
	var img := Image.create(mask[0].length(), mask.size(), false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in mask.size():
		var row: String = mask[y]
		for x in row.length():
			if row[x] == "#":
				img.set_pixel(x, y, color)
	var tex := TextureRect.new()
	tex.texture = ImageTexture.create_from_image(img)
	tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return tex


## Health, sprint and jump-charge meters: matching 160x10 bars bottom-center,
## each with its icon (web §6.3 had the two lower ones at 180x10).
func _build_meters() -> void:
	_meters = VBoxContainer.new()
	_meters.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_meters.offset_left = -108
	_meters.offset_right = 108
	_meters.offset_top = -64
	_meters.offset_bottom = -20
	_meters.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_meters.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_meters.add_theme_constant_override("separation", 4)
	add_child(_meters)
	for entry in [["heart", Color("#ff5560")], ["bolt", Color("#4de08a")], ["jump", Color("#7fb2ff")]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(_icon(entry[0], entry[1]))
		var bg := ColorRect.new()
		bg.color = Color(0, 0, 0, 0.5)
		bg.custom_minimum_size = Vector2(160, 10)
		var fill := ColorRect.new()
		fill.color = entry[1]
		fill.position = Vector2(1, 1)
		fill.size = Vector2(158, 8)
		bg.add_child(fill)
		row.add_child(bg)
		_meters.add_child(row)
		_meter_fills.append(fill)


func _update_meters() -> void:
	if _meters == null or sync_node == null or sync_node.player == null:
		return
	var p: CharacterBody3D = sync_node.player
	_meters.visible = not p.godmode
	# Health: same bar treatment as the other two (Slayer only)
	var slayer := bool(Net.game_settings.get("slayer", true))
	var hp := int(sync_node.scores.get(sync_node.self_id, 0)) if sync_node.self_id != "" else 0
	_meter_fills[0].get_parent().get_parent().visible = slayer
	_meter_fills[0].size.x = 158.0 * clampf(float(hp) / 100.0, 0.0, 1.0)
	_meter_fills[0].color = Color("#ff5560") if hp <= 25 else 		(Color("#ffb347") if hp <= 50 else Color("#ff8090"))
	# Sprint: green fill, red while exhausted (web)
	_meter_fills[1].size.x = 158.0 * (p.sprint_stamina / p.SPRINT_DURATION)
	_meter_fills[1].color = Color(0.9, 0.25, 0.2) if p.sprint_exhausted else Color("#4de08a")
	# Jump: charge (c-1)/3 while held, red cooldown drain otherwise
	if p.charging_jump:
		_meter_fills[2].size.x = 158.0 * ((p.jump_charge - 1.0) / 3.0)
		_meter_fills[2].color = Color("#7fb2ff")
	else:
		_meter_fills[2].size.x = 158.0 * (p.jump_cooldown / p.jump_cooldown_max if p.jump_cooldown_max > 0.0 else 0.0)
		_meter_fills[2].color = Color(0.9, 0.25, 0.2)


var _last_inventory: Array = []

## Slot 0 is the active weapon: a big square with a big icon. The rest are
## small squares of equal width, tops flush with the active slot's top.
## Icons carry the identity — the only text is the ammo count.
func _refresh_inventory(items: Array) -> void:
	_last_inventory = items
	for child in _inventory_hud.get_children():
		child.queue_free()
	for i in items.size():
		var item: String = items[i]["type"]
		var ammo: int = int(items[i]["ammo"])
		var size := 88 if i == 0 else 44
		var pad := 12.0 if i == 0 else 6.0
		var tint := Color(str(ITEM_COLORS.get(item, "#ffffff")))
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(size, size)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # tops aligned
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0.6)
		style.border_color = tint
		style.set_border_width_all(2)
		style.set_corner_radius_all(0)
		style.set_content_margin_all(0)
		slot.add_theme_stylebox_override("panel", style)
		# Icon fills the slot; the ammo count floats in the corner so it can
		# never squeeze the glyph.
		var holder := Control.new()
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(holder)
		var icon := _item_icon(item, tint)
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = pad
		icon.offset_top = pad
		icon.offset_right = -pad
		icon.offset_bottom = -pad
		holder.add_child(icon)
		var ammo_text := ""
		if item == "terragun":
			# Not ammo: a charge cell that buys itself back with your health,
			# so infinite-ammo doesn't apply and the number always matters.
			ammo_text = str(ammo)
		elif bool(Net.game_settings.get("infiniteAmmo", false)):
			ammo_text = "∞"
		elif ammo > 0:
			ammo_text = str(ammo)
		if ammo_text != "":
			var label := Label.new()
			label.text = ammo_text
			label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			label.grow_vertical = Control.GROW_DIRECTION_BEGIN
			label.offset_left = -34
			label.offset_top = -20
			label.offset_right = -3
			label.offset_bottom = -1
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			label.add_theme_font_size_override("font_size", 16)
			label.add_theme_color_override("font_outline_color", Color.BLACK)
			label.add_theme_constant_override("outline_size", 6)
			holder.add_child(label)
		_inventory_hud.add_child(slot)


## Escape menu (web §6.6). Settings live behind the gear and only open in
## Build mode — every other gamemode has them locked to the lobby choice.
func _build_esc_menu() -> void:
	# Sized by its contents, centered: no dead space above or below the buttons
	_esc_menu = PanelContainer.new()
	_esc_menu.visible = false
	_esc_menu.set_anchors_preset(Control.PRESET_CENTER)
	_esc_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_esc_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_esc_menu)
	_esc_menu.add_theme_stylebox_override("panel", Style.panel_box(Color(0.03, 0.04, 0.07, 0.92), 10))
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(200, 0)
	box.add_theme_constant_override("separation", 6)
	_esc_menu.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	var title := Label.new()
	title.text = "MENU"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Style.ACCENT)
	head.add_child(title)
	_gear_btn = Button.new()
	_gear_btn.text = "⚙"
	_gear_btn.focus_mode = Control.FOCUS_NONE
	_gear_btn.custom_minimum_size = Vector2(34, 0)
	head.add_child(_gear_btn)

	_settings_box = PanelContainer.new()
	_settings_box.visible = false
	_settings_box.add_theme_stylebox_override("panel", Style.panel_box(Color(0, 0, 0, 0.3), 8))
	_settings_box.add_child(SettingsPanel.new())
	box.add_child(_settings_box)
	_gear_btn.pressed.connect(func(): _settings_box.visible = not _settings_box.visible)

	for entry in [
		["RESUME", func(): _toggle_esc_menu(false)],
		# Still a poll of everyone in the game — the label just doesn't say so
		["END GAME", func():
			Net.emit_event("startEndVote")
			_toggle_esc_menu(false)],
	]:
		var b := Button.new()
		b.text = entry[0]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(entry[1])
		box.add_child(b)


func _toggle_esc_menu(open: bool) -> void:
	_esc_menu.visible = open
	# The tuning sliders work live in every mode; the rest of the settings
	# only unlock in Build mode, so gray them out elsewhere.
	var buildable := str(Net.game_settings.get("mode", "slayer")) == "build"
	(_settings_box.get_child(0) as Node).set_tuning_only(not buildable)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED


## God menu calls this when it opens — only one menu at a time.
func close_esc_menu() -> void:
	if _esc_menu and _esc_menu.visible:
		_toggle_esc_menu(false)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and get_viewport().gui_get_focus_owner() == null:
		# One menu at a time: Esc lands the build drone before opening
		var god: Node = get_node_or_null("GodMenu")
		if god and god.visible:
			god.toggle()
		_toggle_esc_menu(not _esc_menu.visible)
		get_viewport().set_input_as_handled()
		return
	_hotkey_input(event)


## Slayer readouts: health bottom-center above the meters, and the big
## respawn countdown while dead.
func _build_slayer_hud() -> void:
	# The number rides at the right end of the health bar
	_health_label = Label.new()
	_health_label.add_theme_font_size_override("font_size", 16)
	_health_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_health_label.add_theme_constant_override("outline_size", 6)
	_health_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_meter_fills[0].get_parent().get_parent().add_child(_health_label)

	_death_label = Label.new()
	_death_label.set_anchors_preset(Control.PRESET_CENTER)
	_death_label.offset_left = -160
	_death_label.offset_right = 160
	_death_label.offset_top = -60
	_death_label.offset_bottom = 60
	_death_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_death_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_label.add_theme_font_size_override("font_size", 56)
	_death_label.add_theme_color_override("font_color", Color("#ff5544"))
	_death_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_death_label.add_theme_constant_override("outline_size", 12)
	_death_label.visible = false
	add_child(_death_label)


func _update_slayer_hud() -> void:
	if _health_label == null or sync_node == null:
		return
	var slayer := bool(Net.game_settings.get("slayer", true))
	var p: CharacterBody3D = sync_node.player
	if not slayer or p == null or sync_node.self_id == "":
		_health_label.visible = false
		_death_label.visible = false
		return
	var hp := int(sync_node.scores.get(sync_node.self_id, 0))
	_health_label.visible = not p.godmode
	_health_label.text = "%d" % hp
	var col := Color(1, 1, 1)
	if hp <= 25:
		col = Color("#ff5544")
	elif hp <= 50:
		col = Color("#ffb347")
	_health_label.add_theme_color_override("font_color", col)
	_death_label.visible = p.dead
	if p.dead:
		_death_label.text = "💀 %d" % int(ceil(p.dead_timer))


## Status pill (top-right). Outline only, no fill: green while the server is up
## and running our commit, red the moment it is not. Reads
##   • active - 2h 14m
## because "server connected" said nothing you could act on -- it could not tell
## you the server had been up for a week on last Tuesday's code.
func _build_conn_pill() -> void:
	_conn_pill = PanelContainer.new()
	_conn_pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_conn_pill.offset_left = -190
	_conn_pill.offset_right = -10
	_conn_pill.offset_top = 8
	_conn_pill.offset_bottom = 30
	_conn_pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_conn_style = StyleBoxFlat.new()
	_conn_style.set_corner_radius_all(0)
	_conn_style.set_content_margin_all(4)
	_conn_style.bg_color = Color(0, 0, 0, 0)
	_conn_style.set_border_width_all(1)
	_conn_pill.add_theme_stylebox_override("panel", _conn_style)
	var label := Label.new()
	label.name = "Text"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color.WHITE)
	_conn_pill.add_child(label)
	add_child(_conn_pill)


func _update_conn_pill() -> void:
	if _conn_pill == null:
		return
	var ok := Net.is_socket_connected() and not Net.server_stale() \
		and not Net.client_stale()
	var green := Color(0.35, 0.9, 0.5)
	var red := Color(1.0, 0.35, 0.3)
	_conn_style.border_color = green if ok else red
	var text := "● offline"
	if not Net.is_socket_connected():
		text = "● offline"
	elif Net.server_stale():
		text = "● rebuilding"
	elif Net.client_stale():
		text = "● out of date"
	else:
		text = "● active - %s" % Net.uptime_text()
	(_conn_pill.get_node("Text") as Label).text = text
	(_conn_pill.get_node("Text") as Label).add_theme_color_override(
		"font_color", green if ok else red)


func _process(_delta: float) -> void:
	_scoreboard.visible = Input.is_key_pressed(KEY_TAB) and get_viewport().gui_get_focus_owner() == null
	_update_meters()
	_update_conn_pill()
	_update_slayer_hud()
	_expire_chat_rows()


func _refresh(scores: Dictionary) -> void:
	if not sync_node:
		return
	var slayer := bool(Net.game_settings.get("slayer", true))
	# Damage feedback: datamosh pulse + music sting when your health drops
	var my_hp := int(scores.get(sync_node.self_id, 0))
	if slayer and sync_node.self_id != "" and _last_hp >= 0 and my_hp < _last_hp:
		var fx: Node = get_tree().get_first_node_in_group("screen_fx")
		if fx:
			fx.pulse(clampf(float(_last_hp - my_hp) / 40.0, 0.25, 1.0))
		var music: Node = get_tree().get_first_node_in_group("dynamic_music")
		if music:
			music.damage_pulse()
	_last_hp = my_hp
	var holder: String = sync_node.holder_id
	# The oddball "YOU'RE IT" banner belongs to the old sandbox mode
	_it_label.visible = holder != "" and holder == sync_node.self_id and not slayer

	_rebuild_scoreboard(scores, holder, slayer)


## Hold-Tab roster: who's here and how many they've put down. Sorted by kills
## in Slayer (where `scores` is health), by score in the old sandbox mode.
func _rebuild_scoreboard(scores: Dictionary, holder: String, slayer: bool) -> void:
	if _scoreboard_rows == null:
		return
	for child in _scoreboard_rows.get_children():
		child.free()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 24)
	var title := Label.new()
	title.text = "PLAYERS"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Style.ACCENT)
	head.add_child(title)
	var kcol := Label.new()
	kcol.text = "KILLS" if slayer else "SCORE"
	kcol.add_theme_font_size_override("font_size", 16)
	kcol.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	head.add_child(kcol)
	_scoreboard_rows.add_child(head)

	var rows: Array = []
	for id in scores:
		rows.append([str(id), int(_kills.get(str(id), 0)) if slayer else int(scores[id])])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	for row in rows:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 24)
		var who := Label.new()
		who.text = ("[IT] " if (row[0] == holder and not slayer) else "") + sync_node.name_of(row[0])
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.add_theme_font_size_override("font_size", 16)
		line.add_child(who)
		var n := Label.new()
		n.text = str(row[1])
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		n.custom_minimum_size = Vector2(42, 0)
		n.add_theme_font_size_override("font_size", 16)
		line.add_child(n)
		_scoreboard_rows.add_child(line)
