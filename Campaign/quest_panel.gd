extends CanvasLayer

## The quest list: what's on offer, what you're on, what's done. ACCEPT sends
## questAccept; progress arrives with the character sheet. Opened from the
## board (everything) or from an NPC (only their quests).

signal closed

const Style := preload("res://UI/ui_style.gd")

var _root: PanelContainer
var _rows: VBoxContainer
var _open := false
var _giver := ""


func _ready() -> void:
	layer = 20
	_root = PanelContainer.new()
	_root.visible = false
	_root.set_anchors_preset(Control.PRESET_CENTER)
	_root.offset_left = -260
	_root.offset_right = 260
	_root.offset_top = -220
	_root.offset_bottom = 220
	_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_theme_stylebox_override("panel", Style.panel_box(Style.PANEL_BG, 16))
	add_child(_root)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_root.add_child(box)
	box.add_child(Style.heading("QUESTS", 20))
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 8)
	box.add_child(_rows)
	var back := Button.new()
	back.text = "[ESC] CLOSE"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(close)
	box.add_child(back)
	Net.event_received.connect(_on_net_event)


func is_open() -> bool:
	return _open


func open(giver := "") -> void:
	_giver = giver
	_open = true
	_root.visible = true
	_refresh()


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	closed.emit()


func _on_net_event(event: String, _data: Variant) -> void:
	if _open and (event == "campaignSheet" or event == "campaignWorld"):
		_refresh()


func _refresh() -> void:
	for c in _rows.get_children():
		c.queue_free()
	var world: Variant = Net.campaign_world
	var sheet: Variant = Net.campaign_sheet
	var quests: Array = world.get("quests", []) if world is Dictionary and world.get("quests") is Array else []
	var mine: Dictionary = sheet.get("quests", {}) if sheet is Dictionary and sheet.get("quests") is Dictionary else {}
	var shown := 0
	for q in quests:
		if not q is Dictionary:
			continue
		if _giver != "" and str(q.get("giver", "")) != _giver:
			continue
		shown += 1
		var qid := str(q.get("id", ""))
		var st: Variant = mine.get(qid)
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 10)
		var title := Label.new()
		title.text = str(q.get("title", qid))
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.add_theme_font_size_override("font_size", 17)
		head.add_child(title)
		var reward := Label.new()
		reward.text = "◎ %d" % int(q.get("reward", 0))
		reward.add_theme_color_override("font_color", Color("#ffd54a"))
		head.add_child(reward)
		if st is Dictionary and bool(st.get("done", false)):
			var done := Label.new()
			done.text = "DONE"
			done.add_theme_color_override("font_color", Color("#7dedb0"))
			head.add_child(done)
			title.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		elif st is Dictionary:
			var prog := Label.new()
			prog.text = "%d / %d" % [int(st.get("n", 0)), int(q.get("count", 1))]
			prog.add_theme_color_override("font_color", Color("#8ad4ff"))
			head.add_child(prog)
		else:
			var accept := Button.new()
			accept.text = "ACCEPT"
			accept.focus_mode = Control.FOCUS_NONE
			accept.pressed.connect(func(): Net.emit_event("questAccept", qid))
			head.add_child(accept)
		row.add_child(head)
		var desc := Label.new()
		desc.text = str(q.get("text", ""))
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 14)
		desc.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		row.add_child(desc)
		_rows.add_child(row)
	if shown == 0:
		var none := Label.new()
		none.text = "nothing posted"
		_rows.add_child(none)
