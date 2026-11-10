class_name PriceDialog
extends PlanDialog
## Where an item's price comes from (catalogue / researched price file / your
## override, with sources and confidence) and the user's own override:
## price of the first copy per currency, the step per extra copy, how to get
## it, availability, confidence, source and notes. Save stores it with
## PriceBook.set_override + save_overrides (user://price_overrides.json, never
## in the repository); "Remove my override" brings the researched value back.
## Copies 1..10 are previewed for the current price and for the form.

const PREVIEW := 10

var item := ""
var _name := ""
var _current_box: VBoxContainer
var _layers_box: VBoxContainer
var _method: OptionButton
var _price_edits: Dictionary = {}
var _step_edits: Dictionary = {}
var _avail: OptionButton
var _conf: OptionButton
var _source: LineEdit
var _notes: LineEdit
var _error: Label
var _preview_l: Label
var _remove_btn: Button
var _scroll: ScrollContainer
var _shop_edits: Dictionary = {}
var _shop_msg: Label
## Confidence / availability go into the override only when the user picked
## them (or the override already had them): a note alone never changes them.
var _conf_set := false
var _avail_set := false


static func open(c: PlanContext, item_id: String) -> PriceDialog:
	var d := PriceDialog.new()
	d.setup(c, item_id)
	return d if d.present(c, "Price: %s" % d._name) else null


func setup(c: PlanContext, item_id: String) -> void:
	ctx = c
	preferred_width = 620.0
	item = c.db.resolve_id(item_id) if c.db != null else item_id
	var it: ItemDef = c.db.get_item(item) if c.db != null else null
	_name = it.name if it != null else item
	_build()
	_render_current()
	_load_form()


func _build() -> void:
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = 420
	var body := UI.vbox(10)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(body)
	add_child(_scroll)
	body.add_child(UI.section("Price used now"))
	var card := UI.card()
	_current_box = UI.vbox(4)
	card.add_child(_current_box)
	body.add_child(card)
	_layers_box = UI.vbox(2)
	body.add_child(_layers_box)
	body.add_child(UI.section("Price your shop shows now"))
	body.add_child(PlanUiKit.wrap_label("For items that get dearer with every purchase: enter the price the game shows for your next copy and the planner sets your purchase count to match, so later copies are priced from there.", "Faint"))
	var sh := UI.hbox(8)
	sh.add_child(_currency_grid(PlanUiModels.STEP_CURRENCIES, _shop_edits, false))
	var use := UI.button("Use this price", "check")
	use.pressed.connect(func(): apply_shop_price())
	sh.add_child(use)
	body.add_child(sh)
	_shop_msg = PlanUiKit.wrap_label("", "Dim")
	body.add_child(_shop_msg)
	body.add_child(UI.section("Your override"))
	body.add_child(PlanUiKit.wrap_label("Stored only on this PC, separate from the researched data. Leave the price empty to keep the researched price; setting a price replaces the researched price and step.", "Faint"))
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 6)
	g.add_child(_key_label("How to get"))
	_method = OptionButton.new()
	_method.focus_mode = Control.FOCUS_NONE
	_method.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_method.fit_to_longest_item = false
	_method.clip_text = true
	for m in PlanUiModels.FORM_METHODS:
		_method.add_item(str(PriceBook.METHOD_NAMES.get(m, m)))
	_method.item_selected.connect(func(_i: int): _update_preview())
	g.add_child(_method)
	g.add_child(_key_label("First copy"))
	g.add_child(_currency_grid(PlanUiModels.FORM_CURRENCIES, _price_edits))
	g.add_child(_key_label("+ per extra copy"))
	g.add_child(_currency_grid(PlanUiModels.STEP_CURRENCIES, _step_edits))
	g.add_child(_key_label("Availability"))
	_avail = OptionButton.new()
	_avail.focus_mode = Control.FOCUS_NONE
	_avail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for a in PriceBook.AVAILABILITY:
		_avail.add_item(PlanUiModels.availability_text(a))
	_avail.item_selected.connect(func(_i: int): _avail_set = true)
	g.add_child(_avail)
	g.add_child(_key_label("Confidence"))
	_conf = OptionButton.new()
	_conf.focus_mode = Control.FOCUS_NONE
	_conf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for cf in PriceBook.CONFIDENCE:
		_conf.add_item(str(cf).capitalize())
	_conf.tooltip_text = "How sure you are: Confirmed = you saw it in your game"
	_conf.item_selected.connect(func(_i: int): _conf_set = true)
	g.add_child(_conf)
	g.add_child(_key_label("Source"))
	_source = LineEdit.new()
	_source.placeholder_text = "e.g. seen in my shop on 2026-11-10, or a link"
	_source.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(_source)
	g.add_child(_key_label("Notes"))
	_notes = LineEdit.new()
	_notes.placeholder_text = "e.g. price shown when I owned 3 copies"
	_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(_notes)
	body.add_child(g)
	_error = PlanUiKit.wrap_label("", "Dim")
	_error.add_theme_color_override("font_color", UiTheme.c("danger"))
	_error.visible = false
	body.add_child(_error)
	_preview_l = PlanUiKit.wrap_label("", "Faint")
	body.add_child(_preview_l)
	make_footer()
	_remove_btn = add_footer_button("Remove my override", "", _remove, "trash")
	footer.add_child(UI.spacer())
	add_footer_button("Cancel", "", request_close)
	add_footer_button("Save override", "Accent", _save, "save")


