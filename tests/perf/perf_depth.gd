extends SceneTree
## Depth-order / object-renderer benchmark (headless, no App autoload).
##
##   godot --headless --path . --script res://tests/perf/perf_depth.gd \
##       [-- --sizes=500,2000,5000] [--reps=40] [--json=<path>] [--private]
##
## For every size N it generates a dense synthetic layout (random catalogue
## items with footprints up to 3x3 packed at random, the rest of the grid
## filled with 1x1 items until N objects exist; fixed seeds, so every run sees
## the same layouts) on a square open map, binds a real ObjectRenderer to it and
## measures, end to end (layout mutation -> renderer signal handlers -> draw
## order up to date):
##   * full_sort      a forced full rebuild of the draw order
##   * move_1         move one object by a small free delta
##   * move_20        move a group of 20 neighbouring objects together
##   * add_1          add one small object on a free spot
##   * remove_1       remove one object
##   * pick           one pixel-accurate pick at a random point
## Reports mean / p95 / max in milliseconds. By default only the built-in
## placeholder art is used (pass --private to include installed packs; the
## numbers are timings only, nothing game-derived is printed).

var db: ItemDatabase
var assets: AssetLibrary
var reps := 40
var out: Dictionary = {}
var sizes: Array = [500, 2000, 5000]
var json_path := ""
var _started := false


func _initialize() -> void:
	var private_art := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sizes="):
			sizes.clear()
			for s in a.substr(8).split(","):
				sizes.append(int(s))
		elif a.begins_with("--reps="):
			reps = maxi(3, int(a.substr(7)))
		elif a.begins_with("--json="):
			json_path = a.substr(7)
		elif a == "--private":
			private_art = true
	db = ItemDatabase.new()
	db.load_default()
	assets = AssetLibrary.new()
	if not private_art:
		assets.user_packs_dir = "res://__no_user_packs__"
		assets.dev_packs_dir = "res://__no_dev_packs__"
	assets.load_all(db)
	out["machine"] = {"cpus": OS.get_processor_count(), "renderer": RenderingServer.get_current_rendering_driver_name(),
		"display": DisplayServer.get_name(), "godot": Engine.get_version_info()["string"], "art": "installed packs" if private_art else "placeholders"}
	out["reps"] = reps


func _process(_delta: float) -> bool:
	## Runs once on the first frame: nodes added to the root only get _ready
	## once the main loop is running.
	if _started:
		return true
	_started = true
	for n in sizes:
		out[str(n)] = _bench(n)
		print("PERF_DEPTH %d %s" % [n, JSON.stringify(out[str(n)])])
	if not json_path.is_empty():
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(out, "  "))
			f.close()
			print("wrote " + json_path)
	quit(0)
	return true


# --- layout generation ----------------------------------------------------------------

func _pools() -> Array:
	var small: Array = []
	var ones: Array = []
	for it: ItemDef in db.ordered:
		if not it.can_place() or it.footprint.x <= 0 or it.footprint.y <= 0:
			continue
		if it.footprint.x * it.footprint.y <= 9:
			small.append(it.id)
		if it.footprint == Vector2i.ONE:
			ones.append(it.id)
	return [small, ones]


