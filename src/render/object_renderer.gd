class_name ObjectRenderer
extends Node2D
## Draws placed objects using lightweight RenderingServer canvas items (one per
## object + one per shadow) instead of Nodes. Godot culls each item by its
## rect, so camera movement costs no script time. Draw order is decided by
## DepthSorter and applied with canvas_item_set_draw_index — never by
## accidental scene-tree order.
##
## Layers (children, bottom to top): flat items (paths), shadows, upright objects.

signal order_rebuilt(ms: float)

const PLANNED_TINT := Color(0.72, 0.84, 1.0, 0.55)
const MISSING_TINT := Color(0.85, 0.85, 0.85, 0.9)

var layout: FarmLayout
var db: ItemDatabase
var assets: AssetLibrary
var show_shadows := true:
	set(v):
		show_shadows = v
		if _shadow_root:
			_shadow_root.visible = v

var _flat_root: Node2D
var _shadow_root: Node2D
var _obj_root: Node2D
var _vis: Dictionary = {}          ## uid -> Vis
var _order_dirty := false
var _order_index: Dictionary = {}  ## uid -> int (higher = in front)
var _spatial: Dictionary = {}      ## Vector2i cell -> Array[uid]
var _hidden: Dictionary = {}
var _tints: Dictionary = {}        ## uid -> Color
var last_sort_ms := 0.0

const CELL := 192.0


class Vis:
	var uid: int
	var ci: RID
	var sci: RID
	var sprite: AssetLibrary.SpriteInfo
	var bounds: Rect2
	var rect: Rect2i
	var flat := false
	var flipped := false
	var center: Vector2
	var fallback_poly: PackedVector2Array


func _ready() -> void:
	_flat_root = Node2D.new()
	_flat_root.name = "Flat"
	_shadow_root = Node2D.new()
	_shadow_root.name = "Shadows"
	_obj_root = Node2D.new()
	_obj_root.name = "Objects"
	add_child(_flat_root)
	add_child(_shadow_root)
	add_child(_obj_root)


func bind(l: FarmLayout, item_db: ItemDatabase, lib: AssetLibrary) -> void:
	if layout:
		layout.objects_added.disconnect(_on_added)
		layout.objects_removed.disconnect(_on_removed)
		layout.objects_changed.disconnect(_on_changed)
	layout = l
	db = item_db
	assets = lib
	layout.objects_added.connect(_on_added)
	layout.objects_removed.connect(_on_removed)
	layout.objects_changed.connect(_on_changed)
	rebuild_all()


func rebuild_all() -> void:
	for v: Vis in _vis.values():
		_free_vis(v)
	_vis.clear()
	_hidden.clear()
	if layout == null:
		return
	for o: PlacedObject in layout.objects.values():
		_create(o)
	_order_dirty = true


func _exit_tree() -> void:
	for v: Vis in _vis.values():
		_free_vis(v)
	_vis.clear()


func _free_vis(v: Vis) -> void:
	if v.ci.is_valid():
		RenderingServer.free_rid(v.ci)
	if v.sci.is_valid():
		RenderingServer.free_rid(v.sci)


func _create(o: PlacedObject) -> void:
	var v := Vis.new()
	v.uid = o.uid
	var it := db.get_item(o.item_id)
	v.flat = it != null and it.layer == "ground"
	v.ci = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(v.ci, (_flat_root if v.flat else _obj_root).get_canvas_item())
	_vis[o.uid] = v
	_draw_vis(v, o, it)


func _connection_mask(o: PlacedObject, it: ItemDef) -> int:
	if it == null or it.connect_group.is_empty():
		return -1
	return Connections.mask_for(layout, db, o)


