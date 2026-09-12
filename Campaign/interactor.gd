extends Node

## One E key for everything in the campaign that can be talked to, opened or
## read. Anything in the "interactable" group that answers
##
##   interact_verb() -> String     what the prompt says ("talk", "open", "read")
##   interact_range() -> float     how close you must be
##   interact(player) -> void      what happens
##
## gets a keycap prompt when it's the nearest thing in reach and in front of
## you. The dialogue, shop and quest panels live here too, so a conversation
## can hand off to the shop without the NPC knowing what a shop is.

const DialogueBox := preload("res://Campaign/dialogue_box.gd")
const ShopPanel := preload("res://Campaign/shop_panel.gd")
const QuestPanel := preload("res://Campaign/quest_panel.gd")

@export var player: CharacterBody3D

var dialogue: CanvasLayer
var shop: CanvasLayer
var quests: CanvasLayer
var _prompt: PanelContainer
var _prompt_suffix: Label
var _target: Node = null
# The player reads "a Control has focus" as "typing" and stops moving. While a
# panel is open this invisible control holds the focus, so reading a notice
# board doesn't walk you off the plaza.
var _focus_sink: Control


func _ready() -> void:
	add_to_group("campaign_interactor")
	var sink_layer := CanvasLayer.new()
	add_child(sink_layer)
	_focus_sink = Control.new()
	_focus_sink.focus_mode = Control.FOCUS_ALL
	_focus_sink.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sink_layer.add_child(_focus_sink)
	dialogue = DialogueBox.new()
	add_child(dialogue)
	dialogue.action.connect(_on_dialogue_action)
	dialogue.closed.connect(_on_panel_closed)
	shop = ShopPanel.new()
	add_child(shop)
	shop.closed.connect(_on_panel_closed)
	quests = QuestPanel.new()
	add_child(quests)
	quests.closed.connect(_on_panel_closed)
	_build_prompt()


func any_open() -> bool:
	return dialogue.is_open() or shop.is_open() or quests.is_open()


func _build_prompt() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_prompt = PanelContainer.new()
	_prompt.visible = false
	_prompt.set_anchors_preset(Control.PRESET_CENTER)
	_prompt.offset_top = 60
	_prompt.offset_bottom = 96
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.add_theme_stylebox_override("panel",
		preload("res://UI/ui_style.gd").panel_box(Color(0, 0, 0, 0.65), 6))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_prompt.add_child(row)
	var key := Label.new()
	key.text = " E "
	key.add_theme_font_size_override("font_size", 16)
	row.add_child(key)
	_prompt_suffix = Label.new()
	_prompt_suffix.add_theme_font_size_override("font_size", 16)
	_prompt_suffix.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_prompt_suffix.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_prompt_suffix)
	layer.add_child(_prompt)


func _input(event: InputEvent) -> void:
	if any_open() and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close_all()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if any_open():
		return
	if event.keycode != KEY_E or _target == null or player == null:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or player.godmode or player.dead:
		return
	_target.interact(player)
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if player == null:
		return
	if any_open():
		_prompt.visible = false
		if get_viewport().gui_get_focus_owner() == null:
			_focus_sink.grab_focus()
		return
	if _focus_sink.has_focus():
		_focus_sink.release_focus()
	_target = _nearest()
	_prompt.visible = _target != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and not player.godmode and not player.dead
	if _target:
		_prompt_suffix.text = str(_target.interact_verb())


func _nearest() -> Node:
	var cam := get_viewport().get_camera_3d()
	var best: Node = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("interactable"):
		if not (n is Node3D) or not n.has_method("interact"):
			continue
		var d: float = (n as Node3D).global_position.distance_to(player.global_position)
		if d > float(n.interact_range()):
			continue
		if cam:
			var to: Vector3 = ((n as Node3D).global_position - cam.global_position).normalized()
			if to.dot(-cam.global_transform.basis.z) < 0.35:
				continue
		if d < best_d:
			best_d = d
			best = n
	return best


## Panels ------------------------------------------------------------------

func open_dialogue(npc_name: String, data: Dictionary) -> void:
	_close_all()
	dialogue.open(npc_name, data)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func open_shop() -> void:
	_close_all()
	shop.open()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func open_quests(giver := "") -> void:
	_close_all()
	quests.open(giver)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_all() -> void:
	dialogue.close()
	shop.close()
	quests.close()


func _on_panel_closed() -> void:
	if not any_open() and player and not player.godmode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## A dialogue choice asked for something outside the conversation.
func _on_dialogue_action(kind: String, arg: String) -> void:
	match kind:
		"shop":
			open_shop()
		"quests":
			open_quests(arg)
		"quest_accept":
			Net.emit_event("questAccept", arg)
		"give_item":
			Net.emit_event("godmodeGive", arg)
