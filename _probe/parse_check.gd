extends SceneTree

## Loading a script compiles it. The UI and net files this touched have no probe
## of their own, and a parse error in them would only show up in game.

const FILES := [
	"res://UI/game_hud.gd", "res://Net/multiplayer_sync.gd",
	"res://Net/network_client.gd", "res://Player/camera_rig.gd",
	"res://Player/player.gd", "res://Terrain/voxel_terrain.gd",
	"res://UI/god_menu.gd", "res://Items/parametrics.gd",
	"res://Items/parametric/registry.gd", "res://Items/parametric/ops.gd",
]


func _initialize() -> void:
	var bad := 0
	for f in FILES:
		var res: Variant = load(f)
		if res == null:
			bad += 1
			print("  FAIL %s" % f)
		else:
			print("  ok   %s" % f)
	print("parse: %s" % ("all %d scripts compile" % FILES.size() if bad == 0 else "%d FAILED" % bad))
	quit()
