@tool
extends RefCounted

# Somente ConfigFile e EditorFileSystem; nenhuma prévia carrega ResourceLoader.
const MAX_SIDECAR_BYTES := 65536
const ALLOWED := ["compress/mode", "mipmaps/generate", "process/fix_alpha_border", "process/size_limit"]

func _problem(code: String, message: String) -> Dictionary:
	return {"status": "unavailable", "error": {"code": code, "message": message}}

func _path(raw: Variant) -> bool:
	if typeof(raw) != TYPE_STRING or raw.length() > 512 or not raw.begins_with("res://") or not raw.to_lower().ends_with(".png") or raw.contains("\\"):
		return false
	for part in raw.trim_prefix("res://").split("/"):
		if part in ["", ".", ".."] or part.begins_with(".") or part.contains(":"):
			return false
	return true

func _current_hash(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return FileAccess.get_sha256(path)

func _validate_request(args: Dictionary) -> Dictionary:
	var path = args.get("path")
	var source_hash = args.get("source_sha256")
	var import_hash = args.get("import_sha256")
	if not _path(path) or typeof(source_hash) != TYPE_STRING or source_hash.length() != 64 or (import_hash != null and (typeof(import_hash) != TYPE_STRING or import_hash.length() != 64)):
		return _problem("invalid_target", "Caminho ou SHA inválido.")
	if not FileAccess.file_exists(path) or _current_hash(path) != source_hash or _current_hash(path + ".import") != import_hash:
		return _problem("hash_conflict", "PNG ou sidecar divergiu.")
	return {"status": "ok", "path": path, "sidecar": path + ".import"}

func prepare(args: Dictionary) -> Dictionary:
	var check := _validate_request(args)
	if check.status != "ok":
		return check
	var options = args.get("options")
	if typeof(options) != TYPE_DICTIONARY or options.is_empty():
		return _problem("invalid_options", "Opções vazias ou inválidas.")
	var config := ConfigFile.new()
	var previous_importer := ""
	var previous_uid := ""
	var previous_dependencies: Array[String] = []
	if FileAccess.file_exists(check.sidecar):
		var file := FileAccess.open(check.sidecar, FileAccess.READ)
		if file == null or file.get_length() > MAX_SIDECAR_BYTES:
			return _problem("invalid_sidecar", "Sidecar acima do limite.")
		file.close()
		if config.load(check.sidecar) != OK:
			return _problem("invalid_sidecar", "ConfigFile do sidecar inválido.")
		if str(config.get_value("remap", "importer", "texture")) != "texture":
			return _problem("unsupported_importer", "Apenas importer texture é permitido.")
		previous_importer = str(config.get_value("remap", "importer", ""))
		previous_uid = str(config.get_value("remap", "uid", ""))
		var old_dest_files = config.get_value("deps", "dest_files", PackedStringArray())
		if typeof(old_dest_files) in [TYPE_PACKED_STRING_ARRAY, TYPE_ARRAY]:
			for item in old_dest_files:
				if typeof(item) == TYPE_STRING and item.begins_with("res://.godot/imported/"):
					previous_dependencies.append(item)
	else:
		config.set_value("remap", "importer", "texture")
	for key in options:
		if key not in ALLOWED:
			return _problem("invalid_options", "Opção fora da lista.")
		var value = options[key]
		if key == "compress/mode" and (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT or int(value) not in [0, 1]):
			return _problem("invalid_options", "Compressão inválida.")
		if key in ["mipmaps/generate", "process/fix_alpha_border"] and typeof(value) != TYPE_BOOL:
			return _problem("invalid_options", "Opção booleana inválida.")
		if key == "process/size_limit" and (typeof(value) not in [TYPE_INT, TYPE_FLOAT] or int(value) not in [0, 256, 512, 1024, 2048]):
			return _problem("invalid_options", "Limite de tamanho inválido.")
		config.set_value("params", key, value)
	var candidate := config.encode_to_text()
	if candidate.to_utf8_buffer().size() > MAX_SIDECAR_BYTES:
		return _problem("sidecar_too_large", "ConfigFile excede 64 KiB.")
	if _current_hash(check.path) != args.source_sha256 or _current_hash(check.sidecar) != args.import_sha256:
		return _problem("hash_conflict", "Arquivo mudou durante a prévia.")
	return {"status": "ok", "candidate_text": candidate, "candidate_sha256": candidate.sha256_text(), "previous_importer": previous_importer, "previous_uid": previous_uid, "previous_dependencies": previous_dependencies, "load_performed": false}

func reimport(args: Dictionary) -> Dictionary:
	var path = args.get("path")
	var expected_source = args.get("source_sha256")
	var expected_import = args.get("expected_import_sha256")
	if not _path(path) or typeof(expected_source) != TYPE_STRING or typeof(expected_import) not in [TYPE_STRING, TYPE_NIL]:
		return _problem("invalid_target", "Alvo da reimportação inválido.")
	if _current_hash(path) != expected_source or _current_hash(path + ".import") != expected_import:
		return _problem("hash_conflict", "PNG ou sidecar mudou antes da reimportação.")
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null or filesystem.is_scanning() or filesystem.is_importing():
		return _problem("editor_busy", "EditorFileSystem indisponível ou ocupado.")
	var start := Time.get_ticks_msec()
	filesystem.reimport_files(PackedStringArray([path]))
	var elapsed := Time.get_ticks_msec() - start
	if _current_hash(path) != expected_source:
		return _problem("source_conflict", "PNG mudou durante a reimportação.")
	var sidecar: String = path + ".import"
	var config := ConfigFile.new()
	if config.load(sidecar) != OK:
		return _problem("import_sidecar_invalid", "Reimportação não produziu sidecar legível.")
	var importer := str(config.get_value("remap", "importer", ""))
	var valid := config.get_value("remap", "valid", true)
	var uid := str(config.get_value("remap", "uid", ""))
	var source_file := str(config.get_value("deps", "source_file", ""))
	var dest_files = config.get_value("deps", "dest_files", PackedStringArray())
	if importer != "texture" or valid == false or source_file != path:
		return _problem("import_failed", "Importer, dependência ou valid=false inesperado.")
	var expected_options = args.get("expected_options")
	if expected_options != null:
		if typeof(expected_options) != TYPE_DICTIONARY:
			return _problem("invalid_options", "Opções esperadas inválidas.")
		for key in expected_options:
			if key not in ALLOWED or not config.has_section_key("params", key) or config.get_value("params", key) != expected_options[key]:
				return _problem("import_options_conflict", "Parâmetros de importação divergiram após reimportação.")
	var deps: Array[String] = []
	if typeof(dest_files) in [TYPE_PACKED_STRING_ARRAY, TYPE_ARRAY]:
		for item in dest_files:
			if typeof(item) == TYPE_STRING and item.begins_with("res://.godot/imported/"):
				deps.append(item)
	return {"status": "ok", "path": path, "source_sha256": expected_source, "import_sha256": _current_hash(sidecar), "importer": importer, "uid": uid, "source_file": source_file, "dependencies": deps, "valid": valid, "elapsed_ms": elapsed, "cache_restoration": "reimport_compensation_only"}
