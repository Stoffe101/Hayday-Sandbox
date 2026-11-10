class_name ObjectRenderer
extends Node2D
## Draws placed objects and world entries (fixed landmarks, ...) using
## lightweight RenderingServer canvas items (one per object + one per shadow)
## instead of Nodes. Godot culls each item by its rect, so camera movement
## costs no script time. Draw order is decided by DepthSorter and applied with
## canvas_item_set_draw_index — never by accidental scene-tree order.
##
## Layers (children, bottom to top): flat items (paths), shadows, upright
## objects + world entries.
##
## Draw order is maintained incrementally: every add / remove / change only
## re-sorts the edited items against their on-screen neighbours
## (DepthSorter.Order: gapped labels = draw indices, Pearce-Kelly repair), and
## only items whose label changed get a new draw index. Large batches, bind /
## art-pack reloads and cyclic (bad) data fall back to a full sort. Either way,
## every pair of overlapping sprites ends up in the order a full
## DepthSorter.sort would give.
##
## World entries (set_world_entries) are not layout objects: they have string
## keys, never get uids, are never part of the layout, and are only reachable
## through pick_any() / world_entry_bounds(). Internally they use negative ids.
##
## Ambient animation (pack field "anim"): one global clock (advance_anim), only
## on-screen sprites change frame, and a sprite's frames live on its own canvas
## item or a child of it, so playback never touches the draw order.

signal order_rebuilt(ms: float)

const PLANNED_TINT := Color(0.72, 0.84, 1.0, 0.55)
const MISSING_TINT := Color(0.85, 0.85, 0.85, 0.9)
const WORLD_MARKER_COLOR := Color(0.66, 0.6, 0.52)
const LIFT_SHADOW := Color(0.0, 0.0, 0.0, 0.22)
## order_of() puts flat items below every upright item.
const FLAT_RANK_OFFSET := 1 << 40

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
var _vis: Dictionary = {}          ## uid -> Vis (layout objects)
var _wvis: Dictionary = {}         ## negative id -> Vis (world entries)
var _wkey: Dictionary = {}         ## world key -> negative id
var _next_wid := -1
## Full re-sort requested (bind, art reload). Setting it to true forces the
## next ensure_sorted() to rebuild the whole order.
var _order_dirty := false
var _pending: Dictionary = {}      ## id -> true: re-sort this item at the next flush
var _order := DepthSorter.Order.new()
var _flat_order := DepthSorter.KeyedOrder.new()
var _spatial: Dictionary = {}      ## Vector2i cell -> Array[id] (picking)
var _hidden: Dictionary = {}
var _tints: Dictionary = {}        ## uid -> Color
## View-only layers (ObjectLayers): group -> "dim" | "hide"; objects of hidden
## groups are not drawn and not pickable (_lhidden), dimmed ones are faded.
var _layer_states: Dictionary = {}
var _lhidden: Dictionary = {}      ## uid -> true (hidden by a layer)
var _group_cache: Dictionary = {}  ## item id -> ObjectLayers group
## View tints (e.g. "Compare with my farm"): uid -> Color, multiplied in after _tints.
var _vtints: Dictionary = {}
const DIM_ALPHA := 0.28
var _preview: Dictionary = {}      ## uid -> true (drag preview active)
var _lifted: Dictionary = {}       ## uid -> true
var last_sort_ms := 0.0
var _ambient: int = Ambient.FULL
var _anim_clock := 0.0             ## seconds; the single clock every animation reads
var _anim: Dictionary = {}         ## id -> Vis of sprites that have an animation
var _theme := ""                   ## world theme the object sprites were last drawn with
var _anim_stats := {"ticked": 0, "frame_updates": 0}
var _stats := {"last_flush": "none", "last_flush_ms": 0.0, "full": 0, "incremental": 0,
	"fallback": 0, "draw_index_updates": 0, "last_draw_index_updates": 0}

const CELL := 192.0

## Ambient animation modes (settings: off / reduced / full).
enum Ambient { OFF, REDUCED, FULL }
const AMBIENT_FROM_SETTING := {"off": Ambient.OFF, "reduced": Ambient.REDUCED, "full": Ambient.FULL}


class Vis:
	var uid: int                   ## layout uid (> 0) or world id (< 0)
	var key: String = ""           ## world entry key ("" for layout objects)
	var ci: RID
	var sci: RID
	var lci: RID                   ## lift shadow
	var aci: RID                   ## overlay animation frames (child of ci)
	var anim_frame := -2           ## frame on screen (-1 = static, -2 = nothing drawn yet)
	var sprite: AssetLibrary.SpriteInfo
	var bounds: Rect2              ## sprite bounds at the real position
	var rect: Rect2i
	var flat := false
	var flipped := false
	var center: Vector2
	var fallback_poly: PackedVector2Array
	var sp_bounds: Rect2           ## bounds registered in the picking grid
	var sp_reg := false
	var dentry: DepthSorter.Entry  ## cached depth entry (null = recompute)
	var di := -(1 << 40)           ## draw index last sent to the RenderingServer
	# world entries
	var entry: Dictionary = {}
	var selectable := true
	var visible := true
	var drawn := false
	# drag preview / lift (layout objects)
	var previewing := false
	var pv_delta := Vector2i.ZERO
	var pv_offset := Vector2.ZERO
	var lift := 0.0


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
	_shadow_root.visible = show_shadows
	for v: Vis in _wvis.values():
		_draw_world(v)


