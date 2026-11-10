class_name RecreationGuide
extends RefCounted
## Step-by-step guide for rebuilding a design in Hay Day (docs/PLANNING.md §5).
## Pure: no scene / App dependencies; the same input always gives the same
## steps in the same order with the same ids.
##
## Stages, in order:
##   1 land        unlock the expansion plots the design stands on that are still
##                 locked (baseline "unlocked_plots" when recorded, else the
##                 layout's unlocked_plots), plus plots that must be unlocked on the
##                 way to reach them (map plot neighbours)
##   2 clear       clear obstacles of the baseline the design no longer has
##                 (category "obstacle", or items that can't be moved)
##   3 make_room   put removed baseline objects in storage, then move the objects
##                 the design moved; a move whose target overlaps the current tiles
##                 of another moving object goes after it, a cycle (swap) is broken
##                 by "put X in storage for now" + "place X from storage"
##   4 buildings   categories production, animal_home, farm_building, plus
##                 structures and water items covering >= BIG_AREA tiles
##   5 paths_fences connect style path/fence or category path/fence
##   6 nature      fruit trees, bushes, flowers, nature, fields
##   7 decor       everything else (decorations, furniture, seasonal, small
##                 structures, unknown items)
##   8 look        the chosen look of the farmhouse, truck and roadside shop
##                 (options.customization = SkinBudget.compute(); one step per
##                 landmark whose look is not the original, with the parts to buy)
## Editor planning markers (category "planning") are not game items and get no step.
## Within a stage: phases in build order (Unphased last), then clusters of the
## same item whose footprints touch (8-neighbourhood) — one step per cluster —
## items ordered by where they first appear (top of the screen first).
##
## Without a baseline every design object is "new" (stages 1 and 4–7).
## Each step: {id, number, stage, stage_key, stage_name, kind, phase, phase_name,
##   items, item_names, uids, count, reused, bounds: Rect2i, from_bounds: Rect2i,
##   plot, title, description, tiles_text, from_tiles_text, location: {...}, done}
## kind: unlock | clear | store | store_temp | move | place_from_storage | place | customize.
## done: every uid is marked placed (plan.placed) — or the step was ticked by
## hand (plan.steps_done[id], the only way for steps without objects to place).
## Step ids are derived from the content (kind, stage, phase, items, uids, plot),
## so ticks survive regenerating the guide.
##
## Landmark-relative text: nearest visible map landmark by footprint-centre
## distance, direction as the player sees the isometric screen (grid +x = screen
## down-right, +y = screen down-left: screen dx = gx - gy, dy = (gx + gy) / 2),
## distance = empty tiles between the two footprints (Chebyshev). Landmarks only
## come from the map (never invented); approximate ones are flagged.

const STAGES := [
	{"stage": 1, "key": "land", "name": "Unlock land"},
	{"stage": 2, "key": "clear", "name": "Clear obstacles"},
	{"stage": 3, "key": "make_room", "name": "Store and move existing objects"},
	{"stage": 4, "key": "buildings", "name": "Large buildings"},
	{"stage": 5, "key": "paths_fences", "name": "Paths and fences"},
	{"stage": 6, "key": "nature", "name": "Trees, bushes, flowers and fields"},
	{"stage": 7, "key": "decor", "name": "Decorations and finishing"},
	{"stage": 8, "key": "look", "name": "Farm look (customization)"},
]
const BUILDING_CATEGORIES := ["production", "animal_home", "farm_building"]
## Categories that count as large buildings when the footprint covers >= BIG_AREA tiles.
const LARGE_IF_BIG_CATEGORIES := ["structures", "water"]
const BIG_AREA := 4
const LINE_CATEGORIES := ["path", "fence"]
const LINE_STYLES := ["path", "fence"]
const NATURE_CATEGORIES := ["fruit_tree", "bush", "flowers", "nature", "field"]
const SKIP_CATEGORIES := ["planning"]
const OBSTACLE_CATEGORY := "obstacle"
const UNPHASED_NAME := "Unphased"
## Direction words by 45° screen sector, starting at screen-right, clockwise (y down).
const DIRECTIONS := ["right", "lower right", "below", "lower left", "left", "upper left", "above", "upper right"]


# --- public API ------------------------------------------------------------------------

