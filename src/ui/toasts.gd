class_name Toasts
extends VBoxContainer
## Non-intrusive notifications (bottom-right, auto-dismiss, max 4).


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation", 8)


func show_toast(text: String, kind: String = "info") -> void:
	if get_child_count() >= 4:
		get_child(0).queue_free()
	var p := PanelContainer.new()
	p.theme_type_variation = "Toast"
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var h := UI.hbox(10)
	p.add_child(h)
	var icon := "info"
	var col := UiTheme.c("info")
	match kind:
		"warn":
			icon = "circle-x"
			col = UiTheme.c("warn")
		"error":
			icon = "circle-x"
			col = UiTheme.c("danger")
		"success":
			icon = "check"
			col = UiTheme.c("accent")
	h.add_child(UI.icon_rect(icon, 18, col))
	var l := UI.label(text, "", true)
	l.custom_minimum_size.x = 260
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	p.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			p.queue_free())
	add_child(p)
	p.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.15)
	tw.tween_interval(3.2 if kind == "info" or kind == "success" else 5.5)
	tw.tween_property(p, "modulate:a", 0.0, 0.35)
	tw.tween_callback(p.queue_free)
