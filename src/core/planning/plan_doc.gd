class_name PlanDoc
extends RefCounted
## Pure helpers over a layout's planning dictionary (docs/PLANNING.md §3–4):
## named areas, construction phases, area membership and each object's
## primary phase. Every "with_*" function returns a NEW dictionary (deep copy)
## so callers can wrap the change in an undoable EditCommands.SetPlanning.

const UNPHASED := ""
## Known keys. "steps_done" ({guide step id: true}, optional) holds recreation
## guide steps ticked by hand (land, clearing, storage: steps without objects
## to mark placed); step ids are content-derived (RecreationGuide).
const KEYS := ["next_id", "areas", "phases", "assign", "placed", "acquired", "baseline", "steps_done"]
const DEFAULT_COLORS := ["#f2b84b", "#e58fb0", "#8fc46a", "#6fb3e0", "#b58fe5", "#e5876f", "#5fc4b0", "#d4c85a"]


static func empty() -> Dictionary:
	return {"next_id": 1, "areas": [], "phases": [], "assign": {}, "placed": {}, "acquired": {}}


static func normalize(v: Variant) -> Dictionary:
	## Sanitises a saved planning dictionary: wrong types are dropped, ids made
	## unique, unknown keys kept verbatim (forward compatibility).
	var out := empty()
	if not v is Dictionary:
		return out
	var d: Dictionary = v
	for k in d:
		if not str(k) in KEYS:
			out[str(k)] = d[k]
	var seen := {}
	var max_n := 0
	for kind in ["areas", "phases"]:
		var src: Variant = d.get(kind, [])
		if not src is Array:
			continue
		for e in src:
			if not e is Dictionary:
				continue
			var rec: Dictionary = (e as Dictionary).duplicate(true)
			var id := str(rec.get("id", ""))
			if id.is_empty() or seen.has(id):
				continue
			if kind == "areas" and not _valid_shape(rec):
				continue
			if kind == "areas" and rec.get("rect") is Array:
				var rr: Array = rec["rect"]
				rec["rect"] = [int(rr[0]), int(rr[1]), int(rr[2]), int(rr[3])]   # JSON reads numbers as floats
			seen[id] = true
			max_n = maxi(max_n, _id_number(id))
			rec["id"] = id
			rec["name"] = str(rec.get("name", id))
			if kind == "phases":
				var al: Array = []
				for a in (rec.get("areas", []) if rec.get("areas") is Array else []):
					al.append(str(a))
				rec["areas"] = al
			(out[kind] as Array).append(rec)
	for key in ["assign"]:
		if d.get(key) is Dictionary:
			for u in d[key]:
				if str(u).is_valid_int() and d[key][u] != null:
					out[key][str(u)] = str(d[key][u])
	if d.get("placed") is Dictionary:
		for u in d["placed"]:
			var p: Variant = d["placed"][u]
			if str(u).is_valid_int() and p is Array and (p as Array).size() == 2:
				out["placed"][str(u)] = [int(p[0]), int(p[1])]
	if d.get("acquired") is Dictionary:
		for it in d["acquired"]:
			var n := int(d["acquired"][it]) if (d["acquired"][it] is int or d["acquired"][it] is float) else 0
			if n > 0:
				out["acquired"][str(it)] = n
	if d.get("baseline") is Dictionary:
		var bl: Dictionary = (d["baseline"] as Dictionary).duplicate(true)
		if bl.get("objects") is Dictionary:
			# ["item", x, y, w, h(, flipped)]: integers again after a JSON round trip;
			# records of another shape are kept as they are.
			for u in bl["objects"]:
				var rec: Variant = bl["objects"][u]
				if rec is Array and (rec as Array).size() >= 5:
					var r: Array = rec
					var ok := true
					for i in range(1, 5):
						ok = ok and (r[i] is int or r[i] is float)
					if ok:
						for i in range(1, 5):
							r[i] = int(r[i])
		out["baseline"] = bl
	if d.get("steps_done") is Dictionary:
		var sd := {}
		for k in d["steps_done"]:
			var tick: Variant = d["steps_done"][k]
			if tick is bool and tick and not str(k).is_empty():
				sd[str(k)] = true
		if not sd.is_empty():
			out["steps_done"] = sd
	out["next_id"] = maxi(maxi(1, int(d.get("next_id", 1)) if (d.get("next_id") is int or d.get("next_id") is float) else 1), max_n + 1)
	return out


