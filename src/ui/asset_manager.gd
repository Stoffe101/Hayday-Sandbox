class_name AssetManager
extends VBoxContainer
## Asset Manager: browse which items have original art, compare it with the
## placeholder on the item's real footprint, fine-tune anchor/scale, pick the
## default variant, mark art verified or reject wrong matches, work through a
## pack's review queue, and inspect installed packs.
##
## Every edit is written to the pack's overrides.json through
## AssetLibrary.save_overrides()/assign_image() (pack.json is never touched)
## and the farm is refreshed via App.notify_art_changed().
## Opened from Settings, the top bar, the catalogue header and Ctrl+Shift+A.

signal install_requested

const FILTERS := [
	["all", "All"], ["original", "Original art"], ["placeholder", "Placeholder only"],
	["review", "Needs review"], ["rejected", "Rejected"], ["size", "Size unverified"],
]
const UNVERIFIED_SIZES := ["approximation", "unverified", "unknown"]
const COMMIT_DELAY := 0.6

var modal: Modal
var preview: PreviewCanvas
var item_list: ItemList
var review_list: ItemList
var tabs: TabBar
var filter := "all"
var category := ""
var selected_id := ""
var variant := ""
var view_mode := "original"         ## original | placeholder | onion

var _initial_item := ""
var _side_l := 330.0                ## column widths (narrower in small windows)
var _side_r := 350.0
var _flags: Dictionary = {}         ## item id -> {orig, ph, review, rej, size}
var _counts: Dictionary = {}
var _ids: Array[String] = []
var _icon_queue: Array = []
var _search: LineEdit
var _chips: Dictionary = {}
var _cat_btn: OptionButton
var _count_label: Label
var _summary: Label
var _pages: Array[Control] = []
var _detail: VBoxContainer
var _mode_btns: Dictionary = {}
var _zoom_label: Label
var _commit_timer: Timer
var _pending: Dictionary = {}       ## field -> value waiting for the debounce commit
var _status: Label
var _spin: Dictionary = {}          ## anchor_x, anchor_y, ppw, scale -> SpinBox
# current item
var _key := ""
var _orig_pack := ""                ## pack providing (or having rejected) original art
var _editable := false
var _anchor := Vector2.ZERO
var _ppw := 1.0
var _scale := 1.0
var _orig_tex: Texture2D
var _ph: AssetLibrary.SpriteInfo
# review queue
var _review_pack := ""
var _review_items: Array = []
var _review_rows: Array = []        ## row -> index into _review_items
var _review_sel := -1
var _review_icon_queue: Array = []
var _review_show_done := false
var _review_detail: VBoxContainer
var _review_image: ImageView
var _review_search: LineEdit
var _review_results: ItemList
var _review_result_ids: Array = []
var _review_pack_btn: OptionButton
var _review_progress: Label
var _packs_box: VBoxContainer


static func open(parent: Control, item_id: String = "") -> AssetManager:
	var vs := parent.get_viewport_rect().size
	var w := clampf(vs.x - 72.0, 900.0, 1720.0)
	var h := clampf(vs.y - 150.0, 420.0, 1000.0)
	var m := Modal.open(parent, "Asset manager", w, "image")
	var am := AssetManager.new()
	am.modal = m
	am._initial_item = item_id
	am.custom_minimum_size = Vector2(w - 48.0, h)
	am._side_l = clampf(w * 0.2, 250.0, 330.0)
	am._side_r = clampf(w * 0.21, 270.0, 350.0)
	am.size_flags_vertical = Control.SIZE_EXPAND_FILL
	m.set_meta("asset_manager", am)
	m.body.add_child(am)
	m.closed.connect(am.flush)
	return am


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	_commit_timer = Timer.new()
	_commit_timer.one_shot = true
	_commit_timer.wait_time = COMMIT_DELAY
	_commit_timer.timeout.connect(flush)
	add_child(_commit_timer)
	var head := UI.hbox(10)
	tabs = TabBar.new()
	tabs.add_tab("Items", Icons.get_icon("package-open", 16))
	tabs.add_tab("Review queue", Icons.get_icon("list-checks", 16))
	tabs.add_tab("Packs", Icons.get_icon("layers", 16))
	tabs.focus_mode = Control.FOCUS_NONE
	tabs.clip_tabs = false
	tabs.tab_changed.connect(_on_tab)
	head.add_child(tabs)
	head.add_child(UI.spacer())
	_summary = UI.label("", "Faint")
	head.add_child(_summary)
	var inst := UI.button("Install pack (.zip)…", "upload", "Install a prepared asset pack into your private data folder")
	inst.pressed.connect(func(): install_requested.emit())
	head.add_child(inst)
	add_child(head)
	var stack := Control.new()
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(stack)
	for page: Control in [_build_items_page(), _build_review_page(), _build_packs_page()]:
		stack.add_child(page)
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_pages.append(page)
	App.assets_reloaded.connect(_on_assets_reloaded)
	_recompute_flags()
	_refresh_list()
	var first := _initial_item if App.db.get_item(_initial_item) != null else ""
	if first.is_empty():
		for id in _ids:
			if not id.is_empty() and _flags[id]["orig"]:
				first = id
				break
	if first.is_empty() and not _ids.is_empty():
		first = _ids[0]
	select_item(first)
	_on_tab(0)


func _process(_dt: float) -> void:
	var budget := 16
	while budget > 0 and not _icon_queue.is_empty():
		var row: int = _icon_queue.pop_front()
		if row < _ids.size() and not _ids[row].is_empty():
			var it := App.db.get_item(_ids[row])
			var th := App.assets.get_thumbnail(it.art_key, "", UI.preview_mask(it))
			item_list.set_item_icon(row, th if th else Icons.get_icon("box", 40))
		budget -= 1
	budget = 4
	while budget > 0 and not _review_icon_queue.is_empty():
		var r: int = _review_icon_queue.pop_front()
		if r < _review_rows.size():
			var e: Dictionary = _review_items[_review_rows[r]]
			var tex := App.assets.pack_image(_review_pack, e["file"])
			review_list.set_item_icon(r, tex if tex else Icons.get_icon("image", 40))
		budget -= 1


func _on_tab(i: int) -> void:
	for k in _pages.size():
		_pages[k].visible = k == i
	if i == 1:
		_refresh_review()
	elif i == 2:
		_refresh_packs()
	_update_summary()


func show_tab(i: int) -> void:
	tabs.current_tab = i
	_on_tab(i)


func _on_assets_reloaded() -> void:
	_recompute_flags()
	_refresh_list()
	select_item(selected_id)
	if tabs.current_tab == 1:
		_refresh_review()
	elif tabs.current_tab == 2:
		_refresh_packs()


func _update_summary() -> void:
	var st := App.assets.stats(App.db)
	var user_packs := 0
	for p in App.assets.pack_list():
		if not p["builtin"]:
			user_packs += 1
	_summary.text = "%d art pack%s · original art for %s of %s items" % [user_packs, "" if user_packs == 1 else "s",
		UI.fmt_int(int(st["original"])), UI.fmt_int(int(st["items"]))]


