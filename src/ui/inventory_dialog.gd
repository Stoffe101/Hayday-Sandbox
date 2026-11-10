class_name InventoryDialog
extends PlanDialog
## The player's inventory (docs/PLANNING.md §2): farm level, balances (coins,
## diamonds, vouchers, event currencies, expansion supplies) and per item the
## copies owned and bought so far. Edits a working copy; Apply writes it with
## one undoable SetProfile, Cancel discards it. An empty field means "not
## recorded" (unknown ownership), which is not the same as 0.
## Keyboard: type a number, Enter moves to the same field of the next row.

const PAGE := 80

var _prof: Dictionary = {}
var _used: Dictionary = {}
var _filter := "used"
var _level: SpinBox
var _bal_edits: Dictionary = {}
var _search: LineEdit
var _filter_opt: OptionButton
var _list: PlanUiKit.PagedList
var _scroll: ScrollContainer
var _status: Label
var _baseline_btn: Button

## Rows shown (PlanUiModels.inventory_rows), read by tests / the self-test.
var rows: Array = []


static func open(c: PlanContext) -> InventoryDialog:
	var d := InventoryDialog.new()
	d.setup(c)
	return d if d.present(c, "My inventory") else null


func setup(c: PlanContext) -> void:
	ctx = c
	preferred_width = 640.0
	_prof = c.layout().profile.duplicate(true) if c.layout() != null else {}
	_used = PlanUiModels.design_counts(c.layout(), c.db) if c.layout() != null else {}
	_build()
	_refresh_rows(true)


func working_profile() -> Dictionary:
	return _prof


func _build() -> void:
	add_child(PlanUiKit.wrap_label("What you have in Hay Day right now. Budgets count an item without a number as “to buy” and say so; fill in what you know.", "Faint"))
	var top := PlanUiKit.flow(12, 6)
	var lv := UI.hbox(6)
	lv.add_child(UI.label("Farm level", "Dim"))
	_level = SpinBox.new()
	_level.min_value = 1
	_level.max_value = 999
	_level.step = 1
	_level.rounded = true
	_level.value = int(_prof.get("level", 1))
	_level.value_changed.connect(func(v: float): _prof["level"] = int(v))
	lv.add_child(_level)
	top.add_child(lv)
	add_child(top)
	add_child(UI.section("Balances"))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	var bal: Dictionary = _prof.get("balances", {}) if _prof.get("balances") is Dictionary else {}
	for cur: String in Currency.ORDER:
		var l := UI.label(Currency.name_of(cur), "Dim")
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 60
		grid.add_child(l)
		var e := _num_edit("?", "Empty = not recorded")
		e.text = str(int(bal[cur])) if bal.has(cur) else ""
		var key := cur
		e.text_changed.connect(func(t: String): _set_balance(key, t, e))
		grid.add_child(e)
		_bal_edits[cur] = e
	add_child(grid)
	add_child(UI.section("Items"))
	var sr := UI.hbox(6)
	_search = LineEdit.new()
	_search.placeholder_text = "Search the catalogue"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.x = 80
	_search.text_changed.connect(func(_t: String): _refresh_rows(true))
	sr.add_child(_search)
	_filter_opt = OptionButton.new()
	_filter_opt.focus_mode = Control.FOCUS_NONE
	for k in PlanUiModels.INV_FILTERS:
		_filter_opt.add_item(str(PlanUiModels.INV_FILTER_NAMES[k]))
	_filter_opt.item_selected.connect(func(i: int):
		_filter = str(PlanUiModels.INV_FILTERS[i])
		_refresh_rows(true))
	sr.add_child(_filter_opt)
	add_child(sr)
	var hdr := UI.hbox(8)
	var hn := UI.label("Item", "Faint")
	hn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hn)
	for t in ["Owned", "Bought so far"]:
		var hl := UI.label(t, "Faint")
		hl.custom_minimum_size.x = 84
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hdr.add_child(hl)
	add_child(hdr)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = 260
	_list = PlanUiKit.PagedList.new(PAGE)
	_list.make = _make_row
	_list.bind = _bind_row
	_list.empty_text = "No items."
	_scroll.add_child(_list)
	add_child(_scroll)
	var acts := PlanUiKit.flow(6, 6)
	var fd := UI.button("Fill from this design", "layout-grid", "Owned = at least the copies this design uses (recorded counts are never lowered)")
	fd.pressed.connect(func():
		var n := PlanUiModels.fill_owned(_prof, _used, true)
		_after_fill("Filled %s from the design." % PlanUiModels.plural(n, "entry", "entries")))
	acts.add_child(fd)
	_baseline_btn = UI.button("Fill from my real farm", "house", "Owned = at least the copies standing on your real farm (baseline)")
	var bc := PlanUiModels.baseline_counts(ctx.plan(), ctx.db)
	_baseline_btn.disabled = bc.is_empty()
	if bc.is_empty():
		_baseline_btn.tooltip_text = "Take a snapshot of your real farm first (Plan › My real farm)"
	_baseline_btn.pressed.connect(func():
		var n := PlanUiModels.fill_owned(_prof, PlanUiModels.baseline_counts(ctx.plan(), ctx.db), true)
		_after_fill("Filled %s from your real farm." % PlanUiModels.plural(n, "entry", "entries")))
	acts.add_child(_baseline_btn)
	var imp := UI.button("Import…", "upload", "Read a CSV or JSON inventory file")
	imp.pressed.connect(_import)
	acts.add_child(imp)
	var ex := UI.button("Export CSV…", "download")
	ex.pressed.connect(func(): _export(".csv"))
	acts.add_child(ex)
	var ej := UI.button("Export JSON…", "download")
	ej.pressed.connect(func(): _export(".json"))
	acts.add_child(ej)
	add_child(acts)
	_status = PlanUiKit.wrap_label("", "Dim")
	_status.visible = false
	add_child(_status)
	make_footer()
	add_footer_button("Cancel", "", request_close)
	add_footer_button("Apply", "Accent", _apply, "check")


