extends TestCase
## Depth sorting: the full sort (fast path == reference implementation), the
## incremental orders (DepthSorter.Order / KeyedOrder / LabelSeq) against the
## full sort over thousands of random edits, and the ObjectRenderer integration
## (incremental draw order, world entries, picking, drag preview, lift).
## Synthetic geometry and generated flat-colour images only.

const TMP := "user://test_depth_sort"


func after_each() -> void:
	PackInstaller.remove_recursive(ProjectSettings.globalize_path(TMP))


func _entry(uid: int, r: Rect2i, height: float = 2.0) -> DepthSorter.Entry:
	# Sprite bounds: the footprint diamond extended upward by `height` tiles.
	var b := Iso.footprint_world_bounds(r.position, r.size)
	var h := height * Iso.Z_UNIT
	b.position.y -= h
	b.size.y += h
	return DepthSorter.Entry.new(uid, r, b)


func _index(order: Array, uid: int) -> int:
	return order.find(uid)


func test_simple_row() -> void:
	var order := DepthSorter.sort([_entry(1, Rect2i(0, 0, 1, 1)), _entry(2, Rect2i(1, 0, 1, 1)), _entry(3, Rect2i(2, 0, 1, 1))])
	assert_eq(order, [1, 2, 3])


func test_elongated_neighbour_regression() -> void:
	# A 1x6 hedge along y next to a 1x1 lamp at larger x: the lamp is in
	# front. A plain centre-depth key draws the lamp first (wrong).
	var hedge := _entry(1, Rect2i(0, 0, 1, 6), 1.0)
	var lamp := _entry(2, Rect2i(1, 0, 1, 1), 2.0)
	assert_true(hedge.key > lamp.key, "precondition: naive key would be wrong")
	var order := DepthSorter.sort([lamp, hedge])
	assert_true(_index(order, 1) < _index(order, 2), "hedge behind lamp")


func test_big_building_and_small_side_object() -> void:
	var big := _entry(1, Rect2i(0, 0, 4, 4), 3.0)
	var small := _entry(2, Rect2i(4, 0, 1, 1), 1.0)
	var order := DepthSorter.sort([small, big])
	assert_true(_index(order, 1) < _index(order, 2))
	var front := _entry(3, Rect2i(0, 4, 1, 1), 1.0)
	order = DepthSorter.sort([front, big, small])
	assert_true(_index(order, 1) < _index(order, 3))


func test_deterministic_regardless_of_input_order() -> void:
	var entries: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var occupied := {}
	var uid := 1
	for i in 200:
		var w := rng.randi_range(1, 4)
		var h := rng.randi_range(1, 4)
		var p := Vector2i(rng.randi_range(0, 40), rng.randi_range(0, 40))
		var r := Rect2i(p, Vector2i(w, h))
		var clash := false
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if occupied.has(Vector2i(x, y)):
					clash = true
		if clash:
			continue
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				occupied[Vector2i(x, y)] = true
		entries.append(_entry(uid, r, rng.randf_range(0.2, 4.0)))
		uid += 1
	var a := DepthSorter.sort(entries)
	var shuffled := entries.duplicate()
	shuffled.shuffle()
	var b := DepthSorter.sort(shuffled)
	assert_eq(a, b, "same order for shuffled input")
	assert_eq(a.size(), entries.size())
	# Every overlapping pair respects the separation rule.
	var pos := {}
	for i in a.size():
		pos[a[i]] = i
	var violations := 0
	for i in entries.size():
		for j in range(i + 1, entries.size()):
			var ei: DepthSorter.Entry = entries[i]
			var ej: DepthSorter.Entry = entries[j]
			if not ei.bounds.intersects(ej.bounds):
				continue
			var c := DepthSorter.compare(ei, ej)
			if (c < 0) != (pos[ei.uid] < pos[ej.uid]):
				violations += 1
	assert_eq(violations, 0, "pairwise order violations")


func test_empty() -> void:
	assert_eq(DepthSorter.sort([]), [])
	var o := DepthSorter.Order.new()
	o.rebuild([])
	assert_true(o.apply([], []))
	assert_eq(o.order(), [])


# --- fast full sort == reference ------------------------------------------------------

static func _rand_rect(rng: RandomNumberGenerator, area: Rect2i) -> Rect2i:
	var sizes := [Vector2i(1, 1), Vector2i(1, 1), Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3), Vector2i(1, 4),
		Vector2i(4, 1), Vector2i(1, 6), Vector2i(6, 1), Vector2i(2, 3), Vector2i(3, 2), Vector2i(4, 4), Vector2i(2, 1)]
	var s: Vector2i = sizes[rng.randi() % sizes.size()]
	return Rect2i(Vector2i(rng.randi_range(area.position.x, area.end.x - s.x), rng.randi_range(area.position.y, area.end.y - s.y)), s)


static func _rand_entry(rng: RandomNumberGenerator, uid: int, r: Rect2i) -> DepthSorter.Entry:
	## Renderer-like sprite bounds: footprint diamond, a random height, often
	## wider than the footprint, sometimes fractional, sometimes exactly
	## touching a neighbour (integer edges).
	var b := Iso.footprint_world_bounds(r.position, r.size)
	var h := rng.randf_range(0.0, 4.5) * Iso.Z_UNIT
	var grow := 0.0 if rng.randf() < 0.4 else rng.randf_range(0.0, 28.0)
	var out := Rect2(b.position.x - grow, b.position.y - h, b.size.x + 2.0 * grow, b.size.y + h)
	if rng.randf() < 0.35:
		out = Rect2(out.position.round(), out.size.round())
	return DepthSorter.Entry.new(uid, r, out)


