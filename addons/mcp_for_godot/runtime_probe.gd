extends Node

# Coletor opt-in de uma cena de teste. So envia amostras a uma sessao de debug ativa.
const SCHEMA_VERSION := 1
const MAX_NODES := 300
const MAX_VIEWPORTS := 8
const SAMPLE_INTERVAL_USEC := 1_000_000
const IMAGE_MIN_INTERVAL_USEC := 1_000_000
const MAX_IMAGE_EDGE := 2048
const MAX_IMAGE_BYTES := 262144
const GraphicsProbe = preload("res://addons/mcp_for_godot/graphics_probe.gd")
# Texto de UI pode conter dados privados. A prova autoriza apenas o placar.
const TEXT_NODE_PATHS := ["ScoreLabel", "HUD/ScoreLabel"]

var _run_id := ""
var _sample_seq := 0
var _previous_send_call_usec := 0
var _previous_ack_roundtrip_usec := 0
var _previous_ack_sample_seq := 0
var _last_sample_usec := 0
var _pending_seq := 0
var _pending_sent_tick := 0
var _skipped_intervals := 0
var _skipped_total := 0
var _status_sent_for_seq := 0
var _owns_ack_capture := false
var _owns_image_capture := false
var _owns_input_capture := false
var _input_action := ""
var _input_command_id := ""
var _input_deadline_usec := 0
var _image_capture_id := ""
var _image_capture_scene_path := ""
var _image_viewport_path := ""
var _image_viewport_id := 0
var _image_scene_id := 0
var _image_context: Dictionary = {}
var _image_stage := "idle"
var _image_started_usec := 0
var _frame_intervals: Array[float] = []
var _frame_render_ids: Array[int] = []
var _frame_interval_cursor := 0
var _last_frame_tick := 0
var _last_render_frame := -1
var _last_render_change_usec := 0
var _gpu_measurement := false
var _measured_viewports: Dictionary = {}
var _image_capture_frame := 0
var _image_capture_width := 0
var _image_capture_height := 0
var _image_capture_readback_usec := 0
var _image_last_request_usec := 0
var _image_thread: Thread
var _project_fingerprint := ""
var _structure_dirty := true
var _cached_scene_id := 0
var _structure_generation := 0
var _cached_nodes: Array[Dictionary] = []
var _cached_node_by_id: Dictionary = {}
var _cached_subviewports: Array[Dictionary] = []
var _cached_nodes_truncated := false
var _cached_viewports_truncated := false


func _ready() -> void:
	_run_id = "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_last_sample_usec = Time.get_ticks_usec()
	_project_fingerprint = ProjectSettings.globalize_path("res://").sha256_text()
	_gpu_measurement = bool(ProjectSettings.get_setting("mcp_for_godot/measure_gpu", false))
	if EngineDebugger.has_capture("mcp_for_godot_ack"):
		set_process(false)
		push_warning("MCP_FOR_GODOT_DUPLICATE_COLLECTOR: apenas um coletor por processo de jogo.")
		return
	EngineDebugger.register_message_capture("mcp_for_godot_ack", _capture_ack)
	_owns_ack_capture = true
	if EngineDebugger.has_capture("mcp_for_godot_capture"):
		push_warning("MCP_FOR_GODOT_IMAGE_CAPTURE_UNAVAILABLE: outro coletor registrou o canal de imagem.")
	else:
		EngineDebugger.register_message_capture("mcp_for_godot_capture", _capture_image_request)
		_owns_image_capture = true
	if not EngineDebugger.has_capture("mcp_for_godot_input"):
		EngineDebugger.register_message_capture("mcp_for_godot_input", _capture_input_request)
		_owns_input_capture = true
	get_tree().node_added.connect(_mark_structure_dirty)
	get_tree().node_removed.connect(_mark_structure_dirty)


func _exit_tree() -> void:
	if _owns_ack_capture and EngineDebugger.has_capture("mcp_for_godot_ack"):
		EngineDebugger.unregister_message_capture("mcp_for_godot_ack")
	if _owns_image_capture and EngineDebugger.has_capture("mcp_for_godot_capture"):
		EngineDebugger.unregister_message_capture("mcp_for_godot_capture")
	_release_input("collector_stopped")
	if _owns_input_capture and EngineDebugger.has_capture("mcp_for_godot_input"):
		EngineDebugger.unregister_message_capture("mcp_for_godot_input")
	if _image_thread != null:
		_image_thread.wait_to_finish()
		_image_thread = null


