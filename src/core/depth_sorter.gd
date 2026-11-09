class_name DepthSorter
extends RefCounted
## Deterministic painter's-order for isometric objects with rectangular
## footprints.
##
## A single sort key (e.g. footprint centre depth) is wrong for elongated or
## differently-sized neighbours: a 1x6 hedge beside a 1x1 lamp gets drawn in
## front of the lamp although the lamp stands in front of it. Instead we build
## "A must be drawn before B" edges between objects whose sprite bounds
## overlap on screen, decided by footprint separation along the grid axes, and
## topologically sort them (Kahn's algorithm) with the centre-depth order as a
## deterministic tie-breaker. For disjoint convex footprints and a fixed view
## direction such an order always exists (Guibas & Yao, 1980); if bad data ever
## produces a cycle, it is broken by depth order instead of failing.
##
## Edge model (shared by every function here): for each pair whose sprite
## bounds intersect (Rect2.intersects, borders excluded), a is drawn before b
## iff compare(a, b) < 0. compare() is antisymmetric and a pure function of the
## two entries, so an edit only changes the edges of the edited entries.
##
## * sort()            full sort (fast path: native base sort, owner-cell pair
##                     dedupe, CSR adjacency). Output is identical to
##                     sort_reference(), the original implementation kept for
##                     tests.
## * Order             incremental draw order (gapped integer labels used
##                     directly as draw indices, local relabelling, Pearce-Kelly
##                     2006 repair). Invariant while acyclic: every edge a->b has
##                     label(a) < label(b), so every pair of overlapping sprites
##                     is drawn in the same relative order as sort() draws it
##                     (pixel-identical: sprites with disjoint bounds share no
##                     pixel). Cycles (bad data only) and big batches fall back
##                     to a full sort.
## * KeyedOrder        incremental total order by an integer key (flat items).

const CELL := 256.0


class Entry:
	var uid: int
	var rect: Rect2i     ## footprint in tiles
	var bounds: Rect2    ## sprite bounds in world pixels
	var key: float       ## centre depth
	func _init(u: int, r: Rect2i, b: Rect2) -> void:
		uid = u
		rect = r
		bounds = b
		key = r.position.x + r.position.y + (r.size.x + r.size.y) * 0.5


static func compare(a: Entry, b: Entry) -> int:
	## -1: a drawn first, 1: b drawn first.
	var a_first := a.rect.end.x <= b.rect.position.x or a.rect.end.y <= b.rect.position.y
	var b_first := b.rect.end.x <= a.rect.position.x or b.rect.end.y <= a.rect.position.y
	if a_first and not b_first:
		return -1
	if b_first and not a_first:
		return 1
	return -1 if _base_less(a, b) else 1


static func before(a: Entry, b: Entry) -> bool:
	## True when a must be drawn before b (only meaningful if overlaps(a, b)).
	return compare(a, b) < 0


static func overlaps(a: Entry, b: Entry) -> bool:
	## The pair is constrained (an edge exists) iff the sprite bounds overlap.
	return a.bounds.intersects(b.bounds)


static func _base_less(a: Entry, b: Entry) -> bool:
	if a.key == b.key:
		# Lower on screen (larger y) at equal centre depth is never possible for
		# disjoint rects; fall back to x then uid for full determinism.
		if a.rect.position.x != b.rect.position.x:
			return a.rect.position.x < b.rect.position.x
		return a.uid < b.uid
	return a.key < b.key


static func sort(entries: Array) -> Array:
	## entries: Array[Entry]. Returns uids in back-to-front draw order.
	return sort_detailed(entries)["order"]