func bind(l: FarmLayout, item_db: ItemDatabase, lib: AssetLibrary) -> void:
	if layout:
		layout.objects_added.disconnect(_on_added)
		layout.objects_removed.disconnect(_on_removed)
		layout.objects_changed.disconnect(_on_changed)
	layout = l
	db = item_db
	assets = lib
	_theme = layout.theme()
	layout.objects_added.connect(_on_added)
	layout.objects_removed.connect(_on_removed)
	layout.objects_changed.connect(_on_changed)
	rebuild_all()


func rebuild_all() -> void:
	for v: Vis in _vis.values():
		_free_vis(v)
	_vis.clear()
	_hidden.clear()
	_lhidden.clear()
	_group_cache.clear()
	_preview.clear()
	_lifted.clear()
	_pending.clear()
	if layout != null:
		for o: PlacedObject in layout.objects.values():
			_create(o)
	for v: Vis in _wvis.values():
		_draw_world(v)
	_order_dirty = true


func _exit_tree() -> void:
	for v: Vis in _vis.values():
		_free_vis(v)
	_vis.clear()
	for v: Vis in _wvis.values():
		_free_vis(v)
	_wvis.clear()
	_wkey.clear()


func _free_vis(v: Vis) -> void:
	_spatial_remove(v)
	_anim.erase(v.uid)
	if v.aci.is_valid():
		RenderingServer.free_rid(v.aci)
		v.aci = RID()
	if v.ci.is_valid():
		RenderingServer.free_rid(v.ci)
		v.ci = RID()
	if v.sci.is_valid():
		RenderingServer.free_rid(v.sci)
		v.sci = RID()
	if v.lci.is_valid():
		RenderingServer.free_rid(v.lci)
		v.lci = RID()


func _vis_of(id: int) -> Vis:
	return _vis.get(id) if id > 0 else _wvis.get(id)


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
		v.sprite = assets.get_sprite(art_key, assets.themed_variant(art_key, o.variant, _theme), _connection_mask(o, it))
	_apply_mirror(v)
	if v.sprite:
		var sz := v.sprite.texture.get_size() * v.sprite.scale
		var r := Rect2(-v.sprite.anchor * v.sprite.scale, sz)
		RenderingServer.canvas_item_add_texture_rect(v.ci, r, v.sprite.texture.get_rid())
		v.bounds = v.sprite.world_rect(v.center, v.flipped)
		v.fallback_poly = PackedVector2Array()
		_setup_anim(v)
	else:
		_clear_anim(v)
		var col: Color = db.category(it.category)["color"] if it else Color(0.6, 0.6, 0.6)
		var label := "?" if (it == null or o.missing) else ""
		_draw_block(v, o.origin, o.size, o.flipped, col, it != null and it.layer == "ground", label)
	_draw_shadow(v)
	_apply_transform(v)
	_apply_modulate(v, o)
	_spatial_update(v)
	_pending[v.uid] = true


func _draw_shadow(v: Vis) -> void:
	if v.sprite and v.sprite.shadow and not v.flat and _shadow_root != null:
		if not v.sci.is_valid():
			v.sci = RenderingServer.canvas_item_create()
			RenderingServer.canvas_item_set_parent(v.sci, _shadow_root.get_canvas_item())
		RenderingServer.canvas_item_clear(v.sci)
		var ss := v.sprite.shadow.get_size() * v.sprite.scale
		RenderingServer.canvas_item_add_texture_rect(v.sci, Rect2(-v.sprite.shadow_anchor * v.sprite.scale, ss), v.sprite.shadow.get_rid())
	elif v.sci.is_valid():
		RenderingServer.free_rid(v.sci)
		v.sci = RID()


func _draw_block(v: Vis, origin: Vector2i, size: Vector2i, flipped: bool, col: Color, flat: bool, label: String) -> void:
	## Vector stand-in when there is no art (or the id is unknown): a shaded
	## block exactly the size of the footprint, with an optional marker.
	var h := (0.4 + 0.25 * mini(size.x, size.y)) * Iso.Z_UNIT
	if flat:
		h = 3.0
	var local := Iso.footprint_polygon(origin, size)
	for i in local.size():
		local[i] -= v.center
		if flipped:
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
	if not label.is_empty():
		var font := ThemeDB.fallback_font
		var fs := int(clampf(10.0 + 6.0 * mini(size.x, size.y), 12, 40))
		font.draw_string(ci, Vector2(-fs * 0.3, -h * 0.5 + fs * 0.35), label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, Color(1, 1, 1, 0.95))
	# Bounds and the picking hull are in world space, where the canvas item's
	# own mirror (see _apply_transform) has undone the flip above: use the
	# footprint as it is drawn, not the pre-mirrored polygons.
	var shape := local + top
	if flipped:
		for i in shape.size():
			shape[i].x = -shape[i].x
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in shape:
		mn = mn.min(p)
		mx = mx.max(p)
	v.bounds = Rect2(mn + v.center, mx - mn)
	var hull := Geometry2D.convex_hull(shape)
	v.fallback_poly = PackedVector2Array()
	for p in hull:
		v.fallback_poly.append(p + v.center)


func _draw_center(v: Vis) -> Vector2:
	## Where the sprite is drawn: the real position, or the drag-preview
	## position, raised by the lift.
	var c := v.center
	if v.previewing:
		c = Iso.footprint_center(v.rect.position + v.pv_delta, v.rect.size) + v.pv_offset
	return c - Vector2(0.0, v.lift)