func _capture_ack(message: String, data: Array) -> bool:
	if message != "sample":
		return false
	if data.size() == 2 and typeof(data[0]) == TYPE_STRING and typeof(data[1]) == TYPE_INT:
		if data[0] == _run_id and data[1] == _pending_seq:
			if _pending_sent_tick > 0:
				_previous_ack_sample_seq = _pending_seq
				_previous_ack_roundtrip_usec = maxi(0, Time.get_ticks_usec() - _pending_sent_tick)
			_pending_sent_tick = 0
			_pending_seq = 0
	return true


func _capture_input_request(message: String, data: Array) -> bool:
	if message != "press":
		return false
	if data.size() != 5 or typeof(data[0]) != TYPE_STRING or typeof(data[1]) != TYPE_STRING or typeof(data[2]) != TYPE_STRING or typeof(data[3]) != TYPE_STRING or typeof(data[4]) != TYPE_INT:
		return true
	var run_id: String = data[0]
	var command_id: String = data[1]
	var scene_path: String = data[2]
	var action: String = data[3]
	var duration_ms: int = data[4]
	if command_id.length() != 32 or not command_id.is_valid_hex_number():
		return true
	var scene := get_tree().current_scene
	if run_id != _run_id or scene == null or scene.scene_file_path != scene_path or not EngineDebugger.is_active():
		_send_input_result(command_id, action, "rejected", "session_changed")
		return true
	var allowed = ProjectSettings.get_setting("mcp_for_godot/allowed_input_actions", PackedStringArray())
	if typeof(allowed) != TYPE_PACKED_STRING_ARRAY or allowed.size() > 16 or not action in allowed or not InputMap.has_action(action) or action.is_empty() or action.length() > 64:
		_send_input_result(command_id, action, "rejected", "action_not_allowed")
		return true
	if duration_ms < 1 or duration_ms > 1000:
		_send_input_result(command_id, action, "rejected", "invalid_duration")
		return true
	if not _input_action.is_empty():
		_send_input_result(command_id, action, "rejected", "input_busy")
		return true
	_input_action = action
	_input_command_id = command_id
	_input_deadline_usec = 0
	_press_input_next_frame(command_id, duration_ms)
	return true


func _press_input_next_frame(command_id: String, duration_ms: int) -> void:
	await get_tree().process_frame
	if _input_command_id != command_id:
		return
	if not EngineDebugger.is_active():
		_release_input("debugger_disconnected")
		return
	Input.action_press(_input_action)
	_input_deadline_usec = Time.get_ticks_usec() + duration_ms * 1000
	_send_input_result(command_id, _input_action, "pressed", "")


func _release_input(reason: String = "") -> void:
	if _input_action.is_empty():
		return
	Input.action_release(_input_action)
	_send_input_result(_input_command_id, _input_action, "released", reason)
	_input_action = ""
	_input_command_id = ""
	_input_deadline_usec = 0


func _send_input_result(command_id: String, action: String, status: String, code: String) -> void:
	if EngineDebugger.is_active():
		EngineDebugger.send_message("mcp_for_godot:input_result", [{"run_id": _run_id, "command_id": command_id, "action": action, "status": status, "code": code, "scene_path": get_tree().current_scene.scene_file_path if get_tree().current_scene != null else "", "ticks_usec": Time.get_ticks_usec()}])


func _capture_image_request(message: String, data: Array) -> bool:
	if message != "request":
		return false
	if data.size() not in [2, 3] or typeof(data[0]) != TYPE_STRING or typeof(data[1]) != TYPE_STRING:
		return true
	if data.size() == 3 and (typeof(data[2]) != TYPE_STRING or data[2].length() > 512):
		return true
	var run_id: String = data[0]
	var capture_id: String = data[1]
	if run_id != _run_id or capture_id.length() != 32 or not capture_id.is_valid_hex_number():
		return true
	if _image_capture_id != "":
		_send_image_result(capture_id, "capture_busy")
		return true
	var now := Time.get_ticks_usec()
	if _image_last_request_usec > 0 and now - _image_last_request_usec < IMAGE_MIN_INTERVAL_USEC:
		_send_image_result(capture_id, "rate_limited")
		return true
	_image_last_request_usec = now
	var scene := get_tree().current_scene
	if not EngineDebugger.is_active() or scene == null or scene.scene_file_path.is_empty():
		_send_image_result(capture_id, "scene_unavailable")
		return true
	_image_capture_id = capture_id
	_image_stage = "waiting_frame"
	_image_started_usec = now
	_image_capture_scene_path = scene.scene_file_path
	_image_scene_id = scene.get_instance_id()
	_image_viewport_path = str(data[2]) if data.size() == 3 else ""
	var selected := _selected_viewport(scene, _image_viewport_path)
	if selected == null:
		_send_image_result(capture_id, "viewport_unavailable")
		_image_capture_id = ""
		return true
	_image_viewport_id = selected.get_instance_id()
	_capture_image_after_draw.call_deferred(capture_id)
	return true


