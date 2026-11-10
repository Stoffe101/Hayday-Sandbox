class_name PlanShopTab
extends PlanTab
## Shopping list (docs/PLANNING.md §4–5): what to buy for a scope (whole farm,
## selection, a phase, an area) in one of three cost modes, grouped by item
## group with subtotals. Compact rows (name, still needed, price, badges); a
## click opens the row's details with the "bought" counter, price editing and
## "Show on farm". Acquisition progress is planning data (plan.acquired) changed
## through undoable commands; "Add bought items to my inventory" moves it into
## the inventory in one undo step. Unknown prices stay visibly unknown.

const PAGE := 30
const MERGE_PLUS := "shop_plus:"
const MERGE_SET := "shop_bought:"

var _scope_opt: OptionButton
var _scope_opts: Array = []
var _scope_sig := ""
var _scope_key := PlanUiModels.SCOPE_FARM
var _mode := BudgetEngine.MODE_TO_BUY
var _mode_bar: PanelContainer
var _search: LineEdit
var _sort_opt: OptionButton
var _sort := "group"
var _filters: Dictionary = {}
var _chips: Dictionary = {}
var _progress_l: Label
var _progress_bar: ProgressBar
var _list: PlanUiKit.PagedList
var _totals_l: Label
var _supplies_box: VBoxContainer
var _apply_btn: Button
var _expanded := ""
var _binding := false
## What the current rows were built from: they are rebuilt only when it changes
## (selection changes, other tabs' edits of nothing relevant cost nothing).
var _data_key := ""

## Current data (read by tests / the self-test).
var rows: Array = []
var supplies: Array = []
var shown_rows: Array = []
var totals: Dictionary = {}
var last_refresh_usec := 0
var _farm_level := 1


func _init() -> void:
	tab_id = "shop"
	title = "Shop"
	icon = "coins"


func _build() -> void:
	_scope_opt = OptionButton.new()
	_scope_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scope_opt.fit_to_longest_item = false
	_scope_opt.clip_text = true
	_scope_opt.focus_mode = Control.FOCUS_NONE
	_scope_opt.tooltip_text = "What the list is for"
	_scope_opt.item_selected.connect(func(i: int):
		if i >= 0 and i < _scope_opts.size():
			_scope_key = str(_scope_opts[i]["key"])
			_expanded = ""
			_refresh_data(true))
	add_child(_scope_opt)
	_mode_bar = PlanUiKit.segmented([
		[BudgetEngine.MODE_TO_BUY, "To buy", "Objects your owned copies don't cover"],
		[BudgetEngine.MODE_REMAINING, "Remaining", "Still to buy after what you bought during this project"],
		[BudgetEngine.MODE_DESIGN, "Design", "Every object priced as a purchase, inventory ignored"],
	], _mode, func(id: String):
		_mode = id
		_refresh_data(true))
	add_child(_mode_bar)
	var sr := UI.hbox(6)
	_search = LineEdit.new()
	_search.placeholder_text = "Search items"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.x = 80
	_search.text_changed.connect(func(_t: String): _apply_view(true))
	sr.add_child(_search)
	_sort_opt = OptionButton.new()
	_sort_opt.focus_mode = Control.FOCUS_NONE
	_sort_opt.tooltip_text = "Sort"
	for k in PlanUiModels.SORTS:
		_sort_opt.add_item(str(PlanUiModels.SORT_NAMES[k]))
	_sort_opt.item_selected.connect(func(i: int):
		_sort = str(PlanUiModels.SORTS[i])
		_apply_view(true))
	sr.add_child(_sort_opt)
	add_child(sr)
	var chips := PlanUiKit.flow(6, 6)
	for k in PlanUiModels.FILTER_KEYS:
		var c := PlanUiKit.chip(str(PlanUiModels.FILTER_NAMES[k]), _filter_tip(k))
		var key: String = k
		c.toggled.connect(func(on: bool):
			_filters[key] = on
			_apply_view(true))
		_chips[k] = c
		chips.add_child(c)
	add_child(chips)
	var pr := UI.vbox(3)
	_progress_l = PlanUiKit.wrap_label("", "Dim")
	pr.add_child(_progress_l)
	_progress_bar = PlanUiKit.progress(0.0)
	pr.add_child(_progress_bar)
	add_child(pr)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 180
	_list = PlanUiKit.PagedList.new(PAGE)
	_list.kind_of = func(e: Dictionary) -> String: return str(e["type"])
	_list.make = _make_widget
	_list.bind = _bind_widget
	_list.empty_text = "Nothing to buy here."
	scroll.add_child(_list)
	add_child(scroll)
	var foot := UI.card()
	var fv := UI.vbox(6)
	foot.add_child(fv)
	_totals_l = PlanUiKit.wrap_label("")
	fv.add_child(_totals_l)
	_supplies_box = UI.vbox(2)
	fv.add_child(_supplies_box)
	var btns := PlanUiKit.flow(6, 6)
	_apply_btn = UI.button("Add bought items to my inventory", "package-open",
		"Moves the copies you marked as bought into your inventory (owned), in one undo step")
	_apply_btn.pressed.connect(_apply_to_inventory)
	btns.add_child(_apply_btn)
	var inv := UI.button("Inventory…", "package-open", "What you own: items, coins, diamonds, vouchers and supplies")
	inv.pressed.connect(func(): InventoryDialog.open(ctx))
	btns.add_child(inv)
	var exp_btn := UI.button("Export CSV…", "download", "Save this list as a spreadsheet file")
	exp_btn.pressed.connect(_export_csv)
	btns.add_child(exp_btn)
	fv.add_child(btns)
	add_child(foot)


