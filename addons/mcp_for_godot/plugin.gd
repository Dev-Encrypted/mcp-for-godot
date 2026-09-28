@tool
extends EditorPlugin

# Protocolo privado, uma linha JSON por conexao. Apenas o servidor MCP local deve acessa-lo.
const MAX_REQUEST_BYTES := 65536
const MAX_SCENE_NODES := 300
const ALLOWED_NODE_TYPES := ["Node2D", "Control", "ColorRect", "Label", "Button", "Sprite2D", "Camera2D", "CharacterBody2D", "StaticBody2D", "RigidBody2D", "Area2D", "CollisionShape2D", "CollisionPolygon2D", "AnimatedSprite2D", "TileMapLayer", "AudioStreamPlayer2D", "Marker2D", "Path2D", "PathFollow2D", "Timer", "CanvasLayer", "Panel", "TextureRect", "HBoxContainer", "VBoxContainer", "GridContainer", "MarginContainer", "Node3D", "Sprite3D", "Camera3D", "MeshInstance3D", "DirectionalLight3D", "OmniLight3D"]
const ROOT_NODE_TYPES := ["Node2D", "Control", "Node3D"]
const LIVE_DEBUGGER_SCRIPT = preload("res://addons/mcp_for_godot/live_debugger.gd")
const DEPENDENCY_GRAPH_SCRIPT = preload("res://addons/mcp_for_godot/dependency_graph.gd")
const GRAPHICS_EDIT_SCRIPT = preload("res://addons/mcp_for_godot/graphics_edit.gd")
const GAMEPLAY_COMPOSE_SCRIPT = preload("res://addons/mcp_for_godot/gameplay_compose.gd")
const RESOURCE_WORKFLOW_SCRIPT = preload("res://addons/mcp_for_godot/resource_workflow.gd")
const SCENE_CONTROL_CHECKED_SCRIPT = preload("res://addons/mcp_for_godot/scene_control_checked.gd")
const TILEMAP_COMPOSE_SCRIPT = preload("res://addons/mcp_for_godot/tilemap_compose.gd")
const TEXTURE_IMPORT_SCRIPT = preload("res://addons/mcp_for_godot/texture_import.gd")

var _listener: TCPServer
var _peer: StreamPeerTCP
var _input := ""
var _token := ""
var _bridge_dir := ""
var _live_debugger
var _play_owner := ""
var _play_token := ""
var _created_scenes := {}
var _resource_workflow


func _enter_tree() -> void:
	_live_debugger = LIVE_DEBUGGER_SCRIPT.new()
	_resource_workflow = RESOURCE_WORKFLOW_SCRIPT.new()
	add_debugger_plugin(_live_debugger)
	_bridge_dir = ProjectSettings.globalize_path("res://.godot/ai_mcp")
	if DirAccess.make_dir_recursive_absolute(_bridge_dir) != OK:
		push_error("MCP for Godot: nao foi possivel criar a pasta local da ponte")
		return
	_listener = TCPServer.new()
	var error := _listener.listen(0, "127.0.0.1")
	if error != OK:
		push_error("MCP for Godot: falha ao escutar em 127.0.0.1: %s" % error)
		_listener = null
		return
	_token = Crypto.new().generate_random_bytes(32).hex_encode()
	var info := {
		"port": _listener.get_local_port(),
		"token": _token,
		"project_path": ProjectSettings.globalize_path("res://"),
		"protocol": 1
	}
	var file := FileAccess.open(_bridge_dir.path_join("bridge.json"), FileAccess.WRITE)
	if file == null:
		_listener.stop()
		_listener = null
		push_error("MCP for Godot: nao foi possivel escrever bridge.json")
		return
	file.store_string(JSON.stringify(info))
	file.close()
	set_process(true)
	print("MCP for Godot: ponte local ativa na porta %s" % info.port)


func _exit_tree() -> void:
	set_process(false)
	if _live_debugger != null:
		remove_debugger_plugin(_live_debugger)
		_live_debugger = null
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _listener != null:
		_listener.stop()
		_listener = null
	var bridge_file := _bridge_dir.path_join("bridge.json")
	if FileAccess.file_exists(bridge_file):
		DirAccess.remove_absolute(bridge_file)
	_token = ""


func _process(_delta: float) -> void:
	if _listener == null:
		return
	if _peer == null and _listener.is_connection_available():
		_peer = _listener.take_connection()
		_input = ""
	if _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer = null
		return
	var available := _peer.get_available_bytes()
	if available == 0:
		return
	if available + _input.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
		_send_response({"id": null, "ok": false, "error": "Requisicao muito grande"})
		return
	var received := _peer.get_data(available)
	if received[0] != OK:
		_peer = null
		return
	_input += (received[1] as PackedByteArray).get_string_from_utf8()
	if not _input.contains("\n"):
		return
	var line := _input.get_slice("\n", 0)
	var request = JSON.parse_string(line)
	if typeof(request) != TYPE_DICTIONARY:
		_send_response({"id": null, "ok": false, "error": "JSON invalido"})
		return
	var response: Dictionary = _dispatch(request)
	response["id"] = request.get("id")
	_audit(request, response)
	_send_response(response)


