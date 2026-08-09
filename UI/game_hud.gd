extends CanvasLayer

## In-game HUD (PORT_BLUEPRINT.md §6.3/§6.4): leader display top-center,
## "YOU'RE IT" banner, hold-Tab scoreboard. Chat/meters/inventory come later.

@export var sync_node: Node

@onready var _leader_label: Label = $LeaderLabel
@onready var _it_label: Label = $ItLabel
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _scoreboard_text: Label = $Scoreboard/Margin/Rows


func _ready() -> void:
	_it_label.visible = false
	_scoreboard.visible = false
	if sync_node:
		sync_node.scores_changed.connect(_refresh)
		sync_node.holder_changed.connect(func(_id): _refresh(sync_node.scores))


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
