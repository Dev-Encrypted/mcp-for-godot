@tool
extends EditorDebuggerPlugin

# Amostras do jogo chegam pelo depurador oficial; a ponte MCP le apenas o buffer.
const SCHEMA_VERSION := 1
const MAX_SAMPLE_BYTES := 131072
const MAX_NODES := 300
const MAX_VIEWPORTS := 8
const MAX_HISTORY := 120
const MAX_TIMELINE := 120
const MAX_EVENT_CHANGES := 8
const STALE_AFTER_USEC := 2_500_000
const IMAGE_TIMEOUT_USEC := 10_000_000
const IMAGE_MIN_INTERVAL_USEC := 1_000_000
const MAX_IMAGE_BYTES := 262144
const MAX_IMAGE_EDGE := 2048
const TEXT_NODE_PATHS := ["ScoreLabel", "HUD/ScoreLabel"]
const SUBSYSTEM_FIELDS := {
	"physics_2d": {"active_objects": ["Performance.PHYSICS_2D_ACTIVE_OBJECTS", "process", "count", "monitor"], "collision_pairs": ["Performance.PHYSICS_2D_COLLISION_PAIRS", "process", "count", "monitor"], "islands": ["Performance.PHYSICS_2D_ISLAND_COUNT", "process", "count", "monitor"]},
	"physics_3d": {"active_objects": ["Performance.PHYSICS_3D_ACTIVE_OBJECTS", "process", "count", "monitor"], "collision_pairs": ["Performance.PHYSICS_3D_COLLISION_PAIRS", "process", "count", "monitor"], "islands": ["Performance.PHYSICS_3D_ISLAND_COUNT", "process", "count", "monitor"]},
	"audio": {"bus_count": ["AudioServer.bus_count", "process", "count", "number"], "time_since_last_mix": ["AudioServer.get_time_since_last_mix", "process", "s", "number"], "time_to_next_mix": ["AudioServer.get_time_to_next_mix", "process", "s", "number"], "output_latency": ["Performance.AUDIO_OUTPUT_LATENCY", "process", "s", "monitor"]},
	"multiplayer": {"peer_present": ["MultiplayerAPI.has_multiplayer_peer", "scene_multiplayer_api", "boolean", "bool"], "connection_status": ["MultiplayerPeer.get_connection_status", "scene_multiplayer_api", "enum", "enum"], "transport_kind": ["MultiplayerAPI.multiplayer_peer.get_class", "scene_multiplayer_api", "class", "transport"], "remote_connection": ["public_peer_status_without_remote_handshake", "scene_multiplayer_api", "boolean", "remote"]},
	"navigation_2d": {"active_maps": ["Performance.NAVIGATION_2D_ACTIVE_MAPS", "process", "count", "monitor"], "regions": ["Performance.NAVIGATION_2D_REGION_COUNT", "process", "count", "monitor"], "agents": ["Performance.NAVIGATION_2D_AGENT_COUNT", "process", "count", "monitor"]},
	"navigation_3d": {"active_maps": ["Performance.NAVIGATION_3D_ACTIVE_MAPS", "process", "count", "monitor"], "regions": ["Performance.NAVIGATION_3D_REGION_COUNT", "process", "count", "monitor"], "agents": ["Performance.NAVIGATION_3D_AGENT_COUNT", "process", "count", "monitor"]},
	"platform": {"os_name": ["OS.get_name", "process", "name", "text"], "display_backend": ["DisplayServer.get_name", "process", "name", "text"]}
}
const SUBSYSTEM_SAMPLING_SCOPE := "latest_public_process_values_not_causal_scene_attribution"
const SampleSize = preload("res://addons/mcp_for_godot/sample_size.gd")
const GraphicsProbe = preload("res://addons/mcp_for_godot/graphics_probe.gd")
const FrameTimeline = preload("res://addons/mcp_for_godot/frame_timeline.gd")
const NativeDiagnosticBuffer = preload("res://addons/mcp_for_godot/native_diagnostic_buffer.gd")

var _native_diagnostics = NativeDiagnosticBuffer.new()
var _native_supported: Dictionary = {}

var _latest: Dictionary = {}
var _history: Dictionary = {}
var _timeline: Dictionary = {}
var _timeline_revision: Dictionary = {}
var _timeline_dropped: Dictionary = {}
var _capture_costs: Dictionary = {}
var _tabs: Dictionary = {}
var _capture_errors: Dictionary = {}
var _missing_sequences: Dictionary = {}
var _last_sequence_gap: Dictionary = {}
var _backpressure: Dictionary = {}
var _stale_announced: Dictionary = {}
var _images: Dictionary = {}
var _image_last_request_ticks: Dictionary = {}
var _preview_images: Dictionary = {}
var _ui_captures: Dictionary = {}
var _input_requests: Dictionary = {}


func _has_capture(capture: String) -> bool:
	return capture == "mcp_for_godot"


func _capture(message: String, data: Array, session_id: int) -> bool:
	if message == "mcp_for_godot:status":
		_capture_status(data, session_id)
		return true
	if message == "mcp_for_godot:image":
		_capture_image_result(data, session_id)
		return true
	if message == "mcp_for_godot:input_result":
		_capture_input_result(data, session_id)
		return true
	if message != "mcp_for_godot:snapshot":
		return false
	if data.size() != 1 or typeof(data[0]) != TYPE_DICTIONARY:
		_reject(session_id, "invalid_message", "A mensagem não contém uma única amostra.")
		return true
	var sample: Dictionary = data[0]
	var capture_started := Time.get_ticks_usec()
	var size_result: Dictionary = SampleSize.checked_size(sample, MAX_SAMPLE_BYTES)
	var size_checked := Time.get_ticks_usec()
	var validation_error: Dictionary = _validate_sample(sample, int(size_result["bytes"]))
	if not validation_error.is_empty():
		_reject(session_id, validation_error["code"], "A amostra foi rejeitada pelo contrato de observação.", validation_error.get("field", ""))
		return true
	var validated := Time.get_ticks_usec()
	var previous: Dictionary = _latest.get(session_id, {})
	var gap := 0
	if not previous.is_empty():
		var old: Dictionary = previous["sample"]
		if old.get("run_id") == sample["run_id"] and int(sample["sample_seq"]) <= int(old["sample_seq"]):
			_reject(session_id, "out_of_order", "A sequência da amostra não avançou.")
			return true
		if old.get("run_id") == sample["run_id"]:
			gap = maxi(0, int(sample["sample_seq"]) - int(old["sample_seq"]) - 1)
		else:
			_missing_sequences[session_id] = 0
	else:
		gap = maxi(0, int(sample["sample_seq"]) - 1)
	_missing_sequences[session_id] = int(_missing_sequences.get(session_id, 0)) + gap
	_last_sequence_gap[session_id] = gap
	_capture_errors.erase(session_id)
	_backpressure.erase(session_id)
	_stale_announced.erase(session_id)
	var received := {
		# A mensagem recebida pertence a este callback; as leituras publicas copiam em profundidade.
		"sample": sample.duplicate(),
		"received_ticks_usec": Time.get_ticks_usec(),
		"received_utc": Time.get_datetime_string_from_system(true, true)
	}
	_latest[session_id] = received
	var history: Array = _history.get(session_id, [])
	history.append(received)
	if history.size() > MAX_HISTORY:
		history.pop_front()
	_history[session_id] = history
	if gap > 0:
		_append_event(session_id, {"kind": "sequence_gap", "run_id": sample["run_id"], "sample_seq": sample["sample_seq"], "missing_count": gap, "cause": "unknown"})
	var changes := _observed_changes(previous.get("sample", {}), sample)
	_append_event(session_id, {"kind": "sample", "run_id": sample["run_id"], "sample_seq": sample["sample_seq"], "render_frame": sample.get("render_frame"), "sample_ticks_usec": sample.get("sample_ticks_usec"), "sample_utc": sample.get("sample_utc"), "structure_generation": sample.get("structure_generation"), "changes": changes["items"], "changes_truncated": changes["truncated"], "node_set_complete": changes["node_set_complete"]})
	var stored := Time.get_ticks_usec()
	_send_ack(session_id, str(sample["run_id"]), int(sample["sample_seq"]))
	var acknowledged := Time.get_ticks_usec()
	_render_session(session_id)
	var rendered := Time.get_ticks_usec()
	_capture_costs[session_id] = {"sample_seq": sample["sample_seq"], "scope": "editor_main_thread_capture_callback", "size_check_method": size_result["method"], "size_checked_bytes": size_result["bytes"], "size_check_usec": size_checked - capture_started, "field_validation_usec": validated - size_checked, "validation_usec": validated - capture_started, "store_and_events_usec": stored - validated, "ack_call_usec": acknowledged - stored, "tab_model_update_usec": rendered - acknowledged, "total_usec": rendered - capture_started}
	return true