func _send_response(response: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
	_peer.disconnect_from_host()
	_peer = null
	_input = ""


func _dispatch(request: Dictionary) -> Dictionary:
	if request.get("token") != _token:
		return _fail("Token da ponte invalido")
	var args = request.get("args", {})
	if typeof(args) != TYPE_DICTIONARY:
		return _fail("args deve ser um objeto")
	var operation := str(request.get("op", ""))
	if operation in ["add_node", "add_node_checked", "connect_signal_checked", "set_property", "set_property_checked", "remove_leaf", "remove_leaf_checked", "history_action_checked", "graphics_edit_checked", "gameplay_compose_checked", "gameplay_attach_script_checked", "tilemap_compose_checked"] and not get_undo_redo().has_method("undo_history"):
		return _fail_typed("safe_history_unavailable", "Edição reversível exige um binário customizado com undo_history/redo_history do gerenciador do editor.")
	match str(request.get("op", "")):
		"status":
			var root := EditorInterface.get_edited_scene_root()
			var open_scripts: Array[String] = []
			for script in EditorInterface.get_script_editor().get_open_scripts():
				if script is Script and (script as Script).resource_path.begins_with("res://"):
					open_scripts.append((script as Script).resource_path)
			return _ok({"project_path": ProjectSettings.globalize_path("res://"), "scene_path": root.scene_file_path if root != null else "", "open_scenes": EditorInterface.get_open_scenes(), "unsaved_scenes": EditorInterface.get_unsaved_scenes(), "open_scripts": open_scripts, "editor_connected": true, "playing": EditorInterface.is_playing_scene(), "safe_scene_history": get_undo_redo().has_method("undo_history") and get_undo_redo().has_method("redo_history"), "editor_focused": DisplayServer.window_is_focused(), "editor_low_processor_sleep_usec": OS.low_processor_usage_mode_sleep_usec, "image_previews": _live_debugger.get_preview_status()})
		"scene_tree":
			return _scene_tree()
		"graphics_inspect":
			if typeof(args.get("node_path")) != TYPE_STRING:
				return _fail_typed("invalid_target", "Informe node_path.")
			return GRAPHICS_EDIT_SCRIPT.new().inspect(_active_root(), args["node_path"])
		"graphics_asset":
			if typeof(args.get("path")) != TYPE_STRING:
				return _fail_typed("invalid_asset_path", "Informe path.")
			return GRAPHICS_EDIT_SCRIPT.new().asset(args["path"])
		"graphics_edit_checked":
			return GRAPHICS_EDIT_SCRIPT.new().edit(self, args)
		"gameplay_compose_checked":
			return GAMEPLAY_COMPOSE_SCRIPT.new().compose(self, args)
		"tilemap_compose_checked":
			return TILEMAP_COMPOSE_SCRIPT.new().compose(self, args)
		"texture_import_prepare":
			return _ok(TEXTURE_IMPORT_SCRIPT.new().prepare(args))
		"texture_reimport":
			return _ok(TEXTURE_IMPORT_SCRIPT.new().reimport(args))
		"gameplay_attach_script_checked":
			return GAMEPLAY_COMPOSE_SCRIPT.new().attach_script(self, args)
		"mesh_library_preview":
			return _ok(_resource_workflow.mesh_library_preview(args))
		"mesh_library_generate":
			return _ok(_resource_workflow.mesh_library_generate(args))
		"mesh_library_discard":
			return _ok(_resource_workflow.mesh_library_discard(args))
		"dependency_graph":
			var graph_root := _active_root()
			if graph_root == null or not _valid_scene_path(graph_root.scene_file_path):
				return _fail_typed("no_saved_scene", "Abra uma cena .tscn salva antes de ler dependências.")
			return _ok(DEPENDENCY_GRAPH_SCRIPT.new().build(graph_root, _scene_revision(graph_root)))
		"live_snapshot":
			var session_id = args.get("session_id", -1)
			if typeof(session_id) not in [TYPE_INT, TYPE_FLOAT] or float(session_id) != floorf(float(session_id)) or session_id < -1:
				return _fail("session_id deve ser um inteiro não negativo")
			return _ok(_live_debugger.get_snapshot(int(session_id)))
		"live_timeline":
			var session_id = args.get("session_id", -1)
			var limit = args.get("limit", 20)
			if typeof(session_id) not in [TYPE_INT, TYPE_FLOAT] or float(session_id) != floorf(float(session_id)) or session_id < -1:
				return _fail("session_id deve ser um inteiro não negativo")
			if typeof(limit) not in [TYPE_INT, TYPE_FLOAT] or float(limit) != floorf(float(limit)) or limit < 1 or limit > 40:
				return _fail("limit deve estar entre 1 e 40")
			return _ok(_live_debugger.get_timeline(int(session_id), int(limit)))
		"debugger_events":
			var native_session = args.get("session_id", -1)
			var generation = args.get("run_generation", -1)
			var cursor = args.get("after_cursor", 0)
			var event_limit = args.get("limit", 40)
			if typeof(native_session) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(native_session)) or float(native_session) != floorf(float(native_session)) or native_session < -1 or native_session > 9007199254740991 or typeof(generation) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(generation)) or float(generation) != floorf(float(generation)) or generation < -1 or generation > 9007199254740991 or typeof(cursor) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(cursor)) or float(cursor) != floorf(float(cursor)) or cursor < 0 or cursor > 9007199254740991 or typeof(event_limit) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(event_limit)) or float(event_limit) != floorf(float(event_limit)) or event_limit < 1 or event_limit > 40:
				return _fail_typed("invalid_query", "Sessão, geração, cursor ou limite inválido.")
			return _ok(_live_debugger.get_native_diagnostics(int(native_session), int(generation), int(cursor), int(event_limit)))
		"live_image_start":
			var session_id = args.get("session_id", -1)
			if typeof(session_id) not in [TYPE_INT, TYPE_FLOAT] or float(session_id) != floorf(float(session_id)) or session_id < -1:
				return _fail("session_id deve ser um inteiro não negativo")
			var viewport_path = args.get("viewport_path", "")
			if typeof(viewport_path) != TYPE_STRING or viewport_path.length() > 512:
				return _fail_typed("invalid_viewport", "Caminho de viewport inválido.")
			return _ok(_live_debugger.request_image(int(session_id), viewport_path))
		"live_image_result":
			var session_id = args.get("session_id", -1)
			var capture_id = args.get("capture_id", "")
			if typeof(session_id) not in [TYPE_INT, TYPE_FLOAT] or float(session_id) != floorf(float(session_id)) or session_id < 0:
				return _fail("session_id deve ser um inteiro não negativo")
			if typeof(capture_id) != TYPE_STRING or capture_id.length() != 32 or not capture_id.is_valid_hex_number():
				return _fail("capture_id inválido")
			return _ok(_live_debugger.get_image_result(int(session_id), capture_id))
		"input_action_start":
			var session_id = args.get("session_id")
			var run_id = args.get("run_id")
			var action = args.get("action")
			var duration_ms = args.get("duration_ms")
			if typeof(session_id) not in [TYPE_INT, TYPE_FLOAT] or float(session_id) != floorf(float(session_id)) or session_id < 0 or typeof(run_id) != TYPE_STRING or run_id.is_empty() or run_id.length() > 80 or typeof(action) != TYPE_STRING or action.is_empty() or action.length() > 64 or typeof(duration_ms) not in [TYPE_INT, TYPE_FLOAT] or float(duration_ms) != floorf(float(duration_ms)) or duration_ms < 1 or duration_ms > 1000:
				return _fail_typed("invalid_input", "Sessão, execução, ação ou duração inválida.")
			return _ok(_live_debugger.request_input(int(session_id), run_id, action, int(duration_ms)))
		"input_action_result":
			var session_id = args.get("session_id")
			var command_id = args.get("command_id")
			if typeof(session_id) not in [TYPE_INT, TYPE_FLOAT] or float(session_id) != floorf(float(session_id)) or session_id < 0 or typeof(command_id) != TYPE_STRING or command_id.length() != 32 or not command_id.is_valid_hex_number():
				return _fail_typed("invalid_input", "Identidade da ação inválida.")
			return _ok(_live_debugger.get_input_result(int(session_id), command_id))
		"open_scene":
			return _open_scene(args)
		"open_scene_checked":
			return SCENE_CONTROL_CHECKED_SCRIPT.new().open_scene(self, args)
		"save_scene_checked":
			return SCENE_CONTROL_CHECKED_SCRIPT.new().save_scene(self, args)
		"remove_leaf_checked":
			return SCENE_CONTROL_CHECKED_SCRIPT.new().remove_leaf(self, args)
		"history_state":
			return SCENE_CONTROL_CHECKED_SCRIPT.new().history_state(self)
		"history_action_checked":
			return SCENE_CONTROL_CHECKED_SCRIPT.new().history_action(self, args)
		"close_scene_checked":
			return _close_scene_checked(args)
		"play_scene":
			return _play_scene(args)
		"stop_scene":
			return _stop_scene(args)
		"create_scene":
			return _create_scene(args)
		"save_scene_as_checked":
			return _save_scene_as_checked(args)
		"revert_created_scene":
			return _revert_created_scene(args)
		"resource_uid":
			return _resource_uid(args)
		"instance_scene_checked":
			return _instance_scene_checked(args)
		"add_node":
			return _add_node(args)
		"add_node_checked":
			return _add_node_checked(args)
		"connect_signal_checked":
			return _connect_signal_checked(args)
		"set_property":
			return _set_property(args)
		"set_property_checked":
			return _set_property_checked(args)
		"remove_leaf":
			return _remove_leaf(args)
		"undo":
			return _history_action(false)
		"redo":
			return _history_action(true)
		"save_scene":
			return _save_scene()
		_:
			return _fail("Operacao desconhecida")


