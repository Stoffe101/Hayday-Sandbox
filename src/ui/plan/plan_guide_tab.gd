class_name PlanGuideTab
extends PlanTab
## Step-by-step recreation guide (RecreationGuide via ctx.guide()): a card for
## the current step with landmark-relative directions and exact tiles,
## Previous / Next, "Mark step done" (manual steps are ticked in
## plan.steps_done, the others mark their objects placed; undoable, a burst
## merges), the steps grouped by phase, and exports (HTML with pictures, CSV,
## JSON, text, PNG pictures through ctx.request_export_image). Pictures use
## placeholder art unless the user explicitly picks the installed (private) art.

const MERGE := "guide_steps"
const PAGE := 50
const ART_PLACEHOLDER := "placeholder"
const ART_INSTALLED := "installed"

var _progress_l: Label
var _progress_bar: ProgressBar
var _phase_flow: HFlowContainer
var _card: PanelContainer
var _step_head: Label
var _step_title: Label
var _step_desc: Label
var _step_where: Label
var _step_meta: Label
var _step_badge: PanelContainer
var _prev_btn: Button
var _next_btn: Button
var _done_btn: Button
var _show_btn: Button
var _unfinished: CheckButton
var _list: PlanUiKit.PagedList
var _art_opt: OptionButton
var _art_warn: Label
var _phase_pics: CheckBox
var _export_btn: MenuButton

## Index (into guide.steps) of the step on the card; -1 = none.
var current := -1
var _follow := true
var _advance_from := -1
var _highlighted := false
## Current guide (ctx.guide()), read by tests / the self-test.
var guide: Dictionary = {}
var last_refresh_usec := 0


func _init() -> void:
	tab_id = "guide"
	title = "Guide"
	icon = "map"


func _build() -> void:
	var pc := UI.vbox(4)
	_progress_l = PlanUiKit.wrap_label("", "Dim")
	pc.add_child(_progress_l)
	_progress_bar = PlanUiKit.progress(0.0)
	pc.add_child(_progress_bar)
	_phase_flow = PlanUiKit.flow(4, 4)
	pc.add_child(_phase_flow)
	add_child(pc)
	_card = UI.card()
	var cv := UI.vbox(4)
	_card.add_child(cv)
	var hr := UI.hbox(8)
	_step_head = PlanUiKit.wrap_label("", "Section")
	hr.add_child(_step_head)
	_step_badge = PlanUiKit.badge("", "faint")
	hr.add_child(_step_badge)
	cv.add_child(hr)
	_step_title = PlanUiKit.wrap_label("", "Heading")
	cv.add_child(_step_title)
	_step_desc = PlanUiKit.wrap_label("")
	cv.add_child(_step_desc)
	_step_where = PlanUiKit.wrap_label("", "Dim")
	cv.add_child(_step_where)
	_step_meta = PlanUiKit.wrap_label("", "Faint")
	cv.add_child(_step_meta)
	var nav := PlanUiKit.flow(6, 6)
	_prev_btn = UI.button("Previous", "undo-2", "Previous step")
	_prev_btn.pressed.connect(func(): _go(current - 1))
	nav.add_child(_prev_btn)
	_next_btn = UI.button("Next", "redo-2", "Next step")
	_next_btn.pressed.connect(func(): _go(current + 1))
	nav.add_child(_next_btn)
	_done_btn = UI.button("Mark step done", "check", "", "Accent")
	_done_btn.pressed.connect(_toggle_done)
	nav.add_child(_done_btn)
	_show_btn = UI.icon_button("crosshair", "Show this step on the farm", "Ghost")
	_show_btn.pressed.connect(func(): _focus_step(current))
	nav.add_child(_show_btn)
	cv.add_child(nav)
	add_child(_card)
	_unfinished = CheckButton.new()
	_unfinished.text = "Unfinished only"
	_unfinished.focus_mode = Control.FOCUS_NONE
	_unfinished.toggled.connect(func(_on: bool): _render_list(true))
	add_child(_unfinished)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 160
	_list = PlanUiKit.PagedList.new(PAGE)
	_list.kind_of = func(e: Dictionary) -> String: return str(e["type"])
	_list.make = _make_widget
	_list.bind = _bind_widget
	_list.empty_text = "No steps."
	scroll.add_child(_list)
	add_child(scroll)
	add_child(_build_export())
	visibility_changed.connect(func():
		if not is_visible_in_tree() and _highlighted and ctx != null:
			_highlighted = false
			ctx.request_highlight.emit([], Color()))