func _draw_vis(v: Vis, o: PlacedObject, it: ItemDef) -> void:
	RenderingServer.canvas_item_clear(v.ci)
	v.rect = o.rect()
	v.flipped = o.flipped
	v.center = Iso.footprint_center(o.origin, o.size)
	var art_key := it.art_key if it else o.item_id
	v.sprite = null
	if it:
		v.sprite = assets.get_sprite(art_key, o.variant, _connection_mask(o, it))
	var xf := Transform2D(Vector2(-1.0 if o.flipped else 1.0, 0.0), Vector2(0.0, 1.0), v.center)
	RenderingServer.canvas_item_set_transform(v.ci, xf)
	if v.sprite:
		var sz := v.sprite.texture.get_size() * v.sprite.scale
		var r := Rect2(-v.sprite.anchor * v.sprite.scale, sz)
		RenderingServer.canvas_item_add_texture_rect(v.ci, r, v.sprite.texture.get_rid())
		v.bounds = v.sprite.world_rect(v.center, o.flipped)
		v.fallback_poly = PackedVector2Array()
	else:
		_draw_fallback(v, o, it)
	# Shadow
	if v.sprite and v.sprite.shadow and not v.flat:
		if not v.sci.is_valid():
			v.sci = RenderingServer.canvas_item_create()
			RenderingServer.canvas_item_set_parent(v.sci, _shadow_root.get_canvas_item())
		RenderingServer.canvas_item_clear(v.sci)
		RenderingServer.canvas_item_set_transform(v.sci, xf)
		var ss := v.sprite.shadow.get_size() * v.sprite.scale
		RenderingServer.canvas_item_add_texture_rect(v.sci, Rect2(-v.sprite.shadow_anchor * v.sprite.scale, ss), v.sprite.shadow.get_rid())
	elif v.sci.is_valid():
		RenderingServer.free_rid(v.sci)
		v.sci = RID()
	_apply_modulate(v, o)
	_order_dirty = true


func _draw_fallback(v: Vis, o: PlacedObject, it: ItemDef) -> void:
	## Vector stand-in when an item has no art (or its id is unknown): a
	## shaded block exactly the size of the footprint, with a "?" marker.
	var col: Color = db.category(it.category)["color"] if it else Color(0.6, 0.6, 0.6)
	var h := (0.4 + 0.25 * mini(o.size.x, o.size.y)) * Iso.Z_UNIT
	if it and it.layer == "ground":
		h = 3.0
	var local := Iso.footprint_polygon(o.origin, o.size)
	for i in local.size():
		local[i] -= v.center
		if o.flipped:
			local[i].x = -local[i].x
	var top := PackedVector2Array()
	for p in local:
		top.append(p - Vector2(0, h))
	var ci := v.ci
	var inset := 0.08
	var c := Vector2.ZERO
	for i in top.size():
		top[i] = top[i].lerp(c - Vector2(0, h), inset)
	var base := PackedVector2Array()
	for p in local:
		base.append(p.lerp(c, inset))
	# right face: right(1)-bottom(2), left face: bottom(2)-left(3)
	RenderingServer.canvas_item_add_polygon(ci, PackedVector2Array([base[1], base[2], top[2], top[1]]), PackedColorArray([col.darkened(0.35)]))
	RenderingServer.canvas_item_add_polygon(ci, PackedVector2Array([base[2], base[3], top[3], top[2]]), PackedColorArray([col.darkened(0.15)]))
	RenderingServer.canvas_item_add_polygon(ci, top, PackedColorArray([col.lightened(0.15)]))
	var outline := PackedVector2Array([top[0], top[1], top[2], top[3], top[0]])
	RenderingServer.canvas_item_add_polyline(ci, outline, PackedColorArray([col.darkened(0.55)]), 1.5, true)
	var font := ThemeDB.fallback_font
	var fs := int(clampf(10.0 + 6.0 * mini(o.size.x, o.size.y), 12, 40))
	var label := "?" if (it == null or o.missing) else ""
	if not label.is_empty():
		font.draw_string(ci, Vector2(-fs * 0.3, -h * 0.5 + fs * 0.35), label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(1, 1, 1, 0.95))
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in local + top:
		mn = mn.min(p)
		mx = mx.max(p)
	v.bounds = Rect2(mn + v.center, mx - mn)
	var poly := PackedVector2Array([base[0], base[1], base[2], base[3]])
	var hull := Geometry2D.convex_hull(local + top)
	v.fallback_poly = PackedVector2Array()
	for p in hull:
		v.fallback_poly.append(p + v.center)
	if poly.is_empty():
		pass