static func sort_detailed(entries: Array, want_edges: bool = false) -> Dictionary:
	## Like sort(), plus diagnostics:
	## {"order": Array uids, "cyclic": bool (a cycle had to be broken),
	##  "edges": int, "pairs_tested": int}; with want_edges also
	## "edge_src" / "edge_dst" (PackedInt64Array of uids, src drawn first).
	var n := entries.size()
	var res := {"order": [], "cyclic": false, "edges": 0, "pairs_tested": 0}
	if want_edges:
		res["edge_src"] = PackedInt64Array()
		res["edge_dst"] = PackedInt64Array()
	if n == 0:
		return res
	var base := _base_order(entries)
	# Geometry in packed arrays (exact copies of the float32 Rect2 values, so
	# the overlap test below is bit-identical to Rect2.intersects).
	var x0 := PackedFloat64Array()
	var y0 := PackedFloat64Array()
	var x1 := PackedFloat64Array()
	var y1 := PackedFloat64Array()
	var ex := PackedInt32Array()     # rect end.x
	var ey := PackedInt32Array()     # rect end.y
	var px := PackedInt32Array()     # rect position.x
	var py := PackedInt32Array()     # rect position.y
	x0.resize(n)
	y0.resize(n)
	x1.resize(n)
	y1.resize(n)
	ex.resize(n)
	ey.resize(n)
	px.resize(n)
	py.resize(n)
	var bminx := INF
	var bminy := INF
	var bmaxx := -INF
	var bmaxy := -INF
	for i in n:
		var e: Entry = base[i]
		var p := e.bounds.position
		var q := e.bounds.end
		x0[i] = p.x
		y0[i] = p.y
		x1[i] = q.x
		y1[i] = q.y
		px[i] = e.rect.position.x
		py[i] = e.rect.position.y
		ex[i] = e.rect.end.x
		ey[i] = e.rect.end.y
		bminx = minf(bminx, p.x)
		bminy = minf(bminy, p.y)
		bmaxx = maxf(bmaxx, q.x)
		bmaxy = maxf(bmaxy, q.y)
	# Uniform grid (CSR buckets). The cell grows when the extent is huge so the
	# bucket array stays O(n); correctness does not depend on the cell size.
	var cell := CELL
	var gx0 := floori(bminx / cell)
	var gy0 := floori(bminy / cell)
	var gw := floori(bmaxx / cell) - gx0 + 1
	var gh := floori(bmaxy / cell) - gy0 + 1
	while gw * gh > 16 * n + 4096:
		cell *= 2.0
		gx0 = floori(bminx / cell)
		gy0 = floori(bminy / cell)
		gw = floori(bmaxx / cell) - gx0 + 1
		gh = floori(bmaxy / cell) - gy0 + 1
	var cnt := PackedInt32Array()
	cnt.resize(gw * gh + 1)
	var cx0 := PackedInt32Array()
	var cx1 := PackedInt32Array()
	var cy0 := PackedInt32Array()
	var cy1 := PackedInt32Array()
	cx0.resize(n)
	cx1.resize(n)
	cy0.resize(n)
	cy1.resize(n)
	for i in n:
		var a := floori(x0[i] / cell) - gx0
		var b := floori(x1[i] / cell) - gx0
		var c := floori(y0[i] / cell) - gy0
		var d := floori(y1[i] / cell) - gy0
		cx0[i] = a
		cx1[i] = b
		cy0[i] = c
		cy1[i] = d
		for cy in range(c, d + 1):
			var row := cy * gw
			for cx in range(a, b + 1):
				cnt[row + cx + 1] += 1
	for k in range(1, cnt.size()):
		cnt[k] += cnt[k - 1]
	var fill := cnt.duplicate()
	var mem := PackedInt32Array()
	mem.resize(cnt[cnt.size() - 1])
	for i in n:
		for cy in range(cy0[i], cy1[i] + 1):
			var row := cy * gw
			for cx in range(cx0[i], cx1[i] + 1):
				var slot := row + cx
				mem[fill[slot]] = i
				fill[slot] += 1
	# Candidate pairs: each overlapping pair is handled exactly once, in the
	# cell holding the top-left corner of the two bounds' intersection.
	var es := PackedInt32Array()
	var ed := PackedInt32Array()
	var pairs := 0
	for c in gw * gh:
		var s := cnt[c]
		var t := cnt[c + 1]
		if t - s < 2:
			continue
		var ccx := c % gw
		var ccy := c / gw
		for p in range(s, t):
			var i := mem[p]
			var ix0 := x0[i]
			var ix1 := x1[i]
			var iy0 := y0[i]
			var iy1 := y1[i]
			for q in range(p + 1, t):
				var j := mem[q]
				pairs += 1
				if ix0 >= x1[j] or ix1 <= x0[j] or iy0 >= y1[j] or iy1 <= y0[j]:
					continue
				if floori(maxf(ix0, x0[j]) / cell) - gx0 != ccx or floori(maxf(iy0, y0[j]) / cell) - gy0 != ccy:
					continue
				# i < j in base order. compare(base[i], base[j]) < 0 unless only
				# j is separated in front... i.e. j strictly behind i.
				var i_first := ex[i] <= px[j] or ey[i] <= py[j]
				var j_first := ex[j] <= px[i] or ey[j] <= py[i]
				if j_first and not i_first:
					es.append(j)
					ed.append(i)
				else:
					es.append(i)
					ed.append(j)
	res["pairs_tested"] = pairs
	var m := es.size()
	res["edges"] = m
	if want_edges:
		var su := PackedInt64Array()
		var du := PackedInt64Array()
		su.resize(m)
		du.resize(m)
		for k in m:
			su[k] = (base[es[k]] as Entry).uid
			du[k] = (base[ed[k]] as Entry).uid
		res["edge_src"] = su
		res["edge_dst"] = du
	# CSR adjacency + in-degrees.
	var off := PackedInt32Array()
	off.resize(n + 1)
	var indeg := PackedInt32Array()
	indeg.resize(n)
	for k in m:
		off[es[k] + 1] += 1
		indeg[ed[k]] += 1
	for k in range(1, n + 1):
		off[k] += off[k - 1]
	var pos := off.duplicate()
	var adj := PackedInt32Array()
	adj.resize(m)
	for k in m:
		var a := es[k]
		adj[pos[a]] = ed[k]
		pos[a] += 1
	# Kahn's algorithm, always emitting the ready node with the smallest base
	# index (deterministic: the result depends only on the edge set). Same
	# result as a min-heap of all ready nodes, but cheaper: a scan pointer p
	# walks the base order and only nodes that become ready behind it (an edge
	# against the base order) go through the heap.
	var heap := PackedInt32Array()
	var emitted := PackedByteArray()
	emitted.resize(n)
	var order: Array = []
	order.resize(n)
	var done := 0
	var p := 0
	var scan := 0
	var cyclic := false
	while done < n:
		while p < n and (emitted[p] != 0 or indeg[p] != 0):
			p += 1
		var cur := -1
		while heap.size() > 0 and heap[0] < p:
			var c := _heap_pop(heap)
			if emitted[c] == 0:
				cur = c
				break
		if cur < 0 and p < n:
			cur = p
			p += 1
		if cur < 0:
			# Cycle (only possible with overlapping/bad data): force the
			# shallowest remaining object out.
			cyclic = true
			while scan < n and emitted[scan] != 0:
				scan += 1
			cur = scan
		emitted[cur] = 1
		order[done] = (base[cur] as Entry).uid
		done += 1
		for k in range(off[cur], off[cur + 1]):
			var j := adj[k]
			indeg[j] -= 1
			if indeg[j] == 0 and emitted[j] == 0 and j < p:
				_heap_push(heap, j)
	res["order"] = order
	res["cyclic"] = cyclic
	return res