# ---------------------------------------------------------------------------
# Items page
# ---------------------------------------------------------------------------

func _build_items_page() -> Control:
	var page := UI.hbox(14)
	# Left: search, filters, list.
	var left := UI.vbox(8)
	left.custom_minimum_size.x = _side_l
	_search = LineEdit.new()
	_search.placeholder_text = "Search items…"
	_search.right_icon = Icons.get_icon("search", 18)
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _refresh_list())
	left.add_child(_search)
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 5)
	chips.add_theme_constant_override("v_separation", 5)
	for f in FILTERS:
		var b := UI.button(f[1], "", "", "Chip")
		b.toggle_mode = true
		b.button_pressed = f[0] == filter
		b.pressed.connect(set_filter.bind(f[0]))
		_chips[f[0]] = b
		chips.add_child(b)
	left.add_child(chips)
	var row := UI.hbox(8)
	_cat_btn = OptionButton.new()
	_cat_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cat_btn.add_item("All categories")
	_cat_btn.set_item_metadata(0, "")
	for cat in App.db.categories:
		_cat_btn.add_item(str(cat["name"]))
		_cat_btn.set_item_metadata(_cat_btn.item_count - 1, cat["id"])
	_cat_btn.item_selected.connect(func(i):
		category = str(_cat_btn.get_item_metadata(i))
		_refresh_list())
	row.add_child(_cat_btn)
	_count_label = UI.label("", "Faint")
	row.add_child(_count_label)
	left.add_child(row)
	item_list = ItemList.new()
	item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_list.fixed_icon_size = Vector2i(40, 40)
	item_list.icon_mode = ItemList.ICON_MODE_LEFT
	item_list.max_columns = 1
	item_list.focus_mode = Control.FOCUS_CLICK
	item_list.item_selected.connect(func(i):
		if i < _ids.size() and not _ids[i].is_empty():
			select_item(_ids[i]))
	left.add_child(item_list)
	page.add_child(left)
	# Centre: preview with toolbar.
	var centre := UI.vbox(8)
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.custom_minimum_size.x = 240
	# Wraps onto two rows in small windows instead of widening the page.
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 6)
	bar.add_theme_constant_override("v_separation", 6)
	var seg := PanelContainer.new()
	seg.theme_type_variation = "SegmentBar"
	var sh := UI.hbox(2)
	seg.add_child(sh)
	for m in [["original", "Original", "image"], ["placeholder", "Placeholder", "box"], ["onion", "Onion skin", "layers"]]:
		var b := UI.button(m[1], m[2], "", "Segment")
		b.toggle_mode = true
		b.pressed.connect(set_view_mode.bind(m[0]))
		_mode_btns[m[0]] = b
		sh.add_child(b)
	bar.add_child(seg)
	var tools := UI.hbox(6)
	tools.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.alignment = BoxContainer.ALIGNMENT_END
	bar.add_child(tools)
	for t in [["scan", "Sprite bounds", "show_bounds"], ["crosshair", "Anchor (ground centre)", "show_anchor"], ["grid-3x3", "Surrounding tiles", "show_grid"]]:
		var tb := UI.icon_button(t[0], t[1])
		tb.toggle_mode = true
		tb.button_pressed = true
		tb.toggled.connect(func(on):
			preview.set(t[2], on)
			preview.queue_redraw())
		tools.add_child(tb)
	tools.add_child(VSeparator.new())
	var zo := UI.icon_button("zoom-out", "Zoom out (wheel)")
	zo.pressed.connect(func(): _zoom_by(1.0 / 1.25))
	tools.add_child(zo)
	_zoom_label = UI.label("100%", "Dim")
	_zoom_label.custom_minimum_size.x = 52
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tools.add_child(_zoom_label)
	var zi := UI.icon_button("zoom-in", "Zoom in (wheel)")
	zi.pressed.connect(func(): _zoom_by(1.25))
	tools.add_child(zi)
	var fit := UI.icon_button("maximize-2", "Fit")
	fit.pressed.connect(func():
		preview.fit()
		_zoom_label.text = "%d%%" % roundi(preview.zoom * 100.0))
	tools.add_child(fit)
	centre.add_child(bar)
	preview = PreviewCanvas.new()
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.anchor_dragged.connect(_on_anchor_dragged)
	preview.drag_finished.connect(func(): _queue_commit(0.05))
	preview.nudged.connect(nudge)
	preview.zoom_changed.connect(func(z): _zoom_label.text = "%d%%" % roundi(z * 100.0))
	centre.add_child(preview)
	centre.add_child(UI.label("Drag the art so its base sits on the tiles · arrow keys nudge 1 px (Shift: 10 px) · wheel zooms · right-drag pans", "Faint", true))
	page.add_child(centre)
	# Right: details and controls.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = _side_r
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail = UI.vbox(10)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_detail)
	page.add_child(scroll)
	return page


func set_filter(f: String) -> void:
	filter = f
	for k in _chips:
		_chips[k].button_pressed = k == f
	_refresh_list()


func set_view_mode(m: String) -> void:
	view_mode = m
	for k in _mode_btns:
		_mode_btns[k].button_pressed = k == m
	_update_preview()


func _zoom_by(f: float) -> void:
	preview.set_zoom(preview.zoom * f)


func _recompute_flags() -> void:
	var lib := App.assets
	_flags.clear()
	_counts = {}
	for f in FILTERS:
		_counts[f[0]] = 0
	for it: ItemDef in App.db.ordered:
		var st := lib.art_status(it.art_key)
		var fl := {"orig": st == "original", "ph": st != "original",
			"review": st == "original" and not lib.is_verified(it.art_key),
			"rej": lib.is_rejected(it.art_key), "size": it.footprint_status in UNVERIFIED_SIZES}
		_flags[it.id] = fl
		_counts["all"] += 1
		_counts["original"] += 1 if fl["orig"] else 0
		_counts["placeholder"] += 1 if fl["ph"] else 0
		_counts["review"] += 1 if fl["review"] else 0
		_counts["rejected"] += 1 if fl["rej"] else 0
		_counts["size"] += 1 if fl["size"] else 0
	for f in FILTERS:
		_chips[f[0]].text = "%s  %s" % [f[1], UI.fmt_int(_counts[f[0]])]


func _passes(id: String) -> bool:
	var fl: Dictionary = _flags.get(id, {})
	match filter:
		"original": return fl.get("orig", false)
		"placeholder": return fl.get("ph", false)
		"review": return fl.get("review", false)
		"rejected": return fl.get("rej", false)
		"size": return fl.get("size", false)
	return true


