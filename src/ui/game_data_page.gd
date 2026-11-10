class_name GameDataPage
extends ScrollContainer
## Asset Manager > Game data: what private game data is installed (art pack,
## world data, client prices), how much of the catalogue it covers, problems,
## and the client-price import with its review queue (docs/research/CLIENT_PRICES.md).
## Nothing here is ever written into the project folder: the supplement, its
## report and your matching decisions live in user://private_data/.

## Written by tools/private_assets/validate_world.gd (WorldValidator.DEFAULT_PATH).
const WORLD_REPORT := "user://private_data/world_validation.json"

var _box: VBoxContainer
var _pending: Dictionary = {}     ## import result waiting for "Install"
var _review_filter := "all"
var _status: Label


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box = UI.vbox(12)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_box)
	refresh()


func refresh() -> void:
	UI.clear(_box)
	var intro := UI.hbox(8)
	var il := UI.label("Private data from your own game files makes the planner match the game. It stays in your private data folder and is never added to the project or shared.", "Dim", true)
	il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	intro.add_child(il)
	var of := UI.button("Open folder", "folder-open")
	of.tooltip_text = "The private data folder of this app (prices, reports, your decisions)"
	of.pressed.connect(func():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ClientPrices.DATA_DIR))
		OS.shell_open(ProjectSettings.globalize_path(ClientPrices.DATA_DIR)))
	intro.add_child(of)
	_box.add_child(intro)
	_status = UI.label("", "Dim", true)
	_box.add_child(_status)
	_box.add_child(_overview_card())
	_box.add_child(_prices_card())
	if not _pending.is_empty():
		_box.add_child(_pending_card())
	_box.add_child(_review_card())
	_box.add_child(_world_card())
	var diag := _diagnostics()
	if not diag.is_empty():
		var c := UI.card()
		var v := UI.vbox(4)
		c.add_child(v)
		v.add_child(UI.label("Problems", "Heading"))
		for d in diag:
			v.add_child(UI.label("• " + d, "", true))
		_box.add_child(c)


# --- overview ---------------------------------------------------------------------------------------

func _overview_card() -> PanelContainer:
	var c := UI.card()
	var v := UI.vbox(6)
	c.add_child(v)
	v.add_child(UI.label("Installed", "Heading"))
	var grid := _grid()
	var art := "none (built-in placeholders)"
	for p in App.assets.pack_list():
		if not p["builtin"]:
			art = "%s%s" % [str(p["name"]) if not str(p["name"]).is_empty() else str(p["id"]),
				(" (v%s)" % str(p["version"])) if not str(p["version"]).is_empty() else ""]
			break
	var mp: FarmMap = App.map
	var world := "public approximate map"
	if mp != null and mp.is_game_data():
		var gv := str(mp.provenance.get("client_version", mp.provenance.get("game_version", "")))
		world = "%s%s" % [mp.provenance_label(), (" (game %s)" % gv) if not gv.is_empty() else ""]
	var info: Dictionary = App.prices.client_info
	var prices := "none: prices come from public research (%d items) and your own corrections" % App.prices.price_db_count()
	if not info.is_empty():
		prices = "client prices for game %s (%d item%s, %d appearance part%s), imported %s" % [str(info["game_version"]),
			int(info["items"]), "" if int(info["items"]) == 1 else "s", int(info["components"]),
			"" if int(info["components"]) == 1 else "s", str(info["generated"]).left(10)]
	_kv(grid, "Art pack", art)
	_kv(grid, "World data", world)
	_kv(grid, "Prices", prices)
	_kv(grid, "Price order", "your corrections > your game files > public research > catalogue > unknown")
	_kv(grid, "Your corrections", "%d items" % App.prices.overrides().size())
	var fp := _corrected_footprints()
	if fp >= 0:
		_kv(grid, "Footprints from game data", "%d items" % fp)
	v.add_child(grid)
	return c


func _corrected_footprints() -> int:
	var n := 0
	for it: ItemDef in App.db.items.values():
		if it.footprint_status == "game_data":
			n += 1
	return n


# --- client prices ----------------------------------------------------------------------------------