static func _base_order(entries: Array) -> Array:
	## entries sorted by _base_less, using native PackedInt64Array sorts:
	## key = (2*depth, x, rank of uid) packed into one int.
	var n := entries.size()
	var lim := 1 << 20
	var fits := n < (1 << 21)
	if fits:
		var by_uid := PackedInt64Array()
		by_uid.resize(n)
		for i in n:
			var e: Entry = entries[i]
			if e.uid <= -(1 << 41) or e.uid >= (1 << 41):
				fits = false
				break
			by_uid[i] = ((e.uid + (1 << 41)) << 21) | i
		if fits:
			by_uid.sort()
			var rank := PackedInt32Array()
			rank.resize(n)
			for r in n:
				rank[by_uid[r] & 0x1FFFFF] = r
			var comp := PackedInt64Array()
			comp.resize(n)
			var idx_of_rank := PackedInt32Array()
			idx_of_rank.resize(n)
			for i in n:
				var e: Entry = entries[i]
				var k2 := int(e.key * 2.0)
				var x := e.rect.position.x
				if k2 < -lim or k2 >= lim or x < -lim or x >= lim or float(k2) != e.key * 2.0:
					fits = false
					break
				comp[i] = ((k2 + lim) << 42) | ((x + lim) << 21) | rank[i]
				idx_of_rank[rank[i]] = i
			if fits:
				comp.sort()
				var out: Array = []
				out.resize(n)
				for p in n:
					out[p] = entries[idx_of_rank[comp[p] & 0x1FFFFF]]
				return out
	var base: Array = entries.duplicate()
	base.sort_custom(_base_less)
	return base


