class_name ToolDock
extends VBoxContainer
## Floating bottom dock: tool buttons, view toggles, zoom; plus a status line.

signal tool_selected(tool: String)
signal action(name: String)

const TOOLS := [
	["select", "mouse-pointer-2", "Select & move", "V"],
	["place", "paintbrush", "Place / paint", "B"],
	["erase", "eraser", "Erase (Shift-drag: area)", "E"],
	["pick", "pipette", "Eyedropper", "I"],
	["land", "map", "Land: lock / unlock plots", "M"],
	["annotate", "sticky-note", "Notes & zones", "N"],
	["pan", "hand", "Pan (or hold Space / middle mouse)", "H"],
]

var _btns: Dictionary = {}
var _zoom_lbl: Label
var _status: Label
var _grid_btn: Button
var _stats: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 8)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var pill := PanelContainer.new()
	pill.theme_type_variation = "Pill"
	center.add_child(pill)
	var h := UI.hbox(4)
	pill.add_child(h)
	var group := ButtonGroup.new()
	for t in TOOLS:
		var b := UI.icon_button(t[1], "%s  (%s)" % [t[2], t[3]], "Tool", 22)
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(44, 44)
		b.pressed.connect(func(): tool_selected.emit(t[0]))
		_btns[t[0]] = b
		h.add_child(b)
	h.add_child(VSeparator.new())
	_grid_btn = UI.icon_button("grid-3x3", "Grid (G)", "Tool", 20)
	_grid_btn.toggle_mode = true
	_grid_btn.button_pressed = true
	_grid_btn.custom_minimum_size = Vector2(40, 40)
	_grid_btn.pressed.connect(func(): action.emit("grid"))
	h.add_child(_grid_btn)
	var zo := UI.icon_button("zoom-out", "Zoom out (-)", "Ghost")
	zo.pressed.connect(func(): action.emit("zoom_out"))
	h.add_child(zo)
	_zoom_lbl = UI.label("100%", "Dim")
	_zoom_lbl.custom_minimum_size.x = 48
	_zoom_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h.add_child(_zoom_lbl)
	var zi := UI.icon_button("zoom-in", "Zoom in (+)", "Ghost")
	zi.pressed.connect(func(): action.emit("zoom_in"))
	h.add_child(zi)
	var fit := UI.icon_button("scan", "Fit farm (F / Home)", "Ghost")
	fit.pressed.connect(func(): action.emit("fit"))
	h.add_child(fit)
	var status_row := UI.hbox(12)
	status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status = UI.label("", "Faint")
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_status.add_theme_constant_override("shadow_offset_y", 1)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	status_row.add_child(_status)
	add_child(status_row)


func set_tool(t: String) -> void:
	if _btns.has(t):
		_btns[t].button_pressed = true


func set_zoom(z: float) -> void:
	_zoom_lbl.text = "%d%%" % roundi(z * 100.0)


func set_status(text: String) -> void:
	_status.text = text


func set_grid(on: bool) -> void:
	_grid_btn.button_pressed = on
