@tool
extends RefCounted

# Um atlas PNG pequeno, um TileMapLayer e uma acao de historico por chamada.
const MAX_PNG_BYTES := 1048576
const MAX_ATLAS_TILES := 16
const MAX_CELLS := 256


func _fail(code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": code, "error": message}


func _integer(value: Variant, low: int, high: int) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and floorf(float(value)) == float(value) and float(value) >= low and float(value) <= high


func _pair(value: Variant, low: int, high: int) -> Variant:
	if typeof(value) != TYPE_ARRAY or value.size() != 2 or not _integer(value[0], low, high) or not _integer(value[1], low, high):
		return null
	return Vector2i(int(value[0]), int(value[1]))


func _safe_png(path: Variant) -> bool:
	if typeof(path) != TYPE_STRING or not path.begins_with("res://") or path.length() > 512 or path.get_extension().to_lower() != "png" or path.contains("\\") or path.contains("::"):
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


func compose(plugin: EditorPlugin, args: Dictionary) -> Dictionary:
	var checked: Dictionary = plugin._checked_graph_root(args)
	if not checked.ok:
		return checked
	for key in args:
		if key not in ["expected_scene_path", "expected_graph_revision", "parent_path", "name", "texture_path", "texture_sha256", "tile_size", "atlas_tiles", "cells", "dry_run"]:
			return _fail("invalid_argument", "Campo fora do contrato TileMap.")
	if typeof(args.get("dry_run", false)) != TYPE_BOOL or typeof(args.get("parent_path")) != TYPE_STRING or typeof(args.get("name")) != TYPE_STRING or not plugin._valid_name(args.name):
		return _fail("invalid_target", "Informe pai, nome e dry_run válidos.")
	var root: Node = checked.root
	var parent: Node = plugin._find_node(root, args.parent_path)
	if parent is not Node2D or parent.has_node(NodePath(args.name)):
		return _fail("parent_conflict", "TileMapLayer exige pai Node2D e nome livre.")
	var path = args.get("texture_path")
	var expected_sha = args.get("texture_sha256")
	if not _safe_png(path) or typeof(expected_sha) != TYPE_STRING or expected_sha.length() != 64 or not expected_sha.is_valid_hex_number():
		return _fail("invalid_texture", "Informe PNG local com SHA-256.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 33 or file.get_length() > MAX_PNG_BYTES:
		return _fail("invalid_texture", "PNG ausente ou acima de 1 MiB.")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	if FileAccess.get_sha256(path) != expected_sha:
		return _fail("asset_conflict", "Textura mudou desde a leitura.")
	var signature := [137, 80, 78, 71, 13, 10, 26, 10]
	for index in range(8):
		if bytes[index] != signature[index]:
			return _fail("invalid_texture", "Assinatura PNG inválida.")
	if bytes[12] != 73 or bytes[13] != 72 or bytes[14] != 68 or bytes[15] != 82:
		return _fail("invalid_texture", "IHDR PNG ausente.")
	var declared_width: int = int(bytes[16]) * 16777216 + int(bytes[17]) * 65536 + int(bytes[18]) * 256 + int(bytes[19])
	var declared_height: int = int(bytes[20]) * 16777216 + int(bytes[21]) * 65536 + int(bytes[22]) * 256 + int(bytes[23])
	if declared_width < 8 or declared_height < 8 or declared_width > 512 or declared_height > 512:
		return _fail("invalid_texture", "Dimensões declaradas do PNG fora do limite.")
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.get_width() != declared_width or image.get_height() != declared_height:
		return _fail("invalid_texture", "PNG inválido ou fora dos limites de dimensão.")
	var tile_size = _pair(args.get("tile_size"), 8, 64)
	if tile_size == null or image.get_width() % tile_size.x != 0 or image.get_height() % tile_size.y != 0:
		return _fail("invalid_tile_size", "Tamanho de tile deve dividir a imagem.")
	var grid := Vector2i(image.get_width() / tile_size.x, image.get_height() / tile_size.y)
	var atlas_tiles = args.get("atlas_tiles")
	var cells = args.get("cells")
	if typeof(atlas_tiles) != TYPE_ARRAY or atlas_tiles.is_empty() or atlas_tiles.size() > MAX_ATLAS_TILES or typeof(cells) != TYPE_ARRAY or cells.is_empty() or cells.size() > MAX_CELLS:
		return _fail("invalid_tiles", "Informe 1 a 16 tiles e 1 a 256 células.")
	var tiles := {}
	var solid_tiles := 0
	for spec in atlas_tiles:
		if typeof(spec) != TYPE_DICTIONARY or spec.size() != 2 or not spec.has("atlas") or not spec.has("solid") or typeof(spec.solid) != TYPE_BOOL:
			return _fail("invalid_tiles", "Cada tile exige atlas e solid booleano, sem campos extras.")
		var coord = _pair(spec.atlas, 0, 63)
		if coord == null or coord.x >= grid.x or coord.y >= grid.y or tiles.has(coord):
			return _fail("invalid_tiles", "Coordenada do atlas inválida ou repetida.")
		tiles[coord] = spec.solid
		if spec.solid:
			solid_tiles += 1
	var planned_cells := {}
	for spec in cells:
		if typeof(spec) != TYPE_DICTIONARY or spec.size() != 2 or not spec.has("cell") or not spec.has("atlas"):
			return _fail("invalid_cells", "Cada célula exige cell e atlas, sem campos extras.")
		var cell = _pair(spec.cell, -64, 64)
		var atlas = _pair(spec.atlas, 0, 63)
		if cell == null or atlas == null or planned_cells.has(cell) or not tiles.has(atlas):
			return _fail("invalid_cells", "Célula repetida ou atlas não declarado.")
		planned_cells[cell] = atlas
	if not ResourceLoader.exists(path, "Texture2D"):
		return _fail("asset_not_imported", "PNG ainda não foi importado como Texture2D.")
	var planned_path: String = args.name if parent == root else str(root.get_path_to(parent)).path_join(args.name)
	if args.get("dry_run", false):
		return {"ok": true, "result": {"applied": false, "dry_run": true, "scene_path": root.scene_file_path, "revision_checked": checked.revision, "node_path": planned_path, "texture_sha256": expected_sha, "texture_load_pending": true, "grid": [grid.x, grid.y], "atlas_tile_count": tiles.size(), "solid_tile_count": solid_tiles, "cell_count": planned_cells.size(), "undo_available": false}}
	var texture := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	if texture == null or texture.get_size() != Vector2(grid * tile_size) or FileAccess.get_sha256(path) != expected_sha:
		return _fail("asset_conflict", "Textura importada inválida, desatualizada ou alterada durante a carga.")
	var tile_set := TileSet.new()
	tile_set.tile_size = tile_size
	if solid_tiles > 0:
		tile_set.add_physics_layer()
		tile_set.set_physics_layer_collision_layer(0, 1)
		tile_set.set_physics_layer_collision_mask(0, 1)
	var atlas_source := TileSetAtlasSource.new()
	atlas_source.texture = texture
	atlas_source.texture_region_size = tile_size
	if tile_set.add_source(atlas_source, 0) != 0:
		return _fail("tile_creation_failed", "TileSet recusou fonte atlas ID 0.")
	for coord in tiles:
		atlas_source.create_tile(coord)
		if tiles[coord]:
			var tile_data := atlas_source.get_tile_data(coord, 0)
			if tile_data == null:
				return _fail("tile_creation_failed", "Atlas recusou tile sólido.")
			tile_data.set_collision_polygons_count(0, 1)
			var half := Vector2(tile_size) / 2.0
			tile_data.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]))
	var layer := TileMapLayer.new()
	layer.name = args.name
	layer.tile_set = tile_set
	for cell in planned_cells:
		layer.set_cell(cell, 0, planned_cells[cell])
	var history := plugin.get_undo_redo()
	history.create_action("MCP: compor TileMapLayer %s" % args.name, UndoRedo.MERGE_DISABLE, root)
	history.add_do_method(parent, "add_child", layer)
	history.add_do_method(layer, "set_owner", root)
	history.add_do_reference(layer)
	history.add_undo_method(parent, "remove_child", layer)
	history.commit_action()
	return {"ok": true, "result": {"applied": true, "scene_path": root.scene_file_path, "revision_before": checked.revision, "reread_required": true, "node_path": planned_path, "texture_sha256": expected_sha, "grid": [grid.x, grid.y], "atlas_tile_count": tiles.size(), "solid_tile_count": solid_tiles, "cell_count": planned_cells.size(), "undo_available": true}}