static func sort_reference(entries: Array) -> Array:
	## The original (slow, straightforward) implementation; tests check that
	## sort() returns exactly the same order.
	var n := entries.size()
	if n == 0:
		return []
	var base: Array = entries.duplicate()
	base.sort_custom(_base_less)
	# Spatial hash on sprite bounds to find overlapping pairs cheaply.
	var grid := {}
	for i in n:
		var b: Rect2 = base[i].bounds
		var x0 := floori(b.position.x / CELL)
		var y0 := floori(b.position.y / CELL)
		var x1 := floori(b.end.x / CELL)
		var y1 := floori(b.end.y / CELL)
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				var k := Vector2i(cx, cy)
				if grid.has(k):
					grid[k].append(i)
				else:
					grid[k] = [i]
	var out_edges: Array = []
	out_edges.resize(n)
	for i in n:
		out_edges[i] = PackedInt32Array()
	var indeg := PackedInt32Array()
	indeg.resize(n)
	var seen := {}
	for k in grid:
		var cell: Array = grid[k]
		var m := cell.size()
		for p in m:
			var i: int = cell[p]
			for q in range(p + 1, m):
				var j: int = cell[q]
				var lo := mini(i, j)
				var hi := maxi(i, j)
				var pk := lo * n + hi
				if seen.has(pk):
					continue
				seen[pk] = true
				var ei: Entry = base[lo]
				var ej: Entry = base[hi]
				if not ei.bounds.intersects(ej.bounds):
					continue
				if compare(ei, ej) < 0:
					out_edges[lo].append(hi)
					indeg[hi] += 1
				else:
					out_edges[hi].append(lo)
					indeg[lo] += 1
	# Kahn's algorithm with a min-heap on base index (deterministic).
	var heap := PackedInt32Array()
	for i in n:
		if indeg[i] == 0:
			_heap_push(heap, i)
	var emitted := PackedByteArray()
	emitted.resize(n)
	var order: Array = []
	var scan := 0
	while order.size() < n:
		var cur := -1
		while heap.size() > 0:
			var c := _heap_pop(heap)
			if emitted[c] == 0:
				cur = c
				break
		if cur < 0:
			while scan < n and emitted[scan] != 0:
				scan += 1
			cur = scan
		emitted[cur] = 1
		order.append(base[cur].uid)
		for j in out_edges[cur]:
			indeg[j] -= 1
			if indeg[j] == 0 and emitted[j] == 0:
				_heap_push(heap, j)
	return order


static func _heap_push(h: PackedInt32Array, v: int) -> void:
	h.append(v)
	var i := h.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if h[p] <= h[i]:
			break
		var t := h[p]
		h[p] = h[i]
		h[i] = t
		i = p


static func _heap_pop(h: PackedInt32Array) -> int:
	var top := h[0]
	var last := h[h.size() - 1]
	h.resize(h.size() - 1)
	if h.size() > 0:
		h[0] = last
		var i := 0
		var n := h.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var s := i
			if l < n and h[l] < h[s]:
				s = l
			if r < n and h[r] < h[s]:
				s = r
			if s == i:
				break
			var t := h[s]
			h[s] = h[i]
			h[i] = t
			i = s
	return top


# --- incremental orders ---------------------------------------------------------------