func _capture_image_after_draw(capture_id: String) -> void:
	await RenderingServer.frame_post_draw
	if _image_capture_id != capture_id:
		return
	var scene := get_tree().current_scene
	if not EngineDebugger.is_active() or scene == null or scene.scene_file_path != _image_capture_scene_path or scene.get_instance_id() != _image_scene_id:
		_send_image_result(capture_id, "scene_changed")
		_image_capture_id = ""
		return
	var viewport := _selected_viewport(scene, _image_viewport_path)
	if viewport == null or viewport.get_instance_id() != _image_viewport_id:
		_send_image_result(capture_id, "viewport_unavailable")
		_image_capture_id = ""
		return
	if viewport is SubViewport and viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		_send_image_result(capture_id, "viewport_freshness_unverified")
		_image_capture_id = ""
		return
	var size := viewport.get_visible_rect().size
	if size.x < 1 or size.y < 1 or size.x > MAX_IMAGE_EDGE or size.y > MAX_IMAGE_EDGE:
		_send_image_result(capture_id, "image_dimensions_exceeded")
		_image_capture_id = ""
		return
	var began := Time.get_ticks_usec()
	_image_stage = "readback"
	var image := viewport.get_texture().get_image()
	_image_capture_readback_usec = Time.get_ticks_usec() - began
	if image == null or image.is_empty():
		_send_image_result(capture_id, "readback_failed")
		_image_capture_id = ""
		return
	_image_capture_width = image.get_width()
	_image_capture_height = image.get_height()
	_image_capture_frame = Engine.get_frames_drawn()
	_image_context = GraphicsProbe.capture_context(scene, viewport, str(viewport.get_path()) if _image_viewport_path.is_empty() else _image_viewport_path)
	_image_context["performance"] = _graphics_performance(viewport)
	if _image_capture_width < 1 or _image_capture_height < 1 or _image_capture_width > MAX_IMAGE_EDGE or _image_capture_height > MAX_IMAGE_EDGE:
		_send_image_result(capture_id, "image_dimensions_exceeded")
		_image_capture_id = ""
		return
	_image_thread = Thread.new()
	_image_stage = "encoding"
	var started: Error = _image_thread.start(_encode_capture_png.bind(image))
	if started != OK:
		_image_thread = null
		_send_image_result(capture_id, "encoder_unavailable")
		_image_capture_id = ""


func _encode_capture_png(image: Image) -> Dictionary:
	var began := Time.get_ticks_usec()
	var bytes := image.save_png_to_buffer()
	return {"bytes": bytes, "encode_usec": Time.get_ticks_usec() - began}


func _poll_image_capture() -> void:
	if _image_thread == null or _image_thread.is_alive():
		return
	var encoded: Dictionary = _image_thread.wait_to_finish()
	_image_thread = null
	var scene := get_tree().current_scene
	if scene == null or scene.get_instance_id() != _image_scene_id:
		_send_image_result(_image_capture_id, "scene_changed")
		_image_capture_id = ""
		return
	var bytes: PackedByteArray = encoded["bytes"]
	if bytes.is_empty():
		_send_image_result(_image_capture_id, "png_encode_failed")
	elif bytes.size() > MAX_IMAGE_BYTES:
		_send_image_result(_image_capture_id, "image_bytes_exceeded")
	else:
		_send_image_result(_image_capture_id, "", bytes, int(encoded["encode_usec"]))
	_image_capture_id = ""


func _send_image_result(capture_id: String, code: String, bytes: PackedByteArray = PackedByteArray(), encode_usec: int = 0) -> void:
	if not EngineDebugger.is_active():
		return
	var result := {"schema_version": SCHEMA_VERSION, "project_fingerprint": _project_fingerprint, "run_id": _run_id, "capture_id": capture_id, "status": "error" if code != "" else "ok", "code": code}
	if code == "":
		result.merge({"scene_path": _image_capture_scene_path, "render_frame": _image_capture_frame, "width": _image_capture_width, "height": _image_capture_height, "readback_usec": _image_capture_readback_usec, "encode_usec": encode_usec, "png": bytes, "frame_context": _image_context})
	EngineDebugger.send_message("mcp_for_godot:image", [result])
	if capture_id == _image_capture_id:
		_image_stage = "idle"


