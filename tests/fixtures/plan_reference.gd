extends RefCounted
## Reference copies of planning functions as they were before the W5b speed-ups
## (git 7ce14cc), kept verbatim apart from renamed calls: the equivalence tests
## (tests/unit/test_plan_equivalence.gd) check that the faster versions give
## exactly the same results on synthetic layouts.

static func readiness_build(layout: FarmLayout, db: ItemDatabase, conflicts: Dictionary, report: RealisticAnalyzer.Report,
		not_buyable: Dictionary = {}) -> Dictionary:
	## conflicts: uid -> PlacementRules.Result (EditorSession.conflicts());
	## report: RealisticAnalyzer report (EditorSession.analysis()); not_buyable:
	## item -> objects still to buy that the shop doesn't sell (BudgetEngine
	## item_breakdown "not_buyable", To-buy mode). Returns
	## {"rows": [...], "blocking": rows with Readiness.BLOCKING, "checks": rows with CHECK,
	##  "blocking_objects": n, "ready": no blocking row, "realistic": bool}.
	var realistic := layout.mode == FarmLayout.MODE_REALISTIC
	var acc := {}
	for id in Readiness.ORDER:
		acc[id] = {"uids": {}, "items": {}}
	# Placement: from the conflict index (planned objects included: they are
	# part of the design too). Locked land and fixed landmarks get their own rows.
	for u: int in conflicts:
		var o: PlacedObject = layout.objects.get(u)
		var res: PlacementRules.Result = conflicts[u]
		if o == null or res == null:
			continue
		var other := false
		for c in res.reason_counts:
			if int(c) == PlacementRules.LOCKED_LAND:
				_rput(acc, Readiness.LOCKED_LAND, u, o.item_id)
			elif int(c) == PlacementRules.LANDMARK:
				_rput(acc, Readiness.FIXED, u, o.item_id)
			else:
				other = true
		if other:
			_rput(acc, Readiness.PLACEMENT, u, o.item_id)
	if report != null:
		for u: int in report.issues:
			var o: PlacedObject = layout.objects.get(u)
			if o == null:
				continue
			for c in report.issues[u]:
				var row: String = Readiness.ISSUE_ROWS.get(str(c), "")
				if row == Readiness.LEVEL and not realistic:
					continue
				if not row.is_empty():
					_rput(acc, row, u, o.item_id)
	# Can't buy / no inventory record: per item, every real (not planned) copy.
	var owned: Dictionary = layout.profile.get("owned", {}) if layout.profile.get("owned") is Dictionary else {}
	var nb := {}
	for k in not_buyable:
		if int(not_buyable[k]) > 0:
			nb[str(k)] = int(not_buyable[k])
	var nb_objects := 0
	for k in nb:
		nb_objects += int(nb[k])
	for o: PlacedObject in layout.objects.values():
		if o.planned:
			continue
		var item := db.resolve_id(o.item_id) if db != null else o.item_id
		if nb.has(item) or nb.has(o.item_id):
			_rput(acc, Readiness.CANT_BUY, o.uid, o.item_id)
		if db != null and db.get_item(o.item_id) != null and not owned.has(o.item_id) and not owned.has(item):
			_rput(acc, Readiness.NO_INVENTORY, o.uid, o.item_id)
	var rows: Array = []
	var blocking := 0
	var checks := 0
	var blocking_uids := {}
	for id: String in Readiness.ORDER:
		var a: Dictionary = acc[id]
		var uids: Array = (a["uids"] as Dictionary).keys()
		uids.sort()
		var items: Array = (a["items"] as Dictionary).keys()
		items.sort()
		var n := uids.size()
		if id == Readiness.CANT_BUY and nb_objects > 0:
			n = nb_objects
		var row := {"id": id, "uids": uids, "items": items, "objects": n, "severity": Readiness.severity_of(id)}
		if id == Readiness.LAND_LEVEL:
			if report == null or report.land_level_locked.is_empty() or not realistic:
				continue
			var lv := 0
			for p: Dictionary in report.land_level_locked:
				lv = maxi(lv, int(p.get("min_level", 0)))
			row["objects"] = 0
			row["plots"] = report.land_level_locked.size()
			row["label"] = "%d expansion%s need a higher farm level" % [report.land_level_locked.size(), "" if report.land_level_locked.size() == 1 else "s"]
			row["detail"] = "Up to level %d; your farm is level %d" % [lv, RealisticAnalyzer.farm_level(layout)]
		else:
			if n == 0:
				continue
			var t := Readiness.texts(id, n, items.size(), report)
			row["label"] = t[0]
			row["detail"] = t[1]
		rows.append(row)
		if row["severity"] == Readiness.BLOCKING:
			blocking += 1
			for u in uids:
				blocking_uids[u] = true
		else:
			checks += 1
	return {"rows": rows, "blocking": blocking, "checks": checks, "blocking_objects": blocking_uids.size(),
		"ready": blocking == 0, "realistic": realistic}