func _apply_transform(v: Vis) -> void:
	v.dentry = null
	var c := _draw_center(v)
	var flip := Vector2(-1.0 if v.flipped else 1.0, 0.0)
	RenderingServer.canvas_item_set_transform(v.ci, Transform2D(flip, Vector2(0.0, 1.0), c))
	var ground := c + Vector2(0.0, v.lift)
	if v.sci.is_valid():
		var sflip := Vector2(-1.0, 0.0) if v.sprite and v.sprite.shadow_mirrored else flip
		RenderingServer.canvas_item_set_transform(v.sci, Transform2D(sflip, Vector2(0.0, 1.0), ground))
	if v.lift > 0.0 and _shadow_root != null:
		if not v.lci.is_valid():
			v.lci = RenderingServer.canvas_item_create()
			RenderingServer.canvas_item_set_parent(v.lci, _shadow_root.get_canvas_item())
		RenderingServer.canvas_item_clear(v.lci)
		var w := (v.rect.size.x + v.rect.size.y) * Iso.HALF_W * 0.5 * 0.8
		var h := (v.rect.size.x + v.rect.size.y) * Iso.HALF_H * 0.5 * 0.8
		var pts := PackedVector2Array()
		for i in 24:
			var a := TAU * i / 24.0
			pts.append(Vector2(cos(a) * w, sin(a) * h))
		RenderingServer.canvas_item_add_polygon(v.lci, pts, PackedColorArray([LIFT_SHADOW]))
		RenderingServer.canvas_item_set_transform(v.lci, Transform2D(0.0, ground))
	elif v.lci.is_valid():
		RenderingServer.free_rid(v.lci)
		v.lci = RID()


func _entry_of(v: Vis) -> DepthSorter.Entry:
	## Depth-order entry at the position the item is drawn at (cached until the
	## item is redrawn or moved; entries are immutable once handed out).
	if v.dentry != null:
		return v.dentry
	var r := v.rect
	var b := v.bounds
	if v.previewing or v.lift != 0.0:
		r = Rect2i(r.position + (v.pv_delta if v.previewing else Vector2i.ZERO), r.size)
		b = Rect2(b.position + (_draw_center(v) - v.center), b.size)
	v.dentry = DepthSorter.Entry.new(v.uid, r, b)
	return v.dentry


func _apply_modulate(v: Vis, o: PlacedObject) -> void:
	var m := Color.WHITE
	if o.planned:
		m = PLANNED_TINT
	elif o.missing:
		m = MISSING_TINT
	if _tints.has(o.uid):
		m *= _tints[o.uid]
	if _vtints.has(o.uid):
		m *= _vtints[o.uid]
	var lstate := ObjectLayers.SHOW
	if not _layer_states.is_empty():
		var g: Variant = _group_cache.get(o.item_id)
		if g == null:
			g = ObjectLayers.group_of(db, o.item_id)
			_group_cache[o.item_id] = g
		lstate = str(_layer_states.get(g, ObjectLayers.SHOW))
	if lstate == ObjectLayers.HIDE:
		_lhidden[o.uid] = true
	else:
		_lhidden.erase(o.uid)
		if lstate == ObjectLayers.DIM:
			m.a *= DIM_ALPHA
	RenderingServer.canvas_item_set_modulate(v.ci, m)
	var visible := not _hidden.has(o.uid) and lstate != ObjectLayers.HIDE
	RenderingServer.canvas_item_set_visible(v.ci, visible)
	if v.sci.is_valid():
		RenderingServer.canvas_item_set_visible(v.sci, visible and not o.planned and lstate != ObjectLayers.DIM)


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
			_lhidden.erase(u)
			_tints.erase(u)
			_vtints.erase(u)
			_preview.erase(u)
			_lifted.erase(u)
			_pending[u] = true
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
			v.di = -(1 << 40)
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
	if layout != null:
		for u in _vis:
			var o := layout.get_obj(u)
			if o:
				_draw_vis(_vis[u], o, db.get_item(o.item_id))
	for v: Vis in _wvis.values():
		_draw_world(v)
	_order_dirty = true


func refresh_art(art_keys: Array) -> int:
	## After an override edit: redraw only objects (and world entries) using
	## these art keys. Returns how many objects were redrawn.
	var ks := {}
	for k in art_keys:
		ks[str(k)] = true
	var n := 0
	for u in _vis:
		var o := layout.get_obj(u) if layout else null
		if o == null:
			continue
		var it := db.get_item(o.item_id)
		if ks.has(it.art_key if it else o.item_id):
			_draw_vis(_vis[u], o, it)
			n += 1
	for v: Vis in _wvis.values():
		if ks.has(str(v.entry.get("art", ""))) or ks.has(str(v.entry.get("fallback_art", ""))):
			_draw_world(v)
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


func set_view_tints(tints: Dictionary) -> void:
	## View-only tints (Compare with my farm), on top of set_tints(); {} clears.
	var touched := {}
	for u in _vtints:
		if not tints.has(u) or tints[u] != _vtints[u]:
			touched[u] = true
	for u in tints:
		if not _vtints.has(u) or tints[u] != _vtints[u]:
			touched[u] = true
	_vtints = tints.duplicate()
	for u in touched:
		var v: Vis = _vis.get(u)
		var o := layout.get_obj(u) if layout else null
		if v and o:
			_apply_modulate(v, o)


func view_tint_count() -> int:
	return _vtints.size()


func set_layer_states(states: Dictionary) -> void:
	## Object layers (ObjectLayers): {group: "dim" | "hide"}; {} shows everything.
	## View only: the layout is never touched. O(objects) per call.
	var st := ObjectLayers.normalize(states)
	if st == _layer_states:
		return
	_layer_states = st
	_group_cache.clear()
	if layout == null:
		return
	for u in _vis:
		var o := layout.get_obj(u)
		if o:
			_apply_modulate(_vis[u], o)


func layer_states() -> Dictionary:
	return _layer_states.duplicate()


func is_layer_hidden(uid: int) -> bool:
	## Hidden by an object layer (not drawn, not pickable).
	return _lhidden.has(uid)


