class_name ReadinessCard
extends RefCounted
## "Can I build this?" card (top of Plan › Budget): what blocks rebuilding the
## design in Hay Day, kept apart from what it costs (PlanContext.readiness(),
## Readiness rows). Each row selects, frames and highlights its objects.


static func build(ctx: PlanContext) -> Control:
	var r := ctx.readiness()
	var card := UI.card()
	var v := UI.vbox(2)
	card.add_child(v)
	var head := UI.hbox(8)
	var ttl := UI.label("Can I build this?", "Heading")
	ttl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ttl.clip_text = true
	ttl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(ttl)
	var blocking := int(r.get("blocking", 0))
	var checks := int(r.get("checks", 0))
	if blocking > 0:
		head.add_child(PlanUiKit.badge("%d blocking" % blocking, "danger"))
	elif checks > 0:
		head.add_child(PlanUiKit.badge("To check", "warn"))
	else:
		head.add_child(PlanUiKit.badge("Ready", "accent"))
	v.add_child(head)
	var rows: Array = r.get("rows", [])
	if rows.is_empty():
		v.add_child(UI.label("Nothing blocks rebuilding this design (prices aside).", "Dim", true))
	for row: Dictionary in rows:
		v.add_child(_row(ctx, row))
	if not bool(r.get("realistic", false)):
		v.add_child(UI.label("Farm and land levels are checked in Realistic mode.", "Faint", true))
	return card


static func _row(ctx: PlanContext, row: Dictionary) -> Control:
	var blocking := int(row.get("severity", 0)) == Readiness.BLOCKING
	var col := UiTheme.c("danger") if blocking else UiTheme.c("warn")
	var h := UI.hbox(6)
	h.add_child(PlanUiKit.color_dot(col, 8))
	var uids: Array = row.get("uids", [])
	var tip := str(row.get("detail", ""))
	if not uids.is_empty():
		tip += "\nClick: select them and show them on the farm"
	var id := str(row.get("id", ""))
	var b := PlanUI.row_button(str(row.get("label", "")), tip, func(): _show(ctx, id, uids, col))
	b.add_theme_font_size_override("font_size", 13)
	b.set_meta("readiness_row", id)
	if blocking:
		b.add_theme_color_override("font_color", UiTheme.c("text"))
	h.add_child(b)
	if id == Readiness.NO_INVENTORY:
		var rec := UI.icon_button("clipboard-check", "Record what you own in Hay Day", "Ghost", 16)
		rec.pressed.connect(func(): ctx.request_inventory.emit())
		h.add_child(rec)
	return h


static func _show(ctx: PlanContext, id: String, uids: Array, col: Color) -> void:
	if uids.is_empty():
		if id == Readiness.LAND_LEVEL:
			ctx.toast("Raise your farm level (top bar) or leave those expansions locked", "info")
		return
	ctx.request_highlight.emit(uids.duplicate(), col)
	ctx.request_focus.emit(uids.duplicate(), true)
