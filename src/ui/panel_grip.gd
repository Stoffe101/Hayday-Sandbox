class_name PanelGrip
extends Control
## Thin drag handle on the inner edge of a side panel: drag to resize the
## panel, double-click to return to the automatic width. Only reports the
## pointer; main.gd owns the widths (and remembers them in the settings).

signal dragged(dx: float)
signal released
signal reset

var _dragging := false
var _hover := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Drag to resize · double-click for the automatic width"
	mouse_entered.connect(func():
		_hover = true
		queue_redraw())
	mouse_exited.connect(func():
		_hover = false
		queue_redraw())


func is_dragging() -> bool:
	return _dragging


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and e.double_click:
			_dragging = false
			reset.emit()
		elif e.pressed:
			_dragging = true
		elif _dragging:
			_dragging = false
			released.emit()
		queue_redraw()
		accept_event()
	elif e is InputEventMouseMotion and _dragging:
		dragged.emit(e.relative.x)
		accept_event()


func _draw() -> void:
	if not (_hover or _dragging):
		return
	var col := UiTheme.c("accent")
	col.a = 0.9 if _dragging else 0.55
	var h := minf(size.y * 0.5, 96.0)
	draw_rect(Rect2(size.x * 0.5 - 1.5, (size.y - h) * 0.5, 3.0, h), col)