static func build(layout: FarmLayout, map: FarmMap, plan: Dictionary, options: Dictionary = {}) -> Dictionary:
	## Ordered recreation steps for `layout`. Options:
	##   db: ItemDatabase       item names and categories (without it every item is
	##                          "decor" and named by id; obstacles are not recognised)
	##   baseline: Dictionary   overrides plan["baseline"] ({} = ignore the baseline)
	##   include_planned: bool  include planned ghosts (default true)
	##   big_area: int          tile threshold for structures / water (default BIG_AREA)
	##   customization: Dictionary  SkinBudget.compute() result: adds stage 8 steps
	##   primary: Dictionary    uid -> primary phase id when already known (e.g.
	##                          BudgetEngine.primary_phases(), the same rule as
	##                          PlanDoc.primary_phases(), which is used otherwise)
	## Returns {steps, progress, has_baseline, skipped_markers, phase_names, stages}.
	var db: ItemDatabase = options.get("db") as ItemDatabase
	var bv: Variant = options["baseline"] if options.has("baseline") else plan.get("baseline", {})
	var baseline: Dictionary = bv if bv is Dictionary else {}
	var has_base := Baseline.is_valid(baseline)
	var include_planned := bool(options.get("include_planned", true))
	var big_area := int(options.get("big_area", BIG_AREA))
	var diff: Dictionary = Baseline.diff(layout, baseline, db) if has_base else {}
	var primary: Dictionary = options["primary"] if options.get("primary") is Dictionary else PlanDoc.primary_phases(layout, plan)
	var world := _world_info(map, layout)
	var skipped := 0
	# Design objects the guide is about.
	var design: Array = []
	var uids := layout.objects.keys()
	uids.sort()
	for u in uids:
		var o: PlacedObject = layout.objects[u]
		if o.planned and not include_planned:
			continue
		if _category(db, o.item_id) in SKIP_CATEGORIES:
			skipped += 1
			continue
		design.append(o)
	var drafts: Array = []
	# 1 land
	drafts.append_array(_land_drafts(layout, map, plan, design, baseline, has_base, primary))
	# 2 clear + 3 make room (store)
	var removed_entries: Array = []
	var clear_entries: Array = []
	if has_base:
		for e: Dictionary in diff["removed"]:
			var cat := _category(db, str(e["item"]))
			if cat in SKIP_CATEGORIES:
				continue
			var en := {"uid": int(e["uid"]), "item": str(e["item"]), "rect": e["rect"], "phase": PlanDoc.area_phase_for_rect(plan, e["rect"])}
			if _is_obstacle(db, str(e["item"])):
				clear_entries.append(en)
			else:
				removed_entries.append(en)
	drafts.append_array(_ordered_clusters(_clusters(clear_entries, 2, "clear", "rect"), plan))
	drafts.append_array(_ordered_clusters(_clusters(removed_entries, 3, "store", "rect"), plan))
	# 3 make room (moves) + 4..7 placing
	var move_entries: Array = []
	var place_entries := {4: [], 5: [], 6: [], 7: []}
	for o: PlacedObject in design:
		var st := "new" if not has_base else str(diff["status"].get(o.uid, "new"))
		if st == "unchanged":
			continue
		var ph := str(primary.get(o.uid, PlanDoc.UNPHASED))
		if st == "moved":
			var mv: Dictionary = diff["moves"][o.uid]
			move_entries.append({"uid": o.uid, "item": o.item_id, "rect": mv["to"], "from": mv["from"], "phase": ph,
				"delta": (mv["to"] as Rect2i).position - (mv["from"] as Rect2i).position})
			continue
		var stage := stage_for_item(db.get_item(o.item_id) if db else null, o.size, big_area)
		(place_entries[stage] as Array).append({"uid": o.uid, "item": o.item_id, "rect": o.rect(), "phase": ph,
			"reused": has_base and (diff["reuse"] as Dictionary).has(o.uid)})
	drafts.append_array(_ordered_moves(_clusters(move_entries, 3, "move", "from"), plan))
	for stage in [4, 5, 6, 7]:
		drafts.append_array(_ordered_clusters(_clusters(place_entries[stage], stage, "place", "rect"), plan))
	# 8 the farm's look
	if options.get("customization") is Dictionary:
		for e: Dictionary in (options["customization"] as Dictionary).get("landmarks", []):
			var lm := map.landmark(str(e["id"])) if map else null
			drafts.append({"kind": "customize", "stage": 8, "phase": PlanDoc.UNPHASED, "uids": [], "item": "",
				"bounds": lm.rect() if lm else Rect2i(), "look": "%s:%s" % [e["id"], e["skin"]], "custom": e})
	# Finish the steps: ids, numbers, texts, done.
	var steps: Array = []
	var by_node := {}
	for d: Dictionary in drafts:
		var s := _finish(d, layout, map, plan, db, world)
		s["number"] = steps.size() + 1
		steps.append(s)
		if d.has("node"):
			by_node["%s/%s" % [d["node"], s["kind"]]] = s
	for s: Dictionary in steps:
		if s["kind"] == "store_temp":
			var back: Variant = by_node.get("%s/place_from_storage" % s["node"])
			if back != null:
				s["then_step"] = int(back["number"])
				var note := "it is in the way of other moves: you place it again in step %d" % int(back["number"])
				var desc := str(s["description"])
				s["description"] = desc + "; " + note if not desc.is_empty() else note.substr(0, 1).to_upper() + note.substr(1)
	for s: Dictionary in steps:
		s.erase("node")
	var names := {PlanDoc.UNPHASED: UNPHASED_NAME}
	for p in PlanDoc.phases(plan):
		names[str(p.get("id"))] = str(p.get("name", p.get("id")))
	return {"steps": steps, "progress": progress(steps, plan), "has_baseline": has_base,
		"skipped_markers": skipped, "phase_names": names, "stages": STAGES.duplicate(true)}


static func stage_for_item(it: ItemDef, size: Vector2i = Vector2i.ONE, big_area: int = BIG_AREA) -> int:
	## Build stage (4..7) of a new object of this item (see the class comment).
	if it == null:
		return 7
	if it.connect_style in LINE_STYLES or it.category in LINE_CATEGORIES:
		return 5
	if it.category in BUILDING_CATEGORIES:
		return 4
	if it.category in LARGE_IF_BIG_CATEGORIES and size.x * size.y >= big_area:
		return 4
	if it.category in NATURE_CATEGORIES:
		return 6
	return 7


static func stage_info(stage: int) -> Dictionary:
	for s in STAGES:
		if int(s["stage"]) == stage:
			return s
	return {}


