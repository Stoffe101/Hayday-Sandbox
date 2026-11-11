class_name PlanBuildTab
extends PlanTab
## Construction checklist (docs/PLANNING.md §4): per phase (build order) and
## per item group, how many objects are not acquired, acquired but not placed,
## and placed in Hay Day, with a progress bar per phase and overall. Ticks only
## change planning data (plan.placed) through undoable SetPlanning commands; a
## burst of ticks merges into one undo step. The design itself never changes.

const MERGE := "build_ticks"

var _overall_l: Label
var _overall_bar: ProgressBar
var _overall_counts: Label
var _mark_btn: Button
var _unmark_btn: Button
var _show_btn: Button
var _unfinished: CheckButton
var _moved_box: VBoxContainer
var _compare_l: Label
var _compare_btn: Button
var _phases_box: VBoxContainer
var _highlighting := false

## Current checklist (PlanUiModels.checklist), read by tests / the self-test.
var checklist: Dictionary = {}
var last_refresh_usec := 0


func _init() -> void:
	tab_id = "build"
	title = "Build"
	icon = "list-checks"


func _build() -> void:
	var head := UI.card()
	var hv := UI.vbox(4)
	head.add_child(hv)
	_overall_l = PlanUiKit.wrap_label("", "Heading")
	hv.add_child(_overall_l)
	_overall_bar = PlanUiKit.progress(0.0, 10.0)
	hv.add_child(_overall_bar)
	_overall_counts = PlanUiKit.wrap_label("", "Faint")
	hv.add_child(_overall_counts)
	# Before / after with the real farm (plan.baseline): counts and the canvas view.
	var cr := UI.vbox(4)   # text above the button: side by side the text was squeezed into a narrow column
	_compare_l = PlanUiKit.wrap_label("", "Faint")
	cr.add_child(_compare_l)
	_compare_btn = UI.button("", "git-compare", "", "Ghost")
	_compare_btn.add_theme_font_size_override("font_size", 13)
	_compare_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_compare_btn.pressed.connect(func():
		if ctx.has_baseline():
			ctx.set_compare(not ctx.compare)
		else:
			ctx.request_baseline.emit())
	cr.add_child(_compare_btn)
	hv.add_child(cr)
	add_child(head)
	var acts := PlanUiKit.flow(6, 6)
	_mark_btn = UI.button("Mark selected placed", "check", "The selected objects stand in your Hay Day farm now (Ctrl+Z undoes)")
	_mark_btn.pressed.connect(func(): _mark(ctx.session.selection.duplicate(), true))
	acts.add_child(_mark_btn)
	_unmark_btn = UI.button("Not placed", "undo-2", "Clear the placed mark of the selected objects")
	_unmark_btn.pressed.connect(func(): _mark(ctx.session.selection.duplicate(), false))
	acts.add_child(_unmark_btn)
	_show_btn = UI.button("Show remaining", "eye", "Highlight every object that is not placed yet")
	_show_btn.toggle_mode = true
	_show_btn.toggled.connect(func(on: bool):
		_highlighting = on
		if on:
			_update_highlight()
		else:
			ctx.request_highlight.emit([], Color()))
	acts.add_child(_show_btn)
	add_child(acts)
	_unfinished = CheckButton.new()
	_unfinished.text = "Unfinished only"
	_unfinished.focus_mode = Control.FOCUS_NONE
	_unfinished.toggled.connect(func(_on: bool): _render())
	add_child(_unfinished)
	_moved_box = UI.vbox(4)
	add_child(_moved_box)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 180
	_phases_box = UI.vbox(10)
	_phases_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_phases_box)
	add_child(scroll)
	add_child(PlanUiKit.wrap_label("Ticks never change the design: they record what already stands in your real farm.", "Faint"))
	visibility_changed.connect(func():
		if not is_visible_in_tree() and _highlighting:
			_show_btn.set_pressed_no_signal(false)
			_highlighting = false
			if ctx != null:
				ctx.request_highlight.emit([], Color()))


