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


func _on_version_mismatch(server_build: String, _client_build: String) -> void:
	_update_banner.visible = true
	_update_banner.text = "Version differs from server — checking who's behind..."
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
		_update_banner.text = "SERVER IS OUT OF DATE (server %s, you %s)\nPress F10 to trigger a server redeploy (~2 min) — you'll be reconnected automatically." % [server_build, Net.git_commit()]
	elif we_are_old:
		_offer_pull = true
		_update_banner.text = "YOUR GAME IS OUT OF DATE (you %s, server %s)\nPress F9 to update (runs git pull), then restart the game." % [Net.git_commit(), server_build]
	else:
		_offer_pull = true
		_update_banner.text = "Your copy and the server have DIVERGED (you %s, server %s)\nPress F9 to try updating — if that fails, sort it out in git together." % [Net.git_commit(), server_build]


func _input(event: InputEvent) -> void:
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
		"help":
			_add_system_row("Commands: /vote yes, /vote no, /end (start end-game vote)")
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
			_update_banner.text = "You already have the latest — nothing to pull."
		else:
			_update_banner.text = "UPDATED — restart the game to play on the new version\n%s" % result.left(200)
	else:
		_offer_pull = true
		_update_banner.text = "Update failed (local changes? git missing?) — press F9 to retry\n%s" % result.left(200)


func _trigger_server_deploy() -> void:
	_offer_server_kick = false
	_update_banner.text = "Triggering server redeploy..."
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, code, _h, _b):
		if code >= 200 and code < 300:
			_update_banner.text = "Server redeploy started — give it ~2 minutes; you'll be reconnected automatically."
		else:
			_offer_server_kick = true
			_update_banner.text = "Deploy hook failed (HTTP %d) — check the Render dashboard.\nPress F10 to retry." % code
		req.queue_free()
	)
	if req.request(DEPLOY_HOOK) != OK:
		_offer_server_kick = true
		_update_banner.text = "Could not reach the deploy hook — check your connection. Press F10 to retry."


## Web updateInventoryUI: slot 0 is 80px (active), others 50px, borders in the
## item's category color, red ammo count (blank when 0 = single-use).
func _refresh_inventory(items: Array) -> void:
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
		label.text = item.replace("_", " ").to_upper() + ("\n%d" % ammo if ammo > 0 else "")
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		label.add_theme_font_size_override("font_size", 10 if i > 0 else 12)
		slot.add_child(label)
		_inventory_hud.add_child(slot)


func _process(_delta: float) -> void:
	_scoreboard.visible = Input.is_key_pressed(KEY_TAB)


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
		lines.append("%s%s — %d" % [prefix, sync_node.name_of(row[0]), row[1]])
	_scoreboard_text.text = "\n".join(lines)