static func is_empty_plan(plan: Dictionary) -> bool:
	return (plan.get("areas", []) as Array).is_empty() and (plan.get("phases", []) as Array).is_empty() \
		and (plan.get("assign", {}) as Dictionary).is_empty() and (plan.get("placed", {}) as Dictionary).is_empty() \
		and (plan.get("acquired", {}) as Dictionary).is_empty() and not plan.has("baseline") and not plan.has("steps_done")


# --- lookup ---------------------------------------------------------------------------

static func areas(plan: Dictionary) -> Array:
	return plan.get("areas", [])


static func phases(plan: Dictionary) -> Array:
	return plan.get("phases", [])


static func area(plan: Dictionary, id: String) -> Dictionary:
	for a in areas(plan):
		if str(a.get("id")) == id:
			return a
	return {}


static func phase(plan: Dictionary, id: String) -> Dictionary:
	for p in phases(plan):
		if str(p.get("id")) == id:
			return p
	return {}


static func phase_index(plan: Dictionary, id: String) -> int:
	## Build-order position of a phase; Unphased / unknown ids sort last.
	var ps := phases(plan)
	for i in ps.size():
		if str(ps[i].get("id")) == id:
			return i
	return ps.size()


# --- geometry --------------------------------------------------------------------------

static func area_bounds(a: Dictionary) -> Rect2i:
	## Tile bounds of an area (rect, or the tiles whose centres a polygon can contain).
	if a.get("rect") is Array and (a["rect"] as Array).size() == 4:
		var r: Array = a["rect"]
		return Rect2i(int(r[0]), int(r[1]), maxi(1, int(r[2])), maxi(1, int(r[3])))
	var pts := polygon(a)
	if pts.size() < 3:
		return Rect2i()
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	var x0 := floori(mn.x)
	var y0 := floori(mn.y)
	return Rect2i(x0, y0, maxi(1, ceili(mx.x) - x0), maxi(1, ceili(mx.y) - y0))


static func polygon(a: Dictionary) -> PackedVector2Array:
	## Polygon corners in grid units (tile corners at integers); empty for rect areas.
	var out := PackedVector2Array()
	if a.get("points") is Array:
		for p in a["points"]:
			if p is Array and (p as Array).size() == 2:
				out.append(Vector2(float(p[0]), float(p[1])))
	return out


static func area_polygon(a: Dictionary) -> PackedVector2Array:
	## Outline of any area in grid units (a rect becomes its four corners).
	if a.get("rect") is Array:
		var r := area_bounds(a)
		return PackedVector2Array([Vector2(r.position), Vector2(r.position.x + r.size.x, r.position.y),
			Vector2(r.end), Vector2(r.position.x, r.position.y + r.size.y)])
	return polygon(a)


static func tile_in_area(a: Dictionary, t: Vector2i) -> bool:
	if a.get("rect") is Array:
		return area_bounds(a).has_point(t)
	var pts := polygon(a)
	return pts.size() >= 3 and point_in_polygon(Vector2(t.x + 0.5, t.y + 0.5), pts)


static func rect_in_area(a: Dictionary, r: Rect2i) -> bool:
	## True when ANY tile of `r` (an object's logical footprint) is inside the area.
	var b := area_bounds(a)
	if not b.intersects(r):
		return false
	if a.get("rect") is Array:
		return true
	var pts := polygon(a)
	var c := r.intersection(b)
	for y in range(c.position.y, c.end.y):
		for x in range(c.position.x, c.end.x):
			if point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
				return true
	return false


static func point_in_polygon(p: Vector2, pts: PackedVector2Array) -> bool:
	## Even-odd rule.
	var inside := false
	var j := pts.size() - 1
	for i in pts.size():
		var a := pts[i]
		var b := pts[j]
		if (a.y > p.y) != (b.y > p.y):
			var x := a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
			if p.x < x:
				inside = not inside
		j = i
	return inside


static func objects_in_area(layout: FarmLayout, a: Dictionary) -> Array:
	## uids of the objects with at least one footprint tile in the area, sorted.
	var out: Array = []
	if a.is_empty():
		return out
	var b := area_bounds(a)
	for o: PlacedObject in layout.objects.values():
		var r := o.rect()
		if r.intersects(b) and rect_in_area(a, r):
			out.append(o.uid)
	out.sort()
	return out


