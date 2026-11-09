class_name Connections
extends RefCounted
## Auto-connection (autotiling) for fences, hedges and paths.
##
## Connections are *derived* from the layout at render time, never stored, so
## they can't go stale. Only items sharing the same `connect_group` join, and
## an asset pack decides which of the 16 shapes it actually has art for —
## missing shapes degrade to the closest available one (see best_variant()).

const NE := 1   ## -y  (screen up-right)
const SE := 2   ## +x  (screen down-right)
const SW := 4   ## +y  (screen down-left)
const NW := 8   ## -x  (screen up-left)

const DIRS := {NE: Vector2i(0, -1), SE: Vector2i(1, 0), SW: Vector2i(0, 1), NW: Vector2i(-1, 0)}


static func mask_for(layout: FarmLayout, db: ItemDatabase, o: PlacedObject) -> int:
	var it := db.get_item(o.item_id)
	if it == null or it.connect_group.is_empty():
		return 0
	var mask := 0
	for bit in DIRS:
		if _edge_connected(layout, db, o, it.connect_group, bit):
			mask |= bit
	return mask


static func _edge_connected(layout: FarmLayout, db: ItemDatabase, o: PlacedObject, group: String, bit: int) -> bool:
	var r := o.rect()
	var tiles: Array[Vector2i] = []
	match bit:
		NE:
			for x in range(r.position.x, r.end.x): tiles.append(Vector2i(x, r.position.y - 1))
		SW:
			for x in range(r.position.x, r.end.x): tiles.append(Vector2i(x, r.end.y))
		NW:
			for y in range(r.position.y, r.end.y): tiles.append(Vector2i(r.position.x - 1, y))
		SE:
			for y in range(r.position.y, r.end.y): tiles.append(Vector2i(r.end.x, y))
	for t in tiles:
		var n := layout.object_at(t)
		if n and n.uid != o.uid:
			var nit := db.get_item(n.item_id)
			if nit and nit.connect_group == group:
				return true
	return false


static func neighbours_of_rects(layout: FarmLayout, rects: Array) -> Array:
	## uids of objects touching any of the rects' edges (they may need a new
	## connection shape after an edit).
	var seen := {}
	for r: Rect2i in rects:
		for x in range(r.position.x, r.end.x):
			_add(layout, Vector2i(x, r.position.y - 1), seen)
			_add(layout, Vector2i(x, r.end.y), seen)
		for y in range(r.position.y, r.end.y):
			_add(layout, Vector2i(r.position.x - 1, y), seen)
			_add(layout, Vector2i(r.end.x, y), seen)
	return seen.keys()


static func _add(layout: FarmLayout, t: Vector2i, seen: Dictionary) -> void:
	var u := layout.occupancy.at(t)
	if u != 0:
		seen[u] = true


static func best_variant(mask: int, available: Dictionary) -> int:
	## Picks the mask to render given which masks have art. Prefers the exact
	## shape, then shapes that drop connections (never invents connections),
	## then the isolated piece (0). Returns -1 when nothing is available.
	if available.has(mask):
		return mask
	var best := -1
	var best_bits := -1
	for m in available:
		if (m & mask) == m:
			var bits := _popcount(m)
			if bits > best_bits:
				best = m
				best_bits = bits
	return best


static func _popcount(v: int) -> int:
	var c := 0
	while v:
		c += v & 1
		v >>= 1
	return c


static func shape_name(mask: int) -> String:
	match _popcount(mask):
		0: return "isolated"
		1: return "end"
		2:
			if mask == (NE | SW) or mask == (SE | NW):
				return "straight"
			return "corner"
		3: return "t_junction"
		_: return "cross"
