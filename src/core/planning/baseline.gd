class_name Baseline
extends RefCounted
## Snapshot of the real farm ("before") and its comparison with the design
## ("after"), docs/PLANNING.md §3. Pure, no scene / App dependencies.
##
## Snapshot shape (stored as plan["baseline"], see PlanDoc.with_baseline):
##   {"name": "My farm", "taken": "2026-11-10T..Z", "source_id": "<layout id>",
##    "objects": {"<uid>": ["item", x, y, w, h]},          # 6th element true = flipped
##    "unlocked_plots": ["plot id", ...]}                  # land owned when taken
## The flip flag and "unlocked_plots" extend the §3 shape (both optional).
## Planned ghosts (PlacedObject.planned) are not on the real farm and are left out.
##
## Matching is by uid AND item (a baseline is normally taken from the layout the
## design was made from, so uids correspond): same uid + same item = unchanged
## (same tiles and orientation) or moved; a design uid without a baseline entry
## of the same item = new; a baseline uid without a design object of the same
## item = removed (so the same uid with a different item = removed + new).
## Items are fungible: a new copy of X can reuse a removed X (it goes to
## storage and comes back out), which is reported as reuse, never a purchase.


static func snapshot(layout: FarmLayout, name: String = "", source_id: String = "", taken: String = "") -> Dictionary:
	## The layout's objects as a baseline record (uids are kept as keys).
	var objs := {}
	var uids := layout.objects.keys()
	uids.sort()
	for u in uids:
		var o: PlacedObject = layout.objects[u]
		if o.planned:
			continue
		var rec: Array = [o.item_id, o.origin.x, o.origin.y, o.size.x, o.size.y]
		if o.flipped:
			rec.append(true)
		objs[str(o.uid)] = rec
	var plots: Array = layout.unlocked_plots.keys()
	plots.sort()
	return {
		"name": name if not name.is_empty() else layout.name,
		"taken": taken if not taken.is_empty() else Time.get_datetime_string_from_system(true) + "Z",
		"source_id": source_id if not source_id.is_empty() else layout.id,
		"objects": objs,
		"unlocked_plots": plots,
	}


static func is_valid(baseline: Variant) -> bool:
	return baseline is Dictionary and (baseline as Dictionary).get("objects") is Dictionary


static func entries(baseline: Dictionary, db: ItemDatabase = null) -> Dictionary:
	## uid (int) -> {"item": String, "rect": Rect2i, "flipped": bool} for every
	## well-formed record (malformed ones are skipped). With `db`, renamed item
	## ids are resolved through the catalogue aliases.
	var out := {}
	if not is_valid(baseline):
		return out
	var objs: Dictionary = baseline["objects"]
	for k in objs:
		var ks := str(k)
		var rec: Variant = objs[k]
		if not ks.is_valid_int() or not rec is Array or (rec as Array).size() < 5:
			continue
		var r: Array = rec
		var ok := true
		for i in range(1, 5):
			ok = ok and (r[i] is int or r[i] is float)
		if not ok or str(r[0]).is_empty():
			continue
		var item := str(r[0])
		if db != null:
			item = db.resolve_id(item)
		out[ks.to_int()] = {"item": item, "rect": Rect2i(int(r[1]), int(r[2]), maxi(1, int(r[3])), maxi(1, int(r[4]))),
			"flipped": r.size() > 5 and r[5] is bool and bool(r[5])}
	return out


static func unlocked_plots(baseline: Dictionary) -> Array:
	## Plot ids owned when the snapshot was taken; [] when not recorded.
	var out: Array = []
	if baseline.get("unlocked_plots") is Array:
		for p in baseline["unlocked_plots"]:
			out.append(str(p))
	return out


static func has_unlocked_plots(baseline: Dictionary) -> bool:
	return baseline.get("unlocked_plots") is Array


static func diff(layout: FarmLayout, baseline: Dictionary, db: ItemDatabase = null) -> Dictionary:
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
	var base := entries(baseline, db)
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
		_count(items, str(base[bu]["item"]), "baseline")
	for u in uids:
		var di: String = design_item[u]
		_count(items, di, "design")
		_count(items, di, status[int(u)])
		if status[int(u)] != "new":
			_count(items, di, "kept")
		elif reuse.has(int(u)):
			_count(items, di, "reused")
		else:
			_count(items, di, "extra_needed")
	for e: Dictionary in removed:
		_count(items, str(e["item"]), "removed")
		if not reused_base.has(e["uid"]):
			_count(items, str(e["item"]), "freed")
	var totals := _zero_counts()
	for it in items:
		for k in totals:
			totals[k] += int(items[it][k])
	return {"status": status, "unchanged": unchanged, "moved": moved, "new": added, "removed": removed,
		"moves": moves, "reuse": reuse, "freed": freed, "items": items, "totals": totals}


static func _zero_counts() -> Dictionary:
	return {"baseline": 0, "design": 0, "unchanged": 0, "moved": 0, "kept": 0, "new": 0, "removed": 0,
		"reused": 0, "extra_needed": 0, "freed": 0}


static func _count(items: Dictionary, item: String, key: String) -> void:
	if not items.has(item):
		items[item] = _zero_counts()
	items[item][key] += 1


static func _pair_less(x: Array, y: Array) -> bool:
	if x[0] != y[0]:
		return x[0] < y[0]
	if x[1] != y[1]:
		return x[1] < y[1]
	return x[2] < y[2]
