class_name CompareLegend
extends PanelContainer
## Floating legend of "Compare with my farm" (View tab / Build tab): what the
## colours on the farm mean and how many objects are unchanged, moved, new and
## removed (PlanContext.compare_counts(), i.e. Baseline.diff). main.gd places it
## in a free corner of the canvas while the comparison is on.

signal close_requested

var ctx: PlanContext
var _title: Label
var _counts: Dictionary = {}     ## key -> Label
var _hint: Label
var _sig := ""
var tight := false

const KEYS := [["unchanged", "unchanged", PlanOverlay.C_UNCHANGED], ["moved", "moved", PlanOverlay.C_MOVED],
	["new", "new", PlanOverlay.C_NEW], ["removed", "removed", PlanOverlay.C_REMOVED]]


func setup(context: PlanContext) -> void:
	ctx = context
	var sb := UiTheme.box(UiTheme.c("panel"), 12, UiTheme.c("border"), 1, Vector4(10, 6, 8, 8))
	sb.shadow_color = UiTheme.c("shadow")
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 3)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UI.vbox(4)
	add_child(v)
	var head := UI.hbox(6)
	head.add_child(UI.icon_rect("git-compare", 16, UiTheme.c("text_dim")))
	_title = UI.label("", "Dim")
	_title.add_theme_font_size_override("font_size", 13)
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.custom_minimum_size.x = 120
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var x := UI.icon_button("x", "Stop comparing", "Ghost", 14)
	x.pressed.connect(func(): close_requested.emit())
	head.add_child(x)
	v.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	v.add_child(grid)
	for k: Array in KEYS:
		var h := UI.hbox(6)
		h.add_child(PlanUiKit.color_dot(k[2], 10))
		var l := UI.label("", "Dim")
		l.add_theme_font_size_override("font_size", 13)
		h.add_child(l)
		grid.add_child(h)
		_counts[k[0]] = l
	_hint = UI.label("Arrows: from the old spot · dashed red: removed", "Faint")
	_hint.add_theme_font_size_override("font_size", 11)
	v.add_child(_hint)
	ctx.changed.connect(refresh)
	refresh()


func set_tight(on: bool) -> void:
	## Small canvas (large UI scale): no hint line, shorter title.
	if on == tight:
		return
	tight = on
	_hint.visible = not on
	_sig = ""
	refresh()


func refresh() -> void:
	if ctx == null or not visible:
		return
	var c := ctx.compare_counts()
	var bl: Variant = ctx.plan().get("baseline")
	var nm := str((bl as Dictionary).get("name", "my farm")) if bl is Dictionary else "my farm"
	var sig := "%s|%s" % [nm, str(c)]
	if sig == _sig:
		return
	_sig = sig
	_title.text = ("vs. “%s”" if tight else "Compared with “%s”") % nm
	_title.tooltip_text = _title.text
	for k: Array in KEYS:
		(_counts[k[0]] as Label).text = "%s %s" % [UI.fmt_int(int(c.get(k[0], 0))), k[1]]
