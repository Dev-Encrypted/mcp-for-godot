@tool
extends RefCounted

# Recursos compartilhados nunca são alterados in-place. A ação troca o recurso
# do nó por uma cópia local, preservando o original para Desfazer/Refazer.
const Probe = preload("res://addons/mcp_for_godot/graphics_probe.gd")
const PROPERTIES := ["visible", "modulate", "z_index", "texture_filter", "texture_repeat"]
const MAX_ASSET_BYTES := 16777216


func fail(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error_code": code, "error": message, "error_details": details}


func validate_shader(source: String, path: String) -> Dictionary:
	if source.to_utf8_buffer().size() > 131072:
		return {"status": "unavailable", "code": "shader_too_large"}
	var include_pattern := RegEx.new()
	# Conservador: o preprocessador remove comentários antes de ler diretivas.
	# A palavra também é recusada em comentários, impedindo esconder a diretiva.
	include_pattern.compile("\\binclude\\b")
	var comments := RegEx.new()
	comments.compile("(?s)/\\*.*?\\*/|//[^\\n]*")
	var without_comments := comments.sub(source, "", true)
	if include_pattern.search(source) != null or include_pattern.search(without_comments) != null:
		return {"status": "unavailable", "code": "include_scope_not_supported", "message": "A ferramenta aceita shader de arquivo único; includes precisam de escopo e revisão próprios."}
	if not ClassDB.class_has_method("Shader", "validate_source"):
		return {"status": "unavailable", "code": "native_validation_unavailable"}
	return ClassDB.class_call_static("Shader", "validate_source", source, path)


func safe_path(path: String) -> bool:
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


func asset(path: String) -> Dictionary:
	if not safe_path(path) or path.get_extension().to_lower() not in ["png", "jpg", "jpeg", "webp", "gdshader"]:
		return fail("invalid_asset_path", "Use textura PNG/JPEG/WebP ou shader .gdshader dentro do projeto.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_ASSET_BYTES:
		return fail("asset_unavailable", "Recurso ausente ou maior que 16 MiB.")
	file.close()
	var result := {"path": path, "sha256": FileAccess.get_sha256(path), "origin": "on_disk", "import_status": "not_applicable", "compile_status": "not_verified", "diagnostics": []}
	if path.get_extension() == "gdshader":
		var source := FileAccess.get_file_as_string(path)
		if source.to_utf8_buffer().size() > 131072:
			return fail("shader_too_large", "Shader excede 128 KiB.")
		result["shader_type"] = "canvas_item" if source.contains("shader_type canvas_item;") else "other_or_unknown"
		result["source_validation"] = validate_shader(source, path)
	else:
		var sidecar := path + ".import"
		var config := ConfigFile.new()
		if safe_path(sidecar) and FileAccess.file_exists(sidecar) and config.load(sidecar) == OK:
			result["import_status"] = "metadata_present_not_runtime_validation"
			result["import_sha256"] = FileAccess.get_sha256(sidecar)
			var parameters := {}
			for key in ["compress/mode", "compress/high_quality", "mipmaps/generate", "process/fix_alpha_border", "process/premult_alpha", "detect_3d/compress_to", "roughness/mode"]:
				if config.has_section_key("params", key):
					parameters[key] = config.get_value("params", key)
			result["import_parameters"] = parameters
			if parameters.get("mipmaps/generate") == false:
				result["diagnostics"].append({"kind": "hypothesis", "code": "no_mipmaps", "message": "Avalie mipmaps se esta textura sofre redução; pixel art pode exigir outra escolha."})
		else:
			result["import_status"] = "missing_or_invalid_metadata"
	return {"ok": true, "result": result}


func target(root: Node, path: String) -> CanvasItem:
	if root == null or path.is_empty() or path.begins_with("/") or path.contains(":") or path.contains("\\") or ".." in path.split("/"):
		return null
	var node := root.get_node_or_null(NodePath(path))
	if node is CanvasItem and (node == root or node.owner == root):
		return node
	return null


func encode(value: Variant) -> Variant:
	if value is Color:
		return "#" + value.to_html(true)
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector4:
		return [value.x, value.y, value.z, value.w]
	if value is Resource:
		return Probe.resource_info(value)
	if typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
		return value
	return {"status": "unsupported_type", "type": typeof(value)}


func inspect(root: Node, path: String) -> Dictionary:
	var node := target(root, path)
	if node == null or root.scene_file_path.is_empty():
		return fail("invalid_graphics_target", "Escolha um CanvasItem próprio da cena salva e aberta.")
	var properties := {}
	for property_name in PROPERTIES:
		properties[property_name] = encode(node.get(property_name))
	var result := {"schema_version": 1, "origin": "editor_edited", "scene_path": root.scene_file_path, "node_path": path, "node_instance_id": str(node.get_instance_id()), "properties": properties, "material": Probe.resource_info(node.material), "use_parent_material": node.use_parent_material, "revision_scope": "target_public_properties_loaded_resources_and_shader_values", "shader_parameters": {}, "shader_compile_status": "not_verified"}
	if node is Sprite2D or node is TextureRect:
		result["texture"] = Probe.resource_info(node.texture)
	if node.material is ShaderMaterial and node.material.shader != null:
		result["source_validation"] = validate_shader(node.material.shader.code, node.material.shader.resource_path)
		if result["source_validation"].get("status") != "valid":
			result["revision"] = JSON.stringify(result).sha256_text()
			return {"ok": true, "result": result}
		var uniforms: Array = node.material.shader.get_shader_uniform_list()
		if uniforms.size() > 64:
			return fail("too_many_uniforms", "O shader excede o limite de 64 parâmetros.")
		for uniform in uniforms:
			result["shader_parameters"][uniform["name"]] = {"type": uniform["type"], "value": encode(node.material.get_shader_parameter(uniform["name"]))}
	result["revision"] = JSON.stringify(result).sha256_text()
	return {"ok": true, "result": result}


func decode_uniform(value: Variant, type: int) -> Dictionary:
	if type == TYPE_BOOL and typeof(value) == TYPE_BOOL:
		return {"ok": true, "value": value}
	if type in [TYPE_FLOAT, TYPE_INT] and typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and absf(float(value)) <= 1000000:
		if type == TYPE_INT and float(value) != floorf(float(value)):
			return fail("invalid_uniform", "Inteiro esperado.")
		return {"ok": true, "value": int(value) if type == TYPE_INT else float(value)}
	if type == TYPE_COLOR and typeof(value) == TYPE_STRING and Color.html_is_valid(value):
		return {"ok": true, "value": Color.html(value)}
	if type in [TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4] and typeof(value) == TYPE_ARRAY:
		var count: int = {TYPE_VECTOR2: 2, TYPE_VECTOR3: 3, TYPE_VECTOR4: 4}[type]
		if value.size() == count:
			for component in value:
				if typeof(component) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(component)) or absf(float(component)) > 1000000:
					return fail("invalid_uniform", "Componentes devem ser números finitos limitados.")
			if count == 2:
				return {"ok": true, "value": Vector2(value[0], value[1])}
			if count == 3:
				return {"ok": true, "value": Vector3(value[0], value[1], value[2])}
			return {"ok": true, "value": Vector4(value[0], value[1], value[2], value[3])}
	return fail("invalid_uniform", "Tipo ou valor de parâmetro fora do contrato.")


func edit(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or args.get("expected_scene_path") != root.scene_file_path:
		return fail("scene_conflict", "A cena ativa não corresponde à esperada.")
	if typeof(args.get("node_path")) != TYPE_STRING:
		return fail("invalid_graphics_target", "Informe node_path.")
	var current := inspect(root, args["node_path"])
	if not current.ok:
		return current
	if args.get("expected_revision") != current.result.revision:
		return fail("revision_conflict", "O alvo gráfico mudou desde a inspeção.")
	var changes = args.get("changes")
	if typeof(changes) != TYPE_DICTIONARY or changes.is_empty() or changes.size() > 8 or typeof(args.get("dry_run", false)) != TYPE_BOOL or typeof(args.get("expected_assets", {})) != TYPE_DICTIONARY:
		return fail("invalid_changes", "Informe de uma a oito alterações e prévia booleana.")
	var node := target(root, args["node_path"])
	var planned := {}
	var pending_assets := {}
	var dry_run: bool = args.get("dry_run", false)
	var material: ShaderMaterial
	for key in changes:
		if key in ["shader_path", "shader_parameters"]:
			if node.use_parent_material or (node.material != null and not node.material is ShaderMaterial):
				return fail("unsupported_material_scope", "Use ShaderMaterial local ao nó, sem material herdado.")
			if material == null:
				material = node.material.duplicate() as ShaderMaterial if node.material != null else ShaderMaterial.new()
		elif key not in PROPERTIES and key != "texture_path":
			return fail("invalid_property", "Propriedade gráfica não permitida.")
		if key in ["texture_path", "shader_path"]:
			if typeof(changes[key]) != TYPE_STRING:
				return fail("invalid_asset_path", "Caminho de recurso deve ser texto.")
			var info := asset(changes[key])
			if not info.ok:
				return info
			if args.get("expected_assets", {}).get(changes[key]) != info.result.sha256:
				return fail("asset_conflict", "O hash do recurso não corresponde ao esperado.")
			if key == "shader_path" and info.result.get("source_validation", {}).get("status") != "valid":
				return fail("invalid_shader", "A validação do shader recusou a associação.", info.result.get("source_validation", {}))
			if key == "texture_path" and not (node is Sprite2D or node is TextureRect):
				return fail("invalid_texture_target", "Textura requer Sprite2D/TextureRect.")
			if key == "texture_path" and not ResourceLoader.exists(changes[key], "Texture2D"):
				return fail("asset_not_imported", "Textura ainda não foi importada.")
			if dry_run:
				pending_assets[key] = {"path": changes[key], "sha256": info.result.sha256, "resource_load_pending": true}
				continue
			var resource := ResourceLoader.load(changes[key], "", ResourceLoader.CACHE_MODE_IGNORE)
			if resource == null or resource.get_script() != null:
				return fail("asset_load_failed", "Importe um recurso nativo antes de associá-lo.")
			if FileAccess.get_sha256(changes[key]) != info.result.sha256:
				return fail("asset_conflict", "Recurso mudou durante o carregamento.")
			if key == "texture_path":
				if not (node is Sprite2D or node is TextureRect) or not resource is Texture2D:
					return fail("invalid_texture_target", "Textura requer Sprite2D/TextureRect e recurso Texture2D.")
				planned["texture"] = resource
			else:
				if not resource is Shader or resource.get_mode() != Shader.MODE_CANVAS_ITEM:
					return fail("invalid_shader", "Shader deve ser do tipo canvas_item.")
				if resource.code.sha256_text() != info.result.source_validation.source_sha256:
					return fail("loaded_resource_conflict", "Shader carregado difere do arquivo validado; recarregue pelo editor.")
				material.shader = resource
		elif key in PROPERTIES:
			var value: Variant = changes[key]
			if key == "modulate":
				if typeof(value) != TYPE_STRING or not Color.html_is_valid(value):
					return fail("invalid_value", "Cor deve ser hexadecimal.")
				value = Color.html(value)
			elif key == "visible":
				if typeof(value) != TYPE_BOOL:
					return fail("invalid_value", "Visibilidade deve ser booleana.")
			else:
				var limits: Array = {"z_index": [-4096, 4096], "texture_filter": [0, 6], "texture_repeat": [0, 3]}[key]
				if typeof(value) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(value)) or float(value) != floorf(float(value)) or value < limits[0] or value > limits[1]:
					return fail("invalid_value", "Inteiro gráfico fora do intervalo permitido.")
				value = int(value)
			planned[key] = value
	if changes.has("shader_parameters"):
		if dry_run and pending_assets.has("shader_path"):
			if typeof(changes["shader_parameters"]) != TYPE_DICTIONARY or changes["shader_parameters"].size() > 16:
				return fail("invalid_uniform", "Informe até 16 parâmetros.")
			pending_assets["shader_parameters"] = {"uniform_validation_pending": true}
		else:
			if material.shader == null or typeof(changes["shader_parameters"]) != TYPE_DICTIONARY or changes["shader_parameters"].size() > 16:
				return fail("invalid_uniform", "Informe até 16 parâmetros de um shader existente.")
			var validated := validate_shader(material.shader.code, material.shader.resource_path)
			if validated.get("status") != "valid":
				return fail("invalid_shader", "Shader atual não passou pela validação de código.", validated)
			var types := {}
			for uniform in material.shader.get_shader_uniform_list():
				types[uniform["name"]] = uniform["type"]
			for key in changes["shader_parameters"]:
				if not types.has(key):
					return fail("unknown_uniform", "O shader não declara esse parâmetro.")
				var decoded := decode_uniform(changes["shader_parameters"][key], types[key])
				if not decoded.ok:
					return decoded
				material.set_shader_parameter(key, decoded.value)
	if material != null and not (dry_run and pending_assets.has("shader_path")):
		material.resource_local_to_scene = true
		planned["material"] = material
	var diff := []
	for key in planned:
		diff.append({"property": key, "before": encode(node.get(key)), "after": encode(planned[key])})
	for key in pending_assets:
		if key != "shader_parameters":
			diff.append({"property": "texture" if key == "texture_path" else "material", "before": encode(node.get("texture") if key == "texture_path" else node.material), "after": pending_assets[key]})
	var result := {"applied": false, "dry_run": dry_run, "scene_path": root.scene_file_path, "node_path": args["node_path"], "revision_before": current.result.revision, "diff": diff, "requested_changes": changes, "pending_assets": pending_assets, "undo_available": false, "shared_resource_mutated": false, "disk_saved": false, "shader_compile_status": "not_verified", "runtime_validation": "required"}
	if dry_run:
		return {"ok": true, "result": result}
	var history := plugin.get_undo_redo()
	history.create_action("MCP: editar gráficos de %s" % args["node_path"], UndoRedo.MERGE_DISABLE, root)
	for key in planned:
		history.add_do_property(node, key, planned[key])
		history.add_undo_property(node, key, node.get(key))
	history.commit_action()
	result["applied"] = true
	result["undo_available"] = true
	result["revision_after"] = inspect(root, args["node_path"]).result.revision
	return {"ok": true, "result": result}