func test_fast_sort_matches_reference() -> void:
	var rng := RandomNumberGenerator.new()
	var compared := 0
	var cyclic_cases := 0
	for seed_v in 40:
		rng.seed = 1000 + seed_v
		var n := rng.randi_range(1, 260)
		var area := Rect2i(-25, -18, 50 + rng.randi_range(0, 20), 40)
		var overlap_ok := seed_v % 4 == 3
		var occ := {}
		var entries: Array = []
		var uid := rng.randi_range(-50, 5)
		for i in n * 3:
			if entries.size() >= n:
				break
			var r := _rand_rect(rng, area)
			if not overlap_ok and not _free(occ, r, -(1 << 40)):
				continue
			_occupy(occ, r, uid)
			if uid == 0:
				uid += 1
			entries.append(_rand_entry(rng, uid, r))
			uid += 1
		var det := DepthSorter.sort_detailed(entries)
		var ref := DepthSorter.sort_reference(entries)
		if det["cyclic"]:
			cyclic_cases += 1
		if det["order"] != ref:
			fail("seed %d: fast sort differs from the reference (%d entries)" % [seed_v, entries.size()])
			return
		compared += 1
	assert_eq(compared, 40, "every random case compared")
	assert_true(cyclic_cases > 0, "some random overlap cases contain cycles (the cycle-breaking path is compared too)")


func test_overlap_predicate_is_rect2_intersects() -> void:
	# The packed-array overlap test in sort_detailed must behave exactly like
	# Rect2.intersects (borders excluded) on float32 values.
	var a := DepthSorter.Entry.new(1, Rect2i(0, 0, 1, 1), Rect2(0.0, 0.0, 10.1, 7.3))
	var touching := DepthSorter.Entry.new(2, Rect2i(1, 0, 1, 1), Rect2(10.1, 0.0, 5.0, 5.0))
	var inside := DepthSorter.Entry.new(3, Rect2i(0, 1, 1, 1), Rect2(10.0999, 7.2999, 5.0, 5.0))
	assert_false(DepthSorter.overlaps(a, touching))
	assert_true(DepthSorter.overlaps(a, inside))
	assert_eq(DepthSorter.sort_detailed([a, touching, inside])["edges"], 1, "touching bounds make no edge")


func test_constructed_cycle_is_reported_and_broken() -> void:
	# hedge -> lamp by separation, lamp -> c and c -> hedge by centre depth
	# (c overlaps both footprints: bad data).
	var hedge := _entry(1, Rect2i(0, 0, 1, 6), 4.0)
	var lamp := _entry(2, Rect2i(1, 0, 1, 1), 4.0)
	var c := _entry(3, Rect2i(0, 0, 2, 3), 4.0)
	assert_eq(DepthSorter.compare(hedge, lamp), -1)
	assert_eq(DepthSorter.compare(lamp, c), -1)
	assert_eq(DepthSorter.compare(c, hedge), -1)
	var det := DepthSorter.sort_detailed([hedge, lamp, c])
	assert_true(det["cyclic"], "cycle detected")
	assert_eq((det["order"] as Array).size(), 3)
	assert_eq(det["order"], DepthSorter.sort_reference([hedge, lamp, c]))
	# Incremental: adding the closing entry is detected by Pearce-Kelly.
	var o := DepthSorter.Order.new()
	o.max_incremental = 1000
	o.rebuild([hedge, lamp])
	assert_false(o.cyclic)
	assert_false(o.apply([], [c]), "cycle -> full sort fallback")
	assert_eq(o.stats["fallback_cycle"], 1)
	assert_true(o.cyclic)
	assert_eq(o.order(), DepthSorter.sort([hedge, lamp, c]), "cyclic graph: exactly the full sort")
	# While cyclic, every edit re-sorts fully (exactly the full sort's order).
	var far := _entry(4, Rect2i(30, 30, 1, 1))
	assert_false(o.apply([], [far]))
	assert_eq(o.stats["fallback_cyclic_graph"], 1)
	assert_eq(o.order(), DepthSorter.sort([hedge, lamp, c, far]))
	# Removing a cycle member makes the graph acyclic again -> incremental.
	assert_false(o.apply([3], []))
	assert_false(o.cyclic)
	assert_true(o.apply([], [_entry(5, Rect2i(31, 30, 1, 1))]), "back to incremental")
	assert_eq(o.violations(), 0)


# --- incremental order vs full sort: randomized ----------------------------------------

static func _free(occ: Dictionary, r: Rect2i, ignore_uid: int, ignore: Dictionary = {}) -> bool:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var u: Variant = occ.get(Vector2i(x, y))
			if u != null and u != ignore_uid and not ignore.has(u):
				return false
	return true


static func _occupy(occ: Dictionary, r: Rect2i, uid: int) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			occ[Vector2i(x, y)] = uid


static func _vacate(occ: Dictionary, r: Rect2i, uid: int) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if occ.get(Vector2i(x, y)) == uid:
				occ.erase(Vector2i(x, y))