func _refresh_list() -> void:
	var filters := {}
	if not category.is_empty():
		filters["category"] = category
	var results := App.db.search(_search.text, filters, "name" if _search.text.strip_edges().is_empty() else "relevance")
	item_list.clear()
	_ids.clear()
	_icon_queue.clear()
	for it: ItemDef in results:
		if not _passes(it.id):
			continue
		var row := item_list.add_item(it.name, null)
		var fl: Dictionary = _flags.get(it.id, {})
		var tip := "%s\n%s · %d×%d tiles" % [it.name, it.id, it.footprint.x, it.footprint.y]
		if fl.get("rej", false):
			tip += "\nRejected — placeholder shown"
			item_list.set_item_custom_fg_color(row, UiTheme.c("danger"))
		elif fl.get("review", false):
			tip += "\nOriginal art · needs review"
		elif fl.get("orig", false):
			tip += "\nOriginal art · verified"
			item_list.set_item_custom_fg_color(row, UiTheme.c("accent"))
		item_list.set_item_tooltip(row, tip)
		_ids.append(it.id)
		_icon_queue.append(row)
		if it.id == selected_id:
			item_list.select(row)
	_count_label.text = "%s shown" % UI.fmt_int(_ids.size())
	if _ids.is_empty():
		var r := item_list.add_item("Nothing matches this filter.", null, false)
		item_list.set_item_disabled(r, true)
		_ids.append("")


func select_item(id: String) -> void:
	flush()
	selected_id = id
	variant = ""
	for i in _ids.size():
		if _ids[i] == id:
			item_list.select(i)
			item_list.ensure_current_is_visible()
	_load_current()


func _load_current() -> void:
	var lib := App.assets
	var it := App.db.get_item(selected_id)
	_key = it.art_key if it else ""
	_orig_pack = ""
	_orig_tex = null
	_ph = null
	_editable = false
	if it:
		var p := lib.pack_of(_key)
		if not p.is_empty() and not p["builtin"]:
			_orig_pack = p["id"]
		else:
			_orig_pack = lib.rejected_in(_key)
		if variant.is_empty() and not _orig_pack.is_empty():
			variant = lib.default_variant_of(_key)
		var mask := UI.preview_mask(it)
		_ph = lib.get_sprite_in_pack(lib.placeholder_pack_id(), _key, "", mask)
		if _ph:
			# Read-only values shown for placeholder-only items.
			var php := lib.pack_by_id(lib.placeholder_pack_id())
			var phe: Dictionary = php["sprites"].get(_key, {})
			_anchor = _ph.anchor
			_ppw = float(phe.get("pixels_per_world_px", php["ppw"]))
			_scale = float(phe.get("scale", 1.0))
		if not _orig_pack.is_empty():
			var spr := lib.get_sprite_in_pack(_orig_pack, _key, variant, mask, true)
			if spr:
				_orig_tex = spr.texture
				_anchor = spr.anchor
			var pk := lib.pack_by_id(_orig_pack)
			var e := _orig_entry()
			_ppw = float(e.get("pixels_per_world_px", pk.get("ppw", 1.0)))
			_scale = float(e.get("scale", 1.0))
			_editable = spr != null and bool(pk.get("writable", false)) and not lib.is_rejected(_key)
	_pending.clear()
	_build_detail(it)
	_update_preview()
	preview.fit()
	_zoom_label.text = "%d%%" % roundi(preview.zoom * 100.0)


func _orig_entry() -> Dictionary:
	## The (merged) pack entry being edited, resolved to the current variant.
	var p := App.assets.pack_by_id(_orig_pack)
	if p.is_empty():
		return {}
	var e: Variant = p["sprites"].get(_key, p["raw_sprites"].get(_key))
	if not e is Dictionary:
		return {}
	if not variant.is_empty() and e.get("variants") is Dictionary and (e["variants"] as Dictionary).get(variant) is Dictionary:
		var v: Dictionary = (e["variants"][variant] as Dictionary).duplicate()
		for f in ["pixels_per_world_px", "scale"]:
			if not v.has(f) and e.has(f):
				v[f] = e[f]
		return v
	return e


func _update_preview() -> void:
	var it := App.db.get_item(selected_id)
	preview.footprint = it.footprint if it else Vector2i.ONE
	preview.editable = _editable and view_mode != "placeholder"
	preview.layers.clear()
	var ph_layer := {}
	if _ph:
		ph_layer = {"tex": _ph.texture, "anchor": _ph.anchor, "scale": _ph.scale, "label": "Placeholder"}
	var orig_layer := {}
	if _orig_tex:
		orig_layer = {"tex": _orig_tex, "anchor": _anchor, "scale": 1.0 / maxf(0.01, _ppw) * _scale, "label": "Original", "active": true}
	match view_mode:
		"placeholder":
			if not ph_layer.is_empty():
				ph_layer["active"] = true
				preview.layers.append(ph_layer)
		"onion":
			if not ph_layer.is_empty():
				ph_layer["modulate"] = Color(0.55, 0.78, 1.0, 0.55)
				preview.layers.append(ph_layer)
			if not orig_layer.is_empty():
				orig_layer["modulate"] = Color(1, 1, 1, 0.72)
				preview.layers.append(orig_layer)
		_:
			if not orig_layer.is_empty():
				preview.layers.append(orig_layer)
			elif not ph_layer.is_empty():
				ph_layer["active"] = true
				preview.layers.append(ph_layer)
	var note := ""
	if it == null:
		note = "Choose an item"
	elif view_mode != "placeholder" and _orig_tex == null:
		note = "No original art for this item — showing the placeholder"
	elif App.assets.is_rejected(_key) and view_mode != "placeholder":
		note = "Rejected: the farm shows the placeholder"
	preview.note = note
	preview.queue_redraw()
	for k in _mode_btns:
		_mode_btns[k].button_pressed = k == view_mode


