class_name PlanContext
extends RefCounted
## What every Plan panel tab and planning dialog talks to (docs/PLANNING.md §5).
## Tabs never touch main.gd, the camera or the layout directly: they read the
## models below and ask for actions through the request_* signals, which
## main.gd / PlanController implement. One context lives for the whole app;
## `session` changes when another layout is opened.

## The open layout changed (rebind everything).
signal session_changed
## Planning data, prices, inventory, budget or selection changed. Emitted at most
## once per frame (coalesced); tabs refresh when visible.
signal changed
## Ask the canvas to frame these objects (and select them when `select`).
signal request_focus(uids: Array, select: bool)
## Ask the canvas to frame a tile rectangle (an area, a guide step).
signal request_focus_rect(rect: Rect2i)
## Highlight objects on the canvas without selecting them ([] clears).
signal request_highlight(uids: Array, color: Color)
## Ask for a modal dialog (a Control; main.gd shows it in the modal layer).
signal request_dialog(content: Control, title: String)
## Ask for an image export: opts = {"scope": "farm"|"phase"|"area"|"step", "id": String,
## "guide_numbers": bool, "path": String, "art": "placeholder"|"installed"}.
signal request_export_image(opts: Dictionary)
## Open another Plan tab ("budget", "areas", "phases", "shop", "build", "guide", "accuracy").
signal request_tab(tab_id: String)
## Start the area drawing tool ("rect" | "polygon"), or "selection": add an area
## around the selected objects right away.
signal request_area_tool(kind: String)
## Ask for the inventory dialog (inventory_dialog.gd when present, else "record
## what is placed now" behind a confirmation).
signal request_inventory
## Ask for the price-override dialog of an item (price_dialog.gd when present).
signal request_price_edit(item_id: String)
## Ask to calibrate a screenshot reference (Accuracy tab): main.gd opens the
## inspector's View tab, where references are added and calibrated.
signal request_calibration
## Ask to keep an area's objects as a reusable stamp (Areas tab; main.gd saves it
## in the stamp library and opens the stamps panel).
signal request_area_stamp(area_id: String)
## Ask for the "My real farm" dialog (BaselineDialog), e.g. from the compare toggle.
signal request_baseline
## Cost mode, budget scope, active area / phase, guide step or a planning layer
## changed (view state, not document data; `changed` follows as well).
signal view_changed

## --- shared view state (main UI; never saved in the layout) ---------------------------
## Cost mode of the budget widget and tabs (BudgetEngine.MODE_*).
var mode: String = BudgetEngine.MODE_TO_BUY
## Budget scope: "auto" (selection → active area → active phase → whole farm) or "farm".
var scope_pin: String = "auto"
## Area / phase picked in the Areas / Phases tab ("" = none): part of the auto scope
## and highlighted on the canvas.
var active_area: String = ""
var active_phase: String = ""
## Guide step number the canvas marks (-1 = the current and the next step).
var guide_step: int = -1
## Planning layers on the canvas: areas, progress, heatmap, guide (main keeps them in the settings).
var layers: Dictionary = {"areas": true, "progress": true, "heatmap": false, "guide": true}
## "Compare with my farm" (Baseline.diff on the canvas). View state, not saved.
var compare := false
var _diff: Dictionary = {}
var _diff_key := ""
var _ready_cache: Dictionary = {}
var _ready_key := ""

var session: EditorSession          ## the open layout's editing session (null while loading)
var engine: BudgetEngine            ## budget for `session` (owned by the session)
var prices: PriceBook               ## shared price book (App.prices)
var db: ItemDatabase
var map: FarmMap
## Current guide (RecreationGuide.build result), rebuilt lazily by guide().
var _guide: Dictionary = {}
var _guide_key := ""
var _pending := false


func bind(s: EditorSession, e: BudgetEngine, p: PriceBook, d: ItemDatabase, m: FarmMap) -> void:
	session = s
	engine = e
	prices = p
	db = d
	map = m
	_guide = {}
	_guide_key = ""
	_diff = {}
	_diff_key = ""
	_ready_cache = {}
	_ready_key = ""
	if s == null or PlanDoc.area(plan(), active_area).is_empty():
		active_area = ""
	if s == null or PlanDoc.phase(plan(), active_phase).is_empty():
		active_phase = ""
	guide_step = -1
	session_changed.emit()
	notify_changed()


func plan() -> Dictionary:
	return session.layout.planning if session != null else PlanDoc.empty()


func layout() -> FarmLayout:
	return session.layout if session != null else null


func set_plan(new_plan: Dictionary, label: String, merge_key: String = "") -> void:
	## Every planning edit goes through here: one undoable command.
	if session == null:
		return
	session.execute(EditCommands.SetPlanning.new(session.layout.planning, new_plan, label, merge_key))


func set_profile(new_profile: Dictionary, label: String) -> void:
	if session == null:
		return
	session.execute(EditCommands.SetProfile.new(session.layout.profile, new_profile, label))