func _mark_structure_dirty(_node: Node) -> void:
	_structure_dirty = true


func _mark_rename_dirty() -> void:
	_structure_dirty = true


func _mark_node_dirty(node: Node) -> void:
	var entry: Dictionary = _cached_node_by_id.get(node.get_instance_id(), {})
	if not entry.is_empty():
		entry["dirty"] = true


func _process(_delta: float) -> void:
	_poll_image_capture()
	if not _input_action.is_empty() and (not EngineDebugger.is_active() or (_input_deadline_usec > 0 and Time.get_ticks_usec() >= _input_deadline_usec)):
		_release_input("debugger_disconnected" if not EngineDebugger.is_active() else "")
	if not EngineDebugger.is_active():
		_last_frame_tick = 0
		_pending_seq = 0
		_pending_sent_tick = 0
		_status_sent_for_seq = 0
		return
	if Engine.get_frames_drawn() < 2:
		return
	var now := Time.get_ticks_usec()
	if not _image_capture_id.is_empty() and _image_stage == "waiting_frame" and now - _image_started_usec > 8_000_000:
		_send_image_result(_image_capture_id, "frame_not_rendered")
		_image_capture_id = ""
	if _last_frame_tick > 0:
		var interval := float(now - _last_frame_tick) / 1000.0
		if _frame_intervals.size() < 240:
			_frame_intervals.append(interval)
			_frame_render_ids.append(Engine.get_frames_drawn())
		else:
			_frame_intervals[_frame_interval_cursor] = interval
			_frame_render_ids[_frame_interval_cursor] = Engine.get_frames_drawn()
			_frame_interval_cursor = (_frame_interval_cursor + 1) % 240
	_last_frame_tick = now
	if Engine.get_frames_drawn() != _last_render_frame:
		_last_render_frame = Engine.get_frames_drawn()
		_last_render_change_usec = now
	if now - _last_sample_usec < SAMPLE_INTERVAL_USEC:
		return
	_last_sample_usec = now
	if _pending_seq != 0:
		_skipped_intervals += 1
		_skipped_total += 1
		if _status_sent_for_seq != _pending_seq:
			EngineDebugger.send_message("mcp_for_godot:status", [{
				"schema_version": SCHEMA_VERSION,
				"project_fingerprint": _project_fingerprint,
				"run_id": _run_id,
				"pending_seq": _pending_seq,
				"skipped_intervals": _skipped_intervals,
				"skipped_total": _skipped_total,
				"code": "backpressure"
			}])
			_status_sent_for_seq = _pending_seq
		return
	var scene := get_tree().current_scene
	if scene == null or scene.scene_file_path.is_empty():
		return
	var viewport := scene.get_viewport()
	if viewport == null:
		return
	var started := Time.get_ticks_usec()
	_enable_gpu_measurement(viewport)
	if _needs_structure_refresh(scene):
		_refresh_structure_cache(scene)
	var nodes := _sample_cached_nodes()
	var nodes_done := Time.get_ticks_usec()
	var primary_viewport := _viewport_info(viewport, str(viewport.get_path()), "root")
	var viewports: Array[Dictionary] = [primary_viewport.duplicate(true)]
	for entry in _cached_subviewports:
		viewports.append(_viewport_info(entry["node"], entry["path"], "subviewport"))
	var viewports_done := Time.get_ticks_usec()
	_sample_seq += 1
	var sample := {
		"schema_version": SCHEMA_VERSION,
		"origin": "runtime",
		"project_fingerprint": _project_fingerprint,
		"run_id": _run_id,
		"sample_seq": _sample_seq,
		# O tempo do envio so pode ser publicado na amostra seguinte.
		"previous_send_sample_seq": _sample_seq - 1,
		"previous_send_call_usec": _previous_send_call_usec,
		"backpressure_skipped_intervals": _skipped_intervals,
		"backpressure_skipped_total": _skipped_total,
		"scene_path": scene.scene_file_path,
		"sample_ticks_usec": started,
		"sample_utc": Time.get_datetime_string_from_system(true, true),
		"process_frame": Engine.get_process_frames(),
		"render_frame": Engine.get_frames_drawn(),
		"frame_alignment": "latest_available",
		"backend": {
			"method": RenderingServer.get_current_rendering_method(),
			"driver": RenderingServer.get_current_rendering_driver_name(),
			"gpu": RenderingServer.get_video_adapter_name()
		},
		"viewport": primary_viewport,
		"viewports": viewports,
		"viewports_truncated": _cached_viewports_truncated,
		"performance": {
			"fps": _metric(Performance.get_monitor(Performance.TIME_FPS), "Performance.get_monitor(TIME_FPS)", "process", "fps"),
			"total_objects": _metric(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), "Performance.get_monitor(RENDER_TOTAL_OBJECTS_IN_FRAME)", "process"),
			"total_primitives": _metric(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), "Performance.get_monitor(RENDER_TOTAL_PRIMITIVES_IN_FRAME)", "process"),
			"total_draw_calls": _metric(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "Performance.get_monitor(RENDER_TOTAL_DRAW_CALLS_IN_FRAME)", "process")
		},
		"nodes": nodes,
		"nodes_truncated": _cached_nodes_truncated,
		"structure_generation": _structure_generation,
		"errors": []
	}
	sample["graphics_performance"] = _graphics_performance(viewport)
	sample["subsystems"] = _subsystems(scene)
	sample["image_capture_state"] = {"stage": _image_stage, "capture_id": _image_capture_id, "elapsed_ms": int((Time.get_ticks_usec() - _image_started_usec) / 1000) if not _image_capture_id.is_empty() else 0}
	var package_done := Time.get_ticks_usec()
	if _previous_ack_sample_seq > 0 and _previous_ack_sample_seq == _sample_seq - 1:
		sample["previous_ack_sample_seq"] = _previous_ack_sample_seq
		sample["previous_ack_roundtrip_usec"] = _previous_ack_roundtrip_usec
	sample["collect_phases_usec"] = {"nodes": nodes_done - started, "viewports": viewports_done - nodes_done, "package": package_done - viewports_done}
	sample["collect_usec"] = Time.get_ticks_usec() - started
	_pending_seq = _sample_seq
	_skipped_intervals = 0
	_status_sent_for_seq = 0
	var send_started := Time.get_ticks_usec()
	_pending_sent_tick = send_started
	EngineDebugger.send_message("mcp_for_godot:snapshot", [sample])
	_previous_send_call_usec = Time.get_ticks_usec() - send_started


