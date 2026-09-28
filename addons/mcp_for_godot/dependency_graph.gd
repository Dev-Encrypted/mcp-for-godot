@tool
extends RefCounted

# Projecao limitada da cena editada e das dependencias declaradas em disco.
# Nao executa scripts, nao carrega recursos e nao infere ResourceLoader.load dinamico.
const MAX_SCENE_NODES := 300
const MAX_RESOURCES := 128
const MAX_EDGES := 500
const MAX_UNKNOWN := 40
const MAX_OUTPUT_BYTES := 262144
const MAX_PATH_LENGTH := 512
const RESOURCE_PROPERTIES := ["script", "texture", "material", "theme", "font", "font_data", "shape", "mesh", "tile_set", "stream", "animation", "resource"]

var _nodes: Array[Dictionary] = []
var _resources: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _unknown: Array[Dictionary] = []
var _resource_seen: Dictionary = {}
var _resource_queue: Array[String] = []
var _truncated := {"scene_nodes": false, "resources": false, "edges": false, "unknown": false, "bytes": false}


func build(root: Node, scene_revision: String) -> Dictionary:
	var began := Time.get_ticks_usec()
	_nodes.clear()
	_resources.clear()
	_edges.clear()
	_unknown.clear()
	_resource_seen.clear()
	_resource_queue.clear()
	for key in _truncated:
		_truncated[key] = false
	var scene_path: String = root.scene_file_path
	_add_resource(scene_path)
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if _nodes.size() >= MAX_SCENE_NODES:
			_truncated["scene_nodes"] = true
			break
		var path := str(root.get_path_to(node))
		if path.length() > MAX_PATH_LENGTH:
			_add_unknown("node_path_too_long", path.left(120))
			continue
		var node_id := "node:" + path
		_nodes.append({"id": node_id, "path": path, "name": str(node.name), "type": node.get_class(), "source": "editor_edited_scene"})
		if node != root:
			var parent_path := str(root.get_path_to(node.get_parent()))
			_add_edge("node:" + parent_path, node_id, "contains", "Node.get_children", "editor_edited_scene")
			if not node.scene_file_path.is_empty():
				_link_resource(node_id, node.scene_file_path, "scene_instance", "Node.scene_file_path", "editor_edited_scene")
		_add_node_resources(node, node_id)
		_add_persistent_signals(root, node, node_id)
		for child in node.get_children():
			if child.owner == root:
				queue.append(child)
	while not _resource_queue.is_empty():
		var resource_path: String = _resource_queue.pop_front()
		if not FileAccess.file_exists(resource_path):
			continue
		for raw_dependency in ResourceLoader.get_dependencies(resource_path):
			var parsed := _parse_dependency(str(raw_dependency))
			if parsed["path"].is_empty():
				_add_unknown("unresolved_dependency", str(raw_dependency).left(120))
				continue
			_link_resource("resource:" + resource_path, parsed["path"], "declared_dependency", "ResourceLoader.get_dependencies", "on_disk", parsed["uid"])
	_prune_dangling_edges()
	var result := {"schema_version": 1, "origin": "editor_edited_and_declared_on_disk", "scene_path": scene_path, "scene_revision": scene_revision, "revision_scope": "graph_projection_without_resource_contents", "generated_utc": Time.get_datetime_string_from_system(true, true), "coverage": "owned_editor_nodes_and_declared_resource_dependencies", "dynamic_loads": "unobserved", "nodes": _nodes, "resources": _resources, "edges": _edges, "unknown": _unknown, "truncated": _truncated, "build_usec": Time.get_ticks_usec() - began}
	while JSON.stringify(result).to_utf8_buffer().size() > MAX_OUTPUT_BYTES - 128 and not _edges.is_empty():
		_edges.resize(maxi(0, _edges.size() - 32))
		_truncated["edges"] = true
		_truncated["bytes"] = true
	while JSON.stringify(result).to_utf8_buffer().size() > MAX_OUTPUT_BYTES - 128 and not _resources.is_empty():
		_resources.resize(maxi(0, _resources.size() - 16))
		_truncated["resources"] = true
		_truncated["bytes"] = true
	while JSON.stringify(result).to_utf8_buffer().size() > MAX_OUTPUT_BYTES - 128 and not _nodes.is_empty():
		_nodes.resize(maxi(0, _nodes.size() - 16))
		_truncated["scene_nodes"] = true
		_truncated["bytes"] = true
	result["revision"] = _revision(result)
	result["build_usec"] = Time.get_ticks_usec() - began
	return result


func _revision(result: Dictionary) -> String:
	var resource_items: Array[String] = []
	var edge_items: Array[String] = []
	var unknown_items: Array[String] = []
	for resource in _resources:
		resource_items.append(JSON.stringify(resource))
	for edge in _edges:
		edge_items.append(JSON.stringify(edge))
	for item in _unknown:
		unknown_items.append(JSON.stringify(item))
	resource_items.sort()
	edge_items.sort()
	unknown_items.sort()
	return JSON.stringify({"scene_path": result["scene_path"], "scene_revision": result["scene_revision"], "nodes": _nodes, "resources": resource_items, "edges": edge_items, "unknown": unknown_items, "truncated": _truncated}).sha256_text()