func _fit(_vs: Vector2) -> void:
	_scroll.custom_minimum_size.y = list_height(0.62, 220.0, 620.0)


func _key_label(t: String) -> Label:
	var l := UI.label(t, "Dim")
	l.custom_minimum_size.x = 110
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _currency_grid(ids: Array, into: Dictionary, preview: bool = true) -> Control:
	var f := PlanUiKit.flow(8, 6)
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for cur: String in ids:
		var h := UI.hbox(4)
		var e := LineEdit.new()
		e.custom_minimum_size.x = 76
		e.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		e.placeholder_text = "–"
		e.select_all_on_focus = true
		if preview:
			e.text_changed.connect(func(_t: String): _update_preview())
		h.add_child(e)
		h.add_child(UI.label(Currency.name_of(cur).to_lower(), "Faint"))
		f.add_child(h)
		into[cur] = e
	return f


# --- current state --------------------------------------------------------------------------

func _render_current() -> void:
	UI.clear(_current_box)
	var pb := ctx.prices
	var rec := pb.resolved(item)
	var top := UI.hbox(8)
	top.add_child(PlanUiKit.wrap_label(_name, "Heading"))
	var origin := str(rec.get("origin", PriceBook.ORIGIN_NONE))
	top.add_child(PlanUiKit.badge(PlanUiModels.origin_text(origin), "info" if origin == PriceBook.ORIGIN_USER else ("faint" if origin == PriceBook.ORIGIN_NONE else "accent")))
	_current_box.add_child(top)
	_current_box.add_child(PlanUiKit.wrap_label(pb.method_text(item), "Dim"))
	for kv in PlanUiModels.record_lines(rec, pb):
		_current_box.add_child(UI.kv(str(kv[0]), str(kv[1])))
	_current_box.add_child(PlanUiKit.wrap_label(_preview_text(rec, "Copies 1–%d" % PREVIEW), "Faint"))
	UI.clear(_layers_box)
	var any := false
	for o in [[PriceBook.ORIGIN_CATALOGUE, "Item catalogue"], [PriceBook.ORIGIN_PRICE_DB, "Researched price file"],
			[PriceBook.ORIGIN_CLIENT, "Your game files (game %s)" % str(pb.client_info.get("game_version", "?"))], [PriceBook.ORIGIN_USER, "Your override"]]:
		var layer := pb.layer(item, str(o[0]))
		if layer.is_empty():
			continue
		any = true
		var n := PriceBook.normalize_record(layer, str(o[0])) if str(o[0]) == PriceBook.ORIGIN_USER else layer
		if str(o[0]) == PriceBook.ORIGIN_CLIENT and str(layer.get("client_status", "")) != PriceBook.CLIENT_PRICED:
			_layers_box.add_child(PlanUiKit.wrap_label("%s: %s" % [str(o[1]), "not sold in the regular shop" if str(layer.get("client_status")) == PriceBook.CLIENT_NOT_SOLD else "no price"], "Faint"))
			continue
		_layers_box.add_child(PlanUiKit.wrap_label("%s: %s" % [str(o[1]), _short(n)], "Faint"))
	if not any:
		_layers_box.add_child(PlanUiKit.wrap_label("No source has a price for this item: it stays unknown until you enter one.", "Faint"))
	_remove_btn.disabled = not pb.has_override(item)