func _random_edits(seed_v: int, steps: int, n0: int, overlap_p: float, max_inc: int) -> Dictionary:
	## Random add / remove / move / group move / flip / art change / paste /
	## mixed batches on a model; after every step the incremental order must
	## order every overlapping pair exactly like a fresh full sort. Every 40
	## steps the order's neighbour index is checked against brute force.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var area := Rect2i(-24, -16, 48, 36)   # negative tiles included
	var model := {}                         # uid -> Entry
	var occ := {}
	var next_uid := 1
	for i in n0 * 4:
		if model.size() >= n0:
			break
		var r := _rand_rect(rng, area)
		if _free(occ, r, 0):
			_occupy(occ, r, next_uid)
			model[next_uid] = _rand_entry(rng, next_uid, r)
			next_uid += 1
	var o := DepthSorter.Order.new()
	o.max_incremental = max_inc
	o.rebuild(model.values())
	var res := {"steps": 0, "mismatch": 0, "violations": 0, "pairs": 0, "stale": 0, "edge_set_mismatch": 0,
		"bad_labels": 0, "incremental": 0, "full": 0, "cyclic_steps": 0, "cyclic_order_mismatch": 0}
	for step in steps:
		var removed: Array = []
		var ups: Array = []
		var op := rng.randi() % 9
		var keys := model.keys()
		match op:
			0, 1:   # add one
				for k in 30:
					var r := _rand_rect(rng, area)
					if _free(occ, r, 0) or rng.randf() < overlap_p:
						_occupy(occ, r, next_uid)
						ups.append(_rand_entry(rng, next_uid, r))
						next_uid += 1
						break
			2:      # remove one
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					_vacate(occ, (model[u] as DepthSorter.Entry).rect, u)
					removed.append(u)
			3, 4:   # move one
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					var e: DepthSorter.Entry = model[u]
					var d := Vector2i(rng.randi_range(-4, 4), rng.randi_range(-4, 4))
					var nr := Rect2i(e.rect.position + d, e.rect.size)
					if d != Vector2i.ZERO and (_free(occ, nr, u) or rng.randf() < overlap_p):
						_vacate(occ, e.rect, u)
						_occupy(occ, nr, u)
						ups.append(DepthSorter.Entry.new(u, nr, Rect2(e.bounds.position + Iso.grid_to_world(Vector2(d)), e.bounds.size)))
			5:      # move a group (a marquee selection of up to 30 nearby objects)
				if keys.size() > 3:
					var c: DepthSorter.Entry = model[keys[rng.randi() % keys.size()]]
					var k := rng.randi_range(2, 30)
					var near := keys.duplicate()
					near.sort_custom(func(a: int, b: int) -> bool: return Vector2((model[a] as DepthSorter.Entry).rect.position - c.rect.position).length_squared() < Vector2((model[b] as DepthSorter.Entry).rect.position - c.rect.position).length_squared())
					near.resize(mini(k, near.size()))
					var ign := {}
					for u in near:
						ign[u] = true
					var d := Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3))
					var ok := d != Vector2i.ZERO
					for u in near:
						if ok and not _free(occ, Rect2i((model[u] as DepthSorter.Entry).rect.position + d, (model[u] as DepthSorter.Entry).rect.size), -(1 << 40), ign):
							ok = rng.randf() < overlap_p
					if ok:
						for u in near:
							_vacate(occ, (model[u] as DepthSorter.Entry).rect, u)
						for u in near:
							var e: DepthSorter.Entry = model[u]
							var nr := Rect2i(e.rect.position + d, e.rect.size)
							_occupy(occ, nr, u)
							ups.append(DepthSorter.Entry.new(u, nr, Rect2(e.bounds.position + Iso.grid_to_world(Vector2(d)), e.bounds.size)))
			6:      # flip / resize (swap footprint axes) -> new sprite bounds
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					var e: DepthSorter.Entry = model[u]
					var nr := Rect2i(e.rect.position, Vector2i(e.rect.size.y, e.rect.size.x))
					if _free(occ, nr, u) or rng.randf() < overlap_p:
						_vacate(occ, e.rect, u)
						_occupy(occ, nr, u)
						ups.append(_rand_entry(rng, u, nr))
			7:      # art / variant change: same footprint, new sprite bounds
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					ups.append(_rand_entry(rng, u, (model[u] as DepthSorter.Entry).rect))
			8:      # paste a row of 6, plus remove 2 (mixed batch)
				var s := Vector2i(rng.randi_range(1, 2), rng.randi_range(1, 2))
				var at := Vector2i(rng.randi_range(area.position.x, area.end.x - 6 * s.x), rng.randi_range(area.position.y, area.end.y - s.y))
				var all_free := true
				for k in 6:
					if not _free(occ, Rect2i(at + Vector2i(k * s.x, 0), s), 0):
						all_free = false
				if all_free:
					for k in 6:
						var r := Rect2i(at + Vector2i(k * s.x, 0), s)
						_occupy(occ, r, next_uid)
						ups.append(_rand_entry(rng, next_uid, r))
						next_uid += 1
				for k in 2:
					if keys.size() > k:
						var u: int = keys[rng.randi() % keys.size()]
						if not removed.has(u):
							_vacate(occ, (model[u] as DepthSorter.Entry).rect, u)
							removed.append(u)
		# Drop removals that are also re-added in this batch (keep it a set).
		for e: DepthSorter.Entry in ups:
			removed.erase(e.uid)
		if removed.is_empty() and ups.is_empty():
			continue
		for u in removed:
			model.erase(u)
		for e: DepthSorter.Entry in ups:
			model[e.uid] = e
		if o.apply(removed, ups):
			res["incremental"] += 1
		else:
			res["full"] += 1
		res["steps"] += 1
		var entries := model.values()
		var full := DepthSorter.sort(entries)
		if o.cyclic:
			res["cyclic_steps"] += 1
			if o.order() != full:
				res["cyclic_order_mismatch"] += 1
			continue
		# Every stored edge (= every overlapping pair; the stored edge set is
		# checked against brute force below) must be ordered like the full sort.
		var pos := {}
		for i in full.size():
			pos[full[i]] = i
		var lab := o.seq.label
		for u: int in o.succ:
			var pu: int = pos[u]
			var lu: int = lab[u]
			for nb: int in o.succ[u]:
				res["pairs"] += 1
				if (pu < int(pos[nb])) != (lu < int(lab[nb])):
					res["mismatch"] += 1
		if step % 40 == 0:
			res["violations"] += o.violations()
			if o.size() != model.size():
				res["stale"] += 1
			for e: DepthSorter.Entry in entries:
				var oe := o.entry(e.uid)
				if oe == null or oe.rect != e.rect or oe.bounds != e.bounds:
					res["stale"] += 1
			# Brute-force edge set == the order's neighbour index.
			var brute := 0
			for i in entries.size():
				for j in range(i + 1, entries.size()):
					if (entries[i] as DepthSorter.Entry).bounds.intersects((entries[j] as DepthSorter.Entry).bounds):
						brute += 1
			if brute != o.edge_count() or o.adjacency_errors() != 0:
				res["edge_set_mismatch"] += 1
			var labs := o.seq.lab
			for i in labs.size():
				if (i > 0 and labs[i] <= labs[i - 1]) or int(o.seq.label[o.seq.ids[i]]) != labs[i]:
					res["bad_labels"] += 1
	res["stats"] = o.stats.duplicate()
	res["relabels"] = o.seq.relabels
	return res