func _build_detail(it: ItemDef) -> void:
	UI.clear(_detail)
	_spin.clear()
	if it == null:
		_detail.add_child(UI.label("Choose an item on the left.", "Dim", true))
		return
	var lib := App.assets
	var card := UI.card()
	var cv := UI.vbox(6)
	card.add_child(cv)
	var top := UI.hbox(10)
	var th := TextureRect.new()
	th.texture = lib.get_thumbnail(_key, "", UI.preview_mask(it))
	th.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	th.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	th.custom_minimum_size = Vector2(64, 64)
	top.add_child(th)
	var info := UI.vbox(2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label(it.name, "Heading", true))
	info.add_child(UI.label(it.id, "Faint"))
	top.add_child(info)
	cv.add_child(top)
	var badges := HFlowContainer.new()
	badges.add_theme_constant_override("h_separation", 4)
	badges.add_theme_constant_override("v_separation", 4)
	var rejected := lib.is_rejected(_key)
	badges.add_child(UI.art_badge("original" if not _orig_pack.is_empty() else lib.art_status(_key)))
	if rejected:
		badges.add_child(UI.badge("Rejected", UiTheme.c("danger")))
	elif not _orig_pack.is_empty():
		if lib.is_verified(_key):
			badges.add_child(UI.badge("Verified", UiTheme.c("accent")))
		else:
			badges.add_child(UI.badge("Needs review", UiTheme.c("warn")))
	badges.add_child(UI.badge(UI.status_text(it.footprint_status), UI.status_color(it.footprint_status)))
	cv.add_child(badges)
	cv.add_child(UI.kv("Footprint", "%d × %d tiles" % [it.footprint.x, it.footprint.y]))
	cv.add_child(UI.kv("Category", str(App.db.category(it.category).get("name", it.category))))
	if not _orig_pack.is_empty():
		var p := lib.pack_by_id(_orig_pack)
		cv.add_child(UI.kv("Pack", "%s%s" % [p["name"] if not str(p["name"]).is_empty() else p["id"], (" v" + str(p["version"])) if not str(p["version"]).is_empty() else ""]))
		var e := _orig_entry()
		cv.add_child(UI.kv("File", str(e.get("file", "—"))))
		if _orig_tex:
			var ws := _orig_tex.get_size() / maxf(0.01, _ppw) * _scale
			cv.add_child(UI.kv("Image", "%d × %d px  →  %d × %d on the farm" % [_orig_tex.get_width(), _orig_tex.get_height(), roundi(ws.x), roundi(ws.y)]))
		if bool(e.get("auto_anchor", false)):
			cv.add_child(UI.label("Anchor and scale were estimated automatically — check them against the tiles.", "Faint", true))
	_detail.add_child(card)
	# Variants
	var vars := lib.variants_of(_key) if not rejected else []
	if not vars.is_empty() and not _orig_pack.is_empty():
		_detail.add_child(UI.section("Variant"))
		var vrow := UI.hbox(6)
		var ob := OptionButton.new()
		ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var defv := lib.default_variant_of(_key)
		ob.add_item("Base image")
		ob.set_item_metadata(0, AssetLibrary.BASE_VARIANT if not defv.is_empty() else "")
		for v in vars:
			ob.add_item(InspectorPanel._variant_name(it, v))
			ob.set_item_metadata(ob.item_count - 1, v)
			if v == variant:
				ob.selected = ob.item_count - 1
		ob.item_selected.connect(func(i): set_variant(str(ob.get_item_metadata(i))))
		vrow.add_child(ob)
		var is_base := variant.is_empty() or variant == AssetLibrary.BASE_VARIANT
		var is_def := defv == variant or (defv.is_empty() and is_base)
		var mk := UI.button("Is default" if is_def else "Make default", "star", "Use this appearance when a placed object has no variant chosen")
		mk.disabled = is_def or not _editable
		mk.pressed.connect(func(): _save({"default_variant": null if is_base else variant}, ""))
		vrow.add_child(mk)
		_detail.add_child(vrow)
	# Placement
	_detail.add_child(UI.section("Placement"))
	var pc := UI.card()
	var pv := UI.vbox(8)
	pc.add_child(pv)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	for f in [["anchor_x", "Anchor X (px)", -4096.0, 8192.0, 0.5, _anchor.x], ["anchor_y", "Anchor Y (px)", -4096.0, 8192.0, 0.5, _anchor.y],
			["ppw", "Pixels per world px", 0.05, 64.0, 0.01, _ppw], ["scale", "Scale ×", 0.05, 8.0, 0.01, _scale]]:
		grid.add_child(UI.label(f[1], "Dim"))
		var sb := SpinBox.new()
		sb.min_value = f[2]
		sb.max_value = f[3]
		sb.step = f[4]
		sb.value = f[5]
		sb.custom_minimum_size.x = 130
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.editable = _editable
		sb.value_changed.connect(_on_spin.bind(f[0]))
		_spin[f[0]] = sb
		grid.add_child(sb)
	pv.add_child(grid)
	var prow := HFlowContainer.new()
	prow.add_theme_constant_override("h_separation", 6)
	prow.add_theme_constant_override("v_separation", 6)
	var reset := UI.button("Reset", "undo-2", "Remove your anchor/scale changes for this image")
	reset.disabled = not _editable
	reset.pressed.connect(func(): _save({"anchor": null, "pixels_per_world_px": null, "scale": null}, variant))
	prow.add_child(reset)
	var cat := UI.button("Apply scale to category", "layers", "Use this scale for every item of this category that has art in the same pack")
	cat.disabled = not _editable
	cat.pressed.connect(apply_scale_to_category.bind(true))
	prow.add_child(cat)
	pv.add_child(prow)
	if not _editable:
		var why := "Placeholder art is built in and can't be edited here. Install an asset pack or assign an image in the Review queue."
		if rejected:
			why = "This image was rejected — the farm shows the placeholder. Restore it to edit."
		elif not _orig_pack.is_empty() and not bool(lib.pack_by_id(_orig_pack).get("writable", false)):
			why = "This pack is read-only."
		pv.add_child(UI.label(why, "Faint", true))
	_detail.add_child(pc)
	# Review decision
	if not _orig_pack.is_empty():
		_detail.add_child(UI.section("Review"))
		var rv := UI.vbox(6)
		if rejected:
			var restore := UI.button("Restore original art", "rotate-cw", "Undo “wrong match”", "Accent")
			restore.pressed.connect(func(): _save({"rejected": null}, ""))
			rv.add_child(restore)
		else:
			var ver := lib.is_verified(_key)
			var vb := UI.button("Verified — undo" if ver else "Mark verified", "check", "The art, anchor and scale look right on the tiles", "" if ver else "Accent")
			vb.disabled = not _editable
			vb.pressed.connect(mark_verified.bind(not ver))
			rv.add_child(vb)
			var wb := UI.button("Wrong match (use placeholder)", "circle-x", "This image isn't this item: ignore it and show the placeholder", "Danger")
			wb.disabled = not _editable
			wb.pressed.connect(reject)
			rv.add_child(wb)
		_detail.add_child(rv)
	_status = UI.label("", "Faint", true)
	_detail.add_child(_status)


func set_variant(v: String) -> void:
	flush()
	variant = v
	var keep := view_mode
	_load_current()
	set_view_mode(keep)


func _on_spin(value: float, field: String) -> void:
	match field:
		"anchor_x":
			_anchor.x = value
			_pending["anchor"] = [_anchor.x, _anchor.y]
		"anchor_y":
			_anchor.y = value
			_pending["anchor"] = [_anchor.x, _anchor.y]
		"ppw":
			_ppw = value
			_pending["pixels_per_world_px"] = value
		"scale":
			_scale = value
			_pending["scale"] = value
	_update_preview()
	_queue_commit(COMMIT_DELAY)


func _on_anchor_dragged(a: Vector2) -> void:
	set_art_anchor(a, false)


func set_art_anchor(a: Vector2, commit: bool = true) -> void:
	if not _editable:
		return
	_anchor = Vector2(snappedf(a.x, 0.5), snappedf(a.y, 0.5))
	_pending["anchor"] = [_anchor.x, _anchor.y]
	_sync_spins()
	_update_preview()
	if commit:
		_queue_commit(COMMIT_DELAY)


func nudge(d: Vector2) -> void:
	## Arrow keys: move the art by d texture px (the anchor moves opposite).
	set_art_anchor(_anchor - d)


func _sync_spins() -> void:
	if _spin.has("anchor_x"):
		_spin["anchor_x"].set_value_no_signal(_anchor.x)
		_spin["anchor_y"].set_value_no_signal(_anchor.y)


