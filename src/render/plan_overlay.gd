class_name PlanOverlay
extends Node2D
## Planning marks on the farm (docs/PLANNING.md): area outlines, soft fills and
## names, the active area / phase, objects highlighted by a Plan tab, progress
## checks on objects marked placed, the recreation guide's current step(s) with
## their numbers, the cost heatmap and the area tool's draft. Purely
## presentational: it reads the PlanContext and redraws when told (refresh()),
## never per frame.
##
## Two canvas items: this node sits between the objects and the editor overlay
## (heatmap, names, checks, numbers, outlines that must stay visible), its
## `under` node below the objects (area fills). Both use visibility layer LAYER, which no
## Exporter mask contains: the plan is only exported when an export asks for it
## (main.gd switches the layer for that one capture, with export_opts set).

const LAYER := 16
const FONT_SIZE := 14
const C_TAG_TEXT := Color(1, 1, 1, 0.97)
const C_CHECK := Color(0.30, 0.82, 0.46, 0.96)
const C_STEP := Color(0.98, 0.76, 0.22, 0.98)
const C_STEP_NEXT := Color(0.62, 0.78, 0.98, 0.95)
const C_DRAFT := Color(1.0, 1.0, 1.0, 0.95)
const C_DRAFT_BAD := Color(1.0, 0.45, 0.4, 0.95)

var ctx: PlanContext
var zoom := 1.0
var visible_rect := Rect2()
var font: Font
var under: Under
## Guide marks are shown only while they matter (main.gd: the Guide or Build tab
## is open, or a step was picked), so everyday designing stays uncluttered.
var guide_active := false
## Objects a Plan tab asked to highlight (PlanContext.request_highlight).
var highlight_uids: Array = []
var highlight_color := Color(1.0, 0.85, 0.3)
## Area tool draft: kind "" | "rect" | "polygon"; rect in tiles, polygon corners
## (Vector2i, tile corners), cursor = grid point under the pointer.
var draft_kind := ""
var draft_rect := Rect2i()
var draft_points: Array = []
var draft_cursor := Vector2.ZERO
var draft_valid := true
## Export: {} = the live view. Else what the image shows:
## {"areas": bool, "area_ids": [] (all) | [ids], "guide": bool, "steps": [step numbers] ([] = none)}.
var export_opts: Dictionary = {}
var _heat: Dictionary = {}          ## uid -> bucket (per engine version + mode)
var _heat_key := ""


## Fills and heatmap, drawn below the objects.
class Under:
	extends Node2D
	var plan: PlanOverlay

	func _draw() -> void:
		if plan != null:
			plan._draw_under(self)


func _init() -> void:
	visibility_layer = LAYER
	under = Under.new()
	under.plan = self
	under.visibility_layer = LAYER
	under.name = "PlanUnder"


func _ready() -> void:
	font = UiTheme.font_bold if UiTheme.font_bold != null else ThemeDB.fallback_font


func refresh() -> void:
	queue_redraw()
	if under != null:
		under.queue_redraw()


func set_exporting(opts: Dictionary, layer: int) -> void:
	## main.gd: show `opts` and put both canvas items on `layer` for one capture
	## ({} and LAYER restore the live view).
	export_opts = opts
	visibility_layer = layer
	under.visibility_layer = layer
	refresh()


func _exporting() -> bool:
	return not export_opts.is_empty()


func _layer(key: String) -> bool:
	if ctx == null:
		return false
	if _exporting():
		match key:
			"areas": return bool(export_opts.get("areas", false))
			"guide": return bool(export_opts.get("guide", false))
		return false
	return bool(ctx.layers.get(key, false))


func _inv() -> float:
	return 1.0 / maxf(zoom, 0.05)


# --- below the objects --------------------------------------------------------------------

func _draw_under(ci: Node2D) -> void:
	if ctx == null or ctx.session == null:
		return
	if _layer("areas"):
		for a: Dictionary in _shown_areas():
			var poly := _area_world_polygon(a)
			if poly.size() < 3:
				continue
			var col := _area_color(a)
			if not Geometry2D.triangulate_polygon(poly).is_empty():
				ci.draw_colored_polygon(poly, Color(col.r, col.g, col.b, 0.13 if str(a.get("id")) != ctx.active_area else 0.22))
			var closed := poly.duplicate()
			closed.append(poly[0])
			ci.draw_polyline(closed, Color(col.r, col.g, col.b, 0.85), (3.0 if _exporting() else 2.0) * _inv(), true)