func guide() -> Dictionary:
	## The recreation guide for the current layout and plan (cached per change).
	if session == null:
		return {}
	var key := "%d|%d|%d" % [session.stack.version, plan().hash(), map.get_instance_id() if map else 0]
	if key != _guide_key:
		var opts := {"db": db}
		var bl: Variant = plan().get("baseline")
		if bl is Dictionary:
			opts["baseline"] = bl
		_guide = RecreationGuide.build(session.layout, map, plan(), opts)
		_guide_key = key
	return _guide


func notify_changed() -> void:
	## Coalesces bursts of model signals into one `changed` per frame.
	if _pending:
		return
	_pending = true
	(Engine.get_main_loop() as SceneTree).process_frame.connect(_flush, CONNECT_ONE_SHOT)


func _flush() -> void:
	_pending = false
	changed.emit()


func toast(text: String, kind: String = "info") -> void:
	if session != null:
		session.message.emit(text, kind)


# --- view state (main UI) ----------------------------------------------------------------

func _view_changed() -> void:
	view_changed.emit()
	notify_changed()


func set_mode(m: String) -> void:
	if m in BudgetEngine.MODES and m != mode:
		mode = m
		_view_changed()


func set_scope_pin(p: String) -> void:
	if p in ["auto", "farm"] and p != scope_pin:
		scope_pin = p
		_view_changed()


func set_active_area(id: String) -> void:
	if id != active_area:
		active_area = id
		_view_changed()


func set_active_phase(id: String) -> void:
	if id != active_phase:
		active_phase = id
		_view_changed()


func set_guide_step(number: int) -> void:
	## The guide step the canvas marks (-1 = current + next).
	if number != guide_step:
		guide_step = number
		_view_changed()


func set_layer(key: String, on: bool) -> void:
	if bool(layers.get(key, false)) != on:
		layers[key] = on
		_view_changed()


func set_compare(on: bool) -> void:
	## "Compare with my farm" on the canvas (needs plan.baseline to show anything).
	if on != compare:
		compare = on
		_view_changed()


func has_baseline() -> bool:
	return session != null and Baseline.is_valid(plan().get("baseline"))


func compare_diff() -> Dictionary:
	## Baseline.diff of the design against plan.baseline ({} without a baseline),
	## recomputed only after an edit or a new baseline.
	if not has_baseline():
		return {}
	var bl: Dictionary = plan()["baseline"]
	var key := "%d|%d|%d|%d" % [session.stack.version, session.layout.get_instance_id(), session.layout.objects.size(), bl.hash()]
	if key != _diff_key:
		_diff = Baseline.diff(session.layout, bl, db)
		_diff_key = key
	return _diff


func compare_key() -> String:
	## Changes whenever compare_diff() was recomputed (callers cache on it).
	return _diff_key


func compare_counts() -> Dictionary:
	## {unchanged, moved, new, removed} of compare_diff() ({} without a baseline).
	var d := compare_diff()
	if d.is_empty():
		return {}
	return {"unchanged": (d["unchanged"] as Array).size(), "moved": (d["moved"] as Array).size(),
		"new": (d["new"] as Array).size(), "removed": (d["removed"] as Array).size()}


func readiness() -> Dictionary:
	## "Can I build this?" (Readiness.build) from the session's cached conflicts,
	## Realistic analysis and the budget's can't-buy counts; cached per edit.
	if session == null:
		return {}
	var key := "%d|%d|%s|%d|%d" % [session.stack.version, session.layout.get_instance_id(), session.layout.mode,
		engine.version if engine != null else -1, session.layout.profile.hash()]
	if key != _ready_key:
		var nb := {}
		if engine != null:
			var br := engine.item_breakdown(null, BudgetEngine.MODE_TO_BUY)
			for item: String in br:
				var n := int((br[item] as Dictionary).get("not_buyable", 0))
				if n > 0:
					nb[item] = n
		_ready_cache = Readiness.build(session.layout, db, session.conflicts(), session.analysis(), nb)
		_ready_key = key
	return _ready_cache


func selection() -> Array:
	return session.selection if session != null else []


func scope() -> Dictionary:
	## The budget scope now: {kind: "selection"|"area"|"phase"|"farm", id, uids, label} (PlanScope.resolve).
	if session == null:
		return {"kind": "farm", "id": "", "uids": null, "label": "Whole farm"}
	return PlanScope.resolve(session.selection, active_area, active_phase, scope_pin, plan())


func scope_totals(m: String = "") -> BudgetEngine.Totals:
	## Totals of scope() in mode `m` (default: the shared mode). null without a session.
	if engine == null:
		return null
	return PlanScope.totals(engine, scope(), mode if m.is_empty() else m)


func item_name(item_id: String) -> String:
	var it: ItemDef = db.get_item(item_id) if db else null
	return it.name if it else item_id
