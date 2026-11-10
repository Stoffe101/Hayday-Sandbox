class_name BaselineDialog
extends PlanDialog
## "My real farm": a snapshot of the farm as it stands in Hay Day now
## (Baseline.snapshot, stored as plan.baseline through an undoable
## SetPlanning). It is the lower bound of what you own, the "before" of a
## before / after comparison and what the recreation guide moves objects from.
## Taken from the open layout or from another saved layout (read-only); the
## diff summary shows what the design keeps, moves, adds and removes.

var _status: VBoxContainer
var _name_edit: LineEdit
var _other: OptionButton
var _other_ids: Array = []
var _other_paths: Array = []
var _remove_btn: Button
var _msg: Label

## Last diff (Baseline.diff) shown, read by tests / the self-test.
var diff: Dictionary = {}


static func open(c: PlanContext) -> BaselineDialog:
	var d := BaselineDialog.new()
	d.setup(c)
	return d if d.present(c, "My real farm") else null


func setup(c: PlanContext) -> void:
	ctx = c
	preferred_width = 580.0
	_build()
	c.changed.connect(_render)
	_render()


func _build() -> void:
	add_child(PlanUiKit.wrap_label("A snapshot of your farm as it is in Hay Day now: it tells budgets what you already own at least, shows the before and after, and lets the guide say which objects to move or put in storage.", "Dim"))
	var card := UI.card()
	_status = UI.vbox(4)
	card.add_child(_status)
	add_child(card)
	add_child(UI.section("Take a snapshot"))
	var nr := UI.hbox(8)
	nr.add_child(UI.label("Name", "Dim"))
	_name_edit = LineEdit.new()
	_name_edit.text = "My farm"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nr.add_child(_name_edit)
	add_child(nr)
	var cur := UI.button("Use this layout as my real farm", "house", "Snapshot of the objects and unlocked land of the open layout (Ctrl+Z undoes)", "Accent")
	cur.pressed.connect(take_current)
	add_child(cur)
	add_child(PlanUiKit.wrap_label("Typical use: open the layout of your real farm, take the snapshot here, then redesign it.", "Faint"))
	add_child(UI.section("Or from another saved layout"))
	var orow := UI.hbox(8)
	_other = OptionButton.new()
	_other.focus_mode = Control.FOCUS_NONE
	_other.fit_to_longest_item = false
	_other.clip_text = true
	_other.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	orow.add_child(_other)
	var use := UI.button("Use", "check", "Read that layout (it is not changed) and use it as your real farm")
	use.pressed.connect(func():
		if _other.selected >= 0 and _other.selected < _other_paths.size():
			take_from_file(str(_other_paths[_other.selected]), str(_other_ids[_other.selected])))
	orow.add_child(use)
	add_child(orow)
	add_child(PlanUiKit.wrap_label("Objects are matched by their id, so pick the layout this design was copied from.", "Faint"))
	_fill_library()
	_msg = PlanUiKit.wrap_label("", "Dim")
	_msg.visible = false
	add_child(_msg)
	make_footer()
	_remove_btn = add_footer_button("Remove snapshot", "Danger", remove_baseline, "trash")
	footer.add_child(UI.spacer())
	add_footer_button("Close", "Accent", request_close)


func _fill_library() -> void:
	_other.clear()
	_other_ids.clear()
	_other_paths.clear()
	var lib := LayoutLibrary.new(ctx.db)
	lib.map = ctx.map
	var own_id := ctx.layout().id if ctx.layout() != null else ""
	for e: Dictionary in lib.list():
		if bool(e.get("broken", false)) or str(e["id"]) == own_id:
			continue
		_other.add_item("%s (%s)" % [str(e["name"]), PlanUiModels.plural(int(e.get("objects", 0)), "object")])
		_other_ids.append(str(e["id"]))
		_other_paths.append(str(e["path"]))
	if _other_ids.is_empty():
		_other.add_item("No other saved layouts")
		_other.disabled = true


func _render() -> void:
	if not is_instance_valid(_status) or ctx.session == null:
		return
	UI.clear(_status)
	var bl: Variant = ctx.plan().get("baseline")
	_remove_btn.disabled = not Baseline.is_valid(bl)
	if not Baseline.is_valid(bl):
		diff = {}
		_status.add_child(PlanUiKit.wrap_label("No snapshot yet: every object of the design counts as new.", "Dim"))
		return
	var b: Dictionary = bl
	var h := UI.hbox(8)
	h.add_child(PlanUiKit.wrap_label(str(b.get("name", "My farm")), "Heading"))
	h.add_child(PlanUiKit.badge("Snapshot", "accent"))
	_status.add_child(h)
	var taken := str(b.get("taken", ""))
	var meta: PackedStringArray = [PlanUiModels.plural((b["objects"] as Dictionary).size(), "object")]
	if Baseline.has_unlocked_plots(b):
		meta.append(PlanUiModels.plural(Baseline.unlocked_plots(b).size(), "unlocked plot"))
	if not taken.is_empty():
		meta.append("taken %s" % taken.replace("T", " ").trim_suffix("Z"))
	_status.add_child(PlanUiKit.wrap_label(" · ".join(meta), "Faint"))
	diff = Baseline.diff(ctx.layout(), b, ctx.db)
	_status.add_child(UI.label("Compared with the design", "Section"))
	for l in PlanUiModels.baseline_lines(diff):
		_status.add_child(PlanUiKit.wrap_label(str(l), "Dim"))


func _say(t: String) -> void:
	_msg.text = t
	_msg.visible = not t.is_empty()


func take_current() -> void:
	var snap := Baseline.snapshot(ctx.layout(), _name_edit.text.strip_edges())
	ctx.set_plan(PlanDoc.with_baseline(ctx.plan(), snap), "Set my real farm")
	_say("Snapshot taken: %s." % PlanUiModels.plural((snap["objects"] as Dictionary).size(), "object"))


func take_from_file(path: String, id: String) -> bool:
	var rep := LayoutIO.LoadReport.new()
	var other := LayoutIO.load_file(path, ctx.db, rep, ctx.map)
	if other == null:
		_say("Could not read that layout%s." % (": " + rep.error if not rep.error.is_empty() else ""))
		return false
	if other.id.is_empty():
		other.id = id
	var nm := _name_edit.text.strip_edges()
	var snap := Baseline.snapshot(other, nm if nm != "My farm" or other.name.is_empty() else other.name, other.id)
	ctx.set_plan(PlanDoc.with_baseline(ctx.plan(), snap), "Set my real farm from %s" % other.name)
	_say("Snapshot of “%s” taken: %s." % [other.name, PlanUiModels.plural((snap["objects"] as Dictionary).size(), "object")])
	return true


func remove_baseline() -> void:
	if not Baseline.is_valid(ctx.plan().get("baseline")):
		return
	ctx.set_plan(PlanDoc.with_baseline(ctx.plan(), {}), "Remove my real farm")
	_say("Snapshot removed (Ctrl+Z brings it back).")
