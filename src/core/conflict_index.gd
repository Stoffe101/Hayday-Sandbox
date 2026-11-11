class_name ConflictIndex
extends RefCounted
## Incremental PlacementRules.find_conflicts: which objects currently break the
## placement rules, kept up to date from layout signals instead of re-checking
## every object after every edit.
##
## Why this is enough: an object's verdict depends only on the tiles under it
## (the map, the unlocked land and whoever else stands there). So when something
## changes footprint, only objects sharing one of its old or new tiles can
## change verdict. Land and map changes affect everyone: full recheck.

var layout: FarmLayout
var map: FarmMap
var rechecks := 0                 ## objects re-checked so far (tests, diagnostics)
var full_rebuilds := 0

var _conflicts: Dictionary = {}   ## uid -> PlacementRules.Result
var _rects: Dictionary = {}       ## uid -> Rect2i the index last saw it at
var _dirty_uids: Dictionary = {}
var _dirty_rects: Array[Rect2i] = []
var _all_dirty := true
var _land_hash := 0
## Change log for incremental consumers (RealisticAnalyzer.Cached): uids whose
## verdict was re-checked or dropped, in order. Positions are absolute
## (log_end()); the oldest entries are trimmed, and a full rebuild bumps
## full_rebuilds, so a consumer that fell behind redoes everything.
var _log := PackedInt64Array()
var _log_start := 0
const LOG_MAX := 65536


func _init(l: FarmLayout, m: FarmMap) -> void:
	layout = l
	map = m
	l.objects_added.connect(_on_objects)
	l.objects_changed.connect(_on_objects)
	l.objects_removed.connect(_on_removed)
	l.land_changed.connect(invalidate_all)


func set_map(m: FarmMap) -> void:
	if map != m:
		map = m
		invalidate_all()


func invalidate_all() -> void:
	_all_dirty = true


func conflicts() -> Dictionary:
	## uid -> Result, as PlacementRules.find_conflicts would answer now. Shared:
	## callers must not modify it.
	_flush()
	return _conflicts


func log_end() -> int:
	## Position after the last change-log entry (call conflicts() first).
	return _log_start + _log.size()


func changed_since(pos: int) -> Variant:
	## Uids whose entry in conflicts() may differ from what it was when log_end()
	## returned `pos` (a uid can repeat), or null when that is no longer known
	## (trimmed): then compare everything. A full rebuild (full_rebuilds) is not
	## logged either. Call conflicts() first.
	if pos < _log_start or pos > log_end():
		return null
	return _log.slice(pos - _log_start)


func _logged(u: int) -> void:
	_log.append(u)
	if _log.size() > LOG_MAX:
		@warning_ignore("integer_division")
		var drop := LOG_MAX / 2
		_log = _log.slice(drop)
		_log_start += drop


# --- change tracking --------------------------------------------------------------------

func _on_objects(uids: Array) -> void:
	if _all_dirty:
		return
	for u in uids:
		var o: PlacedObject = layout.objects.get(u)
		if o == null:
			continue
		var r := o.rect()
		var had: Variant = _rects.get(u)
		if had == r:
			continue   # a property edit: same tiles, same verdict
		if had != null:
			_dirty_rects.append(had)
		_dirty_rects.append(r)
		_dirty_uids[u] = true
		_rects[u] = r


func _on_removed(uids: Array) -> void:
	if _all_dirty:
		return
	for u in uids:
		var had: Variant = _rects.get(u)
		if had != null:
			_dirty_rects.append(had)
			_rects.erase(u)
		if _conflicts.has(u):
			_logged(u)
		_conflicts.erase(u)
		_dirty_uids.erase(u)


func _flush() -> void:
	# Safety net for edits that didn't signal (`emit = false` mutations, land set
	# directly): the answer must never be stale.
	var land := [layout.unlocked_plots.hash(), layout.zone_items.hash()].hash()
	if land != _land_hash or layout.objects.size() != _rects.size():
		_all_dirty = true
	if _all_dirty or _dirty_uids.size() * 2 > layout.objects.size() + 16:
		_rebuild(land)
		return
	if _dirty_uids.is_empty() and _dirty_rects.is_empty():
		return
	var touched := _dirty_uids
	for r: Rect2i in _dirty_rects:
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				for u in layout.occupancy.all_at(Vector2i(x, y)):
					touched[u] = true
	for u in touched:
		var o: PlacedObject = layout.objects.get(u)
		if o != null:
			_recheck(o)
			_logged(u)
	_dirty_uids = {}
	_dirty_rects.clear()


func _rebuild(land: int) -> void:
	_conflicts.clear()
	_rects.clear()
	for o: PlacedObject in layout.objects.values():
		_rects[o.uid] = o.rect()
		_recheck(o)
	_dirty_uids = {}
	_dirty_rects.clear()
	_all_dirty = false
	_land_hash = land
	full_rebuilds += 1


func _recheck(o: PlacedObject) -> void:
	## Tile by tile without allocating a Result for the (common) valid object.
	rechecks += 1
	var ignore := {o.uid: true}
	var r := o.rect()
	var zone := layout.zone_items.has(o.item_id)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if PlacementRules.tile_code(layout, map, Vector2i(x, y), ignore, zone) != PlacementRules.OK_TILE:
				_conflicts[o.uid] = PlacementRules.check_rect(layout, map, r, ignore, true, zone)
				return
	_conflicts.erase(o.uid)
