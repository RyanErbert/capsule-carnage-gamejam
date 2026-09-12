extends Node

## The lobby's map dropdown under each gamemode, without a server: the menu
## is fed the gameSettings it would receive, and a frame is saved per mode
## so the locked and open states can be compared. Set PROBE_SHOT.

var _menu: Control


func _ready() -> void:
	_menu = load("res://UI/main_menu.tscn").instantiate()
	add_child(_menu)
	_shoot()


func _shoot() -> void:
	var base := OS.get_environment("PROBE_SHOT")
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	for i in 4:
		await RenderingServer.frame_post_draw
	var report: Array = []
	for mode in ["slayer", "fortwars", "campaign"]:
		_menu.call("_apply_game_settings", {"mode": mode})
		for i in 4:
			await RenderingServer.frame_post_draw
		var opt: OptionButton = _menu.get("_level_opt")
		var keys: Array = _menu.get("_level_keys")
		report.append("%s: %d rows %s disabled=%s level=%s" % [mode, opt.item_count, str(keys), str(opt.disabled), str(Settings.level)])
		if base != "":
			get_viewport().get_texture().get_image().save_png(base.replace(".png", "_%s.png" % mode))
	for line in report:
		print("PROBE " + line)
	get_tree().quit()