func _filter_tip(k: String) -> String:
	match k:
		"unfinished": return "Only items with copies still to get"
		"cant_buy": return "Only items that can't be bought (rewards, not sold)"
		"unknown_price": return "Only items whose price is unknown"
		"over_limit": return "Only items used more often than the game allows"
	return ""


# --- data ------------------------------------------------------------------------------

func refresh() -> void:
	_refresh_data(false)


func _scope() -> Dictionary:
	for o in _scope_opts:
		if str(o["key"]) == _scope_key:
			return o
	return {"key": PlanUiModels.SCOPE_FARM, "kind": PlanUiModels.SCOPE_FARM, "id": ""}


func _sync_scopes() -> void:
	var sel: Array = ctx.session.selection
	_scope_opts = PlanUiModels.scope_options(ctx.plan(), sel.size())
	var keys: PackedStringArray = []
	for o in _scope_opts:
		keys.append(str(o["key"]) + "=" + str(o["label"]))
	var sig := "|".join(keys)
	if sig == _scope_sig:
		return
	_scope_sig = sig
	var found := false
	_scope_opt.clear()
	for i in _scope_opts.size():
		_scope_opt.add_item(str(_scope_opts[i]["label"]))
		if str(_scope_opts[i]["key"]) == _scope_key:
			_scope_opt.select(i)
			found = true
	if not found:
		_scope_key = PlanUiModels.SCOPE_FARM
		_scope_opt.select(0)


func _refresh_data(reset_paging: bool) -> void:
	if ctx == null or ctx.session == null:
		return
	var t0 := Time.get_ticks_usec()
	_farm_level = int(ctx.layout().profile.get("level", 1))
	_sync_scopes()
	var scope := _scope()
	var eng := ctx.engine
	var sel: Array = ctx.session.selection
	var key := "%d|%d|%d|%s|%s|%s|%d" % [eng.version, ctx.prices.version if ctx.prices else 0, ctx.session.stack.version,
		_mode, _scope_key, str(sel.hash()) if str(scope["kind"]) == PlanUiModels.SCOPE_SELECTION else "", ctx.plan().hash()]
	if key == _data_key and not reset_paging:
		last_refresh_usec = Time.get_ticks_usec() - t0
		return
	_data_key = key
	PlanUiModels.batch(eng, func() -> Variant:
		var uids: Variant = PlanUiModels.scope_uids(eng, scope, sel)
		rows = ShoppingList.build(eng, uids, _mode, false)
		supplies = ShoppingList.supply_rows(eng, uids, _mode)
		totals = eng.totals(uids, _mode).to_dict()
		return null)
	if str(scope["kind"]) == PlanUiModels.SCOPE_SELECTION and sel.is_empty():
		_list.empty_text = "Select objects on the farm to see what they cost."
	else:
		_list.empty_text = "Nothing in this list." if rows.is_empty() else "No item matches the search or filters."
	_apply_view(reset_paging)
	last_refresh_usec = Time.get_ticks_usec() - t0