static func objects_in_shape(layout: FarmLayout, shape: Dictionary) -> Array:
	## Same rule for an ad-hoc selection shape: {"rect": [...]} or {"points": [...]}.
	return objects_in_area(layout, shape)


# --- phases ------------------------------------------------------------------------------

static func primary_phases(layout: FarmLayout, plan: Dictionary) -> Dictionary:
	## uid -> phase id ("" = Unphased) for every object: manual assignment first,
	## else the first phase in build order with an area containing the object.
	var out := {}
	var assign: Dictionary = plan.get("assign", {})
	var ps := phases(plan)
	var known := {}
	for p in ps:
		known[str(p.get("id"))] = true
	# Areas of each phase, in build order.
	var phase_areas: Array = []
	for p in ps:
		var al: Array = []
		for aid in p.get("areas", []):
			var a := area(plan, str(aid))
			if not a.is_empty():
				al.append([a, area_bounds(a)])
		phase_areas.append(al)
	for o: PlacedObject in layout.objects.values():
		var key := str(o.uid)
		var manual := str(assign.get(key, ""))
		if not manual.is_empty() and known.has(manual):
			out[o.uid] = manual
			continue
		var found := UNPHASED
		var r := o.rect()
		for i in ps.size():
			for pair in phase_areas[i]:
				if (pair[1] as Rect2i).intersects(r) and rect_in_area(pair[0], r):
					found = str(ps[i].get("id"))
					break
			if found != UNPHASED:
				break
		out[o.uid] = found
	return out


static func area_phase_for_rect(plan: Dictionary, r: Rect2i) -> String:
	## Primary phase by the area rule alone (no manual assignment): the first
	## phase in build order with an area containing any tile of `r`; "" =
	## Unphased. Used for things that are not design objects (e.g. baseline
	## objects the design removes).
	for p in phases(plan):
		for aid in p.get("areas", []):
			var a := area(plan, str(aid))
			if not a.is_empty() and rect_in_area(a, r):
				return str(p.get("id"))
	return UNPHASED


static func phase_members(primary: Dictionary, phase_id: String) -> Array:
	var out: Array = []
	for u in primary:
		if primary[u] == phase_id:
			out.append(u)
	out.sort()
	return out


# --- edits (each returns a new dictionary) -------------------------------------------------

static func next_id(plan: Dictionary, prefix: String) -> String:
	## Peek at the id the next with_area/with_phase call will use.
	return "%s%d" % [prefix, int(plan.get("next_id", 1))]


static func with_area(plan: Dictionary, a: Dictionary) -> Dictionary:
	## Adds (no/unknown id) or replaces (same id) an area.
	var p := plan.duplicate(true)
	var rec := a.duplicate(true)
	var id := str(rec.get("id", ""))
	if id.is_empty() or area(p, id).is_empty():
		if id.is_empty():
			id = next_id(p, "a")
			p["next_id"] = int(p.get("next_id", 1)) + 1
		rec["id"] = id
		if not rec.has("color"):
			rec["color"] = DEFAULT_COLORS[(areas(p).size()) % DEFAULT_COLORS.size()]
		if not rec.has("visible"):
			rec["visible"] = true
		(p["areas"] as Array).append(rec)
		return p
	var list: Array = p["areas"]
	for i in list.size():
		if str(list[i].get("id")) == id:
			list[i] = rec
	return p


static func without_area(plan: Dictionary, id: String) -> Dictionary:
	var p := plan.duplicate(true)
	p["areas"] = (p["areas"] as Array).filter(func(e): return str(e.get("id")) != id)
	for ph in p["phases"]:
		ph["areas"] = (ph.get("areas", []) as Array).filter(func(x): return str(x) != id)
	return p


static func with_phase(plan: Dictionary, ph: Dictionary) -> Dictionary:
	## Adds (no/unknown id, appended last) or replaces (same id) a phase.
	var p := plan.duplicate(true)
	var rec := ph.duplicate(true)
	var id := str(rec.get("id", ""))
	if not rec.has("areas"):
		rec["areas"] = []
	if id.is_empty() or phase(p, id).is_empty():
		if id.is_empty():
			id = next_id(p, "p")
			p["next_id"] = int(p.get("next_id", 1)) + 1
		rec["id"] = id
		if not rec.has("color"):
			rec["color"] = DEFAULT_COLORS[(phases(p).size()) % DEFAULT_COLORS.size()]
		(p["phases"] as Array).append(rec)
		return p
	var list: Array = p["phases"]
	for i in list.size():
		if str(list[i].get("id")) == id:
			list[i] = rec
	return p


