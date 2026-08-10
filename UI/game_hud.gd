extends CanvasLayer

## In-game HUD (PORT_BLUEPRINT.md §6.3/§6.4): leader display top-center,
## "YOU'RE IT" banner, hold-Tab scoreboard, chat (T to talk, web §6.5).
## Meters/inventory come later.

@export var sync_node: Node

@onready var _leader_label: Label = $LeaderLabel
@onready var _it_label: Label = $ItLabel
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _scoreboard_text: Label = $Scoreboard/Margin/Rows
@onready var _version_label: Label = $VersionLabel
@onready var _update_banner: Label = $UpdateBanner
@onready var _chat_log: VBoxContainer = $ChatLog
@onready var _chat_input: LineEdit = $ChatInput
@onready var _inventory_hud: HBoxContainer = $InventoryHud

const CHAT_MAX_ROWS := 8  # web: chatLog keeps the last 8 rows
const CMD_COLOR := Color("#ffd54a")
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
var _esc_toggles: Dictionary = {}
var _esc_sliders: Dictionary = {}
var _health_label: Label
var _death_label: Label


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


func _close_chat() -> void:
	if not _chat_input.visible:
		return
	_chat_input.visible = false
	_chat_input.release_focus()


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
		"rebuild":
			Net.emit_event("startRebuildVote")
		"help":
			_add_system_row("Commands: /vote yes|no, /end, /rebuild (map-reset vote), /kill (also K), /god (also Q)")
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
			if data is Dictionary:
				for key in _esc_toggles:
					_esc_toggles[key].set_pressed_no_signal(bool(data.get(key, false)))
				for key in _esc_sliders:
					_esc_sliders[key].set_value_no_signal(clampf(float(data.get(key, 1.0)), 0.1, 2.0))
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
	var row := RichTextLabel.new()
	row.bbcode_enabled = true
	row.fit_content = true
	row.scroll_active = false
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_font_size_override("normal_font_size", 15)
	row.add_theme_color_override("font_outline_color", Color.BLACK)
	row.add_theme_constant_override("outline_size", 6)
	row.text = "[right]%s[/right]" % bbcode
	_chat_log.add_child(row)
	while _chat_log.get_child_count() > CHAT_MAX_ROWS:
		_chat_log.get_child(0).free()


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


## Sprint + jump-charge meters (web §6.3: 180x10 bars bottom-center).
func _build_meters() -> void:
	_meters = VBoxContainer.new()
	_meters.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_meters.offset_left = -90
	_meters.offset_right = 90
	_meters.offset_top = -46
	_meters.offset_bottom = -20
	_meters.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_meters.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_meters.custom_minimum_size = Vector2(180, 26)
	_meters.add_theme_constant_override("separation", 4)
	add_child(_meters)
	for i in 2:
		var bg := ColorRect.new()
		bg.color = Color(0, 0, 0, 0.5)
		bg.custom_minimum_size = Vector2(180, 10)
		var fill := ColorRect.new()
		fill.color = Color(0.3, 0.9, 0.4)
		fill.position = Vector2(1, 1)
		fill.size = Vector2(178, 8)
		bg.add_child(fill)
		_meters.add_child(bg)
		_meter_fills.append(fill)


func _update_meters() -> void:
	if _meters == null or sync_node == null or sync_node.player == null:
		return
	var p: CharacterBody3D = sync_node.player
	_meters.visible = not p.godmode
	# Sprint: green fill, red while exhausted (web)
	_meter_fills[0].size.x = 178.0 * (p.sprint_stamina / p.SPRINT_DURATION)
	_meter_fills[0].color = Color(0.9, 0.25, 0.2) if p.sprint_exhausted else Color(0.3, 0.9, 0.4)
	# Jump: green charge (c-1)/3 while held, red cooldown drain otherwise
	if p.charging_jump:
		_meter_fills[1].size.x = 178.0 * ((p.jump_charge - 1.0) / 3.0)
		_meter_fills[1].color = Color(0.3, 0.9, 0.4)
	else:
		_meter_fills[1].size.x = 178.0 * (p.jump_cooldown / p.jump_cooldown_max if p.jump_cooldown_max > 0.0 else 0.0)
		_meter_fills[1].color = Color(0.9, 0.25, 0.2)


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
		var size := 80 if i == 0 else 50
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(size, size)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0.6)
		style.border_color = Color(str(ITEM_COLORS.get(item, "#ffffff")))
		style.set_border_width_all(2)
		style.set_corner_radius_all(8)
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
		label.add_theme_font_size_override("font_size", 10 if i > 0 else 12)
		slot.add_child(label)
		_inventory_hud.add_child(slot)


