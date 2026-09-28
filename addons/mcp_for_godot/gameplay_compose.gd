@tool
extends RefCounted

# Lote pequeno para compor cenas reais. Recursos novos pertencem somente aos nos
# criados; arquivos de imagem existentes sao associados apos conferir o hash.
const MAX_NODES := 24
const MAX_ASSET_BYTES := 16777216
const PROBE_SCRIPT := "res://addons/mcp_for_godot/runtime_probe.gd"
const NODE_TYPES := ["Node2D", "CharacterBody2D", "StaticBody2D", "Area2D", "CollisionShape2D", "Sprite2D", "AnimatedSprite2D", "CanvasLayer", "Label", "Node3D", "CharacterBody3D", "StaticBody3D", "Area3D", "CollisionShape3D", "MeshInstance3D", "Sprite3D", "Camera3D", "DirectionalLight3D", "MCPForGodotRuntimeProbe"]


func _fail(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error_code": code, "error": message, "error_details": details}


func _ok(result: Dictionary) -> Dictionary:
	return {"ok": true, "result": result}


func _abort(top_nodes: Array[Node], code: String, message: String, details: Dictionary = {}) -> Dictionary:
	for node in top_nodes:
		node.free()
	return _fail(code, message, details)


func _count_runtime_probes(node: Node) -> int:
	var count := 0
	var script = node.get_script()
	if script is Script and (script as Script).resource_path == PROBE_SCRIPT:
		count = 1
	for child in node.get_children():
		count += _count_runtime_probes(child)
	return count


func _number(value: Variant, positive: bool = false) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and absf(float(value)) <= 1000000.0 and (not positive or float(value) > 0.0)


func _vector(value: Variant, count: int, positive: bool = false) -> Variant:
	if typeof(value) != TYPE_ARRAY or value.size() != count:
		return null
	for part in value:
		if not _number(part, positive):
			return null
	if count == 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _safe_asset_path(path: String) -> bool:
	if not path.begins_with("res://") or path.length() > 512 or path.contains("\\") or path.contains("::"):
		return false
	var directory := DirAccess.open("res://")
	if directory == null:
		return false
	var prefix := "res://"
	for part in path.trim_prefix("res://").split("/"):
		if part.is_empty() or part in [".", ".."] or part.begins_with(".") or part.contains(":"):
			return false
		prefix = prefix.path_join(part)
		if directory.is_link(prefix):
			return false
	return true


func _texture_asset(spec: Variant, dry_run: bool) -> Dictionary:
	if typeof(spec) != TYPE_DICTIONARY or spec.size() != 2 or not spec.has("path") or not spec.has("sha256"):
		return _fail("invalid_asset_path", "Imagem exige path e sha256, sem campos adicionais.")
	var path = spec["path"]
	var expected = spec["sha256"]
	if typeof(path) != TYPE_STRING or typeof(expected) != TYPE_STRING or expected.length() != 64 or not expected.is_valid_hex_number() or not _safe_asset_path(path) or path.get_extension().to_lower() not in ["png", "jpg", "jpeg", "webp"]:
		return _fail("invalid_asset_path", "Imagem deve ser PNG/JPEG/WebP local com SHA-256.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_ASSET_BYTES:
		return _fail("invalid_asset_size", "Imagem ausente ou acima de 16 MiB.")
	var bytes := file.get_length()
	file.close()
	if FileAccess.get_sha256(path) != expected:
		return _fail("asset_conflict", "Hash da imagem diferente do esperado.")
	if not ResourceLoader.exists(path, "Texture2D"):
		return _fail("asset_not_imported", "Imagem ainda nao foi importada como Texture2D.")
	if dry_run:
		return {"ok": true, "bytes": bytes, "load_pending": true}
	var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
	if texture == null:
		return _fail("asset_load_failed", "Imagem importada nao carregou como Texture2D.")
	if FileAccess.get_sha256(path) != expected:
		return _fail("asset_conflict", "Imagem mudou durante o carregamento.")
	return {"ok": true, "texture": texture, "bytes": bytes}


func _configure(node: Node, properties: Dictionary, resource_spec: Variant, dry_run: bool = false) -> Dictionary:
	if properties.size() > 8:
		return _fail("invalid_properties", "Cada no aceita ate oito propriedades.")
	for key in properties:
		if typeof(key) != TYPE_STRING:
			return _fail("invalid_property", "Nome de propriedade deve ser texto.")
		var value: Variant = properties[key]
		match key:
			"position", "scale", "rotation_degrees":
				if node is Control and key == "position":
					value = _vector(value, 2)
				elif node is Node2D:
					value = _vector(value, 2, key == "scale") if key != "rotation_degrees" else (float(value) if _number(value) else null)
				elif node is Node3D:
					value = _vector(value, 3, key == "scale")
				else:
					return _fail("invalid_property", "Transform nao pertence ao tipo de no.")
			"size":
				if node is not Control:
					return _fail("invalid_property", "Tamanho de UI exige Control.")
				value = _vector(value, 2, true)
			"text":
				if node is not Label or typeof(value) != TYPE_STRING or value.length() > 1000:
					return _fail("invalid_value", "Texto exige Label e ate 1000 caracteres.")
			"visible":
				if not (node is CanvasItem or node is Node3D) or typeof(value) != TYPE_BOOL:
					return _fail("invalid_value", "Visibilidade deve ser booleana.")
			"color":
				return _fail("invalid_property", "Cor deve ser configurada no material do recurso.")
			_:
				return _fail("invalid_property", "Propriedade fora do contrato.", {"property": key})
		if value == null:
			return _fail("invalid_value", "Vetor ou numero fora dos limites.", {"property": key})
		node.set(key, value)
	if resource_spec == null:
		return {"ok": true}
	if typeof(resource_spec) != TYPE_DICTIONARY or typeof(resource_spec.get("type")) != TYPE_STRING:
		return _fail("invalid_resource", "Recurso deve ter tipo explicito.")
	var kind: String = resource_spec["type"]
	var fields: Array = {
		"RectangleShape2D": ["type", "size"], "CircleShape2D": ["type", "radius"],
		"BoxShape3D": ["type", "size"], "SphereShape3D": ["type", "radius"],
		"BoxMesh": ["type", "size", "color"], "Texture2D": ["type", "path", "sha256"],
		"SpriteFrames": ["type", "animation", "fps", "loop", "frames"]
	}.get(kind, [])
	if fields.is_empty():
		return _fail("invalid_resource", "Tipo de recurso fora do contrato.")
	for field in resource_spec:
		if field not in fields:
			return _fail("invalid_resource", "Campo de recurso fora do contrato.", {"field": str(field)})
	var resource: Resource
	match kind:
		"RectangleShape2D":
			if node is not CollisionShape2D:
				return _fail("invalid_resource_target", "RectangleShape2D exige CollisionShape2D.")
			var size = _vector(resource_spec.get("size"), 2, true)
			if size == null:
				return _fail("invalid_resource", "Tamanho de retangulo invalido.")
			var shape := RectangleShape2D.new()
			shape.size = size
			resource = shape
		"CircleShape2D":
			if node is not CollisionShape2D or not _number(resource_spec.get("radius"), true):
				return _fail("invalid_resource", "CircleShape2D exige colisao 2D e raio positivo.")
			var shape := CircleShape2D.new()
			shape.radius = float(resource_spec["radius"])
			resource = shape
		"BoxShape3D":
			if node is not CollisionShape3D:
				return _fail("invalid_resource_target", "BoxShape3D exige CollisionShape3D.")
			var size = _vector(resource_spec.get("size"), 3, true)
			if size == null:
				return _fail("invalid_resource", "Tamanho de caixa invalido.")
			var shape := BoxShape3D.new()
			shape.size = size
			resource = shape
		"SphereShape3D":
			if node is not CollisionShape3D or not _number(resource_spec.get("radius"), true):
				return _fail("invalid_resource", "SphereShape3D exige colisao 3D e raio positivo.")
			var shape := SphereShape3D.new()
			shape.radius = float(resource_spec["radius"])
			resource = shape
		"BoxMesh":
			if node is not MeshInstance3D:
				return _fail("invalid_resource_target", "BoxMesh exige MeshInstance3D.")
			var size = _vector(resource_spec.get("size"), 3, true)
			if size == null:
				return _fail("invalid_resource", "Tamanho de malha invalido.")
			var mesh := BoxMesh.new()
			mesh.size = size
			if resource_spec.has("color"):
				if typeof(resource_spec["color"]) != TYPE_STRING or not Color.html_is_valid(resource_spec["color"]):
					return _fail("invalid_resource", "Cor de material invalida.")
				var material := StandardMaterial3D.new()
				material.albedo_color = Color.html(resource_spec["color"])
				mesh.material = material
			resource = mesh
		"Texture2D":
			if not (node is Sprite2D or node is Sprite3D):
				return _fail("invalid_resource_target", "Textura exige Sprite2D ou Sprite3D.")
			var asset := _texture_asset({"path": resource_spec.get("path"), "sha256": resource_spec.get("sha256")}, dry_run)
			if not asset.ok:
				return asset
			if not dry_run:
				resource = asset.texture
		"SpriteFrames":
			if node is not AnimatedSprite2D or (node as AnimatedSprite2D).sprite_frames != null:
				return _fail("invalid_resource_target", "SpriteFrames exige AnimatedSprite2D sem recurso previo.")
			var animation = resource_spec.get("animation")
			var fps = resource_spec.get("fps")
			var loop = resource_spec.get("loop")
			var frames = resource_spec.get("frames")
			if typeof(animation) != TYPE_STRING or animation.length() > 32 or not animation.is_valid_identifier() or not _number(fps, true) or float(fps) > 120.0 or typeof(loop) != TYPE_BOOL or typeof(frames) != TYPE_ARRAY or frames.is_empty() or frames.size() > 8:
				return _fail("invalid_resource", "Animacao exige nome, fps ate 120, loop e 1 a 8 imagens.")
			var seen := {}
			var total_bytes := 0
			var loaded_frames: Array[Texture2D] = []
			for frame in frames:
				var asset := _texture_asset(frame, dry_run)
				if not asset.ok:
					return asset
				if seen.has(frame["path"]):
					return _fail("duplicate_frame", "Cada quadro deve usar arquivo distinto.")
				seen[frame["path"]] = true
				total_bytes += int(asset.bytes)
				if total_bytes > MAX_ASSET_BYTES:
					return _fail("invalid_asset_size", "Soma das imagens excede 16 MiB.")
				if not dry_run:
					loaded_frames.append(asset.texture)
			if not dry_run:
				var sprite_frames := SpriteFrames.new()
				if not sprite_frames.has_animation(animation):
					sprite_frames.add_animation(animation)
				sprite_frames.set_animation_speed(animation, float(fps))
				sprite_frames.set_animation_loop(animation, loop)
				for frame in loaded_frames:
					sprite_frames.add_frame(animation, frame)
				resource = sprite_frames
		_:
			return _fail("invalid_resource", "Tipo de recurso fora do contrato.")
	if dry_run and resource == null:
		return {"ok": true, "asset_load_pending": true}
	if node is CollisionShape2D or node is CollisionShape3D:
		node.set("shape", resource)
	elif node is MeshInstance3D:
		node.set("mesh", resource)
	elif node is AnimatedSprite2D:
		node.set("sprite_frames", resource)
		node.set("animation", resource_spec["animation"])
		node.set("autoplay", resource_spec["animation"])
	else:
		node.set("texture", resource)
	return {"ok": true}


func compose(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var checked: Dictionary = plugin._checked_graph_root(args)
	if not checked.ok:
		return checked
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail("invalid_preview", "dry_run precisa ser booleano.")
	var specs = args.get("nodes")
	if typeof(specs) != TYPE_ARRAY or specs.is_empty() or specs.size() > MAX_NODES:
		return _fail("invalid_nodes", "Informe de um a 24 nos.")
	var root: Node = checked["root"]
	var parent_path = args.get("parent_path", ".")
	if typeof(parent_path) != TYPE_STRING:
		return _fail("invalid_parent", "parent_path deve ser texto.")
	var base: Node = plugin._find_node(root, parent_path)
	if base == null:
		return _fail("invalid_parent", "Pai fora da cena ativa.")
	var by_id := {}
	var created: Array[Node] = []
	var top_nodes: Array[Node] = []
	var paths := {}
	var planned_names := {}
	var probe_count := _count_runtime_probes(root)
	for spec in specs:
		if typeof(spec) != TYPE_DICTIONARY or typeof(spec.get("id")) != TYPE_STRING or typeof(spec.get("type")) != TYPE_STRING or typeof(spec.get("name")) != TYPE_STRING:
			return _abort(top_nodes, "invalid_node", "Cada no exige id, type e name.")
		for field in spec:
			if field not in ["id", "parent", "type", "name", "properties", "resource"]:
				return _abort(top_nodes, "invalid_node", "Campo de no fora do contrato.", {"field": str(field)})
		var id: String = spec["id"]
		var kind: String = spec["type"]
		var name: String = spec["name"]
		if not id.is_valid_identifier() or by_id.has(id) or kind not in NODE_TYPES or not plugin._valid_name(name):
			return _abort(top_nodes, "invalid_node", "Id, tipo ou nome invalido ou repetido.")
		if kind == "MCPForGodotRuntimeProbe":
			probe_count += 1
			if probe_count > 1:
				return _abort(top_nodes, "probe_conflict", "Somente um coletor de runtime por cena.")
		var parent_value = spec.get("parent", "")
		if typeof(parent_value) != TYPE_STRING:
			return _abort(top_nodes, "invalid_parent", "Pai local deve ser texto.")
		var parent_id: String = parent_value
		if not parent_id.is_empty() and not by_id.has(parent_id):
			return _abort(top_nodes, "invalid_parent", "Pai local precisa preceder o filho.")
		var parent: Node = by_id[parent_id] if not parent_id.is_empty() else base
		var planned_key: String = parent_id + "/" + name
		if planned_names.has(planned_key):
			return _abort(top_nodes, "name_conflict", "Dois nos do lote teriam o mesmo nome sob o mesmo pai.", {"name": name})
		if (kind == "CollisionShape2D" and parent is not CollisionObject2D) or (kind == "CollisionShape3D" and parent is not CollisionObject3D):
			return _abort(top_nodes, "invalid_parent", "CollisionShape exige CollisionObject da mesma dimensao.")
		if kind in ["Node3D", "CharacterBody3D", "StaticBody3D", "Area3D", "MeshInstance3D", "Sprite3D", "Camera3D", "DirectionalLight3D"] and parent is not Node3D:
			return _abort(top_nodes, "invalid_parent", "No 3D exige pai Node3D.")
		if parent.has_node(NodePath(name)):
			return _abort(top_nodes, "name_conflict", "O pai ja possui este nome.", {"name": name})
		var node := (Node.new() if kind == "MCPForGodotRuntimeProbe" else ClassDB.instantiate(kind)) as Node
		if node == null:
			return _abort(top_nodes, "invalid_node", "Falha ao instanciar tipo permitido.")
		node.name = name
		var properties = spec.get("properties", {})
		if typeof(properties) != TYPE_DICTIONARY:
			node.free()
			return _abort(top_nodes, "invalid_properties", "Propriedades devem formar um objeto.")
		var configured := _configure(node, properties, spec.get("resource"), args.get("dry_run", false))
		if not configured.ok:
			node.free()
			for top in top_nodes:
				top.free()
			return configured
		if kind == "MCPForGodotRuntimeProbe":
			if not properties.is_empty() or spec.get("resource") != null or not _safe_asset_path(PROBE_SCRIPT) or not FileAccess.file_exists(PROBE_SCRIPT):
				node.free()
				return _abort(top_nodes, "invalid_probe", "Coletor aceita somente script fixo existente do addon, sem propriedades ou recurso.")
			var expected_probe_sha256 := FileAccess.get_sha256(PROBE_SCRIPT)
			if not args.get("dry_run", false):
				# Carregar script pode executar inicializacao; wrapper exige --allow-run.
				var probe_script := ResourceLoader.load(PROBE_SCRIPT, "Script", ResourceLoader.CACHE_MODE_IGNORE) as Script
				if probe_script == null or probe_script.get_instance_base_type() != "Node" or FileAccess.get_sha256(PROBE_SCRIPT) != expected_probe_sha256:
					node.free()
					return _abort(top_nodes, "probe_conflict", "Script fixo do coletor nao carregou, mudou ou tem base inesperada.")
				node.set_script(probe_script)
		if not parent_id.is_empty():
			parent.add_child(node)
		else:
			top_nodes.append(node)
		by_id[id] = node
		planned_names[planned_key] = true
		created.append(node)
		paths[id] = (str(paths[parent_id]).path_join(name) if not parent_id.is_empty() else (name if base == root else str(root.get_path_to(base)).path_join(name)))
	if args.get("dry_run", false):
		for node in top_nodes:
			node.free()
		return _ok({"applied": false, "dry_run": true, "scene_path": root.scene_file_path, "revision_checked": checked["revision"], "node_paths": paths, "undo_available": false})
	var history := plugin.get_undo_redo()
	history.create_action("MCP: compor nos de gameplay", UndoRedo.MERGE_DISABLE, root)
	for node in top_nodes:
		history.add_do_method(base, "add_child", node)
		history.add_undo_method(base, "remove_child", node)
		history.add_do_reference(node)
	for node in created:
		history.add_do_method(node, "set_owner", root)
	history.commit_action()
	return _ok({"applied": true, "scene_path": root.scene_file_path, "revision_before": checked["revision"], "revision_after": null, "reread_required": true, "node_paths": paths, "undo_available": true})


func attach_script(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var checked: Dictionary = plugin._checked_graph_root(args)
	if not checked.ok:
		return checked
	if typeof(args.get("dry_run", false)) != TYPE_BOOL:
		return _fail("invalid_preview", "dry_run precisa ser booleano.")
	var node_path = args.get("node_path")
	var script_path = args.get("script_path")
	var expected_hash = args.get("script_sha256")
	if typeof(node_path) != TYPE_STRING or typeof(script_path) != TYPE_STRING or typeof(expected_hash) != TYPE_STRING:
		return _fail("invalid_script_target", "Caminho de no, script e SHA-256 sao obrigatorios.")
	if not _safe_asset_path(script_path) or script_path.get_extension().to_lower() != "gd":
		return _fail("invalid_script_path", "Script deve ser um .gd dentro do projeto.")
	if expected_hash.length() != 64 or not expected_hash.is_valid_hex_number():
		return _fail("invalid_script_hash", "Informe SHA-256 hexadecimal.")
	var root: Node = checked["root"]
	var node: Node = plugin._find_node(root, node_path)
	if node == null or node.get_script() != null:
		return _fail("script_target_conflict", "No fora da cena ou ja possui script.")
	if not FileAccess.file_exists(script_path):
		return _fail("missing_script", "Script nao existe.")
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null or file.get_length() > 131072:
		return _fail("invalid_script_size", "Script excede 128 KiB ou nao pode ser lido.")
	var source := file.get_as_text()
	file.close()
	if FileAccess.get_sha256(script_path) != expected_hash:
		return _fail("script_conflict", "Hash do script difere do esperado.")
	var blocked := RegEx.new()
	blocked.compile("(?i)@tool|\\b_static_init\\b|\\bstatic\\b|\\bclass_name\\b|\\b(preload|load)\\s*\\(|\\bextends\\s+[\"']")
	if blocked.search(source) != null:
		return _fail("script_scope_rejected", "Script contem inicializacao estatica, classe global, heranca por arquivo, @tool ou carga dinamica fora deste fluxo.")
	for open_script in EditorInterface.get_script_editor().get_open_scripts():
		if open_script is Script and open_script.resource_path == script_path:
			return _fail("script_open", "Feche o script no editor antes de associa-lo.")
	if args.get("dry_run", false):
		return _ok({"applied": false, "dry_run": true, "scene_path": root.scene_file_path, "revision_checked": checked["revision"], "node_path": node_path, "script_path": script_path, "script_sha256": expected_hash, "validation": "pending_load", "undo_available": false})
	# ResourceLoader pode executar inicializadores. Somente no apply com permissao
	# explicita de execucao e apos triagem lexical e de hash.
	var loaded := ResourceLoader.load(script_path, "Script", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if loaded == null:
		return _fail("script_load_failed", "ResourceLoader nao carregou o script.", {"reason": "load_null"})
	var reload_error := loaded.reload()
	if reload_error != OK:
		return _fail("script_load_failed", "Script carregado falhou ao compilar no editor.", {"reason": "reload_failed", "godot_error": reload_error})
	if loaded.source_code != source:
		return _fail("script_load_failed", "Fonte carregada difere do arquivo validado.", {"reason": "source_mismatch", "loaded_sha256": loaded.source_code.sha256_text(), "file_sha256": source.sha256_text()})
	if FileAccess.get_sha256(script_path) != expected_hash:
		return _fail("script_conflict", "Script mudou durante a validacao.")
	var base_type := loaded.get_instance_base_type()
	if base_type.is_empty() or not ClassDB.is_parent_class(node.get_class(), base_type):
		return _fail("script_base_mismatch", "Classe base do script nao corresponde ao no.", {"node_type": node.get_class(), "script_base": base_type})
	var history := plugin.get_undo_redo()
	history.create_action("MCP: associar script %s" % node_path, UndoRedo.MERGE_DISABLE, root)
	history.add_do_property(node, "script", loaded)
	history.add_undo_property(node, "script", null)
	history.commit_action()
	return _ok({"applied": true, "scene_path": root.scene_file_path, "revision_before": checked["revision"], "revision_after": null, "reread_required": true, "node_path": node_path, "script_path": script_path, "script_sha256": expected_hash, "undo_available": true})