func _apply_view(reset_paging: bool = false) -> void:
	var f := _filters.duplicate()
	f["query"] = _search.text
	shown_rows = PlanUiModels.shop_filter(rows, f)
	_list.set_entries(PlanUiModels.shop_entries(shown_rows, _sort), reset_paging)
	var txt := PlanUiModels.totals_text(totals)
	if shown_rows.size() != rows.size():
		txt += " Showing %d of %d items." % [shown_rows.size(), rows.size()]
	_totals_l.text = txt
	var pg := ShoppingList.progress(rows)
	if int(pg["needed"]) > 0:
		_progress_l.text = "Bought %d of %d copies you still needed (%s)." % [int(pg["acquired"]), int(pg["needed"]),
			PlanUiModels.pct_text(PlanUiModels.percent(int(pg["acquired"]), int(pg["needed"])))]
		_progress_bar.value = float(pg["fraction"])
		_progress_bar.visible = true
	else:
		_progress_l.text = "%s · nothing left to buy." % str(BudgetEngine.MODE_NAMES.get(_mode, _mode)) if not rows.is_empty() else str(BudgetEngine.MODE_NAMES.get(_mode, _mode))
		_progress_bar.visible = false
	UI.clear(_supplies_box)
	if not supplies.is_empty():
		_supplies_box.add_child(UI.label("Land for this list", "Section"))
		for s: Dictionary in supplies:
			var l := PlanUiKit.wrap_label(PlanUiModels.supply_text(s), "Dim")
			_supplies_box.add_child(l)
	var acq: Dictionary = ctx.plan().get("acquired", {}) if ctx.plan().get("acquired") is Dictionary else {}
	var n := 0
	for k in acq:
		n += int(acq[k])
	_apply_btn.disabled = n == 0
	_apply_btn.text = "Add %d bought cop%s to my inventory" % [n, "y" if n == 1 else "ies"] if n > 0 else "Add bought items to my inventory"


# --- row widgets -----------------------------------------------------------------------------

class ShopRow extends PanelContainer:
	var item := ""
	var row: Dictionary = {}
	var name_l: Label
	var need_l: Label
	var counts_l: Label
	var price_l: Label
	var badges: HFlowContainer
	var badge_pool: Array = []
	var plus: Button
	var show_btn: Button
	var detail: VBoxContainer
	var detail_l: Label
	var level_l: Label
	var notes_l: Label
	var spin: SpinBox


func _make_widget(kind: String) -> Control:
	if kind == "group":
		var g := UI.vbox(0)
		var h := UI.hbox(8)
		var t := UI.label("", "Section")
		h.add_child(t)
		var s := PlanUiKit.wrap_label("", "Faint")
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(s)
		g.add_child(h)
		g.set_meta("title", t)
		g.set_meta("sub", s)
		var pad := Control.new()
		pad.custom_minimum_size.y = 4
		g.add_child(pad)
		g.move_child(pad, 0)
		return g
	var w := ShopRow.new()
	w.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.c("panel_alt"), 10, Color.TRANSPARENT, 0, Vector4(10, 6, 8, 6)))
	w.mouse_filter = Control.MOUSE_FILTER_STOP
	w.tooltip_text = "Click for details, the bought counter and price editing"
	var v := UI.vbox(3)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	w.add_child(v)
	var top := UI.hbox(6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	w.name_l = PlanUiKit.wrap_label("")
	if UiTheme.font_bold != null:
		w.name_l.add_theme_font_override("font", UiTheme.font_bold)
	w.name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(w.name_l)
	w.need_l = UI.label("", "Dim")
	w.need_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(w.need_l)
	w.plus = UI.icon_button("plus", "I bought one (+1)", "Ghost", 18)
	w.plus.pressed.connect(func(): _plus_one(w.item, str(w.row.get("name", w.item))))
	top.add_child(w.plus)
	w.show_btn = UI.icon_button("crosshair", "Show on farm", "Ghost", 18)
	w.show_btn.pressed.connect(func(): _show_item(w.item))
	top.add_child(w.show_btn)
	v.add_child(top)
	w.price_l = PlanUiKit.wrap_label("", "Dim")
	w.price_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(w.price_l)
	w.counts_l = PlanUiKit.wrap_label("", "Faint")
	w.counts_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(w.counts_l)
	w.badges = PlanUiKit.flow(4, 4)
	w.badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(w.badges)
	w.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_expanded = "" if _expanded == w.item else w.item
			_list.rebind()
			w.accept_event())
	return w