## Escape menu (web §6.6, trimmed: resume / vote / quit — no gfx toggles yet).
func _build_esc_menu() -> void:
	_esc_menu = PanelContainer.new()
	_esc_menu.visible = false
	_esc_menu.set_anchors_preset(Control.PRESET_CENTER)
	_esc_menu.offset_left = -140
	_esc_menu.offset_right = 140
	_esc_menu.offset_top = -240
	_esc_menu.offset_bottom = 240
	_esc_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_esc_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_esc_menu)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.07, 0.92)
	style.border_color = Color(1, 1, 1, 0.25)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	_esc_menu.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(190, 0)
	box.add_theme_constant_override("separation", 8)
	_esc_menu.add_child(box)
	var title := Label.new()
	title.text = "GAME SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color("#ffd54a"))
	box.add_child(title)

	# Server-wide toggles (everyone sees an alert when these change)
	for entry in [["slayer", "Slayer (coins = health)"], ["infiniteAmmo", "Infinite ammo"], ["selfAssign", "Self-assign items"], ["allowMidgameChanges", "Allow mid-game changes"]]:
		var check := CheckBox.new()
		check.text = entry[1]
		check.focus_mode = Control.FOCUS_NONE
		check.set_pressed_no_signal(bool(Net.game_settings.get(entry[0], false)))
		check.toggled.connect(func(on: bool): Net.emit_event("updateGameSetting", {"key": entry[0], "value": on}))
		box.add_child(check)
		_esc_toggles[entry[0]] = check

	# Physics sliders (server-wide)
	for entry in [["speedScale", "Speed"], ["jumpScale", "Jump"], ["gravityScale", "Gravity"]]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lbl := Label.new()
		lbl.text = entry[1]
		lbl.custom_minimum_size = Vector2(52, 0)
		lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(lbl)
		var slider := HSlider.new()
		slider.min_value = 0.1
		slider.max_value = 2.0
		slider.step = 0.01
		slider.custom_minimum_size = Vector2(120, 0)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.focus_mode = Control.FOCUS_NONE
		slider.set_value_no_signal(clampf(float(Net.game_settings.get(entry[0], 1.0)), 0.1, 2.0))
		slider.drag_ended.connect(func(changed: bool):
			if changed:
				Net.emit_event("updateGameSetting", {"key": entry[0], "value": slider.value}))
		row.add_child(slider)
		box.add_child(row)
		_esc_sliders[entry[0]] = slider

	for entry in [
		["RESUME", func(): _toggle_esc_menu(false)],
		["VOTE: REBUILD MAP (reset)", func():
			Net.emit_event("startRebuildVote")
			_toggle_esc_menu(false)],
		["VOTE: END GAME", func():
			Net.emit_event("startEndVote")
			_toggle_esc_menu(false)],
		["LEAVE TO MENU", func(): get_tree().change_scene_to_file("res://UI/main_menu.tscn")],
		["QUIT GAME", func(): get_tree().quit()],
	]:
		var b := Button.new()
		b.text = entry[0]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(entry[1])
		box.add_child(b)


func _toggle_esc_menu(open: bool) -> void:
	_esc_menu.visible = open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and get_viewport().gui_get_focus_owner() == null:
		# Don't fight the god menu for the cursor
		var god: Node = get_node_or_null("GodMenu")
		if god == null or not god.visible:
			_toggle_esc_menu(not _esc_menu.visible)
			get_viewport().set_input_as_handled()
			return
	_hotkey_input(event)


## Slayer readouts: health bottom-center above the meters, and the big
## respawn countdown while dead.
func _build_slayer_hud() -> void:
	_health_label = Label.new()
	_health_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_health_label.offset_left = -90
	_health_label.offset_right = 90
	_health_label.offset_top = -84
	_health_label.offset_bottom = -52
	_health_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_health_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_health_label.add_theme_font_size_override("font_size", 24)
	_health_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_health_label.add_theme_constant_override("outline_size", 8)
	add_child(_health_label)

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
	_death_label.add_theme_font_size_override("font_size", 54)
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
	_health_label.text = "♥ %d" % hp
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
	_conn_style.set_corner_radius_all(11)
	_conn_style.set_content_margin_all(4)
	_conn_pill.add_theme_stylebox_override("panel", _conn_style)
	var label := Label.new()
	label.name = "Text"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 11)
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


func _refresh(scores: Dictionary) -> void:
	if not sync_node:
		return
	var holder: String = sync_node.holder_id
	_it_label.visible = holder != "" and holder == sync_node.self_id

	# Leader = highest score (web: crown + "name: score" top center)
	var best_id := ""
	var best := -1
	var rows: Array = []
	for id in scores:
		if int(scores[id]) > best:
			best = int(scores[id])
			best_id = str(id)
		rows.append([str(id), int(scores[id])])
	_leader_label.text = "👑 %s: %d" % [sync_node.name_of(best_id), best] if best_id != "" else ""

	rows.sort_custom(func(a, b): return a[1] > b[1])
	var lines: Array = []
	for row in rows:
		var prefix := "[IT] " if row[0] == holder else ""
		lines.append("%s%s - %d" % [prefix, sync_node.name_of(row[0]), row[1]])
	_scoreboard_text.text = "\n".join(lines)
