class_name PlanScope
extends RefCounted
## Pure helpers of the planning UI (budget widget, Plan panel, plan overlay,
## area tool): budget scope, area overlaps, heatmap buckets, targets, number
## formatting, area drafts, widget placement. No scene / App dependencies, so
## they are unit-tested (tests/unit/test_plan_scope.gd).

const SCOPE_FARM := "farm"
const SCOPE_SELECTION := "selection"
const SCOPE_AREA := "area"
const SCOPE_PHASE := "phase"

## Heatmap buckets (heat_bucket()).
const HEAT_NOT_BUYABLE := -2
const HEAT_UNKNOWN := -1
const HEAT_NONE := 0          ## nothing to pay in this mode (owned, acquired, free)
const HEAT_LOW := 1           ## < 100 coins
const HEAT_MID := 2           ## < 1,000 coins
const HEAT_HIGH := 3          ## < 10,000 coins
const HEAT_TOP := 4           ## >= 10,000 coins
const HEAT_OTHER := 5         ## paid only in other currencies (diamonds, vouchers, ...): never converted
const HEAT_LIMITS := [100, 1000, 10000]
const HEAT_LEGEND := [
	[HEAT_LOW, "under 100 coins"], [HEAT_MID, "100 – 999 coins"], [HEAT_HIGH, "1,000 – 9,999 coins"],
	[HEAT_TOP, "10,000 coins or more"], [HEAT_OTHER, "other currencies only (never converted)"],
	[HEAT_NONE, "nothing to pay in this mode"], [HEAT_UNKNOWN, "price unknown (hatched)"],
	[HEAT_NOT_BUYABLE, "can't be bought (hatched)"],
]

## Corners of the canvas the budget widget can sit in.
const CORNERS := ["bl", "br", "tl", "tr"]
const CORNER_NAMES := {"bl": "Bottom left", "br": "Bottom right", "tl": "Top left", "tr": "Top right"}

## Mode texts (labels + the tooltips that explain them, docs/PLANNING.md §4).
const MODE_LABELS := {"design": "Design cost", "to_buy": "To buy", "remaining": "Remaining"}
const MODE_HELP := {
	"design": "Design cost: every object priced as a purchase (copy #1, #2, … in build order), ignoring your inventory. What the whole design would cost from scratch.",
	"to_buy": "To buy: objects not covered by the copies you own, plus the land the design needs. What you still have to buy.",
	"remaining": "Remaining: like To buy, but copies you already bought during this project (shopping list) are deducted too.",
}
const MODE_DEDUCTS := {
	"design": "Inventory ignored", "to_buy": "Owned copies deducted", "remaining": "Owned + bought copies deducted",
}


# --- scope ---------------------------------------------------------------------------------

static func resolve(selection: Array, active_area: String, active_phase: String, pin: String, plan: Dictionary) -> Dictionary:
	## Budget scope: pinned "farm" → whole farm; else the selection when there is
	## one, else the active area, else the active phase, else the whole farm.
	## {kind, id, uids (Array, or null for area / phase / farm), label}.
	if pin != SCOPE_FARM:
		if not selection.is_empty():
			return {"kind": SCOPE_SELECTION, "id": "", "uids": selection.duplicate(),
				"label": "Selection · %d object%s" % [selection.size(), "" if selection.size() == 1 else "s"]}
		var a := PlanDoc.area(plan, active_area) if not active_area.is_empty() else {}
		if not a.is_empty():
			return {"kind": SCOPE_AREA, "id": active_area, "uids": null, "label": "Area · %s" % str(a.get("name", active_area))}
		var p := PlanDoc.phase(plan, active_phase) if not active_phase.is_empty() else {}
		if not p.is_empty():
			return {"kind": SCOPE_PHASE, "id": active_phase, "uids": null, "label": "Phase · %s" % str(p.get("name", active_phase))}
	return {"kind": SCOPE_FARM, "id": "", "uids": null, "label": "Whole farm"}


static func totals(engine: BudgetEngine, scope: Dictionary, mode: String) -> BudgetEngine.Totals:
	## Phase scopes use phase_totals (with their land), areas area_totals.
	match str(scope.get("kind", SCOPE_FARM)):
		SCOPE_SELECTION:
			return engine.totals(scope.get("uids", []), mode)
		SCOPE_AREA:
			return engine.area_totals(str(scope["id"]), mode)
		SCOPE_PHASE:
			return engine.phase_totals(str(scope["id"]), mode)
	return engine.totals(null, mode)


