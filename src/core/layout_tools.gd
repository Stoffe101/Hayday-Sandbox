class_name LayoutTools
extends RefCounted
## Pure geometry behind the editing tools: mirror lines, repeat arrays, align,
## distribute, brush shapes, and "what actually fits" filters. Knows nothing
## about the UI; EditorSession turns the results into Commands.
##
## Grid axes: X runs along the road, Y across it (see data/maps/hayday_farm.json
## origin_note), so "along" = x and "across" = y everywhere in this file.

## Mirror lines. A line is {"kind": <one of these>, "pos": int}.
##  * screen: the vertical line of the screen through the tiles with x - y = pos.
##    This is the game's own mirror: art flips and the footprint swaps W x H.
##  * across: a line across the road at x = pos / 2 (reflects along-road positions).
##  * along:  a line along the road at y = pos / 2 (reflects across-road positions).
##    `pos` is doubled so a line can run through tile centres (odd) or between
##    tiles (even).
const KIND_SCREEN := "screen"
const KIND_ALONG := "along"
const KIND_ACROSS := "across"
const KINDS := [KIND_SCREEN, KIND_ACROSS, KIND_ALONG]

const AXIS_ALONG := "along"
const AXIS_ACROSS := "across"
const ALIGN_OPS := ["left", "right", "center_along", "top", "bottom", "center_across"]

const MAX_REPEAT_AXIS := 50      ## columns or rows
const MAX_REPEAT_CELLS := 400    ## columns x rows (keeps previews responsive)


# --- mirror --------------------------------------------------------------------------

static func line_for_tile(kind: String, t: Vector2i) -> Dictionary:
	## The mirror line of `kind` through the centre of tile t.
	match kind:
		KIND_ALONG:
			return {"kind": KIND_ALONG, "pos": 2 * t.y + 1}
		KIND_ACROSS:
			return {"kind": KIND_ACROSS, "pos": 2 * t.x + 1}
	return {"kind": KIND_SCREEN, "pos": t.x - t.y}


static func mirror_rect(r: Rect2i, line: Dictionary) -> Rect2i:
	## The footprint reflected over the line (its own inverse).
	var pos := int(line.get("pos", 0))
	match str(line.get("kind", KIND_SCREEN)):
		KIND_ALONG:
			return Rect2i(r.position.x, pos - r.position.y - r.size.y, r.size.x, r.size.y)
		KIND_ACROSS:
			return Rect2i(pos - r.position.x - r.size.x, r.position.y, r.size.x, r.size.y)
	return Rect2i(r.position.y + pos, r.position.x - pos, r.size.y, r.size.x)


static func mirror_placement(r: Rect2i, flipped: bool, flippable: bool, line: Dictionary) -> Dictionary:
	## {"rect": Rect2i, "flipped": bool} for the mirrored copy of an object, or {}
	## when it can't be mirrored. The screen mirror is the game's rotate, so an
	## item the game can't rotate has no mirror unless its footprint is square.
	## Along / across lines keep the footprint orientation; only a square item
	## can be flipped there without changing the tiles it stands on.
	var square := r.size.x == r.size.y
	if str(line.get("kind", KIND_SCREEN)) == KIND_SCREEN:
		if not flippable and not square:
			return {}
		return {"rect": mirror_rect(r, line), "flipped": (not flipped) if flippable else flipped}
	return {"rect": mirror_rect(r, line), "flipped": (not flipped) if flippable and square else flipped}


static func mirror_mask(mask: int, line: Dictionary) -> int:
	## A connection mask (see Connections) as seen on the mirrored copy.
	if mask < 0:
		return mask
	var out := 0
	var kind := str(line.get("kind", KIND_SCREEN))
	for bit: int in [Connections.NE, Connections.SE, Connections.SW, Connections.NW]:
		if mask & bit:
			out |= _mirror_bit(bit, kind)
	return out


static func _mirror_bit(bit: int, kind: String) -> int:
	var d: Vector2i = Connections.DIRS[bit]
	match kind:
		KIND_ALONG:
			d = Vector2i(d.x, -d.y)
		KIND_ACROSS:
			d = Vector2i(-d.x, d.y)
		_:
			d = Vector2i(d.y, d.x)
	for b: int in Connections.DIRS:
		if Connections.DIRS[b] == d:
			return b
	return bit


static func line_segment(line: Dictionary, bounds: Rect2i) -> Array:
	## [from, to] in grid coordinates, clipped to `bounds` (for drawing the
	## line). [] when the line misses the bounds.
	var pos := int(line.get("pos", 0))
	var r := Rect2(bounds)
	match str(line.get("kind", KIND_SCREEN)):
		KIND_ALONG:
			var y := pos * 0.5
			return [Vector2(r.position.x, y), Vector2(r.end.x, y)] if y >= r.position.y and y <= r.end.y else []
		KIND_ACROSS:
			var x := pos * 0.5
			return [Vector2(x, r.position.y), Vector2(x, r.end.y)] if x >= r.position.x and x <= r.end.x else []
	# x - y = pos, in tile-centre space: the line is the same in corner space.
	var y0 := maxf(r.position.y, r.position.x - pos)
	var y1 := minf(r.end.y, r.end.x - pos)
	if y0 > y1:
		return []
	return [Vector2(y0 + pos, y0), Vector2(y1 + pos, y1)]


