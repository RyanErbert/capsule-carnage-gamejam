extends Node3D

## A character you can talk to. Built from the same parts as a player -- the
## glass marble with the bear inside -- so the world's people look like the
## world's players, just standing still. Faces you when you're close, bobs a
## little, and carries a name over its head.
##
## What it says lives in res://Campaign/dialogue/<npc_key>.json:
##
##   { "name": "Greeter", "color": "#ffb347", "start": "hi",
##     "nodes": { "hi": { "text": "...", "choices": [
##         { "text": "Where am I?", "next": "where" },
##         { "text": "Show me your wares", "action": "shop" },
##         { "text": "Any work?", "action": "quests" },
##         { "text": "I'll do it", "action": "quest_accept:first_steps", "next": "thanks" },
##         { "text": "Bye" } ] }, ... } }
##
## A choice with no "next" ends the conversation; an "action" fires first.

const FACE_RANGE := 9.0
const TALK_RANGE := 3.2

var npc_key := ""
var player: CharacterBody3D
var data: Dictionary = {}
var display_name := ""

var _shell: Node3D
var _label: Label3D
var _t := 0.0
var _base_y := 0.0


func _ready() -> void:
	add_to_group("interactable")
	var path := "res://Campaign/dialogue/%s.json" % npc_key
	if ResourceLoader.exists(path) or FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				data = parsed
	display_name = str(data.get("name", npc_key.capitalize()))
	var color := Color(str(data.get("color", "#d8c9a3")))
	_shell = load("res://Player/marble_shell.gd").new()
	_shell.set_color(color)
	_shell.hold(load("res://Player/PL_bear.glb").instantiate(), 0.8)
	_shell.position.y = 0.4
	add_child(_shell)
	_label = Label3D.new()
	_label.text = display_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 36
	_label.outline_size = 8
	_label.modulate = color.lightened(0.3)
	_label.position.y = 1.35
	add_child(_label)
	_base_y = _shell.position.y


func interact_verb() -> String:
	return "talk"


func interact_range() -> float:
	return TALK_RANGE


func interact(_who: CharacterBody3D) -> void:
	var inter: Node = get_tree().get_first_node_in_group("campaign_interactor")
	if inter == null:
		inter = get_parent().get_node_or_null("Interactor")
	if inter and not data.is_empty():
		inter.open_dialogue(display_name, data)


func _process(delta: float) -> void:
	_t += delta
	_shell.position.y = _base_y + sin(_t * 1.6) * 0.03
	if player == null:
		return
	var to := player.global_position - global_position
	to.y = 0.0
	if to.length() < FACE_RANGE and to.length() > 0.01:
		var want := atan2(to.x, to.z)
		rotation.y = lerp_angle(rotation.y, want, minf(1.0, delta * 4.0))
