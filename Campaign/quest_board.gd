extends Node3D

## The quest board: a notice board on two posts. E opens the full quest list.

const READ_RANGE := 3.0


func _ready() -> void:
	add_to_group("interactable")
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.32, 0.2)
	wood.roughness = 0.9
	var paper := StandardMaterial3D.new()
	paper.albedo_color = Color(0.92, 0.88, 0.76)
	paper.roughness = 0.95
	for dx: float in [-1.1, 1.1]:
		_box(Vector3(0.16, 2.6, 0.16), Vector3(dx, 1.3, 0), wood)
	_box(Vector3(2.6, 1.7, 0.1), Vector3(0, 1.9, 0), wood)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 5:
		_box(Vector3(0.6, 0.45, 0.02), Vector3(rng.randf_range(-0.9, 0.9), rng.randf_range(1.45, 2.4), 0.06), paper)
	var lbl := Label3D.new()
	lbl.text = "QUESTS"
	lbl.font_size = 40
	lbl.outline_size = 8
	lbl.position = Vector3(0, 2.95, 0)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(lbl)
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.6, 2.7, 0.3)
	col.shape = box
	col.position.y = 1.35
	body.add_child(col)
	add_child(body)


func _box(size: Vector3, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = at
	add_child(mi)


func interact_verb() -> String:
	return "read"


func interact_range() -> float:
	return READ_RANGE


func interact(_who: CharacterBody3D) -> void:
	var inter: Node = get_parent().get_node_or_null("Interactor")
	if inter:
		inter.open_quests()