static func progress(steps: Array, plan: Dictionary = {}) -> Dictionary:
	## {total, completed, remaining, percent (0..100), current (index of the first
	##  step not done, -1 when all are), current_number, next (index of the next
	##  not-done step after it, -1), next_number, objects_total, objects_done,
	##  phases: [{phase, name, total, completed, percent}] (build order, Unphased last),
	##  stages: [{stage, key, name, total, completed, percent}]}
	var total := steps.size()
	var done := 0
	var current := -1
	var nxt := -1
	var obj_total := 0
	var obj_done := 0
	var per_phase := {}
	var per_stage := {}
	for i in total:
		var s: Dictionary = steps[i]
		var ok := bool(s.get("done", false))
		var n := (s.get("uids", []) as Array).size()
		obj_total += n
		if ok:
			done += 1
			obj_done += n
		elif current < 0:
			current = i
		elif nxt < 0:
			nxt = i
		var ph := str(s.get("phase", ""))
		if not per_phase.has(ph):
			per_phase[ph] = [0, 0]
		per_phase[ph][0] += 1
		per_phase[ph][1] += 1 if ok else 0
		var st := int(s.get("stage", 0))
		if not per_stage.has(st):
			per_stage[st] = [0, 0]
		per_stage[st][0] += 1
		per_stage[st][1] += 1 if ok else 0
	var phases: Array = []
	var order: Array = per_phase.keys()
	order.sort_custom(func(a: String, b: String) -> bool:
		var ia := PlanDoc.phase_index(plan, a) if not a.is_empty() else 1 << 30
		var ib := PlanDoc.phase_index(plan, b) if not b.is_empty() else 1 << 30
		return ia < ib if ia != ib else a < b)
	for ph in order:
		var p := PlanDoc.phase(plan, ph)
		phases.append({"phase": ph, "name": UNPHASED_NAME if ph.is_empty() else str(p.get("name", ph)),
			"total": per_phase[ph][0], "completed": per_phase[ph][1], "percent": _pct(per_phase[ph][1], per_phase[ph][0])})
	var stages: Array = []
	for info in STAGES:
		var k := int(info["stage"])
		if per_stage.has(k):
			stages.append({"stage": k, "key": info["key"], "name": info["name"], "total": per_stage[k][0],
				"completed": per_stage[k][1], "percent": _pct(per_stage[k][1], per_stage[k][0])})
	return {"total": total, "completed": done, "remaining": total - done, "percent": _pct(done, total),
		"current": current, "current_number": current + 1 if current >= 0 else -1,
		"next": nxt, "next_number": nxt + 1 if nxt >= 0 else -1,
		"objects_total": obj_total, "objects_done": obj_done, "phases": phases, "stages": stages}


static func step_done(step: Dictionary, plan: Dictionary) -> bool:
	## Done-state rule (see the class comment); used again after ticking.
	if PlanDoc.is_step_done(plan, str(step.get("id", ""))):
		return true
	var kind := str(step.get("kind", ""))
	if kind in ["unlock", "clear", "store"]:
		return false
	var us: Array = step.get("uids", [])
	if us.is_empty():
		return false
	var placed: Dictionary = plan.get("placed", {}) if plan.get("placed") is Dictionary else {}
	for u in us:
		if not placed.has(str(u)):
			return false
	return true


static func screen_direction(d: Vector2) -> String:
	## Direction word of a grid offset as seen on the isometric screen ("" = none).
	var sx := d.x - d.y
	var sy := (d.x + d.y) * 0.5
	if absf(sx) < 0.0001 and absf(sy) < 0.0001:
		return ""
	var sector := posmod(roundi(rad_to_deg(atan2(sy, sx)) / 45.0), 8)
	return DIRECTIONS[sector]


static func tiles_text(r: Rect2i) -> String:
	## Exact tile coordinates, e.g. "tiles X 40–51, Y 20".
	var xs := "%d" % r.position.x if r.size.x <= 1 else "%d–%d" % [r.position.x, r.end.x - 1]
	var ys := "%d" % r.position.y if r.size.y <= 1 else "%d–%d" % [r.position.y, r.end.y - 1]
	return "%s X %s, Y %s" % ["tile" if r.size.x <= 1 and r.size.y <= 1 else "tiles", xs, ys]


static func describe_location(map: FarmMap, layout: FarmLayout, r: Rect2i, world: Dictionary = {}) -> Dictionary:
	## Where `r` is, relative to the nearest landmark and in map-region words:
	## {text, landmark, landmark_name, distance, direction, approximate,
	##  across_road, along_river}. `world` = _world_info() cache (optional).
	var w := world if not world.is_empty() else _world_info(map, layout)
	var out := {"text": "", "landmark": "", "landmark_name": "", "distance": -1, "direction": "",
		"approximate": false, "across_road": false, "along_river": false}
	if map == null:
		return out
	var parts := PackedStringArray()
	var c := Vector2(r.position) + Vector2(r.size) * 0.5
	var best: Landmark = null
	var best_d := INF
	var lms: Array = w.get("landmarks", [])
	var lcs: Variant = w.get("landmark_centers")   # same expression, computed once per build
	for i in lms.size():
		var lm: Landmark = lms[i]
		var lc: Vector2 = lcs[i] if lcs != null else Vector2(lm.origin) + Vector2(lm.footprint) * 0.5
		var dd := lc.distance_squared_to(c)
		if dd < best_d - 0.000001 or (absf(dd - best_d) <= 0.000001 and best != null and lm.id < best.id):
			best = lm
			best_d = dd
	if best != null:
		var lr := best.rect()
		var gx := maxi(0, maxi(lr.position.x - r.end.x, r.position.x - lr.end.x))
		var gy := maxi(0, maxi(lr.position.y - r.end.y, r.position.y - lr.end.y))
		var dist := maxi(gx, gy)
		var lc := Vector2(lr.position) + Vector2(lr.size) * 0.5
		var dir := screen_direction(c - lc)
		var the := _the(best.name)
		var rel := ""
		if lr.intersects(r) or dir.is_empty():
			rel = "at %s" % the
		elif dist == 0:
			rel = "directly %s" % _dir_phrase(dir, the)
		else:
			rel = "%d tile%s %s" % [dist, "" if dist == 1 else "s", _dir_phrase(dir, the)]
		var approx := best.confidence == "approximate"
		if approx:
			rel += " (approximate landmark position)"
		parts.append(rel)
		out["landmark"] = best.id
		out["landmark_name"] = best.name
		out["distance"] = dist
		out["direction"] = dir
		out["approximate"] = approx
	out["across_road"] = _across_road(map, r, w)
	out["along_river"] = _along_river(map, r, w)
	if out["across_road"]:
		parts.append("across the road")
	if out["along_river"]:
		parts.append("along the river")
	var t := ", ".join(parts)
	out["text"] = t.substr(0, 1).to_upper() + t.substr(1) if not t.is_empty() else ""
	return out


