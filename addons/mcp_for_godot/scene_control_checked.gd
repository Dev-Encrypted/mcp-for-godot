@tool
extends RefCounted

# Controles da cena ativa com precondicoes explicitas. Salvamento persiste no
# disco e nao usa UndoRedo; o chamador deve guardar o hash anterior.


func _fail(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error_code": code, "error": message, "error_details": details}


func _ok(result: Dictionary) -> Dictionary:
	return {"ok": true, "result": result}


func _hash(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and value.length() == 64 and value.is_valid_hex_number()


func remove_leaf(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var checked: Dictionary = plugin._checked_graph_root(args)
	if not checked.ok:
		return checked
	if typeof(args.get("dry_run", false)) != TYPE_BOOL or typeof(args.get("node_path")) != TYPE_STRING:
		return _fail("invalid_target", "Informe node_path e dry_run booleano.")
	var root: Node = checked.root
	var node: Node = plugin._find_node(root, args.node_path)
	if node == null or node == root or node.get_child_count(true) != 0:
		return _fail("not_leaf", "Remocao exige no folha pertencente a cena.")
	var parent := node.get_parent()
	if parent == null:
		return _fail("invalid_target", "No sem pai na cena.")
	var index := node.get_index(true)
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "scene_path": root.scene_file_path, "revision_checked": checked.revision, "node_path": args.node_path, "node_type": node.get_class(), "undo_available": false})
	var history := plugin.get_undo_redo()
	history.create_action("MCP: remover folha %s" % args.node_path, UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "remove_child", node)
	history.add_undo_method(parent, "add_child", node)
	history.add_undo_method(parent, "move_child", node, index)
	history.add_undo_method(node, "set_owner", root)
	history.add_undo_reference(node)
	history.commit_action()
	return _ok({"applied": true, "scene_path": root.scene_file_path, "revision_before": checked.revision, "reread_required": true, "node_path": args.node_path, "undo_available": true})


func open_scene(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	if not args.has("expected_active_scene_path"):
		return _fail("missing_precondition", "Informe expected_active_scene_path como texto ou null.")
	var expected = args.expected_active_scene_path
	if expected != null and typeof(expected) != TYPE_STRING:
		return _fail("invalid_precondition", "Cena atual esperada deve ser texto ou null.")
	if typeof(args.get("path")) != TYPE_STRING or not plugin._valid_scene_path(args.path):
		return _fail("invalid_target", "Informe cena .tscn do projeto.")
	if args.has("expected_target_sha256") and not _hash(args.expected_target_sha256):
		return _fail("invalid_precondition", "SHA-256 alvo deve ser hexadecimal.")
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail("invalid_preview", "dry_run precisa ser booleano.")
	var root := EditorInterface.get_edited_scene_root()
	var actual: Variant = root.scene_file_path if root != null else null
	if actual != expected:
		return _fail("scene_conflict", "A cena ativa mudou.", {"actual_scene_path": actual})
	if not EditorInterface.get_unsaved_scenes().is_empty():
		return _fail("unsaved_scene", "Salve cenas pendentes antes de abrir outra.")
	if not FileAccess.file_exists(args.path):
		return _fail("file_conflict", "Cena alvo ausente.")
	var target_sha256 := FileAccess.get_sha256(args.path)
	if args.has("expected_target_sha256") and target_sha256 != args.expected_target_sha256:
		return _fail("file_conflict", "Hash da cena alvo mudou.")
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "expected_active_scene_path": expected, "target_path": args.path, "target_sha256": target_sha256, "load_performed": false})
	EditorInterface.open_scene_from_path(args.path)
	return _ok({"requested": true, "target_path": args.path, "target_sha256_at_request": target_sha256, "completion": "poll_active_scene"})