func _capture_input_result(data: Array, session_id: int) -> void:
	if data.size() != 1 or typeof(data[0]) != TYPE_DICTIONARY or not _input_requests.has(session_id):
		return
	var result: Dictionary = data[0]
	var pending: Dictionary = _input_requests[session_id]
	if result.get("command_id") != pending["command_id"] or result.get("run_id") != pending["run_id"] or result.get("action") != pending["action"] or result.get("scene_path") != pending["scene_path"]:
		return
	if result.get("status") not in ["pressed", "released", "rejected"] or typeof(result.get("code")) != TYPE_STRING or str(result["code"]).length() > 64:
		return
	pending["status"] = result["status"]
	pending["code"] = result["code"]
	pending["runtime_ticks_usec"] = result.get("ticks_usec")
	if result["status"] in ["released", "rejected"]:
		_append_event(session_id, {"kind": "input_" + str(result["status"]), "run_id": pending["run_id"], "action": pending["action"], "command_id": pending["command_id"], "code": pending["code"]})


func request_input(requested_session: int, expected_run_id: String, action: String, duration_ms: int) -> Dictionary:
	var snapshot := get_snapshot(requested_session, false)
	if snapshot.get("status") != "ok":
		return _problem("sample_unavailable", "A entrada exige amostra viva da sessão escolhida.")
	var session_id: int = snapshot["session_id"]
	var sample: Dictionary = snapshot["sample"]
	if sample.get("run_id") != expected_run_id:
		return _problem("session_changed", "A execução mudou desde a leitura.")
	if _input_requests.has(session_id):
		var previous: Dictionary = _input_requests[session_id]
		if previous.get("status") in ["pending", "pressed"]:
			return _problem("input_busy", "Outra ação ainda está em curso.")
		_input_requests.erase(session_id)
	var session := get_session(session_id)
	if session == null or not session.is_active():
		return _problem("inactive_session", "O jogo não está conectado ao depurador.")
	var command_id := Crypto.new().generate_random_bytes(16).hex_encode()
	_input_requests[session_id] = {"status": "pending", "command_id": command_id, "run_id": expected_run_id, "scene_path": sample["scene_path"], "action": action, "requested_ticks_usec": Time.get_ticks_usec()}
	session.send_message("mcp_for_godot_input:press", [expected_run_id, command_id, sample["scene_path"], action, duration_ms])
	return {"status": "pending", "session_id": session_id, "run_id": expected_run_id, "command_id": command_id, "action": action, "duration_ms": duration_ms}


func get_input_result(session_id: int, command_id: String) -> Dictionary:
	if not _input_requests.has(session_id):
		return _problem("input_not_found", "A ação não existe nesta sessão do editor.")
	var result: Dictionary = _input_requests[session_id]
	if result["command_id"] != command_id:
		return _problem("input_not_found", "Identidade da ação não confere.")
	if Time.get_ticks_usec() - int(result["requested_ticks_usec"]) > 5_000_000:
		_input_requests.erase(session_id)
		return _problem("input_timeout", "O jogo não confirmou a liberação da ação em cinco segundos.")
	if result["status"] in ["released", "rejected", "unavailable"]:
		_input_requests.erase(session_id)
	return result.duplicate(true)


func _capture_image_result(data: Array, session_id: int) -> void:
	var received_started := Time.get_ticks_usec()
	if not _images.has(session_id):
		return
	var entry: Dictionary = _images[session_id]
	if entry["status"] != "pending":
		return
	if data.size() != 1 or typeof(data[0]) != TYPE_DICTIONARY:
		entry["status"] = "unavailable"
		entry["error"] = {"code": "invalid_image", "message": "Resposta de imagem inválida."}
		return
	var result: Dictionary = data[0]
	if result.get("schema_version") != SCHEMA_VERSION or result.get("project_fingerprint") != ProjectSettings.globalize_path("res://").sha256_text() or result.get("capture_id") != entry["capture_id"] or result.get("run_id") != entry["run_id"]:
		entry["status"] = "unavailable"
		entry["error"] = {"code": "invalid_image", "message": "Identidade da imagem não confere."}
		return
	if result.get("status") == "error":
		var code = result.get("code")
		if typeof(code) != TYPE_STRING or not ["capture_busy", "rate_limited", "scene_unavailable", "scene_changed", "image_dimensions_exceeded", "readback_failed", "encoder_unavailable", "png_encode_failed", "image_bytes_exceeded", "viewport_unavailable", "viewport_freshness_unverified", "frame_not_rendered"].has(code):
			code = "invalid_image"
		entry["status"] = "unavailable"
		entry["error"] = {"code": code, "message": "O jogo não conseguiu capturar o viewport."}
		return
	if result.get("status") != "ok" or typeof(result.get("png")) != TYPE_PACKED_BYTE_ARRAY or typeof(result.get("width")) != TYPE_INT or typeof(result.get("height")) != TYPE_INT or typeof(result.get("render_frame")) != TYPE_INT or typeof(result.get("readback_usec")) != TYPE_INT or typeof(result.get("encode_usec")) != TYPE_INT or typeof(result.get("scene_path")) != TYPE_STRING:
		entry["status"] = "unavailable"
		entry["error"] = {"code": "invalid_image", "message": "Metadados da imagem inválidos."}
		return
	var bytes: PackedByteArray = result["png"]
	if bytes.size() < 24 or bytes.size() > MAX_IMAGE_BYTES or bytes[0] != 137 or bytes[1] != 80 or bytes[2] != 78 or bytes[3] != 71 or bytes[4] != 13 or bytes[5] != 10 or bytes[6] != 26 or bytes[7] != 10 or int(result["width"]) < 1 or int(result["height"]) < 1 or int(result["width"]) > MAX_IMAGE_EDGE or int(result["height"]) > MAX_IMAGE_EDGE or int(result["render_frame"]) < 1 or int(result["readback_usec"]) < 0 or int(result["encode_usec"]) < 0 or result["scene_path"] != entry["scene_path"]:
		entry["status"] = "unavailable"
		entry["error"] = {"code": "invalid_image", "message": "PNG ou escopo da imagem inválido."}
		return
	var context = result.get("frame_context", {})
	if not _valid_frame_context(context, entry, result):
		entry["status"] = "unavailable"
		entry["error"] = {"code": "invalid_frame_context", "message": "Contexto gráfico fora do contrato."}
		return
	entry["frame_context"] = context
	entry["status"] = "ready"
	entry["png"] = bytes
	entry["render_frame"] = result["render_frame"]
	entry["width"] = result["width"]
	entry["height"] = result["height"]
	entry["readback_usec"] = result["readback_usec"]
	entry["encode_usec"] = result["encode_usec"]
	entry["editor_receive_validation_usec"] = Time.get_ticks_usec() - received_started
	entry["completed_ticks_usec"] = Time.get_ticks_usec()
	entry["received_utc"] = Time.get_datetime_string_from_system(true, true)
	_cache_image_preview(session_id, entry, bytes)
	_append_event(session_id, {"kind": "image", "run_id": entry["run_id"], "render_frame": entry["render_frame"], "viewport_path": entry.get("viewport_path", ""), "capture_id": entry["capture_id"], "pixel_metric_same_frame": "unproven"})


func _cache_image_preview(session_id: int, entry: Dictionary, bytes: PackedByteArray) -> void:
	if not _tabs.has(session_id):
		return
	_preview_images[session_id] = {"status": "cached", "png": bytes, "capture_id": entry["capture_id"], "run_id": entry["run_id"], "scene_path": entry["scene_path"], "sample_seq_at_request": entry["sample_seq_at_request"], "backend": entry["backend"], "render_frame": entry["render_frame"], "received_utc": entry["received_utc"], "width": entry["width"], "height": entry["height"], "png_bytes": bytes.size()}
	_preview_images[session_id]["frame_context"] = entry.get("frame_context", {})
	var view: Dictionary = _tabs[session_id]
	(view["preview_texture"] as TextureRect).texture = null
	(view["preview_label"] as Label).text = _preview_description(_preview_images[session_id]) + "\nAbra Imagem para decodificar e exibir."
	_fill_visual_tree(session_id, entry.get("frame_context", {}).get("items", []))
	call_deferred("_show_image_preview", 2, session_id)


func _preview_description(entry: Dictionary) -> String:
	var backend: Dictionary = entry["backend"]
	return "Jogo em execução · %s · frame %s · amostra no pedido %s · %s × %s px · %s bytes\n%s · %s / %s · GPU: %s · recebido UTC %s" % [entry["scene_path"], entry["render_frame"], entry["sample_seq_at_request"], entry["width"], entry["height"], entry["png_bytes"], entry["run_id"], backend.get("method", "?"), backend.get("driver", "?"), backend.get("gpu", "?"), entry["received_utc"]]


func _show_image_preview(tab_index: int, session_id: int) -> void:
	if tab_index != 2 or not _tabs.has(session_id) or not _preview_images.has(session_id):
		return
	var view: Dictionary = _tabs[session_id]
	if (view["views"] as TabContainer).current_tab != 2:
		return
	var entry: Dictionary = _preview_images[session_id]
	if entry["status"] != "cached":
		return
	var started := Time.get_ticks_usec()
	var image := Image.new()
	var decoded: Error = image.load_png_from_buffer(entry["png"])
	if decoded != OK or image.get_width() != entry["width"] or image.get_height() != entry["height"]:
		entry["status"] = "decode_failed"
		entry.erase("png")
		(view["preview_label"] as Label).text = _preview_description(entry) + "\nFalha ao decodificar a prévia no editor."
		return
	var texture := ImageTexture.create_from_image(image)
	if texture == null:
		entry["status"] = "decode_failed"
		entry.erase("png")
		(view["preview_label"] as Label).text = _preview_description(entry) + "\nFalha ao criar a textura da prévia."
		return
	(view["preview_texture"] as TextureRect).texture = texture
	entry.erase("png")
	entry["status"] = "visible"
	entry["editor_preview_decode_usec"] = Time.get_ticks_usec() - started
	(view["preview_label"] as Label).text = _preview_description(entry) + "\nPrévia do PNG recebido; contadores podem vir de outro frame. Decodificação no editor: %s µs." % entry["editor_preview_decode_usec"]


