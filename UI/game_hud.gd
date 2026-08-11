extends CanvasLayer

## In-game HUD (PORT_BLUEPRINT.md §6.3/§6.4): health/sprint/jump meters,
## inventory, "YOU'RE IT" banner, hold-Tab scoreboard, chat (T to talk).

@export var sync_node: Node

@onready var _it_label: Label = $ItLabel
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _scoreboard_text: Label = $Scoreboard/Margin/Rows
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
	"machinegun": "#ff4444", "rocket": "#ff4444", "mines": "#ff4444",
	"block": "#ffff44", "wall": "#ffff44", "ramp": "#ffff44", "platform": "#ffff44", "bridge_gun": "#ffff44",
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


func _ready() -> void:
	_it_label.visible = false
	_scoreboard.visible = false
	_update_banner.visible = false
	_version_label.text = "build " + Net.git_commit()
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


## Scrollable history of everything said this session, shown while typing.
func _build_scrollback() -> void:
	_chat_scroll = PanelContainer.new()
	_chat_scroll.visible = false
	_chat_scroll.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_chat_scroll.offset_left = -430
	_chat_scroll.offset_right = -12
	_chat_scroll.offset_top = -300
	_chat_scroll.offset_bottom = -48
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
		"god":
			var god: Node = get_node_or_null("GodMenu")
			if god:
				god.toggle()
		"help":
			_add_system_row("/vote yes|no  /end  /kill [K]  /god [Q]")
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
		"gameEnded":
			_add_system_row("Game ended.")
		"gameSettings":
			# (the settings panel wires itself to this event)
			_refresh_inventory(_last_inventory)  # ammo display may flip to ∞


func _bb_escape(s: String) -> String:
	return s.replace("[", "[lb]")


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

func _icon(name: String, color: Color) -> TextureRect:
	var mask: Array = ICON_MASKS[name]
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
	tex.custom_minimum_size = Vector2(18, 14)
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

## Web updateInventoryUI: slot 0 is 80px (active), others 50px, borders in the
## item's category color, red ammo count (blank when 0 = single-use).
func _refresh_inventory(items: Array) -> void:
	_last_inventory = items
	for child in _inventory_hud.get_children():
		child.queue_free()
	for i in items.size():
		var item: String = items[i]["type"]
		var ammo: int = int(items[i]["ammo"])
		# Slot 0 is the active weapon: noticeably bigger than the rest
		var size := 104 if i == 0 else 48
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(size, size)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0.6)
		style.border_color = Color(str(ITEM_COLORS.get(item, "#ffffff")))
		style.set_border_width_all(2)
		style.set_corner_radius_all(0)
		slot.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		var ammo_text := ""
		if bool(Net.game_settings.get("infiniteAmmo", false)):
			ammo_text = "\n∞"
		elif ammo > 0:
			ammo_text = "\n%d" % ammo
		label.text = item.replace("_", " ").to_upper() + ammo_text
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		label.add_theme_font_size_override("font_size", 16)
		slot.add_child(label)
		_inventory_hud.add_child(slot)


## Escape menu (web §6.6). Settings live behind the gear and only open in
## Build mode — every other gamemode has them locked to the lobby choice.
func _build_esc_menu() -> void:
	_esc_menu = PanelContainer.new()
	_esc_menu.visible = false
	_esc_menu.set_anchors_preset(Control.PRESET_CENTER)
	_esc_menu.offset_left = -140
	_esc_menu.offset_right = 140
	_esc_menu.offset_top = -220
	_esc_menu.offset_bottom = 220
	_esc_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_esc_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_esc_menu)
	_esc_menu.add_theme_stylebox_override("panel", Style.panel_box(Color(0.03, 0.04, 0.07, 0.92), 14))
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(190, 0)
	box.add_theme_constant_override("separation", 8)
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
		["VOTE: END GAME", func():
			Net.emit_event("startEndVote")
			_toggle_esc_menu(false)],
		["RETURN TO LOBBY", func(): get_tree().change_scene_to_file("res://UI/main_menu.tscn")],
		["QUIT GAME", func(): get_tree().quit()],
	]:
		var b := Button.new()
		b.text = entry[0]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(entry[1])
		box.add_child(b)


func _toggle_esc_menu(open: bool) -> void:
	_esc_menu.visible = open
	# Only Build mode can change settings live; elsewhere the gear is dead
	var buildable := str(Net.game_settings.get("mode", "slayer")) == "build"
	_gear_btn.disabled = not buildable
	if not buildable:
		_settings_box.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED


## God menu calls this when it opens — only one menu at a time.
func close_esc_menu() -> void:
	if _esc_menu and _esc_menu.visible:
		_toggle_esc_menu(false)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and get_viewport().gui_get_focus_owner() == null:
		# One menu at a time: Esc kicks god mode out before opening
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


## Connection pill (top-right): green = connected, red = disconnected.
func _build_conn_pill() -> void:
	_conn_pill = PanelContainer.new()
	_conn_pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_conn_pill.offset_left = -110
	_conn_pill.offset_right = -10
	_conn_pill.offset_top = 8
	_conn_pill.offset_bottom = 30
	_conn_pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_conn_style = StyleBoxFlat.new()
	_conn_style.set_corner_radius_all(0)
	_conn_style.set_content_margin_all(4)
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
	var ok := Net.is_socket_connected()
	_conn_style.bg_color = Color(0.1, 0.45, 0.2, 0.85) if ok else Color(0.55, 0.1, 0.1, 0.9)
	(_conn_pill.get_node("Text") as Label).text = "● online" if ok else "● offline"


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

	# Standings live on the hold-Tab scoreboard, not over the crosshair
	var rows: Array = []
	for id in scores:
		rows.append([str(id), int(scores[id])])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	var lines: Array = []
	for row in rows:
		var prefix := "[IT] " if (row[0] == holder and not slayer) else ""
		lines.append("%s%s - %d" % [prefix, sync_node.name_of(row[0]), row[1]])
	_scoreboard_text.text = "\n".join(lines)