func _build_export() -> Control:
	var box := UI.vbox(6)
	box.add_child(UI.section("Export"))
	var row := PlanUiKit.flow(6, 6)
	_art_opt = OptionButton.new()
	_art_opt.focus_mode = Control.FOCUS_NONE
	_art_opt.fit_to_longest_item = false
	_art_opt.clip_text = true
	_art_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_art_opt.custom_minimum_size.x = 168   # readable choice; the flow wraps the export button below when narrow
	_art_opt.add_item("Placeholder art")
	_art_opt.add_item("Installed art (private)")
	_art_opt.tooltip_text = "Which art the exported pictures use. Pictures with installed art stay on this PC."
	_art_opt.item_selected.connect(func(i: int): _art_warn.visible = i == 1)
	row.add_child(_art_opt)
	_export_btn = MenuButton.new()
	_export_btn.text = "Export guide…"
	_export_btn.icon = Icons.get_icon("download", 20)
	_export_btn.flat = false
	_export_btn.focus_mode = Control.FOCUS_NONE
	var pop := _export_btn.get_popup()
	pop.add_item("Printable page (HTML)…", 0)
	pop.add_item("Checklist (CSV)…", 1)
	pop.add_item("Data (JSON)…", 2)
	pop.add_item("Plain text…", 3)
	pop.add_separator()
	pop.add_item("Overview picture (PNG)…", 4)
	pop.add_item("A picture per phase (PNG)…", 5)
	pop.add_separator()
	pop.add_item("PDF: open the HTML page in your browser and print it to PDF", 6)
	pop.set_item_disabled(pop.get_item_index(6), true)
	pop.id_pressed.connect(_on_export)
	row.add_child(_export_btn)
	box.add_child(row)
	_phase_pics = CheckBox.new()
	_phase_pics.text = "Picture per phase (HTML)"
	_phase_pics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_phase_pics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phase_pics.focus_mode = Control.FOCUS_NONE
	box.add_child(_phase_pics)
	_art_warn = PlanUiKit.wrap_label("Pictures with installed game art are private: keep them on this PC and don't share or upload them.", "Faint")
	_art_warn.add_theme_color_override("font_color", UiTheme.c("warn"))
	_art_warn.visible = false
	box.add_child(_art_warn)
	return box


# --- refresh --------------------------------------------------------------------------------

func refresh() -> void:
	var t0 := Time.get_ticks_usec()
	guide = ctx.guide()
	var steps: Array = guide.get("steps", [])
	var prog: Dictionary = guide.get("progress", {})
	if _advance_from >= 0:
		current = _next_open(_advance_from)
		_advance_from = -1
	elif _follow or current >= steps.size():
		current = int(prog.get("current", -1))
	if current < 0 and not steps.is_empty() and not _follow:
		current = 0
	_progress_l.text = PlanUiModels.progress_text(prog)
	_progress_bar.value = float(prog.get("percent", 0.0)) / 100.0
	_progress_bar.visible = int(prog.get("total", 0)) > 0
	UI.clear(_phase_flow)
	var phases: Array = prog.get("phases", [])
	if phases.size() > 1:
		for pp: Dictionary in phases:
			var done := int(pp.get("completed", 0)) >= int(pp.get("total", 0))
			_phase_flow.add_child(PlanUiKit.badge("%s %d/%d" % [str(pp.get("name", "")), int(pp.get("completed", 0)), int(pp.get("total", 0))],
				"accent" if done else "faint"))
	_render_card()
	_render_list(false)
	last_refresh_usec = Time.get_ticks_usec() - t0


func _next_open(from: int) -> int:
	var steps: Array = guide.get("steps", [])
	for i in range(from + 1, steps.size()):
		if not bool(steps[i].get("done", false)):
			return i
	for i in range(0, mini(from + 1, steps.size())):
		if not bool(steps[i].get("done", false)):
			return i
	return clampi(from, -1, steps.size() - 1)


func step(i: int) -> Dictionary:
	var steps: Array = guide.get("steps", [])
	return steps[i] if i >= 0 and i < steps.size() else {}


func _render_card() -> void:
	var steps: Array = guide.get("steps", [])
	var s := step(current)
	_card.visible = not s.is_empty()
	_prev_btn.disabled = current <= 0
	_next_btn.disabled = current < 0 or current >= steps.size() - 1
	if s.is_empty():
		return
	var done := bool(s.get("done", false))
	_step_head.text = "STEP %d OF %d · %s" % [int(s.get("number", 0)), steps.size(), str(s.get("stage_name", "")).to_upper()]
	PlanUiKit.set_badge(_step_badge, "Done" if done else "To do", "accent" if done else "faint")
	_step_title.text = str(s.get("title", ""))
	_step_desc.text = str(s.get("description", ""))
	_step_desc.visible = not _step_desc.text.is_empty()
	_step_where.text = PlanUiModels.step_where_text(s)
	_step_meta.text = PlanUiModels.step_meta_text(s)
	_done_btn.text = "Not done" if done else "Mark step done"
	_done_btn.theme_type_variation = "" if done else "Accent"
	_done_btn.tooltip_text = ("Tick this step by hand (nothing to mark placed)" if PlanUiModels.step_is_manual(s)
		else "Marks its objects placed in Hay Day") + " · Ctrl+Z undoes"