func get_preview_status() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for session_id in _preview_images:
		var entry: Dictionary = _preview_images[session_id]
		result.append({"session_id": session_id, "status": entry["status"], "capture_id": entry["capture_id"], "run_id": entry["run_id"], "scene_path": entry["scene_path"], "render_frame": entry["render_frame"], "width": entry["width"], "height": entry["height"], "png_bytes": entry["png_bytes"], "editor_preview_decode_usec": entry.get("editor_preview_decode_usec")})
	return result


func request_image(requested_session: int = -1, viewport_path: String = "") -> Dictionary:
	var request_started := Time.get_ticks_usec()
	var snapshot := get_snapshot(requested_session, false)
	if snapshot["status"] != "ok":
		return _problem("sample_unavailable", "É necessária uma amostra viva e recente para capturar imagem.", {"snapshot_status": snapshot["status"], "snapshot_error": snapshot.get("error")})
	var session_id: int = snapshot["session_id"]
	var now := Time.get_ticks_usec()
	if _images.has(session_id):
		var old: Dictionary = _images[session_id]
		if now - int(old.get("requested_ticks_usec", now)) > IMAGE_TIMEOUT_USEC:
			_images.erase(session_id)
	if _images.has(session_id) and (_images[session_id] as Dictionary).get("status") in ["pending", "ready"]:
		return _problem("capture_busy", "Já existe uma captura pendente nesta sessão.")
	if now - int(_image_last_request_ticks.get(session_id, 0)) < IMAGE_MIN_INTERVAL_USEC:
		return _problem("rate_limited", "Aguarde um segundo entre capturas.")
	var sample: Dictionary = snapshot["sample"]
	var selected_path := str(sample["viewport"]["path"]) if viewport_path.is_empty() else viewport_path
	var found := false
	for viewport in sample.get("viewports", [sample["viewport"]]):
		if viewport["path"] == selected_path:
			found = true
			if viewport.get("frame_alignment") != "latest_available":
				return _problem("viewport_freshness_unverified", "O viewport não tem atualização contínua comprovada.")
	if not found:
		return _problem("viewport_unavailable", "Escolha um viewport presente na amostra viva.")
	var capture_id := Crypto.new().generate_random_bytes(16).hex_encode()
	_images[session_id] = {"status": "pending", "capture_id": capture_id, "run_id": sample["run_id"], "scene_path": sample["scene_path"], "sample_seq_at_request": sample["sample_seq"], "backend": sample["backend"].duplicate(true), "requested_ticks_usec": now}
	_images[session_id]["viewport_path"] = selected_path
	_image_last_request_ticks[session_id] = now
	var session := get_session(session_id)
	if session == null or not session.is_active():
		_images.erase(session_id)
		return _problem("inactive_session", "A sessão foi encerrada antes da captura.")
	var send_started := Time.get_ticks_usec()
	session.send_message("mcp_for_godot_capture:request", [sample["run_id"], capture_id, selected_path])
	return {"status": "pending", "session_id": session_id, "capture_id": capture_id, "editor_request_dispatch_usec": Time.get_ticks_usec() - request_started, "editor_send_call_usec": Time.get_ticks_usec() - send_started}


func get_image_result(session_id: int, capture_id: String) -> Dictionary:
	if not _images.has(session_id):
		return _problem("capture_unknown", "Captura não encontrada ou sessão encerrada.")
	var entry: Dictionary = _images[session_id]
	if entry["capture_id"] != capture_id:
		return _problem("capture_unknown", "Identificador de captura não confere.")
	if entry["status"] == "unavailable" and (entry.get("error", {}) as Dictionary).get("code") == "session_changed":
		_images.erase(session_id)
		return {"status": "unavailable", "error": entry["error"]}
	var current := get_snapshot(session_id, false)
	if current["status"] == "unavailable" or current.get("sample", {}).get("run_id") != entry["run_id"] or current.get("sample", {}).get("scene_path") != entry["scene_path"] or current.get("sample", {}).get("backend") != entry["backend"]:
		_images.erase(session_id)
		return _problem("session_changed", "A sessão ou execução mudou durante a captura.")
	if entry["status"] == "pending" and Time.get_ticks_usec() - int(entry["requested_ticks_usec"]) > IMAGE_TIMEOUT_USEC:
		entry["status"] = "unavailable"
		entry["error"] = {"code": "capture_timeout", "message": "O jogo não respondeu à captura em dez segundos."}
	if entry["status"] == "pending":
		return {"status": "pending", "session_id": session_id, "capture_id": capture_id}
	_images.erase(session_id)
	if entry["status"] == "unavailable":
		return {"status": "unavailable", "error": entry["error"]}
	var bytes: PackedByteArray = entry["png"]
	var hash := HashingContext.new()
	var hash_started := Time.get_ticks_usec()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	var checksum := hash.finish().hex_encode()
	var hash_usec := Time.get_ticks_usec() - hash_started
	var base64_started := Time.get_ticks_usec()
	var encoded := Marshalls.raw_to_base64(bytes)
	return {"status": "ready", "schema_version": SCHEMA_VERSION, "origin": "runtime_viewport_readback", "session_id": session_id, "capture_id": capture_id, "run_id": entry["run_id"], "scene_path": entry["scene_path"], "sample_seq_at_request": entry["sample_seq_at_request"], "backend": entry["backend"], "render_frame": entry["render_frame"], "received_utc": entry["received_utc"], "width": entry["width"], "height": entry["height"], "readback_usec": entry["readback_usec"], "encode_usec": entry["encode_usec"], "png_bytes": bytes.size(), "sha256": checksum, "image_base64": encoded, "viewport_path": entry.get("viewport_path", ""), "frame_context": entry.get("frame_context", {}), "editor_receive_validation_usec": entry.get("editor_receive_validation_usec"), "editor_hash_usec": hash_usec, "editor_base64_usec": Time.get_ticks_usec() - base64_started}


func _capture_status(data: Array, session_id: int) -> void:
	if data.size() != 1 or typeof(data[0]) != TYPE_DICTIONARY or JSON.stringify(data[0]).to_utf8_buffer().size() > 1024:
		_reject(session_id, "invalid_status", "Mensagem de fluxo inválida.")
		return
	var status: Dictionary = data[0]
	if status.get("schema_version") != SCHEMA_VERSION or status.get("code") != "backpressure" or status.get("project_fingerprint") != ProjectSettings.globalize_path("res://").sha256_text():
		_reject(session_id, "invalid_status", "Mensagem de fluxo incompatível.")
		return
	if typeof(status.get("run_id")) != TYPE_STRING or str(status["run_id"]).length() > 80 or typeof(status.get("pending_seq")) != TYPE_INT or int(status["pending_seq"]) < 1 or typeof(status.get("skipped_intervals")) != TYPE_INT or int(status["skipped_intervals"]) < 1:
		_reject(session_id, "invalid_status", "Contadores de fluxo inválidos.")
		return
	var previous: Dictionary = _latest.get(session_id, {})
	if not previous.is_empty():
		var sample: Dictionary = previous["sample"]
		if sample["run_id"] != status["run_id"] or sample["sample_seq"] != status["pending_seq"]:
			return
	_backpressure[session_id] = status.duplicate(true)
	_append_event(session_id, {"kind": "backpressure", "run_id": status["run_id"], "sample_seq": status["pending_seq"], "skipped_intervals": status["skipped_intervals"]})
	_render_session(session_id)
	if not previous.is_empty():
		_send_ack(session_id, str(status["run_id"]), int(status["pending_seq"]))


func _send_ack(session_id: int, run_id: String, sequence: int) -> void:
	var session := get_session(session_id)
	if session != null and session.is_active():
		session.send_message("mcp_for_godot_ack:sample", [run_id, sequence])


func _reject(session_id: int, code: String, message: String, field: String = "") -> void:
	var error := {"code": code, "message": message}
	var event := {"kind": "rejected", "code": code}
	if not field.is_empty():
		error["field"] = field
		event["field"] = field
	_capture_errors[session_id] = error
	_append_event(session_id, event)
	_render_session(session_id)


func _append_event(session_id: int, details: Dictionary) -> void:
	var event := details.duplicate(true)
	event["received_ticks_usec"] = Time.get_ticks_usec()
	event["received_utc"] = Time.get_datetime_string_from_system(true, true)
	var events: Array = _timeline.get(session_id, [])
	events.append(event)
	if events.size() > MAX_TIMELINE:
		events.pop_front()
		_timeline_dropped[session_id] = int(_timeline_dropped.get(session_id, 0)) + 1
	_timeline[session_id] = events
	_timeline_revision[session_id] = int(_timeline_revision.get(session_id, 0)) + 1