func _check_random_run(r: Dictionary, label: String) -> void:
	assert_eq(r["mismatch"], 0, "%s: pairs ordered differently from the full sort" % label)
	assert_eq(r["violations"], 0, "%s: violated edges" % label)
	assert_eq(r["stale"], 0, "%s: stale entries" % label)
	assert_eq(r["edge_set_mismatch"], 0, "%s: neighbour index != brute force" % label)
	assert_eq(r["bad_labels"], 0, "%s: labels not strictly increasing / inconsistent" % label)
	assert_eq(r["cyclic_order_mismatch"], 0, "%s: cyclic graph must use exactly the full sort" % label)
	assert_eq(int(r["stats"]["fallback_invariant"]), 0, "%s: the local invariant safety net never fires" % label)


func test_incremental_order_matches_full_sort_randomized() -> void:
	# 3 seeds x 700 steps of always-incremental edits (falls back only on cycles).
	var total := 0
	var pk := 0
	var pairs := 0
	for seed_v in [11, 22, 33]:
		var r := _random_edits(seed_v, 820, 140, 0.0, 1 << 30)
		_check_random_run(r, "seed %d" % seed_v)
		# Fallbacks only happen when a (rare) depth cycle exists: every edit then
		# re-sorts fully until the cycle is gone (counted in cyclic_steps).
		assert_eq(r["incremental"] + r["cyclic_steps"] + int(r["stats"]["fallback_cycle"]), r["steps"], "seed %d: incremental unless cyclic" % seed_v)
		assert_true(r["incremental"] > r["steps"] * 0.6, "seed %d: incremental path used (%d of %d)" % [seed_v, r["incremental"], r["steps"]])
		total += r["steps"]
		pk += int(r["stats"]["pk_calls"])
		pairs += int(r["pairs"])
	assert_true(total >= 2000, "thousands of edits checked (%d)" % total)
	assert_true(pk > 0, "Pearce-Kelly repairs exercised (%d)" % pk)
	assert_true(pairs > 100000, "overlapping pairs compared (%d)" % pairs)


func test_incremental_order_with_bad_data_and_batch_fallbacks() -> void:
	# Overlapping footprints (cycles possible) and the default cost-based batch
	# policy (big group moves may re-sort fully): still equivalent.
	var r := _random_edits(77, 500, 120, 0.3, -1)
	_check_random_run(r, "overlaps")
	assert_true(r["steps"] >= 400)
	var r2 := _random_edits(78, 300, 120, 0.0, 4)
	_check_random_run(r2, "max_incremental=4")
	assert_true(r2["full"] > 0 and r2["incremental"] > 0, "both paths taken (%d full, %d incremental)" % [r2["full"], r2["incremental"]])


# --- label sequences ---------------------------------------------------------------------