func _prices_card() -> PanelContainer:
	var c := UI.card()
	var v := UI.vbox(8)
	c.add_child(v)
	var head := UI.hbox(8)
	head.add_child(UI.icon_rect("coins", 22, UiTheme.c("accent")))
	head.add_child(UI.label("Prices from your game files", "Heading"))
	head.add_child(UI.spacer())
	v.add_child(head)
	var rep: Variant = JsonUtil.read_json(ClientPrices.REPORT_PATH)
	if App.prices.has_client_data() and rep is Dictionary:
		var cov: Dictionary = rep.get("coverage", {})
		var st: Dictionary = rep.get("stats", {})
		var grid := _grid()
		_kv(grid, "Game version", str(rep.get("game_version", "?")))
		_kv(grid, "Client records", "%s (%s objects, %s appearance parts kept apart)" % [UI.fmt_int(int(st.get("records", 0))),
			UI.fmt_int(int(st.get("item_records", 0))), UI.fmt_int(int(st.get("component_records", 0)))])
		_kv(grid, "Matched to items", UI.fmt_int(App.prices.client_count()))
		_kv(grid, "Known prices", "%s before → %s now (%s new, %s confirmed, %s changed)" % [UI.fmt_int(int(cov.get("known_before", 0))),
			UI.fmt_int(int(cov.get("known_after", 0))), UI.fmt_int(int(cov.get("newly_priced", 0))),
			UI.fmt_int(int(cov.get("price_confirmed", 0))), UI.fmt_int(int(cov.get("price_changed", 0)))])
		_kv(grid, "Can't be bought", UI.fmt_int(int(cov.get("not_buyable_after", 0))))
		_kv(grid, "Still unknown", UI.fmt_int(int(cov.get("still_unknown", 0))))
		_kv(grid, "Needs your review", UI.fmt_int((rep.get("review", []) as Array).size()))
		v.add_child(grid)
	else:
		v.add_child(UI.label("Not installed. Import the data tables from your own Hay Day client (the folder with decorations.csv, deco_fences.csv, processing_buildings.csv, …) or a client price reference file. Matching uses your art pack's verified export names first, so install the art pack first when you have one.", "", true))
	var row := UI.hbox(8)
	var b1 := UI.button("Import tables folder…", "folder-open", "A folder with the game's data tables (assets/data)")
	b1.pressed.connect(func(): _pick(true))
	row.add_child(b1)
	var b2 := UI.button("Import reference file…", "upload", "A client price reference (.json)")
	b2.pressed.connect(func(): _pick(false))
	row.add_child(b2)
	var last := ClientPrices.last_source()
	if not last.is_empty():
		var b3 := UI.button("Re-import with my decisions", "rotate-cw", "Import %s again, applying your review decisions" % last)
		b3.pressed.connect(func(): run_import(last))
		row.add_child(b3)
	v.add_child(row)
	var row2 := UI.hbox(8)
	if FileAccess.file_exists(PriceBook.DEFAULT_CLIENT.get_basename() + ClientPrices.PREVIOUS_SUFFIX):
		var rb := UI.button("Restore previous", "undo-2", "Swap back to the supplement installed before this one")
		rb.pressed.connect(func():
			var r := ClientPrices.rollback()
			_after_change("Previous client prices restored" if r["ok"] else str(r["error"]), r["ok"]))
		row2.add_child(rb)
	if App.prices.has_client_data():
		var rm := UI.button("Remove", "trash", "Stop using client prices (kept as the previous version)")
		rm.pressed.connect(func():
			Modal.confirm(self, "Remove client prices?", "The planner goes back to public research and your corrections. You can restore it with “Restore previous”.", "Remove", true, func():
				ClientPrices.remove()
				_after_change("Client prices removed", true)))
		row2.add_child(rm)
	if FileAccess.file_exists(ClientPrices.REPORT_PATH.get_basename() + ".md"):
		var op := UI.button("Open report", "folder-open")
		op.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path(ClientPrices.REPORT_PATH.get_basename() + ".md")))
		row2.add_child(op)
	if row2.get_child_count() > 0:
		v.add_child(row2)
	return c


