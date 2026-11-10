class_name PlanPanel
extends PanelContainer
## The Plan workspace (docs/PLANNING.md): takes the inspector's place on the
## right while open. A rail of tabs (icon + label) in workflow order — Budget,
## Areas, Phases, Shop, Build, Guide, Accuracy — and the current tab, built on
## first use. Tabs whose script isn't there yet show a short placeholder, so
## the panel never depends on them. Closed with its X, Esc or J (main.gd).

signal close_requested
signal tab_changed(tab_id: String)

## [id, label, icon, script, what it is about]
const TABS := [
	["budget", "Budget", "coins", "res://src/ui/plan/plan_budget_tab.gd", "What the design costs: totals per scope, unknown prices, targets"],
	["areas", "Areas", "square-dashed", "res://src/ui/plan/plan_areas_tab.gd", "Named parts of the farm (rectangles and polygons)"],
	["phases", "Phases", "layers", "res://src/ui/plan/plan_phases_tab.gd", "Build order, what each phase costs and what you can afford"],
	["shop", "Shop", "package-open", "res://src/ui/plan/plan_shop_tab.gd", "Shopping list: what to buy, grouped"],
	["build", "Build", "list-checks", "res://src/ui/plan/plan_build_tab.gd", "Checklist: bought and placed in Hay Day"],
	["guide", "Guide", "map", "res://src/ui/plan/plan_guide_tab.gd", "Step-by-step guide for rebuilding the design in the game"],
	["accuracy", "Accuracy", "ruler", "res://src/ui/plan/plan_accuracy_tab.gd", "How exact the map, landmarks and footprints are"],
]

var ctx: PlanContext
var current := ""
var _rail: VBoxContainer
var _rail_btns: Dictionary = {}
var _title: Label
var _stack: Control
var _pages: Dictionary = {}         ## tab id -> ScrollContainer holding the tab
var tabs: Dictionary = {}           ## tab id -> PlanTab (built ones)


static func tab_ids() -> Array:
	var out: Array = []
	for t in TABS:
		out.append(t[0])
	return out


static func tab_info(id: String) -> Array:
	for t in TABS:
		if t[0] == id:
			return t
	return []


func setup(context: PlanContext) -> void:
	ctx = context
	theme_type_variation = "FloatingPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var h := UI.hbox(10)
	add_child(h)
	var rail_scroll := ScrollContainer.new()
	rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	rail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h.add_child(rail_scroll)
	_rail = UI.vbox(2)
	rail_scroll.add_child(_rail)
	var group := ButtonGroup.new()
	for t in TABS:
		var b := UI.button(t[1], "", "%s — %s" % [t[1], t[4]], "Rail")
		b.icon = Icons.get_icon(t[2], 20)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.expand_icon = false
		b.add_theme_font_size_override("font_size", 11)
		b.custom_minimum_size = Vector2(62, 0)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(open.bind(t[0]))
		_rail.add_child(b)
		_rail_btns[t[0]] = b
	h.add_child(VSeparator.new())
	var right := UI.vbox(8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(right)
	var head := UI.hbox(6)
	_title = UI.label("Plan", "Heading")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	head.add_child(_title)
	var x := UI.icon_button("x", "Close the plan (Esc / J)")
	x.pressed.connect(func(): close_requested.emit())
	head.add_child(x)
	right.add_child(head)
	_stack = Control.new()
	_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stack.clip_contents = true
	right.add_child(_stack)


var compact := false


func set_compact(on: bool) -> void:
	## Narrow panel (small window / large UI scale): the rail shows icons only
	## (the labels stay in the tooltips), leaving the room to the tab.
	if on == compact or _rail == null:
		return
	compact = on
	for t in TABS:
		var b: Button = _rail_btns[t[0]]
		b.text = "" if on else str(t[1])
		b.custom_minimum_size.x = 40 if on else 62


func open(tab_id: String) -> void:
	if tab_info(tab_id).is_empty():
		tab_id = "budget"
	if not _pages.has(tab_id):
		_build_page(tab_id)
	current = tab_id
	for id in _pages:
		(_pages[id] as Control).visible = id == tab_id
	for id in _rail_btns:
		(_rail_btns[id] as Button).set_pressed_no_signal(id == tab_id)
	_title.text = str(tab_info(tab_id)[1])
	tab_changed.emit(tab_id)


func page_of(tab_id: String) -> PlanTab:
	return tabs.get(tab_id) as PlanTab


func _build_page(tab_id: String) -> void:
	var info := tab_info(tab_id)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.visible = false
	_stack.add_child(scroll)
	var tab: PlanTab = null
	var path: String = info[3]
	if ResourceLoader.exists(path):
		var sc: Variant = load(path)
		if sc is Script:
			var inst: Variant = (sc as Script).new()
			if inst is PlanTab:
				tab = inst
			elif inst is Node:
				(inst as Node).free()
	if tab == null:
		tab = ComingSoon.new()
		(tab as ComingSoon).what = str(info[4])
	if tab.tab_id.is_empty():
		tab.tab_id = tab_id
	if tab.title.is_empty():
		tab.title = str(info[1])
	if tab.icon.is_empty():
		tab.icon = str(info[2])
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(tab)
	tab.setup(ctx)
	_pages[tab_id] = scroll
	tabs[tab_id] = tab


## Stand-in for a tab whose script is not in this build yet.
class ComingSoon:
	extends PlanTab
	var what := ""

	func _build() -> void:
		var card := UI.card()
		var v := UI.vbox(6)
		card.add_child(v)
		v.add_child(UI.label(what, "Dim", true))
		v.add_child(UI.label("This part of the plan isn't available in this build yet.", "Faint", true))
		add_child(card)