func layer_hidden_count() -> int:
	return _lhidden.size()


func refresh_theme() -> void:
	## After the layout's world theme changed: only objects whose art really has
	## theme variants are redrawn. Landmarks follow through set_world_entries.
	var t := layout.theme() if layout else ""
	if t == _theme:
		return
	_theme = t
	for u in _vis:
		var o := layout.get_obj(u)
		if o == null:
			continue
		var it := db.get_item(o.item_id)
		if it and assets.has_theme_variants(it.art_key):
			_draw_vis(_vis[u], o, it)


# --- ambient animation -----------------------------------------------------------------

func set_ambient_mode(mode: int) -> void:
	_ambient = mode
	for v: Vis in _anim.values():
		_show_anim_frame(v, _anim_frame_for(v))


func ambient_mode() -> int:
	return _ambient


func advance_anim(dt: float, view: Rect2) -> void:
	## Moves the clock and updates the sprites whose rect touches `view` (world px).
	_anim_stats["ticked"] = 0
	_anim_stats["frame_updates"] = 0
	if _ambient == Ambient.OFF:
		return
	_anim_clock += dt
	for v: Vis in _anim.values():
		if not v.bounds.intersects(view) or _hidden.has(v.uid) or not v.visible:
			continue
		_anim_stats["ticked"] += 1
		var f := _anim_frame_for(v)
		if f != v.anim_frame:
			_show_anim_frame(v, f)
			_anim_stats["frame_updates"] += 1


func anim_stats() -> Dictionary:
	## {"animated": sprites with an animation, "ticked" / "frame_updates": of the last advance}.
	return {"animated": _anim.size(), "ticked": _anim_stats["ticked"], "frame_updates": _anim_stats["frame_updates"]}


func anim_frame_of(uid: int) -> int:
	## Frame on screen (-1 = static image, -2 = no animation). Layout uid.
	var v: Vis = _vis.get(uid)
	return v.anim_frame if v and v.sprite and v.sprite.anim else -2


func _apply_mirror(v: Vis) -> void:
	## A flipped object whose sprite has hand-drawn mirror art shows that art unflipped.
	if v.flipped and v.sprite and v.sprite.mirror:
		v.sprite = v.sprite.mirror
		v.flipped = false


func _anim_frame_for(v: Vis) -> int:
	## The frame this sprite should show now (-1 = its static image).
	var a := v.sprite.anim
	if a.frames < 2 or _ambient == Ambient.OFF or (_ambient == Ambient.REDUCED and posmod(v.uid, 3) != 0):
		return -1
	var fps := a.fps * (0.5 if _ambient == Ambient.REDUCED else 1.0)
	return (floori(_anim_clock * fps) + posmod(v.uid * 7, a.frames)) % a.frames


func _setup_anim(v: Vis) -> void:
	## Called right after the sprite was (re)drawn on v.ci.
	var a := v.sprite.anim
	if a == null:
		_clear_anim(v)
		return
	_anim[v.uid] = v
	v.anim_frame = -2
	if not a.overlay and v.aci.is_valid():
		RenderingServer.free_rid(v.aci)
		v.aci = RID()
	v.bounds = v.bounds.merge(a.world_rect(v.center, v.flipped, v.sprite.scale))
	_show_anim_frame(v, _anim_frame_for(v))


func _clear_anim(v: Vis) -> void:
	_anim.erase(v.uid)
	v.anim_frame = -2
	if v.aci.is_valid():
		RenderingServer.free_rid(v.aci)
		v.aci = RID()


func _show_anim_frame(v: Vis, f: int) -> void:
	if f == v.anim_frame:
		return
	var had_static := v.anim_frame == -2   # _draw_vis / _draw_world just drew the static image
	v.anim_frame = f
	var a := v.sprite.anim
	var sc := v.sprite.scale
	var r := Rect2(-a.anchor * sc, a.frame_size * sc)
	if a.overlay:
		if not v.aci.is_valid():
			v.aci = RenderingServer.canvas_item_create()
			RenderingServer.canvas_item_set_parent(v.aci, v.ci)
		RenderingServer.canvas_item_clear(v.aci)
		RenderingServer.canvas_item_add_texture_rect_region(v.aci, r, a.sheet.get_rid(), a.frame_rect(maxi(f, 0)))
	elif f >= 0:
		RenderingServer.canvas_item_clear(v.ci)
		RenderingServer.canvas_item_add_texture_rect_region(v.ci, r, a.sheet.get_rid(), a.frame_rect(f))
	elif not had_static:
		RenderingServer.canvas_item_clear(v.ci)
		RenderingServer.canvas_item_add_texture_rect(v.ci, Rect2(-v.sprite.anchor * sc, v.sprite.texture.get_size() * sc), v.sprite.texture.get_rid())


# --- drag preview / lift ------------------------------------------------------------

func set_drag_preview(uids: Array, tile_delta: Vector2i, pixel_offset: Vector2 = Vector2.ZERO) -> void:
	## Draws these objects at origin + tile_delta (+ a sub-tile pixel offset for
	## smooth motion), depth-sorted at their prospective footprint, without
	## touching the layout. Picking keeps using the real positions. O(K) per
	## call (K = objects whose preview changed).
	var want := {}
	for u in uids:
		if _vis.has(u):
			want[u] = true
	for u in _preview.keys():
		if not want.has(u):
			_set_preview(_vis.get(u), false, Vector2i.ZERO, Vector2.ZERO)
			_preview.erase(u)
	for u in want:
		_set_preview(_vis[u], true, tile_delta, pixel_offset)
		_preview[u] = true