func test_label_seq_dense_inserts_relabel_locally() -> void:
	var s := DepthSorter.LabelSeq.new()
	var model: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var next := 1
	var bad := 0
	for i in 3000:
		var r := rng.randf()
		if r < 0.45 or model.is_empty():
			# hot spot: keep inserting right after the same element
			var p := mini(model.size(), 7)
			s.insert_at(p, next)
			model.insert(p, next)
			next += 1
		elif r < 0.85:
			var p2 := rng.randi_range(0, model.size())
			s.insert_at(p2, next)
			model.insert(p2, next)
			next += 1
		else:
			var u: int = model[rng.randi() % model.size()]
			s.remove(u)
			model.erase(u)
		if i % 100 == 0:
			if s.order() != model:
				bad += 1
			for k in range(1, s.lab.size()):
				if s.lab[k] <= s.lab[k - 1]:
					bad += 1
	assert_eq(bad, 0, "sequence and strictly increasing labels kept")
	assert_eq(s.order(), model)
	assert_true(s.relabels > 0, "gaps were exhausted and relabelled locally (%d)" % s.relabels)
	assert_eq(s.renumbers, 0, "no global renumber needed")
	assert_true(float(s.relabeled_nodes) / s.relabels < 200.0, "relabel windows stay small (avg %.1f)" % (float(s.relabeled_nodes) / s.relabels))
	for id in model:
		assert_true(absi(int(s.label[id])) < DepthSorter.LabelSeq.LIMIT)


func test_keyed_order_matches_sorted_keys() -> void:
	var k := DepthSorter.KeyedOrder.new()
	var keys := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in 1500:
		var id := rng.randi_range(1, 300)
		if rng.randf() < 0.25:
			k.remove(id)
			keys.erase(id)
		else:
			var key := DepthSorter.KeyedOrder.flat_key(Rect2i(rng.randi_range(-30, 30), rng.randi_range(-30, 30), 1, 1), id)
			k.upsert(id, key)
			keys[id] = key
	var expect := keys.keys()
	expect.sort_custom(func(a: int, b: int) -> bool: return keys[a] < keys[b])
	assert_eq(k.order(), expect)
	for i in range(1, expect.size()):
		assert_true(k.index_of(expect[i - 1]) < k.index_of(expect[i]))
	# Flat order = (x + y, uid), negative tiles included.
	assert_true(DepthSorter.KeyedOrder.flat_key(Rect2i(-5, -5, 1, 1), 9) < DepthSorter.KeyedOrder.flat_key(Rect2i(-5, -4, 1, 1), 1))
	assert_true(DepthSorter.KeyedOrder.flat_key(Rect2i(2, 3, 1, 1), 4) < DepthSorter.KeyedOrder.flat_key(Rect2i(3, 2, 1, 1), 5))


# --- renderer integration ----------------------------------------------------------------

static func _img(w: int, h: int, used: Rect2i, col: Color) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(used, col)
	return img


static func _write_json(path: String, data: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))
	f.close()


static func _save(img: Image, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)


func _lib() -> AssetLibrary:
	## A built-in-style pack for the fixture items and a "private-style" pack
	## with synthetic landmark art (variants, a transparent half for picking).
	var base := TMP.path_join("builtin")
	_save(_img(40, 80, Rect2i(0, 0, 40, 80), Color(0.8, 0.5, 0.2)), base.path_join("lamp.png"))
	_save(_img(200, 160, Rect2i(0, 0, 200, 160), Color(0.5, 0.5, 0.9)), base.path_join("bakery.png"))
	_save(_img(64, 160, Rect2i(0, 0, 64, 160), Color(0.3, 0.7, 0.3)), base.path_join("long.png"))
	_save(_img(64, 32, Rect2i(0, 0, 64, 32), Color(0.6, 0.6, 0.6)), base.path_join("path.png"))
	_save(_img(30, 50, Rect2i(0, 0, 30, 50), Color(0.6, 0.4, 0.3)), base.path_join("fence.png"))
	_write_json(base.path_join("pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": AssetLibrary.BUILTIN_ID, "priority": 0,
		"pixels_per_world_px": 1.0, "sprites": {
			"t_lamp": {"file": "lamp.png", "anchor": [20, 70]}, "t_bakery": {"file": "bakery.png", "anchor": [100, 130]},
			"t_long": {"file": "long.png", "anchor": [32, 120]}, "t_path": {"file": "path.png", "anchor": [32, 16]},
			"t_fence": {"file": "fence.png", "anchor": [15, 45]}}})
	var up := TMP.path_join("user/priv")
	_save(_img(128, 128, Rect2i(0, 0, 64, 128), Color(0.9, 0.2, 0.2)), up.path_join("lm_alpha.png"))
	for name in ["lm_test", "lm_test__stage_1", "lm_test__stage_1__winter", "lm_test__skin_red"]:
		_save(_img(96, 96, Rect2i(0, 0, 96, 96), Color(0.2, 0.2, 0.2)), up.path_join(name + ".png"))
	_write_json(up.path_join("pack.json"), {"format": AssetLibrary.PACK_FORMAT, "id": "priv", "priority": 5,
		"pixels_per_world_px": 1.0, "sprites": {
			"lm_alpha": {"file": "lm_alpha.png", "anchor": [64, 128]},
			"lm_test": {"file": "lm_test.png", "anchor": [48, 90], "variants": {
				"stage_1": {"file": "lm_test__stage_1.png"}, "stage_1__winter": {"file": "lm_test__stage_1__winter.png"},
				"skin_red": {"file": "lm_test__skin_red.png"}}}}})
	var lib := AssetLibrary.new()
	lib.builtin_pack_path = base.path_join("pack.json")
	lib.dev_packs_dir = TMP.path_join("no_dev")
	lib.user_packs_dir = TMP.path_join("user")
	lib.load_all()
	return lib