static func _rput(acc: Dictionary, id: String, uid: int, item: String) -> void:
	(acc[id]["uids"] as Dictionary)[uid] = true
	(acc[id]["items"] as Dictionary)[item] = true


static func baseline_diff(layout: FarmLayout, baseline: Dictionary, db: ItemDatabase = null) -> Dictionary:
	## Compares the design with the baseline. Returns
	##   status:    {design uid (int): "unchanged" | "moved" | "new"} for every design object
	##   unchanged, moved, new: sorted design uids
	##   removed:   [{uid, item, rect: Rect2i, flipped}] baseline objects not in the design (by uid)
	##   moves:     {design uid: {"from": Rect2i, "to": Rect2i}}
	##   reuse:     {new design uid: removed baseline uid}: new copies that reuse a removed copy
	##              of the same item (nearest first), i.e. "from the old spot / storage"
	##   freed:     sorted baseline uids of removed copies no new copy reuses (go to storage)
	##   items:     {item: {baseline, design, unchanged, moved, kept, new, removed, reused,
	##               extra_needed, freed}}  (kept = unchanged + moved; extra_needed = new copies
	##               not covered by removed ones: from storage / inventory or to buy)
	##   totals:    the same counts summed over all items
	var base := Baseline.entries(baseline, db)
	var status := {}
	var unchanged: Array = []
	var moved: Array = []
	var added: Array = []
	var moves := {}
	var matched := {}
	var uids := layout.objects.keys()
	uids.sort()
	# Design item ids resolved like the baseline's (an object saved under an old
	# alias is still the same item; BudgetEngine matches the same way).
	var design_item := {}
	for u in uids:
		var raw: String = (layout.objects[u] as PlacedObject).item_id
		design_item[u] = db.resolve_id(raw) if db != null else raw
	for u in uids:
		var o: PlacedObject = layout.objects[u]
		var b: Variant = base.get(int(u))
		if b != null and str(b["item"]) == str(design_item[u]):
			matched[int(u)] = true
			if b["rect"] == o.rect() and bool(b["flipped"]) == o.flipped:
				status[int(u)] = "unchanged"
				unchanged.append(int(u))
			else:
				status[int(u)] = "moved"
				moved.append(int(u))
				moves[int(u)] = {"from": b["rect"], "to": o.rect()}
		else:
			status[int(u)] = "new"
			added.append(int(u))
	var removed: Array = []
	var buids := base.keys()
	buids.sort()
	for bu in buids:
		if matched.has(bu):
			continue
		var e: Dictionary = base[bu]
		removed.append({"uid": bu, "item": e["item"], "rect": e["rect"], "flipped": e["flipped"]})
	# Fungible reuse: pair new copies with removed copies of the same item.
	var removed_by_item := {}
	for e: Dictionary in removed:
		if not removed_by_item.has(e["item"]):
			removed_by_item[e["item"]] = []
		removed_by_item[e["item"]].append(e)
	var new_by_item := {}
	for u in added:
		var it: String = design_item[u]
		if not new_by_item.has(it):
			new_by_item[it] = []
		new_by_item[it].append(u)
	var reuse := {}
	var reused_base := {}
	for it in new_by_item:
		if not removed_by_item.has(it):
			continue
		var pairs: Array = []
		for nu in new_by_item[it]:
			var no: PlacedObject = layout.objects[nu]
			for e: Dictionary in removed_by_item[it]:
				var d: Vector2i = no.origin - (e["rect"] as Rect2i).position
				pairs.append([d.length_squared(), int(nu), int(e["uid"])])
		pairs.sort_custom(func(x: Array, y: Array) -> bool: return Baseline._pair_less(x, y))
		var used_new := {}
		for p in pairs:
			if used_new.has(p[1]) or reused_base.has(p[2]):
				continue
			used_new[p[1]] = true
			reused_base[p[2]] = true
			reuse[p[1]] = p[2]
	var freed: Array = []
	for e: Dictionary in removed:
		if not reused_base.has(e["uid"]):
			freed.append(e["uid"])
	# Per-item counts.
	var items := {}
	for bu in base:
		Baseline._count(items, str(base[bu]["item"]), "baseline")
	for u in uids:
		var di: String = design_item[u]
		Baseline._count(items, di, "design")
		Baseline._count(items, di, status[int(u)])
		if status[int(u)] != "new":
			Baseline._count(items, di, "kept")
		elif reuse.has(int(u)):
			Baseline._count(items, di, "reused")
		else:
			Baseline._count(items, di, "extra_needed")
	for e: Dictionary in removed:
		Baseline._count(items, str(e["item"]), "removed")
		if not reused_base.has(e["uid"]):
			Baseline._count(items, str(e["item"]), "freed")
	var totals := Baseline._zero_counts()
	for it in items:
		for k in totals:
			totals[k] += int(items[it][k])
	return {"status": status, "unchanged": unchanged, "moved": moved, "new": added, "removed": removed,
		"moves": moves, "reuse": reuse, "freed": freed, "items": items, "totals": totals}


