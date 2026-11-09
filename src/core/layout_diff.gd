class_name LayoutDiff
extends RefCounted
## Compares two layouts by item type and position (uids differ between
## layouts, so matching is geometric):
##   unchanged: same item at the same origin/orientation
##   moved:     same item type, different place (greedy nearest pairing)
##   added / removed: the rest.


class Result:
	var unchanged: Array = []   ## [uid_a, uid_b]
	var moved: Array = []       ## [uid_a, uid_b]
	var added: Array = []       ## uids in b
	var removed: Array = []     ## uids in a
	var item_delta: Dictionary = {}  ## item id -> count(b) - count(a)

	func summary() -> String:
		return "%d unchanged · %d moved · %d added · %d removed" % [unchanged.size(), moved.size(), added.size(), removed.size()]


static func compare(a: FarmLayout, b: FarmLayout) -> Result:
	var r := Result.new()
	var exact := {}
	for o: PlacedObject in b.objects.values():
		var k := _key(o)
		if not exact.has(k):
			exact[k] = []
		exact[k].append(o.uid)
	var rest_a := {}   # item -> [PlacedObject]
	var matched_b := {}
	var a_uids := a.objects.keys()
	a_uids.sort()
	for u in a_uids:
		var o: PlacedObject = a.objects[u]
		var k := _key(o)
		if exact.has(k) and not exact[k].is_empty():
			var ub: int = exact[k].pop_front()
			r.unchanged.append([o.uid, ub])
			matched_b[ub] = true
		else:
			if not rest_a.has(o.item_id):
				rest_a[o.item_id] = []
			rest_a[o.item_id].append(o)
	var rest_b := {}
	var b_uids := b.objects.keys()
	b_uids.sort()
	for u in b_uids:
		if matched_b.has(u):
			continue
		var o: PlacedObject = b.objects[u]
		if not rest_b.has(o.item_id):
			rest_b[o.item_id] = []
		rest_b[o.item_id].append(o)
	for item in rest_a:
		var la: Array = rest_a[item]
		var lb: Array = rest_b.get(item, [])
		# Greedy nearest pairing — good enough for planning diffs.
		var pairs: Array = []
		for oa: PlacedObject in la:
			for ob: PlacedObject in lb:
				pairs.append([(oa.origin - ob.origin).length_squared(), oa.uid, ob.uid])
		pairs.sort_custom(func(x, y):
			if x[0] == y[0]:
				return x[1] < y[1] if x[1] != y[1] else x[2] < y[2]
			return x[0] < y[0])
		var used_a := {}
		var used_b := {}
		for p in pairs:
			if used_a.has(p[1]) or used_b.has(p[2]):
				continue
			used_a[p[1]] = true
			used_b[p[2]] = true
			r.moved.append([p[1], p[2]])
		for oa: PlacedObject in la:
			if not used_a.has(oa.uid):
				r.removed.append(oa.uid)
		for ob: PlacedObject in lb:
			if not used_b.has(ob.uid):
				r.added.append(ob.uid)
		rest_b.erase(item)
	for item in rest_b:
		for ob: PlacedObject in rest_b[item]:
			r.added.append(ob.uid)
	var ca := a.item_counts()
	var cb := b.item_counts()
	for k in ca:
		var d: int = cb.get(k, 0) - ca[k]
		if d != 0:
			r.item_delta[k] = d
	for k in cb:
		if not ca.has(k):
			r.item_delta[k] = cb[k]
	return r


static func _key(o: PlacedObject) -> String:
	return "%s@%d,%d%s" % [o.item_id, o.origin.x, o.origin.y, "f" if o.flipped else ""]