class LabelSeq:
	## A sequence of ids with strictly increasing integer labels (gapped), so an
	## id can be inserted between two neighbours without touching the others.
	## When a gap is used up, the smallest window around it whose labels can be
	## spread at MIN_SPACING is relabelled (order-maintenance list labelling);
	## a global renumber only happens when labels approach the int32 limit.
	## Labels are used directly as canvas-item draw indices (unique, int32).
	extends RefCounted
	const GAP := 64
	const MIN_SPACING := 8
	const LIMIT := 1 << 30
	var lab := PackedInt64Array()   ## ascending labels
	var ids := PackedInt64Array()   ## ids[i] carries label lab[i]
	var label := {}                 ## id -> label
	var changed := {}               ## id -> true: label changed since take_changed()
	var relabels := 0
	var relabeled_nodes := 0
	var renumbers := 0

	func clear() -> void:
		lab = PackedInt64Array()
		ids = PackedInt64Array()
		label.clear()
		changed.clear()

	func size() -> int:
		return lab.size()

	func has(id: int) -> bool:
		return label.has(id)

	func assign(order: Array) -> void:
		## Replace everything: labels GAP, 2*GAP, ... in this order.
		var n := order.size()
		lab = PackedInt64Array()
		ids = PackedInt64Array()
		lab.resize(n)
		ids.resize(n)
		label.clear()
		changed.clear()
		for i in n:
			var id: int = order[i]
			var l := (i + 1) * GAP
			lab[i] = l
			ids[i] = id
			label[id] = l
			changed[id] = true

	func position_of(id: int) -> int:
		return lab.bsearch(int(label[id]))

	func insert_at(p: int, id: int) -> void:
		## Insert `id` so that it sits between positions p-1 and p.
		var n := lab.size()
		var l := 0
		if n == 0:
			l = 0
		elif p <= 0:
			l = lab[0] - GAP
		elif p >= n:
			l = lab[n - 1] + GAP
		else:
			if lab[p] - lab[p - 1] < 2:
				_make_room(p)
			l = (lab[p - 1] + lab[p]) / 2
		lab.insert(p, l)
		ids.insert(p, id)
		label[id] = l
		changed[id] = true
		if l <= -LIMIT or l >= LIMIT:
			renumber()

	func remove(id: int) -> void:
		if not label.has(id):
			return
		var p := lab.bsearch(int(label[id]))
		lab.remove_at(p)
		ids.remove_at(p)
		label.erase(id)
		changed.erase(id)

	func _make_room(p: int) -> void:
		## Spread the smallest window around the p-1/p boundary whose labels can
		## be re-spaced at >= MIN_SPACING (the ends of the list are open).
		var n := lab.size()
		var half := 1
		while true:
			var a := maxi(0, p - half)
			var b := mini(n - 1, p + half - 1)
			var cnt := b - a + 1
			var lo: int = lab[a - 1] if a > 0 else lab[a] - GAP * (cnt + 1)
			var hi: int = lab[b + 1] if b < n - 1 else lab[b] + GAP * (cnt + 1)
			var step := (hi - lo) / (cnt + 1)
			if step >= MIN_SPACING:
				for i in cnt:
					var nl := lo + (i + 1) * step
					if lab[a + i] != nl:
						lab[a + i] = nl
						label[ids[a + i]] = nl
						changed[ids[a + i]] = true
				relabels += 1
				relabeled_nodes += cnt
				if lab[0] <= -LIMIT or lab[n - 1] >= LIMIT:
					renumber()
				return
			half *= 2

	func renumber() -> void:
		renumbers += 1
		for i in lab.size():
			var l := (i + 1) * GAP
			lab[i] = l
			label[ids[i]] = l
			changed[ids[i]] = true

	func reassign(seq: Array, pool: Array) -> void:
		## Give seq[i] the label pool[i] (pool = the same set of labels these ids
		## hold now, ascending). Used by Pearce-Kelly.
		for i in seq.size():
			var w: int = seq[i]
			var l: int = pool[i]
			label[w] = l
			ids[lab.bsearch(l)] = w
			changed[w] = true

	func take_changed() -> Array:
		var out := changed.keys()
		changed.clear()
		return out

	func order() -> Array:
		return Array(ids)