func _apply_modulate(v: Vis, o: PlacedObject) -> void:
	var m := Color.WHITE
	if o.planned:
		m = PLANNED_TINT
	elif o.missing:
		m = MISSING_TINT
	if _tints.has(o.uid):
		m *= _tints[o.uid]
	RenderingServer.canvas_item_set_modulate(v.ci, m)
	var visible := not _hidden.has(o.uid)
	RenderingServer.canvas_item_set_visible(v.ci, visible)
	if v.sci.is_valid():
		RenderingServer.canvas_item_set_visible(v.sci, visible and not o.planned)


func _on_added(uids: Array) -> void:
	var rects: Array = []
	for u in uids:
		var o := layout.get_obj(u)
		if o:
			_create(o)
			rects.append(o.rect())
	_refresh_neighbours(rects, uids)


func _on_removed(uids: Array) -> void:
	var rects: Array = []
	for u in uids:
		var v: Vis = _vis.get(u)
		if v:
			rects.append(v.rect)
			_free_vis(v)
			_vis.erase(u)
			_hidden.erase(u)
			_tints.erase(u)
	_order_dirty = true
	_refresh_neighbours(rects, [])


func _on_changed(uids: Array) -> void:
	var rects: Array = []
	for u in uids:
		var o := layout.get_obj(u)
		var v: Vis = _vis.get(u)
		if o == null or v == null:
			continue
		rects.append(v.rect)
		var it := db.get_item(o.item_id)
		var want_flat := it != null and it.layer == "ground"
		if want_flat != v.flat:
			v.flat = want_flat
			RenderingServer.canvas_item_set_parent(v.ci, (_flat_root if v.flat else _obj_root).get_canvas_item())
		_draw_vis(v, o, it)
		rects.append(o.rect())
	_refresh_neighbours(rects, uids)


func _refresh_neighbours(rects: Array, skip: Array) -> void:
	if rects.is_empty():
		return
	var skip_d := {}
	for u in skip:
		skip_d[u] = true
	for u in Connections.neighbours_of_rects(layout, rects):
		if skip_d.has(u):
			continue
		var o := layout.get_obj(u)
		var v: Vis = _vis.get(u)
		if o == null or v == null:
			continue
		var it := db.get_item(o.item_id)
		if it and not it.connect_group.is_empty():
			_draw_vis(v, o, it)


func refresh_all_art() -> void:
	## After asset packs change.
	if layout == null:
		return
	for u in _vis:
		var o := layout.get_obj(u)
		if o:
			_draw_vis(_vis[u], o, db.get_item(o.item_id))


func refresh_art(art_keys: Array) -> int:
	## After an override edit: redraw only objects using these art keys.
	## Returns how many objects were redrawn.
	if layout == null:
		return 0
	var ks := {}
	for k in art_keys:
		ks[str(k)] = true
	var n := 0
	for u in _vis:
		var o := layout.get_obj(u)
		if o == null:
			continue
		var it := db.get_item(o.item_id)
		if ks.has(it.art_key if it else o.item_id):
			_draw_vis(_vis[u], o, it)
			n += 1
	return n


func set_hidden(uids: Array) -> void:
	var old := _hidden.keys()
	_hidden.clear()
	for u in uids:
		_hidden[u] = true
	for u in old + uids:
		var v: Vis = _vis.get(u)
		var o := layout.get_obj(u) if layout else null
		if v and o:
			_apply_modulate(v, o)