func _renderer(layout: FarmLayout, db: ItemDatabase, lib: AssetLibrary) -> ObjectRenderer:
	var r := ObjectRenderer.new()
	r._ready()   # not in a tree in --script tests: create the layer nodes by hand
	r.bind(layout, db, lib)
	r.ensure_sorted()
	return r


func _dispose(r: ObjectRenderer) -> void:
	r._exit_tree()
	r.free()


func _add(layout: FarmLayout, db: ItemDatabase, item: String, at: Vector2i, flipped: bool = false) -> int:
	var o := make_obj(db.get_item(item), at, flipped)
	return layout.add_objects([o], true)[0]


func test_renderer_incremental_edits_match_full_sort() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var items := ["t_lamp", "t_lamp", "t_bakery", "t_long", "t_path", "t_fence", "t_fence", "t_mystery"]
	for i in 160:
		var it := db.get_item(items[rng.randi() % items.size()])
		var at := Vector2i(rng.randi_range(-10, 30), rng.randi_range(-8, 30))
		var fl := rng.randf() < 0.3
		if layout.object_at(at) == null and _area_free(layout, Rect2i(at, it.size_for(fl)), 0):
			layout.add_objects([make_obj(it, at, fl)], false)
	var r := _renderer(layout, db, lib)
	r.set_world_entries([
		{"key": "lm:a", "rect": Rect2i(-6, -6, 3, 3), "art": "lm_test", "variant": "stage_1"},
		{"key": "lm:b", "rect": Rect2i(12, -12, 2, 4), "art": "lm_missing", "fallback_art": "t_bakery"},
		{"key": "lm:c", "rect": Rect2i(31, 31, 2, 2), "art": "lm_alpha"}])
	var bad := 0
	var incremental := 0
	var steps := 0
	for step in 300:
		var keys := layout.objects.keys()
		var op := rng.randi() % 7
		match op:
			0:
				var it := db.get_item(items[rng.randi() % items.size()])
				var at := Vector2i(rng.randi_range(-10, 30), rng.randi_range(-8, 30))
				if _area_free(layout, Rect2i(at, it.footprint), 0):
					layout.add_objects([make_obj(it, at)], true)
			1:
				if not keys.is_empty():
					layout.remove_objects([keys[rng.randi() % keys.size()]], true)
			2, 3:
				if not keys.is_empty():
					var group: Array = []
					for k in rng.randi_range(1, 12):
						var u: int = keys[rng.randi() % keys.size()]
						if not group.has(u):
							group.append(u)
					var d := Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3))
					var ok := true
					var ign := {}
					for u in group:
						ign[u] = true
					for u in group:
						var o := layout.get_obj(u)
						if not _area_free(layout, Rect2i(o.origin + d, o.size), 0, ign):
							ok = false
					if ok and d != Vector2i.ZERO:
						layout.move_objects(group, d, true)
			4:
				if not keys.is_empty():
					var u: int = keys[rng.randi() % keys.size()]
					var o := layout.get_obj(u)
					var ns := Vector2i(o.size.y, o.size.x)
					if _area_free(layout, Rect2i(o.origin, ns), u):
						o.flipped = not o.flipped
						layout.set_object_rect(u, o.origin, ns, true)
			5:
				r.update_world_entry(["lm:a", "lm:b", "lm:c"][rng.randi() % 3], {"rect": Rect2i(rng.randi_range(-12, 30), rng.randi_range(-12, 30), rng.randi_range(1, 3), rng.randi_range(1, 3)),
					"visible": rng.randf() < 0.85, "variant": ["", "stage_1", "stage_1__winter", "skin_red"][rng.randi() % 4]})
			6:
				if not keys.is_empty():
					var u2: int = keys[rng.randi() % keys.size()]
					layout.set_property([u2], "variant", [["", "winter"][rng.randi() % 2]], true)
		r.ensure_sorted()
		steps += 1
		if r.depth_stats()["last_flush"] == "incremental":
			incremental += 1
		var c := r.check_order()
		if c["mismatch"] != 0 or c["flat_mismatch"] != 0 or c["stale"] != 0 or (not c["cyclic"] and c["violations"] != 0):
			bad += 1
			if bad == 1:
				fail("step %d op %d: %s" % [step, op, str(c)])
	assert_eq(bad, 0, "draw order equals the full sort after every edit")
	assert_true(incremental > steps * 0.8, "edits handled incrementally (%d of %d)" % [incremental, steps])
	# The forced full rebuild path (perf self-test uses it) gives the same order.
	var before := {}
	for u in layout.objects:
		before[u] = r.order_of(u)
	r._order_dirty = true
	r.ensure_sorted()
	assert_eq(r.depth_stats()["last_flush"], "full")
	var c2 := r.check_order()
	assert_eq(c2["mismatch"], 0)
	_dispose(r)


func _area_free(layout: FarmLayout, rect: Rect2i, ignore_uid: int, ignore: Dictionary = {}) -> bool:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var o := layout.object_at(Vector2i(x, y))
			if o and o.uid != ignore_uid and not ignore.has(o.uid):
				return false
	return true


