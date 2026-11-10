extends PlanTab
## Areas tab (docs/PLANNING.md §3–4): draw rectangle / polygon areas on the
## farm, make one from the selection, then name, recolour, show / hide, give a
## target budget or delete them. Each row shows the area's objects and cost in
## the current mode; clicking a row makes it the active area (budget scope,
## canvas highlight) and frames it. Every edit is one undoable ctx.set_plan.

var _body: VBoxContainer
var _sig := ""


func _build() -> void:
	tab_id = "areas"
	title = "Areas"
	icon = "square-dashed"
	var tools := PlanUI.flow()
	tools.add_child(PlanUI.small_button("Rectangle", "square-dashed", "Drag a rectangle on the farm", func(): ctx.request_area_tool.emit("rect")))
	tools.add_child(PlanUI.small_button("Polygon", "spline", "Click the corners on the farm; double-click or Enter closes it", func(): ctx.request_area_tool.emit("polygon")))
	tools.add_child(PlanUI.small_button("From selection", "scan", "A rectangle around the selected objects", func(): ctx.request_area_tool.emit("selection")))
	add_child(tools)
	var show_cb := CheckButton.new()
	show_cb.text = "Show areas on the farm"
	show_cb.set_meta("layer", "areas")
	show_cb.toggled.connect(func(on: bool): ctx.set_layer("areas", on))
	add_child(show_cb)
	_body = UI.vbox(8)
	add_child(_body)


func refresh() -> void:
	var eng := ctx.engine
	if eng == null:
		return
	for c in get_children():
		if c is CheckButton and c.has_meta("layer"):
			(c as CheckButton).set_pressed_no_signal(bool(ctx.layers.get("areas", true)))
	var sig := "%d|%s|%s|%s" % [eng.version, ctx.mode, ctx.active_area, str(ctx.plan().get("areas", []).hash())]
	if sig == _sig:
		return
	_sig = sig
	var keep := PlanUI.focused_key(self)
	UI.clear(_body)
	var areas := PlanDoc.areas(ctx.plan())
	if areas.is_empty():
		var card := UI.card()
		var v := UI.vbox(4)
		card.add_child(v)
		v.add_child(UI.label("No areas yet", "Heading"))
		v.add_child(UI.label("Areas name parts of your farm — “Flower Garden”, “Orchard” — so you can budget and build them one at a time. Draw one with the buttons above, or drag on the farm with the notes tool (N).", "Dim", true))
		_body.add_child(card)
		return
	_overlap_notice(areas)
	for a: Dictionary in areas:
		_body.add_child(_row(a))
	PlanUI.restore_focus(self, keep)


func _overlap_notice(areas: Array) -> void:
	var pairs := PlanScope.overlapping_areas(ctx.plan())
	if pairs.is_empty():
		return
	var per := {}
	for a in areas:
		per[str(a.get("id"))] = ctx.engine.area_uids(str(a.get("id")))
	var sh := PlanScope.shared_objects(per)
	var names: PackedStringArray = []
	for p: Array in pairs.slice(0, 3):
		names.append("%s + %s" % [str(PlanDoc.area(ctx.plan(), p[0]).get("name", p[0])), str(PlanDoc.area(ctx.plan(), p[1]).get("name", p[1]))])
	var txt := "Overlapping areas: %s%s." % [", ".join(names), "" if pairs.size() <= 3 else " and %d more" % (pairs.size() - 3)]
	if int(sh["objects"]) > 0:
		txt += " %d object%s count in more than one area, so area totals are not additive (phases still add up)." % [int(sh["objects"]), "" if int(sh["objects"]) == 1 else "s"]
	var l := UI.label(txt, "Dim", true)
	l.add_theme_color_override("font_color", UiTheme.c("warn"))
	_body.add_child(l)


