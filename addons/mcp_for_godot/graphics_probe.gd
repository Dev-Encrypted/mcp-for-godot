@tool
extends RefCounted

# Projeção pública, feita sob demanda no thread principal após frame_post_draw.
# Retângulos são candidatos geométricos: não representam teste de pixel/oclusão.
const MAX_ITEMS := 128
const MAX_VISITED := 300
const MAX_CONTEXT_BYTES := 98304


static func resource_info(resource: Resource) -> Dictionary:
	if resource == null:
		return {}
	var result := {"type": resource.get_class(), "path": resource.resource_path.left(512), "instance_id": str(resource.get_instance_id()), "identity_scope": "process_lifetime"}
	if resource is Texture2D:
		result["size"] = [resource.get_width(), resource.get_height()]
	if resource is ShaderMaterial:
		var shader: Shader = resource.shader
		if shader != null:
			result["shader"] = {"path": shader.resource_path.left(512), "code_sha256": shader.code.sha256_text(), "compile_status": "not_verified"}
	return result


static func visual_item(root: Node, node: CanvasItem) -> Dictionary:
	var item := {"path": str(root.get_path_to(node)).left(512), "type": node.get_class(), "visible_in_tree": node.is_visible_in_tree(), "z_index": node.z_index, "z_as_relative": node.z_as_relative, "material": resource_info(node.material), "use_parent_material": node.use_parent_material, "bounds_status": "unsupported_geometry", "occlusion": "unobserved", "source": "CanvasItem_public_state_after_draw"}
	var rect := Rect2()
	var supported := false
	if node is Control:
		rect = Rect2(Vector2.ZERO, node.size)
		supported = true
	elif node is Sprite2D:
		rect = node.get_rect()
		supported = true
	if node is Sprite2D or node is TextureRect:
		item["texture"] = resource_info(node.texture)
	if supported:
		var bounds: Rect2 = node.get_global_transform_with_canvas() * rect
		item["bounds"] = [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y]
		item["bounds_status"] = "axis_aligned_candidate_not_pixel_ownership"
	return item


static func capture_context(root: Node, viewport: Viewport, viewport_path: String) -> Dictionary:
	var began := Time.get_ticks_usec()
	var items: Array[Dictionary] = []
	var queue: Array[Node] = [root]
	var visited := 0
	while not queue.is_empty() and visited < MAX_VISITED and items.size() < MAX_ITEMS:
		var node: Node = queue.pop_front()
		visited += 1
		if node is CanvasItem and node.get_viewport() == viewport:
			items.append(visual_item(root, node))
		for child in node.get_children():
			queue.append(child)
	var counters := {}
	for entry in [["canvas", Viewport.RENDER_INFO_TYPE_CANVAS], ["visible_3d", Viewport.RENDER_INFO_TYPE_VISIBLE], ["shadow_3d", Viewport.RENDER_INFO_TYPE_SHADOW]]:
		counters[entry[0]] = {"objects": viewport.get_render_info(entry[1], Viewport.RENDER_INFO_OBJECTS_IN_FRAME), "primitives": viewport.get_render_info(entry[1], Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME), "draw_calls": viewport.get_render_info(entry[1], Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)}
	var result := {"schema_version": 1, "viewport_path": viewport_path, "observed_render_frame": Engine.get_frames_drawn(), "observed_ticks_usec": began, "source": "public_API_after_frame_post_draw", "pixel_metric_same_frame": "unproven", "counter_alignment": "latest_available_no_public_frame_stamp", "counter_scope": "selected_viewport", "counter_source": "Viewport.get_render_info", "counters": counters, "global_draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "global_source": "Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME", "items": items, "truncated": not queue.is_empty(), "draw_order": "unobserved", "internal_passes": "not_exposed", "native_runtime_errors": "not_collected"}
	while JSON.stringify(result).to_utf8_buffer().size() > MAX_CONTEXT_BYTES - 128 and not items.is_empty():
		items.pop_back()
		result["truncated"] = true
	result["collect_usec"] = Time.get_ticks_usec() - began
	return result


static func candidates(context: Dictionary, pixel: Vector2) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item in context.get("items", []):
		if not item.get("visible_in_tree", false) or not item.has("bounds"):
			continue
		var box: Array = item["bounds"]
		if Rect2(box[0], box[1], box[2], box[3]).has_point(pixel):
			result.append(item)
	return result
