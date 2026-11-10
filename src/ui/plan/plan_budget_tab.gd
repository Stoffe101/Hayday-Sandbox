extends PlanTab
## Budget tab (docs/PLANNING.md §4): the cost mode; whole farm, selection,
## active area and active phase side by side per currency; what is NOT in the
## totals (unknown prices, can't-be-bought items, unknown ownership) with ways to
## fix it; land; area / phase targets; the most expensive objects and areas; the
## cost heatmap and its legend. Read-only: edits go through ctx (prices,
## inventory) or other tabs.

const LIST_MAX := 10

var _mode_btns: Dictionary = {}
var _ready_box: VBoxContainer
var _body: VBoxContainer
var _sig := ""


func _build() -> void:
	tab_id = "budget"
	title = "Budget"
	icon = "coins"
	_ready_box = UI.vbox(0)
	add_child(_ready_box)
	var seg := PanelContainer.new()
	seg.theme_type_variation = "SegmentBar"
	var sh := UI.hbox(2)
	seg.add_child(sh)
	var group := ButtonGroup.new()
	for m: String in BudgetEngine.MODES:
		var b := UI.button(str(PlanScope.MODE_LABELS[m]), "", str(PlanScope.MODE_HELP[m]), "Segment")
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 13)
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var pad := Vector4(6, 5, 6, 5)
		b.add_theme_stylebox_override("normal", UiTheme.box(Color.TRANSPARENT, 999, Color.TRANSPARENT, 0, pad))
		b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.c("elevated_hover"), 999, Color.TRANSPARENT, 0, pad))
		b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.c("accent"), 999, Color.TRANSPARENT, 0, pad))
		b.add_theme_stylebox_override("hover_pressed", UiTheme.box(UiTheme.c("accent_hover"), 999, Color.TRANSPARENT, 0, pad))
		b.pressed.connect(func(): ctx.set_mode(m))
		sh.add_child(b)
		_mode_btns[m] = b
	add_child(seg)
	_body = UI.vbox(8)
	add_child(_body)
	resized.connect(func():
		if _narrow() != _was_narrow:
			_sig = ""
			_on_changed())


var _was_narrow := false


func _narrow() -> bool:
	## Too narrow for totals side by side (small window / large UI scale): stacked.
	var w := size.x
	if w <= 1.0 and get_parent() is Control:
		w = (get_parent() as Control).size.x
	return w > 1.0 and w < 300.0


func refresh() -> void:
	var eng := ctx.engine
	if eng == null:
		return
	var sig := "%d/%d|%s|%s|%s|%s|%s|%d|%s|%d" % [eng.get_instance_id(), eng.version, ctx.mode, str(ctx.selection()), ctx.active_area, ctx.active_phase,
		str(ctx.layers.get("heatmap")), ctx.session.stack.version, ctx.session.layout.mode, ctx.session.layout.profile.hash()]
	if sig == _sig:
		return
	_sig = sig
	for m in _mode_btns:
		(_mode_btns[m] as Button).set_pressed_no_signal(m == ctx.mode)
	UI.clear(_body)
	# What blocks building it comes first, apart from what it costs.
	UI.clear(_ready_box)
	_ready_box.add_child(ReadinessCard.build(ctx))
	_body.add_child(UI.label(str(PlanScope.MODE_HELP[ctx.mode]), "Faint", true))
	_totals_section()
	var sc := ctx.scope()
	var uids: Variant = PlanScope.scope_uids(eng, sc)
	var where := str(sc.get("label", "Whole farm"))
	var br := eng.item_breakdown(uids, ctx.mode)
	_unknown_section(br, uids, where)
	_not_buyable_section(br, uids, where)
	_ownership_section(sc)
	_land_section()
	_targets_section()
	_expensive_section(uids, where)
	_heatmap_section()


# --- totals side by side ---------------------------------------------------------------------