func _pick(folder: bool) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	if not folder:
		fd.filters = PackedStringArray(["*.json ; Client price reference"])
	fd.dir_selected.connect(run_import)
	fd.file_selected.connect(run_import)
	add_child(fd)
	fd.popup_centered_ratio(0.6)


func run_import(path: String) -> Dictionary:
	## Builds (does not install) the supplement from `path` and shows the result.
	var exports := ClientPrices.export_index_from_library(App.assets, App.db)
	var hints := ClientPrices.art_hints_from_library(App.assets, App.db)
	var res := ClientPrices.import_from(path, App.db, exports, App.prices.derived(null), App.client_build(), null,
		PriceBook.DEFAULT_CLIENT, hints)
	if not bool(res["ok"]):
		_pending = {}
		refresh()
		_set_status("Import failed: %s" % str(res["error"]), false)
		return res
	_pending = res
	_pending["path"] = path
	refresh()
	_set_status("Read %d client records. Check the summary below, then install." % int(res["doc"]["stats"]["records"]), true)
	return res


func _pending_card() -> PanelContainer:
	var c := UI.card()
	var v := UI.vbox(6)
	c.add_child(v)
	var rep: Dictionary = _pending["report"]
	var cov: Dictionary = rep["coverage"]
	var st: Dictionary = rep["stats"]
	v.add_child(UI.label("Ready to install: game %s" % str(rep["game_version"]), "Heading"))
	var grid := _grid()
	var by: Dictionary = st.get("by_rule", {})
	_kv(grid, "Matched", "%s items (export name %s · alias %s · game text %s · translation id %s · name %s · yours %s)" % [
		UI.fmt_int((_pending["doc"]["items"] as Dictionary).size()), by.get(ClientPrices.RULE_EXPORT, 0), by.get(ClientPrices.RULE_ALIAS, 0),
		by.get(ClientPrices.RULE_TEXT, 0), by.get(ClientPrices.RULE_TID, 0), by.get(ClientPrices.RULE_NAME, 0), by.get(ClientPrices.RULE_USER, 0)])
	_kv(grid, "Not applied", "%s ambiguous · %s unmatched · %s conflicting (all in the review list)" % [st.get("ambiguous", 0),
		st.get("unmatched", 0), st.get("conflicting_claims", 0)])
	_kv(grid, "Known prices", "%s → %s" % [UI.fmt_int(int(cov["known_before"])), UI.fmt_int(int(cov["known_after"]))])
	_kv(grid, "Changes", "%s new · %s confirmed · %s changed · %s researched prices the client does not list" % [cov["newly_priced"],
		cov["price_confirmed"], cov["price_changed"], cov["now_not_sold"]])
	if int(cov["override_shadows_client"]) > 0:
		_kv(grid, "Your corrections", "%d of your own prices stay in force over the client price" % int(cov["override_shadows_client"]))
	var prev: Dictionary = rep.get("previous", {})
	if not prev.is_empty():
		_kv(grid, "Replaces", "game %s (%d items; %d differ)" % [prev["game_version"], int(prev["items"]), int(prev["items_differing"])])
	v.add_child(grid)
	var row := UI.hbox(8)
	var ok := UI.button("Install", "check", "", "Accent")
	ok.pressed.connect(install_pending)
	row.add_child(ok)
	var no := UI.button("Discard", "x")
	no.pressed.connect(func():
		_pending = {}
		refresh())
	row.add_child(no)
	v.add_child(row)
	return c


func install_pending() -> bool:
	if _pending.is_empty():
		return false
	var r := ClientPrices.install(_pending["doc"], _pending["report"])
	if bool(r["ok"]):
		ClientPrices.set_last_source(str(_pending.get("path", "")))
	_pending = {}
	_after_change("Client prices installed" if r["ok"] else "Not installed: %s" % str(r["error"]), r["ok"])
	return bool(r["ok"])


func _after_change(msg: String, ok: bool) -> void:
	App.reload_client_prices()
	refresh()
	_set_status(msg, ok)
	App.toast(msg, "success" if ok else "error")


func _set_status(t: String, ok: bool) -> void:
	if _status != null:
		_status.text = t
		_status.add_theme_color_override("font_color", UiTheme.c("text_dim") if ok else UiTheme.c("danger"))


# --- review queue -----------------------------------------------------------------------------------