class Order:
	## Incremental painter's order over DepthSorter's edge model (see the
	## script doc). New neighbours are found through a bounds grid; edges are
	## kept as per-node successor / predecessor lists (built lazily from the
	## full sort's edges on the first edit after a rebuild) so Pearce-Kelly
	## searches never re-scan the grid.
	##
	## apply(removed, upserts) is O(affected neighbourhood) per entry:
	##  * remove: drop the entry (an order stays valid when edges disappear);
	##  * add: put it in a free label between its last predecessor and first
	##    successor; if a predecessor sits after a successor, place it after
	##    its predecessors and repair each violated edge with Pearce-Kelly;
	##  * move / resize / flip / art change = remove + add.
	## A full sort (rebuild) is used for: big batches (estimated incremental
	## cost >= last full sort), cycles (PK found one, or the last full sort had
	## to break one: every edit then re-sorts until the cycle is gone), and a
	## failed local invariant check after a Pearce-Kelly repair (every edge of
	## every relabelled entry must be in order; a safety net, never seen).
	extends RefCounted
	const GRID_CELL := 256.0
	var seq := LabelSeq.new()
	var entries := {}               ## id -> Entry
	var grid := {}                  ## cell key -> Array[int] ids
	var succ := {}                  ## id -> Array[int] (drawn after id)   valid when _adj_ready
	var pred := {}                  ## id -> Array[int] (drawn before id)  valid when _adj_ready
	var _adj_ready := false
	var _edge_src := PackedInt64Array()
	var _edge_dst := PackedInt64Array()
	var cyclic := false             ## the last full sort had to break a cycle
	var last_kind := ""             ## "full" | "incremental" (last apply/rebuild)
	var last_full_ms := 1.0
	var avg_entry_ms := 0.2         ## EMA of incremental cost per touched entry
	## Batches larger than this always rebuild (-1 = decide by estimated cost).
	var max_incremental := -1
	## Batches at or below this size never rebuild for cost reasons.
	var min_rebuild := 8
	var stats := {"rebuilds": 0, "incremental": 0, "fallback_batch": 0, "fallback_cycle": 0,
		"fallback_cyclic_graph": 0, "fallback_invariant": 0, "direct": 0, "conflicts": 0,
		"pk_calls": 0, "pk_moved": 0}

	func size() -> int:
		return entries.size()

	func has(id: int) -> bool:
		return entries.has(id)

	func entry(id: int) -> Entry:
		return entries.get(id)

	func index_of(id: int) -> int:
		return int(seq.label.get(id, 0))

	func order() -> Array:
		return seq.order()

	func take_changed() -> Array:
		return seq.take_changed()

	func rebuild(list: Array) -> void:
		var t0 := Time.get_ticks_usec()
		entries.clear()
		grid.clear()
		for e: Entry in list:
			entries[e.uid] = e
			_grid_add(e)
		var r := DepthSorter.sort_detailed(list if list.size() == entries.size() else entries.values(), true)
		cyclic = r["cyclic"]
		seq.assign(r["order"])
		_edge_src = r["edge_src"]
		_edge_dst = r["edge_dst"]
		_adj_ready = false
		succ.clear()
		pred.clear()
		last_kind = "full"
		stats["rebuilds"] += 1
		last_full_ms = maxf(0.05, (Time.get_ticks_usec() - t0) / 1000.0)

	func apply(removed: Array, upserts: Array) -> bool:
		## removed: ids to drop; upserts: Entries to add or replace (same uid).
		## Returns true when handled incrementally, false when it re-sorted.
		var k := removed.size() + upserts.size()
		if k == 0:
			return true
		var too_big := false
		if max_incremental >= 0:
			too_big = k > max_incremental
		else:
			too_big = k > min_rebuild and k * avg_entry_ms >= last_full_ms
		if too_big or cyclic:
			stats["fallback_cyclic_graph" if cyclic else "fallback_batch"] += 1
			_rebuild_with(removed, upserts, 0)
			return false
		_ensure_adj()
		var t0 := Time.get_ticks_usec()
		for id in removed:
			_remove(id)
		for e: Entry in upserts:
			_remove(e.uid)
		for i in upserts.size():
			var res := _add(upserts[i])
			if res != "":
				stats["fallback_" + res] += 1
				_rebuild_with([], upserts, i + 1)
				return false
		stats["incremental"] += 1
		last_kind = "incremental"
		var per := (Time.get_ticks_usec() - t0) / 1000.0 / k
		avg_entry_ms = avg_entry_ms * 0.8 + per * 0.2
		return true

	func _rebuild_with(removed: Array, upserts: Array, from: int) -> void:
		for id in removed:
			entries.erase(id)
		for i in range(from, upserts.size()):
			var e: Entry = upserts[i]
			entries[e.uid] = e
		rebuild(entries.values())

	# --- grid ---------------------------------------------------------------------

	## Grid cells are keyed by cx * 2^24 + cy (|cy| < 2^23 cells).

	func _grid_add(e: Entry) -> void:
		var b := e.bounds
		var y0 := floori(b.position.y / GRID_CELL)
		var y1 := floori(b.end.y / GRID_CELL)
		for cx in range(floori(b.position.x / GRID_CELL), floori(b.end.x / GRID_CELL) + 1):
			for cy in range(y0, y1 + 1):
				var k := cx * 16777216 + cy
				var a: Variant = grid.get(k)
				if a == null:
					grid[k] = [e.uid]
				else:
					(a as Array).append(e.uid)

	func _grid_remove(e: Entry) -> void:
		var b := e.bounds
		var y0 := floori(b.position.y / GRID_CELL)
		var y1 := floori(b.end.y / GRID_CELL)
		for cx in range(floori(b.position.x / GRID_CELL), floori(b.end.x / GRID_CELL) + 1):
			for cy in range(y0, y1 + 1):
				var k := cx * 16777216 + cy
				var a: Variant = grid.get(k)
				if a != null:
					(a as Array).erase(e.uid)
					if (a as Array).is_empty():
						grid.erase(k)

	func neighbours(e: Entry) -> Array:
		## ids whose bounds overlap e's (e itself excluded).
		var out: Array = []
		var b := e.bounds
		var y0 := floori(b.position.y / GRID_CELL)
		var y1 := floori(b.end.y / GRID_CELL)
		var x0 := floori(b.position.x / GRID_CELL)
		var x1 := floori(b.end.x / GRID_CELL)
		var multi := x1 > x0 or y1 > y0
		var seen := {}
		for cx in range(x0, x1 + 1):
			for cy in range(y0, y1 + 1):
				var a: Variant = grid.get(cx * 16777216 + cy)
				if a == null:
					continue
				for u: int in a:
					if u == e.uid:
						continue
					if multi:
						if seen.has(u):
							continue
						seen[u] = true
					if (entries[u] as Entry).bounds.intersects(b):
						out.append(u)
		return out

	func _ensure_adj() -> void:
		if _adj_ready:
			return
		succ.clear()
		pred.clear()
		for id: int in entries:
			succ[id] = []
			pred[id] = []
		for k in _edge_src.size():
			var a := _edge_src[k]
			var b := _edge_dst[k]
			(succ[a] as Array).append(b)
			(pred[b] as Array).append(a)
		_edge_src = PackedInt64Array()
		_edge_dst = PackedInt64Array()
		_adj_ready = true

	# --- edits --------------------------------------------------------------------

	func _remove(id: int) -> void:
		var e: Entry = entries.get(id)
		if e == null:
			return
		_grid_remove(e)
		entries.erase(id)
		seq.remove(id)
		for s: int in succ[id]:
			(pred[s] as Array).erase(id)
		for p: int in pred[id]:
			(succ[p] as Array).erase(id)
		succ.erase(id)
		pred.erase(id)

	func _add(e: Entry) -> String:
		## "" on success, else the fallback reason ("cycle" / "invariant").
		var id := e.uid
		var lab := seq.label
		var lo := -(1 << 62)
		var lo_id := 0
		var has_lo := false
		var hi := 1 << 62
		var hi_id := 0
		var has_hi := false
		var succs: Array = []
		var preds: Array = []
		for n: int in neighbours(e):
			var l: int = lab[n]
			if DepthSorter.compare(e, entries[n]) < 0:
				succs.append(n)
				(pred[n] as Array).append(id)
				if l < hi:
					hi = l
					hi_id = n
					has_hi = true
			else:
				preds.append(n)
				(succ[n] as Array).append(id)
				if l > lo:
					lo = l
					lo_id = n
					has_lo = true
		entries[id] = e
		succ[id] = succs
		pred[id] = preds
		_grid_add(e)
		if not has_lo and not has_hi:
			seq.insert_at(seq.size(), id)
			stats["direct"] += 1
			return ""
		if lo < hi:
			if has_lo:
				seq.insert_at(seq.position_of(lo_id) + 1, id)
			else:
				seq.insert_at(seq.position_of(hi_id), id)
			stats["direct"] += 1
			return ""
		# A predecessor sits after a successor: go after the predecessors, then
		# repair every violated id -> s edge (Pearce-Kelly, one edge at a time).
		stats["conflicts"] += 1
		seq.insert_at(seq.position_of(lo_id) + 1, id)
		var moved: Array = [id]
		for s: int in succs:
			if int(lab[s]) < int(lab[id]):
				var r := _pk(id, s, moved)
				if r != "":
					return r
		return "" if _locally_ordered(moved) else "invariant"

	func _locally_ordered(ids: Array) -> bool:
		## Every edge touching these entries is in label order.
		var lab := seq.label
		for w: int in ids:
			var lw: int = lab[w]
			for s: int in succ[w]:
				if lw >= int(lab[s]):
					return false
			for p: int in pred[w]:
				if int(lab[p]) >= lw:
					return false
		return true

	func _pk(x: int, y: int, moved: Array) -> String:
		## Edge x -> y with label(x) > label(y): reorder the affected window.
		stats["pk_calls"] += 1
		var lab := seq.label
		var lb: int = lab[y]
		var ub: int = lab[x]
		var df := {}
		var stack: Array = [y]
		while not stack.is_empty():
			var w: int = stack.pop_back()
			if df.has(w):
				continue
			df[w] = true
			for s: int in succ[w]:
				if s == x:
					return "cycle"
				if not df.has(s) and int(lab[s]) < ub:
					stack.append(s)
		var db := {}
		stack = [x]
		while not stack.is_empty():
			var w: int = stack.pop_back()
			if db.has(w):
				continue
			if df.has(w):
				return "cycle"
			db[w] = true
			for p: int in pred[w]:
				if not db.has(p) and int(lab[p]) > lb:
					stack.append(p)
		var fl: Array = df.keys()
		var bl: Array = db.keys()
		fl.sort_custom(func(a: int, c: int) -> bool: return lab[a] < lab[c])
		bl.sort_custom(func(a: int, c: int) -> bool: return lab[a] < lab[c])
		var pool: Array = []
		for w: int in fl:
			pool.append(lab[w])
		for w: int in bl:
			pool.append(lab[w])
		pool.sort()
		seq.reassign(bl + fl, pool)
		moved.append_array(bl)
		moved.append_array(fl)
		stats["pk_moved"] += pool.size()
		return ""

	# --- verification (tests / debug) --------------------------------------------

	func violations() -> int:
		## Stored edges whose order is violated. 0 whenever `cyclic` is false.
		_ensure_adj()
		var bad := 0
		for id: int in succ:
			var l: int = seq.label[id]
			for n: int in succ[id]:
				if l >= int(seq.label[n]):
					bad += 1
		return bad

	func edge_count() -> int:
		## Stored edges (tests compare this with a brute-force pair count).
		_ensure_adj()
		var c := 0
		for id: int in succ:
			c += (succ[id] as Array).size()
		return c

	func adjacency_errors() -> int:
		## Stored edges that disagree with compare() on the current entries
		## (direction or existence), or pred/succ lists out of sync. Tests only.
		_ensure_adj()
		var bad := 0
		for id: int in entries:
			var e: Entry = entries[id]
			var s_set := {}
			for n: int in neighbours(e):
				if DepthSorter.compare(e, entries[n]) < 0:
					s_set[n] = true
			if s_set.size() != (succ[id] as Array).size():
				bad += 1
				continue
			for n: int in succ[id]:
				if not s_set.has(n) or not (pred[n] as Array).has(id):
					bad += 1
		return bad