func _ok(value: Dictionary) -> Dictionary:
	return {"ok": true, "result": value}


func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


func _fail_typed(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error": message, "error_code": code, "error_details": details}


func _scene_tree() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _fail("Nenhuma cena aberta no editor")
	var nodes: Array[Dictionary] = []
	_collect_nodes(root, root, nodes)
	var truncated := nodes.size() >= MAX_SCENE_NODES
	return _ok({"scene_path": root.scene_file_path, "revision": "" if truncated else _revision_for(root.scene_file_path, nodes), "revision_scope": "inspected_scene_projection", "nodes": nodes, "truncated": truncated})


func _revision_for(scene_path: String, nodes: Array[Dictionary]) -> String:
	return JSON.stringify({"scene_path": scene_path, "nodes": nodes}).sha256_text()


func _scene_revision(root: Node) -> String:
	var nodes: Array[Dictionary] = []
	_collect_nodes(root, root, nodes)
	if nodes.size() >= MAX_SCENE_NODES:
		return ""
	return _revision_for(root.scene_file_path, nodes)


func _collect_nodes(root: Node, node: Node, nodes: Array[Dictionary]) -> void:
	if nodes.size() >= MAX_SCENE_NODES:
		return
	if node != root and node.owner != root:
		return
	var item := {"path": str(root.get_path_to(node)), "name": str(node.name), "type": node.get_class(), "children": node.get_child_count()}
	for property_name in ["text", "position", "size", "scale", "rotation_degrees", "visible", "modulate", "color"]:
		if _property_allowed(node, property_name):
			item[property_name] = _encode_value(node.get(property_name))
	nodes.append(item)
	for child in node.get_children():
		_collect_nodes(root, child, nodes)


func _open_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if not _valid_scene_path(path) or not FileAccess.file_exists(path):
		return _fail("Cena fora de res:// ou inexistente")
	EditorInterface.open_scene_from_path(path)
	return _ok({"requested_scene_path": path, "note": "A abertura pode terminar no proximo ciclo do editor; consulte scene_tree."})


func _close_scene_checked(args: Dictionary) -> Dictionary:
	var root := _active_root()
	if root == null or typeof(args.get("expected_scene_path")) != TYPE_STRING or root.scene_file_path != args["expected_scene_path"]:
		return _fail_typed("scene_conflict", "A cena ativa não corresponde à solicitada.")
	if root.scene_file_path in EditorInterface.get_unsaved_scenes():
		return _fail_typed("unsaved_scene", "Fechar descartaria alterações não salvas.")
	var path := root.scene_file_path
	var close_error := EditorInterface.close_scene()
	if close_error != OK:
		return _fail_typed("close_failed", "Editor recusou fechar a cena.", {"godot_error": close_error})
	return _ok({"closed": true, "scene_path": path})


func _play_scene(args: Dictionary) -> Dictionary:
	var owner = args.get("owner")
	if typeof(owner) != TYPE_STRING or owner.length() != 32 or not owner.is_valid_hex_number():
		return _fail_typed("invalid_owner", "Identidade de cliente inválida.")
	if EditorInterface.is_playing_scene():
		return _fail_typed("already_playing", "O editor já executa uma cena; não assumir controle de sessão alheia.")
	var mode = args.get("mode", "current")
	if mode not in ["current", "main", "path"]:
		return _fail_typed("invalid_mode", "Modo de execução inválido.")
	var root := _active_root()
	var unsaved := EditorInterface.get_unsaved_scenes()
	if not unsaved.is_empty():
		return _fail_typed("unsaved_scene", "Salve ou descarte as alterações das cenas antes de executar via MCP.", {"scene_paths": unsaved})
	var scene_path := ""
	match mode:
		"current":
			if root == null or not _valid_scene_path(root.scene_file_path):
				return _fail_typed("no_saved_scene", "Abra uma cena .tscn salva antes de executar.")
			scene_path = root.scene_file_path
			EditorInterface.play_current_scene()
		"main":
			scene_path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
			if not _valid_scene_path(scene_path) or not FileAccess.file_exists(scene_path):
				return _fail_typed("no_main_scene", "Cena principal inexistente.")
			EditorInterface.play_main_scene()
		"path":
			scene_path = str(args.get("path", ""))
			if not _valid_scene_path(scene_path) or not FileAccess.file_exists(scene_path):
				return _fail_typed("invalid_scene", "Cena solicitada fora do projeto ou inexistente.")
			EditorInterface.play_custom_scene(scene_path)
	_play_owner = owner
	_play_token = Crypto.new().generate_random_bytes(16).hex_encode()
	return _ok({"requested": true, "play_token": _play_token, "mode": mode, "scene_path": scene_path, "playing_at_response": EditorInterface.is_playing_scene(), "note": "Confirme o estado e a sessão viva após o próximo ciclo do editor."})


func _stop_scene(args: Dictionary) -> Dictionary:
	var owner = args.get("owner")
	var token = args.get("play_token")
	if typeof(owner) != TYPE_STRING or typeof(token) != TYPE_STRING or owner != _play_owner or token != _play_token or _play_token.is_empty():
		return _fail_typed("not_owner", "A sessão não pertence a este cliente MCP.")
	if not EditorInterface.is_playing_scene():
		_play_owner = ""
		_play_token = ""
		return _fail_typed("already_stopped", "A execução já terminou; nenhuma sessão foi encerrada.")
	EditorInterface.stop_playing_scene()
	_play_owner = ""
	_play_token = ""
	return _ok({"stop_requested": true, "play_token": token})


func _create_scene(args: Dictionary) -> Dictionary:
	var path = args.get("path")
	var root_type = args.get("root_type")
	var root_name = args.get("root_name")
	if typeof(path) != TYPE_STRING or not _valid_scene_path(path) or typeof(root_type) != TYPE_STRING or not root_type in ROOT_NODE_TYPES or typeof(root_name) != TYPE_STRING or not _valid_name(root_name):
		return _fail_typed("invalid_scene", "Caminho, tipo de raiz ou nome inválido.")
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail_typed("invalid_preview", "dry_run precisa ser booleano.")
	if FileAccess.file_exists(path) or ResourceLoader.exists(path):
		return _fail_typed("path_conflict", "O arquivo de cena já existe.")
	var parent: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(parent)):
		return _fail_typed("missing_directory", "O diretório de destino precisa existir.")
	var root := ClassDB.instantiate(root_type) as Node
	if root == null:
		return _fail_typed("invalid_type", "Tipo de raiz indisponível.")
	root.name = root_name
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	root.free()
	if pack_error != OK:
		return _fail_typed("pack_failed", "Não foi possível empacotar a nova cena.", {"godot_error": pack_error})
	if args.get("dry_run", false):
		return _ok({"applied": false, "path": path, "root_type": root_type, "root_name": root_name, "compensation": "revert_created_scene"})
	var save_error := ResourceSaver.save(packed, path)
	if save_error != OK:
		return _fail_typed("save_failed", "Não foi possível salvar a nova cena.", {"godot_error": save_error})
	var checksum := FileAccess.get_sha256(path)
	_created_scenes[path] = checksum
	return _ok({"applied": true, "path": path, "sha256": checksum, "root_type": root_type, "root_name": root_name, "undo_available": false, "compensation": "revert_created_scene"})