func review_rows() -> Array:
	## The review list shown: the pending import's, else the installed report's.
	var src: Variant = _pending.get("doc", {}).get("review") if not _pending.is_empty() else null
	if src == null:
		var rep: Variant = JsonUtil.read_json(ClientPrices.REPORT_PATH)
		src = rep.get("review", []) if rep is Dictionary and App.prices.has_client_data() else []
	return src if src is Array else []


func _review_card() -> PanelContainer:
	var c := UI.card()
	var v := UI.vbox(6)
	c.add_child(v)
	var rows := review_rows()
	var mapping := ClientPrices.load_mapping()
	var decided := 0
	for r: Dictionary in rows:
		if mapping.has(str(r.get("key", ""))):
			decided += 1
	var head := UI.hbox(8)
	head.add_child(UI.label("Review: client records not applied (%d · %d decided)" % [rows.size(), decided], "Heading"))
	head.add_child(UI.spacer())
	var flt := OptionButton.new()
	for f in [["all", "All"], ["choice", "Needs a choice (has candidates)"], ["priced", "With a price"], ["ambiguous", "Ambiguous"],
			["conflict", "Conflicting"], ["unmatched", "Unmatched"], ["decided", "Decided by you"]]:
		flt.add_item(f[1])
		flt.set_item_metadata(flt.item_count - 1, f[0])
		if f[0] == _review_filter:
			flt.select(flt.item_count - 1)
	flt.item_selected.connect(func(i):
		_review_filter = str(flt.get_item_metadata(i))
		refresh())
	head.add_child(flt)
	v.add_child(head)
	if rows.is_empty():
		v.add_child(UI.label("Nothing to review.", "Dim"))
		return c
	v.add_child(UI.label("A record is applied only when a reliable identifier matches. Compare the candidates side by side, pick the right item (or ignore the record), then use “Re-import with my decisions”. Records you have not decided stay unassigned: a wrong price is worse than an unknown one.", "Faint", true))
	var shown := 0
	for r: Dictionary in rows:
		if not _passes_filter(r, mapping):
			continue
		shown += 1
		if shown > 150:
			v.add_child(UI.label("… more records (narrow the filter)", "Faint"))
			break
		v.add_child(_review_row(r, mapping))
	if shown == 0:
		v.add_child(UI.label("No record matches this filter.", "Dim"))
	return c


func _passes_filter(r: Dictionary, mapping: Dictionary) -> bool:
	var kind := str(r.get("kind", ""))
	match _review_filter:
		"priced":
			return not (r.get("price", {}) as Dictionary).is_empty()
		"choice":
			return not (r.get("candidates", []) as Array).is_empty()
		"decided":
			return mapping.has(str(r.get("key", "")))
		"ambiguous", "conflict", "unmatched":
			return kind == _review_filter
	return true


func _review_row(r: Dictionary, mapping: Dictionary) -> PanelContainer:
	## One record: what the client says, its candidates side by side (picture,
	## name, id, size, price now) and the decision buttons.
	var key := str(r["key"])
	var dec := ClientPrices.decision_of(key, mapping)
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _row_style(str(dec["state"])))
	var v := UI.vbox(4)
	box.add_child(v)
	var top := UI.hbox(8)
	var fp: Variant = r.get("footprint")
	var title := str(r["name"])
	if not str(r.get("text", "")).is_empty() and str(r["text"]).to_lower() != title.to_lower():
		title += " — “%s”" % str(r["text"])
	var tl := UI.label(title, "", true)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl.tooltip_text = "Export: %s · TID: %s · record %s" % [str(r.get("export", "")), str(r.get("tid", "")), key]
	top.add_child(tl)
	top.add_child(_decision_badge(dec))
	v.add_child(top)
	var facts := "%s · %s · client size %s · client price %s" % [str(r.get("kind", "")), str(r["table"]),
		("%d×%d" % [int(fp[0]), int(fp[1])]) if fp is Array and (fp as Array).size() == 2 else "?",
		Currency.format_line(r["price"] if not (r["price"] as Dictionary).is_empty() else null, "free", "none")]
	v.add_child(UI.label(facts, "Faint", true))
	if not str(r.get("reason", "")).is_empty():
		v.add_child(UI.label(str(r["reason"]), "Faint", true))
	var extra: Array = []
	if str(dec["state"]) == "chosen" and not str(dec["item"]) in (r.get("candidates", []) as Array):
		extra.append(str(dec["item"]))
	var cands := ClientPrices.review_candidates(r, App.db, App.prices, extra)
	if not cands.is_empty():
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		for cd: Dictionary in cands:
			flow.add_child(_candidate_tile(key, cd, str(dec["state"]) == "chosen" and str(dec["item"]) == str(cd["id"])))
		v.add_child(flow)
	var act := UI.hbox(8)
	var other := UI.button("Other item…", "search", "Pick any catalogue item for this record")
	other.pressed.connect(func(): _pick_other(key, str(r.get("text", r["name"]))))
	act.add_child(other)
	if str(dec["state"]) != "ignored":
		var ig := UI.button("Ignore record", "eye-off", "This record is not a catalogue item (or not one you plan with)")
		ig.pressed.connect(func(): set_decision(key, ""))
		act.add_child(ig)
	if str(dec["state"]) != "unassigned":
		var cl := UI.button("Clear decision", "x", "Back to unassigned (nothing is applied)")
		cl.pressed.connect(func(): set_decision(key, null))
		act.add_child(cl)
	v.add_child(act)
	return box


