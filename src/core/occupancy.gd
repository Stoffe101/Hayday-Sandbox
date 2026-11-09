class_name Occupancy
extends RefCounted
## Tile -> object index. Normally one object per tile; if a loaded layout has
## overlaps (e.g. an item's footprint grew in newer metadata) the tile keeps
## every uid so nothing is silently lost and conflicts can be reported.

var _cells: Dictionary = {}   ## key(int) -> int uid, or Array[int] when stacked


static func key(t: Vector2i) -> int:
	return (t.y + 32768) * 65536 + (t.x + 32768)


static func unkey(k: int) -> Vector2i:
	return Vector2i(k % 65536 - 32768, k / 65536 - 32768)


func clear() -> void:
	_cells.clear()


func add_rect(uid: int, r: Rect2i) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var k := key(Vector2i(x, y))
			var cur: Variant = _cells.get(k)
			if cur == null:
				_cells[k] = uid
			elif cur is int:
				if cur != uid:
					_cells[k] = [cur, uid]
			elif not uid in cur:
				(cur as Array).append(uid)


func remove_rect(uid: int, r: Rect2i) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var k := key(Vector2i(x, y))
			var cur: Variant = _cells.get(k)
			if cur == null:
				continue
			if cur is int:
				if cur == uid:
					_cells.erase(k)
			else:
				(cur as Array).erase(uid)
				if cur.size() == 1:
					_cells[k] = cur[0]
				elif cur.is_empty():
					_cells.erase(k)


func at(t: Vector2i) -> int:
	## Top-most uid at tile, or 0.
	var cur: Variant = _cells.get(key(t))
	if cur == null:
		return 0
	if cur is int:
		return cur
	return cur[cur.size() - 1]


func all_at(t: Vector2i) -> Array:
	var cur: Variant = _cells.get(key(t))
	if cur == null:
		return []
	if cur is int:
		return [cur]
	return (cur as Array).duplicate()


func is_free(t: Vector2i, ignore: Dictionary = {}) -> bool:
	var cur: Variant = _cells.get(key(t))
	if cur == null:
		return true
	if cur is int:
		return ignore.has(cur)
	for u in cur:
		if not ignore.has(u):
			return false
	return true


func blockers(t: Vector2i, ignore: Dictionary = {}) -> Array:
	var out: Array = []
	for u in all_at(t):
		if not ignore.has(u):
			out.append(u)
	return out


func stacked_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in _cells:
		if _cells[k] is Array:
			out.append(unkey(k))
	return out


func occupied_count() -> int:
	return _cells.size()