func _row(a: Dictionary) -> PanelContainer:
	var id := str(a.get("id"))
	var active := id == ctx.active_area
	var card := UI.card()
	if active:
		card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.c("accent_soft"), 12, UiTheme.c("accent"), 1, Vector4(12, 10, 12, 10)))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_activate(a))
	var v := UI.vbox(4)
	card.add_child(v)
	var head := UI.hbox(4)
	v.add_child(head)
	head.add_child(PlanUI.swatch(Color.from_string(str(a.get("color", "#6fb3e0")), Color("#6fb3e0")), "Colour", func(hex: String):
		_edit(id, {"color": hex}, "Recolour area")))
	head.add_child(PlanUI.name_edit(str(a.get("name", "")), "area_name_" + id, func(t: String):
		_edit(id, {"name": t}, "Rename area")))
	var vis := bool(a.get("visible", true))
	var eye := UI.icon_button("eye" if vis else "eye-off", "Hide on the farm" if vis else "Show on the farm", "Ghost", 16)
	eye.pressed.connect(func(): _edit(id, {"visible": not vis}, "Hide area" if vis else "Show area"))
	head.add_child(eye)
	var focus := UI.icon_button("crosshair", "Show it on the farm", "Ghost", 16)
	focus.pressed.connect(func(): _activate(a))
	head.add_child(focus)
	var t := ctx.engine.area_totals(id, ctx.mode)
	var shape := "polygon, %d corners" % PlanDoc.polygon(a).size() if not a.get("rect") is Array else "%d × %d tiles" % [PlanDoc.area_bounds(a).size.x, PlanDoc.area_bounds(a).size.y]
	var info := UI.label("%d object%s · %s" % [t.objects, "" if t.objects == 1 else "s", PlanUI.cost_text(t)], "Dim", true)
	info.tooltip_text = "%s: %s\n%s" % [str(PlanScope.MODE_LABELS[ctx.mode]), Currency.format_line(t.cost, "nothing to pay", "no known price"), shape]
	info.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(info)
	var target: Dictionary = a.get("target", {}) if a.get("target") is Dictionary else {}
	var over := PlanScope.over_target(t.cost, target)
	if not over.is_empty():
		var w := UI.label("Over its target by %s" % Currency.format_line(over), "Dim", true)
		w.add_theme_color_override("font_color", UiTheme.c("danger"))
		v.add_child(w)
	if active:
		v.add_child(UI.label(shape, "Faint"))
		var phases: PackedStringArray = []
		for p in PlanDoc.phases(ctx.plan()):
			if id in (p.get("areas", []) as Array):
				phases.append(str(p.get("name", "")))
		v.add_child(UI.label("In phase: %s" % (", ".join(phases) if not phases.is_empty() else "none (attach it in the Phases tab)"), "Faint", true))
		v.add_child(UI.label("Target budget (0 = none)", "Faint"))
		for cur in [Currency.COINS, Currency.DIAMONDS]:
			var tr := UI.hbox(6)
			tr.add_child(BudgetWidget.glyph(cur, 18))
			tr.add_child(PlanUI.spin(int(target.get(cur, 0)), "", "Target budget in %s (0 = none)" % Currency.name_of(cur).to_lower(), "area_t%s_%s" % [cur, id],
				func(n: int): _set_target(id, cur, n)))
			v.add_child(tr)
		var acts := PlanUI.flow()
		acts.add_child(PlanUI.small_button("Picture…", "image-down", "Save a picture of this area (placeholder art)", func():
			ctx.request_export_image.emit({"scope": "area", "id": id, "guide_numbers": false, "path": "", "art": "placeholder"})))
		var st := PlanUI.small_button("Save as stamp", "copy-plus", "Keep this area's design as a stamp: place it anywhere from Stamps (fixed farm buildings are left out)", func():
			ctx.request_area_stamp.emit(id))
		st.disabled = t.objects == 0
		acts.add_child(st)
		var del := PlanUI.small_button("Delete", "trash", "Delete the area (objects stay; Ctrl+Z undoes it)", func():
			ctx.set_active_area("")
			ctx.set_plan(PlanDoc.without_area(ctx.plan(), id), "Delete area “%s”" % str(a.get("name", ""))))
		del.add_theme_color_override("icon_normal_color", UiTheme.c("danger"))
		acts.add_child(del)
		v.add_child(acts)
	return card


func _activate(a: Dictionary) -> void:
	ctx.set_active_area(str(a.get("id")))
	ctx.request_focus_rect.emit(PlanDoc.area_bounds(a))


func _edit(id: String, fields: Dictionary, label: String) -> void:
	var a := PlanDoc.area(ctx.plan(), id).duplicate(true)
	if a.is_empty():
		return
	for k in fields:
		a[k] = fields[k]
	ctx.set_plan(PlanDoc.with_area(ctx.plan(), a), label)


func _set_target(id: String, currency: String, n: int) -> void:
	var a := PlanDoc.area(ctx.plan(), id).duplicate(true)
	if a.is_empty():
		return
	var t: Dictionary = (a.get("target", {}) as Dictionary).duplicate() if a.get("target") is Dictionary else {}
	if n > 0:
		t[currency] = n
	else:
		t.erase(currency)
	if t.is_empty():
		a.erase("target")
	else:
		a["target"] = t
	ctx.set_plan(PlanDoc.with_area(ctx.plan(), a), "Area target", "area_target_" + id)