func _observed_changes(old_sample: Dictionary, sample: Dictionary) -> Dictionary:
	var result := {"items": [], "truncated": false, "node_set_complete": not sample.get("nodes_truncated", false) and not old_sample.get("nodes_truncated", false)}
	if old_sample.is_empty() or old_sample.get("run_id") != sample["run_id"]:
		return result
	var old_nodes := {}
	for node in old_sample.get("nodes", []):
		old_nodes[node["path"]] = node
	for node in sample["nodes"]:
		var path: String = node["path"]
		if not old_nodes.has(path):
			continue
		var old: Dictionary = old_nodes[path]
		for field in ["text", "visible_in_tree"]:
			if not node.has(field) or not old.has(field) or node[field] == old[field]:
				continue
			if result["items"].size() >= MAX_EVENT_CHANGES:
				result["truncated"] = true
				return result
			result["items"].append({"path": path, "field": field, "before": old[field], "after": node[field], "basis": "observed_between_samples", "match_key": "node_path_only"})
	if not result["node_set_complete"]:
		return result
	if old_sample.has("structure_generation") and sample.has("structure_generation") and old_sample["structure_generation"] == sample["structure_generation"]:
		return result
	var new_nodes := {}
	for node in sample["nodes"]:
		new_nodes[node["path"]] = node
	for node in old_sample["nodes"]:
		var path: String = node["path"]
		if new_nodes.has(path):
			continue
		if result["items"].size() >= MAX_EVENT_CHANGES:
			result["truncated"] = true
			return result
		result["items"].append({"path": path, "field": "presence", "before": true, "after": false, "basis": "observed_between_samples", "match_key": "node_path_only"})
	for node in sample["nodes"]:
		var path: String = node["path"]
		if old_nodes.has(path):
			continue
		if result["items"].size() >= MAX_EVENT_CHANGES:
			result["truncated"] = true
			return result
		result["items"].append({"path": path, "field": "presence", "before": false, "after": true, "basis": "observed_between_samples", "match_key": "node_path_only"})
	return result


func _validation_error(code: String, field: String = "") -> Dictionary:
	return {"code": code, "field": field} if not field.is_empty() else {"code": code}


func _valid_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return number >= 0.0 and number <= 1.0e12


func _valid_metric(value: Variant, scope: String, unit: String) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var metric: Dictionary = value
	if typeof(metric.get("source")) != TYPE_STRING or str(metric["source"]).is_empty() or str(metric["source"]).length() > 160:
		return false
	if metric.get("scope") != scope or metric.get("unit") != unit:
		return false
	var status: Variant = metric.get("status")
	if status == "ok":
		return _valid_number(metric.get("value"))
	if not ["not_updating", "freshness_unverified", "unsupported", "error"].has(status):
		return false
	return metric.get("value") == null and typeof(metric.get("reason")) == TYPE_STRING and not str(metric["reason"]).is_empty() and str(metric["reason"]).length() <= 120


func _valid_subsystem_metric(value: Variant, spec: Array) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var metric: Dictionary = value
	if metric.size() != (6 if metric.has("reason") else 5):
		return false
	for required_key in ["value", "source", "scope", "unit", "status"]:
		if not metric.has(required_key):
			return false
	for key in metric:
		if key not in ["value", "source", "scope", "unit", "status", "reason"]:
			return false
	if metric.get("source") != spec[0] or metric.get("scope") != spec[1] or metric.get("unit") != spec[2]:
		return false
	var kind: String = spec[3]
	var status: Variant = metric.get("status")
	var data: Variant = metric.get("value")
	if status == "ok" and not metric.has("reason"):
		if kind in ["number", "monitor"]:
			return typeof(data) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(data)) and float(data) >= 0.0 and float(data) <= 1000000000.0
		if kind == "bool":
			return typeof(data) == TYPE_BOOL
		if kind == "enum":
			return typeof(data) == TYPE_INT and int(data) >= 0 and int(data) <= 3
		if kind in ["text", "transport"]:
			return typeof(data) == TYPE_STRING and not str(data).is_empty() and str(data).length() <= 64
		return false
	if typeof(metric.get("reason")) != TYPE_STRING:
		return false
	var reason: String = metric["reason"]
	if kind == "monitor" and status == "unverified_zero":
		return typeof(data) in [TYPE_INT, TYPE_FLOAT] and float(data) == 0.0 and reason == "public_monitor_has_no_support_flag"
	if status != "unavailable" or data != null:
		return false
	if kind in ["number", "monitor"]:
		return reason == "negative_non_finite_or_out_of_range"
	if kind in ["enum", "transport"]:
		return reason == "no_peer"
	if kind == "remote":
		return reason in ["remote_connection_not_verified", "offline_peer"]
	return false


