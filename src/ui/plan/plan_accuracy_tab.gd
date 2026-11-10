class_name PlanAccuracyTab
extends PlanTab
## Farm Accuracy Report (AccuracyReport): how far the farm on screen can be
## trusted when it is rebuilt in Hay Day. A plain-language headline, then one
## card per section with a status chip: the evidence ladder (client ground and
## expansion data, landmark coordinates, footprints, rendering anchors,
## calibration, terrain, game version; from user://private_data/world_validation.json
## when present), the calibration result of every reference screenshot (RMS /
## max error, verdict) and what is still uncertain.
## Never upgrades the data: the wording comes from AccuracyReport itself.

## Optional PlanContext signal that opens the inspector's screenshot
## calibration (emitted only when the context declares it).
const CALIBRATE_SIGNAL := "request_calibration"
const CALIBRATE_HELP := "To calibrate: open the inspector's View tab, add a screenshot under “Screenshot reference” and use Calibrate (2, 3 or 4 points). Four or more points measure the error."

var _headline: Label
var _level_badge: PanelContainer
var _sections: VBoxContainer
var _help: Label
var _key := ""

## Current report (AccuracyReport.build), read by tests / the self-test.
var report: Dictionary = {}
var last_refresh_usec := 0


func _init() -> void:
	tab_id = "accuracy"
	title = "Accuracy"
	icon = "target"


func _build() -> void:
	var head := UI.card()
	var hv := UI.vbox(6)
	head.add_child(hv)
	_level_badge = PlanUiKit.badge("", "faint")
	var br := UI.hbox(6)
	br.add_child(_level_badge)
	br.add_child(UI.spacer())
	hv.add_child(br)
	_headline = PlanUiKit.wrap_label("", "Heading")
	hv.add_child(_headline)
	add_child(head)
	var acts := PlanUiKit.flow(6, 6)
	var cal := UI.button("Calibrate a screenshot", "crosshair", "Compare the grid with a screenshot of your real farm")
	cal.pressed.connect(_calibrate)
	acts.add_child(cal)
	var cp := UI.button("Copy report as text", "copy", "Copy the whole report to the clipboard")
	cp.pressed.connect(func():
		DisplayServer.clipboard_set(AccuracyReport.to_text(report))
		ctx.toast("Accuracy report copied", "success"))
	acts.add_child(cp)
	var pc := UI.button("Write placement check", "clipboard-check", "For every calibrated screenshot: check each clicked landmark against the others and write a private report (user://private_data/placement_checks)")
	pc.pressed.connect(func():
		var w := write_placement_checks()
		ctx.toast(str(w["text"]), "success" if int(w["written"]) > 0 else "info"))
	acts.add_child(pc)
	add_child(acts)
	_help = PlanUiKit.wrap_label(CALIBRATE_HELP, "Faint")
	_help.visible = false
	add_child(_help)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 180
	_sections = UI.vbox(8)
	_sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_sections)
	add_child(scroll)


func refresh() -> void:
	# The report depends on the map, the objects and the reference images, not
	# on planning ticks: rebuild only when the layout or the map changed.
	var key := "%d|%d|%d|%d" % [ctx.session.stack.version, ctx.map.get_instance_id() if ctx.map else 0,
		ctx.layout().get_instance_id(), ctx.layout().reference.hash()]
	if key == _key and not report.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	_key = key
	report = AccuracyReport.build(ctx.map, ctx.db, ctx.layout())
	_render()
	last_refresh_usec = Time.get_ticks_usec() - t0


func _level_tone(level: String) -> Array:
	match level:
		"game_data_calibrated": return ["Game data, calibrated", "accent"]
		"game_data_validated": return ["Game data, checked against the client", "accent"]
		"game_data_unverified": return ["Game data, not verified", "info"]
		"public_approximation": return ["Approximate map", "warn"]
	return ["Unknown origin", "danger"]