# --- stage 1: land ---------------------------------------------------------------------

static func _land_drafts(layout: FarmLayout, map: FarmMap, plan: Dictionary, design: Array, baseline: Dictionary,
		has_base: bool, primary: Dictionary) -> Array:
	var out: Array = []
	if map == null or map.plots.is_empty():
		return out
	var owned := map.canonical_unlocked(Baseline.unlocked_plots(baseline) if has_base and Baseline.has_unlocked_plots(baseline) else layout.unlocked_plots)
	var needed := {}     # plot id -> [uids]
	# map.plot_id_at() / is_plot_unlocked() per tile, with the per-plot answers
	# looked up once (plot index -> id, or "" when already unlocked).
	var mw := map.size.x
	var mh := map.size.y
	var plot_of := map.plot_of
	var direct := plot_of.size() == mw * mh
	var locked_id := PackedStringArray()
	for p in map.plots:
		var pid := str(p["id"])
		locked_id.append("" if map.is_plot_unlocked(pid, owned) else pid)
	for o: PlacedObject in design:
		var r := o.rect()
		var seen := {}
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var pid := ""
				if direct:
					if x < 0 or y < 0 or x >= mw or y >= mh:
						continue
					var pi := plot_of[y * mw + x]
					if pi < 0:
						continue
					pid = locked_id[pi]
					if pid.is_empty() or seen.has(pid):
						continue
				else:
					pid = map.plot_id_at(Vector2i(x, y))
					if pid.is_empty() or seen.has(pid) or map.is_plot_unlocked(pid, owned):
						continue
				seen[pid] = true
				if not needed.has(pid):
					needed[pid] = []
				needed[pid].append(o.uid)
	if needed.is_empty():
		return out
	var phase_of := {}
	for pid in needed:
		var best := 1 << 30
		var best_id := PlanDoc.UNPHASED
		for u in needed[pid]:
			var ph := str(primary.get(u, PlanDoc.UNPHASED))
			var i := PlanDoc.phase_index(plan, ph) if not ph.is_empty() else (1 << 29)
			if i < best:
				best = i
				best_id = ph
		phase_of[pid] = best_id
	var remaining: Array = needed.keys()
	remaining.sort_custom(func(a: String, b: String) -> bool:
		var ka := [RecreationGuide._phase_rank(plan, phase_of[a]), int(map.plot(a).get("number", 0)), a]
		var kb := [RecreationGuide._phase_rank(plan, phase_of[b]), int(map.plot(b).get("number", 0)), b]
		return RecreationGuide._lex_less(ka, kb))
	var own := owned.duplicate()
	var guard := 0
	while not remaining.is_empty() and guard < 10000:
		guard += 1
		var picked := ""
		for pid in remaining:
			if _plot_unlockable(map, pid, own):
				picked = pid
				break
		if not picked.is_empty():
			remaining.erase(picked)
			own[picked] = true
			out.append(_land_draft(map, picked, needed[picked], phase_of[picked], ""))
			continue
		var target: String = remaining[0]
		var path := _plot_path(map, own, target)
		if path.is_empty():
			for pid in remaining:
				var d := _land_draft(map, pid, needed[pid], phase_of[pid], "")
				d["unreachable"] = true
				out.append(d)
			break
		for pid in path:
			own[pid] = true
			out.append(_land_draft(map, pid, [], phase_of[target], target))
	return out


static func _land_draft(map: FarmMap, pid: String, needed_by: Array, phase: String, via: String) -> Dictionary:
	var p := map.plot(pid)
	var b := Rect2i()
	var first := true
	for r: Rect2i in p.get("rects", []):
		b = r if first else b.merge(r)
		first = false
	var nb := needed_by.duplicate()
	nb.sort()
	return {"stage": 1, "kind": "unlock", "phase": phase, "item": "", "uids": [], "needed_by": nb, "bounds": b,
		"plot": pid, "via": via}


static func _plot_unlockable(map: FarmMap, pid: String, own: Dictionary) -> bool:
	var p := map.plot(pid)
	if bool(p.get("touches_land", false)):
		return true
	for n in p.get("neighbors", []):
		if map.is_plot_unlocked(str(n), own):
			return true
	return false


static func _plot_path(map: FarmMap, own: Dictionary, target: String) -> Array:
	## Locked plots to unlock (in order) before `target` becomes unlockable;
	## [] when it can't be reached. Breadth-first over plot neighbours.
	var parent := {}
	var queue: Array = []
	for p in map.plots:
		var pid := str(p["id"])
		if not map.is_plot_unlocked(pid, own) and _plot_unlockable(map, pid, own):
			parent[pid] = ""
			queue.append(pid)
	var head := 0
	while head < queue.size():
		var cur: String = queue[head]
		head += 1
		if cur == target:
			var path: Array = []
			var at: String = parent[cur]
			while not at.is_empty():
				path.push_front(at)
				at = parent[at]
			return path
		for n in map.plot(cur).get("neighbors", []):
			var ns := str(n)
			if parent.has(ns) or map.is_plot_unlocked(ns, own):
				continue
			parent[ns] = cur
			queue.append(ns)
	return []