func _save_scene_as_checked(args: Dictionary) -> Dictionary:
	var checked := _checked_graph_root(args)
	if not checked.ok:
		return checked
	var root: Node = checked["root"]
	var path = args.get("path")
	if typeof(path) != TYPE_STRING or not _valid_scene_path(path) or path == root.scene_file_path:
		return _fail_typed("invalid_path", "Informe novo caminho .tscn dentro do projeto.")
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail_typed("invalid_preview", "dry_run precisa ser booleano.")
	if FileAccess.file_exists(path) or ResourceLoader.exists(path):
		return _fail_typed("path_conflict", "O caminho de destino já existe.")
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path.get_base_dir())):
		return _fail_typed("missing_directory", "O diretório de destino precisa existir.")
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "source_path": root.scene_file_path, "path": path, "revision_checked": checked["revision"], "compensation": "revert_created_scene"})
	var source_path := root.scene_file_path
	EditorInterface.save_scene_as(path, false)
	if not FileAccess.file_exists(path):
		return _fail_typed("save_failed", "O editor não criou a cena no destino.")
	var checksum := FileAccess.get_sha256(path)
	_created_scenes[path] = checksum
	return _ok({"applied": true, "source_path": source_path, "path": path, "sha256": checksum, "active_scene_path": root.scene_file_path, "undo_available": false, "compensation": "revert_created_scene"})


func _resource_uid(args: Dictionary) -> Dictionary:
	var path = args.get("path")
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or not FileAccess.file_exists(path):
		return _fail_typed("invalid_resource", "Recurso inexistente no projeto.")
	var uid := ResourceUID.path_to_uid(path)
	return _ok({"path": path, "uid": uid if uid.begins_with("uid://") else null, "associated": uid.begins_with("uid://"), "origin": "ResourceUID.path_to_uid_editor_cache", "note": "Associação no cache do editor; não valida sidecar, importação nem consumidores."})