func _candidate_tile(key: String, cd: Dictionary, chosen: bool) -> PanelContainer:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(240, 0)
	tile.add_theme_stylebox_override("panel", _row_style("chosen" if chosen else "tile"))
	var v := UI.vbox(2)
	tile.add_child(v)
	var tex := App.assets.get_thumbnail(str(cd["art_key"])) if App.assets != null else null
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = Vector2(64, 64)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		v.add_child(tr)
	var nm := UI.label(str(cd["name"]), "", true)
	v.add_child(nm)
	v.add_child(UI.label("%s%s" % [str(cd["id"]), " · from your game files" if bool(cd["added"]) else ""], "Faint", true))
	var fpv: Vector2i = cd["footprint"]
	var size_txt := "%d×%d %s" % [fpv.x, fpv.y, ItemDef.status_label(str(cd["footprint_status"])).to_lower()]
	var sl := UI.label(size_txt + ("" if cd["size_match"] == null else (" · same size as the record" if bool(cd["size_match"]) else " · NOT the record's size")), "Faint", true)
	if cd["size_match"] == false:
		sl.add_theme_color_override("font_color", UiTheme.c("warn"))
	v.add_child(sl)
	var origin := str({PriceBook.ORIGIN_CATALOGUE: "catalogue", PriceBook.ORIGIN_PRICE_DB: "public research",
		PriceBook.ORIGIN_CLIENT: "your game files", PriceBook.ORIGIN_USER: "your correction"}.get(str(cd["origin"]), ""))
	v.add_child(UI.label("Price now: %s%s" % [str(cd["price_text"]), (" (%s)" % origin) if not origin.is_empty() and cd["price"] != null else ""], "Faint", true))
	var b := UI.button("Chosen" if chosen else "Use this", "check" if chosen else "", "Map this record to %s" % str(cd["name"]), "Accent" if chosen else "")
	b.disabled = chosen
	b.pressed.connect(func(): set_decision(key, str(cd["id"])))
	v.add_child(b)
	return tile


func _decision_badge(dec: Dictionary) -> Control:
	match str(dec["state"]):
		"chosen":
			var it := App.db.get_item(str(dec["item"]))
			return UI.badge("→ %s" % (it.name if it else str(dec["item"])), UiTheme.c("accent"))
		"ignored":
			return UI.badge("Ignored", UiTheme.c("text_dim"))
	return UI.badge("Unassigned", UiTheme.c("warn"))