func _columns() -> Array:
	## [[header, tooltip, Totals]] for the farm and whatever else is in focus.
	var eng := ctx.engine
	var cols: Array = [["Farm", "Whole farm", eng.totals(null, ctx.mode)]]
	var sel := ctx.selection()
	if not sel.is_empty():
		cols.append(["Selection", "%d selected object%s" % [sel.size(), "" if sel.size() == 1 else "s"], eng.totals(sel, ctx.mode)])
	var a := PlanDoc.area(ctx.plan(), ctx.active_area)
	if not a.is_empty():
		cols.append([str(a.get("name", "Area")), "Area “%s”" % str(a.get("name", "")), eng.area_totals(ctx.active_area, ctx.mode)])
	var p := PlanDoc.phase(ctx.plan(), ctx.active_phase)
	if not p.is_empty():
		cols.append([str(p.get("name", "Phase")), "Phase “%s” (with the land it opens)" % str(p.get("name", "")), eng.phase_totals(ctx.active_phase, ctx.mode)])
	return cols


func _totals_section() -> void:
	_body.add_child(UI.section("Totals · %s" % str(PlanScope.MODE_LABELS[ctx.mode])))
	var cols := _columns()
	_was_narrow = _narrow()
	if _was_narrow:
		_totals_stacked(cols)
		return
	var card := UI.card()
	var grid := GridContainer.new()
	grid.columns = cols.size() + 1
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	card.add_child(grid)
	_body.add_child(card)
	grid.add_child(Control.new())
	for c: Array in cols:
		var h := UI.label(str(c[0]), "Faint")
		h.tooltip_text = str(c[1])
		h.mouse_filter = Control.MOUSE_FILTER_PASS
		h.clip_text = true
		h.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h.custom_minimum_size.x = 40
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(h)
	var cur := {}
	for c: Array in cols:
		for k in (c[2] as BudgetEngine.Totals).cost:
			cur[k] = true
	var short := cols.size() > 2
	for k: String in Currency.sorted_ids(cur.keys()):
		var g := BudgetWidget.glyph(k, 16)
		g.tooltip_text = Currency.name_of(k)
		g.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(g)
		for c: Array in cols:
			var t: BudgetEngine.Totals = c[2]
			_cell(grid, int(t.cost.get(k, 0)), short, "%s %s" % [Currency.format_amount(int(t.cost.get(k, 0))), Currency.unit_name(k, int(t.cost.get(k, 0)))])
	if cur.is_empty():
		grid.add_child(UI.label("—", "Faint"))
		for c in cols:
			grid.add_child(UI.label("", "Faint"))
	for row in [["Objects", "objects"], ["Not priced", "unpriced"]]:
		var l := UI.label(row[0], "Faint")
		l.tooltip_text = "Unknown prices and items that can't be bought: counted here, never as 0" if row[1] == "unpriced" else "Objects in the scope"
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		grid.add_child(l)
		for c: Array in cols:
			var t: BudgetEngine.Totals = c[2]
			var n := t.objects if row[1] == "objects" else t.unknown_price_objects + t.not_buyable_objects
			var v := UI.label(UI.fmt_int(n), "Dim")
			v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			if row[1] == "unpriced" and n > 0:
				v.add_theme_color_override("font_color", UiTheme.c("warn"))
				v.tooltip_text = PlanScope.unknown_text(t)
				v.mouse_filter = Control.MOUSE_FILTER_PASS
			grid.add_child(v)
	if cols.size() > 1:
		_body.add_child(UI.label("Selection, area and phase are parts of the farm total. Areas may overlap, so area totals are not additive; phase totals add up to the farm.", "Faint", true))


