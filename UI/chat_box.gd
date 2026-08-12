extends PanelContainer

## Chat panel for the lobby and the map editor, where the mouse is already
## free so the box can just sit there. In game the HUD runs its own T-to-talk
## version over the crosshair.

const Style := preload("res://UI/ui_style.gd")
const MAX_ROWS := 60

var _rows: VBoxContainer
var _scroll: ScrollContainer
var _input: LineEdit


func _ready() -> void:
	# Matches the lobby's other panels: the 3D background behind it is busy
	add_theme_stylebox_override("panel", Style.panel_box(Color(0.071, 0.082, 0.11, 0.94), 10))
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(330, 190)  # hosts may pre-size to dock it
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)
	_input = LineEdit.new()
	_input.placeholder_text = "say something"
	_input.max_length = 200
	_input.text_submitted.connect(_send)
	box.add_child(_input)
	Net.event_received.connect(_on_net_event)


func _on_net_event(event: String, data: Variant) -> void:
	if not data is Dictionary or str(data.get("text", "")) == "":
		return
	if event == "chatMessage":
		var color := str(data.get("color", "#ffffff"))
		if not color.begins_with("#"):
			color = "#ffffff"
		_push("[color=%s]%s:[/color] %s" % [
			color, _esc(str(data.get("name", "Player"))), _esc(str(data.get("text")))])
	elif event == "systemMessage":
		_push("[color=#ffd54a]%s[/color]" % _esc(str(data.get("text"))))


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _send(text: String) -> void:
	var msg := text.strip_edges().left(200)
	if msg != "":
		Net.emit_event("chat", msg)
	_input.text = ""


func _push(bbcode: String) -> void:
	var row := RichTextLabel.new()
	row.bbcode_enabled = true
	row.fit_content = true
	row.scroll_active = false
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_font_size_override("normal_font_size", 16)
	row.text = bbcode
	_rows.add_child(row)
	while _rows.get_child_count() > MAX_ROWS:
		_rows.get_child(0).free()
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