func _row_style(state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiTheme.c("panel_solid") if state != "tile" else UiTheme.c("panel_alt")
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	if state == "chosen":
		sb.border_color = UiTheme.c("accent")
		sb.set_border_width_all(2)
	return sb


func set_decision(key: String, to: Variant) -> void:
	## Saves the user's decision for a record (item id, "" = ignore, null = clear)
	## in client_price_mapping.json; it applies at the next (re-)import.
	var m := ClientPrices.load_mapping()
	if to == null:
		m.erase(key)
	else:
		m[key] = str(to)
	ClientPrices.save_mapping(m)
	refresh()
	_set_status("Saved. Use “Re-import with my decisions” to apply it.", true)


func _pick_other(key: String, query: String) -> void:
	var box := UI.vbox(6)
	box.custom_minimum_size = Vector2(420, 360)
	var q := LineEdit.new()
	q.placeholder_text = "Search the catalogue"
	q.text = query
	box.add_child(q)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list)
	var fill := func(t: String):
		list.clear()
		for it: ItemDef in App.db.search(t, {"include_hidden": true}).slice(0, 60):
			list.add_item("%s  (%s · %d×%d)" % [it.name, it.id, it.footprint.x, it.footprint.y])
			list.set_item_metadata(list.item_count - 1, it.id)
	q.text_changed.connect(fill)
	fill.call(query)
	var dlg := AcceptDialog.new()
	dlg.title = "Choose the catalogue item"
	dlg.ok_button_text = "Use selected"
	dlg.add_child(box)
	dlg.confirmed.connect(func():
		var sel := list.get_selected_items()
		if not sel.is_empty():
			set_decision(key, str(list.get_item_metadata(sel[0])))
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


# --- world --------------------------------------------------------------------------------------------

func _world_card() -> PanelContainer:
	var c := UI.card()
	var v := UI.vbox(6)
	c.add_child(v)
	v.add_child(UI.label("World check against your game's level data", "Heading"))
	var rep: Variant = JsonUtil.read_json(WORLD_REPORT)
	if not rep is Dictionary:
		v.add_child(UI.label("No check has been run. Run tools/private_assets/validate_world.gd with your client tables (see docs/research/WORLD_VALIDATION.md); its report appears here and in the Plan panel's Accuracy tab.", "Dim", true))
		return c
	var grid := _grid()
	_kv(grid, "Game version", str(rep.get("game_version", "?")))
	_kv(grid, "Checked", str(rep.get("generated", "")).left(19))
	var checks: Variant = rep.get("checks")
	if checks is Dictionary:
		var keys: Array = (checks as Dictionary).keys()
		keys.sort()
		for k in keys:
			var ch: Variant = checks[k]
			if ch is Dictionary:
				_kv(grid, str(ch.get("title", k)), "%s%s" % [str(ch.get("status", "?")).to_upper(),
					(" · " + str(ch.get("summary", ""))) if not str(ch.get("summary", "")).is_empty() else ""])
	elif checks is Array:
		for ch in checks:
			if ch is Dictionary:
				_kv(grid, str(ch.get("title", ch.get("id", "?"))), "%s%s" % [str(ch.get("status", "?")).to_upper(),
					(" · " + str(ch.get("summary", ""))) if not str(ch.get("summary", "")).is_empty() else ""])
	v.add_child(grid)
	return c


# --- diagnostics ----------------------------------------------------------------------------------

func _diagnostics() -> PackedStringArray:
	var out := PackedStringArray()
	for e in App.prices.errors:
		if "client" in e:
			out.append(e)
	var n := 0
	for w in App.prices.warnings:
		if "client" in w:
			n += 1
			if n <= 5:
				out.append(w)
	if n > 5:
		out.append("… %d more client price warnings" % (n - 5))
	var info: Dictionary = App.prices.client_info
	var build := App.client_build()
	if not info.is_empty() and not build.is_empty() and str(info.get("game_version", "")) != build:
		out.append("Client prices are for game %s but your art pack / world is from game %s." % [str(info["game_version"]), build])
	if FileAccess.file_exists(PriceBook.DEFAULT_CLIENT) and not App.prices.has_client_data():
		out.append("A client price file exists but could not be loaded: %s" % ProjectSettings.globalize_path(PriceBook.DEFAULT_CLIENT))
	return out


# --- helpers ------------------------------------------------------------------------------------------

func _grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 4)
	return g


func _kv(g: GridContainer, k: String, val: String) -> void:
	g.add_child(UI.label(k, "Dim"))
	var l := UI.label(val, "", true)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(l)
