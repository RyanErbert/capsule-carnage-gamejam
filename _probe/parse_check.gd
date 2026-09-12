extends SceneTree

## Loading a script compiles it. The UI and net files this touched have no probe
## of their own, and a parse error in them would only show up in game.

const FILES := [
	"res://UI/game_hud.gd", "res://Net/multiplayer_sync.gd",
	"res://Net/network_client.gd", "res://Player/camera_rig.gd",
	"res://Player/player.gd", "res://Terrain/voxel_terrain.gd",
	"res://UI/god_menu.gd", "res://Items/parametrics.gd",
	"res://Items/parametric/registry.gd", "res://Items/parametric/ops.gd",
	"res://UI/main_menu.gd", "res://UI/settings_panel.gd", "res://Items/item_controller.gd",
	"res://Items/weapon_rig.gd", "res://Net/remote_player.gd", "res://Items/generators.gd",
	"res://Items/vampire_gun.gd", "res://Items/vampire_beam.gd", "res://UI/settings.gd",
	"res://Items/aura.gd", "res://Scenes/creative.gd", "res://Items/terra_gun.gd",
	"res://Scenes/campaign.gd", "res://Campaign/interactor.gd", "res://Campaign/npc.gd",
	"res://Campaign/dialogue_box.gd", "res://Campaign/shop_panel.gd", "res://Campaign/quest_panel.gd",
	"res://Campaign/loot_crate.gd", "res://Campaign/checkpoint.gd", "res://Campaign/quest_board.gd",
	"res://Scenes/glb_level.gd", "res://Campaign/glb_world.gd",
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