func _render() -> void:
	var lt := _level_tone(str(report.get("level", "unknown")))
	PlanUiKit.set_badge(_level_badge, str(lt[0]), str(lt[1]))
	_headline.text = str(report.get("headline", ""))
	UI.clear(_sections)
	for s: Dictionary in report.get("sections", []):
		_sections.add_child(_section_card(s))


func _section_card(s: Dictionary) -> Control:
	var card := UI.card()
	var v := UI.vbox(4)
	card.add_child(v)
	var h := UI.hbox(8)
	h.add_child(PlanUiKit.wrap_label(str(s.get("title", "")), "Heading"))
	var st := str(s.get("status", "unknown"))
	h.add_child(PlanUiKit.badge(str(PlanUiModels.STATUS_WORDS.get(st, st)), str(PlanUiModels.STATUS_TONES.get(st, "faint"))))
	v.add_child(h)
	if str(s.get("id", "")) == "evidence" and not (s.get("rows", []) as Array).is_empty():
		# Evidence ladder: one row per kind of evidence, each with its own chip.
		var rows: Array = s["rows"]
		for i in rows.size():
			var e: Dictionary = rows[i]
			var est := str(e.get("status", "unknown"))
			var row := UI.hbox(6)
			row.add_child(PlanUiKit.wrap_label("%d. %s" % [i + 1, str(e.get("title", ""))]))
			row.add_child(PlanUiKit.badge(str(AccuracyReport.EVIDENCE_WORDS.get(est, est)), str(PlanUiModels.STATUS_TONES.get(est, "faint"))))
			v.add_child(row)
			v.add_child(PlanUiKit.wrap_label(str(e.get("text", "")), "Faint"))
		return card
	if str(s.get("id", "")) == "calibration" and not (report.get("calibration", []) as Array).is_empty():
		for c: Dictionary in PlanUiModels.calibration_rows(report):
			var row := UI.hbox(6)
			row.add_child(PlanUiKit.wrap_label(str(c["name"])))
			row.add_child(PlanUiKit.badge(str(c["verdict_text"]), str(c["tone"])))
			v.add_child(row)
			v.add_child(PlanUiKit.wrap_label(str(c["text"]), "Faint"))
		return card
	for l in s.get("lines", []):
		v.add_child(PlanUiKit.wrap_label(str(l), "Dim"))
	if (s.get("lines", []) as Array).is_empty():
		v.add_child(PlanUiKit.wrap_label("Nothing known to report.", "Faint"))
	return card


func _calibrate() -> void:
	_help.visible = true
	if ctx.has_signal(CALIBRATE_SIGNAL):
		ctx.emit_signal(CALIBRATE_SIGNAL)


const PLACEMENT_DIR := "user://private_data/placement_checks"


func write_placement_checks(dir: String = PLACEMENT_DIR) -> Dictionary:
	## PlacementCheck of every calibrated reference image -> <dir>/<time>_<image id>.json + .md
	## (private: made from the user's own screenshots). {written, labels: [..], paths: [..], text}.
	var out := {"written": 0, "labels": [], "paths": [], "text": ""}
	var imgs: Array = LayoutIO.normalize_reference(ctx.layout().reference).get("images", [])
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for im in imgs:
		if not im is Dictionary or CalibrationMath.record_of(im).is_empty():
			continue
		var r := PlacementCheck.build(im, ctx.map, ctx.layout(), Time.get_datetime_string_from_system(true))
		var base := dir.path_join("%s_%s" % [stamp, str(im.get("id", "image")).validate_filename()])
		JsonUtil.write_atomic(base + ".json", JsonUtil.stringify(r, true), false)
		JsonUtil.write_atomic(base + ".md", PlacementCheck.to_markdown(r), false)
		out["written"] = int(out["written"]) + 1
		out["labels"].append(str(r["label"]))
		out["paths"].append(base + ".json")
	out["text"] = "No calibrated screenshot yet: calibrate one first (Calibrate a screenshot)." if int(out["written"]) == 0 \
		else "Placement check written for %d screenshot(s): %s (private_data/placement_checks)" % [out["written"], ", ".join(PackedStringArray(out["labels"]))]
	return out