func _build_detail(w: ShopRow) -> void:
	w.detail = UI.vbox(6)
	var v: VBoxContainer = w.get_child(0)
	v.add_child(w.detail)
	w.detail.add_child(HSeparator.new())
	w.detail_l = PlanUiKit.wrap_label("", "Dim")
	w.detail.add_child(w.detail_l)
	w.level_l = PlanUiKit.wrap_label("", "Dim")
	w.detail.add_child(w.level_l)
	w.notes_l = PlanUiKit.wrap_label("", "Faint")
	w.detail.add_child(w.notes_l)
	var h := UI.hbox(8)
	h.add_child(UI.label("Bought so far", "Dim"))
	w.spin = SpinBox.new()
	w.spin.min_value = 0
	w.spin.max_value = 99999
	w.spin.step = 1
	w.spin.rounded = true
	w.spin.custom_minimum_size.x = 96
	w.spin.tooltip_text = "Copies bought during this project (not yet in your inventory). Ctrl+Z undoes."
	w.spin.value_changed.connect(func(val: float):
		if _binding or w.item.is_empty():
			return
		ctx.set_plan(PlanDoc.with_acquired(ctx.plan(), w.item, int(val)), "Bought: %s" % str(w.row.get("name", w.item)), MERGE_SET + w.item))
	h.add_child(w.spin)
	w.detail.add_child(h)
	var bf := PlanUiKit.flow(6, 6)
	var ep := UI.button("Edit price…", "pencil", "See where the price comes from and set your own")
	ep.pressed.connect(func(): PriceDialog.open(ctx, w.item))
	bf.add_child(ep)
	var sh := UI.button("Show on farm", "crosshair", "Frame and select the objects of this item")
	sh.pressed.connect(func(): _show_item(w.item))
	bf.add_child(sh)
	w.detail.add_child(bf)


func _bind_widget(c: Control, e: Dictionary, _i: int) -> void:
	if str(e["type"]) == "group":
		(c.get_meta("title") as Label).text = str(e["group"]).to_upper()
		(c.get_meta("sub") as Label).text = str(e["text"])
		return
	var w := c as ShopRow
	var r: Dictionary = e["row"]
	w.row = r
	w.item = str(r.get("item", ""))
	w.name_l.text = str(r.get("name", w.item))
	var miss := int(r.get("missing", 0))
	w.need_l.text = "need %d" % miss if miss > 0 else "done"
	_font_color(w.need_l, "text" if miss > 0 else "accent")
	var price := PlanUiModels.row_price_text(r)
	var total := PlanUiModels.row_total_text(r)
	w.price_l.text = price if total == "Nothing to pay" or int(r.get("charged", 0)) <= 1 else "%s · total %s" % [price, total]
	w.counts_l.text = PlanUiModels.row_counts_text(r)
	var bl := PlanUiModels.row_badges(r, _farm_level)
	while w.badge_pool.size() < bl.size():
		var b := PlanUiKit.badge("", "faint")
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		w.badge_pool.append(b)
		w.badges.add_child(b)
	for j in w.badge_pool.size():
		var b: PanelContainer = w.badge_pool[j]
		b.visible = j < bl.size()
		if j < bl.size():
			PlanUiKit.set_badge(b, str(bl[j][0]), str(bl[j][1]))
	w.badges.visible = not bl.is_empty()
	w.plus.disabled = not bool(r.get("buyable", false)) and int(r.get("missing", 0)) <= 0
	var open := _expanded == w.item
	if open and w.detail == null:
		_build_detail(w)
	if w.detail != null:
		w.detail.visible = open
	if open:
		_bind_detail(w, r)