func _totals_stacked(cols: Array) -> void:
	## One small card per scope: name, amounts (wrapping), objects and unpriced count.
	for c: Array in cols:
		var t: BudgetEngine.Totals = c[2]
		var card := UI.card()
		var v := UI.vbox(2)
		card.add_child(v)
		var h := UI.label(str(c[0]), "Dim")
		h.tooltip_text = str(c[1])
		h.mouse_filter = Control.MOUSE_FILTER_PASS
		h.clip_text = true
		h.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.add_child(h)
		var f := PlanUI.flow()
		for k: String in Currency.sorted_ids(t.cost.keys()):
			f.add_child(BudgetWidget.amount_chip(k, int(t.cost[k]), true))
		if t.cost.is_empty():
			f.add_child(UI.label("nothing to pay" if t.is_exact() else "no known price", "Faint"))
		v.add_child(f)
		var unk := t.unknown_price_objects + t.not_buyable_objects
		var l := UI.label("%d object%s%s" % [t.objects, "" if t.objects == 1 else "s", " · %d not priced" % unk if unk > 0 else ""], "Faint", true)
		if unk > 0:
			l.tooltip_text = PlanScope.unknown_text(t)
			l.mouse_filter = Control.MOUSE_FILTER_PASS
		v.add_child(l)
		_body.add_child(card)
	if cols.size() > 1:
		_body.add_child(UI.label("Selection, area and phase are parts of the farm total. Areas may overlap, so area totals are not additive; phase totals add up to the farm.", "Faint", true))


func _cell(grid: GridContainer, n: int, short: bool, tip: String) -> void:
	var l := UI.label(PlanScope.abbreviate(n) if short else Currency.format_amount(n))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_font_size_override("font_size", 14)
	grid.add_child(l)


# --- what is not in the totals ----------------------------------------------------------------

func _uids_of_item(item: String, uids: Variant) -> Array:
	var out: Array = []
	var pool: Array = ctx.session.layout.objects.keys() if uids == null else uids
	for u in pool:
		var o := ctx.session.layout.get_obj(int(u))
		if o != null and (o.item_id == item or ctx.db.resolve_id(o.item_id) == item):
			out.append(o.uid)
	return out


func _item_rows(card_v: VBoxContainer, rows: Array, uids: Variant, price_button: bool) -> void:
	## rows: [[item, count, tooltip]]
	for i in mini(rows.size(), LIST_MAX):
		var r: Array = rows[i]
		var item: String = r[0]
		var h := UI.hbox(4)
		var b := PlanUI.row_button("%s  ×%d" % [ctx.item_name(item), int(r[1])], "%s\nClick: show them on the farm" % str(r[2]), func():
			ctx.request_focus.emit(_uids_of_item(item, uids), true))
		h.add_child(b)
		if price_button:
			var pb := UI.icon_button("pencil", "Enter the price you know for %s (kept on this PC)" % ctx.item_name(item), "Ghost", 16)
			pb.pressed.connect(func(): ctx.request_price_edit.emit(item))
			h.add_child(pb)
		card_v.add_child(h)
	if rows.size() > LIST_MAX:
		card_v.add_child(UI.label("+ %d more item types" % (rows.size() - LIST_MAX), "Faint"))


func _unknown_section(br: Dictionary, uids: Variant, where: String) -> void:
	var rows: Array = []
	for item: String in br:
		var e: Dictionary = br[item]
		if int(e["unknown"]) > 0:
			rows.append([item, int(e["unknown"]), "Price unknown: %s" % ctx.prices.method_text(item)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1] if a[1] != b[1] else a[0] < b[0])
	_body.add_child(UI.section("Unknown prices"))
	var card := UI.card()
	var v := UI.vbox(2)
	card.add_child(v)
	if rows.is_empty():
		v.add_child(UI.label("Every charged object in %s has a known price." % where.to_lower() if where == "Whole farm" else "Every charged object here has a known price.", "Dim", true))
	else:
		var n := 0
		for r in rows:
			n += int(r[1])
		v.add_child(UI.label("%d object%s of %d type%s in %s: not in the totals until you add their price." % [n, "" if n == 1 else "s", rows.size(), "" if rows.size() == 1 else "s", where.to_lower() if where == "Whole farm" else where], "Dim", true))
		_item_rows(v, rows, uids, true)
	_body.add_child(card)


func _not_buyable_section(br: Dictionary, uids: Variant, where: String) -> void:
	var rows: Array = []
	for item: String in br:
		var e: Dictionary = br[item]
		if int(e["not_buyable"]) > 0:
			rows.append([item, int(e["not_buyable"]), ctx.prices.method_text(item)])
	if rows.is_empty():
		return
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1] if a[1] != b[1] else a[0] < b[0])
	_body.add_child(UI.section("Can't be bought"))
	var card := UI.card()
	var v := UI.vbox(2)
	card.add_child(v)
	v.add_child(UI.label("Rewards and items the shop doesn't sell (%s): you need to own them already." % where.to_lower() if where == "Whole farm" else "Rewards and items the shop doesn't sell: you need to own them already.", "Dim", true))
	_item_rows(v, rows, uids, false)
	_body.add_child(card)