func save_scene(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var checked: Dictionary = plugin._checked_graph_root(args)
	if not checked.ok:
		return checked
	if not _hash(args.get("expected_disk_sha256")) or typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail("invalid_precondition", "Informe SHA-256 do arquivo e dry_run booleano.")
	var root: Node = checked.root
	var path := root.scene_file_path
	if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != args.expected_disk_sha256:
		return _fail("file_conflict", "Arquivo mudou desde a leitura.")
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "scene_path": path, "revision_checked": checked.revision, "file_sha256": args.expected_disk_sha256, "undo_available": false})
	EditorInterface.save_scene_as(path, false)
	if not FileAccess.file_exists(path) or path in EditorInterface.get_unsaved_scenes():
		return _fail("save_failed", "Editor nao confirmou salvamento da cena ativa.")
	return _ok({"saved": true, "scene_path": path, "revision_before": checked.revision, "file_sha256_before": args.expected_disk_sha256, "file_sha256_after": FileAccess.get_sha256(path), "undo_available": false, "file_rollback": "not_provided"})


func history_state(plugin: EditorPlugin) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not plugin._valid_scene_path(root.scene_file_path):
		return _fail("no_saved_scene", "Abra uma cena .tscn salva.")
	var manager := plugin.get_undo_redo()
	if not manager.has_method("undo_history") or not manager.has_method("redo_history"):
		return _fail("safe_history_unavailable", "Build sem historico protegido por cena.")
	var history_id := manager.get_object_history_id(root)
	var history := manager.get_history_undo_redo(history_id)
	if history == null:
		return _fail("history_unavailable", "Historico da cena indisponivel.")
	var current := history.get_current_action()
	var undo := {"available": false}
	var redo := {"available": false}
	if history.has_undo():
		var action_name := history.get_current_action_name()
		if action_name.begins_with("MCP: "):
			undo = {"available": true, "action_name": action_name, "action_index": current}
	if history.has_redo():
		var action_name := history.get_action_name(current + 1)
		if action_name.begins_with("MCP: "):
			redo = {"available": true, "action_name": action_name, "action_index": current + 1}
	return _ok({"scene_path": root.scene_file_path, "history_id": history_id, "undo": undo, "redo": redo, "revision_source": "godot_dependency_graph"})


func history_action(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var checked: Dictionary = plugin._checked_graph_root(args)
	if not checked.ok:
		return checked
	var direction = args.get("direction")
	var expected_name = args.get("expected_action_name")
	var expected_history_id = args.get("expected_history_id")
	var expected_action_index = args.get("expected_action_index")
	if direction not in ["undo", "redo"] or typeof(expected_name) != TYPE_STRING or not expected_name.begins_with("MCP: ") or typeof(expected_history_id) not in [TYPE_INT, TYPE_FLOAT] or typeof(expected_action_index) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(expected_history_id)) or not is_finite(float(expected_action_index)) or floorf(float(expected_history_id)) != float(expected_history_id) or floorf(float(expected_action_index)) != float(expected_action_index) or expected_action_index < 0:
		return _fail("invalid_precondition", "Informe direcao, historico, indice e nome da acao MCP esperada.")
	var root: Node = checked.root
	var manager := plugin.get_undo_redo()
	if not manager.has_method("undo_history") or not manager.has_method("redo_history"):
		return _fail("safe_history_unavailable", "Build sem historico protegido por cena.")
	var history_id := manager.get_object_history_id(root)
	if history_id != expected_history_id:
		return _fail("history_conflict", "Identidade do historico mudou.", {"actual_history_id": history_id})
	var history := manager.get_history_undo_redo(history_id)
	if history == null:
		return _fail("history_unavailable", "Historico da cena indisponivel.")
	var redo: bool = direction == "redo"
	if (redo and not history.has_redo()) or (not redo and not history.has_undo()):
		return _fail("history_empty", "Acao solicitada indisponivel.")
	var actual_index := history.get_current_action() + (1 if redo else 0)
	var actual_name := history.get_action_name(actual_index) if redo else history.get_current_action_name()
	if actual_index != expected_action_index or actual_name != expected_name:
		return _fail("history_conflict", "Acao de historico mudou.", {"actual_index": actual_index, "actual_name": actual_name})
	if not manager.call("redo_history" if redo else "undo_history", history_id):
		return _fail("history_rejected", "Gerenciador recusou a acao; releia cena e historico.")
	return _ok({"operation": direction, "scene_path": root.scene_file_path, "history_id": history_id, "action_name": actual_name, "action_index": actual_index, "revision_before": checked.revision, "reread_required": true})