func make_layout(n: int) -> Array:
	## -> [FarmLayout, FarmMap]. About 3.2 tiles of land per object.
	var side := int(ceil(sqrt(n * 3.2)))
	var map := FarmMap.make_simple(side, side)
	var l := FarmLayout.new()
	l.map_id = map.id
	l.set_unlocked(map.all_plot_ids(), false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * n + 13
	var pools := _pools()
	var small: Array = pools[0]
	var ones: Array = pools[1]
	var target_big := int(n * 0.6)
	var tries := 0
	while l.count() < target_big and tries < n * 30:
		tries += 1
		var it := db.get_item(small[rng.randi() % small.size()])
		var o := PlacedObject.new()
		o.item_id = it.id
		o.size = it.footprint
		o.origin = Vector2i(rng.randi_range(0, side - it.footprint.x), rng.randi_range(0, side - it.footprint.y))
		if PlacementRules.check_rect(l, map, o.rect()).ok:
			l.add_objects([o], false)
	var free: Array = []
	for y in side:
		for x in side:
			if l.object_at(Vector2i(x, y)) == null:
				free.append(Vector2i(x, y))
	_shuffle(free, rng)
	var i := 0
	while l.count() < n and i < free.size():
		var f := PlacedObject.new()
		f.item_id = ones[rng.randi() % ones.size()]
		f.origin = free[i]
		f.size = Vector2i.ONE
		l.add_objects([f], false)
		i += 1
	return [l, map]


func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


# --- measurement ------------------------------------------------------------------------

static func stats(samples: Array) -> Dictionary:
	if samples.is_empty():
		return {"n": 0}
	var s := samples.duplicate()
	s.sort()
	var total := 0.0
	for v: float in s:
		total += v
	var p95: float = s[clampi(int(ceil(0.95 * s.size())) - 1, 0, s.size() - 1)]
	return {"n": s.size(), "mean_ms": snappedf(total / s.size(), 0.001), "p95_ms": snappedf(p95, 0.001),
		"max_ms": snappedf(float(s[s.size() - 1]), 0.001), "min_ms": snappedf(float(s[0]), 0.001)}


func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func _bench(n: int) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var lm: Array = make_layout(n)
	var l: FarmLayout = lm[0]
	var map: FarmMap = lm[1]
	var r := {"objects": l.count(), "map": "%dx%d" % [map.size.x, map.size.y], "gen_ms": snappedf(_ms(t0), 0.1)}
	var flats := 0
	for o: PlacedObject in l.objects.values():
		var it := db.get_item(o.item_id)
		if it and it.layer == "ground":
			flats += 1
	r["flat_objects"] = flats
	var renderer := ObjectRenderer.new()
	root.add_child(renderer)
	t0 = Time.get_ticks_usec()
	renderer.bind(l, db, assets)
	renderer.ensure_sorted()
	r["bind_and_first_sort_ms"] = snappedf(_ms(t0), 0.01)
	var rng := RandomNumberGenerator.new()
	rng.seed = 104729 + n
	# Full rebuild of the draw order.
	var full: Array = []
	for i in maxi(5, reps / 4):
		renderer._order_dirty = true
		t0 = Time.get_ticks_usec()
		renderer.ensure_sorted()
		full.append(_ms(t0))
	r["full_sort"] = stats(full)
	# Pure DepthSorter.sort on renderer-equivalent entries (no RenderingServer work).
	var entries: Array = []
	for u in l.objects:
		var it := db.get_item(l.get_obj(u).item_id)
		if it and it.layer == "ground":
			continue
		var b: Rect2 = renderer.bounds_of(u)
		entries.append(DepthSorter.Entry.new(u, l.get_obj(u).rect(), b))
	var pure: Array = []
	for i in maxi(5, reps / 4):
		t0 = Time.get_ticks_usec()
		DepthSorter.sort(entries)
		pure.append(_ms(t0))
	r["depthsorter_sort_only"] = stats(pure)
	# Edits.
	var mv1: Array = []
	var mv20: Array = []
	var add1: Array = []
	var rem1: Array = []
	var kinds := {}
	for i in reps:
		var d := _move_one(l, map, rng, renderer)
		if d >= 0.0:
			mv1.append(d)
		d = _move_group(l, map, rng, renderer, 20)
		if d >= 0.0:
			mv20.append(d)
		d = _add_one(l, map, rng, renderer)
		if d >= 0.0:
			add1.append(d)
		d = _remove_one(l, rng, renderer)
		if d >= 0.0:
			rem1.append(d)
		if renderer.has_method("depth_stats"):
			var ds: Dictionary = renderer.call("depth_stats")
			kinds[str(ds.get("last_flush", "?"))] = int(kinds.get(str(ds.get("last_flush", "?")), 0)) + 1
	r["move_1"] = stats(mv1)
	# The first edit after a full rebuild also builds the order's adjacency
	# lists (lazily); report it on its own as well (same samples as before).
	if not mv1.is_empty():
		r["move_1_first_after_full_ms"] = snappedf(float(mv1[0]), 0.001)
		r["move_1_steady"] = stats(mv1.slice(1))
	r["move_20"] = stats(mv20)
	r["add_1"] = stats(add1)
	r["remove_1"] = stats(rem1)
	if renderer.has_method("depth_stats"):
		r["depth_stats"] = renderer.call("depth_stats")
		r["last_flush_kinds"] = kinds
	# Picking.
	var picks: Array = []
	var points: Array = []
	var side := map.size.x
	for i in reps * 5:
		var w := Iso.tile_center(Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))) + Vector2(rng.randf_range(-20, 20), rng.randf_range(-60, 10))
		points.append(w)
		t0 = Time.get_ticks_usec()
		renderer.pick(w)
		picks.append(_ms(t0))
	r["pick"] = stats(picks)
	# Same points again: alpha masks are built lazily on the first hit test of
	# a sprite, so this isolates the lookup cost from mask creation.
	var warm: Array = []
	for w: Vector2 in points:
		t0 = Time.get_ticks_usec()
		renderer.pick(w)
		warm.append(_ms(t0))
	r["pick_warm"] = stats(warm)
	if renderer.has_method("pick_any"):
		var anyp: Array = []
		for w: Vector2 in points:
			t0 = Time.get_ticks_usec()
			renderer.call("pick_any", w)
			anyp.append(_ms(t0))
		r["pick_any_warm"] = stats(anyp)
	renderer.queue_free()
	root.remove_child(renderer)
	renderer.free()
	return r