# --- clustering and ordering ----------------------------------------------------------------

static func _clusters(entries: Array, stage: int, kind: String, rect_key: String) -> Array:
	## Groups entries of the same (phase, item[, delta]) whose `rect_key` rects
	## touch (8-neighbourhood) into cluster drafts.
	var groups := {}
	for e: Dictionary in entries:
		var gk := "%s|%s" % [e["phase"], e["item"]]
		if e.has("delta"):
			gk += "|%d,%d" % [(e["delta"] as Vector2i).x, (e["delta"] as Vector2i).y]
		if not groups.has(gk):
			groups[gk] = []
		groups[gk].append(e)
	var out: Array = []
	var gkeys: Array = groups.keys()
	gkeys.sort()
	for gk in gkeys:
		var list: Array = _sorted_by_uid(groups[gk])
		var parent: Array = []
		for i in list.size():
			parent.append(i)
		_link_touching(list, rect_key, parent)
		var members := {}
		for i in list.size():
			var root := _find(parent, i)
			if not members.has(root):
				members[root] = []
			members[root].append(list[i])
		var roots: Array = members.keys()
		roots.sort()
		for root in roots:
			var ms: Array = members[root]
			var us: Array = []
			var b: Rect2i = ms[0]["rect"]
			var fb: Rect2i = ms[0].get("from", ms[0]["rect"])
			var reused := 0
			for m: Dictionary in ms:
				us.append(int(m["uid"]))
				b = b.merge(m["rect"])
				fb = fb.merge(m.get("from", m["rect"]))
				reused += 1 if bool(m.get("reused", false)) else 0
			us.sort()
			var rects: Array = []
			var from_rects: Array = []
			for m: Dictionary in ms:
				rects.append(m["rect"])
				from_rects.append(m.get("from", m["rect"]))
			out.append({"stage": stage, "kind": kind, "phase": str(ms[0]["phase"]), "item": str(ms[0]["item"]),
				"uids": us, "bounds": b, "from_bounds": fb, "rects": rects, "from_rects": from_rects, "reused": reused})
	return out


static func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)


static func _sorted_by_uid(list: Array) -> Array:
	## Entries by uid (native sort of packed keys; equal uids keep their order).
	if list.size() < 2:
		return list
	var keys := PackedInt64Array()
	keys.resize(list.size())
	for i in list.size():
		keys[i] = (int(list[i]["uid"]) << 24) | i
	keys.sort()
	var out: Array = []
	out.resize(list.size())
	for i in keys.size():
		out[i] = list[keys[i] & 0xFFFFFF]
	return out


static func _link_touching(list: Array, rect_key: String, parent: Array) -> void:
	## Unions entries whose rects touch (8-neighbourhood: a tile of one within
	## the other grown by 1). The components are what matters (each root is the
	## smallest index of its component), so any exact touch test gives the same
	## clusters: rect pairs for small groups, a tile grid for large ones.
	var n := list.size()
	if n < 2:
		return
	var rects: Array[Rect2i] = []
	var bounds := Rect2i()
	var degenerate := false
	for i in n:
		var r: Rect2i = list[i][rect_key]
		rects.append(r)
		degenerate = degenerate or r.size.x <= 0 or r.size.y <= 0
		bounds = r if i == 0 else bounds.merge(r)
	if not degenerate and n <= 24:
		for i in n:
			var g := rects[i].grow(1)
			for j in range(i + 1, n):
				if g.intersects(rects[j]):
					_union(parent, i, j)
		return
	var gb := bounds.grow(1)
	if degenerate or gb.get_area() > 4000000:
		# Fallback (odd rects): tile -> last entry on it, as a dictionary.
		var at := {}
		for i in n:
			var r := rects[i]
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					at[Vector2i(x, y)] = i
		for i in n:
			var g := rects[i].grow(1)
			for y in range(g.position.y, g.end.y):
				for x in range(g.position.x, g.end.x):
					var j: Variant = at.get(Vector2i(x, y))
					if j != null and int(j) != i:
						_union(parent, i, int(j))
		return
	var w := gb.size.x
	var grid := PackedInt32Array()
	grid.resize(gb.get_area())
	grid.fill(-1)
	for i in n:
		var r := rects[i]
		for y in range(r.position.y, r.end.y):
			var row := (y - gb.position.y) * w - gb.position.x
			for x in range(r.position.x, r.end.x):
				grid[row + x] = i
	for i in n:
		var g := rects[i].grow(1)
		for y in range(g.position.y, g.end.y):
			var row := (y - gb.position.y) * w - gb.position.x
			for x in range(g.position.x, g.end.x):
				var j := grid[row + x]
				if j >= 0 and j != i:
					_union(parent, i, j)


static func _phase_rank(plan: Dictionary, phase: String) -> int:
	return PlanDoc.phase_index(plan, phase) if not phase.is_empty() else (1 << 29)


static func _sort_keys(clusters: Array, plan: Dictionary) -> void:
	## Adds "_key" to every cluster: [phase rank, item's first screen row, its
	## first screen column, item, cluster screen row, column, first uid].
	var item_first := {}
	for c: Dictionary in clusters:
		var p: Vector2i = (c["bounds"] as Rect2i).position
		var k := "%s|%s" % [c["phase"], c["item"]]
		var v := [p.x + p.y, p.x - p.y]
		if not item_first.has(k) or _lex_less(v, item_first[k]):
			item_first[k] = v
	for c: Dictionary in clusters:
		var p: Vector2i = (c["bounds"] as Rect2i).position
		var f: Array = item_first["%s|%s" % [c["phase"], c["item"]]]
		c["_key"] = [_phase_rank(plan, str(c["phase"])), f[0], f[1], str(c["item"]), p.x + p.y, p.x - p.y,
			int((c["uids"] as Array)[0]) if not (c["uids"] as Array).is_empty() else 0]