func _revert_created_scene(args: Dictionary) -> Dictionary:
	var path = args.get("path")
	var checksum = args.get("expected_sha256")
	if typeof(path) != TYPE_STRING or not _valid_scene_path(path) or typeof(checksum) != TYPE_STRING or checksum.length() != 64 or _created_scenes.get(path, "") != checksum:
		return _fail_typed("not_created_here", "A cena não foi criada nesta sessão do plugin ou a prova não confere.")
	if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != checksum:
		return _fail_typed("file_conflict", "O arquivo mudou desde a criação; remoção recusada.")
	var active := _active_root()
	if (active != null and active.scene_file_path == path) or path in EditorInterface.get_open_scenes():
		return _fail_typed("scene_open", "Feche a cena criada antes de compensar a criação.")
	if EditorInterface.is_playing_scene():
		return _fail_typed("scene_playing", "Pare a execução antes de compensar a criação.")
	if not EditorInterface.get_unsaved_scenes().is_empty():
		return _fail_typed("unsaved_scene", "Há cenas abertas não salvas; compensação recusada.")
	var uid := ResourceUID.path_to_uid(path)
	var uid_id := ResourceUID.text_to_id(uid) if uid.begins_with("uid://") else ResourceUID.INVALID_ID
	var uid_owned: bool = uid_id != ResourceUID.INVALID_ID and ResourceUID.has_id(uid_id) and ResourceUID.get_id_path(uid_id) == path
	var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if remove_error != OK:
		return _fail_typed("remove_failed", "Não foi possível remover a cena criada.", {"godot_error": remove_error})
	if uid_owned:
		ResourceUID.remove_id(uid_id)
	_created_scenes.erase(path)
	return _ok({"reverted": true, "path": path, "sha256": checksum, "uid_cache_invalidated": uid_owned})