func clear_drag_preview() -> void:
	for u in _preview.keys():
		_set_preview(_vis.get(u), false, Vector2i.ZERO, Vector2.ZERO)
	_preview.clear()


func _set_preview(v: Vis, on: bool, d: Vector2i, off: Vector2) -> void:
	if v == null:
		return
	if v.previewing == on and v.pv_delta == d and v.pv_offset == off:
		return
	v.previewing = on
	v.pv_delta = d
	v.pv_offset = off
	_apply_transform(v)
	_pending[v.uid] = true


func is_previewing(uid: int) -> bool:
	return _preview.has(uid)


func set_lift(uids: Array, px: float) -> void:
	## Raises these objects' sprites by `px` world pixels with a soft ground
	## shadow under the footprint (drag feedback); other objects are lowered.
	## set_lift([], 0) clears it.
	var want := {}
	for u in uids:
		if _vis.has(u):
			want[u] = true
	for u in _lifted.keys():
		if not want.has(u):
			_set_lift(_vis.get(u), 0.0)
			_lifted.erase(u)
	for u in want:
		_set_lift(_vis[u], maxf(0.0, px))
		if px > 0.0:
			_lifted[u] = true
		else:
			_lifted.erase(u)


func _set_lift(v: Vis, px: float) -> void:
	if v == null or v.lift == px:
		return
	v.lift = px
	_apply_transform(v)
	_pending[v.uid] = true


# --- world entries ---------------------------------------------------------------------

func set_world_entries(entries: Array) -> void:
	## Replace the set of world entries (see the rendering contract):
	## {"key", "rect": Rect2i (footprint, may be negative), "art", "fallback_art",
	##  "variant", "draw_anchor", "selectable", "visible", "tint": Color (optional),
	##  "flipped": bool (optional)}. Entries depth-sort together with placed
	## objects; unchanged entries are left alone; duplicate keys: first wins.
	var seen := {}
	for d in entries:
		if not d is Dictionary:
			continue
		var key := str((d as Dictionary).get("key", ""))
		if key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		var norm := _normalize_world(d)
		if _wkey.has(key):
			var v: Vis = _wvis[_wkey[key]]
			if v.entry != norm:
				v.entry = norm
				_draw_world(v)
		else:
			var v := Vis.new()
			v.uid = _next_wid
			_next_wid -= 1
			v.key = key
			v.entry = norm
			v.ci = RenderingServer.canvas_item_create()
			_wkey[key] = v.uid
			_wvis[v.uid] = v
			_draw_world(v)
	for key in _wkey.keys():
		if not seen.has(key):
			_remove_world(key)


func update_world_entry(key: String, changes: Dictionary) -> bool:
	## Merge `changes` into one entry (e.g. {"variant": "stage_2__winter"} or
	## {"visible": false}) and re-sort just that entry. False if unknown.
	var id: Variant = _wkey.get(key)
	if id == null:
		return false
	var v: Vis = _wvis[id]
	var merged: Dictionary = v.entry.duplicate()
	for k in changes:
		merged[k] = changes[k]
	merged["key"] = key
	var norm := _normalize_world(merged)
	if norm != v.entry:
		v.entry = norm
		_draw_world(v)
	return true


func world_entry_bounds(key: String) -> Rect2:
	## Sprite bounds (world px) of a world entry; Rect2() when unknown.
	var id: Variant = _wkey.get(key)
	if id == null:
		return Rect2()
	return (_wvis[id] as Vis).bounds


func world_entry(key: String) -> Dictionary:
	## The normalised entry dictionary ({} when unknown).
	var id: Variant = _wkey.get(key)
	return (_wvis[id] as Vis).entry.duplicate() if id != null else {}


func world_entry_keys() -> Array:
	return _wkey.keys()


func world_sprite_of(key: String) -> AssetLibrary.SpriteInfo:
	var id: Variant = _wkey.get(key)
	return (_wvis[id] as Vis).sprite if id != null else null


func world_order_of(key: String) -> int:
	## Draw rank of a world entry (comparable with order_of(uid)); 0 if unknown.
	ensure_sorted()
	var id: Variant = _wkey.get(key)
	return _order.index_of(id) if id != null else 0


func _remove_world(key: String) -> void:
	var id: int = _wkey[key]
	var v: Vis = _wvis[id]
	_free_vis(v)
	_wvis.erase(id)
	_wkey.erase(key)
	_pending[id] = true


static func _normalize_world(d: Dictionary) -> Dictionary:
	var r := Rect2i(0, 0, 1, 1)
	var rv: Variant = d.get("rect")
	if rv is Rect2i:
		r = rv
	elif rv is Rect2:
		r = Rect2i(Vector2i((rv as Rect2).position.floor()), Vector2i((rv as Rect2).size.round()))
	elif rv is Array and (rv as Array).size() >= 4:
		r = Rect2i(int(rv[0]), int(rv[1]), int(rv[2]), int(rv[3]))
	r.size = r.size.max(Vector2i.ONE)
	var tint: Variant = d.get("tint", Color.WHITE)
	return {"key": str(d.get("key", "")), "rect": r, "art": str(d.get("art", "")),
		"fallback_art": str(d.get("fallback_art", "")), "variant": str(d.get("variant", "")),
		"draw_anchor": str(d.get("draw_anchor", "top_corner")), "selectable": bool(d.get("selectable", true)),
		"visible": bool(d.get("visible", true)), "tint": tint if tint is Color else Color.WHITE,
		"flipped": bool(d.get("flipped", false))}