func _bind_detail(w: ShopRow, r: Dictionary) -> void:
	var parts: PackedStringArray = []
	parts.append("How to get: %s" % str(r.get("method_text", "")))
	parts.append(PlanUiModels.availability_text(str(r.get("availability", "unknown"))))
	parts.append("Price: %s (%s, %s)" % [PlanUiModels.row_price_text(r), PlanUiModels.origin_text(str(r.get("origin", ""))),
		str(r.get("confidence", "unknown"))])
	if int(r.get("charged", 0)) > 0:
		parts.append("Known total: %s" % PlanUiModels.row_total_text(r))
	if int(r.get("max_count", -1)) > 0:
		parts.append("Limit: %d (this design uses %d)" % [int(r["max_count"]), int(r.get("count_total", 0))])
	w.detail_l.text = "\n".join(parts)
	var lvl := int(r.get("unlock_level", -1))
	if lvl > 0:
		w.level_l.text = "Unlocks at level %d (your farm: level %d)" % [lvl, _farm_level]
		_font_color(w.level_l, "danger" if lvl > _farm_level else "text_dim")
	else:
		w.level_l.text = "Unlock level unknown"
		_font_color(w.level_l, "text_faint")
	var notes := str(r.get("notes", ""))
	if not str(r.get("info", "")).is_empty():
		notes = (notes + "\n" if not notes.is_empty() else "") + str(r["info"])
	w.notes_l.text = notes
	w.notes_l.visible = not notes.is_empty()
	_binding = true
	var le := w.spin.get_line_edit()
	if not le.has_focus():
		w.spin.set_value_no_signal(int(r.get("acquired_total", 0)))
		le.text = str(int(r.get("acquired_total", 0)))
	_binding = false


func _font_color(l: Label, token: String) -> void:
	## Re-used row controls: only touch the theme override when it changes
	## (each override change re-lays the label out).
	var k := token + "|" + str(UiTheme.palette.get("name", ""))
	if str(l.get_meta("color_token", "")) == k:
		return
	l.set_meta("color_token", k)
	l.add_theme_color_override("font_color", UiTheme.c(token))


# --- actions ------------------------------------------------------------------------------

func _plus_one(item: String, name: String) -> void:
	if item.is_empty():
		return
	ctx.set_plan(ShoppingList.with_bought(ctx.plan(), item, 1), "Bought 1 × %s" % name, MERGE_PLUS + item)


func item_uids(item: String) -> Array:
	## Objects of an item inside the current scope (allocation order).
	var all := ctx.engine.alloc_order(item)
	var scope := _scope()
	if str(scope["kind"]) == PlanUiModels.SCOPE_FARM:
		return all
	var inside := {}
	var sc: Variant = PlanUiModels.scope_uids(ctx.engine, scope, ctx.session.selection)
	for u in (sc if sc is Array else []):
		inside[int(u)] = true
	return all.filter(func(u: int) -> bool: return inside.has(u))


func _show_item(item: String) -> void:
	var uids := item_uids(item)
	if uids.is_empty():
		ctx.toast("No object of this item in this list", "info")
		return
	ctx.request_focus.emit(uids, true)


func _apply_to_inventory() -> void:
	var layout := ctx.layout()
	var res := ShoppingList.apply_acquired_to_inventory(layout.profile, ctx.plan())
	var applied: Dictionary = res["applied"]
	if applied.is_empty():
		ctx.toast("Nothing marked as bought yet", "info")
		return
	var n := 0
	for k in applied:
		n += int(applied[k])
	# One undo step for both halves (inventory + planning progress).
	var cmd := EditCommands.Composite.new([
		EditCommands.SetProfile.new(layout.profile, res["profile"], "Add bought items to inventory"),
		EditCommands.SetPlanning.new(layout.planning, res["plan"], "Add bought items to inventory"),
	], "Add %d bought copies to inventory" % n)
	ctx.session.execute(cmd)
	var assumed: Array = res["assumed"]
	var msg := "Added %d cop%s of %s to your inventory." % [n, "y" if n == 1 else "ies", PlanUiModels.plural(applied.size(), "item")]
	if not assumed.is_empty():
		msg += " %d had no recorded count: the copies on your real farm (or 0) were taken as the start." % assumed.size()
	ctx.toast(msg, "success")


func _export_csv() -> void:
	var nm := PlanUiModels.safe_file_stem(ctx.layout().name, "farm") + "_shopping.csv"
	var data := PlanUiModels.shop_csv(rows, supplies)
	PlanUiKit.save_file(self, "Export shopping list", PackedStringArray(["*.csv ; CSV spreadsheet"]), nm, func(p: String):
		var err := PlanUiKit.write_text(p, data)
		ctx.toast("Saved the shopping list to %s" % p if err.is_empty() else err, "success" if err.is_empty() else "error"))