static func scope_uids(engine: BudgetEngine, scope: Dictionary) -> Variant:
	## uids of a scope (null = whole farm).
	match str(scope.get("kind", SCOPE_FARM)):
		SCOPE_SELECTION:
			return scope.get("uids", [])
		SCOPE_AREA:
			return engine.area_uids(str(scope["id"]))
		SCOPE_PHASE:
			return engine.phase_uids(str(scope["id"]))
	return null


static func shared_objects(area_uids: Dictionary) -> Dictionary:
	## Objects counted in more than one area (area id -> uids):
	## {"objects": distinct shared uids, "pairs": [[a, b, n], ...]} (pairs in id order).
	var ids := area_uids.keys()
	ids.sort()
	var seen := {}
	var shared := {}
	var pairs: Array = []
	for i in ids.size():
		for u in area_uids[ids[i]]:
			if seen.has(u):
				shared[u] = true
			seen[u] = true
		for j in range(i + 1, ids.size()):
			var set_b := {}
			for u in area_uids[ids[j]]:
				set_b[u] = true
			var n := 0
			for u in area_uids[ids[i]]:
				if set_b.has(u):
					n += 1
			if n > 0:
				pairs.append([ids[i], ids[j], n])
	return {"objects": shared.size(), "pairs": pairs}


static func overlapping_areas(plan: Dictionary) -> Array:
	## Pairs of areas whose shapes share at least one tile: [[a, b], ...].
	var list := PlanDoc.areas(plan)
	var out: Array = []
	for i in list.size():
		var a: Dictionary = list[i]
		var ba := PlanDoc.area_bounds(a)
		for j in range(i + 1, list.size()):
			var b: Dictionary = list[j]
			var bb := PlanDoc.area_bounds(b)
			if not ba.intersects(bb):
				continue
			var c := ba.intersection(bb)
			var hit := false
			for y in range(c.position.y, c.end.y):
				for x in range(c.position.x, c.end.x):
					if PlanDoc.tile_in_area(a, Vector2i(x, y)) and PlanDoc.tile_in_area(b, Vector2i(x, y)):
						hit = true
						break
				if hit:
					break
			if hit:
				out.append([str(a.get("id")), str(b.get("id"))])
	return out


# --- heatmap ---------------------------------------------------------------------------------

static func heat_bucket(cost: Variant, price_state: String) -> int:
	## Bucket of one object's own cost in a mode (BudgetEngine.object_cost /
	## object_info price_state). Unknown and unbuyable never count as 0.
	if cost == null:
		return HEAT_NOT_BUYABLE if price_state == "not_buyable" else HEAT_UNKNOWN
	var c: Dictionary = cost
	if Currency.is_zero(c):
		return HEAT_NONE
	var coins := int(c.get(Currency.COINS, 0))
	if coins <= 0:
		return HEAT_OTHER
	for i in HEAT_LIMITS.size():
		if coins < int(HEAT_LIMITS[i]):
			return HEAT_LOW + i
	return HEAT_TOP


static func heat_color(bucket: int) -> Color:
	match bucket:
		HEAT_LOW: return Color(0.42, 0.80, 0.42, 0.42)
		HEAT_MID: return Color(0.93, 0.85, 0.30, 0.46)
		HEAT_HIGH: return Color(0.96, 0.56, 0.20, 0.50)
		HEAT_TOP: return Color(0.90, 0.22, 0.20, 0.55)
		HEAT_OTHER: return Color(0.62, 0.42, 0.92, 0.48)
		HEAT_UNKNOWN: return Color(0.55, 0.57, 0.60, 0.40)
		HEAT_NOT_BUYABLE: return Color(0.30, 0.30, 0.34, 0.50)
	return Color(1, 1, 1, 0.10)


# --- targets / ranking ---------------------------------------------------------------------

static func over_target(cost: Dictionary, target: Variant) -> Dictionary:
	## Per currency: how much `cost` exceeds the target ({} = within it or no target).
	## Only currencies the target names are compared (never converted).
	var out := {}
	if not target is Dictionary:
		return out
	for k in target:
		var lim := int(target[k])
		var have := int(cost.get(k, 0))
		if have > lim:
			out[str(k)] = have - lim
	return out


static func most_expensive(engine: BudgetEngine, uids: Variant, mode: String, n: int = 5) -> Array:
	## Objects with the highest known coin cost in `mode` (then diamonds): [{uid, cost}].
	var rows: Array = []
	var list: Array = engine.layout.objects.keys() if uids == null else uids
	for u in list:
		var c: Variant = engine.object_cost(int(u), mode)
		if c == null or Currency.is_zero(c):
			continue
		rows.append({"uid": int(u), "cost": c, "k": [int(c.get(Currency.COINS, 0)), int(c.get(Currency.DIAMONDS, 0)), -int(u)]})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["k"] > b["k"])
	var out: Array = []
	for r in rows.slice(0, n):
		out.append({"uid": r["uid"], "cost": r["cost"]})
	return out