func set_tints(tints: Dictionary) -> void:
	var touched := _tints.keys() + tints.keys()
	_tints = tints.duplicate()
	for u in touched:
		var v: Vis = _vis.get(u)
		var o := layout.get_obj(u) if layout else null
		if v and o:
			_apply_modulate(v, o)


func _process(_dt: float) -> void:
	if _order_dirty:
		ensure_sorted()


func ensure_sorted() -> void:
	if not _order_dirty:
		return
	_order_dirty = false
	var t0 := Time.get_ticks_usec()
	var entries: Array = []
	var flats: Array = []
	for v: Vis in _vis.values():
		if v.flat:
			flats.append(v)
		else:
			entries.append(DepthSorter.Entry.new(v.uid, v.rect, v.bounds))
	var order := DepthSorter.sort(entries)
	_order_index.clear()
	flats.sort_custom(func(a, b): return (a.rect.position.x + a.rect.position.y) < (b.rect.position.x + b.rect.position.y) or ((a.rect.position.x + a.rect.position.y) == (b.rect.position.x + b.rect.position.y) and a.uid < b.uid))
	for i in flats.size():
		RenderingServer.canvas_item_set_draw_index(flats[i].ci, i)
		_order_index[flats[i].uid] = i - 1000000
	for i in order.size():
		var v: Vis = _vis[order[i]]
		RenderingServer.canvas_item_set_draw_index(v.ci, i)
		_order_index[v.uid] = i
	_rebuild_spatial()
	last_sort_ms = (Time.get_ticks_usec() - t0) / 1000.0
	order_rebuilt.emit(last_sort_ms)


func _rebuild_spatial() -> void:
	_spatial.clear()
	for v: Vis in _vis.values():
		var b := v.bounds
		for cy in range(floori(b.position.y / CELL), floori(b.end.y / CELL) + 1):
			for cx in range(floori(b.position.x / CELL), floori(b.end.x / CELL) + 1):
				var k := Vector2i(cx, cy)
				if _spatial.has(k):
					_spatial[k].append(v.uid)
				else:
					_spatial[k] = [v.uid]


func pick(world_pos: Vector2, include_hidden: bool = false) -> int:
	## Top-most object whose *visible pixels* are under world_pos, falling
	## back to the footprint tile. Returns 0 when nothing is there.
	ensure_sorted()
	var k := Vector2i(floori(world_pos.x / CELL), floori(world_pos.y / CELL))
	var best := 0
	var best_idx := -INF
	for u in _spatial.get(k, []):
		if not include_hidden and _hidden.has(u):
			continue
		var v: Vis = _vis.get(u)
		if v == null or not v.bounds.has_point(world_pos):
			continue
		var hit := false
		if v.sprite:
			hit = v.sprite.hit(v.center, v.flipped, world_pos)
		elif not v.fallback_poly.is_empty():
			hit = Geometry2D.is_point_in_polygon(world_pos, v.fallback_poly)
		var idx: float = _order_index.get(u, 0)
		if hit and idx > best_idx:
			best = u
			best_idx = idx
	if best != 0:
		return best
	var o := layout.object_at(Iso.world_to_tile(world_pos)) if layout else null
	if o and (include_hidden or not _hidden.has(o.uid)):
		return o.uid
	return 0


func uids_in_world_rect(r: Rect2) -> Array:
	## Objects whose footprint centre lies inside a world-space rectangle.
	var out: Array = []
	for v: Vis in _vis.values():
		if r.has_point(v.center):
			out.append(v.uid)
	return out


func bounds_of(uid: int) -> Rect2:
	var v: Vis = _vis.get(uid)
	return v.bounds if v else Rect2()


func sprite_of(uid: int) -> AssetLibrary.SpriteInfo:
	var v: Vis = _vis.get(uid)
	return v.sprite if v else null


func order_of(uid: int) -> int:
	return _order_index.get(uid, 0)


func object_count() -> int:
	return _vis.size()