func _metric(value: float, source: String, scope: String, unit: String = "count") -> Dictionary:
	return {"value": value, "source": source, "scope": scope, "unit": unit, "status": "ok"}


func _bounded_metric(value: float, source: String, scope: String, unit: String = "count") -> Dictionary:
	if not is_finite(value) or value < 0.0 or value > 1000000000.0:
		return {"value": null, "source": source, "scope": scope, "unit": unit, "status": "unavailable", "reason": "negative_non_finite_or_out_of_range"}
	return _metric(value, source, scope, unit)


func _monitor_metric(value: float, source: String, scope: String, unit: String = "count") -> Dictionary:
	var result := _bounded_metric(value, source, scope, unit)
	if result.status == "ok" and value == 0.0:
		# Performance não publica bit de suporte: zero pode ser valor real ou backend ausente.
		result["status"] = "unverified_zero"
		result["reason"] = "public_monitor_has_no_support_flag"
	return result


func _subsystems(scene: Node) -> Dictionary:
	# Todas as leituras são APIs públicas; contadores são do processo, não só da cena.
	var physics_2d := {
		"active_objects": _monitor_metric(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS), "Performance.PHYSICS_2D_ACTIVE_OBJECTS", "process"),
		"collision_pairs": _monitor_metric(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS), "Performance.PHYSICS_2D_COLLISION_PAIRS", "process"),
		"islands": _monitor_metric(Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT), "Performance.PHYSICS_2D_ISLAND_COUNT", "process")
	}
	var physics_3d := {
		"active_objects": _monitor_metric(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), "Performance.PHYSICS_3D_ACTIVE_OBJECTS", "process"),
		"collision_pairs": _monitor_metric(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS), "Performance.PHYSICS_3D_COLLISION_PAIRS", "process"),
		"islands": _monitor_metric(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT), "Performance.PHYSICS_3D_ISLAND_COUNT", "process")
	}
	var audio := {
		"bus_count": _bounded_metric(float(AudioServer.bus_count), "AudioServer.bus_count", "process"),
		"time_since_last_mix": _bounded_metric(AudioServer.get_time_since_last_mix(), "AudioServer.get_time_since_last_mix", "process", "s"),
		"time_to_next_mix": _bounded_metric(AudioServer.get_time_to_next_mix(), "AudioServer.get_time_to_next_mix", "process", "s"),
		"output_latency": _monitor_metric(Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY), "Performance.AUDIO_OUTPUT_LATENCY", "process", "s")
	}
	var multiplayer_api := scene.multiplayer
	var peer_present: bool = multiplayer_api.has_multiplayer_peer()
	var multiplayer := {
		"peer_present": {"value": peer_present, "source": "MultiplayerAPI.has_multiplayer_peer", "scope": "scene_multiplayer_api", "unit": "boolean", "status": "ok"},
		"connection_status": {"value": null, "source": "MultiplayerPeer.get_connection_status", "scope": "scene_multiplayer_api", "unit": "enum", "status": "unavailable", "reason": "no_peer"},
		"transport_kind": {"value": null, "source": "MultiplayerAPI.multiplayer_peer.get_class", "scope": "scene_multiplayer_api", "unit": "class", "status": "unavailable", "reason": "no_peer"},
		"remote_connection": {"value": null, "source": "public_peer_status_without_remote_handshake", "scope": "scene_multiplayer_api", "unit": "boolean", "status": "unavailable", "reason": "remote_connection_not_verified"}
	}
	if peer_present:
		var peer := multiplayer_api.multiplayer_peer
		if peer != null:
			multiplayer["connection_status"] = {"value": peer.get_connection_status(), "source": "MultiplayerPeer.get_connection_status", "scope": "scene_multiplayer_api", "unit": "enum", "status": "ok"}
			multiplayer["transport_kind"] = {"value": peer.get_class().left(64), "source": "MultiplayerAPI.multiplayer_peer.get_class", "scope": "scene_multiplayer_api", "unit": "class", "status": "ok"}
			if peer is OfflineMultiplayerPeer:
				multiplayer["remote_connection"]["reason"] = "offline_peer"
	var navigation_2d := {
		"active_maps": _monitor_metric(Performance.get_monitor(Performance.NAVIGATION_2D_ACTIVE_MAPS), "Performance.NAVIGATION_2D_ACTIVE_MAPS", "process"),
		"regions": _monitor_metric(Performance.get_monitor(Performance.NAVIGATION_2D_REGION_COUNT), "Performance.NAVIGATION_2D_REGION_COUNT", "process"),
		"agents": _monitor_metric(Performance.get_monitor(Performance.NAVIGATION_2D_AGENT_COUNT), "Performance.NAVIGATION_2D_AGENT_COUNT", "process")
	}
	var navigation_3d := {
		"active_maps": _monitor_metric(Performance.get_monitor(Performance.NAVIGATION_3D_ACTIVE_MAPS), "Performance.NAVIGATION_3D_ACTIVE_MAPS", "process"),
		"regions": _monitor_metric(Performance.get_monitor(Performance.NAVIGATION_3D_REGION_COUNT), "Performance.NAVIGATION_3D_REGION_COUNT", "process"),
		"agents": _monitor_metric(Performance.get_monitor(Performance.NAVIGATION_3D_AGENT_COUNT), "Performance.NAVIGATION_3D_AGENT_COUNT", "process")
	}
	var platform := {
		"os_name": {"value": OS.get_name().left(64), "source": "OS.get_name", "scope": "process", "unit": "name", "status": "ok"},
		"display_backend": {"value": DisplayServer.get_name().left(64), "source": "DisplayServer.get_name", "scope": "process", "unit": "name", "status": "ok"}
	}
	return {"physics_2d": physics_2d, "physics_3d": physics_3d, "audio": audio, "multiplayer": multiplayer, "navigation_2d": navigation_2d, "navigation_3d": navigation_3d, "platform": platform, "sampling_scope": "latest_public_process_values_not_causal_scene_attribution"}