func refresh() -> void:
	var t0 := Time.get_ticks_usec()
	checklist = PlanUiModels.batch(ctx.engine, func() -> Variant:
		return PlanUiModels.checklist(ctx.engine, ctx.layout(), ctx.db, ctx.plan()))
	var sel: Array = ctx.session.selection
	_mark_btn.disabled = sel.is_empty()
	_unmark_btn.disabled = sel.is_empty()
	_mark_btn.text = "Mark %d selected placed" % sel.size() if not sel.is_empty() else "Mark selected placed"
	_render()
	_update_highlight()
	last_refresh_usec = Time.get_ticks_usec() - t0


func _render() -> void:
	var ov: Dictionary = checklist.get("overall", {})
	var total := int(ov.get("total", 0))
	_overall_l.text = "%s placed in Hay Day" % PlanUiModels.pct_text(float(ov.get("percent", 0.0))) if total > 0 else "Nothing to build yet"
	_overall_bar.value = float(ov.get(PlanUiModels.ST_PLACED, 0)) / maxf(1.0, total)
	_overall_counts.text = PlanUiModels.counts_text(ov) if total > 0 else "Place objects on the farm to get a checklist."
	_render_compare()
	_render_moved()
	UI.clear(_phases_box)
	var cl := PlanUiModels.filter_unfinished(checklist) if _unfinished.button_pressed else checklist
	var phases: Array = cl.get("phases", [])
	if phases.is_empty():
		_phases_box.add_child(PlanUiKit.wrap_label("Everything is placed." if total > 0 else "No objects yet.", "Dim"))
	for p: Dictionary in phases:
		_phases_box.add_child(_phase_card(p))


func _render_compare() -> void:
	var c := ctx.compare_counts()
	if c.is_empty():
		_compare_l.text = "No snapshot of your real farm yet: take one to see what stays, moves, is new or goes."
		_compare_btn.text = "My real farm…"
		_compare_btn.tooltip_text = "Take a snapshot of your farm as it is in Hay Day now"
		return
	_compare_l.text = "Vs. your farm: %d unchanged · %d moved · %d new · %d removed" % [int(c["unchanged"]), int(c["moved"]), int(c["new"]), int(c["removed"])]
	_compare_btn.text = "Hide" if ctx.compare else "Show"
	_compare_btn.tooltip_text = "Compare with my farm on the canvas (tints, arrows from the old spots, removed ghosts)"


func _render_moved() -> void:
	UI.clear(_moved_box)
	var moved: Array = checklist.get("moved", [])
	if moved.is_empty():
		return
	var card := PanelContainer.new()
	var col := UiTheme.c("warn")
	card.add_theme_stylebox_override("panel", UiTheme.box(Color(col.r, col.g, col.b, 0.14), 12, col, 1, Vector4(12, 8, 12, 8)))
	var v := UI.vbox(6)
	card.add_child(v)
	v.add_child(PlanUiKit.wrap_label("%s moved after you marked %s placed. Check %s in Hay Day." % [
		PlanUiModels.plural(moved.size(), "object"), "it" if moved.size() == 1 else "them", "it" if moved.size() == 1 else "them"]))
	var row := PlanUiKit.flow(6, 6)
	var sh := UI.button("Show", "crosshair", "Frame and select them")
	sh.pressed.connect(func(): ctx.request_focus.emit(moved.duplicate(), true))
	row.add_child(sh)
	var keep := UI.button("Placed here", "check", "They stand at the new spot in Hay Day too")
	keep.pressed.connect(func(): _mark(moved.duplicate(), true, "Re-mark moved objects placed"))
	row.add_child(keep)
	var un := UI.button("Not placed", "undo-2", "Clear their placed mark")
	un.pressed.connect(func(): _mark(moved.duplicate(), false, "Unmark moved objects"))
	row.add_child(un)
	v.add_child(row)
	_moved_box.add_child(card)


