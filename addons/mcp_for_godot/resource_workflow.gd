@tool
extends RefCounted

# Gera apenas candidato sob .godot. Promover ao destino exige transação Python.
const MAX_TEXT_BYTES := 524288
const MAX_MESH_ITEMS := 64
var _staged: Dictionary = {}

func _problem(code: String) -> Dictionary:
	return {"status": "unavailable", "error": {"code": code}}

func _path(path: Variant, extension: String) -> bool:
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or not path.ends_with(extension) or path.length() > 512 or path.contains("\\"):
		return false
	for part in path.trim_prefix("res://").split("/"):
		if part in ["", ".", ".."] or part.begins_with(".") or part.contains(":"):
			return false
	return true

func _safe_stage_dir() -> bool:
	var current := "res://"
	for part in [".godot", "ai_mcp", "resource-staging"]:
		var dir := DirAccess.open(current)
		if dir == null or dir.is_link(part) or not dir.dir_exists(part):
			return false
		current = current.path_join(part)
	return true

func mesh_library_preview(args: Dictionary) -> Dictionary:
	var scene_path = args.get("scene_path")
	var output_path = args.get("output_path")
	var expected = args.get("expected_scene_sha256")
	if not _path(scene_path, ".tscn") or not _path(output_path, ".tres") or typeof(expected) != TYPE_STRING or expected.length() != 64:
		return _problem("invalid_target")
	if not FileAccess.file_exists(scene_path) or FileAccess.get_sha256(scene_path) != expected:
		return _problem("scene_conflict")
	if FileAccess.file_exists(output_path) or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(output_path.get_base_dir())):
		return _problem("output_conflict")
	var file := FileAccess.open(scene_path, FileAccess.READ)
	if file == null or file.get_length() > MAX_TEXT_BYTES:
		return _problem("scene_too_large")
	var text := file.get_as_text()
	file.close()
	if text.contains('type="Script"') or text.contains("script =") or text.contains("instance="):
		return _problem("scene_requires_dedicated_review")
	var candidates := 0
	for line in text.split("\n"):
		if not line.begins_with("[node "):
			continue
		if line.contains('type="MeshInstance3D"'):
			if not line.contains('parent="."'):
				return _problem("nested_mesh_unsupported")
			candidates += 1
		elif line.contains('type="StaticBody3D"') or line.contains('type="CollisionShape3D"') or line.contains('type="NavigationRegion3D"'):
			return _problem("collision_navigation_unsupported")
	if candidates < 1 or candidates > MAX_MESH_ITEMS:
		return _problem("mesh_candidate_limit")
	return {"status": "ok", "schema_version": 1, "scene_path": scene_path, "output_path": output_path, "scene_sha256": expected, "textual_mesh_candidates": candidates, "load_performed": false, "preview_certainty": "candidate_only", "export_scope": "direct_child_meshes_only", "script_execution_risk_on_generate": true}

func mesh_library_generate(args: Dictionary) -> Dictionary:
	var preview := mesh_library_preview(args)
	if preview.status != "ok":
		return preview
	if args.get("allow_scene_load") != true:
		return _problem("scene_load_permission_required")
	var packed: PackedScene = ResourceLoader.load(preview.scene_path, "PackedScene")
	if packed == null:
		return _problem("scene_load_failed")
	var root := packed.instantiate()
	if root == null:
		return _problem("scene_instantiate_failed")
	var library := MeshLibrary.new()
	var names: Dictionary = {}
	for child in root.get_children():
		if not child is MeshInstance3D:
			continue
		if child.mesh == null or child.material_override != null or child.material_overlay != null:
			root.free()
			return _problem("unsupported_mesh_property")
		for surface in range(child.get_surface_override_material_count()):
			if child.get_surface_override_material(surface) != null:
				root.free()
				return _problem("unsupported_mesh_property")
		if library.get_item_count() >= MAX_MESH_ITEMS or names.has(str(child.name)):
			root.free()
			return _problem("mesh_item_limit")
		var id := library.get_last_unused_item_id()
		library.create_item(id)
		library.set_item_name(id, str(child.name))
		library.set_item_mesh(id, child.mesh)
		library.set_item_mesh_transform(id, child.transform)
		names[str(child.name)] = true
	root.free()
	if library.get_item_count() != preview.textual_mesh_candidates or FileAccess.get_sha256(preview.scene_path) != preview.scene_sha256 or FileAccess.file_exists(preview.output_path):
		return _problem("scene_or_output_changed")
	var stage_id := Crypto.new().generate_random_bytes(16).hex_encode()
	var staged_path := "res://.godot/ai_mcp/resource-staging/" + stage_id + ".tres"
	if not _safe_stage_dir():
		return _problem("stage_failed")
	if ResourceSaver.save(library, staged_path) != OK or not FileAccess.file_exists(staged_path):
		return _problem("stage_failed")
	var digest := FileAccess.get_sha256(staged_path)
	_staged[stage_id] = {"staged_path": staged_path, "sha256": digest, "scene_path": preview.scene_path, "scene_sha256": preview.scene_sha256, "output_path": preview.output_path}
	return {"status": "ok", "stage_id": stage_id, "staged_path": staged_path, "staged_sha256": digest, "scene_path": preview.scene_path, "scene_sha256": preview.scene_sha256, "output_path": preview.output_path, "item_count": library.get_item_count(), "load_performed": true, "promotion_required": true}

func mesh_library_discard(args: Dictionary) -> Dictionary:
	var stage_id = args.get("stage_id")
	if typeof(stage_id) != TYPE_STRING or not _staged.has(stage_id):
		return _problem("stage_unknown")
	var entry: Dictionary = _staged[stage_id]
	if FileAccess.get_sha256(entry.staged_path) != entry.sha256:
		return _problem("stage_conflict")
	if DirAccess.remove_absolute(ProjectSettings.globalize_path(entry.staged_path)) != OK:
		return _problem("discard_failed")
	_staged.erase(stage_id)
	return {"status": "ok", "discarded": true, "stage_id": stage_id}