func _canvas_metric(viewport: Viewport, info: int, label: String) -> Dictionary:
	var source := "Viewport.get_render_info(CANVAS, %s)" % label
	if viewport is SubViewport:
		var mode: int = (viewport as SubViewport).render_target_update_mode
		if mode == SubViewport.UPDATE_DISABLED:
			return {"value": null, "source": source, "scope": "viewport", "unit": "count", "status": "not_updating", "reason": "subviewport_update_disabled"}
		if mode != SubViewport.UPDATE_ALWAYS:
			var reason := "subviewport_update_once_no_public_frame_stamp" if mode == SubViewport.UPDATE_ONCE else "subviewport_conditional_update_no_public_frame_stamp"
			return {"value": null, "source": source, "scope": "viewport", "unit": "count", "status": "freshness_unverified", "reason": reason}
	return _metric(viewport.get_render_info(Viewport.RENDER_INFO_TYPE_CANVAS, info), source, "viewport")


func _viewport_info(viewport: Viewport, path: String, kind: String) -> Dictionary:
	_enable_gpu_measurement(viewport)
	var info := {
		"path": path,
		"kind": kind,
		"size": [viewport.get_visible_rect().size.x, viewport.get_visible_rect().size.y],
		"frame_alignment": "latest_available",
		"canvas_objects": _canvas_metric(viewport, Viewport.RENDER_INFO_OBJECTS_IN_FRAME, "OBJECTS"),
		"canvas_primitives": _canvas_metric(viewport, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME, "PRIMITIVES"),
		"canvas_draw_calls": _canvas_metric(viewport, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME, "DRAW_CALLS")
	}
	if viewport is SubViewport:
		info["update_mode"] = (viewport as SubViewport).render_target_update_mode
		if info["update_mode"] == SubViewport.UPDATE_DISABLED:
			info["frame_alignment"] = "not_rendering"
		elif info["update_mode"] != SubViewport.UPDATE_ALWAYS:
			info["frame_alignment"] = "unverified"
	return info