static func _ordered_clusters(clusters: Array, plan: Dictionary) -> Array:
	_sort_keys(clusters, plan)
	var out: Array = []
	for i in _key_order(clusters):
		out.append(clusters[i])
	return out


static func _key_order(clusters: Array) -> Array:
	## Indices of `clusters` in _lex_less order of their "_key". Sorted natively
	## (Array < compares element by element like _lex_less; the keys end with the
	## cluster's first uid, so they are distinct and the order is the same).
	var keyed: Array = []
	keyed.resize(clusters.size())
	for i in clusters.size():
		var k: Array = (clusters[i]["_key"] as Array).duplicate()
		k.append(i)
		keyed[i] = k
	keyed.sort()
	var out: Array = []
	out.resize(keyed.size())
	for i in keyed.size():
		var k: Array = keyed[i]
		out[i] = k[k.size() - 1]
	return out


static func _ordered_moves(clusters: Array, plan: Dictionary) -> Array:
	## Topological order: a cluster whose target tiles overlap another cluster's
	## current tiles goes after it. When everything left waits on something (a
	## cycle, e.g. a swap), the first cluster by sort key is put in storage first
	## and placed from storage once its target is free.
	_sort_keys(clusters, plan)
	var n := clusters.size()
	var from_at := {}
	for i in n:
		for r: Rect2i in clusters[i]["from_rects"]:
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					if not from_at.has(Vector2i(x, y)):
						from_at[Vector2i(x, y)] = []
					from_at[Vector2i(x, y)].append(i)
	var outs: Array = []
	var preds: Array = []
	var indeg: Array = []
	for i in n:
		outs.append({})
		preds.append({})
		indeg.append(0)
	for a in n:
		var deps := {}
		for r: Rect2i in clusters[a]["rects"]:
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					for b in from_at.get(Vector2i(x, y), []):
						if b != a:
							deps[b] = true
		for b in deps:
			outs[b][a] = true
			preds[a][b] = true
			indeg[a] += 1
	var order: Array = _key_order(clusters)
	var rank := {}
	for i in order.size():
		rank[order[i]] = i
	var out: Array = []
	var emitted := {}
	var stored := {}
	while emitted.size() < n:
		var pick := -1
		for i in order:
			if not emitted.has(i) and indeg[i] <= 0:
				pick = i
				break
		if pick >= 0:
			emitted[pick] = true
			var d: Dictionary = clusters[pick].duplicate()
			d["node"] = pick
			if stored.has(pick):
				d["kind"] = "place_from_storage"
			out.append(d)
			_release(outs, indeg, pick)
			continue
		# Cycle: store a cluster that is ON a cycle (the first by sort key) to free its
		# tiles. A cluster merely waiting behind a cycle must not go to storage: it
		# moves normally once the cycle is broken.
		var brk := _cycle_member(order, rank, preds, emitted, stored)
		if brk < 0:
			break   # cannot happen: every waiting cluster is already stored
		stored[brk] = true
		var s: Dictionary = clusters[brk].duplicate()
		s["kind"] = "store_temp"
		s["node"] = brk
		s["bounds"] = s["from_bounds"]
		out.append(s)
		_release(outs, indeg, brk)
	return out


static func _cycle_member(order: Array, rank: Dictionary, preds: Array, emitted: Dictionary, stored: Dictionary) -> int:
	## A waiting cluster on a dependency cycle (-1 = none): walk from the first
	## waiting cluster along still-blocking dependencies (clusters neither moved nor
	## stored; every waiting cluster has one) until one repeats, then take the
	## cycle's first cluster by sort key.
	var start := -1
	for i in order:
		if not emitted.has(i) and not stored.has(i):
			start = i
			break
	if start < 0:
		return -1
	var pos := {}
	var path: Array = []
	var cur := start
	while not pos.has(cur):
		pos[cur] = path.size()
		path.append(cur)
		var nxt := -1
		for b in preds[cur]:
			if emitted.has(b) or stored.has(b):
				continue
			if nxt < 0 or int(rank[b]) < int(rank[nxt]):
				nxt = int(b)
		if nxt < 0:
			return start   # defensive: nothing blocks it after all
		cur = nxt
	var best := cur
	for j in range(int(pos[cur]), path.size()):
		if int(rank[path[j]]) < int(rank[best]):
			best = path[j]
	return best


static func _release(outs: Array, indeg: Array, i: int) -> void:
	for a in outs[i]:
		indeg[a] -= 1
	outs[i] = {}


static func _lex_less(a: Array, b: Array) -> bool:
	for i in mini(a.size(), b.size()):
		if a[i] == b[i]:
			continue
		return a[i] < b[i]
	return a.size() < b.size()


# --- step texts ---------------------------------------------------------------------------------