static func checklist(engine: BudgetEngine, layout: FarmLayout, db: ItemDatabase, plan: Dictionary) -> Dictionary:
	## Construction checklist: {phases: [{phase, name, color, status, status_text,
	## marked_done, total, not_acquired, acquired, placed, percent, uids,
	## open_uids, groups: [{group, total, not_acquired, acquired, placed, percent,
	## uids, open_uids}]}] (build order, Unphased last, empty phases left out
	## except named ones), overall: {total, not_acquired, acquired, placed, percent},
	## moved: uids marked placed that were moved since, skipped: editor markers}.
	## Editor planning markers (category "planning") are not game objects and are left out.
	var states := PlanUiModels.object_states(engine, layout, db, plan)
	var phases: Array = []
	var overall := PlanUiModels._counts()
	var skipped := 0
	for pid in engine.phase_ids(true):
		var ph := PlanDoc.phase(plan, pid)
		var acc := PlanUiModels._counts()
		var groups := {}
		for u in engine.phase_uids(pid):
			var o: PlacedObject = layout.objects.get(int(u))
			if o == null:
				continue
			var it: ItemDef = db.get_item(o.item_id) if db != null else null
			if it != null and it.category in RecreationGuide.SKIP_CATEGORIES:
				skipped += 1
				continue
			var g := ShoppingList.group_of_category(it.category) if it != null else ShoppingList.GROUP_OTHER
			var st: String = states.get(int(u), PlanUiModels.ST_NOT_ACQUIRED)
			if not groups.has(g):
				groups[g] = PlanUiModels._counts()
			PlanUiModels._count_into(groups[g], int(u), st)
			PlanUiModels._count_into(acc, int(u), st)
			PlanUiModels._count_into(overall, int(u), st)
		if acc["total"] == 0 and pid == BudgetEngine.UNPHASED:
			continue
		var glist: Array = []
		for g in ShoppingList.GROUPS + (groups.keys().filter(func(k): return not k in ShoppingList.GROUPS)):
			if not groups.has(g):
				continue
			var gc: Dictionary = groups[g]
			gc["group"] = g
			gc["percent"] = PlanUiModels.percent(int(gc[PlanUiModels.ST_PLACED]), int(gc["total"]))
			glist.append(gc)
		var status := engine.phase_status(pid) if pid != BudgetEngine.UNPHASED else PlanUiModels._unphased_status(acc)
		acc["phase"] = pid
		acc["name"] = "Unphased" if pid == BudgetEngine.UNPHASED else str(ph.get("name", pid))
		acc["color"] = str(ph.get("color", "")) if pid != BudgetEngine.UNPHASED else ""
		acc["status"] = status
		acc["status_text"] = str(PlanUiModels.PHASE_STATUS_NAMES.get(status, status))
		acc["marked_done"] = bool(ph.get("done", false))
		acc["percent"] = PlanUiModels.percent(int(acc[PlanUiModels.ST_PLACED]), int(acc["total"]))
		acc["groups"] = glist
		phases.append(acc)
	overall["percent"] = PlanUiModels.percent(int(overall[PlanUiModels.ST_PLACED]), int(overall["total"]))
	return {"phases": phases, "overall": overall, "moved": PlanUiModels.moved_since_placed(layout, plan), "skipped": skipped}


static func step_to_dict(step: Dictionary) -> Dictionary:
	## JSON-safe copy of a step (rects become [x, y, w, h]).
	var out := {}
	for k in step:
		out[k] = _plain_ref(step[k])
	return out


static func _plain_ref(v: Variant) -> Variant:
	if v is Rect2i:
		var r: Rect2i = v
		return [r.position.x, r.position.y, r.size.x, r.size.y]
	if v is Vector2i:
		return [(v as Vector2i).x, (v as Vector2i).y]
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y]
	if v is Dictionary:
		var d := {}
		for k in v:
			d[str(k)] = _plain_ref(v[k])
		return d
	if v is Array:
		var a: Array = []
		for e in v:
			a.append(_plain_ref(e))
		return a
	if v is PackedStringArray:
		return Array(v)
	return v
