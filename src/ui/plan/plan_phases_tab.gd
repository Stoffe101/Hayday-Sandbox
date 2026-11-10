extends PlanTab
## Phases tab (docs/PLANNING.md §3–4): construction phases in build order. Add,
## rename, recolour, reorder (▲ ▼), delete, attach areas, assign the selection
## by hand (or clear that), mark done. Each phase shows its objects, Design /
## To buy / Remaining cost, status, completion and target; the focus button
## frames its objects and highlights them. "Available budget" edits the coins
## and diamonds you have (profile balances) and lists which phases that pays
## for, in build order — currencies are never converted.

var _body: VBoxContainer
var _sig := ""


func _build() -> void:
	tab_id = "phases"
	title = "Phases"
	icon = "layers"
	var tools := PlanUI.flow()
	tools.add_child(PlanUI.small_button("Add phase", "plus", "A new phase at the end of the build order", _add_phase))
	var assign := MenuButton.new()
	assign.text = "Assign selection…"
	assign.icon = Icons.get_icon("map-pin", 20)
	assign.flat = false
	assign.theme_type_variation = "Ghost"
	assign.add_theme_font_size_override("font_size", 13)
	assign.tooltip_text = "Put the selected objects in a phase by hand (wins over the area rule)"
	assign.about_to_popup.connect(func(): _fill_assign_menu(assign.get_popup()))
	assign.get_popup().id_pressed.connect(_on_assign)
	tools.add_child(assign)
	tools.add_child(PlanUI.small_button("Clear manual", "x", "The selected objects follow the area rule again", func(): _assign("")))
	add_child(tools)
	_body = UI.vbox(8)
	add_child(_body)


func refresh() -> void:
	var eng := ctx.engine
	if eng == null:
		return
	var sig := "%d|%s|%s|%s|%d" % [eng.version, ctx.active_phase, str(ctx.plan().get("phases", []).hash()), str(ctx.session.layout.profile.hash()), ctx.selection().size()]
	if sig == _sig:
		return
	_sig = sig
	var keep := PlanUI.focused_key(self)
	UI.clear(_body)
	_budget_card()
	var phases := PlanDoc.phases(ctx.plan())
	if phases.is_empty():
		var card := UI.card()
		var v := UI.vbox(4)
		card.add_child(v)
		v.add_child(UI.label("No phases yet", "Heading"))
		v.add_child(UI.label("Phases are the order you build in: “Farm entrance” first, then “Orchard”… Attach areas to a phase, or assign selected objects by hand. Everything else stays Unphased.", "Dim", true))
		_body.add_child(card)
	for i in phases.size():
		_body.add_child(_row(phases[i], i, phases.size()))
	var un := eng.phase_totals(BudgetEngine.UNPHASED, BudgetEngine.MODE_DESIGN)
	if un.objects > 0:
		_body.add_child(_unphased_row(un))
	PlanUI.restore_focus(self, keep)


# --- available budget + affordability -------------------------------------------------------

