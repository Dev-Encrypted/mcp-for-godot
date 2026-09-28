@tool
extends RefCounted

# Para o formato de no emitido pelo coletor, calcula um teto seguro do JSON.
# Formatos diferentes preservam a verificacao exata; nenhum tamanho declarado
# pelo processo do jogo e usado para autorizar uma amostra.
# Godot 4.7.2 usa String::num() com casas decimais dependentes da magnitude.
# Valores fora da faixa abaixo retornam ao JSON exato (ex.: 1e-300).
const NUMBER_JSON_BYTES_UPPER_BOUND := 48
const MIN_FAST_FLOAT_MAGNITUDE := 1.0e-12
const MAX_FAST_FLOAT_MAGNITUDE := 1.0e12


static func checked_size(sample: Dictionary, limit_bytes: int) -> Dictionary:
	if typeof(sample.get("nodes")) != TYPE_ARRAY:
		return {"bytes": JSON.stringify(sample).to_utf8_buffer().size(), "method": "json_exact"}
	var header := sample.duplicate()
	var nodes: Array = header["nodes"]
	header["nodes"] = []
	var upper_bound := JSON.stringify(header).to_utf8_buffer().size()
	# Substituir [] por [nos...] nunca diminui os bytes do cabecalho.
	if upper_bound > limit_bytes:
		return {"bytes": upper_bound, "method": "header_lower_bound"}
	for node in nodes:
		var node_bound := _node_json_upper_bound(node)
		if node_bound < 0:
			return {"bytes": JSON.stringify(sample).to_utf8_buffer().size(), "method": "json_exact"}
		upper_bound += node_bound + 1 # Uma virgula extra tambem cobre o primeiro no.
		if upper_bound > limit_bytes:
			return {"bytes": JSON.stringify(sample).to_utf8_buffer().size(), "method": "json_exact"}
	return {"bytes": upper_bound, "method": "node_upper_bound"}


static func _json_string_bytes(value: String) -> int:
	if value.is_valid_ascii_identifier():
		return value.length() + 2
	return JSON.stringify(value).to_utf8_buffer().size()


static func _node_json_upper_bound(value: Variant) -> int:
	if typeof(value) != TYPE_DICTIONARY:
		return -1
	var node: Dictionary = value
	if typeof(node.get("path")) != TYPE_STRING or typeof(node.get("name")) != TYPE_STRING or typeof(node.get("type")) != TYPE_STRING:
		return -1
	if not _bounded_json_number(node.get("children")):
		return -1
	# Chaves ASCII fixas: aspas + dois-pontos + uma virgula por campo.
	var size := 2 + 8 + _json_string_bytes(node["path"]) + 8 + _json_string_bytes(node["name"]) + 8 + _json_string_bytes(node["type"]) + 12 + NUMBER_JSON_BYTES_UPPER_BOUND
	var expected_keys := 4
	if node.has("position"):
		expected_keys += 1
		if not _numeric_pair(node["position"]):
			return -1
		size += 12 + 3 + 2 * NUMBER_JSON_BYTES_UPPER_BOUND
	if node.has("size"):
		expected_keys += 1
		if not _numeric_pair(node["size"]):
			return -1
		size += 8 + 3 + 2 * NUMBER_JSON_BYTES_UPPER_BOUND
	if node.has("visible"):
		expected_keys += 1
		if typeof(node["visible"]) != TYPE_BOOL:
			return -1
		size += 11 + 5
	if node.has("visible_in_tree"):
		expected_keys += 1
		if typeof(node["visible_in_tree"]) != TYPE_BOOL:
			return -1
		size += 19 + 5
	if node.has("text"):
		expected_keys += 1
		if typeof(node["text"]) != TYPE_STRING:
			return -1
		size += 8 + _json_string_bytes(node["text"])
	# Quantidade + presenca das chaves conhecidas excluem campos adicionais.
	if node.size() != expected_keys:
		return -1
	return size


static func _numeric_pair(value: Variant) -> bool:
	return typeof(value) == TYPE_ARRAY and value.size() == 2 and _bounded_json_number(value[0]) and _bounded_json_number(value[1])


static func _bounded_json_number(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true # int64 decimal: ate 20 bytes, incluindo sinal.
	if typeof(value) != TYPE_FLOAT:
		return false
	var number: float = value
	if is_nan(number) or is_inf(number):
		return false
	var magnitude := absf(number)
	return magnitude == 0.0 or (magnitude >= MIN_FAST_FLOAT_MAGNITUDE and magnitude <= MAX_FAST_FLOAT_MAGNITUDE)
