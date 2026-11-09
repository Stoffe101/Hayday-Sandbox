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
			# Cycle (only possible with overlapping/bad data): force the
			# shallowest remaining object out.
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