func _render_list(reset: bool) -> void:
	_list.empty_text = "All steps are done." if _unfinished.button_pressed else "No steps: place objects on the farm first."
	_list.set_entries(PlanUiModels.guide_entries(guide, _unfinished.button_pressed), reset)


# --- list rows ----------------------------------------------------------------------------------

func _make_widget(kind: String) -> Control:
	if kind == "phase":
		var h := UI.hbox(8)
		var t := PlanUiKit.wrap_label("", "Section")
		h.add_child(t)
		var s := UI.label("", "Faint")
		h.add_child(s)
		h.set_meta("title", t)
		h.set_meta("sub", s)
		return h
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var h2 := UI.hbox(8)
	h2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h2)
	var tick := UI.icon_rect("check", 16, UiTheme.c("accent"))
	h2.add_child(tick)
	var l := PlanUiKit.wrap_label("")
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h2.add_child(l)
	p.set_meta("tick", tick)
	p.set_meta("label", l)
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_go(int(p.get_meta("index", -1)))
			p.accept_event())
	return p


func _bind_widget(c: Control, e: Dictionary, _i: int) -> void:
	if str(e["type"]) == "phase":
		(c.get_meta("title") as Label).text = str(e["name"]).to_upper()
		(c.get_meta("sub") as Label).text = "%d/%d" % [int(e["completed"]), int(e["total"])]
		return
	var s: Dictionary = e["step"]
	var idx := int(e["index"])
	c.set_meta("index", idx)
	var done := bool(s.get("done", false))
	var tick: TextureRect = c.get_meta("tick")
	# Only finished steps get a tick (a faint tick read as "done").
	tick.modulate = Color(1, 1, 1, 1.0 if done else 0.0)
	var l: Label = c.get_meta("label")
	l.text = PlanUiModels.step_list_text(s)
	var cur := idx == current
	var look := "%s|%s|%s" % [done, cur, str(UiTheme.palette.get("name", ""))]
	if str(c.get_meta("look", "")) != look:
		c.set_meta("look", look)
		l.add_theme_color_override("font_color", UiTheme.c("text_faint") if done else UiTheme.c("text"))
		c.add_theme_stylebox_override("panel", _row_box(cur))
	c.tooltip_text = "%s\n%s" % [str(s.get("description", "")), PlanUiModels.step_where_text(s)]


var _boxes: Dictionary = {}


func _row_box(cur: bool) -> StyleBoxFlat:
	var k := "%s|%s" % [cur, str(UiTheme.palette.get("name", ""))]
	if not _boxes.has(k):
		_boxes[k] = UiTheme.box(UiTheme.c("accent_soft") if cur else Color.TRANSPARENT, 8,
			UiTheme.c("accent") if cur else Color.TRANSPARENT, 1 if cur else 0, Vector4(8, 4, 8, 4))
	return _boxes[k]


# --- actions -----------------------------------------------------------------------------------

func _go(i: int) -> void:
	var steps: Array = guide.get("steps", [])
	if i < 0 or i >= steps.size():
		return
	current = i
	_follow = false
	_render_card()
	_list.rebind()
	_focus_step(i)


func _focus_step(i: int) -> void:
	var s := step(i)
	if s.is_empty():
		return
	var r: Rect2i = s.get("bounds", Rect2i())
	if str(s.get("kind", "")) == "move" and s.get("from_bounds") is Rect2i:
		r = r.merge(s["from_bounds"])
	if r.size.x > 0 and r.size.y > 0:
		ctx.request_focus_rect.emit(r)
	ctx.request_highlight.emit((s.get("uids", []) as Array).duplicate(), UiTheme.c("accent"))
	ctx.set_guide_step(int(s.get("number", i + 1)))
	_highlighted = true


func _toggle_done() -> void:
	var s := step(current)
	if s.is_empty():
		return
	var done := not bool(s.get("done", false))
	var np := PlanUiModels.plan_with_step(ctx.plan(), ctx.layout(), s, done)
	if np == ctx.plan():
		return
	if done:
		_advance_from = current
	ctx.set_plan(np, ("Done: %s" if done else "Not done: %s") % str(s.get("title", "")), MERGE)