func _safe_path(path: String) -> bool:
	if not path.begins_with("res://") or path.length() > MAX_PATH_LENGTH or path.contains("\\"):
		return false
	var directory := DirAccess.open("res://")
	if directory == null:
		return false
	var current := "res://"
	for part in path.trim_prefix("res://").split("/"):
		if part in ["", ".", ".."] or part.contains(":"):
			return false
		current = current.path_join(part)
		if directory.is_link(current):
			return false
	return true


func _add_resource(path: String) -> void:
	if not _safe_path(path):
		_add_unknown("out_of_scope_resource", path.left(120))
		return
	if _resource_seen.has(path):
		return
	if _resources.size() >= MAX_RESOURCES:
		_truncated["resources"] = true
		return
	_resource_seen[path] = true
	var exists := FileAccess.file_exists(path)
	var uid := ResourceUID.path_to_uid(path) if exists else path
	_resources.append({"id": "resource:" + path, "path": path, "uid": uid if uid.begins_with("uid://") else null, "extension": path.get_extension().to_lower(), "type": null, "type_status": "unresolved_without_loading", "status": "available" if exists else "missing", "source": "ResourceLoader_and_FileAccess"})
	if exists:
		_resource_queue.append(path)
	else:
		_add_unknown("missing_resource", path)


func _link_resource(source_id: String, path: String, relation: String, api: String, scope: String, declared_uid: String = "") -> void:
	if not _safe_path(path):
		_add_unknown("out_of_scope_resource", path.left(120))
		return
	_add_resource(path)
	if not _resource_seen.has(path):
		return
	var details := {"from": source_id, "to": "resource:" + path, "relation": relation, "source": api, "scope": scope}
	if not declared_uid.is_empty():
		details["declared_uid"] = declared_uid
	_add_edge_dict(details)


func _add_edge(source_id: String, target_id: String, relation: String, api: String, scope: String) -> void:
	_add_edge_dict({"from": source_id, "to": target_id, "relation": relation, "source": api, "scope": scope})


func _add_edge_dict(edge: Dictionary) -> void:
	if _edges.size() >= MAX_EDGES:
		_truncated["edges"] = true
		return
	_edges.append(edge)


func _add_unknown(reason: String, detail: String) -> void:
	if _unknown.size() >= MAX_UNKNOWN:
		_truncated["unknown"] = true
		return
	_unknown.append({"reason": reason, "detail": detail})


func _prune_dangling_edges() -> void:
	var known := {}
	for node in _nodes:
		known[node["id"]] = true
	for resource in _resources:
		known[resource["id"]] = true
	var retained: Array[Dictionary] = []
	for edge in _edges:
		if known.has(edge["from"]) and known.has(edge["to"]):
			retained.append(edge)
		else:
			_truncated["edges"] = true
	_edges = retained


func _parse_dependency(raw: String) -> Dictionary:
	if not raw.contains("::"):
		return {"path": raw if _safe_path(raw) else "", "uid": ""}
	var uid := raw.get_slice("::", 0)
	var path := raw.get_slice("::", 2)
	if path.is_empty():
		path = raw.get_slice("::", 1)
	return {"path": path if _safe_path(path) else "", "uid": uid if uid.begins_with("uid://") else ""}


func _add_node_resources(node: Node, node_id: String) -> void:
	var available := {}
	for property_info in node.get_property_list():
		if int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE:
			available[str(property_info["name"])] = true
	for property_name in RESOURCE_PROPERTIES:
		if not available.has(property_name):
			continue
		var value: Variant = node.get(property_name)
		if value is Resource:
			var resource_path: String = value.resource_path
			if resource_path.begins_with("res://") and not resource_path.contains("::"):
				_link_resource(node_id, resource_path, "node_resource_property", "Object.get_property_list/Object.get", "editor_edited_scene")
			else:
				_add_unknown("embedded_or_external_resource", str(node_id + "." + property_name).left(120))


func _add_persistent_signals(root: Node, node: Node, node_id: String) -> void:
	for signal_info in node.get_signal_list():
		var signal_name: String = str(signal_info["name"])
		for connection in node.get_signal_connection_list(signal_name):
			if (int(connection.get("flags", 0)) & Object.CONNECT_PERSIST) == 0:
				continue
			var callable: Callable = connection["callable"]
			var target: Object = callable.get_object()
			if target is Node and (target == root or target.owner == root):
				var target_path := str(root.get_path_to(target))
				var edge := {"from": node_id, "to": "node:" + target_path, "relation": "persistent_signal", "signal": signal_name, "method": str(callable.get_method()), "source": "Object.get_signal_connection_list", "scope": "editor_edited_scene"}
				_add_edge_dict(edge)
			else:
				_add_unknown("signal_target_outside_scene", (node_id + "." + signal_name).left(120))