func _queue_commit(delay: float) -> void:
	_commit_timer.start(delay)


func flush() -> void:
	## Writes pending anchor/scale edits (debounced while dragging/nudging).
	if _commit_timer:
		_commit_timer.stop()
	if _pending.is_empty() or _orig_pack.is_empty() or _key.is_empty():
		_pending.clear()
		return
	var changes := _pending.duplicate()
	_pending.clear()
	_save(changes, variant, false)


func _variant_target(v: String) -> String:
	## Variant overrides only apply when the pack really has that variant.
	var p := App.assets.pack_by_id(_orig_pack)
	var e: Variant = p.get("raw_sprites", {}).get(_key) if not p.is_empty() else null
	if v.is_empty() or v == AssetLibrary.BASE_VARIANT or not e is Dictionary or not e.get("variants") is Dictionary or not (e["variants"] as Dictionary).has(v):
		return ""
	return v


func _save(changes: Dictionary, v: String, rebuild: bool = true) -> Error:
	if _orig_pack.is_empty():
		return ERR_UNAVAILABLE
	var err := App.assets.save_overrides(_orig_pack, _key, changes, _variant_target(v))
	if err != OK:
		App.toast("Could not save overrides: %s" % error_string(err), "error")
		return err
	App.notify_art_changed([_key])
	if rebuild:
		var keep_mode := view_mode
		_recompute_flags()
		_refresh_list()
		_load_current()
		set_view_mode(keep_mode)
	if is_instance_valid(_status):
		_status.text = "Saved to %s/overrides.json" % _orig_pack
	return OK


func mark_verified(on: bool = true) -> void:
	flush()
	_save({"verified": on}, "")   # false is kept: it also un-verifies art the pack itself marks as verified
	if on:
		App.toast("Marked “%s” as verified" % _name(selected_id), "success")
		_advance_if_hidden()


func reject() -> void:
	flush()
	_save({"rejected": true}, "")
	App.toast("“%s” now uses the placeholder (restore it any time)" % _name(selected_id), "info")
	_advance_if_hidden()


func _advance_if_hidden() -> void:
	## In a review-style filter the decided item drops out: move to the next one.
	if selected_id in _ids or _ids.is_empty() or _ids[0].is_empty():
		return
	select_item(_ids[0])


func _name(id: String) -> String:
	var it := App.db.get_item(id)
	return it.name if it else id


func apply_scale_to_category(confirm: bool = true) -> int:
	## Sets this item's scale on every item of the same category whose art
	## comes from the same pack. Returns how many sprites were changed.
	flush()
	var it := App.db.get_item(selected_id)
	if it == null or _orig_pack.is_empty() or not _editable:
		return 0
	var keys := {}
	for other: ItemDef in App.db.ordered:
		if other.category == it.category and App.assets.art_source(other.art_key) == _orig_pack:
			keys[other.art_key] = {"scale": _scale}
	var cat_name := str(App.db.category(it.category).get("name", it.category))
	var run := func() -> void:
		var err := App.assets.save_overrides_many(_orig_pack, keys)
		if err != OK:
			App.toast("Could not save overrides: %s" % error_string(err), "error")
			return
		App.notify_art_changed(keys.keys())
		App.toast("Scale ×%.2f applied to %d %s sprite%s" % [_scale, keys.size(), cat_name, "" if keys.size() == 1 else "s"], "success")
		_load_current()
	if confirm:
		Modal.confirm(modal.get_parent() as Control, "Apply scale to category?", "Set scale ×%.2f for %d item%s in “%s” with art from this pack? Anchors are kept." % [_scale, keys.size(), "" if keys.size() == 1 else "s", cat_name], "Apply", false, run)
	else:
		run.call()
	return keys.size()


# ---------------------------------------------------------------------------
# Review queue
# ---------------------------------------------------------------------------

func _build_review_page() -> Control:
	var page := UI.hbox(14)
	var left := UI.vbox(8)
	left.custom_minimum_size.x = _side_l
	_review_pack_btn = OptionButton.new()
	_review_pack_btn.item_selected.connect(func(i):
		_review_pack = str(_review_pack_btn.get_item_metadata(i))
		_review_sel = -1
		_refresh_review())
	left.add_child(_review_pack_btn)
	var row := UI.hbox(8)
	_review_progress = UI.label("", "Dim")
	_review_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_review_progress)
	var done := CheckButton.new()
	done.text = "Show assigned"
	done.toggled.connect(func(on):
		_review_show_done = on
		_refresh_review())
	row.add_child(done)
	left.add_child(row)
	review_list = ItemList.new()
	review_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	review_list.fixed_icon_size = Vector2i(48, 48)
	review_list.max_columns = 1
	review_list.item_selected.connect(func(i): select_review(i))
	left.add_child(review_list)
	page.add_child(left)
	var centre := UI.vbox(8)
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_review_image = ImageView.new()
	_review_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_child(_review_image)
	_review_detail = UI.vbox(4)
	centre.add_child(_review_detail)
	page.add_child(centre)
	var right := UI.vbox(8)
	right.custom_minimum_size.x = _side_r
	right.add_child(UI.section("Assign to item"))
	_review_search = LineEdit.new()
	_review_search.placeholder_text = "Search all items…"
	_review_search.right_icon = Icons.get_icon("search", 18)
	_review_search.clear_button_enabled = true
	_review_search.text_changed.connect(func(_t): _fill_review_results())
	right.add_child(_review_search)
	_review_results = ItemList.new()
	_review_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_review_results.fixed_icon_size = Vector2i(36, 36)
	_review_results.max_columns = 1
	_review_results.item_activated.connect(func(i): _assign_row(i))
	right.add_child(_review_results)
	var brow := UI.hbox(6)
	var asg := UI.button("Assign", "check", "Use this image for the chosen item", "Accent")
	asg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	asg.pressed.connect(func():
		var sel := _review_results.get_selected_items()
		if not sel.is_empty():
			_assign_row(sel[0]))
	brow.add_child(asg)
	var skip := UI.button("Skip", "", "Leave this image for later")
	skip.pressed.connect(func(): _review_next(true))
	brow.add_child(skip)
	var un := UI.button("Unassign", "x", "Remove the assignment of this image")
	un.pressed.connect(func(): assign_review_to(""))
	brow.add_child(un)
	right.add_child(brow)
	page.add_child(right)
	return page


