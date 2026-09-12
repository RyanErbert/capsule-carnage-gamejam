extends Node3D

## A loot crate: E to crack it. The server rolls the loot, tells everyone it's
## open, and it stays open (lid up, glow off) until the respawn timer runs
## out. Opened state is shared, so a crate a friend just emptied is empty for
## you too.

const OPEN_RANGE := 2.6

var crate_id := ""
var _lid: Node3D
var _glow: OmniLight3D
var _closed_at := 0.0    # ms left until it closes again; 0 = open for business
var _open := false


func _ready() -> void:
	add_to_group("interactable")
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.5, 0.36, 0.22)
	wood.roughness = 0.85
	var band := StandardMaterial3D.new()
	band.albedo_color = Color(0.3, 0.3, 0.33)
	band.metallic = 0.6
	band.roughness = 0.4
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 0.8, 0.9)
	col.shape = box
	col.position.y = 0.4
	body.add_child(col)
	add_child(body)
	_box(Vector3(1.2, 0.7, 0.9), Vector3(0, 0.35, 0), wood)
	_box(Vector3(1.24, 0.12, 0.94), Vector3(0, 0.2, 0), band)
	_box(Vector3(1.24, 0.12, 0.94), Vector3(0, 0.55, 0), band)
	# The lid hinges along the back edge
	_lid = Node3D.new()
	_lid.position = Vector3(0, 0.7, -0.45)
	add_child(_lid)
	var lid := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(1.2, 0.14, 0.9)
	lm.material = wood
	lid.mesh = lm
	lid.position = Vector3(0, 0.07, 0.45)
	_lid.add_child(lid)
	_glow = OmniLight3D.new()
	_glow.light_color = Color(1.0, 0.85, 0.4)
	_glow.omni_range = 3.5
	_glow.light_energy = 0.9
	_glow.position.y = 0.9
	_glow.shadow_enabled = false
	add_child(_glow)
	Net.event_received.connect(_on_net_event)
	_adopt_world(Net.campaign_world)


func _box(size: Vector3, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = at
	add_child(mi)


func interact_verb() -> String:
	return "open"


func interact_range() -> float:
	return OPEN_RANGE if not _open else 0.0


func interact(_who: CharacterBody3D) -> void:
	if not _open:
		Net.emit_event("openCrate", crate_id)


func _on_net_event(event: String, data: Variant) -> void:
	match event:
		"campaignWorld":
			_adopt_world(data)
		"crateOpened":
			if data is Dictionary and str(data.get("id", "")) == crate_id:
				_set_open(float(data.get("respawnMs", 120000)))
				Sfx.boost(global_position, 0.7)


func _adopt_world(world: Variant) -> void:
	if not world is Dictionary:
		return
	var crates: Variant = world.get("crates", {})
	if crates is Dictionary and crates.has(crate_id):
		_set_open(float(crates[crate_id]))


func _set_open(ms_left: float) -> void:
	_open = true
	_closed_at = ms_left / 1000.0
	_glow.visible = false


func _process(delta: float) -> void:
	var want := -1.9 if _open else 0.0
	_lid.rotation.x = lerpf(_lid.rotation.x, want, minf(1.0, delta * 6.0))
	if _open:
		_closed_at -= delta
		if _closed_at <= 0.0:
			_open = false
			_glow.visible = true
