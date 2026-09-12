extends CanvasLayer

## The conversation panel: who's speaking, what they said, and up to four
## replies you can click or press 1-4 for. Choices can carry an action for the
## interactor (open the shop, take a quest) before moving to the next node.

signal action(kind: String, arg: String)
signal closed

const Style := preload("res://UI/ui_style.gd")

var _root: PanelContainer
var _speaker: Label
var _text: RichTextLabel
var _choices: VBoxContainer
var _data: Dictionary = {}
var _node_id := ""
var _open := false


func _ready() -> void:
	layer = 20
	_root = PanelContainer.new()
	_root.visible = false
	_root.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_root.offset_left = -330
	_root.offset_right = 330
	_root.offset_top = -250
	_root.offset_bottom = -70
	_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_theme_stylebox_override("panel", Style.panel_box(Style.PANEL_BG, 16))
	add_child(_root)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_root.add_child(box)
	_speaker = Label.new()
	_speaker.add_theme_font_size_override("font_size", 18)
	_speaker.add_theme_color_override("font_color", Style.ACCENT)
	box.add_child(_speaker)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.custom_minimum_size = Vector2(0, 48)
	_text.add_theme_font_size_override("normal_font_size", 17)
	box.add_child(_text)
	_choices = VBoxContainer.new()
	_choices.add_theme_constant_override("separation", 4)
	box.add_child(_choices)


func is_open() -> bool:
	return _open


func open(speaker: String, data: Dictionary) -> void:
	_data = data
	_open = true
	_root.visible = true
	_speaker.text = speaker
	_show(str(data.get("start", "start")))


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	closed.emit()


func _show(node_id: String) -> void:
	var nodes: Dictionary = _data.get("nodes", {}) if _data.get("nodes") is Dictionary else {}
	if not nodes.has(node_id):
		close()
		return
	_node_id = node_id
	var node: Dictionary = nodes[node_id]
	if node.has("speaker"):
		_speaker.text = str(node["speaker"])
	_text.text = str(node.get("text", ""))
	for c in _choices.get_children():
		c.queue_free()
	var choices: Array = node.get("choices", []) if node.get("choices") is Array else []
	if choices.is_empty():
		choices = [{"text": "..."}]
	for i in mini(4, choices.size()):
		var ch: Dictionary = choices[i]
		var b := Button.new()
		b.text = "%d   %s" % [i + 1, str(ch.get("text", ""))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_pick.bind(ch))
		_choices.add_child(b)


func _pick(ch: Dictionary) -> void:
	var act := str(ch.get("action", ""))
	if act != "":
		var kind := act.get_slice(":", 0)
		var arg := act.substr(kind.length() + 1) if act.contains(":") else ""
		action.emit(kind, arg)
		# Opening a panel closes the conversation; the interactor owns that
		if kind in ["shop", "quests"]:
			close()
			return
	var next := str(ch.get("next", ""))
	if next == "":
		close()
	else:
		_show(next)


func _unhandled_input(event: InputEvent) -> void:
	if not _open or not (event is InputEventKey and event.pressed and not event.echo):
		return
	var idx := -1
	match event.keycode:
		KEY_1: idx = 0
		KEY_2: idx = 1
		KEY_3: idx = 2
		KEY_4: idx = 3
	if idx >= 0 and idx < _choices.get_child_count():
		(_choices.get_child(idx) as Button).pressed.emit()
		get_viewport().set_input_as_handled()