func test_world_entries_variants_fallbacks_and_depth() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var r := _renderer(layout, db, lib)
	r.set_world_entries([
		{"key": "lm:house", "rect": Rect2i(-8, -5, 3, 3), "art": "lm_test", "fallback_art": "t_bakery", "variant": "stage_1__winter",
			"draw_anchor": "top_corner", "selectable": true, "visible": true},
		{"key": "lm:themed_missing", "rect": Rect2i(-20, 4, 2, 2), "art": "lm_test", "variant": "stage_1__autumn"},
		{"key": "lm:unknown_state", "rect": Rect2i(-20, 10, 2, 2), "art": "lm_test", "variant": "no_such_state"},
		{"key": "lm:fallback", "rect": Rect2i(-30, -30, 2, 2), "art": "lm_not_in_any_pack", "fallback_art": "t_bakery", "variant": "stage_1"},
		{"key": "lm:marker", "rect": Rect2i(-3, -40, 1, 2), "art": "lm_not_in_any_pack", "fallback_art": ""},
		{"key": "lm:house", "rect": Rect2i(50, 50, 1, 1)}])   # duplicate key: first wins
	assert_eq(r.world_entry_keys().size(), 5)
	assert_eq(r.world_sprite_of("lm:house").variant, "stage_1__winter", "exact variant")
	assert_eq(r.world_sprite_of("lm:themed_missing").variant, "stage_1", "missing theme variant -> its state")
	assert_eq(r.world_sprite_of("lm:unknown_state").variant, "", "unknown state -> base image")
	assert_eq(r.world_sprite_of("lm:fallback").path, "bakery.png", "art not in any pack -> fallback_art")
	assert_null(r.world_sprite_of("lm:marker"), "no art at all -> footprint marker")
	var mb := r.world_entry_bounds("lm:marker")
	assert_true(mb.size.x > 0 and mb.size.y > 0, "marker has bounds")
	assert_true(mb.has_point(Iso.footprint_center(Vector2i(-3, -40), Vector2i(1, 2))), "marker drawn on its (negative) footprint")
	var hb := r.world_entry_bounds("lm:house")
	var hc := Iso.footprint_center(Vector2i(-8, -5), Vector2i(3, 3))
	var hs := r.world_sprite_of("lm:house")
	assert_eq(hb, hs.world_rect(hc, false), "sprite anchored at the footprint's ground centre, like item sprites")
	assert_vec_almost(hb.position, hc - hs.anchor * hs.scale, 0.01)
	assert_eq(r.world_entry_bounds("lm:nope"), Rect2())
	assert_eq(layout.count(), 0, "world entries never enter the layout")
	# Depth: an object right in front of the house (separated along +x) draws
	# after it, one right behind (along -y) before it.
	var front := _add(layout, db, "t_lamp", Vector2i(-5, -4))
	var behind := _add(layout, db, "t_lamp", Vector2i(-7, -6))
	assert_true(r.order_of(front) > r.world_order_of("lm:house"), "object in front of the landmark")
	assert_true(r.order_of(behind) < r.world_order_of("lm:house"), "object behind the landmark")
	assert_eq(r.depth_stats()["last_flush"], "incremental")
	assert_eq(r.check_order()["mismatch"], 0)
	# update_world_entry: variant, skin, visibility, position (incremental).
	assert_true(r.update_world_entry("lm:house", {"variant": "skin_red"}))
	assert_eq(r.world_sprite_of("lm:house").variant, "skin_red")
	assert_false(r.update_world_entry("lm:nope", {"variant": "x"}))
	var n_up: int = r.check_order()["uprights"]
	r.update_world_entry("lm:house", {"visible": false})
	assert_eq(r.check_order()["uprights"], n_up - 1, "hidden entries leave the draw order")
	assert_eq(r.pick_any(hc)["kind"], "object" if layout.object_at(Iso.world_to_tile(hc)) else "", "hidden landmark is not pickable")
	r.update_world_entry("lm:house", {"visible": true, "rect": Rect2i(-9, -5, 3, 3)})
	assert_eq(r.world_entry("lm:house")["rect"], Rect2i(-9, -5, 3, 3))
	assert_eq(r.check_order()["mismatch"], 0)
	assert_eq(r.check_order()["stale"], 0)
	# Replacing the set removes entries that are gone.
	r.set_world_entries([{"key": "lm:house", "rect": [-9, -5, 3, 3], "art": "lm_test"}])
	assert_eq(r.world_entry_keys(), ["lm:house"])
	assert_eq(r.check_order()["stale"], 0)
	r.set_world_entries([])
	assert_eq(r.world_entry_keys().size(), 0)
	assert_eq(r.check_order()["uprights"], 2)
	_dispose(r)