func _instance_scene_checked(args: Dictionary) -> Dictionary:
	var checked := _checked_graph_root(args)
	if not checked.ok:
		return checked
	var root: Node = checked["root"]
	var source_path = args.get("source_path")
	var expected_source_sha256 = args.get("expected_source_sha256")
	var parent_path = args.get("parent_path")
	var node_name = args.get("name")
	if typeof(source_path) != TYPE_STRING or not _valid_scene_path(source_path) or source_path == root.scene_file_path or typeof(parent_path) != TYPE_STRING or typeof(node_name) != TYPE_STRING or not _valid_name(node_name):
		return _fail_typed("invalid_target", "Subcena, pai ou nome inválido.")
	if typeof(expected_source_sha256) != TYPE_STRING or expected_source_sha256.length() != 64 or not expected_source_sha256.is_valid_hex_number():
		return _fail_typed("invalid_precondition", "Informe SHA-256 da subcena.")
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail_typed("invalid_preview", "dry_run precisa ser booleano.")
	if not FileAccess.file_exists(source_path):
		return _fail_typed("missing_scene", "Subcena não encontrada.")
	if FileAccess.get_sha256(source_path) != expected_source_sha256:
		return _fail_typed("source_conflict", "Subcena mudou desde a leitura.")
	var parent := _find_node(root, parent_path)
	if parent == null or parent.has_node(NodePath(node_name)):
		return _fail_typed("parent_conflict", "Pai inexistente ou nome já utilizado.")
	var planned_path: String = node_name if parent == root else str(root.get_path_to(parent)).path_join(node_name)
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "source_path": source_path, "source_sha256": expected_source_sha256, "node_path": planned_path, "revision_checked": checked["revision"], "resource_load_pending": true})
	# ResourceLoader e PackedScene.instantiate podem executar codigo do projeto.
	var source = ResourceLoader.load(source_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if source == null:
		return _fail_typed("load_failed", "A subcena não pôde ser carregada.")
	if FileAccess.get_sha256(source_path) != expected_source_sha256:
		return _fail_typed("source_conflict", "Subcena mudou durante o carregamento.")
	var instance := source.instantiate()
	if instance == null:
		return _fail_typed("instantiate_failed", "A subcena não pôde ser instanciada.")
	if FileAccess.get_sha256(source_path) != expected_source_sha256:
		instance.free()
		return _fail_typed("source_conflict", "Subcena mudou durante a instanciação.")
	instance.name = node_name
	var history := get_undo_redo()
	history.create_action("MCP: instanciar %s" % node_name, UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "add_child", instance)
	history.add_do_method(instance, "set_owner", root)
	history.add_do_reference(instance)
	history.add_undo_method(parent, "remove_child", instance)
	history.commit_action()
	return _ok({"applied": true, "source_path": source_path, "source_sha256": expected_source_sha256, "node_path": str(root.get_path_to(instance)), "revision_before": checked["revision"], "reread_required": true, "undo_available": true})


func _valid_scene_path(path: String) -> bool:
	if not path.begins_with("res://") or not path.ends_with(".tscn"):
		return false
	for part in path.trim_prefix("res://").split("/"):
		if part in ["", ".", ".."] or part.begins_with(".") or part.contains("\\") or part.contains(":"):
			return false
	return true


func _active_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _find_node(root: Node, path: String) -> Node:
	if path == ".":
		return root
	if path.is_empty() or path.begins_with("/") or path.contains(":") or path.contains("\\"):
		return null
	for part in path.split("/"):
		if part in ["", ".", ".."]:
			return null
	var node := root.get_node_or_null(NodePath(path))
	if node != null and (node == root or node.owner == root):
		return node
	return null


func _valid_name(name: String) -> bool:
	if name.is_empty() or name.length() > 64:
		return false
	var alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
	var digits := "0123456789"
	if not alphabet.contains(name[0]):
		return false
	for letter in name:
		if not alphabet.contains(letter) and not digits.contains(letter):
			return false
	return true


func _add_node(args: Dictionary) -> Dictionary:
	var root := _active_root()
	if root == null:
		return _fail("Abra uma cena antes de editar")
	var parent := _find_node(root, str(args.get("parent_path", ".")))
	var node_type := str(args.get("node_type", ""))
	var node_name := str(args.get("name", ""))
	if parent == null or not _valid_name(node_name) or not node_type in ALLOWED_NODE_TYPES:
		return _fail("Pai, nome ou tipo de no invalido")
	if parent.has_node(NodePath(node_name)):
		return _fail("Ja existe um filho com esse nome")
	var node := ClassDB.instantiate(node_type) as Node
	if node == null:
		return _fail("Nao foi possivel instanciar o tipo")
	node.name = node_name
	var history := get_undo_redo()
	history.create_action("MCP: adicionar %s" % node_name, UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "add_child", node)
	history.add_do_method(node, "set_owner", root)
	history.add_do_reference(node)
	history.add_undo_method(parent, "remove_child", node)
	history.commit_action()
	return _ok({"node_path": str(root.get_path_to(node)), "node_type": node_type, "scene_path": root.scene_file_path})


func _checked_graph_root(args: Dictionary) -> Dictionary:
	var root := _active_root()
	if root == null or not _valid_scene_path(root.scene_file_path):
		return _fail_typed("no_saved_scene", "Abra uma cena .tscn salva antes da operação protegida.")
	if typeof(args.get("expected_scene_path")) != TYPE_STRING or args["expected_scene_path"] != root.scene_file_path:
		return _fail_typed("scene_conflict", "A cena ativa mudou desde a leitura.", {"actual_scene_path": root.scene_file_path})
	var expected = args.get("expected_graph_revision")
	if typeof(expected) != TYPE_STRING or str(expected).length() != 64 or not str(expected).is_valid_hex_number():
		return _fail_typed("invalid_revision", "Informe a revisão de godot_dependency_graph.")
	var scene_revision := _scene_revision(root)
	if scene_revision.is_empty():
		return _fail_typed("scene_too_large", "A projeção da cena excede o limite de 300 nós.")
	var graph: Dictionary = DEPENDENCY_GRAPH_SCRIPT.new().build(root, scene_revision)
	for limited in graph["truncated"].values():
		if limited:
			return _fail_typed("graph_incomplete", "O grafo ultrapassou um limite; a operação protegida foi recusada.")
	if expected != graph["revision"]:
		return _fail_typed("revision_conflict", "O grafo da cena mudou desde a leitura.", {"actual_revision": graph["revision"]})
	return {"ok": true, "root": root, "revision": graph["revision"]}


func _add_node_checked(args: Dictionary) -> Dictionary:
	var checked := _checked_graph_root(args)
	if not checked.ok:
		return checked
	var root: Node = checked["root"]
	if typeof(args.get("parent_path")) != TYPE_STRING or typeof(args.get("node_type")) != TYPE_STRING or typeof(args.get("name")) != TYPE_STRING:
		return _fail_typed("invalid_target", "Pai, tipo e nome precisam ser textos.")
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail_typed("invalid_preview", "dry_run precisa ser booleano.")
	var parent := _find_node(root, args["parent_path"])
	var node_type: String = args["node_type"]
	var node_name: String = args["name"]
	if parent == null or not node_type in ALLOWED_NODE_TYPES or not _valid_name(node_name):
		return _fail_typed("invalid_target", "Pai, tipo ou nome fora da lista permitida.")
	if parent.has_node(NodePath(node_name)):
		return _fail_typed("name_conflict", "O pai já contém um nó com esse nome.")
	var properties = args.get("properties", {})
	if typeof(properties) != TYPE_DICTIONARY or properties.size() > 8:
		return _fail_typed("invalid_properties", "Informe até oito propriedades tipadas.")
	var node := ClassDB.instantiate(node_type) as Node
	if node == null:
		return _fail_typed("invalid_type", "Não foi possível criar o tipo permitido.")
	node.name = node_name
	var applied := {}
	for property_name in properties:
		if typeof(property_name) != TYPE_STRING or not _property_allowed(node, property_name):
			node.free()
			return _fail_typed("invalid_property", "Propriedade fora da lista permitida.")
		var decoded := _decode_value(property_name, properties[property_name])
		if not decoded.ok:
			node.free()
			return _fail_typed("invalid_value", "Uma propriedade não corresponde ao tipo permitido.")
		node.set(property_name, decoded.result.value)
		applied[property_name] = _encode_value(node.get(property_name))
	var planned_path := node_name if parent == root else str(root.get_path_to(parent)).path_join(node_name)
	if args.get("dry_run", false):
		node.free()
		return _ok({"applied": false, "dry_run": true, "scene_path": root.scene_file_path, "revision_checked": checked["revision"], "change": {"kind": "add_node", "parent_path": args["parent_path"], "node_path": planned_path, "node_type": node_type, "properties": applied}, "undo_available": false})
	var history := get_undo_redo()
	history.create_action("MCP: criar %s" % node_name, UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "add_child", node)
	history.add_do_method(node, "set_owner", root)
	history.add_do_reference(node)
	history.add_undo_method(parent, "remove_child", node)
	history.commit_action()
	return _ok({"applied": true, "scene_path": root.scene_file_path, "node_path": str(root.get_path_to(node)), "node_type": node_type, "properties": applied, "revision_before": checked["revision"], "revision_after": null, "reread_required": true, "undo_available": true})


func _connect_signal_checked(args: Dictionary) -> Dictionary:
	var checked := _checked_graph_root(args)
	if not checked.ok:
		return checked
	var root: Node = checked["root"]
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail_typed("invalid_preview", "dry_run precisa ser booleano.")
	for key in ["source_path", "signal", "target_path", "method"]:
		if typeof(args.get(key)) != TYPE_STRING:
			return _fail_typed("invalid_target", "Origem, sinal, destino e método precisam ser textos.")
	var source := _find_node(root, args["source_path"])
	var target := _find_node(root, args["target_path"])
	var signal_name: String = args["signal"]
	var method_name: String = args["method"]
	if source == null or target == null or not _valid_name(signal_name) or not _valid_name(method_name) or not method_name.begins_with("_on_"):
		return _fail_typed("invalid_target", "Conexão fora da cena ou nomes não permitidos.")
	var target_script := target.get_script() as Script
	if not source.has_signal(signal_name) or target_script == null or not target.has_method(method_name):
		return _fail_typed("invalid_signature", "Sinal ou método de script inexistente.")
	var signal_arguments := -1
	var signal_args: Array = []
	for signal_info in source.get_signal_list():
		if str(signal_info["name"]) == signal_name:
			signal_args = signal_info.get("args", []) as Array
			signal_arguments = signal_args.size()
			break
	var method_arguments := -1
	var defaults := 0
	var method_args: Array = []
	for method_info in target_script.get_script_method_list():
		if str(method_info["name"]) == method_name:
			method_args = method_info.get("args", []) as Array
			method_arguments = method_args.size()
			defaults = (method_info.get("default_args", []) as Array).size()
			break
	if signal_arguments < 0 or method_arguments < 0 or signal_arguments < method_arguments - defaults or signal_arguments > method_arguments:
		return _fail_typed("invalid_signature", "Quantidade de argumentos do sinal e do método incompatível.")
	for index in range(signal_arguments):
		var signal_arg: Dictionary = signal_args[index]
		var method_arg: Dictionary = method_args[index]
		var source_type := int(signal_arg.get("type", -1))
		var target_type := int(method_arg.get("type", -1))
		if source_type < 0 or target_type < 0 or (target_type != TYPE_NIL and target_type != source_type):
			return _fail_typed("invalid_signature", "Tipos de argumentos do sinal e do método incompatíveis.")
		if source_type == TYPE_OBJECT and target_type == TYPE_OBJECT:
			var target_class := str(method_arg.get("class_name", ""))
			if not target_class.is_empty() and target_class != str(signal_arg.get("class_name", "")):
				return _fail_typed("invalid_signature", "Classe do argumento do sinal não confere com o método.")
	var callable := Callable(target, method_name)
	if source.is_connected(signal_name, callable):
		return _fail_typed("connection_conflict", "O sinal já está conectado a esse método.")
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "scene_path": root.scene_file_path, "revision_checked": checked["revision"], "change": {"kind": "connect_signal", "source_path": args["source_path"], "signal": signal_name, "target_path": args["target_path"], "method": method_name, "persistent": true}, "undo_available": false})
	var history := get_undo_redo()
	history.create_action("MCP: conectar %s.%s" % [args["source_path"], signal_name], UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(source, "connect", signal_name, callable, Object.CONNECT_PERSIST)
	history.add_undo_method(source, "disconnect", signal_name, callable)
	history.commit_action()
	return _ok({"applied": true, "scene_path": root.scene_file_path, "source_path": args["source_path"], "signal": signal_name, "target_path": args["target_path"], "method": method_name, "revision_before": checked["revision"], "revision_after": null, "reread_required": true, "undo_available": true})


func _property_allowed(node: Node, property_name: String) -> bool:
	match property_name:
		"position":
			return node is Node2D or node is Control
		"size":
			return node is Control
		"rotation_degrees", "scale":
			return node is Node2D
		"visible", "modulate":
			return node is CanvasItem
		"text":
			return node is Label or node is Button
		"color":
			return node is ColorRect
		_:
			return false


func _decode_value(property_name: String, value: Variant) -> Dictionary:
	match property_name:
		"position", "size", "scale":
			if typeof(value) != TYPE_ARRAY or value.size() != 2:
				return _fail("Valor esperado: [x, y]")
			if typeof(value[0]) not in [TYPE_INT, TYPE_FLOAT] or typeof(value[1]) not in [TYPE_INT, TYPE_FLOAT]:
				return _fail("Coordenadas devem ser numeros")
			if not is_finite(float(value[0])) or not is_finite(float(value[1])) or absf(float(value[0])) > 1000000.0 or absf(float(value[1])) > 1000000.0:
				return _fail("Coordenadas devem ser finitas e ter módulo até 1000000")
			return _ok({"value": Vector2(float(value[0]), float(value[1]))})
		"rotation_degrees":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
				return _fail("Rotacao deve ser numero")
			if not is_finite(float(value)) or absf(float(value)) > 1000000.0:
				return _fail("Rotação deve ser finita e ter módulo até 1000000")
			return _ok({"value": float(value)})
		"visible":
			if typeof(value) != TYPE_BOOL:
				return _fail("Visibilidade deve ser booleana")
			return _ok({"value": value})
		"text":
			if typeof(value) != TYPE_STRING or value.length() > 1000:
				return _fail("Texto deve ter no maximo 1000 caracteres")
			return _ok({"value": value})
		"color", "modulate":
			if typeof(value) != TYPE_STRING or not Color.html_is_valid(value):
				return _fail("Cor deve ser hexadecimal, por exemplo #478cbf")
			return _ok({"value": Color.html(value)})
		_:
			return _fail("Propriedade nao permitida")


func _encode_value(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Color:
		return "#" + value.to_html(true)
	return value


func _set_property(args: Dictionary) -> Dictionary:
	var root := _active_root()
	if root == null:
		return _fail("Abra uma cena antes de editar")
	var path := str(args.get("node_path", ""))
	var node := _find_node(root, path)
	var property_name := str(args.get("property", ""))
	if node == null or not _property_allowed(node, property_name):
		return _fail("No ou propriedade fora da lista permitida")
	var parsed := _decode_value(property_name, args.get("value"))
	if not parsed.ok:
		return parsed
	var old_value: Variant = node.get(property_name)
	var new_value: Variant = parsed.result.value
	var history := get_undo_redo()
	history.create_action("MCP: alterar %s de %s" % [property_name, path], UndoRedo.MERGE_DISABLE, root)
	history.add_do_property(node, property_name, new_value)
	history.add_undo_property(node, property_name, old_value)
	history.commit_action()
	return _ok({"node_path": path, "property": property_name, "old_value": _encode_value(old_value), "value": _encode_value(node.get(property_name))})


func _set_property_checked(args: Dictionary) -> Dictionary:
	var root := _active_root()
	if root == null:
		return _fail_typed("no_scene", "Abra uma cena antes de editar.")
	if not _valid_scene_path(root.scene_file_path):
		return _fail_typed("unsaved_scene", "A cena precisa estar salva em res:// antes da operação protegida.")
	var expected_scene = args.get("expected_scene_path")
	if typeof(expected_scene) != TYPE_STRING or expected_scene != root.scene_file_path:
		return _fail_typed("scene_conflict", "A cena ativa mudou desde a leitura.", {"actual_scene_path": root.scene_file_path})
	var expected_revision = args.get("expected_revision")
	if typeof(expected_revision) != TYPE_STRING or str(expected_revision).length() != 64:
		return _fail_typed("invalid_revision", "Informe a revisão de godot_scene_tree.")
	var current_revision := _scene_revision(root)
	if current_revision.is_empty():
		return _fail_typed("scene_too_large", "A projeção da cena excede o limite de 300 nós.")
	if expected_revision != current_revision:
		return _fail_typed("revision_conflict", "A cena editada mudou desde a leitura.", {"actual_revision": current_revision})
	var path = args.get("node_path")
	var property_name = args.get("property")
	if typeof(path) != TYPE_STRING or typeof(property_name) != TYPE_STRING:
		return _fail_typed("invalid_target", "Caminho e propriedade precisam ser textos.")
	var node := _find_node(root, path)
	if node == null or not _property_allowed(node, property_name):
		return _fail_typed("invalid_target", "Nó ou propriedade fora da lista permitida.")
	if not args.has("expected_value") or not args.has("value"):
		return _fail_typed("missing_value", "Informe valor esperado e novo valor.")
	var expected_parsed := _decode_value(property_name, args["expected_value"])
	var new_parsed := _decode_value(property_name, args["value"])
	if not expected_parsed.ok or not new_parsed.ok:
		return _fail_typed("invalid_value", "Um dos valores não corresponde ao tipo permitido da propriedade.")
	var old_value: Variant = node.get(property_name)
	if old_value != expected_parsed.result.value:
		return _fail_typed("value_conflict", "O valor atual não corresponde ao esperado.", {"actual_value": _encode_value(old_value)})
	var new_value: Variant = new_parsed.result.value
	if new_value == old_value:
		return _ok({"scene_path": root.scene_file_path, "node_path": path, "property": property_name, "revision_before": current_revision, "revision_after": current_revision, "old_value": _encode_value(old_value), "value": _encode_value(old_value), "applied": false})
	var history := get_undo_redo()
	history.create_action("MCP: alterar %s de %s" % [property_name, path], UndoRedo.MERGE_DISABLE, root)
	history.add_do_property(node, property_name, new_value)
	history.add_undo_property(node, property_name, old_value)
	history.commit_action()
	return _ok({"scene_path": root.scene_file_path, "node_path": path, "property": property_name, "revision_before": current_revision, "revision_after": null, "reread_required": true, "old_value": _encode_value(old_value), "value": _encode_value(node.get(property_name)), "applied": true, "undo_available": true})


func _remove_leaf(args: Dictionary) -> Dictionary:
	var root := _active_root()
	if root == null:
		return _fail("Abra uma cena antes de editar")
	var path := str(args.get("node_path", ""))
	var node := _find_node(root, path)
	if node == null or node == root or node.get_child_count() != 0:
		return _fail("A remocao exige um no folha pertencente a cena")
	var parent := node.get_parent()
	var index := node.get_index()
	var history := get_undo_redo()
	history.create_action("MCP: remover %s" % path, UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "remove_child", node)
	history.add_undo_method(parent, "add_child", node)
	history.add_undo_method(parent, "move_child", node, index)
	history.add_undo_method(node, "set_owner", root)
	history.add_undo_reference(node)
	history.commit_action()
	return _ok({"removed_path": path, "scene_path": root.scene_file_path})


func _history_action(redo: bool) -> Dictionary:
	var root := _active_root()
	if root == null:
		return _fail("Nenhuma cena aberta")
	var manager := get_undo_redo()
	if not manager.has_method("undo_history") or not manager.has_method("redo_history"):
		return _fail_typed("safe_history_unavailable", "Use um binário customizado com histórico protegido do editor; a API deste binário não permite reversão segura por cena.")
	var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
	if history == null:
		return _fail("Historico indisponivel")
	if redo:
		if not history.has_redo() or not history.get_action_name(history.get_current_action() + 1).begins_with("MCP: "):
			return _fail("A proxima acao nao pertence ao MCP")
		if not manager.call("redo_history", manager.get_object_history_id(root)):
			return _fail_typed("history_rejected", "O gerenciador recusou Refazer; releia o estado da cena.")
	else:
		if not history.has_undo() or not history.get_current_action_name().begins_with("MCP: "):
			return _fail("A ultima acao nao pertence ao MCP")
		if not manager.call("undo_history", manager.get_object_history_id(root)):
			return _fail_typed("history_rejected", "O gerenciador recusou Desfazer; releia o estado da cena.")
	return _ok({"operation": "redo" if redo else "undo", "scene_path": root.scene_file_path})


func _save_scene() -> Dictionary:
	var root := _active_root()
	if root == null or not _valid_scene_path(root.scene_file_path):
		return _fail("A cena ativa precisa estar salva em res:// como .tscn")
	# A miniatura usa o renderer do editor e falha em --headless. A API permite
	# salvar a cena ativa sem preview, tanto no editor grafico como no headless.
	EditorInterface.save_scene_as(root.scene_file_path, false)
	if not FileAccess.file_exists(root.scene_file_path):
		return _fail("A cena nao foi gravada no caminho esperado")
	return _ok({"scene_path": root.scene_file_path, "saved": true})


func _audit(request: Dictionary, response: Dictionary) -> void:
	var directory := DirAccess.open(_bridge_dir)
	if directory == null or directory.is_link("audit.jsonl") or directory.is_link("audit.jsonl.1"):
		return
	var args = request.get("args", {})
	var target := {}
	var preconditions := {}
	if typeof(args) == TYPE_DICTIONARY:
		for key in ["path", "scene_path", "source_path", "output_path", "resource_path", "node_path"]:
			if typeof(args.get(key)) == TYPE_STRING:
				target[key] = (args[key] as String).substr(0, 256)
		for key in ["expected_sha256", "expected_current_sha256", "expected_scene_sha256", "expected_source_sha256", "expected_graph_revision", "expected_revision", "expected_disk_sha256"]:
			if typeof(args.get(key)) == TYPE_STRING:
				preconditions[key] = (args[key] as String).substr(0, 80)
	var trace = request.get("id")
	if typeof(trace) != TYPE_STRING or trace.length() != 32 or not trace.is_valid_hex_number():
		trace = str(Time.get_ticks_usec())
	var entry := {"time_utc": Time.get_datetime_string_from_system(true, true), "trace_id": trace, "operation": str(request.get("op", "?")).substr(0, 80), "target": target, "preconditions": preconditions, "ok": response.get("ok", false), "result_code": str(response.get("error_code", "ok" if response.get("ok", false) else "error")).substr(0, 80)}
	var line := JSON.stringify(entry) + "\n"
	if line.to_utf8_buffer().size() > 2048:
		return
	var path := _bridge_dir.path_join("audit.jsonl")
	if FileAccess.file_exists(path):
		var existing := FileAccess.open(path, FileAccess.READ)
		if existing == null:
			return
		var rotate := existing.get_length() + line.to_utf8_buffer().size() > 1048576
		existing.close()
		if rotate:
			var previous := _bridge_dir.path_join("audit.jsonl.1")
			if FileAccess.file_exists(previous) and DirAccess.remove_absolute(previous) != OK:
				return
			if DirAccess.rename_absolute(path, previous) != OK:
				return
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_string(line)
	file.flush()
	file.close()