# --- numbers ---------------------------------------------------------------------------------

static func abbreviate(n: int) -> String:
	## Compact amounts for narrow places: 950, 12.3k, 123k, 4.56M (full value in tooltips).
	var a := absi(n)
	var neg := "-" if n < 0 else ""
	if a < 10000:
		return neg + Currency.format_amount(a)
	if a < 1000000:
		var k := floorf(a / 100.0) / 10.0
		return neg + (("%.1fk" % k) if k < 100.0 else ("%dk" % int(k)))
	var m := floorf(a / 10000.0) / 100.0
	return neg + (("%.2fM" % m) if m < 10.0 else ("%.1fM" % m))


static func unknown_text(t: BudgetEngine.Totals) -> String:
	## "3 objects: price unknown · 2 can't be bought" ("" when the total is exact).
	var parts: PackedStringArray = []
	if t.unknown_price_objects > 0:
		parts.append("%d with unknown price" % t.unknown_price_objects)
	if t.not_buyable_objects > 0:
		parts.append("%d can't be bought" % t.not_buyable_objects)
	if not t.unknown_cost_plots.is_empty():
		parts.append("%d plot%s with unknown supplies" % [t.unknown_cost_plots.size(), "" if t.unknown_cost_plots.size() == 1 else "s"])
	return " · ".join(parts)


# --- area drafts -----------------------------------------------------------------------------

static func snap_corner(g: Vector2) -> Vector2i:
	## Nearest tile corner of a grid point (polygon vertices sit on tile corners).
	return Vector2i(roundi(g.x), roundi(g.y))


static func rect_area(r: Rect2i, name: String) -> Dictionary:
	return {"name": name, "rect": [r.position.x, r.position.y, maxi(1, r.size.x), maxi(1, r.size.y)], "visible": true}


static func polygon_area(points: Array, name: String) -> Dictionary:
	var pts: Array = []
	for p in points:
		pts.append([int(p.x), int(p.y)])
	return {"name": name, "points": pts, "visible": true}


static func clean_polygon(points: Array) -> Array:
	## Drops repeated consecutive corners (and a last one equal to the first).
	var out: Array = []
	for p in points:
		if out.is_empty() or out[out.size() - 1] != p:
			out.append(p)
	while out.size() > 1 and out[0] == out[out.size() - 1]:
		out.pop_back()
	return out


static func polygon_ok(points: Array) -> bool:
	## At least three distinct corners enclosing some area.
	var pts := clean_polygon(points)
	if pts.size() < 3:
		return false
	var a := 0.0
	for i in pts.size():
		var p: Vector2 = Vector2(pts[i])
		var q: Vector2 = Vector2(pts[(i + 1) % pts.size()])
		a += p.x * q.y - q.x * p.y
	return absf(a) > 0.5


static func next_area_name(plan: Dictionary) -> String:
	var used := {}
	for a in PlanDoc.areas(plan):
		used[str(a.get("name", ""))] = true
	var n := PlanDoc.areas(plan).size() + 1
	while used.has("Area %d" % n):
		n += 1
	return "Area %d" % n


static func next_phase_name(plan: Dictionary) -> String:
	var used := {}
	for p in PlanDoc.phases(plan):
		used[str(p.get("name", ""))] = true
	var n := PlanDoc.phases(plan).size() + 1
	while used.has("Phase %d" % n):
		n += 1
	return "Phase %d" % n


static func selection_rect(layout: FarmLayout, uids: Array) -> Rect2i:
	## Bounding tile rectangle of the selected objects' footprints (size 0 = none).
	var live: Array = uids.filter(func(u): return layout.objects.has(u))
	if live.is_empty():
		return Rect2i()
	return layout.bounds_of(live)


# --- widget placement --------------------------------------------------------------------------

static func corner_position(corner: String, canvas: Rect2, size: Vector2, pad: float = 8.0) -> Vector2:
	## Top-left of a box of `size` in a corner of the free canvas rectangle, kept inside it.
	var x := canvas.position.x + pad if corner in ["bl", "tl"] else canvas.end.x - size.x - pad
	var y := canvas.position.y + pad if corner in ["tl", "tr"] else canvas.end.y - size.y - pad
	x = clampf(x, canvas.position.x, maxf(canvas.position.x, canvas.end.x - size.x))
	y = clampf(y, canvas.position.y, maxf(canvas.position.y, canvas.end.y - size.y))
	return Vector2(x, y)