func _refresh_review() -> void:
	var lib := App.assets
	var rp := lib.review_packs()
	_review_pack_btn.clear()
	for id in rp:
		var p := lib.pack_by_id(id)
		_review_pack_btn.add_item("%s — %d images" % [p["name"] if not str(p["name"]).is_empty() else id, lib.review_queue(id).size()])
		_review_pack_btn.set_item_metadata(_review_pack_btn.item_count - 1, id)
	if not _review_pack in rp:
		_review_pack = rp[0] if not rp.is_empty() else ""
		_review_sel = -1
	_review_pack_btn.visible = rp.size() > 1
	for i in _review_pack_btn.item_count:
		if _review_pack_btn.get_item_metadata(i) == _review_pack:
			_review_pack_btn.selected = i
	tabs.set_tab_title(1, "Review queue" + (" (%d)" % _open_review_count() if not rp.is_empty() else ""))
	_review_items = lib.review_queue(_review_pack) if not _review_pack.is_empty() else []
	review_list.clear()
	_review_rows.clear()
	_review_icon_queue.clear()
	var assigned := 0
	for i in _review_items.size():
		var e: Dictionary = _review_items[i]
		var who := str(e["assigned"])
		if not who.is_empty():
			assigned += 1
			if not _review_show_done:
				continue
		var label := str(e["file"]).get_file()
		if not who.is_empty():
			label += "  →  " + _name(who)
		var r := review_list.add_item(label, null)
		review_list.set_item_tooltip(r, "%s\n%s" % [e["file"], e["reason"]])
		if not who.is_empty():
			review_list.set_item_custom_fg_color(r, UiTheme.c("accent"))
		_review_rows.append(i)
		_review_icon_queue.append(r)
	_review_progress.text = "%d of %d assigned" % [assigned, _review_items.size()] if not _review_items.is_empty() else ""
	if _review_items.is_empty():
		UI.clear(_review_detail)
		_review_image.texture = null
		_review_image.note = "No review queue"
		_review_detail.add_child(UI.label("Nothing to review", "Heading"))
		_review_detail.add_child(UI.label("A pack can ship a review.json listing images that couldn't be matched to an item automatically. They show up here so you can assign each one with a search.", "Dim", true))
		_review_image.queue_redraw()
		_fill_review_results()
		return
	var target := -1
	for r in _review_rows.size():
		if _review_rows[r] == _review_sel:
			target = r
	if target < 0 and not _review_rows.is_empty():
		target = 0
	if target >= 0:
		review_list.select(target)
		select_review(target)
	else:
		_review_sel = -1
		UI.clear(_review_detail)
		_review_image.texture = null
		_review_image.note = "All images are assigned"
		_review_image.queue_redraw()
		_fill_review_results()


func _open_review_count() -> int:
	var n := 0
	for id in App.assets.review_packs():
		for e in App.assets.review_queue(id):
			if str(e["assigned"]).is_empty():
				n += 1
	return n


func select_review(row: int) -> void:
	if row < 0 or row >= _review_rows.size():
		return
	_review_sel = _review_rows[row]
	var e: Dictionary = _review_items[_review_sel]
	var tex := App.assets.pack_image(_review_pack, e["file"])
	_review_image.texture = tex
	_review_image.note = "" if tex else "Image missing: %s" % e["file"]
	_review_image.queue_redraw()
	UI.clear(_review_detail)
	var head := UI.hbox(8)
	var nl := UI.label(str(e["file"]).get_file(), "Heading")
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nl.clip_text = true
	head.add_child(nl)
	if not str(e["assigned"]).is_empty():
		head.add_child(UI.badge("→ " + _name(e["assigned"]), UiTheme.c("accent")))
	_review_detail.add_child(head)
	var meta := str(e["file"])
	if tex:
		meta += "  ·  %d × %d px" % [tex.get_width(), tex.get_height()]
	_review_detail.add_child(UI.label(meta, "Faint", true))
	if not str(e["reason"]).is_empty():
		_review_detail.add_child(UI.label(str(e["reason"]), "Dim", true))
	_fill_review_results()


func _fill_review_results() -> void:
	_review_results.clear()
	_review_result_ids.clear()
	var seen := {}
	if _review_sel >= 0 and _review_sel < _review_items.size() and _review_search.text.strip_edges().is_empty():
		for sid in _review_items[_review_sel]["suggestions"]:
			var it := App.db.get_item(sid)
			if it and not seen.has(it.id):
				seen[it.id] = true
				_add_result(it, "Suggested · ")
	var q := _review_search.text.strip_edges()
	if not q.is_empty():
		var n := 0
		for it: ItemDef in App.db.search(q, {}, "relevance"):
			if seen.has(it.id):
				continue
			_add_result(it, "")
			n += 1
			if n >= 60:
				break
	if _review_results.item_count == 0:
		var r := _review_results.add_item("Type to search 1,900+ items…" if q.is_empty() else "No items match “%s”" % q, null, false)
		_review_results.set_item_disabled(r, true)
		_review_result_ids.append("")
	elif _review_results.item_count > 0:
		_review_results.select(0)


func _add_result(it: ItemDef, prefix: String) -> void:
	var th := App.assets.get_thumbnail(it.art_key, "", UI.preview_mask(it))
	var r := _review_results.add_item("%s%s  (%d×%d)" % [prefix, it.name, it.footprint.x, it.footprint.y], th)
	_review_results.set_item_tooltip(r, it.id)
	_review_result_ids.append(it.id)


func _assign_row(row: int) -> void:
	if row >= 0 and row < _review_result_ids.size() and not str(_review_result_ids[row]).is_empty():
		assign_review_to(_review_result_ids[row])


func assign_review_to(item_id: String) -> Error:
	## Assigns the selected review image to an item ("" un-assigns).
	if _review_sel < 0 or _review_pack.is_empty():
		return ERR_UNAVAILABLE
	var e: Dictionary = _review_items[_review_sel]
	var old := str(e["assigned"])
	var err := App.assets.assign_image(_review_pack, e["file"], item_id)
	if err != OK:
		App.toast("Could not assign: %s" % error_string(err), "error")
		return err
	var keys: Array = []
	for id in [old, item_id]:
		var it := App.db.get_item(id)
		if it:
			keys.append(it.art_key)
	App.notify_art_changed(keys)
	if item_id.is_empty():
		App.toast("Unassigned %s" % str(e["file"]).get_file(), "info")
	else:
		App.toast("%s → %s" % [str(e["file"]).get_file(), _name(item_id)], "success")
	_recompute_flags()
	_refresh_list()
	_review_search.text = ""
	if item_id.is_empty():
		_refresh_review()
	else:
		_review_next(false)
	return OK


func _review_next(skip_current: bool) -> void:
	## Moves to the next unassigned image after the current one.
	var cur := _review_sel
	_review_items = App.assets.review_queue(_review_pack)
	var n := _review_items.size()
	var nxt := -1
	for k in range(1, n + 1):
		var i := (cur + k) % n if cur >= 0 else k - 1
		if str(_review_items[i]["assigned"]).is_empty() and (i != cur or not skip_current):
			nxt = i
			break
	_review_sel = nxt if nxt >= 0 else cur
	_refresh_review()


# ---------------------------------------------------------------------------
# Packs page
# ---------------------------------------------------------------------------

func _build_packs_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_packs_box = UI.vbox(12)
	_packs_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_packs_box)
	return scroll