func apply_shop_price(price: Variant = null) -> Dictionary:
	## Sets the purchase counter (profile.purchased) from the price the game shows
	## for the next copy (`price`, or the "Price your shop shows now" fields).
	## Returns PriceBook.copy_index_for_price()'s result.
	var cur := {}
	if price is Dictionary:
		cur = price
	else:
		for c in _shop_edits:
			var v := PlanUiModels.parse_count((_shop_edits[c] as LineEdit).text)
			if v > 0:
				cur[c] = v
	var r := ctx.prices.copy_index_for_price(item, cur)
	if cur.is_empty():
		_shop_msg.text = "Enter the price first."
		return r
	if int(r["copy"]) < 0:
		_shop_msg.text = "No copy of this item costs %s with the current price data. If the game's price really differs, enter it as your own price below." % Currency.format_line(cur)
		return r
	var lay := ctx.layout()
	if lay == null:
		return r
	var prof: Dictionary = lay.profile.duplicate(true)
	var purchased: Dictionary = (prof.get("purchased", {}) as Dictionary).duplicate()
	purchased[item] = int(r["purchases"])
	prof["purchased"] = purchased
	ctx.set_profile(prof, "Set purchase count of %s" % _name)
	if int(r["last"]) > int(r["copy"]):
		_shop_msg.text = "That is the price of copies %d–%s, so the game's counter is somewhere in that range; the planner now assumes %d bought (the cheapest case)." % [int(r["copy"]),
			"∞" if int(r["last"]) >= 100000 else str(int(r["last"])), int(r["purchases"])]
	else:
		_shop_msg.text = "That is copy #%d: the planner now counts %d bought, and prices your next copies from there." % [int(r["copy"]), int(r["purchases"])]
	_render_current()
	return r


func _short(rec: Dictionary) -> String:
	var m := str(rec.get("method", PriceBook.METHOD_UNKNOWN))
	var t := str(PriceBook.METHOD_NAMES.get(m, m))
	if m in PriceBook.COST_METHODS:
		t += ", " + Currency.format_line(PlanUiModels.copy_price_of(rec, 1))
		if rec.get("step") is Dictionary and not Currency.is_zero(rec["step"]):
			t += " + %s per copy" % Currency.format_line(rec["step"])
		elif rec.get("schedule") is Array:
			t += " (per-copy table)"
	return "%s · %s" % [t, str(rec.get("confidence", "unknown"))]


func _preview_text(rec: Dictionary, head: String) -> String:
	var parts: PackedStringArray = []
	for p: Dictionary in PlanUiModels.preview_copies(rec, PREVIEW):
		parts.append("#%d %s" % [int(p["copy"]), "?" if p["cost"] == null else Currency.format_line(p["cost"])])
	return "%s: %s" % [head, " · ".join(parts)]


# --- form ------------------------------------------------------------------------------------