class KeyedOrder:
	## Incremental total order by an int64 key (ties impossible: callers fold the
	## id into the key). Used for flat items: (x + y, uid).
	extends RefCounted
	var seq := LabelSeq.new()
	var keys := PackedInt64Array()    ## parallel to seq.lab
	var key_of := {}                  ## id -> key

	static func flat_key(r: Rect2i, uid: int) -> int:
		return ((r.position.x + r.position.y + (1 << 28)) << 34) | (uid + (1 << 33))

	func size() -> int:
		return key_of.size()

	func has(id: int) -> bool:
		return key_of.has(id)

	func index_of(id: int) -> int:
		return int(seq.label.get(id, 0))

	func rebuild(items: Array) -> void:
		## items: Array of [id, key].
		key_of.clear()
		var ks := PackedInt64Array()
		var by_key := {}
		for it: Array in items:
			key_of[it[0]] = it[1]
			ks.append(it[1])
			by_key[it[1]] = it[0]
		ks.sort()
		keys = ks
		var ord: Array = []
		for k in ks:
			ord.append(by_key[k])
		seq.assign(ord)

	func upsert(id: int, key: int) -> void:
		if key_of.has(id):
			if key_of[id] == key:
				return
			remove(id)
		var p := keys.bsearch(key)
		keys.insert(p, key)
		seq.insert_at(p, id)
		key_of[id] = key

	func remove(id: int) -> void:
		if not key_of.has(id):
			return
		var p := keys.bsearch(int(key_of[id]))
		keys.remove_at(p)
		seq.remove(id)
		key_of.erase(id)

	func order() -> Array:
		return seq.order()

	func take_changed() -> Array:
		return seq.take_changed()