func _refresh_packs() -> void:
	UI.clear(_packs_box)
	var lib := App.assets
	_packs_box.add_child(UI.label("Packs are layered: the highest priority pack that has art for an item wins; anything without art falls back to the built-in placeholders. Your fine-tuning lives in each pack's overrides.json, so updating a pack keeps it.", "Dim", true))
	for p in lib.pack_list():
		var st := lib.pack_stats(p["id"])
		var card := UI.card()
		var v := UI.vbox(6)
		card.add_child(v)
		var head := UI.hbox(8)
		head.add_child(UI.icon_rect("box" if p["builtin"] else "package-open", 22, UiTheme.c("accent")))
		var nm := UI.label(str(p["name"]) if not str(p["name"]).is_empty() else str(p["id"]), "Heading")
		head.add_child(nm)
		if not str(p["version"]).is_empty():
			head.add_child(UI.badge("v" + str(p["version"]), UiTheme.c("info")))
		head.add_child(UI.art_badge(p["art_kind"] if p["art_kind"] != "placeholder" else "placeholder"))
		head.add_child(UI.badge("priority %d" % int(p["priority"]), UiTheme.c("text_dim")))
		if not p["writable"]:
			head.add_child(UI.badge("read-only", UiTheme.c("text_faint")))
		head.add_child(UI.spacer())
		if not p["builtin"]:
			var of := UI.button("Open folder", "folder-open")
			of.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path(str(p["base"]))))
			head.add_child(of)
		v.add_child(head)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 4)
		var prov: Variant = p["provenance"]
		var prov_text := ""
		if prov is Dictionary and not (prov as Dictionary).is_empty():
			var parts := PackedStringArray()
			for k in prov:
				parts.append("%s: %s" % [k, str(prov[k])])
			prov_text = " · ".join(parts)
		elif prov is String:
			prov_text = prov
		for kv in [["Id", p["id"]], ["License", p["license"]], ["Provenance", prov_text if not prov_text.is_empty() else "—"],
				["Folder", ProjectSettings.globalize_path(str(p["base"]))],
				["Contents", "%s sprites · %s variants · %s connection shapes · %s thumbnails · %s files" % [UI.fmt_int(st["sprites"]), UI.fmt_int(st["variants"]), UI.fmt_int(st["connections"]), UI.fmt_int(st["thumbs"]), UI.fmt_int(st["files"])]],
				["Review", "%d verified · %d rejected · %d assigned · %d in review queue" % [st["verified"], st["rejected"], st["assigned"], st["review_items"]]]]:
			grid.add_child(UI.label(kv[0], "Dim"))
			var val := UI.label(str(kv[1]), "", true)
			val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(val)
		v.add_child(grid)
		var missing: Array = st["missing_files"]
		if missing.is_empty():
			var ok := UI.label("✓ All %s referenced files are present" % UI.fmt_int(st["files"]), "Dim")
			ok.add_theme_color_override("font_color", UiTheme.c("accent"))
			v.add_child(ok)
		else:
			var ml := UI.label("%d missing file%s: %s%s" % [missing.size(), "" if missing.size() == 1 else "s", ", ".join(PackedStringArray(missing.slice(0, 8))), "…" if missing.size() > 8 else ""], "", true)
			ml.add_theme_color_override("font_color", UiTheme.c("warn"))
			v.add_child(ml)
		for e in (st["override_errors"] as Array).slice(0, 5):
			var el := UI.label("overrides: " + str(e), "Faint", true)
			v.add_child(el)
		_packs_box.add_child(card)


# ---------------------------------------------------------------------------
# Drawing widgets
# ---------------------------------------------------------------------------