func _load_form() -> void:
	var pb := ctx.prices
	var ov := pb.override(item)
	var rec := pb.resolved(item)
	var m := str(ov.get("method", rec.get("method", PriceBook.METHOD_SHOP)))
	_method.select(maxi(0, PlanUiModels.FORM_METHODS.find(m)))
	var price: Variant = Currency.normalize(ov.get("price")) if ov.has("price") else null
	var step: Variant = Currency.normalize(ov.get("step")) if ov.has("step") else null
	for cur in _price_edits:
		(_price_edits[cur] as LineEdit).text = str(int(price[cur])) if price is Dictionary and (price as Dictionary).has(cur) else ""
		var cur_price: Variant = PlanUiModels.copy_price_of(rec, 1)
		(_price_edits[cur] as LineEdit).placeholder_text = str(int(cur_price[cur])) if cur_price is Dictionary and (cur_price as Dictionary).has(cur) else "–"
	for cur in _step_edits:
		(_step_edits[cur] as LineEdit).text = str(int(step[cur])) if step is Dictionary and (step as Dictionary).has(cur) else ""
	var av := str(ov.get("availability", rec.get("availability", "unknown")))
	_avail.select(maxi(0, PriceBook.AVAILABILITY.find(av)))
	var cf := str(ov.get("confidence", "unverified"))
	_conf.select(maxi(0, PriceBook.CONFIDENCE.find(cf)))
	_conf_set = ov.has("confidence")
	_avail_set = ov.has("availability")
	var srcs: Array = ov.get("sources", []) if ov.get("sources") is Array else []
	_source.text = str(srcs[0]) if not srcs.is_empty() else ""
	_notes.text = str(ov.get("notes", ""))
	_update_preview()


func form() -> Dictionary:
	## The form as PlanUiModels.override_record() input; {"error": ...} when a
	## field is not a whole number >= 0.
	var price := {}
	var step := {}
	for pair in [[_price_edits, price], [_step_edits, step]]:
		for cur in pair[0]:
			var v := PlanUiModels.parse_count((pair[0][cur] as LineEdit).text)
			if v == -2:
				return {"error": "“%s” is not a whole number." % (pair[0][cur] as LineEdit).text}
			if v > 0:
				(pair[1] as Dictionary)[cur] = v
	var out := {"method": str(PlanUiModels.FORM_METHODS[maxi(0, _method.selected)]), "price": price, "step": step,
		"source": _source.text, "notes": _notes.text}
	if _avail_set:
		out["availability"] = str(PriceBook.AVAILABILITY[maxi(0, _avail.selected)])
	if _conf_set or not price.is_empty():
		out["confidence"] = str(PriceBook.CONFIDENCE[maxi(0, _conf.selected)])
	return out


func set_form(f: Dictionary) -> void:
	## Fills the form (tests / the self-test).
	_method.select(maxi(0, PlanUiModels.FORM_METHODS.find(str(f.get("method", "shop")))))
	for pair in [[_price_edits, f.get("price", {})], [_step_edits, f.get("step", {})]]:
		for cur in pair[0]:
			(pair[0][cur] as LineEdit).text = str(int(pair[1][cur])) if (pair[1] as Dictionary).has(cur) else ""
	if f.has("confidence"):
		_conf.select(maxi(0, PriceBook.CONFIDENCE.find(str(f["confidence"]))))
		_conf_set = true
	_source.text = str(f.get("source", ""))
	_notes.text = str(f.get("notes", ""))
	_update_preview()


func _update_preview() -> Dictionary:
	var f := form()
	if f.has("error"):
		_show_error(str(f["error"]))
		return {}
	var res := PlanUiModels.override_record(f)
	_show_error(str(res["error"]))
	if not str(res["error"]).is_empty():
		return {}
	var rec := PlanUiModels.resolve_with_override(PlanUiModels.base_record(ctx.prices, item), res["record"])
	_preview_l.text = _preview_text(rec, "With your override")
	return res["record"]


func _show_error(t: String) -> void:
	_error.text = t
	_error.visible = not t.is_empty()


func _save() -> void:
	var rec := _update_preview()
	if _error.visible:
		return
	ctx.prices.set_override(item, rec)
	var err := ctx.prices.save_overrides()
	ctx.toast("Saved your price for %s" % _name if err == OK else "Could not save price overrides: %s" % error_string(err),
		"success" if err == OK else "error")
	request_close()


func _remove() -> void:
	if not ctx.prices.has_override(item):
		return
	ctx.prices.remove_override(item)
	var err := ctx.prices.save_overrides()
	ctx.toast("Removed your price for %s: the researched value is used again" % _name if err == OK else "Could not save price overrides: %s" % error_string(err),
		"success" if err == OK else "error")
	_render_current()
	_load_form()