func _draw_heatmap(ci: Node2D) -> void:
	var eng := ctx.engine
	if eng == null:
		return
	var key := "%d|%s|%d" % [eng.version, ctx.mode, ctx.session.layout.objects.size()]
	if key != _heat_key:
		_heat_key = key
		_heat.clear()
		for u: int in ctx.session.layout.objects:
			var c: Variant = eng.object_cost(u, ctx.mode)
			var st := "known"
			if c == null:
				st = str(eng.object_info(u).get("price_state", "unknown"))
			_heat[u] = PlanScope.heat_bucket(c, st)
	var lw := 1.2 * _inv()
	for u: int in _heat:
		var o: PlacedObject = ctx.session.layout.objects.get(u)
		if o == null:
			continue
		var b := int(_heat[u])
		if b == PlanScope.HEAT_NONE:
			continue
		var poly := Iso.footprint_polygon(o.origin, o.size)
		if visible_rect.size != Vector2.ZERO and not visible_rect.intersects(Iso.footprint_world_bounds(o.origin, o.size)):
			continue
		var col := PlanScope.heat_color(b)
		ci.draw_colored_polygon(poly, col)
		var closed := poly.duplicate()
		closed.append(poly[0])
		ci.draw_polyline(closed, Color(col.r, col.g, col.b, 0.9), lw, true)
		if b == PlanScope.HEAT_UNKNOWN or b == PlanScope.HEAT_NOT_BUYABLE:
			_hatch(ci, poly, Color(1, 1, 1, 0.55) if b == PlanScope.HEAT_UNKNOWN else Color(0, 0, 0, 0.55), lw, o.size)


static func _hatch(ci: CanvasItem, poly: PackedVector2Array, col: Color, w: float, size: Vector2i) -> void:
	## Stripes across a footprint diamond (top, right, bottom, left corners).
	var n := maxi(3, (size.x + size.y) * 2)
	for i in range(1, n):
		var t := float(i) / n
		ci.draw_line(poly[0].lerp(poly[1], t), poly[3].lerp(poly[2], t), col, w)


# --- above the objects ----------------------------------------------------------------------

func _draw() -> void:
	if ctx == null or ctx.session == null:
		_draw_draft()
		return
	var layout := ctx.session.layout
	if _layer("heatmap"):
		_draw_heatmap(self)
	if not _exporting():
		_draw_phase_highlight(layout)
		_draw_highlight(layout)
		if _layer("progress"):
			_draw_progress(layout)
	if _layer("areas"):
		for a: Dictionary in _shown_areas():
			_draw_area_label(a)
	# Step numbers last: they must stay readable over area names.
	if _layer("guide") and (_exporting() or guide_active or ctx.guide_step >= 1):
		_draw_guide()
	_draw_draft()


func _draw_area_label(a: Dictionary) -> void:
	var pts := PlanDoc.area_polygon(a)
	if pts.size() < 3:
		return
	var col := _area_color(a)
	var active := str(a.get("id")) == ctx.active_area and not _exporting()
	if active:
		var poly := _area_world_polygon(a)
		var closed := poly.duplicate()
		closed.append(poly[0])
		draw_polyline(closed, col.lightened(0.25), 3.0 * _inv(), true)
	# Name at the top corner of the shape (the north tip on screen), nudged inside.
	var top := Iso.grid_to_world(pts[0])
	for p in pts:
		var w := Iso.grid_to_world(p)
		if w.y < top.y:
			top = w
	_draw_tag(top + Vector2(0, 16.0 * _inv()), str(a.get("name", "")), col, active)


func _draw_phase_highlight(layout: FarmLayout) -> void:
	if ctx.active_phase.is_empty() or ctx.engine == null:
		return
	var ph := PlanDoc.phase(ctx.plan(), ctx.active_phase)
	if ph.is_empty():
		return
	var col := Color(str(ph.get("color", "#f2b84b")))
	for u in ctx.engine.phase_uids(ctx.active_phase):
		var o := layout.get_obj(int(u))
		if o != null:
			_outline(Iso.footprint_polygon(o.origin, o.size), col, 2.0)