# --- repeat ----------------------------------------------------------------------------

static func repeat_offsets(bounds: Vector2i, cols: int, rows: int, spacing: Vector2i) -> Array:
	## Offsets of every copy in a cols x rows array of a group with the given
	## bounds; the original cell (0, 0) is not included. Rows grow across the
	## road, columns along it.
	var c := clampi(cols, 1, MAX_REPEAT_AXIS)
	var r := clampi(rows, 1, MAX_REPEAT_AXIS)
	if c * r > MAX_REPEAT_CELLS:
		r = maxi(1, MAX_REPEAT_CELLS / c)
	var step := Vector2i(maxi(1, bounds.x + spacing.x), maxi(1, bounds.y + spacing.y))
	var out: Array = []
	for j in r:
		for i in c:
			if i == 0 and j == 0:
				continue
			out.append(Vector2i(i * step.x, j * step.y))
	return out


# --- align / distribute ------------------------------------------------------------------

static func align_deltas(rects: Array, op: String) -> Array:
	## Per-rect moves aligning them to the group's own bounds. left / right /
	## center_along work on the along-road axis; top / bottom / center_across on
	## the across-road axis. Unknown ops move nothing.
	var out: Array = []
	out.resize(rects.size())
	out.fill(Vector2i.ZERO)
	if rects.is_empty() or not op in ALIGN_OPS:
		return out
	var along := op in ["left", "right", "center_along"]
	var lo := 2147483647
	var hi := -2147483648
	for r: Rect2i in rects:
		lo = mini(lo, _start(r, along))
		hi = maxi(hi, _end(r, along))
	for i in rects.size():
		var r: Rect2i = rects[i]
		var size := _end(r, along) - _start(r, along)
		var target := lo
		if op in ["right", "bottom"]:
			target = hi - size
		elif op in ["center_along", "center_across"]:
			target = floori((lo + hi - size) * 0.5)
		var d := target - _start(r, along)
		out[i] = Vector2i(d, 0) if along else Vector2i(0, d)
	return out


static func distribute_deltas(rects: Array, axis: String) -> Array:
	## Per-rect moves giving equal gaps along `axis`. The first and last rect
	## stay where they are; needs at least 3 rects and room for all of them.
	var out: Array = []
	out.resize(rects.size())
	out.fill(Vector2i.ZERO)
	var along := axis != AXIS_ACROSS
	if rects.size() < 3:
		return out
	var order: Array = []
	for i in rects.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var pa := _start(rects[a], along)
		var pb := _start(rects[b], along)
		return pa < pb if pa != pb else a < b)
	var first: Rect2i = rects[order[0]]
	var last: Rect2i = rects[order[order.size() - 1]]
	var used := 0
	for i: int in order:
		used += _end(rects[i], along) - _start(rects[i], along)
	var free := _end(last, along) - _start(first, along) - used
	if free < 0:
		return out
	var run := _start(first, along)
	var n := order.size() - 1
	for k in range(1, n):
		var cur: Rect2i = rects[order[k]]
		var prev: Rect2i = rects[order[k - 1]]
		run += _end(prev, along) - _start(prev, along)
		var target := run + floori(float(free) * k / n + 0.5)
		var d := target - _start(cur, along)
		out[order[k]] = Vector2i(d, 0) if along else Vector2i(0, d)
	return out


static func _start(r: Rect2i, along: bool) -> int:
	return r.position.x if along else r.position.y


static func _end(r: Rect2i, along: bool) -> int:
	return r.end.x if along else r.end.y


# --- brush shapes ------------------------------------------------------------------------

static func line_origins(a: Vector2i, b: Vector2i, size: Vector2i) -> Array:
	## Origins of a straight run from a towards b along the dominant grid axis,
	## stepping by the footprint so neighbours touch without overlapping.
	var d := b - a
	var step := Vector2i(maxi(1, size.x), maxi(1, size.y))
	var out: Array = []
	if absi(d.x) >= absi(d.y):
		var sx := 1 if d.x >= 0 else -1
		for i in range(absi(d.x) / step.x + 1):
			out.append(a + Vector2i(i * step.x * sx, 0))
	else:
		var sy := 1 if d.y >= 0 else -1
		for i in range(absi(d.y) / step.y + 1):
			out.append(a + Vector2i(0, i * step.y * sy))
	return out