func _budget_card() -> void:
	_body.add_child(UI.section("Available budget"))
	var card := UI.card()
	var v := UI.vbox(6)
	card.add_child(v)
	var prof := ctx.session.layout.profile
	var bal: Dictionary = prof.get("balances", {}) if prof.get("balances") is Dictionary else {}
	for cur in [Currency.COINS, Currency.DIAMONDS]:
		var row := UI.hbox(6)
		row.add_child(BudgetWidget.glyph(cur, 18))
		row.add_child(PlanUI.spin(int(bal.get(cur, 0)), "", "%s you have now (inventory balance)" % Currency.name_of(cur), "bal_" + cur,
			func(n: int): _set_balance(cur, n)))
		v.add_child(row)
	var spend := BudgetEngine.spendable(prof)
	var caps: PackedStringArray = []
	for pair in [["budget_coins", "coins"], ["budget_diamonds", "diamonds"]]:
		if int(prof.get(pair[0], -1)) >= 0:
			caps.append("%s %s" % [Currency.format_amount(int(prof[pair[0]])), pair[1]])
	if not caps.is_empty():
		v.add_child(UI.label("Budget limit (Farm tab): %s — the smaller of balance and limit counts." % ", ".join(caps), "Faint", true))
	var aff := ctx.engine.affordability(spend, BudgetEngine.MODE_REMAINING)
	var rows: Array = aff["phases"]
	if rows.is_empty():
		v.add_child(UI.label("Nothing left to pay for.", "Dim", true))
	else:
		v.add_child(UI.label("Remaining cost, cumulative in build order:", "Faint", true))
	for r: Dictionary in rows:
		var ok := bool(r["affordable"])
		var pname := str(r["name"]) if not str(r["phase"]).is_empty() else "Unphased"
		var h := UI.hbox(6)
		h.add_child(UI.icon_rect("check" if ok else "circle-x", 16, UiTheme.c("accent") if ok else UiTheme.c("danger")))
		var lv := UI.vbox(0)
		lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var l := UI.label("%s — %s%s" % [pname, Currency.format_line(r["cost"], "nothing to pay"), "" if bool(r["exact"]) else " or more"], "Dim", true)
		l.tooltip_text = "Cumulative: %s%s" % [Currency.format_line(r["cumulative"], "nothing"), "" if bool(r["exact"]) else "
At least: some prices are unknown."]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		lv.add_child(l)
		if not ok:
			var sf := UI.label("short %s" % Currency.format_line(r["shortfall"]), "Faint", true)
			sf.add_theme_color_override("font_color", UiTheme.c("danger").lerp(UiTheme.c("text_dim"), 0.35))
			lv.add_child(sf)
		h.add_child(lv)
		v.add_child(h)
	if int(aff["affordable_count"]) > 0:
		v.add_child(UI.label("Affordable now: the first %d phase%s." % [int(aff["affordable_count"]), "" if int(aff["affordable_count"]) == 1 else "s"], "Dim", true))
	var missing: Array = aff["missing_balances"]
	if not missing.is_empty():
		var names: PackedStringArray = []
		for m in missing:
			names.append(Currency.name_of(str(m)).to_lower())
		v.add_child(UI.label("No balance recorded for %s (counted as 0; record it in the inventory)." % ", ".join(names), "Faint", true))
	_body.add_child(card)


func _set_balance(currency: String, n: int) -> void:
	var p := ctx.session.layout.profile.duplicate(true)
	var bal: Dictionary = (p.get("balances", {}) as Dictionary).duplicate() if p.get("balances") is Dictionary else {}
	bal[currency] = maxi(0, n)
	p["balances"] = bal
	ctx.set_profile(p, "Set %s balance" % Currency.name_of(currency).to_lower())


# --- phase rows --------------------------------------------------------------------------------

func _row(ph: Dictionary, index: int, count: int) -> PanelContainer:
	var id := str(ph.get("id"))
	var active := id == ctx.active_phase
	var eng := ctx.engine
	var card := UI.card()
	if active:
		card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.c("accent_soft"), 12, UiTheme.c("accent"), 1, Vector4(12, 10, 12, 10)))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_focus(id))
	var v := UI.vbox(4)
	card.add_child(v)
	var head := UI.hbox(2)
	v.add_child(head)
	var num := UI.label("%d" % (index + 1), "Faint")
	num.custom_minimum_size.x = 14
	head.add_child(num)
	head.add_child(PlanUI.swatch(Color.from_string(str(ph.get("color", "#f2b84b")), Color("#f2b84b")), "Colour", func(hex: String):
		_edit(id, {"color": hex}, "Recolour phase")))
	head.add_child(PlanUI.name_edit(str(ph.get("name", "")), "phase_name_" + id, func(t: String): _edit(id, {"name": t}, "Rename phase")))
	var up := UI.button("▲", "", "Earlier in the build order", "Ghost")
	up.disabled = index == 0
	up.pressed.connect(func(): ctx.set_plan(PlanDoc.with_phase_moved(ctx.plan(), id, index - 1), "Move phase earlier"))
	head.add_child(up)
	var down := UI.button("▼", "", "Later in the build order", "Ghost")
	down.disabled = index >= count - 1
	down.pressed.connect(func(): ctx.set_plan(PlanDoc.with_phase_moved(ctx.plan(), id, index + 1), "Move phase later"))
	head.add_child(down)
	var st := eng.phase_status(id)
	var row2 := UI.hbox(6)
	row2.add_child(PlanUI.status_badge(st))
	var td := eng.phase_totals(id, BudgetEngine.MODE_DESIGN)
	var pct := 0 if td.objects == 0 else roundi(100.0 * td.placed_objects / td.objects)
	if st == BudgetEngine.PHASE_COMPLETED and bool(ph.get("done", false)):
		pct = 100
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value = pct
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(60, 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.tooltip_text = "%d of %d objects placed in Hay Day" % [td.placed_objects, td.objects]
	row2.add_child(bar)
	row2.add_child(UI.label("%d%%" % pct, "Faint"))
	v.add_child(row2)
	var areas: PackedStringArray = []
	for aid in ph.get("areas", []):
		var a := PlanDoc.area(ctx.plan(), str(aid))
		if not a.is_empty():
			areas.append(str(a.get("name", aid)))
	v.add_child(UI.label("%d object%s%s" % [td.objects, "" if td.objects == 1 else "s", " · areas: " + ", ".join(areas) if not areas.is_empty() else " · no areas attached"], "Dim", true))
	for m: String in BudgetEngine.MODES:
		var t := eng.phase_totals(id, m)
		var l := UI.label("%s: %s" % [str(PlanScope.MODE_LABELS[m]), PlanUI.cost_text(t)], "Faint", true)
		l.tooltip_text = str(PlanScope.MODE_HELP[m])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		v.add_child(l)
	var target: Dictionary = ph.get("target", {}) if ph.get("target") is Dictionary else {}
	if not target.is_empty():
		var over := PlanScope.over_target(eng.phase_totals(id, BudgetEngine.MODE_REMAINING).cost, target)
		var tl := UI.label(("Over its target by %s" % Currency.format_line(over)) if not over.is_empty() else "Target: %s" % Currency.format_line(target), "Dim", true)
		if not over.is_empty():
			tl.add_theme_color_override("font_color", UiTheme.c("danger"))
		v.add_child(tl)
	if active:
		_details(v, ph, id)
	return card


func _details(v: VBoxContainer, ph: Dictionary, id: String) -> void:
	v.add_child(HSeparator.new())
	var areas := PlanDoc.areas(ctx.plan())
	if areas.is_empty():
		v.add_child(UI.label("No areas yet: draw some in the Areas tab, then attach them here.", "Faint", true))
	else:
		v.add_child(UI.label("Areas in this phase", "Faint"))
		var f := PlanUI.flow()
		var mine: Array = ph.get("areas", [])
		for a in areas:
			var aid := str(a.get("id"))
			var cb := CheckBox.new()
			cb.text = str(a.get("name", aid))
			cb.button_pressed = aid in mine
			cb.toggled.connect(func(on: bool): _toggle_area(id, aid, on))
			f.add_child(cb)
		v.add_child(f)
	var target: Dictionary = ph.get("target", {}) if ph.get("target") is Dictionary else {}
	v.add_child(UI.label("Target budget (0 = none)", "Faint"))
	for cur in [Currency.COINS, Currency.DIAMONDS]:
		var tr := UI.hbox(6)
		tr.add_child(BudgetWidget.glyph(cur, 18))
		tr.add_child(PlanUI.spin(int(target.get(cur, 0)), "", "Target budget in %s (0 = none)" % Currency.name_of(cur).to_lower(), "phase_t%s_%s" % [cur, id],
			func(n: int): _set_target(id, cur, n)))
		v.add_child(tr)
	var acts := PlanUI.flow()
	acts.add_child(PlanUI.small_button("Show", "crosshair", "Frame its objects on the farm", func(): _focus(id)))
	acts.add_child(PlanUI.small_button("Picture…", "image-down", "Save a picture of this phase with its guide step numbers (placeholder art)", func():
		ctx.request_export_image.emit({"scope": "phase", "id": id, "guide_numbers": true, "path": "", "art": "placeholder"})))
	var done := bool(ph.get("done", false))
	acts.add_child(PlanUI.small_button("Not done" if done else "Mark done", "check", "Mark the whole phase as built (or not)", func():
		_edit(id, {"done": not done}, "Phase done" if not done else "Phase not done")))
	acts.add_child(PlanUI.small_button("Delete", "trash", "Delete the phase (objects stay; manual assignments to it are cleared)", func():
		ctx.set_active_phase("")
		ctx.set_plan(PlanDoc.without_phase(ctx.plan(), id), "Delete phase “%s”" % str(ph.get("name", "")))))
	v.add_child(acts)


func _unphased_row(t: BudgetEngine.Totals) -> PanelContainer:
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	v.add_child(UI.label("Unphased", "Heading"))
	v.add_child(UI.label("%d object%s in no phase · design %s" % [t.objects, "" if t.objects == 1 else "s", PlanUI.cost_text(t)], "Dim", true))
	var b := PlanUI.small_button("Show them", "crosshair", "Select the unphased objects", func():
		ctx.request_focus.emit(ctx.engine.phase_uids(BudgetEngine.UNPHASED), true))
	v.add_child(b)
	return card


# --- actions ---------------------------------------------------------------------------------------

func _focus(id: String) -> void:
	ctx.set_active_phase(id)
	var uids := ctx.engine.phase_uids(id)
	var ph := PlanDoc.phase(ctx.plan(), id)
	ctx.request_highlight.emit(uids, Color.from_string(str(ph.get("color", "#f2b84b")), Color("#f2b84b")))
	if not uids.is_empty():
		ctx.request_focus.emit(uids, false)


func _add_phase() -> void:
	var plan := ctx.plan()
	var id := PlanDoc.next_id(plan, "p")
	var nm := PlanScope.next_phase_name(plan)
	var rec := {"name": nm, "areas": []}
	if not ctx.active_area.is_empty() and not PlanDoc.area(plan, ctx.active_area).is_empty():
		var used := false
		for p in PlanDoc.phases(plan):
			used = used or ctx.active_area in (p.get("areas", []) as Array)
		if not used:
			rec["areas"] = [ctx.active_area]
	ctx.set_plan(PlanDoc.with_phase(plan, rec), "Add phase “%s”" % nm)
	ctx.set_active_phase(id)


func _edit(id: String, fields: Dictionary, label: String) -> void:
	var p := PlanDoc.phase(ctx.plan(), id).duplicate(true)
	if p.is_empty():
		return
	for k in fields:
		p[k] = fields[k]
	ctx.set_plan(PlanDoc.with_phase(ctx.plan(), p), label)


func _toggle_area(id: String, area_id: String, on: bool) -> void:
	var p := PlanDoc.phase(ctx.plan(), id).duplicate(true)
	var list: Array = (p.get("areas", []) as Array).duplicate()
	if on and not area_id in list:
		list.append(area_id)
	elif not on:
		list.erase(area_id)
	p["areas"] = list
	ctx.set_plan(PlanDoc.with_phase(ctx.plan(), p), "Attach area" if on else "Detach area")


func _set_target(id: String, currency: String, n: int) -> void:
	var p := PlanDoc.phase(ctx.plan(), id).duplicate(true)
	if p.is_empty():
		return
	var t: Dictionary = (p.get("target", {}) as Dictionary).duplicate() if p.get("target") is Dictionary else {}
	if n > 0:
		t[currency] = n
	else:
		t.erase(currency)
	if t.is_empty():
		p.erase("target")
	else:
		p["target"] = t
	ctx.set_plan(PlanDoc.with_phase(ctx.plan(), p), "Phase target", "phase_target_" + id)


func _fill_assign_menu(pm: PopupMenu) -> void:
	pm.clear()
	var n := ctx.selection().size()
	if n == 0:
		pm.add_item("Select objects on the farm first", 999)
		pm.set_item_disabled(0, true)
		return
	var phases := PlanDoc.phases(ctx.plan())
	for i in phases.size():
		pm.add_item("%s  (%d object%s)" % [str(phases[i].get("name", "")), n, "" if n == 1 else "s"], i)
	if phases.is_empty():
		pm.add_item("Add a phase first", 999)
		pm.set_item_disabled(0, true)


func _on_assign(i: int) -> void:
	var phases := PlanDoc.phases(ctx.plan())
	if i >= 0 and i < phases.size():
		_assign(str(phases[i].get("id")))


func _assign(phase_id: String) -> void:
	var uids := ctx.selection().duplicate()
	if uids.is_empty():
		ctx.toast("Select objects on the farm first", "info")
		return
	ctx.set_plan(PlanDoc.with_assignment(ctx.plan(), uids, phase_id),
		("Assign %d object%s to a phase" if not phase_id.is_empty() else "Clear phase of %d object%s") % [uids.size(), "" if uids.size() == 1 else "s"])
	if not phase_id.is_empty():
		ctx.set_active_phase(phase_id)
