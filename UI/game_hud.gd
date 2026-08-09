extends CanvasLayer

## In-game HUD (PORT_BLUEPRINT.md §6.3/§6.4): leader display top-center,
## "YOU'RE IT" banner, hold-Tab scoreboard. Chat/meters/inventory come later.

@export var sync_node: Node

@onready var _leader_label: Label = $LeaderLabel
@onready var _it_label: Label = $ItLabel
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _scoreboard_text: Label = $Scoreboard/Margin/Rows
@onready var _version_label: Label = $VersionLabel


func _ready() -> void:
	_it_label.visible = false
	_scoreboard.visible = false
	_version_label.text = "build " + _git_commit()
	if sync_node:
		sync_node.scores_changed.connect(_refresh)
		sync_node.holder_changed.connect(func(_id): _refresh(sync_node.scores))


## Reads the current git commit so both players can confirm they run the same
## build (shown bottom-right; works when running from a clone, "dev" otherwise).
func _git_commit() -> String:
	var head := FileAccess.open("res://.git/HEAD", FileAccess.READ)
	if head == null:
		return "dev"
	var line := head.get_as_text().strip_edges()
	if not line.begins_with("ref: "):
		return line.left(7)  # detached HEAD
	var ref := line.substr(5)
	var ref_file := FileAccess.open("res://.git/" + ref, FileAccess.READ)
	if ref_file:
		return ref_file.get_as_text().strip_edges().left(7)
	var packed := FileAccess.open("res://.git/packed-refs", FileAccess.READ)
	if packed:
		for l in packed.get_as_text().split("\n"):
			if l.ends_with(" " + ref):
				return l.get_slice(" ", 0).left(7)
	return "dev"


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