static func without_phase(plan: Dictionary, id: String) -> Dictionary:
	## Removes a phase; objects assigned to it manually fall back to the area rule.
	var p := plan.duplicate(true)
	p["phases"] = (p["phases"] as Array).filter(func(e): return str(e.get("id")) != id)
	var assign: Dictionary = p["assign"]
	for u in assign.keys():
		if str(assign[u]) == id:
			assign.erase(u)
	return p


static func with_phase_moved(plan: Dictionary, id: String, to_index: int) -> Dictionary:
	var p := plan.duplicate(true)
	var list: Array = p["phases"]
	var i := phase_index(p, id)
	if i >= list.size():
		return p
	var rec: Variant = list[i]
	list.remove_at(i)
	list.insert(clampi(to_index, 0, list.size()), rec)
	return p


static func with_assignment(plan: Dictionary, uids: Array, phase_id: String) -> Dictionary:
	## Manual primary phase for objects ("" clears it: back to the area rule).
	var p := plan.duplicate(true)
	var assign: Dictionary = p["assign"]
	for u in uids:
		if phase_id.is_empty():
			assign.erase(str(u))
		else:
			assign[str(u)] = phase_id
	return p


static func with_placed(plan: Dictionary, layout: FarmLayout, uids: Array, placed: bool) -> Dictionary:
	## Marks objects as placed in Hay Day (remembering where they stood) or not.
	var p := plan.duplicate(true)
	var pl: Dictionary = p["placed"]
	for u in uids:
		if not placed:
			pl.erase(str(u))
			continue
		var o: PlacedObject = layout.objects.get(int(u))
		if o != null:
			pl[str(u)] = [o.origin.x, o.origin.y]
	return p


static func with_acquired(plan: Dictionary, item_id: String, copies: int) -> Dictionary:
	var p := plan.duplicate(true)
	if copies > 0:
		p["acquired"][item_id] = copies
	else:
		(p["acquired"] as Dictionary).erase(item_id)
	return p


static func is_placed(plan: Dictionary, uid: int) -> bool:
	return (plan.get("placed", {}) as Dictionary).has(str(uid))


static func with_baseline(plan: Dictionary, baseline: Dictionary) -> Dictionary:
	## Sets ({} removes) the baseline snapshot (see Baseline.snapshot()).
	var p := plan.duplicate(true)
	if baseline.is_empty():
		p.erase("baseline")
	else:
		p["baseline"] = baseline.duplicate(true)
	return p


static func is_step_done(plan: Dictionary, step_id: String) -> bool:
	return bool((plan.get("steps_done", {}) as Dictionary).get(step_id, false)) if plan.get("steps_done") is Dictionary else false


static func with_step_done(plan: Dictionary, step_id: String, done: bool) -> Dictionary:
	## Ticks (or unticks) a recreation-guide step by hand.
	var p := plan.duplicate(true)
	var sd: Dictionary = p.get("steps_done", {}) if p.get("steps_done") is Dictionary else {}
	if done:
		sd[step_id] = true
	else:
		sd.erase(step_id)
	if sd.is_empty():
		p.erase("steps_done")
	else:
		p["steps_done"] = sd
	return p


static func without_objects(plan: Dictionary, uids: Array) -> Dictionary:
	## Drops per-object entries (assignment, placed) of objects that no longer exist.
	var p := plan.duplicate(true)
	for u in uids:
		(p["assign"] as Dictionary).erase(str(u))
		(p["placed"] as Dictionary).erase(str(u))
	return p


static func _valid_shape(a: Dictionary) -> bool:
	if a.get("rect") is Array:
		return (a["rect"] as Array).size() == 4
	return polygon(a).size() >= 3


static func _id_number(id: String) -> int:
	var digits := ""
	for i in range(id.length() - 1, -1, -1):
		if id[i] >= "0" and id[i] <= "9":
			digits = id[i] + digits
		else:
			break
	return digits.to_int() if not digits.is_empty() else 0
