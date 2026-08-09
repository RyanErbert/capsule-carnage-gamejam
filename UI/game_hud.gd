extends CanvasLayer

## In-game HUD (PORT_BLUEPRINT.md §6.3/§6.4): leader display top-center,
## "YOU'RE IT" banner, hold-Tab scoreboard. Chat/meters/inventory come later.

@export var sync_node: Node

@onready var _leader_label: Label = $LeaderLabel
@onready var _it_label: Label = $ItLabel
@onready var _scoreboard: PanelContainer = $Scoreboard
@onready var _scoreboard_text: Label = $Scoreboard/Margin/Rows
@onready var _version_label: Label = $VersionLabel
@onready var _update_banner: Label = $UpdateBanner

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
		_update_banner.text = "SERVER IS OUT OF DATE (server %s, you %s)\nPress F10 to trigger a server redeploy (~2 min), then restart the game." % [server_build, Net.git_commit()]
	elif we_are_old:
		_offer_pull = true
		_update_banner.text = "YOUR GAME IS OUT OF DATE (you %s, server %s)\nPress F9 to update (runs git pull), then restart the game." % [Net.git_commit(), server_build]
	else:
		_offer_pull = true
		_update_banner.text = "Your copy and the server have DIVERGED (you %s, server %s)\nPress F9 to try updating — if that fails, sort it out in git together." % [Net.git_commit(), server_build]


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if _offer_pull and event.keycode == KEY_F9:
			_run_git_pull()
		elif _offer_server_kick and event.keycode == KEY_F10:
			_trigger_server_deploy()


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
			_update_banner.text = "Server redeploy started — give it ~2 minutes, then restart the game."
		else:
			_offer_server_kick = true
			_update_banner.text = "Deploy hook failed (HTTP %d) — check the Render dashboard.\nPress F10 to retry." % code
		req.queue_free()
	)
	if req.request(DEPLOY_HOOK) != OK:
		_offer_server_kick = true
		_update_banner.text = "Could not reach the deploy hook — check your connection. Press F10 to retry."


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