func _world_sprite(e: Dictionary) -> AssetLibrary.SpriteInfo:
	## art (with the variant, then the variant's base state before "__", then
	## the base image), else fallback_art the same way, else null (marker).
	if assets == null:
		return null
	var variant: String = e["variant"]
	for art: String in [e["art"], e["fallback_art"]]:
		if art.is_empty():
			continue
		var s := assets.get_sprite(art, variant)
		if s == null:
			continue
		if variant.is_empty() or variant == AssetLibrary.BASE_VARIANT or s.variant == variant:
			return s
		var cut := variant.find("__")
		if cut > 0:
			var s2 := assets.get_sprite(art, variant.substr(0, cut))
			if s2 and s2.variant == variant.substr(0, cut):
				return s2
		return assets.get_sprite(art, AssetLibrary.BASE_VARIANT)
	return null


func _draw_world(v: Vis) -> void:
	## (Re)draws a world entry. Before _ready() it only records the entry; it is
	## drawn when the node enters the tree.
	if not v.ci.is_valid() or _obj_root == null:
		return
	if not v.drawn:
		RenderingServer.canvas_item_set_parent(v.ci, _obj_root.get_canvas_item())
		v.drawn = true
	var e := v.entry
	RenderingServer.canvas_item_clear(v.ci)
	v.rect = e["rect"]
	v.flipped = e["flipped"]
	v.selectable = e["selectable"]
	v.visible = e["visible"]
	v.center = Iso.footprint_center(v.rect.position, v.rect.size)
	v.sprite = _world_sprite(e)
	_apply_mirror(v)
	if v.sprite:
		var sz := v.sprite.texture.get_size() * v.sprite.scale
		RenderingServer.canvas_item_add_texture_rect(v.ci, Rect2(-v.sprite.anchor * v.sprite.scale, sz), v.sprite.texture.get_rid())
		v.bounds = v.sprite.world_rect(v.center, v.flipped)
		v.fallback_poly = PackedVector2Array()
		_setup_anim(v)
	else:
		_clear_anim(v)
		_draw_block(v, v.rect.position, v.rect.size, v.flipped, WORLD_MARKER_COLOR, false, "")
	_draw_shadow(v)
	_apply_transform(v)
	RenderingServer.canvas_item_set_modulate(v.ci, e["tint"])
	RenderingServer.canvas_item_set_visible(v.ci, v.visible)
	if v.sci.is_valid():
		RenderingServer.canvas_item_set_visible(v.sci, v.visible)
	_spatial_update(v)
	_pending[v.uid] = true


# --- draw order ------------------------------------------------------------------------

func _process(dt: float) -> void:
	if _order_dirty or not _pending.is_empty():
		ensure_sorted()
	if not _anim.is_empty():
		advance_anim(dt, get_canvas_transform().affine_inverse() * get_viewport_rect())


func ensure_sorted() -> void:
	if not _order_dirty and _pending.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var kind := ""
	if _order_dirty:
		_full_rebuild()
		kind = "full"
	else:
		kind = "incremental" if _flush_pending() else "full_fallback"
	var n := _push_draw_indices(kind != "incremental")
	last_sort_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_stats["last_flush"] = kind
	_stats["last_flush_ms"] = last_sort_ms
	_stats["last_draw_index_updates"] = n
	_stats["draw_index_updates"] += n
	if kind == "incremental":
		_stats["incremental"] += 1
	elif kind == "full":
		_stats["full"] += 1
	else:
		_stats["fallback"] += 1
	order_rebuilt.emit(last_sort_ms)


func _upright_ok(v: Vis) -> bool:
	return not v.flat and (v.key.is_empty() or v.visible)


func _full_rebuild() -> void:
	_order_dirty = false
	_pending.clear()
	var entries: Array = []
	var flats: Array = []
	for v: Vis in _vis.values():
		if v.flat:
			flats.append([v.uid, DepthSorter.KeyedOrder.flat_key(_entry_of(v).rect, v.uid)])
		else:
			entries.append(_entry_of(v))
	for v: Vis in _wvis.values():
		if _upright_ok(v):
			entries.append(_entry_of(v))
	_order.rebuild(entries)
	_flat_order.rebuild(flats)


func _flush_pending() -> bool:
	## -> true when the upright order was updated incrementally.
	var rm: Array = []
	var up: Array = []
	for id: int in _pending:
		var v := _vis_of(id)
		if v == null:
			if _order.has(id):
				rm.append(id)
			_flat_order.remove(id)
		elif v.flat:
			if _order.has(id):
				rm.append(id)
			_flat_order.upsert(id, DepthSorter.KeyedOrder.flat_key(_entry_of(v).rect, id))
		else:
			_flat_order.remove(id)
			if _upright_ok(v):
				var e := _entry_of(v)
				var old := _order.entry(id)
				# Redrawn but same footprint and bounds (e.g. a connection
				# neighbour or an art refresh at the same size): edges unchanged.
				if old == null or old.rect != e.rect or old.bounds != e.bounds:
					up.append(e)
			elif _order.has(id):
				rm.append(id)
	_pending.clear()
	return _order.apply(rm, up)


func _push_draw_indices(all: bool) -> int:
	## Sends changed labels as draw indices (unique per parent, so the engine
	## order is well defined). After a full sort every item is checked, but only
	## items whose index really changed cost a RenderingServer call.
	var n := 0
	for seq: DepthSorter.LabelSeq in [_order.seq, _flat_order.seq]:
		if all:
			seq.changed.clear()
			var ids := seq.ids
			var lab := seq.lab
			for i in ids.size():
				var id := ids[i]
				var v: Vis = _vis.get(id) if id > 0 else _wvis.get(id)
				if v and v.di != lab[i] and v.ci.is_valid():
					v.di = lab[i]
					RenderingServer.canvas_item_set_draw_index(v.ci, v.di)
					n += 1
		else:
			for id: int in seq.take_changed():
				var v := _vis_of(id)
				var l: int = seq.label.get(id, 0)
				if v and v.di != l and v.ci.is_valid():
					v.di = l
					RenderingServer.canvas_item_set_draw_index(v.ci, l)
					n += 1
	return n