func _free_delta(l: FarmLayout, map: FarmMap, uids: Array, rng: RandomNumberGenerator, span: int) -> Vector2i:
	for k in 40:
		var d := Vector2i(rng.randi_range(-span, span), rng.randi_range(-span, span))
		if d == Vector2i.ZERO:
			continue
		if PlacementRules.check_group_move(l, map, uids, d).ok:
			return d
	return Vector2i.ZERO


func _move_one(l: FarmLayout, map: FarmMap, rng: RandomNumberGenerator, renderer: ObjectRenderer) -> float:
	for attempt in 30:
		var keys := l.objects.keys()
		var u: int = keys[rng.randi() % keys.size()]
		var d := _free_delta(l, map, [u], rng, 3)
		if d == Vector2i.ZERO:
			continue
		var t0 := Time.get_ticks_usec()
		l.move_objects([u], d, true)
		renderer.ensure_sorted()
		return _ms(t0)
	return -1.0


func _move_group(l: FarmLayout, map: FarmMap, rng: RandomNumberGenerator, renderer: ObjectRenderer, k: int) -> float:
	for attempt in 30:
		var keys := l.objects.keys()
		var seed_o := l.get_obj(keys[rng.randi() % keys.size()])
		# The k objects nearest to a random object (a typical marquee selection).
		var near: Array = []
		var r := 2
		while near.size() < k and r < 32:
			var seen := {}
			for y in range(seed_o.origin.y - r, seed_o.origin.y + r + 1):
				for x in range(seed_o.origin.x - r, seed_o.origin.x + r + 1):
					var o := l.object_at(Vector2i(x, y))
					if o:
						seen[o.uid] = true
			near = seen.keys()
			r += 1
		if near.size() < k:
			continue
		near.sort_custom(func(a: int, b: int) -> bool: return (l.get_obj(a).origin - seed_o.origin).length_squared() < (l.get_obj(b).origin - seed_o.origin).length_squared())
		near.resize(k)
		var d := _free_delta(l, map, near, rng, 2)
		if d == Vector2i.ZERO:
			continue
		var t0 := Time.get_ticks_usec()
		l.move_objects(near, d, true)
		renderer.ensure_sorted()
		return _ms(t0)
	return -1.0


func _add_one(l: FarmLayout, map: FarmMap, rng: RandomNumberGenerator, renderer: ObjectRenderer) -> float:
	var pools := _pools()
	var small: Array = pools[0]
	for attempt in 200:
		var it := db.get_item(small[rng.randi() % small.size()])
		var o := PlacedObject.new()
		o.item_id = it.id
		o.size = it.footprint
		o.origin = Vector2i(rng.randi_range(0, map.size.x - it.footprint.x), rng.randi_range(0, map.size.y - it.footprint.y))
		if not PlacementRules.check_rect(l, map, o.rect()).ok:
			continue
		var t0 := Time.get_ticks_usec()
		l.add_objects([o], true)
		renderer.ensure_sorted()
		return _ms(t0)
	return -1.0


func _remove_one(l: FarmLayout, rng: RandomNumberGenerator, renderer: ObjectRenderer) -> float:
	var keys := l.objects.keys()
	if keys.is_empty():
		return -1.0
	var u: int = keys[rng.randi() % keys.size()]
	var t0 := Time.get_ticks_usec()
	l.remove_objects([u], true)
	renderer.ensure_sorted()
	return _ms(t0)