func _validate_subsystems(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return _validation_error("invalid_subsystems", "subsystems")
	var groups: Dictionary = value
	if groups.size() != SUBSYSTEM_FIELDS.size() + 1 or groups.get("sampling_scope") != SUBSYSTEM_SAMPLING_SCOPE:
		return _validation_error("invalid_subsystems", "subsystems.sampling_scope")
	for group_name in groups:
		if group_name != "sampling_scope" and not SUBSYSTEM_FIELDS.has(group_name):
			return _validation_error("invalid_subsystems", "subsystems." + str(group_name).left(64))
	for group_name in SUBSYSTEM_FIELDS:
		var fields: Dictionary = SUBSYSTEM_FIELDS[group_name]
		var group: Variant = groups.get(group_name)
		if typeof(group) != TYPE_DICTIONARY or group.size() != fields.size():
			return _validation_error("invalid_subsystems", "subsystems." + group_name)
		for field_name in group:
			if not fields.has(field_name):
				return _validation_error("invalid_subsystems", "subsystems." + group_name + "." + str(field_name).left(64))
		for field_name in fields:
			if not _valid_subsystem_metric(group.get(field_name), fields[field_name]):
				return _validation_error("invalid_subsystems", "subsystems." + group_name + "." + field_name)
	return {}


func _valid_vec2(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and value.size() == 2 and _valid_number(value[0]) and _valid_number(value[1])


func _validate_viewport(value: Variant, field: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return _validation_error("invalid_viewport", field)
	var viewport: Dictionary = value
	if typeof(viewport.get("path")) != TYPE_STRING or str(viewport["path"]).is_empty() or str(viewport["path"]).length() > 512:
		return _validation_error("invalid_viewport", field + ".path")
	if not ["root", "subviewport"].has(viewport.get("kind")) or not _valid_vec2(viewport.get("size")):
		return _validation_error("invalid_viewport", field)
	if not ["latest_available", "not_rendering", "unverified"].has(viewport.get("frame_alignment")):
		return _validation_error("invalid_viewport", field + ".frame_alignment")
	if viewport["kind"] == "subviewport" and (typeof(viewport.get("update_mode")) != TYPE_INT or int(viewport["update_mode"]) < 0 or int(viewport["update_mode"]) > 4):
		return _validation_error("invalid_viewport", field + ".update_mode")
	for key in ["canvas_objects", "canvas_primitives", "canvas_draw_calls"]:
		if not _valid_metric(viewport.get(key), "viewport", "count"):
			return _validation_error("invalid_metric", field + "." + key)
	return {}


func _validate_sample(sample: Dictionary, checked_bytes: int) -> Dictionary:
	if checked_bytes > MAX_SAMPLE_BYTES:
		return _validation_error("sample_too_large")
	if sample.get("schema_version") != SCHEMA_VERSION or sample.get("origin") != "runtime":
		return _validation_error("invalid_schema")
	if sample.has("graphics_performance") and not _valid_graphics_performance(sample["graphics_performance"]):
		return _validation_error("invalid_graphics_performance", "graphics_performance")
	if sample.has("subsystems"):
		var subsystem_error := _validate_subsystems(sample["subsystems"])
		if not subsystem_error.is_empty():
			return subsystem_error
	if sample.get("project_fingerprint") != ProjectSettings.globalize_path("res://").sha256_text():
		return _validation_error("wrong_project")
	if typeof(sample.get("run_id")) != TYPE_STRING or str(sample["run_id"]).length() > 80:
		return _validation_error("invalid_run_id")
	if typeof(sample.get("sample_seq")) != TYPE_INT or int(sample["sample_seq"]) < 1:
		return _validation_error("invalid_sequence")
	if sample.has("previous_send_call_usec") or sample.has("previous_send_sample_seq"):
		if typeof(sample.get("previous_send_sample_seq")) != TYPE_INT or int(sample["previous_send_sample_seq"]) != int(sample["sample_seq"]) - 1 or typeof(sample.get("previous_send_call_usec")) != TYPE_INT or int(sample["previous_send_call_usec"]) < 0 or int(sample["previous_send_call_usec"]) > 10_000_000:
			return _validation_error("invalid_send_timing", "previous_send_call_usec")
	if sample.has("previous_ack_roundtrip_usec") or sample.has("previous_ack_sample_seq"):
		if typeof(sample.get("previous_ack_sample_seq")) != TYPE_INT or int(sample["previous_ack_sample_seq"]) != int(sample["sample_seq"]) - 1 or typeof(sample.get("previous_ack_roundtrip_usec")) != TYPE_INT or int(sample["previous_ack_roundtrip_usec"]) < 0 or int(sample["previous_ack_roundtrip_usec"]) > 1_000_000_000_000:
			return _validation_error("invalid_ack_timing", "previous_ack_roundtrip_usec")
	if typeof(sample.get("scene_path")) != TYPE_STRING or not str(sample["scene_path"]).begins_with("res://"):
		return _validation_error("invalid_scene")
	if typeof(sample.get("nodes")) != TYPE_ARRAY or sample["nodes"].size() > MAX_NODES:
		return _validation_error("invalid_nodes")
	if typeof(sample.get("viewport")) != TYPE_DICTIONARY or typeof(sample.get("performance")) != TYPE_DICTIONARY or typeof(sample.get("backend")) != TYPE_DICTIONARY:
		return _validation_error("invalid_metrics")
	if sample.has("viewports"):
		if typeof(sample["viewports"]) != TYPE_ARRAY or sample["viewports"].is_empty() or sample["viewports"].size() > MAX_VIEWPORTS:
			return _validation_error("invalid_viewports")
	for index in range(sample["nodes"].size()):
		var node: Variant = sample["nodes"][index]
		if typeof(node) != TYPE_DICTIONARY or typeof(node.get("path")) != TYPE_STRING or str(node["path"]).length() > 512:
			return _validation_error("invalid_node", "nodes[%s]" % index)
		if node.has("text"):
			if not TEXT_NODE_PATHS.has(node["path"]):
				return _validation_error("invalid_text_scope", "nodes[%s].text" % index)
			if typeof(node["text"]) != TYPE_STRING or str(node["text"]).length() > 160:
				return _validation_error("invalid_node_field", "nodes[%s].text" % index)
		if node.has("visible_in_tree") and typeof(node["visible_in_tree"]) != TYPE_BOOL:
			return _validation_error("invalid_node_field", "nodes[%s].visible_in_tree" % index)
	var root_error := _validate_viewport(sample["viewport"], "viewport")
	if not root_error.is_empty():
		return root_error
	if sample.has("viewports"):
		for index in range(sample["viewports"].size()):
			var viewport_error := _validate_viewport(sample["viewports"][index], "viewports[%s]" % index)
			if not viewport_error.is_empty():
				return viewport_error
	for key in ["total_objects", "total_primitives", "total_draw_calls"]:
		if not _valid_metric(sample["performance"].get(key), "process", "count"):
			return _validation_error("invalid_metric", "performance." + key)
	if not _valid_metric(sample["performance"].get("fps"), "process", "fps"):
		return _validation_error("invalid_metric", "performance.fps")
	for key in ["method", "driver", "gpu"]:
		if typeof(sample["backend"].get(key)) != TYPE_STRING or str(sample["backend"][key]).length() > 256:
			return _validation_error("invalid_backend", "backend." + key)
	return {}


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	var tab := VBoxContainer.new()
	tab.name = "MCP for Godot"
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var heading := Label.new()
	heading.text = "Aguardando amostras da cena em execução"
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tab.add_child(heading)
	var metrics := Label.new()
	metrics.text = "Cena de runtime, viewport e Performance aparecerão aqui."
	metrics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var subsystems_tree := Tree.new()
	subsystems_tree.name = "Subsistemas"
	subsystems_tree.columns = 4
	subsystems_tree.column_titles_visible = true
	subsystems_tree.set_column_title(0, "Subsistema / métrica")
	subsystems_tree.set_column_title(1, "Valor")
	subsystems_tree.set_column_title(2, "Estado")
	subsystems_tree.set_column_title(3, "Fonte / escopo")
	subsystems_tree.custom_minimum_size = Vector2(540, 160)
	subsystems_tree.visible = false
	var note := Label.new()
	note.text = "Origem: jogo em execução. Canvas = Viewport.get_render_info(CANVAS), escopo do viewport; total = Performance.get_monitor(RENDER_TOTAL_DRAW_CALLS_IN_FRAME), escopo do processo. Ambos representam o último frame disponível. Compare o total em Depurador > Monitores > Raster > Total Draw Calls."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var tree := Tree.new()
	tree.name = "Cena"
	tree.columns = 3
	tree.column_titles_visible = true
	tree.set_column_title(0, "Nó de runtime")
	tree.set_column_title(1, "Tipo")
	tree.set_column_title(2, "Estado")
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.custom_minimum_size = Vector2(540, 180)
	var views := TabContainer.new()
	views.size_flags_vertical = Control.SIZE_EXPAND_FILL
	views.custom_minimum_size = Vector2(540, 180)
	tab.add_child(views)
	var scene_panel := VBoxContainer.new()
	scene_panel.name = "Cena"
	scene_panel.add_child(metrics)
	scene_panel.add_child(subsystems_tree)
	scene_panel.add_child(note)
	scene_panel.add_child(tree)
	views.add_child(scene_panel)
	var timeline_tree := Tree.new()
	timeline_tree.name = "Eventos"
	timeline_tree.columns = 4
	timeline_tree.column_titles_visible = true
	timeline_tree.set_column_title(0, "Recebido UTC")
	timeline_tree.set_column_title(1, "Evento")
	timeline_tree.set_column_title(2, "Amostra")
	timeline_tree.set_column_title(3, "Detalhe")
	timeline_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline_tree.tooltip_text = "Amostras limitadas a 1 Hz; mudanças observadas entre leituras, sem causa atribuída."
	views.add_child(timeline_tree)
	var preview_panel := VBoxContainer.new()
	preview_panel.name = "Imagem"
	preview_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var preview_scroll := ScrollContainer.new()
	preview_scroll.name = "Imagem"
	preview_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	preview_scroll.add_child(preview_panel)
	views.add_child(preview_scroll)
	var preview_label := Label.new()
	preview_label.text = "Escolha um viewport e capture. Clique na imagem para listar candidatos geométricos; não são prova de autoria do pixel."
	preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_panel.add_child(preview_label)
	var capture_controls := HBoxContainer.new()
	var viewport_choice := OptionButton.new()
	viewport_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	capture_controls.add_child(viewport_choice)
	var capture_button := Button.new()
	capture_button.text = "Capturar viewport"
	capture_button.pressed.connect(_request_ui_image.bind(session_id))
	capture_controls.add_child(capture_button)
	preview_panel.add_child(capture_controls)
	var graphics_label := Label.new()
	graphics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_panel.add_child(graphics_label)
	var preview_texture := TextureRect.new()
	preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_texture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_texture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_texture.custom_minimum_size = Vector2(540, 180)
	preview_panel.add_child(preview_texture)
	preview_texture.gui_input.connect(_pick_image.bind(session_id))
	var visual_tree := Tree.new()
	visual_tree.columns = 3
	visual_tree.column_titles_visible = true
	visual_tree.set_column_title(0, "Candidato / nó")
	visual_tree.set_column_title(1, "Textura / material / shader")
	visual_tree.set_column_title(2, "Limite da observação")
	visual_tree.custom_minimum_size = Vector2(540, 110)
	visual_tree.item_activated.connect(_select_editor_candidate.bind(session_id))
	preview_panel.add_child(visual_tree)
	preview_panel.move_child(capture_controls, 0)
	preview_panel.move_child(preview_texture, 1)
	var frames_panel := VBoxContainer.new()
	frames_panel.name = "Frames"
	var frames_label := Label.new()
	frames_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	frames_panel.add_child(frames_label)
	var frames_plot := FrameTimeline.new()
	frames_plot.custom_minimum_size = Vector2(540, 150)
	frames_plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frames_plot.tooltip_text = "Intervalos do processo, até 240 observações. A linha amarela marca 16,67 ms. Não é tempo de GPU."
	frames_panel.add_child(frames_plot)
	views.add_child(frames_panel)
	views.tab_changed.connect(_show_image_preview.bind(session_id))
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_refresh_session.bind(session_id))
	tab.add_child(timer)
	_tabs[session_id] = {"heading": heading, "metrics": metrics, "subsystems_tree": subsystems_tree, "tree": tree, "timeline": timeline_tree, "views": views, "preview_label": preview_label, "preview_texture": preview_texture, "viewport_choice": viewport_choice, "visual_tree": visual_tree, "graphics_label": graphics_label, "rendered_sample_ticks_usec": -1, "rendered_timeline_revision": -1, "rendered_paths": [], "rendered_rows": {}, "rendered_values": {}}
	_tabs[session_id]["frames_plot"] = frames_plot
	_tabs[session_id]["frames_label"] = frames_label
	session.started.connect(_session_started.bind(session_id))
	session.stopped.connect(_session_stopped.bind(session_id))
	_native_supported[session_id] = session.has_method("get_native_diagnostic_version") and session.has_signal("native_diagnostic") and session.get_native_diagnostic_version() == 1
	if _native_supported[session_id]:
		session.native_diagnostic.connect(_on_native_diagnostic.bind(session_id))
	session.add_session_tab(tab)


func _session_started(session_id: int) -> void:
	_native_diagnostics.start(session_id)
	_input_requests.erase(session_id)
	_images.erase(session_id)
	_clear_image_preview(session_id)
	_image_last_request_ticks.erase(session_id)
	_latest.erase(session_id)
	_history.erase(session_id)
	_timeline.erase(session_id)
	_timeline_revision.erase(session_id)
	_timeline_dropped.erase(session_id)
	_capture_costs.erase(session_id)
	_capture_errors.erase(session_id)
	_missing_sequences.erase(session_id)
	_last_sequence_gap.erase(session_id)
	_backpressure.erase(session_id)
	_stale_announced.erase(session_id)
	_render_session(session_id)


func _session_stopped(session_id: int) -> void:
	_native_diagnostics.stop(session_id)
	if _input_requests.has(session_id):
		_input_requests[session_id]["status"] = "unavailable"
		_input_requests[session_id]["code"] = "session_changed"
	_clear_image_preview(session_id)
	if _images.has(session_id):
		var image: Dictionary = _images[session_id]
		image.erase("png")
		image["status"] = "unavailable"
		image["error"] = {"code": "session_changed", "message": "A sessão terminou durante a captura."}
	_image_last_request_ticks.erase(session_id)
	_latest.erase(session_id)
	_history.erase(session_id)
	_timeline.erase(session_id)
	_timeline_revision.erase(session_id)
	_timeline_dropped.erase(session_id)
	_capture_costs.erase(session_id)
	_capture_errors.erase(session_id)
	_missing_sequences.erase(session_id)
	_last_sequence_gap.erase(session_id)
	_backpressure.erase(session_id)
	_stale_announced.erase(session_id)
	_render_session(session_id)


func _on_native_diagnostic(diagnostic: Dictionary, session_id: int) -> void:
	_native_diagnostics.append(session_id, diagnostic)


func get_native_diagnostics(requested_session: int = -1, run_generation: int = -1, after_cursor: int = 0, limit: int = 40) -> Dictionary:
	if requested_session < -1:
		return _problem("invalid_session", "Identificador de sessão inválido.")
	var active: Array[int] = []
	for index in range(get_sessions().size()):
		var session := get_session(index)
		if session != null and session.is_active():
			active.append(index)
	if requested_session == -1:
		if active.is_empty():
			return _problem("no_active_session", "Nenhum jogo conectado ao depurador do editor.")
		if active.size() != 1:
			return _problem("ambiguous_session", "Informe session_id para escolher um jogo.", {"active_sessions": active})
		requested_session = active[0]
	if not _native_supported.get(requested_session, false):
		return _problem("native_debugger_unavailable", "Este binário não expõe diagnósticos nativos versionados.", {"session_id": requested_session})
	return _native_diagnostics.read(requested_session, run_generation, after_cursor, limit)


func _clear_image_preview(session_id: int) -> void:
	_preview_images.erase(session_id)
	_ui_captures.erase(session_id)
	if _tabs.has(session_id):
		var view: Dictionary = _tabs[session_id]
		(view["preview_texture"] as TextureRect).texture = null
		(view["visual_tree"] as Tree).clear()
		(view["graphics_label"] as Label).text = ""
		(view["viewport_choice"] as OptionButton).clear()
		view["frames_plot"].set_intervals([])
		(view["frames_label"] as Label).text = "Nenhuma janela de frames desta sessão."
		(view["preview_label"] as Label).text = "Nenhuma imagem desta sessão. Capturas do viewport raiz pedidas pelo MCP aparecem aqui."


func _refresh_session(session_id: int) -> void:
	if _ui_captures.has(session_id):
		var image_result := get_image_result(session_id, _ui_captures[session_id])
		if image_result["status"] != "pending":
			_ui_captures.erase(session_id)
			if image_result["status"] == "unavailable":
				(_tabs[session_id]["preview_label"] as Label).text = str(image_result["error"])
	var entry: Dictionary = _latest.get(session_id, {})
	if not entry.is_empty() and not _stale_announced.has(session_id) and not _capture_errors.has(session_id) and not _backpressure.has(session_id):
		var age_usec: int = Time.get_ticks_usec() - int(entry["received_ticks_usec"])
		if age_usec > STALE_AFTER_USEC:
			_stale_announced[session_id] = true
			var sample: Dictionary = entry["sample"]
			_append_event(session_id, {"kind": "stale_timeout", "run_id": sample["run_id"], "sample_seq": sample["sample_seq"], "age_ms": int(age_usec / 1000), "cause": "no_recent_sample"})
	_render_session(session_id)


func get_snapshot(requested_session: int = -1, copy_sample: bool = true) -> Dictionary:
	if requested_session < -1:
		return _problem("invalid_session", "Identificador de sessão inválido.")
	var active: Array[int] = []
	for index in range(get_sessions().size()):
		var session := get_session(index)
		if session != null and session.is_active():
			active.append(index)
	if requested_session == -1:
		if active.is_empty():
			return _problem("no_active_session", "Nenhum jogo conectado ao depurador do editor.")
		if active.size() != 1:
			return _problem("ambiguous_session", "Informe session_id para escolher um jogo.", {"active_sessions": active})
		requested_session = active[0]
	elif not active.has(requested_session):
		return _problem("inactive_session", "A sessão solicitada não está ativa.", {"active_sessions": active})
	if not _latest.has(requested_session):
		if _capture_errors.has(requested_session):
			var capture_error: Dictionary = _capture_errors[requested_session]
			return _problem(capture_error["code"], capture_error["message"], {"session_id": requested_session})
		if _backpressure.has(requested_session):
			return _problem("backpressure", "Coleta suspensa aguardando confirmação do editor.", {"session_id": requested_session, "flow": _backpressure[requested_session]})
		return _problem("no_sample", "A sessão ainda não publicou uma amostra.", {"session_id": requested_session})
	var entry: Dictionary = _latest[requested_session]
	var age_ms: int = maxi(0, int((Time.get_ticks_usec() - int(entry["received_ticks_usec"])) / 1000))
	var capture_error: Dictionary = _capture_errors.get(requested_session, {})
	var flow: Dictionary = _backpressure.get(requested_session, {})
	var status := "stale" if age_ms * 1000 > STALE_AFTER_USEC or not capture_error.is_empty() or not flow.is_empty() else "ok"
	return {
		"status": status,
		"session_id": requested_session,
		"age_ms": age_ms,
		"received_ticks_usec": entry["received_ticks_usec"],
		"received_utc": entry["received_utc"],
		"history_count": (_history.get(requested_session, []) as Array).size(),
		"sequence_gaps": int(_missing_sequences.get(requested_session, 0)),
		"last_sequence_gap": int(_last_sequence_gap.get(requested_session, 0)),
		"flow": flow if not flow.is_empty() else null,
		"sample": (entry["sample"] as Dictionary).duplicate(true) if copy_sample else entry["sample"],
		"error": capture_error if not capture_error.is_empty() else ({"code": "backpressure", "message": "Coleta suspensa aguardando confirmação do editor."} if not flow.is_empty() else ({"code": "stale_sample", "message": "A última amostra não é atual."} if status == "stale" else null))
	}


func get_timeline(requested_session: int = -1, limit: int = 20) -> Dictionary:
	if limit < 1 or limit > 40:
		return _problem("invalid_limit", "O limite da linha do tempo deve estar entre 1 e 40.")
	var current := get_snapshot(requested_session, false)
	if current["status"] == "unavailable" and not current.has("session_id"):
		return current
	var session_id: int = current["session_id"]
	var events: Array = _timeline.get(session_id, [])
	var start: int = maxi(0, events.size() - limit)
	var selected: Array = events.slice(start).duplicate(true)
	var dropped: int = int(_timeline_dropped.get(session_id, 0))
	var cost: Dictionary = _capture_costs.get(session_id, {})
	var window := {"events": selected, "truncated": start > 0 or dropped > 0, "retained_event_count": events.size(), "dropped_event_count": dropped, "receiver_last_capture_usec": cost.duplicate(true) if not cost.is_empty() else null}
	if current["status"] == "unavailable":
		var unavailable := {"schema_version": SCHEMA_VERSION, "origin": "editor_receiver", "status": "unavailable", "session_id": session_id, "error": current["error"]}
		unavailable.merge(window)
		return unavailable
	var sample: Dictionary = current["sample"]
	var result := {"schema_version": SCHEMA_VERSION, "origin": "editor_receiver", "status": current["status"], "session_id": session_id, "age_ms": current["age_ms"], "run_id": sample["run_id"], "latest_sample_seq": sample["sample_seq"], "scene_path": sample["scene_path"], "backend": sample["backend"], "error": current["error"]}
	result.merge(window)
	return result


func _problem(code: String, message: String, extra: Dictionary = {}) -> Dictionary:
	var result := {"status": "unavailable", "error": {"code": code, "message": message}}
	result.merge(extra)
	return result


func _render_session(session_id: int) -> void:
	if not _tabs.has(session_id):
		return
	var view: Dictionary = _tabs[session_id]
	var heading: Label = view["heading"]
	var metrics: Label = view["metrics"]
	var tree: Tree = view["tree"]
	var timeline_tree: Tree = view["timeline"]
	var result := get_snapshot(session_id, false)
	if result["status"] == "unavailable":
		heading.text = "MCP for Godot · %s" % result["error"]["message"]
		metrics.text = "Nenhum dado vivo disponível."
		(view["subsystems_tree"] as Tree).visible = false
		if int(view.get("rendered_sample_ticks_usec", -1)) != -1:
			tree.clear()
			view["rendered_sample_ticks_usec"] = -1
			view["rendered_paths"] = []
			view["rendered_rows"] = {}
			view["rendered_values"] = {}
		_render_timeline(session_id, timeline_tree)
		return
	var sample: Dictionary = result["sample"]
	_update_viewport_choices(session_id, sample)
	if int(view.get("rendered_sample_ticks_usec", -1)) != int(result["received_ticks_usec"]):
		var frame_timing: Dictionary = sample.get("graphics_performance", {})
		view["frames_plot"].set_intervals(frame_timing.get("intervals_ms", []))
		(view["frames_label"] as Label).text = "Intervalos do processo · %s observações · p50 %s ms · p95 %s ms · máximo %s ms\nJanela móvel de até 240 observações, publicada com a amostra; pode omitir frames entre leituras. Linha amarela: 16,67 ms. GPU: %s ms (%s), fonte RenderingServer, sem correspondência exata de frame." % [frame_timing.get("samples", 0), frame_timing.get("p50_ms", "?"), frame_timing.get("p95_ms", "?"), frame_timing.get("max_ms", "?"), frame_timing.get("gpu_ms", "?"), frame_timing.get("gpu_status", "?" )]
	var viewport: Dictionary = sample["viewport"]
	var performance: Dictionary = sample["performance"]
	var backend: Dictionary = sample["backend"]
	var viewport_size: Array = viewport.get("size", [])
	heading.text = "MCP for Godot · %s · sessão %s · amostra %s · frame %s · idade %s ms%s · lacunas %s\n%s / %s · GPU: %s" % [sample["scene_path"], session_id, sample["sample_seq"], sample.get("render_frame", "?"), result["age_ms"], " · AMOSTRA ANTIGA" if result["status"] == "stale" else "", result["sequence_gaps"], backend.get("method", "?"), backend.get("driver", "?"), backend.get("gpu", "?")]
	if result.get("flow") != null:
		var flow: Dictionary = result["flow"]
		heading.text += "\nColeta suspensa: sem ACK da amostra %s; %s intervalo(s) ignorado(s)." % [flow.get("pending_seq", "?"), flow.get("skipped_intervals", "?")]
	metrics.text = "Viewport %s · %s × %s px\nCanvas deste viewport: %s chamadas, %s objetos, %s primitivas\nTotal do processo (Performance): %s chamadas, %s FPS · coleta %s µs" % [
		viewport.get("path", "?"),
		viewport_size[0] if viewport_size.size() == 2 else "?",
		viewport_size[1] if viewport_size.size() == 2 else "?",
		_value(viewport.get("canvas_draw_calls", {})),
		_value(viewport.get("canvas_objects", {})),
		_value(viewport.get("canvas_primitives", {})),
		_value(performance.get("total_draw_calls", {})),
		_value(performance.get("fps", {})),
		sample.get("collect_usec", "?")
	]
	if sample.has("previous_ack_roundtrip_usec"):
		metrics.text += "\nACK da amostra %s: ida e volta %s µs (jogo → editor → jogo; inclui fila/agendamento)" % [sample["previous_ack_sample_seq"], sample["previous_ack_roundtrip_usec"]]
	for extra in sample.get("viewports", []):
		if extra.get("kind") != "subviewport":
			continue
		var extra_size: Array = extra.get("size", [])
		metrics.text += "\nSubViewport %s · %s × %s px · atualização %s · canvas %s chamadas" % [extra.get("path", "?"), extra_size[0] if extra_size.size() == 2 else "?", extra_size[1] if extra_size.size() == 2 else "?", extra.get("update_mode", "?"), _value(extra.get("canvas_draw_calls", {}))]
	if sample.get("viewports_truncated", false):
		metrics.text += "\nLista de viewports truncada."
	if int(view.get("rendered_sample_ticks_usec", -1)) != int(result["received_ticks_usec"]):
		_render_subsystems(sample, view)
		var paths: Array[String] = []
		for node in sample["nodes"]:
			paths.append(str(node["path"]))
		var rebuild: bool = view.get("rendered_paths", []) != paths or int(view.get("rendered_sample_ticks_usec", -1)) == -1
		var rows: Dictionary = view.get("rendered_rows", {})
		var values: Dictionary = view.get("rendered_values", {})
		var root_item: TreeItem = null
		if rebuild:
			tree.clear()
			root_item = tree.create_item()
			rows = {".": root_item}
			values = {}
		for node in sample["nodes"]:
			var path: String = node["path"]
			var row: TreeItem
			if rebuild:
				var parent_path := path.get_base_dir() if path != "." else "."
				if parent_path.is_empty():
					parent_path = "."
				var parent: TreeItem = rows.get(parent_path, root_item)
				row = tree.create_item(parent)
				rows[path] = row
			else:
				row = rows[path]
			var name: String = str(node.get("name", path))
			var kind: String = str(node.get("type", "?"))
			var details := "visível=%s" % str(node.get("visible_in_tree", "?"))
			if node.has("position"):
				details += " · pos=%s" % str(node["position"])
			if node.has("size"):
				details += " · tamanho=%s" % str(node["size"])
			if node.has("text"):
				details += " · %s" % node["text"]
			var before: Array = values.get(path, [])
			if before.size() != 3 or before[0] != name:
				row.set_text(0, name)
			if before.size() != 3 or before[1] != kind:
				row.set_text(1, kind)
			if before.size() != 3 or before[2] != details:
				row.set_text(2, details)
			values[path] = [name, kind, details]
		view["rendered_paths"] = paths
		view["rendered_rows"] = rows
		view["rendered_values"] = values
		view["rendered_sample_ticks_usec"] = int(result["received_ticks_usec"])
	_render_timeline(session_id, timeline_tree)


func _render_timeline(session_id: int, timeline_tree: Tree) -> void:
	var view: Dictionary = _tabs[session_id]
	var revision: int = int(_timeline_revision.get(session_id, 0))
	if int(view.get("rendered_timeline_revision", -1)) == revision:
		return
	timeline_tree.clear()
	var root_item := timeline_tree.create_item()
	var events: Array = _timeline.get(session_id, [])
	for index in range(maxi(0, events.size() - 12), events.size()):
		var event: Dictionary = events[index]
		var row := timeline_tree.create_item(root_item)
		row.set_text(0, str(event.get("received_utc", "?")))
		row.set_text(1, str(event.get("kind", "?")))
		row.set_text(2, str(event.get("sample_seq", "—")))
		var detail := ""
		match str(event.get("kind", "")):
			"image":
				detail = "captura %s · frame %s · viewport %s" % [event.get("capture_id", "?"), event.get("render_frame", "?"), event.get("viewport_path", "?")]
			"sample":
				detail = "frame %s" % event.get("render_frame", "?")
				var changes: Array = event.get("changes", [])
				if not changes.is_empty():
					var change: Dictionary = changes[0]
					detail += " · %s.%s: %s → %s" % [change["path"], change["field"], change["before"], change["after"]]
				if changes.size() > 1 or event.get("changes_truncated", false):
					detail += " · %s mudança(s)%s" % [changes.size(), "+" if event.get("changes_truncated", false) else ""]
			"sequence_gap":
				detail = "%s amostra(s) ausente(s); causa desconhecida" % event.get("missing_count", "?")
			"backpressure":
				detail = "%s intervalo(s) ignorado(s); aguardando ACK" % event.get("skipped_intervals", "?")
			"rejected":
				detail = "amostra rejeitada: %s" % event.get("code", "?")
				if event.has("field"):
					detail += " · %s" % event["field"]
			"stale_timeout":
				detail = "sem nova amostra há %s ms; causa desconhecida" % event.get("age_ms", "?")
		row.set_text(3, detail)
	view["rendered_timeline_revision"] = revision


func _value(metric: Dictionary) -> String:
	if metric.get("status") != "ok":
		return "indisponível"
	return str(metric.get("value", "?"))


func _render_subsystems(sample: Dictionary, view: Dictionary) -> void:
	var display: Tree = view["subsystems_tree"]
	var payload: Variant = sample.get("subsystems")
	if typeof(payload) != TYPE_DICTIONARY:
		display.visible = false # Amostras de coletores anteriores não possuem este campo.
		display.clear()
		return
	var expanded: Dictionary = {}
	var old_root := display.get_root()
	if old_root != null:
		var old_group := old_root.get_first_child()
		while old_group != null:
			expanded[old_group.get_text(0)] = not old_group.collapsed
			old_group = old_group.get_next()
	display.clear()
	display.hide_root = true
	display.visible = true
	var root := display.create_item()
	var groups := [
		["physics_2d", "Física 2D", {"active_objects": "Ativos", "collision_pairs": "Pares", "islands": "Ilhas"}],
		["physics_3d", "Física 3D", {"active_objects": "Ativos", "collision_pairs": "Pares", "islands": "Ilhas"}],
		["audio", "Áudio", {"bus_count": "Barramentos", "time_since_last_mix": "Desde mix", "time_to_next_mix": "Até mix", "output_latency": "Latência"}],
		["multiplayer", "Multiplayer", {"peer_present": "Peer presente", "transport_kind": "Transporte", "connection_status": "Conexão local", "remote_connection": "Conexão remota"}],
		["navigation_2d", "Navegação 2D", {"active_maps": "Mapas", "regions": "Regiões", "agents": "Agentes"}],
		["navigation_3d", "Navegação 3D", {"active_maps": "Mapas", "regions": "Regiões", "agents": "Agentes"}],
		["platform", "Plataforma", {"os_name": "Sistema", "display_backend": "Display"}]
	]
	for definition in groups:
		var group_key: String = definition[0]
		var group_data: Variant = payload.get(group_key)
		if typeof(group_data) != TYPE_DICTIONARY:
			continue
		var group := display.create_item(root)
		group.set_text(0, definition[1])
		group.collapsed = not expanded.get(definition[1], false)
		for field in definition[2]:
			var metric: Variant = group_data.get(field)
			if typeof(metric) != TYPE_DICTIONARY:
				continue
			var row := display.create_item(group)
			row.set_text(0, definition[2][field])
			var status := str(metric.get("status", "unavailable")).left(32)
			var unit := str(metric.get("unit", "")).left(24)
			var has_value := metric.get("value") != null
			row.set_text(1, (str(metric.get("value")) if has_value else "—") + (" " + unit if has_value and unit not in ["", "count", "boolean", "name", "enum"] else ""))
			row.set_text(2, status if status == "ok" else status + " · " + str(metric.get("reason", "")).left(64))
			row.set_text(3, (str(metric.get("source", "?")).replace("\n", " ").left(160) + " · " + str(metric.get("scope", "?")).left(48)))
	display.tooltip_text = "Leituras públicas mais recentes; contadores de Performance são do processo, não causalmente atribuídos à cena. Escopo: " + str(payload.get("sampling_scope", "não informado")).left(120)


func _valid_frame_context(context: Variant, entry: Dictionary, result: Dictionary) -> bool:
	if typeof(context) != TYPE_DICTIONARY:
		return false
	if context.is_empty():
		return true # Coletor legado: nenhuma relação visual é anunciada.
	if int(SampleSize.checked_size(context, GraphicsProbe.MAX_CONTEXT_BYTES)["bytes"]) > GraphicsProbe.MAX_CONTEXT_BYTES:
		return false
	if context.get("viewport_path") != entry.get("viewport_path") or context.get("observed_render_frame") != result.get("render_frame") or context.get("pixel_metric_same_frame") != "unproven":
		return false
	if typeof(context.get("items")) != TYPE_ARRAY or context["items"].size() > GraphicsProbe.MAX_ITEMS:
		return false
	for item in context["items"]:
		if typeof(item) != TYPE_DICTIONARY or typeof(item.get("path")) != TYPE_STRING or item["path"].length() > 512 or typeof(item.get("type")) != TYPE_STRING or typeof(item.get("visible_in_tree")) != TYPE_BOOL:
			return false
		if item.has("bounds"):
			if typeof(item["bounds"]) != TYPE_ARRAY or item["bounds"].size() != 4:
				return false
			for value in item["bounds"]:
				if not _valid_number(value):
					return false
		for key in ["material", "texture"]:
			if item.has(key) and typeof(item[key]) != TYPE_DICTIONARY:
				return false
			var resource: Dictionary = item.get(key, {})
			if resource.has("shader") and typeof(resource["shader"]) != TYPE_DICTIONARY:
				return false
	if typeof(context.get("counters")) != TYPE_DICTIONARY or not _valid_graphics_performance(context.get("performance")):
		return false
	for group in ["canvas", "visible_3d", "shadow_3d"]:
		if typeof(context["counters"].get(group)) != TYPE_DICTIONARY:
			return false
		for key in ["objects", "primitives", "draw_calls"]:
			var value: Variant = context["counters"][group].get(key)
			if not _valid_number(value) or value < 0:
				return false
	return true


func _valid_graphics_performance(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY or value.get("source") != "main_thread_process_interval" or value.get("unit") != "ms":
		return false
	if typeof(value.get("samples")) != TYPE_INT or value["samples"] < 0 or value["samples"] > 240:
		return false
	if value.get("gpu_status") not in ["disabled", "observed_positive", "availability_or_freshness_unverified"]:
		return false
	for key in ["p50_ms", "p95_ms", "max_ms", "gpu_ms", "render_cpu_ms"]:
		if value.get(key) != null and (not _valid_number(value[key]) or value[key] < 0):
			return false
	for key in ["intervals_ms", "observed_render_frames"]:
		if value.has(key):
			if typeof(value[key]) != TYPE_ARRAY or value[key].size() != value["samples"]:
				return false
			for number in value[key]:
				if not _valid_number(number) or number < 0:
					return false
	return true


func _update_viewport_choices(session_id: int, sample: Dictionary) -> void:
	var choice: OptionButton = _tabs[session_id]["viewport_choice"]
	var paths: Array[String] = []
	for viewport in sample.get("viewports", [sample["viewport"]]):
		paths.append(viewport["path"])
	var old: Array[String] = []
	for index in choice.item_count:
		old.append(choice.get_item_text(index))
	if paths == old:
		return
	var selected := choice.get_item_text(choice.selected) if choice.selected >= 0 else ""
	choice.clear()
	for path in paths:
		choice.add_item(path)
		if path == selected:
			choice.select(choice.item_count - 1)


func _request_ui_image(session_id: int) -> void:
	var view: Dictionary = _tabs[session_id]
	var choice: OptionButton = view["viewport_choice"]
	if choice.selected < 0:
		return
	var result := request_image(session_id, choice.get_item_text(choice.selected))
	if result["status"] == "pending":
		_ui_captures[session_id] = result["capture_id"]
		(view["preview_label"] as Label).text = "Capturando o viewport selecionado…"
	else:
		(view["preview_label"] as Label).text = str(result.get("error"))


func _fill_visual_tree(session_id: int, items: Array) -> void:
	var view: Dictionary = _tabs[session_id]
	var tree: Tree = view["visual_tree"]
	tree.clear()
	var root := tree.create_item()
	tree.hide_root = true
	for item in items:
		var row := tree.create_item(root)
		row.set_text(0, str(item.get("path", "?")))
		row.set_metadata(0, item)
		var texture: Dictionary = item.get("texture", {})
		var material: Dictionary = item.get("material", {})
		row.set_text(1, "%s · %s" % [texture.get("path", "sem textura"), material.get("shader", {}).get("path", material.get("type", "sem material"))])
		row.set_tooltip_text(1, JSON.stringify({"texture": texture, "material": material}))
		row.set_text(2, str(item.get("bounds_status", "?")))
	var context: Dictionary = _preview_images.get(session_id, {}).get("frame_context", {})
	var canvas: Dictionary = context.get("counters", {}).get("canvas", {})
	var timing: Dictionary = context.get("performance", {})
	(view["graphics_label"] as Label).text = "Viewport: %s · frame observado: %s\nCanvas: %s chamadas · %s objetos · %s primitivas. Intervalo de frame p95: %s ms; GPU: %s ms (%s).\nPixels/contadores no mesmo frame: não comprovado. Duplo clique localiza o candidato na cena editada; ela pode diferir do runtime." % [context.get("viewport_path", "?"), context.get("observed_render_frame", "?"), canvas.get("draw_calls", "?"), canvas.get("objects", "?"), canvas.get("primitives", "?"), timing.get("p95_ms", "?"), timing.get("gpu_ms", "?"), timing.get("gpu_status", "?" )]


func _pick_image(event: InputEvent, session_id: int) -> void:
	if not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT or not _preview_images.has(session_id):
		return
	var rect: TextureRect = _tabs[session_id]["preview_texture"]
	if rect.texture == null:
		return
	var image_size := rect.texture.get_size()
	var factor := minf(rect.size.x / image_size.x, rect.size.y / image_size.y)
	if factor <= 0:
		return
	var pixel: Vector2 = (event.position - (rect.size - image_size * factor) * 0.5) / factor
	if not Rect2(Vector2.ZERO, image_size).has_point(pixel):
		return
	_fill_visual_tree(session_id, GraphicsProbe.candidates(_preview_images[session_id].get("frame_context", {}), pixel))


func _select_editor_candidate(session_id: int) -> void:
	var tree: Tree = _tabs[session_id]["visual_tree"]
	var row := tree.get_selected()
	var root := EditorInterface.get_edited_scene_root()
	if row == null or root == null or root.scene_file_path != _preview_images.get(session_id, {}).get("scene_path"):
		return
	var item: Dictionary = row.get_metadata(0)
	var path: String = item.get("path", "")
	if path.is_empty() or path.begins_with("/") or path.contains(":") or ".." in path.split("/"):
		return
	var node := root.get_node_or_null(NodePath(path))
	if node != null and node.get_class() == item.get("type") and (node == root or root.is_ancestor_of(node)):
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(node)
		EditorInterface.edit_node(node)
