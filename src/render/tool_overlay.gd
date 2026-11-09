class_name ToolOverlay
extends Node2D
## World-space marks of the layout tools that EditorOverlay doesn't draw: the
## symmetry mirror line. Purely presentational, never part of exports.

const C_LINE := Color(0.45, 0.85, 1.0, 0.95)

var line: Dictionary = {}       ## LayoutTools mirror line ({} = none)
var bounds := Rect2i()          ## clip area in tiles


func _ready() -> void:
	visibility_layer = Exporter.LAYER_OVERLAY


func show_line(new_line: Dictionary, area: Rect2i) -> void:
	if new_line == line and area == bounds:
		return
	line = new_line
	bounds = area
	queue_redraw()


func clear() -> void:
	if line.is_empty():
		return
	line = {}
	queue_redraw()


func _draw() -> void:
	if line.is_empty():
		return
	var seg := LayoutTools.line_segment(line, bounds)
	if seg.is_empty():
		return
	var a := Iso.grid_to_world(seg[0])
	var b := Iso.grid_to_world(seg[1])
	var zoom := maxf(get_viewport().get_canvas_transform().get_scale().x, 0.05)
	draw_dashed_line(a, b, Color(0, 0, 0, 0.45), 4.0 / zoom, 16.0 / zoom)
	draw_dashed_line(a, b, C_LINE, 2.0 / zoom, 16.0 / zoom)