static func _finish(d: Dictionary, layout: FarmLayout, map: FarmMap, plan: Dictionary, db: ItemDatabase, world: Dictionary) -> Dictionary:
	var kind := str(d["kind"])
	var stage := int(d["stage"])
	# Per-build lookups kept in `world` (stage records, phases, item names).
	if not world.has("_memo"):
		world["_memo"] = {}
	var memo: Dictionary = world["_memo"]
	var info: Variant = memo.get(stage)
	if info == null:
		info = stage_info(stage)
		memo[stage] = info
	var item := str(d.get("item", ""))
	var us: Array = d.get("uids", [])
	var n := us.size()
	var nv: Variant = memo.get("n:" + item)
	if nv == null:
		nv = _item_name(db, item)
		memo["n:" + item] = nv
	var name: String = nv
	var bounds: Rect2i = d["bounds"]
	var from_b: Rect2i = d.get("from_bounds", bounds)
	var ph := str(d.get("phase", ""))
	var p: Variant = memo.get("p:" + ph)
	if p == null:
		p = PlanDoc.phase(plan, ph)
		memo["p:" + ph] = p
	var s := {
		"stage": stage, "stage_key": info.get("key", ""), "stage_name": info.get("name", ""), "kind": kind,
		"phase": ph, "phase_name": UNPHASED_NAME if ph.is_empty() else str(p.get("name", ph)),
		"items": [item] if not item.is_empty() else [], "item_names": [name] if not item.is_empty() else [],
		"uids": us.duplicate(), "count": n, "reused": int(d.get("reused", 0)),
		"bounds": bounds, "from_bounds": from_b, "plot": str(d.get("plot", "")),
	}
	if d.has("node"):
		s["node"] = d["node"]
	var loc := describe_location(map, layout, bounds, world)
	var what := name if n <= 1 else "%d × %s" % [n, name]
	var title := ""
	var extra := PackedStringArray()
	match kind:
		"unlock":
			var pl := map.plot(str(d["plot"])) if map else {}
			var pname := str(pl.get("name", d["plot"]))
			title = "Unlock %s" % pname
			if not str(d.get("via", "")).is_empty():
				var tp := map.plot(str(d["via"]))
				title += " (to reach %s)" % str(tp.get("name", d["via"]))
			elif not (d.get("needed_by", []) as Array).is_empty():
				var nb := (d["needed_by"] as Array).size()
				extra.append("needed for %d object%s" % [nb, "" if nb == 1 else "s"])
			if bool(d.get("unreachable", false)):
				extra.append("the map shows no way to reach it from your land")
			s["needed_by"] = d.get("needed_by", [])
			s["cost"] = (pl.get("cost", {}) as Dictionary).duplicate(true) if pl.get("cost") is Dictionary else {}
		"clear":
			title = "Clear %s" % what
		"store":
			title = "Put %s in storage" % what
		"store_temp":
			title = "Put %s in storage for now" % what
		"move":
			title = "Move %s" % what
			extra.append("from %s" % tiles_text(from_b))
		"place_from_storage":
			title = "Place %s from storage" % what
		"customize":
			var e: Dictionary = d["custom"]
			title = "Give the %s the look “%s”" % [str(e.get("name", e.get("id", ""))), str(e.get("skin_name", ""))]
			var buy := PackedStringArray()
			var own := PackedStringArray()
			for r: Dictionary in e.get("rows", []):
				if str(r["status"]) == "to_buy":
					buy.append("%s (%s)" % [str(r["name"]), Currency.format_line(r["price"])])
				elif str(r["status"]) == "unknown":
					buy.append("%s (price unknown)" % str(r["name"]))
				elif str(r["status"]) == "owned":
					own.append(str(r["name"]))
			if not buy.is_empty():
				extra.append("parts to buy: " + ", ".join(buy))
			if not own.is_empty():
				extra.append("already owned: " + ", ".join(own))
			if buy.is_empty() and own.is_empty():
				extra.append("only default parts: nothing to buy")
			s["cost"] = (e.get("cost", {}) as Dictionary).duplicate()
			s["landmark"] = str(e.get("id", ""))
			s["look"] = str(d.get("look", ""))
		_:
			title = "Place %s" % what
			var ru := int(d.get("reused", 0))
			if ru > 0:
				title += " (from storage)" if ru == n else " (%d from storage)" % ru
	s["title"] = title
	var desc := str(loc["text"])
	if not extra.is_empty():
		desc = (desc + "; " if not desc.is_empty() else "") + "; ".join(extra)
		desc = desc.substr(0, 1).to_upper() + desc.substr(1)
	s["description"] = desc
	s["location"] = loc
	s["tiles_text"] = tiles_text(bounds)
	s["from_tiles_text"] = tiles_text(from_b) if kind == "move" else ""
	s["id"] = _step_id(s)
	s["done"] = step_done(s, plan)
	return s


static func _step_id(s: Dictionary) -> String:
	var us: Array = s["uids"]
	var parts := PackedStringArray([str(s["stage"]), str(s["kind"]), str(s["phase"]), ",".join(PackedStringArray(s["items"])),
		str(s["plot"])])
	var ul := PackedStringArray()
	for u in us:
		ul.append(str(u))
	parts.append(",".join(ul))
	if s.has("look"):
		parts.append(str(s["look"]))
	return "%s-%s" % [s["kind"], "|".join(parts).md5_text().left(12)]


static func _item_name(db: ItemDatabase, item: String) -> String:
	if item.is_empty():
		return ""
	var it := db.get_item(item) if db else null
	return it.name if it else item


static func _category(db: ItemDatabase, item: String) -> String:
	var it := db.get_item(item) if db else null
	return it.category if it else ""


static func _is_obstacle(db: ItemDatabase, item: String) -> bool:
	var it := db.get_item(item) if db else null
	return it != null and (it.category == OBSTACLE_CATEGORY or not it.movable)


static func _the(name: String) -> String:
	return name if name.to_lower().begins_with("the ") else "the " + name


static func _dir_phrase(dir: String, the: String) -> String:
	match dir:
		"right", "left":
			return "%s of %s" % [dir, the]
		"below", "above":
			return "%s %s" % [dir, the]
	return "to the %s of %s" % [dir, the]


