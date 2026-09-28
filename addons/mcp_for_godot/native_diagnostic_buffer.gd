@tool
extends RefCounted

const SCHEMA_VERSION := 1
const MAX_EVENTS := 256
const MAX_MESSAGE_CHARS := 4096
const MAX_FILE_CHARS := 1024

var _sessions: Dictionary = {}


func start(session_id: int) -> void:
	var old: Dictionary = _sessions.get(session_id, {})
	_sessions[session_id] = {"generation": int(old.get("generation", 0)) + 1, "active": true, "events": [], "last_cursor": 0, "dropped": 0}


func stop(session_id: int) -> void:
	if _sessions.has(session_id):
		_sessions[session_id]["active"] = false


func append(session_id: int, diagnostic: Dictionary) -> bool:
	if not _sessions.has(session_id):
		return false
	var state: Dictionary = _sessions[session_id]
	if not state["active"] or diagnostic.get("schema_version") != SCHEMA_VERSION or diagnostic.get("session_id") != session_id or diagnostic.get("run_generation") != state["generation"]:
		return false
	var cursor = diagnostic.get("cursor")
	if typeof(cursor) != TYPE_INT or cursor <= int(state["last_cursor"]):
		return false
	var kind = diagnostic.get("kind")
	var severity = diagnostic.get("severity")
	var file = diagnostic.get("file")
	var line = diagnostic.get("line")
	var message = diagnostic.get("message")
	if kind not in ["error", "output", "dropped"] or severity not in ["error", "warning", "info"] or typeof(file) != TYPE_STRING or typeof(line) != TYPE_INT or typeof(message) != TYPE_STRING:
		return false
	var safe := {"schema_version": SCHEMA_VERSION, "session_id": session_id, "run_generation": state["generation"], "cursor": cursor, "kind": kind, "severity": severity, "file": file.left(MAX_FILE_CHARS), "line": line, "message": message.left(MAX_MESSAGE_CHARS), "truncated": bool(diagnostic.get("truncated", false)) or file.length() > MAX_FILE_CHARS or message.length() > MAX_MESSAGE_CHARS}
	if typeof(diagnostic.get("source_file")) == TYPE_STRING and typeof(diagnostic.get("source_line")) == TYPE_INT:
		safe["source_file"] = str(diagnostic["source_file"]).left(MAX_FILE_CHARS)
		safe["source_line"] = diagnostic["source_line"]
	if kind == "dropped":
		var count = diagnostic.get("dropped_count")
		if typeof(count) != TYPE_INT or count < 1:
			return false
		safe["dropped_count"] = count
	state["last_cursor"] = cursor
	var events: Array = state["events"]
	events.append(safe)
	if events.size() > MAX_EVENTS:
		events.pop_front()
		state["dropped"] = int(state["dropped"]) + 1
	return true


func read(session_id: int, generation: int = -1, after_cursor: int = 0, limit: int = 40) -> Dictionary:
	if limit < 1 or limit > 100 or after_cursor < 0:
		return {"status": "unavailable", "error": {"code": "invalid_query"}}
	if not _sessions.has(session_id):
		return {"status": "unavailable", "error": {"code": "session_unknown"}}
	var state: Dictionary = _sessions[session_id]
	if generation != -1 and generation != state["generation"]:
		return {"status": "unavailable", "error": {"code": "session_changed"}, "session_id": session_id, "run_generation": state["generation"]}
	if after_cursor > int(state["last_cursor"]):
		return {"status": "unavailable", "error": {"code": "invalid_cursor"}, "session_id": session_id, "run_generation": state["generation"], "last_cursor": state["last_cursor"]}
	var events: Array = state["events"]
	var first_cursor := int(state["last_cursor"]) + 1 if events.is_empty() else int(events[0]["cursor"])
	var selected: Array = []
	for event in events:
		if int(event["cursor"]) > after_cursor:
			selected.append(event.duplicate(true))
			if selected.size() == limit:
				break
	return {"status": "ok", "schema_version": SCHEMA_VERSION, "origin": "editor_native_debugger", "session_id": session_id, "run_generation": state["generation"], "active": state["active"], "events": selected, "last_cursor": state["last_cursor"], "first_retained_cursor": first_cursor, "dropped_retention_count": state["dropped"], "cursor_gap": after_cursor < first_cursor - 1, "has_more": not selected.is_empty() and int(selected.back()["cursor"]) < int(state["last_cursor"])}