class PreviewCanvas extends Control:
	## Draws the item's footprint (w×h diamond tiles, 64×32 world px each) with
	## sprite layers placed at their anchors. Dragging moves the active layer
	## (its anchor); arrow keys nudge; wheel zooms; right/middle-drag pans.
	signal anchor_dragged(anchor: Vector2)
	signal drag_finished
	signal nudged(delta: Vector2)
	signal zoom_changed(zoom: float)

	var footprint := Vector2i.ONE
	var layers: Array = []           ## {tex, anchor, scale, modulate?, active?, label}
	var zoom := 1.0
	var pan := Vector2.ZERO
	var editable := false
	var show_bounds := true
	var show_anchor := true
	var show_grid := true
	var note := ""
	var _dragging := false
	var _panning := false
	var _drag_from := Vector2.ZERO
	var _anchor0 := Vector2.ZERO
	var _auto_fit := true

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		clip_contents = true
		mouse_default_cursor_shape = Control.CURSOR_MOVE

	func ground_origin() -> Vector2:
		return Vector2(size.x * 0.5, size.y * 0.66) + pan

	func _active() -> Dictionary:
		for l in layers:
			if l.get("active", false):
				return l
		return layers.back() if not layers.is_empty() else {}

	func sprite_rect(l: Dictionary) -> Rect2:
		var tex: Texture2D = l["tex"]
		var s: float = float(l["scale"]) * zoom
		return Rect2(ground_origin() - (l["anchor"] as Vector2) * s, tex.get_size() * s)

	func fit() -> void:
		## Zoom so the footprint and the art fit with a margin (re-fits on
		## resize until the user zooms or pans).
		_auto_fit = true
		pan = Vector2.ZERO
		var need := Vector2((footprint.x + footprint.y) * Iso.HALF_W, (footprint.x + footprint.y) * Iso.HALF_H)
		var top := need.y * 0.5
		var bottom := need.y * 0.5
		var half_w := need.x * 0.5
		for l in layers:
			var tex: Texture2D = l["tex"]
			var a: Vector2 = l["anchor"]
			var s: float = l["scale"]
			top = maxf(top, a.y * s)
			bottom = maxf(bottom, (tex.get_height() - a.y) * s)
			half_w = maxf(half_w, maxf(a.x, tex.get_width() - a.x) * s)
		var avail := size - Vector2(48, 48)
		if avail.x <= 0 or avail.y <= 0:
			avail = Vector2(600, 400)
		var zx := avail.x * 0.5 / maxf(1.0, half_w)
		var zy := minf(avail.y * 0.66 / maxf(1.0, top), avail.y * 0.34 / maxf(1.0, bottom))
		zoom = clampf(minf(zx, zy), 0.1, 8.0)
		zoom_changed.emit(zoom)
		queue_redraw()

	func set_zoom(z: float) -> void:
		_auto_fit = false
		zoom = clampf(z, 0.1, 12.0)
		zoom_changed.emit(zoom)
		queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			if _auto_fit:
				fit()
			queue_redraw()

	func _draw() -> void:
		var bg := UiTheme.c("panel_alt")
		draw_rect(Rect2(Vector2.ZERO, size), bg)
		# Subtle checkerboard (shows transparency).
		var cs := 16.0
		var alt := bg.lightened(0.04) if bg.get_luminance() < 0.5 else bg.darkened(0.04)
		for y in int(ceil(size.y / cs)):
			for x in int(ceil(size.x / cs)):
				if (x + y) % 2 == 0:
					draw_rect(Rect2(x * cs, y * cs, cs, cs), alt)
		var o := ground_origin()
		var c := Iso.footprint_center(Vector2i.ZERO, footprint)
		# Context tiles around the footprint.
		if show_grid:
			var ring := 3
			for gy in range(-ring, footprint.y + ring):
				for gx in range(-ring, footprint.x + ring):
					if gx >= 0 and gy >= 0 and gx < footprint.x and gy < footprint.y:
						continue
					var poly := _tile_poly(Vector2i(gx, gy), c, o)
					draw_polyline(_closed(poly), Color(1, 1, 1, 0.07), 1.0, true)
		# Footprint tiles.
		var g1 := Color("#6f9c5c")
		var g2 := Color("#648f52")
		for gy in footprint.y:
			for gx in footprint.x:
				var poly := _tile_poly(Vector2i(gx, gy), c, o)
				draw_colored_polygon(poly, g1 if (gx + gy) % 2 == 0 else g2)
				draw_polyline(_closed(poly), Color(0, 0, 0, 0.18), 1.0, true)
		var outline := PackedVector2Array()
		for p in Iso.footprint_polygon(Vector2i.ZERO, footprint):
			outline.append((p - c) * zoom + o)
		draw_polyline(_closed(outline), UiTheme.c("accent"), 2.0, true)
		# Sprite layers.
		for l in layers:
			var tex: Texture2D = l["tex"]
			if tex == null:
				continue
			draw_texture_rect(tex, sprite_rect(l), false, l.get("modulate", Color.WHITE))
		if show_bounds:
			for l in layers:
				var r := sprite_rect(l)
				var act: bool = l.get("active", false)
				var col := UiTheme.c("info") if act else Color(0.55, 0.78, 1.0, 0.8)
				_dashed_rect(r, col)
				var txt := "%s  %d×%d px" % [l.get("label", ""), (l["tex"] as Texture2D).get_width(), (l["tex"] as Texture2D).get_height()]
				# Active layer: label above its top-left corner; others below
				# their bottom-right corner, so coinciding bounds never collide.
				var pos := r.position + Vector2(4, -7) if act else r.end + Vector2(-_text_width(txt) - 4, 17)
				pos.x = clampf(pos.x, 8.0, maxf(8.0, size.x - _text_width(txt) - 8.0))
				pos.y = clampf(pos.y, 18.0, size.y - 30.0)
				_text(pos, txt, col)
		if show_anchor:
			var ac := UiTheme.c("danger")
			for d in [Vector2(1, 0), Vector2(0, 1)]:
				draw_line(o - d * 16.0, o + d * 16.0, Color(0, 0, 0, 0.6), 4.0)
				draw_line(o - d * 16.0, o + d * 16.0, ac, 2.0)
			draw_arc(o, 6.0, 0, TAU, 20, ac, 2.0, true)
			var al := _active()
			if not al.is_empty():
				var a: Vector2 = al["anchor"]
				_text(o + Vector2(12, 24), "anchor %.1f, %.1f" % [a.x, a.y], Color(1, 1, 1, 0.92))
		var cap := "%d × %d tiles" % [footprint.x, footprint.y]
		_text(Vector2(size.x - _text_width(cap) - 12, size.y - 14), cap, UiTheme.c("text_dim"))
		if not note.is_empty():
			_text(Vector2(12, size.y - 14), note, UiTheme.c("warn"))
		if has_focus():
			draw_rect(Rect2(Vector2(1, 1), size - Vector2(2, 2)), UiTheme.c("accent"), false, 2.0)

	func _text(pos: Vector2, txt: String, col: Color) -> void:
		var font := get_theme_default_font()
		draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.55))
		draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)

	func _text_width(txt: String) -> float:
		return get_theme_default_font().get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x

	func _tile_poly(t: Vector2i, c: Vector2, o: Vector2) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in Iso.footprint_polygon(t, Vector2i.ONE):
			out.append((p - c) * zoom + o)
		return out

	static func _closed(p: PackedVector2Array) -> PackedVector2Array:
		var q := p.duplicate()
		q.append(p[0])
		return q

	func _dashed_rect(r: Rect2, col: Color) -> void:
		var pts := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
		for i in 4:
			draw_dashed_line(pts[i], pts[(i + 1) % 4], col, 1.5, 6.0)

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			if mb.pressed:
				grab_focus()
			match mb.button_index:
				MOUSE_BUTTON_LEFT:
					var al := _active()
					if mb.pressed and editable and not al.is_empty():
						_dragging = true
						_drag_from = mb.position
						_anchor0 = al["anchor"]
					elif not mb.pressed and _dragging:
						_dragging = false
						drag_finished.emit()
				MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
					_panning = mb.pressed
					_drag_from = mb.position
				MOUSE_BUTTON_WHEEL_UP:
					if mb.pressed:
						set_zoom(zoom * 1.15)
				MOUSE_BUTTON_WHEEL_DOWN:
					if mb.pressed:
						set_zoom(zoom / 1.15)
			accept_event()
		elif e is InputEventMouseMotion:
			var mm := e as InputEventMouseMotion
			if _dragging:
				var al := _active()
				if not al.is_empty():
					var s: float = float(al["scale"]) * zoom
					anchor_dragged.emit(_anchor0 - (mm.position - _drag_from) / maxf(0.0001, s))
				accept_event()
			elif _panning:
				_auto_fit = false
				pan += mm.relative
				queue_redraw()
				accept_event()
		elif e is InputEventKey and e.pressed:
			var k := e as InputEventKey
			var step := 10.0 if k.shift_pressed else 1.0
			var d := Vector2.ZERO
			match k.keycode:
				KEY_LEFT: d = Vector2(-step, 0)
				KEY_RIGHT: d = Vector2(step, 0)
				KEY_UP: d = Vector2(0, -step)
				KEY_DOWN: d = Vector2(0, step)
			if d != Vector2.ZERO:
				if editable:
					nudged.emit(d)
				accept_event()


class ImageView extends Control:
	## Checkerboard + an image fitted into the control (review queue).
	var texture: Texture2D
	var note := ""

	func _init() -> void:
		clip_contents = true

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		var bg := UiTheme.c("panel_alt")
		draw_rect(Rect2(Vector2.ZERO, size), bg)
		var cs := 16.0
		var alt := bg.lightened(0.04) if bg.get_luminance() < 0.5 else bg.darkened(0.04)
		for y in int(ceil(size.y / cs)):
			for x in int(ceil(size.x / cs)):
				if (x + y) % 2 == 0:
					draw_rect(Rect2(x * cs, y * cs, cs, cs), alt)
		if texture:
			var ts := texture.get_size()
			var f := minf(minf((size.x - 32) / ts.x, (size.y - 32) / ts.y), 4.0)
			var ds := ts * maxf(0.05, f)
			draw_texture_rect(texture, Rect2((size - ds) * 0.5, ds), false)
		elif not note.is_empty():
			draw_string(get_theme_default_font(), Vector2(16, size.y * 0.5), note, HORIZONTAL_ALIGNMENT_CENTER, size.x - 32, 15, UiTheme.c("text_faint"))
