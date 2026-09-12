extends CanvasLayer

## The weapons shop: every item the server prices, with your coins at the top.
## BUY sends shopBuy; the server debits the wallet and hands the item over as
## an ordinary pickup, and the sheet that comes back redraws the numbers.

signal closed

const Style := preload("res://UI/ui_style.gd")
const NAMES := {
	"machinegun": "Machine gun", "rocket": "Rocket launcher", "mines": "Mines",
	"grapple": "Grapple", "terragun": "Terraformer", "vampire": "Vampire gun",
}

var _root: PanelContainer
var _coins: Label
var _rows: VBoxContainer
var _open := false


func _ready() -> void:
	layer = 20
	_root = PanelContainer.new()
	_root.visible = false
	_root.set_anchors_preset(Control.PRESET_CENTER)
	_root.offset_left = -220
	_root.offset_right = 220
	_root.offset_top = -200
	_root.offset_bottom = 200
	_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_theme_stylebox_override("panel", Style.panel_box(Style.PANEL_BG, 16))
	add_child(_root)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_root.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Style.heading("SHOP", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_coins = Label.new()
	_coins.add_theme_font_size_override("font_size", 18)
	_coins.add_theme_color_override("font_color", Color("#ffd54a"))
	head.add_child(_coins)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	box.add_child(_rows)
	var back := Button.new()
	back.text = "[ESC] LEAVE"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(close)
	box.add_child(back)
	Net.event_received.connect(_on_net_event)


func is_open() -> bool:
	return _open


func open() -> void:
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
	if _open and (event == "campaignSheet" or event == "campaignWorld" or event == "campaignDenied"):
		_refresh()


func _refresh() -> void:
	var sheet: Variant = Net.campaign_sheet
	var coins := int(sheet.get("coins", 0)) if sheet is Dictionary else 0
	_coins.text = "◎ %d" % coins
	for c in _rows.get_children():
		c.queue_free()
	var world: Variant = Net.campaign_world
	var prices: Dictionary = world.get("shop", {}) if world is Dictionary and world.get("shop") is Dictionary else {}
	if prices.is_empty():
		var empty := Label.new()
		empty.text = "nothing for sale"
		_rows.add_child(empty)
		return
	for item in prices:
		var price := int(prices[item])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lbl := Label.new()
		lbl.text = str(NAMES.get(item, str(item).capitalize()))
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_font_size_override("font_size", 16)
		row.add_child(lbl)
		var cost := Label.new()
		cost.text = "◎ %d" % price
		cost.add_theme_font_size_override("font_size", 16)
		cost.add_theme_color_override("font_color",
			Color("#ffd54a") if coins >= price else Color(1, 0.5, 0.45))
		row.add_child(cost)
		var buy := Button.new()
		buy.text = "BUY"
		buy.focus_mode = Control.FOCUS_NONE
		buy.disabled = coins < price
		buy.pressed.connect(func(): Net.emit_event("shopBuy", item))
		row.add_child(buy)
		_rows.add_child(row)