func _selected_viewport(scene: Node, path: String) -> Viewport:
	if path.is_empty() or path == str(scene.get_viewport().get_path()):
		return scene.get_viewport()
	if path.begins_with("/") or path.contains(":") or path.contains("\\") or ".." in path.split("/"):
		return null
	var node := scene.get_node_or_null(NodePath(path))
	if node is SubViewport and scene.is_ancestor_of(node):
		return node as Viewport
	return null


func _enable_gpu_measurement(viewport: Viewport) -> void:
	if _gpu_measurement and not _measured_viewports.has(viewport.get_instance_id()):
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
		_measured_viewports[viewport.get_instance_id()] = Engine.get_frames_drawn()


func _graphics_performance(viewport: Viewport) -> Dictionary:
	var intervals := _frame_intervals.duplicate()
	intervals.sort()
	var result := {"source": "main_thread_process_interval", "unit": "ms", "scope": "process", "samples": intervals.size(), "window_max_frames": 240, "cpu_gpu_time": false, "gpu_measurement_enabled": _gpu_measurement, "gpu_ms": null, "render_cpu_ms": null, "gpu_status": "disabled", "gpu_source": "RenderingServer.viewport_get_measured_render_time_gpu", "render_cpu_source": "RenderingServer.viewport_get_measured_render_time_cpu", "render_timing_scope": "selected_viewport", "timing_alignment": "latest_available_no_public_frame_stamp"}
	var ordered: Array = []
	var frame_ids: Array = []
	for index in _frame_intervals.size():
		var offset := (index + _frame_interval_cursor) % _frame_intervals.size()
		ordered.append(_frame_intervals[offset])
		frame_ids.append(_frame_render_ids[offset])
	result["intervals_ms"] = ordered
	result["observed_render_frames"] = frame_ids
	result["coverage"] = "rolling_process_window_may_omit_frames_between_samples"
	if not intervals.is_empty():
		result["p50_ms"] = intervals[int(ceil(intervals.size() * 0.5)) - 1]
		result["p95_ms"] = intervals[int(ceil(intervals.size() * 0.95)) - 1]
		result["max_ms"] = intervals[-1]
	if _gpu_measurement:
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
		var cpu := RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())
		var warm: bool = _measured_viewports.has(viewport.get_instance_id()) and Engine.get_frames_drawn() - int(_measured_viewports[viewport.get_instance_id()]) >= 2
		var recent_draw: bool = _last_render_change_usec > 0 and Time.get_ticks_usec() - _last_render_change_usec < 250_000
		var fresh: bool = recent_draw and (not viewport is SubViewport or viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
		result["gpu_status"] = "observed_positive" if warm and fresh and gpu > 0.0 else "availability_or_freshness_unverified"
		if result["gpu_status"] == "observed_positive":
			result["gpu_ms"] = gpu
			result["render_cpu_ms"] = cpu
	return result


func _needs_structure_refresh(scene: Node) -> bool:
	return _structure_dirty or _cached_scene_id != scene.get_instance_id()


func _refresh_structure_cache(scene: Node) -> void:
	_cached_nodes.clear()
	_cached_node_by_id.clear()
	_cached_subviewports.clear()
	_cached_nodes_truncated = _cache_nodes(scene, scene)
	_cached_viewports_truncated = _cache_subviewports(scene, scene)
	_cached_scene_id = scene.get_instance_id()
	_structure_generation += 1
	_structure_dirty = false


func _cache_nodes(root: Node, node: Node) -> bool:
	if _cached_nodes.size() >= MAX_NODES:
		return true
	var full_name := str(node.name)
	if not node.renamed.is_connected(_mark_rename_dirty):
		node.renamed.connect(_mark_rename_dirty)
	var path := str(root.get_path_to(node))
	var entry := {
		"node": node,
		"base": {"path": path, "name": full_name.left(80), "type": node.get_class(), "children": node.get_child_count()},
		"text_node": TEXT_NODE_PATHS.has(path),
		"dirty": false
	}
	entry["item"] = _project_cached_node(entry)
	_cached_nodes.append(entry)
	_cached_node_by_id[node.get_instance_id()] = entry
	if node is CanvasItem:
		var canvas := node as CanvasItem
		var callback := _mark_node_dirty.bind(node)
		if not canvas.item_rect_changed.is_connected(callback):
			canvas.item_rect_changed.connect(callback)
		if not canvas.visibility_changed.is_connected(callback):
			canvas.visibility_changed.connect(callback)
	for child in node.get_children():
		if _cache_nodes(root, child):
			return true
	return false


func _cache_subviewports(root: Node, node: Node) -> bool:
	if node is SubViewport:
		if _cached_subviewports.size() >= MAX_VIEWPORTS - 1:
			return true
		_cached_subviewports.append({"node": node, "path": str(root.get_path_to(node))})
	for child in node.get_children():
		if _cache_subviewports(root, child):
			return true
	return false


func _sample_cached_nodes() -> Array[Dictionary]:
	var nodes: Array[Dictionary] = []
	for entry in _cached_nodes:
		var node: Node = entry["node"]
		var text_changed := false
		if entry["text_node"]:
			var previous: Dictionary = entry["item"]
			if node is Label:
				text_changed = previous.get("text") != (node as Label).text.left(160)
			elif node is Button:
				text_changed = previous.get("text") != (node as Button).text.left(160)
		# Node3D nao emite os sinais de retangulo usados por CanvasItem.
		if entry["dirty"] or text_changed or node is Node3D:
			entry["item"] = _project_cached_node(entry)
			entry["dirty"] = false
		nodes.append(entry["item"])
	return nodes


func _project_cached_node(entry: Dictionary) -> Dictionary:
	var node: Node = entry["node"]
	var item: Dictionary = (entry["base"] as Dictionary).duplicate()
	if node is CanvasItem:
		item["visible"] = (node as CanvasItem).visible
		item["visible_in_tree"] = (node as CanvasItem).is_visible_in_tree()
	elif node is Node3D:
		var spatial := node as Node3D
		item["visible"] = spatial.visible
		item["visible_in_tree"] = spatial.is_visible_in_tree()
		var local := spatial.position
		var world := spatial.global_position
		var rotation := spatial.rotation_degrees
		var scale_value := spatial.scale
		var parts := [local.x, local.y, local.z, world.x, world.y, world.z, rotation.x, rotation.y, rotation.z, scale_value.x, scale_value.y, scale_value.z]
		var bounded := true
		for part in parts:
			if not is_finite(float(part)) or absf(float(part)) > 1000000.0:
				bounded = false
				break
		if bounded:
			item["position"] = [local.x, local.y, local.z]
			item["global_position"] = [world.x, world.y, world.z]
			item["rotation_degrees"] = [rotation.x, rotation.y, rotation.z]
			item["scale"] = [scale_value.x, scale_value.y, scale_value.z]
			item["transform_origin"] = "local_parent_and_global_world"
		else:
			item["transform_status"] = "non_finite_or_out_of_range"
	if node is Control:
		item["position"] = [(node as Control).position.x, (node as Control).position.y]
		item["size"] = [(node as Control).size.x, (node as Control).size.y]
	elif node is Node2D:
		item["position"] = [(node as Node2D).position.x, (node as Node2D).position.y]
	if entry["text_node"]:
		if node is Label:
			item["text"] = (node as Label).text.left(160)
		elif node is Button:
			item["text"] = (node as Button).text.left(160)
	return item