func test_pick_any_pixel_accurate_and_footprint_fallback() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var r := _renderer(layout, db, lib)
	# A landmark whose sprite is opaque only on its left half, and a lamp
	# behind it whose sprite sticks out above the landmark's footprint.
	r.set_world_entries([{"key": "lm:alpha", "rect": Rect2i(4, 4, 2, 2), "art": "lm_alpha"}])
	var lamp := _add(layout, db, "t_lamp", Vector2i(3, 3))
	var wb := r.world_entry_bounds("lm:alpha")
	assert_vec_almost(wb.position, Vector2(-64, 32), 0.01)
	var lb := r.bounds_of(lamp)
	assert_vec_almost(lb.position, Vector2(-20, 42), 0.01)
	assert_true(r.order_of(lamp) < r.world_order_of("lm:alpha"), "lamp behind the landmark")
	var opaque := Vector2(-10, 100)        # in both sprites; landmark's opaque half
	var transparent := Vector2(10, 100)    # in both sprites; landmark transparent there
	assert_eq(r.pick_any(opaque), {"kind": "landmark", "uid": 0, "key": "lm:alpha"}, "top-most opaque pixel wins")
	assert_eq(r.pick_any(transparent), {"kind": "object", "uid": lamp, "key": ""}, "transparent landmark pixels fall through")
	assert_eq(r.pick(opaque), lamp, "pick() only ever returns layout objects")
	# Footprint fallback: the landmark's own ground tile where its sprite is transparent.
	var tile_pt := Iso.tile_center(Vector2i(5, 4))
	assert_true(tile_pt.x > 0.0, "precondition: right (transparent) half")
	assert_eq(r.pick_any(tile_pt)["key"], "lm:alpha", "footprint fallback for world entries")
	# Not selectable: clicks go through.
	r.update_world_entry("lm:alpha", {"selectable": false})
	assert_eq(r.pick_any(opaque)["uid"], lamp)
	assert_eq(r.pick_any(tile_pt)["kind"], "")
	# Hidden objects are skipped unless asked for.
	r.set_hidden([lamp])
	assert_eq(r.pick_any(opaque)["kind"], "")
	assert_eq(r.pick_any(opaque, true)["uid"], lamp)
	r.set_hidden([])
	# Overlapping landmarks (allowed world data) never crash picking/sorting.
	r.set_world_entries([{"key": "lm:alpha", "rect": Rect2i(4, 4, 2, 2), "art": "lm_alpha"},
		{"key": "lm:over", "rect": Rect2i(4, 5, 3, 3), "art": "lm_test"},
		{"key": "lm:over2", "rect": Rect2i(3, 4, 2, 4), "art": "lm_missing"}])
	assert_true(r.pick_any(Iso.tile_center(Vector2i(4, 5)))["kind"] in ["landmark", "object"])
	var c := r.check_order()
	assert_eq(c["mismatch"], 0)
	assert_eq(c["stale"], 0)
	_dispose(r)


func test_flats_rank_below_uprights_and_follow_x_plus_y() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var r := _renderer(layout, db, lib)
	var p1 := _add(layout, db, "t_path", Vector2i(5, 5))
	var p2 := _add(layout, db, "t_path", Vector2i(-3, -3))
	var lamp := _add(layout, db, "t_lamp", Vector2i(-20, -20))
	assert_true(r.order_of(p2) < r.order_of(p1), "flats by x + y (negative tiles too)")
	assert_true(r.order_of(p1) < r.order_of(lamp), "flats below every upright")
	layout.move_objects([p2], Vector2i(20, 20), true)
	assert_true(r.order_of(p1) < r.order_of(p2))
	assert_eq(r.check_order()["flat_mismatch"], 0)
	_dispose(r)


func test_drag_preview_and_lift_sort_without_touching_the_layout() -> void:
	var db := fixture_db()
	var lib := _lib()
	var layout := FarmLayout.new()
	var r := _renderer(layout, db, lib)
	var a := _add(layout, db, "t_lamp", Vector2i(0, 0))
	var b := _add(layout, db, "t_lamp", Vector2i(1, 0))
	var c := _add(layout, db, "t_lamp", Vector2i(0, 2))
	assert_true(r.bounds_of(a).intersects(r.bounds_of(b)), "precondition: a and b overlap on screen")
	assert_true(r.order_of(a) < r.order_of(b))
	var real_bounds := r.bounds_of(a)
	r.set_drag_preview([a], Vector2i(2, 0), Vector2(5, -3))
	r.ensure_sorted()
	assert_true(r.is_previewing(a))
	assert_eq(layout.get_obj(a).origin, Vector2i(0, 0), "layout untouched")
	assert_eq(r.bounds_of(a), real_bounds, "picking keeps the real position")
	assert_true(r.order_of(a) > r.order_of(b), "previewed object sorts at its prospective footprint (in front of b)")
	assert_eq(r.check_order()["mismatch"], 0)
	assert_eq(r.depth_stats()["last_flush"], "incremental")
	# Same preview again: nothing to do.
	r.set_drag_preview([a], Vector2i(2, 0), Vector2(5, -3))
	assert_true(r._pending.is_empty(), "unchanged preview is a no-op")
	# Group preview, then a smaller group: the dropped one returns home.
	r.set_drag_preview([a, c], Vector2i(0, -1))
	r.set_drag_preview([c], Vector2i(0, -1))
	assert_false(r.is_previewing(a))
	assert_true(r.order_of(a) < r.order_of(b), "a back at its real place")
	assert_eq(r.check_order()["mismatch"], 0)
	r.clear_drag_preview()
	assert_false(r.is_previewing(c))
	assert_eq(r.check_order()["mismatch"], 0)
	# Lift: raised sprite, sorted with its lifted bounds, then lowered.
	r.set_lift([a], 8.0)
	assert_eq(r.check_order()["mismatch"], 0)
	r.set_lift([], 0.0)
	assert_eq(r.check_order()["mismatch"], 0)
	# Removing a previewed object is safe.
	r.set_drag_preview([b], Vector2i(1, 1))
	layout.remove_objects([b], true)
	assert_false(r.is_previewing(b))
	assert_eq(r.check_order()["stale"], 0)
	_dispose(r)