func _fit(_vs: Vector2) -> void:
	_scroll.custom_minimum_size.y = list_height(0.36, 140.0, 420.0)


func _num_edit(placeholder: String, tip: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.tooltip_text = tip
	e.custom_minimum_size.x = 84
	e.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	e.select_all_on_focus = true
	return e


func _mark_valid(e: LineEdit, ok: bool) -> void:
	if ok:
		e.remove_theme_color_override("font_color")
	else:
		e.add_theme_color_override("font_color", UiTheme.c("danger"))


func _set_balance(cur: String, t: String, e: LineEdit) -> void:
	var v := PlanUiModels.parse_count(t)
	_mark_valid(e, v != -2)
	if v != -2:
		PlanUiModels.set_count(_prof, "balances", cur, v)


# --- item rows ---------------------------------------------------------------------------------

func _make_row(_kind: String) -> Control:
	var h := UI.hbox(8)
	var info := UI.vbox(0)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := PlanUiKit.wrap_label("")
	info.add_child(nm)
	var sub := PlanUiKit.wrap_label("", "Faint")
	info.add_child(sub)
	h.add_child(info)
	var owned := _num_edit("?", "Copies you own (farm + storage). Empty = not recorded. Enter: next row")
	var bought := _num_edit("–", "Copies bought so far, for prices that rise per copy. Empty = same as owned. Enter: next row")
	h.add_child(owned)
	h.add_child(bought)
	h.set_meta("name", nm)
	h.set_meta("sub", sub)
	h.set_meta("owned", owned)
	h.set_meta("bought", bought)
	owned.text_changed.connect(func(t: String): _set_item(h, "owned", t, owned))
	bought.text_changed.connect(func(t: String): _set_item(h, "purchased", t, bought))
	owned.text_submitted.connect(func(_t: String): _focus_next(h, "owned"))
	bought.text_submitted.connect(func(_t: String): _focus_next(h, "bought"))
	return h


func _bind_row(c: Control, r: Dictionary, _i: int) -> void:
	c.set_meta("item", str(r["item"]))
	(c.get_meta("name") as Label).text = str(r["name"])
	var sub := PackedStringArray()
	if int(r["used"]) > 0:
		sub.append("used %d× in this design" % int(r["used"]))
	if not bool(r.get("known", true)):
		sub.append("not in the catalogue")
	(c.get_meta("sub") as Label).text = " · ".join(sub)
	(c.get_meta("sub") as Label).visible = not sub.is_empty()
	var o: LineEdit = c.get_meta("owned")
	var b: LineEdit = c.get_meta("bought")
	o.text = str(int(r["owned"])) if int(r["owned"]) >= 0 else ""
	b.text = str(int(r["purchased"])) if int(r["purchased"]) >= 0 else ""
	_mark_valid(o, true)
	_mark_valid(b, true)


func _set_item(c: Control, key: String, t: String, e: LineEdit) -> void:
	var item := str(c.get_meta("item", ""))
	if item.is_empty():
		return
	var v := PlanUiModels.parse_count(t)
	_mark_valid(e, v != -2)
	if v != -2:
		PlanUiModels.set_count(_prof, key, item, v)


func _focus_next(c: Control, field: String) -> void:
	var ws := _list.widgets()
	var i := ws.find(c)
	if i < 0:
		return
	if i + 1 >= ws.size() and _list.shown_count() < _list.entries.size():
		_list.limit += _list.page_size
		_list.rebind()
		ws = _list.widgets()
	if i + 1 < ws.size():
		var e: LineEdit = (ws[i + 1] as Control).get_meta(field)
		e.grab_focus()
		_scroll.ensure_control_visible(e)


func _refresh_rows(reset: bool) -> void:
	rows = PlanUiModels.inventory_rows(ctx.db, _prof, _used, _filter, _search.text if _search else "")
	match _filter:
		"used": _list.empty_text = "This design has no objects yet. Search the whole catalogue instead."
		"not_recorded": _list.empty_text = "Every item of this design has a recorded count."
		"recorded": _list.empty_text = "Nothing recorded yet."
		_: _list.empty_text = "No item matches."
	_list.set_entries(rows, reset)


func _after_fill(msg: String) -> void:
	_show_status([msg])
	_refresh_rows(false)


func _show_status(lines: Array) -> void:
	_status.text = "\n".join(PackedStringArray(lines))
	_status.visible = not lines.is_empty()


func _sync_balances() -> void:
	var bal: Dictionary = _prof.get("balances", {}) if _prof.get("balances") is Dictionary else {}
	for cur in _bal_edits:
		(_bal_edits[cur] as LineEdit).text = str(int(bal[cur])) if bal.has(cur) else ""
	_level.set_value_no_signal(int(_prof.get("level", 1)))


# --- import / export / apply --------------------------------------------------------------------

func _import() -> void:
	PlanUiKit.open_file(self, "Import inventory", PackedStringArray(["*.csv, *.json, *.txt ; Inventory (CSV or JSON)"]), import_file)


func import_file(path: String) -> Dictionary:
	## Reads an inventory file into the working copy; returns the import report.
	var text: Variant = PlanUiKit.read_text(path)
	if text == null:
		_show_status(["Could not read %s" % path])
		return {}
	return import_text(str(text))


func import_text(text: String) -> Dictionary:
	var rep := InventoryIO.import_text(text, ctx.db, _prof, false)
	if bool(rep.get("ok", false)):
		_prof = rep["profile"]
		_sync_balances()
		_refresh_rows(false)
	_show_status(PlanUiModels.import_report_lines(rep) + ["Nothing is saved until you press Apply."])
	return rep


func _export(ext: String) -> void:
	var nm := PlanUiModels.safe_file_stem(ctx.layout().name, "farm") + "_inventory" + ext
	var data := InventoryIO.export_csv(_prof, ctx.db) if ext == ".csv" else InventoryIO.export_json(_prof)
	var filt := "*.csv ; CSV spreadsheet" if ext == ".csv" else "*.json ; JSON"
	PlanUiKit.save_file(self, "Export inventory", PackedStringArray([filt]), nm, func(p: String):
		var err := PlanUiKit.write_text(p, data)
		_show_status(["Saved %s" % p if err.is_empty() else err]))


func _apply() -> void:
	if ctx.layout() != null and _prof != ctx.layout().profile:
		ctx.set_profile(_prof, "Edit inventory")
		ctx.toast("Inventory updated (Ctrl+Z undoes)", "success")
	request_close()