func _draw_highlight(layout: FarmLayout) -> void:
	for u in highlight_uids:
		var o := layout.get_obj(int(u))
		if o == null:
			continue
		var poly := Iso.footprint_polygon(o.origin, o.size)
		draw_colored_polygon(poly, Color(highlight_color.r, highlight_color.g, highlight_color.b, 0.22))
		_outline(poly, highlight_color, 2.5)


func _draw_progress(layout: FarmLayout) -> void:
	## A small check above every object marked "placed in Hay Day" (or unchanged
	## from the baseline), only where the view is.
	var eng := ctx.engine
	if eng == null:
		return
	var placed: Dictionary = ctx.plan().get("placed", {})
	var bl: Variant = ctx.plan().get("baseline")
	if placed.is_empty() and not bl is Dictionary:
		return
	var r := 7.0 * _inv()
	for o: PlacedObject in layout.objects.values():
		var c := Iso.footprint_center(o.origin, o.size)
		if visible_rect.size != Vector2.ZERO and not visible_rect.has_point(c):
			continue
		if not (placed.has(str(o.uid)) or (bl is Dictionary and eng.is_placed(o.uid))):
			continue
		draw_circle(c, r, Color(0.06, 0.2, 0.1, 0.85))
		draw_circle(c, r * 0.82, C_CHECK)
		var w := 1.8 * _inv()
		draw_polyline(PackedVector2Array([c + Vector2(-0.45, 0.0) * r, c + Vector2(-0.1, 0.38) * r, c + Vector2(0.5, -0.38) * r]), Color(1, 1, 1, 0.98), w, true)


func _guide_steps() -> Array:
	## [[step, role]] of the steps to mark: role "current" | "next" | "export".
	var g := ctx.guide()
	var steps: Array = g.get("steps", [])
	if steps.is_empty():
		return []
	var out: Array = []
	if _exporting():
		var want: Array = export_opts.get("steps", [])
		var set_w := {}
		for n in want:
			set_w[int(n)] = true
		for s: Dictionary in steps:
			if set_w.has(int(s.get("number", 0))):
				out.append([s, "export"])
		return out
	if ctx.guide_step >= 1 and ctx.guide_step <= steps.size():
		return [[steps[ctx.guide_step - 1], "current"]]
	var pr: Dictionary = g.get("progress", {})
	var cur := int(pr.get("current", -1))
	var nxt := int(pr.get("next", -1))
	if cur >= 0 and cur < steps.size():
		out.append([steps[cur], "current"])
	if nxt >= 0 and nxt < steps.size():
		out.append([steps[nxt], "next"])
	return out


func _draw_guide() -> void:
	for pair: Array in _guide_steps():
		var s: Dictionary = pair[0]
		var role: String = pair[1]
		var col := C_STEP if role != "next" else C_STEP_NEXT
		var b: Variant = s.get("bounds")
		if not b is Rect2i or (b as Rect2i).size == Vector2i.ZERO:
			continue
		var r: Rect2i = b
		var poly := Iso.grid_rect_polygon(r)
		if role != "export":
			draw_colored_polygon(poly, Color(col.r, col.g, col.b, 0.14))
			_dashed(poly, col)
		var fb: Variant = s.get("from_bounds")
		if fb is Rect2i and (fb as Rect2i).size != Vector2i.ZERO and fb != b:
			var f: Rect2i = fb
			_dashed(Iso.grid_rect_polygon(f), Color(col.r, col.g, col.b, 0.6))
			draw_line(Iso.footprint_center(f.position, f.size), Iso.footprint_center(r.position, r.size), Color(col.r, col.g, col.b, 0.8), 2.0 * _inv())
		_draw_number(Iso.grid_to_world(Vector2(r.position)) + Vector2(0, -4.0 * _inv()), int(s.get("number", 0)), col, bool(s.get("done", false)))