# --- exports -------------------------------------------------------------------------------------

func _art() -> String:
	return ART_INSTALLED if _art_opt.selected == 1 else ART_PLACEHOLDER


func _can_export_images() -> bool:
	return not ctx.request_export_image.get_connections().is_empty()


func _stem() -> String:
	return PlanUiModels.safe_file_stem(ctx.layout().name, "farm") + "_guide"


func _opts() -> Dictionary:
	return {"title": "%s: recreation guide" % ctx.layout().name, "generated": PlanUiKit.now_text()}


func _phase_ids_with_steps() -> Array:
	var out: Array = []
	for pp: Dictionary in (guide.get("progress", {}) as Dictionary).get("phases", []):
		out.append(str(pp.get("phase", "")))
	return out


func _on_export(id: int) -> void:
	guide = ctx.guide()
	match id:
		0: PlanUiKit.save_file(self, "Export guide (HTML)", PackedStringArray(["*.html ; Web page"]), _stem() + ".html", _export_html)
		1: _save_text("Export checklist (CSV)", "*.csv ; CSV spreadsheet", ".csv", GuideExport.to_csv(guide, _opts()))
		2: _save_text("Export guide (JSON)", "*.json ; JSON", ".json", GuideExport.to_json(guide, _opts()))
		3: _save_text("Export guide (text)", "*.txt ; Text", ".txt", GuideExport.to_text(guide, _opts()))
		4: PlanUiKit.save_file(self, "Export overview picture", PackedStringArray(["*.png ; PNG image"]), _stem() + "_overview.png", _export_overview)
		5: PlanUiKit.pick_dir(self, "Folder for the phase pictures", _export_phase_pictures)


func _export_overview(path: String) -> void:
	if _request_image({"scope": "farm", "id": "", "guide_numbers": true, "path": path}):
		ctx.toast("Saving the overview picture to %s" % path, "info")


func _save_text(title_text: String, filter: String, ext: String, data: String) -> void:
	PlanUiKit.save_file(self, title_text, PackedStringArray([filter]), _stem() + ext, func(p: String):
		var err := PlanUiKit.write_text(p, data)
		ctx.toast("Saved %s" % p if err.is_empty() else err, "success" if err.is_empty() else "error"))


func _request_image(opts: Dictionary) -> bool:
	if PlanUiKit.is_inside_repo(str(opts.get("path", ""))):
		ctx.toast("Choose a folder outside the program folder (e.g. Documents).", "error")
		return false
	if not _can_export_images():
		ctx.toast("Picture export is not available here", "error")
		return false
	var o := opts.duplicate()
	o["art"] = _art()
	ctx.request_export_image.emit(o)
	return true


func html_for(path: String) -> Dictionary:
	## The HTML text and the picture requests for an HTML export to `path`:
	## {html, images: [export opts]} (pictures are written next to the page and
	## referenced by relative file name).
	var dir := path.get_base_dir()
	var phases := _phase_ids_with_steps()
	var names := PlanUiModels.guide_image_names(path.get_file().get_basename(), phases)
	var opts := _opts()
	var images: Array = []
	if _can_export_images():
		opts["overview_image"] = names["overview"]
		images.append({"scope": "farm", "id": "", "guide_numbers": true, "path": dir.path_join(names["overview"])})
		if _phase_pics.button_pressed:
			opts["phase_images"] = names["phases"]
			for pid in phases:
				images.append({"scope": "phase", "id": pid, "guide_numbers": true, "path": dir.path_join(str(names["phases"][pid]))})
	return {"html": GuideExport.to_html(guide, opts), "images": images}


func _export_html(path: String) -> void:
	var h := html_for(path)
	var err := PlanUiKit.write_text(path, str(h["html"]))
	if not err.is_empty():
		ctx.toast(err, "error")
		return
	for o in h["images"]:
		_request_image(o)
	var note := " Pictures are being saved next to it." if not (h["images"] as Array).is_empty() else ""
	ctx.toast("Saved the guide to %s.%s Print it to PDF from your browser if you need a PDF." % [path, note], "success")


func _export_phase_pictures(dir: String) -> void:
	var phases := _phase_ids_with_steps()
	if phases.is_empty():
		ctx.toast("No phases with steps", "info")
		return
	var names := PlanUiModels.guide_image_names(_stem(), phases)
	var n := 0
	for pid in phases:
		if _request_image({"scope": "phase", "id": pid, "guide_numbers": true, "path": dir.path_join(str(names["phases"][pid]))}):
			n += 1
	if n > 0:
		ctx.toast("Saving %s to %s" % [PlanUiModels.plural(n, "picture"), dir], "info")