static func outline_origins(a: Vector2i, b: Vector2i, size: Vector2i) -> Array:
	## Origins around the perimeter of the rectangle spanned by a and b
	## (each cell once; a one-cell-wide rectangle degenerates to a line).
	var step := Vector2i(maxi(1, size.x), maxi(1, size.y))
	var nx := absi(b.x - a.x) / step.x + 1
	var ny := absi(b.y - a.y) / step.y + 1
	var sx := 1 if b.x >= a.x else -1
	var sy := 1 if b.y >= a.y else -1
	var out: Array = []
	for j in ny:
		for i in nx:
			if i == 0 or i == nx - 1 or j == 0 or j == ny - 1:
				out.append(a + Vector2i(i * step.x * sx, j * step.y * sy))
	return out


static func connection_masks(layout: FarmLayout, db: ItemDatabase, group: String, rects: Array) -> Array:
	## For previews of a fence/path run: the connection mask of each planned
	## rect, counting the other planned rects and what already stands on the
	## farm. Same-group test as Connections.mask_for (masks are never stored).
	var planned := {}
	for r: Rect2i in rects:
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				planned[Occupancy.key(Vector2i(x, y))] = true
	var out: Array = []
	for r: Rect2i in rects:
		var mask := 0
		for bit: int in Connections.DIRS:
			for t: Vector2i in _edge_tiles(r, bit):
				if planned.has(Occupancy.key(t)) or _same_group_at(layout, db, group, t):
					mask |= bit
					break
		out.append(mask)
	return out


static func _edge_tiles(r: Rect2i, bit: int) -> Array:
	var out: Array = []
	match bit:
		Connections.NE:
			for x in range(r.position.x, r.end.x):
				out.append(Vector2i(x, r.position.y - 1))
		Connections.SW:
			for x in range(r.position.x, r.end.x):
				out.append(Vector2i(x, r.end.y))
		Connections.NW:
			for y in range(r.position.y, r.end.y):
				out.append(Vector2i(r.position.x - 1, y))
		Connections.SE:
			for y in range(r.position.y, r.end.y):
				out.append(Vector2i(r.end.x, y))
	return out


static func _same_group_at(layout: FarmLayout, db: ItemDatabase, group: String, t: Vector2i) -> bool:
	var n := layout.object_at(t)
	if n == null or db == null:
		return false
	var it := db.get_item(n.item_id)
	return it != null and it.connect_group == group


# --- what fits -----------------------------------------------------------------------------

static func zone_flags(layout: FarmLayout, objs: Array) -> Array:
	## Per PlacedObject: true for water decorations (fit_mask's `zones`).
	var out: Array = []
	for o: PlacedObject in objs:
		out.append(PlacementRules.is_zone_object(layout, o))
	return out


static func fit_mask(layout: FarmLayout, map: FarmMap, rects: Array, ignore: Dictionary = {}, zones: Array = []) -> Array:
	## In order, true for each rect the placement rules accept given everything
	## on the farm and every rect accepted before it. Refused rects claim nothing.
	## `zones`: true per rect of a water decoration (PlacementRules.tile_code).
	var taken := {}
	var out: Array = []
	for i in rects.size():
		var r: Rect2i = rects[i]
		var zone := i < zones.size() and bool(zones[i])
		var keys: Array = []
		var ok := true
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var t := Vector2i(x, y)
				var k := Occupancy.key(t)
				if taken.has(k) or PlacementRules.tile_code(layout, map, t, ignore, zone) != PlacementRules.OK_TILE:
					ok = false
					break
				keys.append(k)
			if not ok:
				break
		if ok:
			for k in keys:
				taken[k] = true
		out.append(ok)
	return out


static func resolve_moves(layout: FarmLayout, map: FarmMap, uids: Array, deltas: Array) -> Dictionary:
	## Which of several simultaneous moves are legal: {"uids": [...], "deltas":
	## [...], "skipped": n}. An object that can't reach its target stays put, and
	## then blocks the others like any object; repeats until stable.
	var active := {}
	for i in uids.size():
		var o := layout.get_obj(uids[i])
		if o != null and deltas[i] != Vector2i.ZERO:
			active[i] = true
	var total := active.size()
	while true:
		var ignore := {}
		for i: int in active:
			ignore[uids[i]] = true
		var rects: Array = []
		var indices: Array = []
		var zones: Array = []
		for i: int in active:
			var o := layout.get_obj(uids[i])
			rects.append(Rect2i(o.origin + (deltas[i] as Vector2i), o.size))
			indices.append(i)
			zones.append(PlacementRules.is_zone_object(layout, o))
		var mask := fit_mask(layout, map, rects, ignore, zones)
		var dropped := false
		for k in mask.size():
			if not mask[k]:
				active.erase(indices[k])
				dropped = true
		if not dropped:
			break
	var ok_uids: Array = []
	var ok_deltas: Array = []
	for i in uids.size():
		if active.has(i):
			ok_uids.append(uids[i])
			ok_deltas.append(deltas[i])
	return {"uids": ok_uids, "deltas": ok_deltas, "skipped": total - ok_uids.size()}
