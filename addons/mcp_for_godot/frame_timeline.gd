@tool
extends Control

# Janela limitada dos intervalos do processo. Não representa tempos de GPU.
var intervals: Array = []
var ceiling_ms := 33.34


func set_intervals(values: Array) -> void:
	intervals = values.duplicate()
	ceiling_ms = 33.34
	for value in intervals:
		ceiling_ms = maxf(ceiling_ms, float(value))
	queue_redraw()


func _draw() -> void:
	var area := Rect2(Vector2(8, 8), Vector2(maxf(1, size.x - 16), maxf(1, size.y - 16)))
	draw_rect(area, Color("151e2b"))
	var budget_y := area.end.y - 16.667 / ceiling_ms * area.size.y
	draw_line(Vector2(area.position.x, budget_y), Vector2(area.end.x, budget_y), Color("c99a4a"), 1.0)
	if intervals.size() < 2:
		return
	var points := PackedVector2Array()
	for index in intervals.size():
		points.append(Vector2(area.position.x + float(index) / (intervals.size() - 1) * area.size.x, area.end.y - float(intervals[index]) / ceiling_ms * area.size.y))
	draw_polyline(points, Color("67c6ee"), 2.0, true)