func _ownership_section(sc: Dictionary) -> void:
	var t := PlanScope.totals(ctx.engine, sc, BudgetEngine.MODE_TO_BUY)
	_body.add_child(UI.section("Inventory"))
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	var types: Array = t.unknown_ownership_types
	if types.is_empty():
		v.add_child(UI.label("Every item type here has an inventory entry (or a baseline): owned copies are deducted.", "Dim", true))
	else:
		v.add_child(UI.label("%d item type%s without an inventory entry count as to buy (an upper bound):" % [types.size(), "" if types.size() == 1 else "s"], "Dim", true))
		var names: PackedStringArray = []
		for id in types.slice(0, 8):
			names.append(ctx.item_name(str(id)))
		var more := "" if types.size() <= 8 else " and %d more" % (types.size() - 8)
		v.add_child(UI.label(", ".join(names) + more, "Faint", true))
	var b := UI.button("Record inventory…", "clipboard-check", "What you own in Hay Day: copies per item and your coins / diamonds")
	b.pressed.connect(func(): ctx.request_inventory.emit())
	v.add_child(b)
	_body.add_child(card)


func _land_section() -> void:
	var t := ctx.engine.totals(null, BudgetEngine.MODE_TO_BUY)
	if t.plots.is_empty():
		return
	_body.add_child(UI.section("Land and expansions"))
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	v.add_child(UI.label("%d locked plot%s under the design must be unlocked." % [t.plots.size(), "" if t.plots.size() == 1 else "s"], "Dim", true))
	for k: String in Currency.sorted_ids(t.land_cost.keys()):
		v.add_child(BudgetWidget.currency_row(k, int(t.land_cost[k]), ""))
	if not t.unknown_cost_plots.is_empty():
		v.add_child(UI.label("%d plot%s with unknown supplies (not in the totals)." % [t.unknown_cost_plots.size(), "" if t.unknown_cost_plots.size() == 1 else "s"], "Faint", true))
	_body.add_child(card)


func _targets_section() -> void:
	var rows: Array = []
	for a in PlanDoc.areas(ctx.plan()):
		if a.get("target") is Dictionary and not (a["target"] as Dictionary).is_empty():
			rows.append(["Area", a, ctx.engine.area_totals(str(a.get("id")), ctx.mode)])
	for p in PlanDoc.phases(ctx.plan()):
		if p.get("target") is Dictionary and not (p["target"] as Dictionary).is_empty():
			rows.append(["Phase", p, ctx.engine.phase_totals(str(p.get("id")), ctx.mode)])
	if rows.is_empty():
		return
	_body.add_child(UI.section("Targets"))
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	var kinds := {}
	for r: Array in rows:
		kinds[r[0]] = true
	var last_kind := ""
	for r: Array in rows:
		var rec: Dictionary = r[1]
		var t: BudgetEngine.Totals = r[2]
		if kinds.size() > 1 and r[0] != last_kind:
			v.add_child(UI.label("Areas" if r[0] == "Area" else "Phases", "Faint"))
		last_kind = r[0]
		var over := PlanScope.over_target(t.cost, rec["target"])
		var txt := target_text(str(rec.get("name", "")), t.cost, rec["target"], t.is_exact())
		var l := UI.label(txt + (" · over by %s" % Currency.format_line(over) if not over.is_empty() else ""), "Dim", true)
		l.tooltip_text = "%s “%s”: what it costs (%s) against its target budget" % [r[0], str(rec.get("name", "")), str(PlanScope.MODE_LABELS[ctx.mode]).to_lower()]
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		if not over.is_empty():
			l.add_theme_color_override("font_color", UiTheme.c("danger"))
		v.add_child(l)
	_body.add_child(card)