func _phase_card(p: Dictionary) -> Control:
	var card := UI.card()
	var v := UI.vbox(6)
	card.add_child(v)
	var head := UI.hbox(8)
	if not str(p.get("color", "")).is_empty():
		head.add_child(PlanUiKit.color_dot(Color.from_string(str(p["color"]), UiTheme.c("text_faint"))))
	var nm := PlanUiKit.wrap_label(str(p.get("name", "")), "Heading")
	head.add_child(nm)
	var st := str(p.get("status", ""))
	var tone := "faint"
	match st:
		BudgetEngine.PHASE_COMPLETED: tone = "accent"
		BudgetEngine.PHASE_READY: tone = "info"
		BudgetEngine.PHASE_IN_PROGRESS: tone = "warn"
	head.add_child(PlanUiKit.badge(str(p.get("status_text", st)), tone))
	v.add_child(head)
	var pr := UI.hbox(8)
	pr.add_child(PlanUiKit.progress(float(p.get(PlanUiModels.ST_PLACED, 0)) / maxf(1.0, int(p.get("total", 0)))))
	pr.add_child(UI.label(PlanUiModels.pct_text(float(p.get("percent", 0.0))), "Dim"))
	v.add_child(pr)
	var counts := PlanUiModels.counts_text(p)
	if bool(p.get("marked_done", false)) and int(p.get(PlanUiModels.ST_PLACED, 0)) < int(p.get("total", 0)):
		counts += " · phase marked done"
	v.add_child(PlanUiKit.wrap_label(counts, "Faint"))
	var open: Array = p.get("open_uids", [])
	var all: Array = p.get("uids", [])
	var acts := PlanUiKit.flow(6, 6)
	if not open.is_empty():
		var mk := UI.button("Mark phase placed", "check", "Every object of this phase stands in Hay Day (Ctrl+Z undoes)")
		mk.pressed.connect(func(): _mark(open.duplicate(), true, "Mark phase placed"))
		acts.add_child(mk)
		var sh := UI.button("Show remaining", "eye", "Highlight and frame the objects of this phase not placed yet")
		sh.pressed.connect(func():
			ctx.request_highlight.emit(open.duplicate(), UiTheme.c("warn"))
			ctx.request_focus.emit(open.duplicate(), false))
		acts.add_child(sh)
	elif not all.is_empty():
		var um := UI.button("Mark not placed", "undo-2", "Clear the placed marks of this phase")
		um.pressed.connect(func(): _mark(all.duplicate(), false, "Unmark phase"))
		acts.add_child(um)
	if acts.get_child_count() > 0:
		v.add_child(acts)
	for g: Dictionary in p.get("groups", []):
		v.add_child(_group_row(g))
	return card


func _group_row(g: Dictionary) -> Control:
	var h := UI.hbox(6)
	var info := UI.vbox(0)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(PlanUiKit.wrap_label(str(g.get("group", ""))))
	info.add_child(PlanUiKit.wrap_label(PlanUiModels.counts_text(g), "Faint"))
	h.add_child(info)
	var open: Array = g.get("open_uids", [])
	var all: Array = g.get("uids", [])
	if not open.is_empty():
		var mk := UI.icon_button("check", "Mark these %d placed" % open.size(), "Ghost", 18)
		mk.pressed.connect(func(): _mark(open.duplicate(), true, "Mark %s placed" % str(g.get("group", ""))))
		h.add_child(mk)
	else:
		var um := UI.icon_button("undo-2", "Mark not placed", "Ghost", 18)
		um.pressed.connect(func(): _mark(all.duplicate(), false, "Unmark %s" % str(g.get("group", ""))))
		h.add_child(um)
	var sh := UI.icon_button("crosshair", "Show on farm", "Ghost", 18)
	sh.pressed.connect(func():
		var target: Array = open if not open.is_empty() else all
		ctx.request_highlight.emit(target.duplicate(), UiTheme.c("warn") if not open.is_empty() else UiTheme.c("accent"))
		ctx.request_focus.emit(target.duplicate(), false))
	h.add_child(sh)
	return h


func _mark(uids: Array, placed: bool, label: String = "") -> void:
	if uids.is_empty():
		return
	var lbl := label if not label.is_empty() else ("Mark %d placed" % uids.size() if placed else "Unmark %d placed" % uids.size())
	var np := PlanDoc.with_placed(ctx.plan(), ctx.layout(), uids, placed)
	if np == ctx.plan():
		return
	ctx.set_plan(np, lbl, MERGE)


func _update_highlight() -> void:
	if not _highlighting:
		return
	var ov: Dictionary = checklist.get("overall", {})
	ctx.request_highlight.emit((ov.get("open_uids", []) as Array).duplicate(), UiTheme.c("warn"))