func _rank(v: Vis) -> int:
	## Comparable draw rank: flat items below every upright item.
	if v.flat:
		return _flat_order.index_of(v.uid) - FLAT_RANK_OFFSET
	return _order.index_of(v.uid)


func depth_stats() -> Dictionary:
	## Diagnostics: last flush kind ("full" | "incremental" | "full_fallback"),
	## its time, draw-index updates and the incremental order's counters.
	var d := _stats.duplicate()
	d["order"] = _order.stats.duplicate()
	d["cyclic"] = _order.cyclic
	d["uprights"] = _order.size()
	d["flats"] = _flat_order.size()
	d["relabels"] = _order.seq.relabels + _flat_order.seq.relabels
	d["relabeled_nodes"] = _order.seq.relabeled_nodes + _flat_order.seq.relabeled_nodes
	d["renumbers"] = _order.seq.renumbers + _flat_order.seq.renumbers
	return d


func check_order() -> Dictionary:
	## Debug / tests: {"violations": edges drawn in the wrong order (0 unless the
	## data is cyclic), "cyclic": bool, "mismatch": pairs ordered differently
	## from a fresh full DepthSorter.sort, "flat_mismatch": flats out of order}.
	ensure_sorted()
	var entries: Array = []
	var flats: Array = []
	for v: Vis in _vis.values():
		if v.flat:
			flats.append(v)
		else:
			entries.append(_entry_of(v))
	for v: Vis in _wvis.values():
		if _upright_ok(v):
			entries.append(_entry_of(v))
	var full := DepthSorter.sort(entries)
	var pos := {}
	for i in full.size():
		pos[full[i]] = i
	var mismatch := 0
	var by := {}
	for e: DepthSorter.Entry in entries:
		by[e.uid] = e
	for e: DepthSorter.Entry in entries:
		for n: int in _order.neighbours(e):
			if n <= e.uid:
				continue
			if (pos[e.uid] < pos[n]) != (_order.index_of(e.uid) < _order.index_of(n)):
				mismatch += 1
	flats.sort_custom(func(a: Vis, b: Vis) -> bool: return DepthSorter.KeyedOrder.flat_key(a.rect, a.uid) < DepthSorter.KeyedOrder.flat_key(b.rect, b.uid))
	var flat_mismatch := 0
	for i in range(1, flats.size()):
		if _flat_order.index_of(flats[i - 1].uid) >= _flat_order.index_of(flats[i].uid):
			flat_mismatch += 1
	return {"violations": _order.violations(), "cyclic": _order.cyclic, "mismatch": mismatch,
		"flat_mismatch": flat_mismatch, "uprights": entries.size(), "stale": _order.size() - entries.size()}


# --- picking ---------------------------------------------------------------------------

func _spatial_update(v: Vis) -> void:
	var pickable := v.key.is_empty() or v.visible
	if v.sp_reg and pickable and v.sp_bounds == v.bounds:
		return
	_spatial_remove(v)
	if not pickable:
		return
	var b := v.bounds
	for cy in range(floori(b.position.y / CELL), floori(b.end.y / CELL) + 1):
		for cx in range(floori(b.position.x / CELL), floori(b.end.x / CELL) + 1):
			var k := Vector2i(cx, cy)
			var a: Variant = _spatial.get(k)
			if a == null:
				_spatial[k] = [v.uid]
			else:
				(a as Array).append(v.uid)
	v.sp_bounds = b
	v.sp_reg = true


func _spatial_remove(v: Vis) -> void:
	if not v.sp_reg:
		return
	var b := v.sp_bounds
	for cy in range(floori(b.position.y / CELL), floori(b.end.y / CELL) + 1):
		for cx in range(floori(b.position.x / CELL), floori(b.end.x / CELL) + 1):
			var k := Vector2i(cx, cy)
			var a: Variant = _spatial.get(k)
			if a != null:
				(a as Array).erase(v.uid)
				if (a as Array).is_empty():
					_spatial.erase(k)
	v.sp_reg = false


func _hit(v: Vis, world_pos: Vector2) -> bool:
	if not v.bounds.has_point(world_pos):
		return false
	if v.sprite:
		return v.sprite.hit(v.center, v.flipped, world_pos)
	if not v.fallback_poly.is_empty():
		return Geometry2D.is_point_in_polygon(world_pos, v.fallback_poly)
	return false


func pick(world_pos: Vector2, include_hidden: bool = false) -> int:
	## Top-most layout object whose *visible pixels* are under world_pos,
	## falling back to the footprint tile. Returns 0 when nothing is there.
	## World entries are ignored (see pick_any).
	ensure_sorted()
	var k := Vector2i(floori(world_pos.x / CELL), floori(world_pos.y / CELL))
	var best := 0
	var best_rank := -FLAT_RANK_OFFSET * 4
	var up: Dictionary = _order.seq.label
	var fl: Dictionary = _flat_order.seq.label
	for u: int in _spatial.get(k, []):
		if u <= 0 or (not include_hidden and _hidden.has(u)) or _lhidden.has(u):
			continue
		var v: Vis = _vis.get(u)
		if v == null or not v.bounds.has_point(world_pos):
			continue
		var r: int = int(fl.get(u, 0)) - FLAT_RANK_OFFSET if v.flat else int(up.get(u, 0))
		if r <= best_rank or not _hit(v, world_pos):
			continue
		best = u
		best_rank = r
	if best != 0:
		return best
	var o := _tile_object(Iso.world_to_tile(world_pos), include_hidden)
	return o.uid if o else 0