static func target_text(name: String, cost: Dictionary, target: Dictionary, exact: bool) -> String:
	## "Flower Garden: 1,902 of 20,000 coins target · 20 diamonds (no diamond
	## target) · some prices unknown": every currency of the cost or the target,
	## each against its own target (currencies are never converted).
	var parts: PackedStringArray = []
	var ids := {}
	for k in cost:
		ids[k] = true
	for k in target:
		ids[k] = true
	for k: String in Currency.sorted_ids(ids.keys()):
		var have := int(cost.get(k, 0))
		if target.has(k) and int(target[k]) > 0:
			parts.append("%s of %s %s target" % [Currency.format_amount(have), Currency.format_amount(int(target[k])), Currency.unit_name(k, int(target[k]))])
		elif have > 0:
			parts.append("%s %s (no %s target)" % [Currency.format_amount(have), Currency.unit_name(k, have), Currency.unit_name(k, 1)])
	if parts.is_empty():
		parts.append("nothing to pay")
	if not exact:
		parts.append("some prices unknown")
	return "%s: %s" % [name, " · ".join(parts)]


func _expensive_section(uids: Variant, where: String) -> void:
	var top := PlanScope.most_expensive(ctx.engine, uids, ctx.mode, 5)
	var area_rows: Array = []
	for a in PlanDoc.areas(ctx.plan()):
		var t := ctx.engine.area_totals(str(a.get("id")), ctx.mode)
		if int(t.cost.get(Currency.COINS, 0)) > 0 or int(t.cost.get(Currency.DIAMONDS, 0)) > 0:
			area_rows.append([a, t])
	area_rows.sort_custom(func(x: Array, y: Array) -> bool:
		return int((x[1] as BudgetEngine.Totals).cost.get(Currency.COINS, 0)) > int((y[1] as BudgetEngine.Totals).cost.get(Currency.COINS, 0)))
	if top.is_empty() and area_rows.is_empty():
		return
	_body.add_child(UI.section("Most expensive"))
	var card := UI.card()
	var v := UI.vbox(2)
	card.add_child(v)
	if not top.is_empty():
		v.add_child(UI.label("Objects (%s)" % (where.to_lower() if where == "Whole farm" else where), "Faint"))
	for e: Dictionary in top:
		var u := int(e["uid"])
		var o := ctx.session.layout.get_obj(u)
		if o == null:
			continue
		v.add_child(PlanUI.row_button("%s — %s" % [ctx.item_name(o.item_id), Currency.format_line(e["cost"])], "Click: select it and show it on the farm", func():
			ctx.request_focus.emit([u], true)))
	if not area_rows.is_empty():
		v.add_child(UI.label("Areas", "Faint"))
	for r: Array in area_rows.slice(0, 3):
		var a: Dictionary = r[0]
		var aid := str(a.get("id"))
		v.add_child(PlanUI.row_button("%s — %s" % [str(a.get("name", "")), Currency.format_line((r[1] as BudgetEngine.Totals).cost)], "Click: show this area", func():
			ctx.set_active_area(aid)
			ctx.request_focus_rect.emit(PlanDoc.area_bounds(a))))
	_body.add_child(card)


func _heatmap_section() -> void:
	_body.add_child(UI.section("Cost heatmap"))
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	var cb := CheckButton.new()
	cb.text = "Show on the farm"
	cb.tooltip_text = "Colour every object by what it costs"
	cb.button_pressed = bool(ctx.layers.get("heatmap", false))
	cb.toggled.connect(func(on: bool): ctx.set_layer("heatmap", on))
	v.add_child(cb)
	v.add_child(UI.label("Each object's own cost in the current mode (%s). Currencies are never converted." % str(PlanScope.MODE_LABELS[ctx.mode]), "Faint", true))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 3)
	for e: Array in PlanScope.HEAT_LEGEND:
		var sw := ColorRect.new()
		var col := PlanScope.heat_color(int(e[0]))
		sw.color = Color(col.r, col.g, col.b, maxf(col.a, 0.75))
		sw.custom_minimum_size = Vector2(18, 12)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(sw)
		var l := UI.label(str(e[1]), "Faint", true)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
	v.add_child(grid)
	_body.add_child(card)