static func _pct(a: int, b: int) -> float:
	return 100.0 if b <= 0 else snappedf(100.0 * a / b, 0.1)


# --- map regions ------------------------------------------------------------------------------------

static func _world_info(map: FarmMap, layout: FarmLayout) -> Dictionary:
	## Cached per build: visible landmarks, plot -> section side, the centre of
	## the starting land (for "across the road"), river rects.
	var out := {"landmarks": [], "side_of_plot": {}, "main_center": null, "has_road": false, "river_rects": []}
	if map == null:
		return out
	var lms: Array = []
	var lcs: Array = []
	for lm in map.landmarks:
		if layout == null or layout.is_landmark_visible(lm.id, not lm.hidden_by_default):
			lms.append(lm)
			lcs.append(Vector2(lm.origin) + Vector2(lm.footprint) * 0.5)
	out["landmarks"] = lms
	out["landmark_centers"] = lcs
	for s in map.sections:
		for pid in s.get("plots", []):
			out["side_of_plot"][str(pid)] = str(s.get("side", "main"))
	var sum := Vector2.ZERO
	var cnt := 0
	for y in map.size.y:
		for x in map.size.x:
			var k := map.kinds[y * map.size.x + x]
			if k == FarmMap.Kind.BUILDABLE:
				sum += Vector2(x + 0.5, y + 0.5)
				cnt += 1
			elif k == FarmMap.Kind.ROAD:
				out["has_road"] = true
	if cnt > 0:
		out["main_center"] = sum / cnt
	for sc in map.scenery:
		if str(sc.get("kind", "")) == "river":
			out["river_rects"].append(sc["rect"])
	# Summed-area tables of road and water tiles: "any road / water tile in this
	# rectangle?" in O(1) (the per-step location texts ask it thousands of times).
	var mw := map.size.x
	var mh := map.size.y
	if mw > 0 and mh > 0 and map.kinds.size() == mw * mh:
		var road := PackedInt32Array()
		var water := PackedInt32Array()
		road.resize((mw + 1) * (mh + 1))
		road.fill(0)
		water.resize((mw + 1) * (mh + 1))
		water.fill(0)
		var kinds := map.kinds
		for y in mh:
			var rr := 0
			var wr := 0
			var o1 := (y + 1) * (mw + 1)
			var o0 := y * (mw + 1)
			for x in mw:
				var k := kinds[y * mw + x]
				rr += 1 if k == FarmMap.Kind.ROAD else 0
				wr += 1 if k == FarmMap.Kind.WATER else 0
				road[o1 + x + 1] = road[o0 + x + 1] + rr
				water[o1 + x + 1] = water[o0 + x + 1] + wr
		out["road_sum"] = road
		out["water_sum"] = water
	return out


static func _any_in(sat: PackedInt32Array, mw: int, mh: int, x0: int, y0: int, x1: int, y1: int) -> bool:
	## Any counted tile in tiles x0..x1-1, y0..y1-1 (clipped to the map)?
	x0 = maxi(x0, 0)
	y0 = maxi(y0, 0)
	x1 = mini(x1, mw)
	y1 = mini(y1, mh)
	if x0 >= x1 or y0 >= y1:
		return false
	var s := mw + 1
	return sat[y1 * s + x1] - sat[y0 * s + x1] - sat[y1 * s + x0] + sat[y0 * s + x0] > 0


static func _across_road(map: FarmMap, r: Rect2i, w: Dictionary) -> bool:
	var c := Vector2(r.position) + Vector2(r.size) * 0.5
	var ct := Vector2i(floori(c.x), floori(c.y))
	var pid := map.plot_id_at(ct)
	if not pid.is_empty() and str((w["side_of_plot"] as Dictionary).get(pid, "main")) != "main":
		return true
	if not bool(w["has_road"]) or w["main_center"] == null or map.kind_at(ct) == FarmMap.Kind.ROAD:
		return false
	# On the far side of a road: the straight line to the starting land crosses road tiles.
	var to: Vector2 = w["main_center"]
	var road: Variant = w.get("road_sum")
	var mw := map.size.x
	var mh := map.size.y
	if road != null:
		# Every sample below lies on the segment; no road tile in its bounding box
		# (one tile of margin against rounding) means no sample can hit a road.
		if not _any_in(road, mw, mh, floori(minf(c.x, to.x)) - 1, floori(minf(c.y, to.y)) - 1,
				floori(maxf(c.x, to.x)) + 2, floori(maxf(c.y, to.y)) + 2):
			return false
	var kinds := map.kinds
	var direct := kinds.size() == mw * mh
	var steps := maxi(1, ceili(c.distance_to(to) * 2.0))
	for i in range(1, steps):
		var p := c.lerp(to, float(i) / steps)
		var tx := floori(p.x)
		var ty := floori(p.y)
		if direct:
			# map.kind_at() inlined: outside the map is VOID, never a road.
			if tx >= 0 and ty >= 0 and tx < mw and ty < mh and kinds[ty * mw + tx] == FarmMap.Kind.ROAD:
				return true
		elif map.kind_at(Vector2i(tx, ty)) == FarmMap.Kind.ROAD:
			return true
	return false


static func _along_river(map: FarmMap, r: Rect2i, w: Dictionary) -> bool:
	var g := r.grow(1)
	for rr: Rect2i in w["river_rects"]:
		if rr.intersects(g):
			return true
	var water: Variant = w.get("water_sum")
	if water != null:
		return _any_in(water, map.size.x, map.size.y, g.position.x, g.position.y, g.end.x, g.end.y)
	for y in range(g.position.y, g.end.y):
		for x in range(g.position.x, g.end.x):
			if map.kind_at(Vector2i(x, y)) == FarmMap.Kind.WATER:
				return true
	return false