func _tile_object(t: Vector2i, include_hidden: bool) -> PlacedObject:
	## Top object whose footprint covers the tile, skipping layer-hidden ones
	## (and drag/erase-hidden ones unless include_hidden).
	if layout == null:
		return null
	var o := layout.object_at(t)
	if o == null or (not include_hidden and _hidden.has(o.uid)):
		return null
	if not _lhidden.has(o.uid):
		return o
	var stacked: Array = layout.occupancy.all_at(t)
	for i in range(stacked.size() - 1, -1, -1):
		var u: int = stacked[i]
		if not _lhidden.has(u) and (include_hidden or not _hidden.has(u)):
			return layout.get_obj(u)
	return null


func pick_any(world_pos: Vector2, include_hidden: bool = false) -> Dictionary:
	## Top-most layout object or selectable, visible world entry under
	## world_pos: pixel-accurate (sprite alpha) first, then the footprint tile
	## (objects before world entries). -> {"kind": "object" | "landmark" | "",
	## "uid": int (objects, else 0), "key": String (world entries, else "")}.
	ensure_sorted()
	var k := Vector2i(floori(world_pos.x / CELL), floori(world_pos.y / CELL))
	var best: Vis = null
	var best_rank := -FLAT_RANK_OFFSET * 4
	var up: Dictionary = _order.seq.label
	var fl: Dictionary = _flat_order.seq.label
	for id: int in _spatial.get(k, []):
		var v: Vis = _vis.get(id) if id > 0 else _wvis.get(id)
		if v == null or not v.bounds.has_point(world_pos):
			continue
		if id > 0:
			if (not include_hidden and _hidden.has(id)) or _lhidden.has(id):
				continue
		elif not v.selectable or not v.visible:
			continue
		var r: int = int(fl.get(id, 0)) - FLAT_RANK_OFFSET if v.flat else int(up.get(id, 0))
		if r <= best_rank or not _hit(v, world_pos):
			continue
		best = v
		best_rank = r
	if best != null:
		return _pick_result(best)
	var t := Iso.world_to_tile(world_pos)
	var o := _tile_object(t, include_hidden)
	if o:
		return {"kind": "object", "uid": o.uid, "key": ""}
	for v: Vis in _wvis.values():
		if v.selectable and v.visible and v.rect.has_point(t):
			var r := _rank(v)
			if best == null or r > best_rank:
				best = v
				best_rank = r
	if best != null:
		return _pick_result(best)
	return {"kind": "", "uid": 0, "key": ""}


func pick_all(world_pos: Vector2, include_hidden: bool = false) -> Array:
	## Everything under world_pos, top-most first, in pick_any()'s result shape:
	## pixel hits by draw rank, then whatever only covers the point with its
	## footprint tile. The first entry is what pick_any() returns.
	ensure_sorted()
	var k := Vector2i(floori(world_pos.x / CELL), floori(world_pos.y / CELL))
	var hits: Array = []
	var up: Dictionary = _order.seq.label
	var fl: Dictionary = _flat_order.seq.label
	for id: int in _spatial.get(k, []):
		var v: Vis = _vis.get(id) if id > 0 else _wvis.get(id)
		if v == null or not v.bounds.has_point(world_pos):
			continue
		if id > 0:
			if (not include_hidden and _hidden.has(id)) or _lhidden.has(id):
				continue
		elif not v.selectable or not v.visible:
			continue
		if _hit(v, world_pos):
			hits.append([int(fl.get(id, 0)) - FLAT_RANK_OFFSET if v.flat else int(up.get(id, 0)), v])
	hits.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	var out: Array = []
	var seen := {}
	for h: Array in hits:
		var v: Vis = h[1]
		seen[v.uid] = true
		out.append(_pick_result(v))
	var t := Iso.world_to_tile(world_pos)
	if layout:
		var stacked: Array = layout.occupancy.all_at(t)
		stacked.reverse()
		for u in stacked:
			if not seen.has(u) and not _lhidden.has(u) and (include_hidden or not _hidden.has(u)):
				seen[u] = true
				out.append({"kind": "object", "uid": u, "key": ""})
	var lms: Array = []
	for v: Vis in _wvis.values():
		if not seen.has(v.uid) and v.selectable and v.visible and v.rect.has_point(t):
			lms.append([_rank(v), v])
	lms.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	for h: Array in lms:
		out.append(_pick_result(h[1]))
	return out


func _pick_result(v: Vis) -> Dictionary:
	if v.key.is_empty():
		return {"kind": "object", "uid": v.uid, "key": ""}
	return {"kind": "landmark", "uid": 0, "key": v.key}


func uids_in_world_rect(r: Rect2) -> Array:
	## Objects whose footprint centre lies inside a world-space rectangle.
	var out: Array = []
	for v: Vis in _vis.values():
		if r.has_point(v.center) and not _lhidden.has(v.uid):
			out.append(v.uid)
	return out


func bounds_of(uid: int) -> Rect2:
	var v: Vis = _vis.get(uid)
	return v.bounds if v else Rect2()


func sprite_of(uid: int) -> AssetLibrary.SpriteInfo:
	var v: Vis = _vis.get(uid)
	return v.sprite if v else null


func order_of(uid: int) -> int:
	## Draw rank (higher = in front); flat items rank below upright ones.
	ensure_sorted()
	var v: Vis = _vis.get(uid)
	return _rank(v) if v else 0


func object_count() -> int:
	return _vis.size()