func _draw_number(at: Vector2, n: int, col: Color, done: bool) -> void:
	## A round badge with the step number (screen-sized), its bottom at `at`.
	var inv := _inv()
	var txt := str(n)
	var fs := FONT_SIZE
	var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var rad := maxf(12.0, tw * 0.5 + 7.0)
	draw_set_transform(at, 0.0, Vector2(inv, inv))
	var c := Vector2(0, -rad)
	draw_circle(c, rad + 2.0, Color(0.08, 0.08, 0.08, 0.85))
	draw_circle(c, rad, col if not done else C_CHECK)
	draw_string(font, c + Vector2(-tw * 0.5, font.get_ascent(fs) * 0.5 - 1.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.1, 0.08, 0.02))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_draft() -> void:
	match draft_kind:
		"rect":
			if draft_rect.size == Vector2i.ZERO:
				return
			var poly := Iso.grid_rect_polygon(draft_rect)
			draw_colored_polygon(poly, Color(1, 1, 1, 0.14))
			_outline(poly, C_DRAFT, 2.0)
			_draw_tag(Iso.grid_to_world(Vector2(draft_rect.position)) + Vector2(0, 16.0 * _inv()), "%d × %d" % [draft_rect.size.x, draft_rect.size.y], Color(0.2, 0.2, 0.2), false)
		"polygon":
			var pts := PackedVector2Array()
			for p in draft_points:
				pts.append(Iso.grid_to_world(Vector2(p)))
			var col := C_DRAFT if draft_valid else C_DRAFT_BAD
			if pts.size() >= 3 and not Geometry2D.triangulate_polygon(pts).is_empty():
				draw_colored_polygon(pts, Color(1, 1, 1, 0.12))
			var line := pts.duplicate()
			line.append(Iso.grid_to_world(draft_cursor))
			if line.size() >= 2:
				draw_polyline(line, col, 2.0 * _inv(), true)
			if pts.size() >= 2:
				draw_line(line[line.size() - 1], pts[0], Color(col.r, col.g, col.b, 0.35), 1.5 * _inv())
			for i in pts.size():
				draw_circle(pts[i], (6.0 if i == 0 else 4.0) * _inv(), col)


# --- helpers ---------------------------------------------------------------------------------

func _shown_areas() -> Array:
	var out: Array = []
	var only: Array = export_opts.get("area_ids", []) if _exporting() else []
	for a in PlanDoc.areas(ctx.plan()):
		if not bool(a.get("visible", true)) and not (str(a.get("id")) == ctx.active_area and not _exporting()):
			continue
		if not only.is_empty() and not str(a.get("id")) in only:
			continue
		out.append(a)
	return out


static func _area_world_polygon(a: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in PlanDoc.area_polygon(a):
		out.append(Iso.grid_to_world(p))
	return out


static func _area_color(a: Dictionary) -> Color:
	var s := str(a.get("color", "#6fb3e0"))
	return Color.from_string(s, Color("#6fb3e0"))


func _outline(poly: PackedVector2Array, col: Color, w: float) -> void:
	var p := poly.duplicate()
	p.append(poly[0])
	draw_polyline(p, col, w * _inv(), true)


func _dashed(poly: PackedVector2Array, col: Color) -> void:
	var w := 2.0 * _inv()
	var dash := 9.0 * _inv()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var n := maxi(1, int(a.distance_to(b) / dash))
		for k in range(0, n, 2):
			draw_line(a.lerp(b, float(k) / n), a.lerp(b, minf(1.0, float(k + 1) / n)), col, w)


func _draw_tag(at: Vector2, text: String, col: Color, strong: bool) -> void:
	## Name box in screen-size pixels, centred on `at`.
	if text.is_empty():
		return
	var inv := _inv()
	var fs := FONT_SIZE
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_set_transform(at, 0.0, Vector2(inv, inv))
	var box := Rect2(Vector2(-sz.x * 0.5 - 8.0, -font.get_height(fs) * 0.5 - 3.0), Vector2(sz.x + 16.0, font.get_height(fs) + 6.0))
	var bg := Color(col.r * 0.45, col.g * 0.45, col.b * 0.45, 0.92 if strong else 0.82)
	draw_rect(box, bg, true)
	draw_rect(box, Color(col.r, col.g, col.b, 0.95), false, 2.0 if strong else 1.0)
	draw_string(font, Vector2(-sz.x * 0.5, box.position.y + 3.0 + font.get_ascent(fs)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_TAG_TEXT)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
