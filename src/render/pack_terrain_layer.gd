class_name PackTerrainLayer
extends Node2D
## Terrain art from an asset pack (TerrainPack, docs/TERRAIN_PACKS.md). A child
## of GroundLayer drawn behind it, after the procedural TerrainLayer:
##   background colour (base "color") -> ground tiles -> pieces (by z) -> animated pieces
## and below every object (the whole ground layer is). Pieces with "layer":
## "foreground" go to `foreground`, a node main.gd moves above the objects
## (attach_foreground); it only draws, so it never takes a click. Everything is
## cached: the tile triangles are rebuilt only when the map, the theme variant
## or plot ownership changes, the pieces only on a map / variant change, never
## on a camera move. Files load once per pack (TerrainPack.cache / AssetLibrary).
##
## Fallback per element: a tile whose art the pack lacks is not `covered`, so
## GroundLayer / the procedural terrain draw it; a piece that fails to load is
## skipped and keeps `backdrop_ok` false, so the procedural terrain stays
## underneath instead of leaving a hole. Problems go to the pack's diagnostics
## (TerrainPack.errors, listed by the Asset Manager), never to an error dialog.

## The pieces' extent changed (map, pack or variant): camera bounds may follow.
signal extent_changed

const BACKDROP_MARGIN := 64      ## tiles of background colour beyond the world bounds
## The background colour fills an axis-aligned screen-space rectangle this far
## (world px) around the world bounds, so no zoom-out shows the app's clear
## colour in the corners of the iso diamond (seen with a real pack at zoom 0.25).
const BACKDROP_PAD_PX := 32768.0
const TILE_INSET := 0.5          ## texels kept off a tile rect's border (no atlas bleeding)
const DEFAULT_BACKGROUND := Color("#5f9a49")
## Margin (world px) kept around the pieces' extent for the camera bounds.
const CAMERA_MARGIN := 64.0
## Two-pass colour-add term of clip elements: the normal pass draws
## texture * mul, this pass adds add * alpha on top (see _AnimNode).
const CLIP_ADD_SHADER_CODE := """shader_type canvas_item;
render_mode blend_add;
varying vec4 vc;
void vertex() { vc = COLOR; }
void fragment() { COLOR = vec4(vc.rgb, texture(TEXTURE, UV).a * vc.a); }
"""

static var _materials: Dictionary = {}   ## "<blend>:<add>" -> Material (null = default)

var pack: TerrainPack
var assets: AssetLibrary
var map: FarmMap
var variant := ""
var ambient: int = ObjectRenderer.Ambient.FULL
var cover_rect := Rect2i()
var covered := PackedByteArray()  ## per tile of cover_rect: 1 = the pack draws that tile's ground
var backdrop_ok := false          ## base "color" and every piece loaded: the procedural terrain may hide
var failed_pieces := 0
var stats := {"tiles": 0, "tile_batches": 0, "pieces": 0, "foreground": 0, "vertices": 0, "anims": 0, "clips": 0, "blended": 0}
var last_tiles_usec := 0
var last_pieces_usec := 0
var tiles_version := 0            ## bumped whenever `covered` is rebuilt
## World-px rectangle covered by the pieces of the current variant (incl.
## animation instances); empty without pieces.
var extent := Rect2()
## Foreground pieces (drawn over the objects once main.gd attached it above
## them; until then it is a child of this layer, under the objects).
var foreground: Node2D

var _tiles: _Canvas
var _pieces: Node2D
var _anim: _AnimNode
var _fg_pieces: Node2D
var _fg_anim: _AnimNode
var _open := PackedByteArray([255])
var _batches: Array = []          ## [Texture2D, PackedInt32Array, PackedVector2Array, PackedColorArray, PackedVector2Array]
var _bg_poly := PackedVector2Array()
var _bg_color := Color()
## variant -> the tiles built last for it ({open, batches, covered, rect, bg_poly,
## bg_color, tiles}); one ownership state per variant, cleared with the map / pack.
var _tile_cache: Dictionary = {}


class _Canvas extends Node2D:
	var painter: Callable

	func _draw() -> void:
		if painter.is_valid():
			painter.call(self)


class _PieceNode extends Node2D:
	## One static piece: an image (atlas region or file), a mesh or a polygon.
	var piece: Dictionary
	var tex: Texture2D
	var mesh: ArrayMesh
	var region := Rect2()

	func local_bounds() -> Rect2:
		## What it draws, relative to its anchor (world px).
		match str(piece["type"]):
			"image":
				if tex == null:
					return Rect2()
				var sc: float = piece["scale"]
				var r := Rect2(-(piece["origin"] as Vector2) * sc, region.size * sc)
				if bool(piece["flip_h"]):
					r.position.x = -r.end.x
				return r
			"mesh":
				if mesh:
					var a := mesh.get_aabb()
					return Rect2(a.position.x, a.position.y, a.size.x, a.size.y)
			"polygon":
				return PackTerrainLayer._poly_bounds(piece["polygon"])
		return Rect2()

	func _draw() -> void:
		var mod: Color = piece["modulate"]
		match str(piece["type"]):
			"image":
				if tex == null:
					return
				var sc: float = piece["scale"]
				if bool(piece["flip_h"]):
					draw_set_transform(Vector2.ZERO, 0.0, Vector2(-1, 1))
				draw_texture_rect_region(tex, Rect2(-(piece["origin"] as Vector2) * sc, region.size * sc), region, mod)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			"mesh":
				if mesh:
					draw_mesh(mesh, tex, Transform2D.IDENTITY, mod)
			"polygon":
				var pts: PackedVector2Array = piece["polygon"]
				var c: Color = (piece["color"] as Color) * mod
				var cols := PackedColorArray()
				cols.resize(pts.size())
				cols.fill(c)
				var uvs := PackedVector2Array()
				if tex:
					var div: float = piece["uv_world"]
					var at: Vector2 = piece["at"]
					for p in pts:
						uvs.append((p + at) / div)
				draw_polygon(pts, cols, uvs, tex)


class _AnimNode extends Node2D:
	## Animated pieces (sprite sheets) and clip animations (per-frame shape
	## transforms, e.g. water glints). One clock; redrawn only when a frame of
	## an instance in view changes (instances out of view keep their frame
	## until they come into view). Ambient animation: Off = static, Reduced =
	## every third instance at half speed, Full = all.
	##
	## A clip element's colour transform is mul (multiplier) and add (rgb term):
	## the normal pass draws texture * mul, the child `add_pass` (additive
	## blend) adds add * alpha, which together give (texture * mul + add) over
	## the ground (unclamped; the add passes of all instances follow their
	## normal passes).
	var sheets: Array = []   ## {tex, at, origin, scale, flip, frames, columns, fps, fs, overlay, index, bounds}
	var clips: Array = []    ## {clip: {fps, frames, bounds}, xform, shapes, index, bounds, mul, add}
	var mode: int = ObjectRenderer.Ambient.FULL
	var clock := 0.0
	var redraws := 0
	var add_pass: _Canvas
	var has_add := false     ## some clip element or instance has an add term
	var _shown := {}         ## instance key -> frame drawn last
	var _view := Rect2()     ## world rect seen at the last advance (empty = all)

	func _init() -> void:
		add_pass = _Canvas.new()
		add_pass.name = "AddPass"
		add_pass.painter = func(c: CanvasItem) -> void: _paint_clips(c, true)
		var m := ShaderMaterial.new()
		m.shader = Shader.new()
		m.shader.code = PackTerrainLayer.CLIP_ADD_SHADER_CODE
		add_pass.material = m
		add_child(add_pass)

	func has_work() -> bool:
		return not sheets.is_empty() or not clips.is_empty()

	func set_mode(m: int) -> void:
		mode = m
		set_process(has_work() and mode != ObjectRenderer.Ambient.OFF)
		_redraw()

	func _redraw() -> void:
		queue_redraw()
		if has_add:
			add_pass.queue_redraw()

	func _animates(index: int) -> bool:
		return mode == ObjectRenderer.Ambient.FULL or (mode == ObjectRenderer.Ambient.REDUCED and posmod(index, 3) == 0)

	func frame_of(fps: float, frames: int, index: int) -> int:
		## Frame shown now (-1 = the static look).
		if frames < 2 or not _animates(index):
			return -1
		var f := fps * (0.5 if mode == ObjectRenderer.Ambient.REDUCED else 1.0)
		return (floori(clock * f) + posmod(index * 7, frames)) % frames

	func animating_in(view: Rect2) -> int:
		## Instances that animate in this world rect (Ambient mode applied).
		if mode == ObjectRenderer.Ambient.OFF:
			return 0
		var n := 0
		for s in sheets:
			if (s["bounds"] as Rect2).intersects(view) and int(s["frames"]) > 1 and _animates(s["index"]):
				n += 1
		for c in clips:
			if (c["bounds"] as Rect2).intersects(view) and (c["clip"]["frames"] as Array).size() > 1 and _animates(c["index"]):
				n += 1
		return n

	func advance(dt: float, view: Rect2) -> bool:
		## Moves the clock; true when something in view changed (a redraw was queued).
		if mode == ObjectRenderer.Ambient.OFF:
			return false
		clock += dt
		_view = view
		var changed := false
		for i in sheets.size():
			var s: Dictionary = sheets[i]
			if not (s["bounds"] as Rect2).intersects(view):
				continue
			var f := frame_of(s["fps"], s["frames"], s["index"])
			if _shown.get("s%d" % i, -2) != f:
				changed = true
				break
		if not changed:
			for i in clips.size():
				var c: Dictionary = clips[i]
				if not (c["bounds"] as Rect2).intersects(view):
					continue
				var f := frame_of(float(c["clip"]["fps"]), (c["clip"]["frames"] as Array).size(), c["index"])
				if _shown.get("c%d" % i, -2) != f:
					changed = true
					break
		if changed:
			_redraw()
		return changed

	func _process(dt: float) -> void:
		advance(dt, get_canvas_transform().affine_inverse() * get_viewport_rect())

	func _shown_frame(key: String, now: int, bounds: Rect2) -> int:
		## The frame to draw: the current one in view, the last drawn one out of
		## view (it is not animated while nobody sees it).
		if _view.size == Vector2.ZERO or bounds.intersects(_view) or not _shown.has(key):
			_shown[key] = now
			return now
		return _shown[key]

	func _draw() -> void:
		redraws += 1
		for i in sheets.size():
			var s: Dictionary = sheets[i]
			var f := _shown_frame("s%d" % i, frame_of(s["fps"], s["frames"], s["index"]), s["bounds"])
			if f < 0:
				if bool(s["overlay"]):
					continue   # the static image is the piece itself
				f = 0
			var fs: Vector2 = s["fs"]
			var src := Rect2(Vector2(f % int(s["columns"]), f / int(s["columns"])) * fs, fs)
			var sc: float = s["scale"]
			draw_set_transform(s["at"], 0.0, Vector2(-1, 1) if bool(s["flip"]) else Vector2.ONE)
			draw_texture_rect_region(s["tex"], Rect2(-(s["origin"] as Vector2) * sc, fs * sc), src, s["mod"])
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		_paint_clips(self, false)

	func _paint_clips(ci: CanvasItem, adding: bool) -> void:
		for i in clips.size():
			var c: Dictionary = clips[i]
			var frames: Array = c["clip"]["frames"]
			var key := "c%d" % i
			var f: int = _shown.get(key, -1) if adding else _shown_frame(key, frame_of(float(c["clip"]["fps"]), frames.size(), c["index"]), c["bounds"])
			if f < 0 or f >= frames.size():
				continue   # clips have no static look (their first frame is often empty)
			var xf: Transform2D = c["xform"]
			var imul: Color = c["mul"]
			var iadd: Color = c["add"]
			for el in frames[f]:
				if not el is Dictionary:
					continue
				var sh: Dictionary = (c["shapes"] as Dictionary).get(str(el.get("shape", "")), {})
				var m: Variant = el.get("m", null)
				if sh.is_empty() or not m is Array or (m as Array).size() != 6:
					continue
				var col := _rgba(el.get("mul", null), Color.WHITE)
				# Instance over element: mul = mi * me, add = ae * mi + ai (rgb).
				var add := _rgba(el.get("add", null), Color(0, 0, 0, 0))
				add = Color(add.r * imul.r + iadd.r, add.g * imul.g + iadd.g, add.b * imul.b + iadd.b, 0.0)
				col = col * imul
				if adding and add.r + add.g + add.b <= 0.0:
					continue
				ci.draw_set_transform_matrix(xf * Transform2D(Vector2(float(m[0]), float(m[1])), Vector2(float(m[2]), float(m[3])), Vector2(float(m[4]), float(m[5]))))
				ci.draw_polygon(sh["pts"], PackedColorArray([Color(add.r, add.g, add.b, col.a) if adding else col]), sh["uvs"], sh["tex"])
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	static func _rgba(v: Variant, dflt: Color) -> Color:
		if v is Array and (v as Array).size() >= 3:
			return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if (v as Array).size() > 3 else dflt.a)
		return dflt


func _init() -> void:
	_tiles = _Canvas.new()
	_tiles.name = "Tiles"
	_tiles.painter = _paint_tiles
	add_child(_tiles)
	_pieces = Node2D.new()
	_pieces.name = "Pieces"
	add_child(_pieces)
	_anim = _AnimNode.new()
	_anim.name = "Anim"
	_anim.set_process(false)
	add_child(_anim)
	foreground = Node2D.new()
	foreground.name = "PackForeground"
	_fg_pieces = Node2D.new()
	_fg_pieces.name = "Pieces"
	foreground.add_child(_fg_pieces)
	_fg_anim = _AnimNode.new()
	_fg_anim.name = "Anim"
	_fg_anim.set_process(false)
	foreground.add_child(_fg_anim)
	add_child(foreground)
	for n: CanvasItem in [_tiles, _pieces, _anim, _fg_pieces, _fg_anim]:
		n.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_pieces.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_fg_pieces.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func _notification(what: int) -> void:
	# The foreground lives elsewhere once attached: it goes with this layer.
	if what == NOTIFICATION_PREDELETE and is_instance_valid(foreground) and foreground.get_parent() != self:
		if foreground.get_parent():
			foreground.get_parent().remove_child(foreground)
		foreground.free()


func attach_foreground(parent: Node, index: int = -1) -> void:
	## Moves the foreground pieces under `parent` (main.gd: the world node,
	## right after the object renderer), so they draw over the objects.
	if foreground.get_parent() == parent:
		return
	if foreground.get_parent():
		foreground.get_parent().remove_child(foreground)
	parent.add_child(foreground)
	if index >= 0:
		parent.move_child(foreground, index)


func active() -> bool:
	return pack != null and map != null


func setup(m: FarmMap, tp: TerrainPack, lib: AssetLibrary, open_plots: PackedByteArray, theme_id: String) -> void:
	## Cheap when nothing changed: compares map / pack / variant / ownership.
	var v := tp.variant_for(theme_id) if tp else ""
	if m != map or tp != pack or lib != assets or v != variant or (tp != null and lib == null):
		if m != map or tp != pack or lib != assets:
			_tile_cache.clear()
		map = m
		pack = tp if lib != null else null
		assets = lib
		variant = v
		_open = PackedByteArray([255])
		var old := extent
		_build_pieces()
		if extent != old:
			extent_changed.emit()
	if open_plots != _open:
		_open = open_plots.duplicate()
		_build_tiles(open_plots)


func set_ambient_mode(mode: int) -> void:
	ambient = mode
	_anim.set_mode(mode)
	_fg_anim.set_mode(mode)


func covers(t: Vector2i) -> bool:
	if covered.is_empty() or not cover_rect.has_point(t):
		return false
	var p := t - cover_rect.position
	return covered[p.y * cover_rect.size.x + p.x] == 1


func draws_land_edge() -> bool:
	## GroundLayer's soil edge along the land: off when the pack says its own art has it.
	return pack == null or pack.land_edge or not backdrop_ok


func anim_node() -> Node2D:
	return _anim


func foreground_anim_node() -> Node2D:
	return _fg_anim


func camera_rect(m: FarmMap, world_rect: Rect2) -> Rect2:
	## Camera bounds for map m (world px). Without pack pieces: world_rect. A
	## pack that replaces the terrain (base "color") is framed by its pieces
	## (+ CAMERA_MARGIN) and the placement grid and landmarks (always
	## reachable); the iso diamond of world_bounds overshoots its art far into
	## the background colour. Over the procedural terrain: the union of both.
	if not active() or m != map or extent.size == Vector2.ZERO:
		return world_rect
	var r := extent.grow(CAMERA_MARGIN)
	if pack.base != "color" or not backdrop_ok:
		return world_rect.merge(r)
	r = r.merge(Iso.footprint_world_bounds(Vector2i.ZERO, m.size))
	for lm in m.landmarks:
		r = r.merge(Iso.footprint_world_bounds(lm.origin, lm.footprint))
	return r


# --- ground tiles -------------------------------------------------------------------

func _texture_of(atlas: String, file: String) -> Texture2D:
	var rel := file
	if not atlas.is_empty():
		rel = str((pack.atlases.get(atlas, {}) as Dictionary).get("file", ""))
	return assets.terrain_texture(pack, rel) if assets else null


func _build_tiles(open_plots: PackedByteArray) -> void:
	var t0 := Time.get_ticks_usec()
	_batches = []
	covered = PackedByteArray()
	cover_rect = Rect2i()
	_bg_poly = PackedVector2Array()
	stats["tiles"] = 0
	stats["tile_batches"] = 0
	tiles_version += 1
	if not active():
		_tiles.queue_redraw()
		last_tiles_usec = Time.get_ticks_usec() - t0
		return
	# A season / ownership state seen before: its triangles are cached (a
	# theme switch back and forth only swaps arrays).
	var ck := variant
	var hit: Dictionary = _tile_cache.get(ck, {})
	if not hit.is_empty() and hit["open"] == open_plots:
		_batches = hit["batches"]
		covered = hit["covered"]
		cover_rect = hit["rect"]
		_bg_poly = hit["bg_poly"]
		_bg_color = hit["bg_color"]
		stats["tiles"] = hit["tiles"]
		stats["tile_batches"] = _batches.size()
		_tiles.queue_redraw()
		last_tiles_usec = Time.get_ticks_usec() - t0
		return
	if pack.base == "color":
		var wb := map.world_bounds if map.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, map.size)
		var bb := _poly_bounds(Iso.grid_rect_polygon(wb.grow(BACKDROP_MARGIN))).grow(BACKDROP_PAD_PX)
		_bg_poly = PackedVector2Array([bb.position, Vector2(bb.end.x, bb.position.y), bb.end, Vector2(bb.position.x, bb.end.y)])
		var bc: Variant = pack.background_for(variant)
		_bg_color = bc if bc is Color else DEFAULT_BACKGROUND
	var ga := pack.ground_art(map, open_plots)
	var keys: Array[String] = ga["keys"]
	var ids: PackedInt32Array = ga["ids"]
	cover_rect = ga["rect"]
	# Art key -> [batch index, uv rect] (null = no texture: not covered).
	var res: Array = []
	var batch_of := {}
	for k in keys:
		var spec := pack.tile_spec(k, variant)
		if spec.is_empty():
			pack.report("no tile texture for art '%s' (drawn by the built-in ground instead)" % k)
			res.append(null)
			continue
		var tex := _texture_of(spec["atlas"], spec["file"])
		if tex == null:
			res.append(null)
			continue
		var ts := tex.get_size()
		var r: Rect2i = spec["rect"]
		if r.size == Vector2i.ZERO:
			r = Rect2i(Vector2i.ZERO, Vector2i(ts))
		var inset := minf(TILE_INSET, r.size.x * 0.25)
		var uv := Rect2((Vector2(r.position) + Vector2(inset, inset)) / ts, (Vector2(r.size) - Vector2(inset, inset) * 2.0) / ts)
		if not batch_of.has(tex):
			batch_of[tex] = _batches.size()
			_batches.append([tex, PackedInt32Array(), PackedVector2Array(), PackedColorArray(), PackedVector2Array()])
		res.append([batch_of[tex], uv])
	# Per batch (usually one atlas): count, then fill pre-sized local arrays.
	# (Packed arrays held in an Array are copies when read back, so each batch
	# is filled locally and stored once.)
	var counts := PackedInt32Array()
	counts.resize(_batches.size())
	covered.resize(ids.size())
	covered.fill(0)
	var batch_id := PackedInt32Array()
	batch_id.resize(ids.size())
	batch_id.fill(-1)
	for i in ids.size():
		var k := ids[i]
		if k >= 0 and res[k] != null:
			var bk: int = res[k][0]
			counts[bk] += 1
			covered[i] = 1
			batch_id[i] = bk
	var w := cover_rect.size.x
	var x0 := cover_rect.position.x
	var y0 := cover_rect.position.y
	var total := 0
	var right := Vector2(Iso.HALF_W, Iso.HALF_H)
	var bottom := Vector2(0.0, Iso.TILE_H)
	var left := Vector2(-Iso.HALF_W, Iso.HALF_H)
	for bi in _batches.size():
		var n := counts[bi]
		var idx := PackedInt32Array()
		var pts := PackedVector2Array()
		var cols := PackedColorArray()
		var uvs := PackedVector2Array()
		idx.resize(n * 6)
		pts.resize(n * 4)
		cols.resize(n * 4)
		cols.fill(Color.WHITE)
		uvs.resize(n * 4)
		var q := 0
		for i in ids.size():
			if batch_id[i] != bi:
				continue
			var uv: Rect2 = res[ids[i]][1]
			var x := float(x0 + i % w)
			var y := float(y0 + i / w)
			var v := q * 4
			var top := Vector2((x - y) * Iso.HALF_W, (x + y) * Iso.HALF_H)
			pts[v] = top
			pts[v + 1] = top + right
			pts[v + 2] = top + bottom
			pts[v + 3] = top + left
			# u runs along +x, v along +y (top, right, bottom, left corners).
			uvs[v] = uv.position
			uvs[v + 1] = Vector2(uv.end.x, uv.position.y)
			uvs[v + 2] = uv.end
			uvs[v + 3] = Vector2(uv.position.x, uv.end.y)
			var j := q * 6
			idx[j] = v
			idx[j + 1] = v + 1
			idx[j + 2] = v + 2
			idx[j + 3] = v
			idx[j + 4] = v + 2
			idx[j + 5] = v + 3
			q += 1
		_batches[bi] = [_batches[bi][0], idx, pts, cols, uvs]
		total += q
	stats["tiles"] = total
	stats["tile_batches"] = _batches.size()
	_tile_cache[ck] = {"open": open_plots.duplicate(), "batches": _batches, "covered": covered, "rect": cover_rect,
		"bg_poly": _bg_poly, "bg_color": _bg_color, "tiles": total}
	_tiles.queue_redraw()
	last_tiles_usec = Time.get_ticks_usec() - t0


static func _poly_bounds(pts: PackedVector2Array) -> Rect2:
	var r := Rect2(pts[0], Vector2.ZERO)
	for q in pts:
		r = r.expand(q)
	return r


func _paint_tiles(c: CanvasItem) -> void:
	var ci := c.get_canvas_item()
	if _bg_poly.size() == 4:
		RenderingServer.canvas_item_add_polygon(ci, _bg_poly, PackedColorArray([_bg_color, _bg_color, _bg_color, _bg_color]))
	for b in _batches:
		if (b[1] as PackedInt32Array).is_empty():
			continue
		RenderingServer.canvas_item_add_triangle_array(ci, b[1], b[2], b[3], b[4], PackedInt32Array(), PackedFloat32Array(), (b[0] as Texture2D).get_rid())


# --- pieces -------------------------------------------------------------------------

func _build_pieces() -> void:
	var t0 := Time.get_ticks_usec()
	for holder in [_pieces, _fg_pieces]:
		for c in holder.get_children():
			holder.remove_child(c)
			c.queue_free()
	for a: _AnimNode in [_anim, _fg_anim]:
		a.sheets.clear()
		a.clips.clear()
		a.has_add = false
	failed_pieces = 0
	backdrop_ok = false
	extent = Rect2()
	var verts := 0
	var blended := 0
	if active():
		var clips_data := _clips() if not pack.clips_file.is_empty() else {}
		var n := 0
		for p in pack.pieces_for(variant):
			var fg := str(p.get("layer", "ground")) == "foreground"
			var anim: _AnimNode = _fg_anim if fg else _anim
			var node := _make_piece(p, anim)
			if node == null:
				failed_pieces += 1
				continue
			node.name = "%s_%d" % [str(p["id"]).validate_node_name(), n]
			n += 1
			(_fg_pieces if fg else _pieces).add_child(node)
			if node.mesh:
				verts += node.mesh.surface_get_array_len(0)
			if str(p.get("blend", "normal")) != "normal":
				blended += 1
			_grow_extent(node.local_bounds(), p["at"])
			for c in p["clips"]:
				var clip: Variant = (clips_data.get("clips", {}) as Dictionary).get(c["clip"], null)
				if clip == null:
					pack.report("piece '%s' uses unknown clip '%s'" % [p["id"], c["clip"]])
					continue
				var xf := Transform2D(0.0, p["at"]) * (c["xform"] as Transform2D)
				var cb: Rect2 = clip["bounds"]
				var bounds := xf * cb if cb.size != Vector2.ZERO else Rect2(xf.origin, Vector2.ZERO)
				anim.clips.append({"clip": clip, "xform": xf, "shapes": clips_data["shapes"], "index": anim.clips.size(),
					"bounds": bounds, "mul": c.get("mul", Color.WHITE), "add": c.get("add", Color(0, 0, 0, 0))})
				var ia: Color = c.get("add", Color(0, 0, 0, 0))
				if bool(clip.get("has_add", false)) or ia.r + ia.g + ia.b > 0.0:
					anim.has_add = true
				_grow_extent(bounds, Vector2.ZERO)
		for a: _AnimNode in [_anim, _fg_anim]:
			for s in a.sheets:
				_grow_extent(s["bounds"], Vector2.ZERO)
		backdrop_ok = pack.base == "color" and failed_pieces == 0
	stats["pieces"] = _pieces.get_child_count() + _fg_pieces.get_child_count()
	stats["foreground"] = _fg_pieces.get_child_count()
	stats["vertices"] = verts
	stats["anims"] = _anim.sheets.size() + _fg_anim.sheets.size()
	stats["clips"] = _anim.clips.size() + _fg_anim.clips.size()
	stats["blended"] = blended
	_anim.set_mode(ambient)
	_fg_anim.set_mode(ambient)
	last_pieces_usec = Time.get_ticks_usec() - t0


func _grow_extent(local: Rect2, at: Vector2) -> void:
	if local.size == Vector2.ZERO:
		return
	var r := Rect2(local.position + at, local.size)
	extent = r if extent.size == Vector2.ZERO else extent.merge(r)


func _make_piece(p: Dictionary, anim: _AnimNode) -> _PieceNode:
	var node := _PieceNode.new()
	node.piece = p
	node.position = p["at"]
	var has_add := false
	match str(p["type"]):
		"image":
			var has_tex := not str(p["atlas"]).is_empty() or not str(p["file"]).is_empty()
			if has_tex:
				node.tex = _texture_of(p["atlas"], p["file"])
				if node.tex == null:
					node.free()
					return null
				var r: Rect2i = p["rect"]
				node.region = Rect2(r) if r.size != Vector2i.ZERO else Rect2(Vector2.ZERO, node.tex.get_size())
			if p.has("anim"):
				var a: Dictionary = p["anim"]
				var sheet := assets.terrain_texture(pack, a["sheet"])
				if sheet == null:
					if not has_tex:
						node.free()
						return null
				else:
					var fs: Vector2 = a["frame_size"]
					if fs == Vector2.ZERO:
						var rows := ceili(float(a["frames"]) / float(a["columns"]))
						fs = Vector2(sheet.get_width() / float(a["columns"]), sheet.get_height() / float(rows))
					var sc: float = p["scale"]
					var at: Vector2 = p["at"]
					var o: Vector2 = p["origin"]
					anim.sheets.append({"tex": sheet, "at": at, "origin": o, "scale": sc, "flip": p["flip_h"],
						"frames": int(a["frames"]), "columns": int(a["columns"]), "fps": float(a["fps"]), "fs": fs,
						"overlay": bool(a["overlay"]), "mod": p["modulate"], "index": anim.sheets.size(),
						"bounds": Rect2(at - o * sc, fs * sc).abs()})
		"mesh":
			var md := _mesh(p["mesh"])
			if md.is_empty():
				node.free()
				return null
			node.mesh = md["mesh"]
			node.tex = md["tex"]
			has_add = bool(md["add"])
		"polygon":
			if not str(p["texture_file"]).is_empty():
				node.tex = assets.terrain_texture(pack, p["texture_file"])
				if node.tex == null:
					node.free()
					return null
				if float(p["uv_world"]) <= 0.0:
					p["uv_world"] = node.tex.get_width() / pack.pixels_per_world_px
	node.material = material_for(str(p.get("blend", "normal")), has_add)
	return node


static func material_for(blend: String, has_add: bool) -> Material:
	## Material of a piece: null for plain normal blend, else a canvas shader
	## for the blend mode (add, screen, multiply) and/or the colour-add term of
	## a mesh (vertex CUSTOM0.rgb). Shared, built once per combination.
	if blend == "normal" and not has_add:
		return null
	var key := "%s:%s" % [blend, str(has_add)]
	if not _materials.has(key):
		var sh := Shader.new()
		sh.code = shader_code(blend, has_add)
		var m := ShaderMaterial.new()
		m.shader = sh
		_materials[key] = m
	return _materials[key]


static func shader_code(blend: String, has_add: bool) -> String:
	## Godot's fragment COLOR already holds texture * vertex colour, so the
	## shader rebuilds it from the texture and the vertex colour (a varying):
	##   c = (texture.rgb * mul.rgb + add, texture.a * mul.a)   (straight alpha)
	## normal: mix; add: dst + c.rgb * c.a; multiply: dst * mix(1, c.rgb, c.a);
	## screen: mix(dst, 1 - (1 - c.rgb) * (1 - dst), c.a) (reads the screen
	## behind it, i.e. what was drawn before in this frame's canvas).
	var mode: String = {"add": "blend_add", "multiply": "blend_mul"}.get(blend, "blend_mix")
	var code := "shader_type canvas_item;\nrender_mode %s;\n" % mode
	if blend == "screen":
		code += "uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;\n"
	code += "varying vec4 mul;\nvarying vec3 add_rgb;\n"
	code += "void vertex() { mul = COLOR; add_rgb = %s; }\n" % ("CUSTOM0.rgb" if has_add else "vec3(0.0)")
	code += "void fragment() {\n\tvec4 t = texture(TEXTURE, UV);\n"
	code += "\tvec4 c = vec4(clamp(t.rgb * mul.rgb + add_rgb, 0.0, 1.0), t.a * mul.a);\n"
	match blend:
		"multiply":
			code += "\tCOLOR = vec4(mix(vec3(1.0), c.rgb, c.a), 1.0);\n"
		"screen":
			code += "\tvec3 d = texture(screen_tex, SCREEN_UV).rgb;\n\tCOLOR = vec4(1.0 - (1.0 - c.rgb) * (1.0 - d), c.a);\n"
		_:
			code += "\tCOLOR = c;\n"
	return code + "}\n"


func _mesh(rel: String) -> Dictionary:
	## {"mesh": ArrayMesh, "tex": Texture2D, "add": bool} from a mesh JSON
	## (positions / uvs / colors / indices / add_ops, see the docs), cached in
	## the pack; {} when it can't be used (reported).
	var key := "mesh:" + rel
	if pack.cache.has(key):
		return pack.cache[key]
	var out := {}
	var d: Variant = JsonUtil.read_json(pack.base_dir.path_join(rel))
	var why := ""
	if not d is Dictionary:
		why = "missing or not a JSON object"
	else:
		var tex := _texture_of(str(d.get("atlas", "")), str(d.get("texture", "")))
		var pos: Variant = d.get("positions", [])
		var uv: Variant = d.get("uvs", [])
		var col: Variant = d.get("colors", [])
		var ind: Variant = d.get("indices", [])
		if tex == null:
			why = "no usable atlas/texture"
		elif not (pos is Array and uv is Array and col is Array and ind is Array):
			why = "positions, uvs, colors and indices must be lists"
		elif (pos as Array).size() % 2 != 0 or (pos as Array).size() < 6 or (uv as Array).size() != (pos as Array).size():
			why = "positions and uvs need the same even number of values (x, y pairs)"
		elif not (col as Array).is_empty() and (col as Array).size() != (pos as Array).size() * 2:
			why = "colors need 4 values per vertex (or none)"
		elif (ind as Array).size() % 3 != 0 or (ind as Array).is_empty():
			why = "indices must be triangles (a multiple of 3)"
		else:
			var n := (pos as Array).size() / 2
			var pf := PackedFloat32Array(pos)
			var uf := PackedFloat32Array(uv)
			var pts := PackedVector2Array()
			var uvs := PackedVector2Array()
			pts.resize(n)
			uvs.resize(n)
			for i in n:
				pts[i] = Vector2(pf[2 * i], pf[2 * i + 1])
				uvs[i] = Vector2(uf[2 * i], uf[2 * i + 1])
			var idx := PackedInt32Array(ind)
			for i in idx:
				if i < 0 or i >= n:
					why = "an index is out of range"
					break
			if why.is_empty():
				var arr := []
				arr.resize(Mesh.ARRAY_MAX)
				arr[Mesh.ARRAY_VERTEX] = pts
				arr[Mesh.ARRAY_TEX_UV] = uvs
				arr[Mesh.ARRAY_INDEX] = idx
				var cols := PackedColorArray()
				cols.resize(n)
				if (col as Array).is_empty():
					cols.fill(Color.WHITE)
				else:
					var cf := PackedFloat32Array(col)
					for i in n:
						cols[i] = Color(cf[4 * i], cf[4 * i + 1], cf[4 * i + 2], cf[4 * i + 3])
				arr[Mesh.ARRAY_COLOR] = cols
				var flags := 0
				var ops: Variant = d.get("add_ops", [])
				var has_add := false
				if ops is Array and not (ops as Array).is_empty():
					var add := PackedFloat32Array()
					add.resize(n * 4)
					for op in ops:
						if not op is Dictionary or not op.get("add_rgb") is Array:
							continue
						var a: Array = op["add_rgb"]
						var first := int(op.get("first_index", 0))
						var cnt := int(op.get("index_count", 0))
						for j in range(maxi(first, 0), mini(first + cnt, idx.size())):
							var vi := idx[j]
							add[4 * vi] = float(a[0])
							add[4 * vi + 1] = float(a[1])
							add[4 * vi + 2] = float(a[2])
							has_add = true
					if has_add:
						arr[Mesh.ARRAY_CUSTOM0] = add
						flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
				var am := ArrayMesh.new()
				am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, flags)
				out = {"mesh": am, "tex": tex, "add": has_add}
	if not why.is_empty():
		pack.report("mesh %s: %s" % [rel, why])
	pack.cache[key] = out
	return out


func _clips() -> Dictionary:
	## {"shapes": {id: {pts, uvs, tex}}, "clips": {name: {fps, frames}}} from
	## the pack's clips file (cached; {} when unusable, reported).
	if pack.cache.has("clips"):
		return pack.cache["clips"]
	var out := {}
	var d: Variant = JsonUtil.read_json(pack.base_dir.path_join(pack.clips_file))
	if not d is Dictionary or not d.get("shapes") is Dictionary or not d.get("clips") is Dictionary:
		pack.report("clips file %s is missing or has no shapes/clips" % pack.clips_file)
	else:
		var shapes := {}
		for sid in d["shapes"]:
			var s: Variant = d["shapes"][sid]
			if not s is Dictionary:
				continue
			var tex := _texture_of(str(s.get("atlas", "")), str(s.get("texture", "")))
			var pts := PackedVector2Array()
			var uvs := PackedVector2Array()
			for q in s.get("polygon_world", []):
				pts.append(Vector2(float(q[0]), float(q[1])))
			for q in s.get("uv", []):
				uvs.append(Vector2(float(q[0]), float(q[1])))
			if tex == null or pts.size() < 3 or uvs.size() != pts.size():
				pack.report("clip shape '%s' is unusable (texture, or polygon/uv sizes)" % str(sid))
				continue
			shapes[str(sid)] = {"pts": pts, "uvs": uvs, "tex": tex}
		var clips := {}
		for cid in d["clips"]:
			var c: Variant = d["clips"][cid]
			if c is Dictionary and c.get("frames") is Array and not (c["frames"] as Array).is_empty():
				clips[str(cid)] = _clip_info(c, shapes)
		out = {"shapes": shapes, "clips": clips}
	pack.cache["clips"] = out
	return out


static func _clip_info(c: Dictionary, shapes: Dictionary) -> Dictionary:
	## {fps, frames, bounds (clip-local world px over every frame), has_add}.
	var bounds := Rect2()
	var has_add := false
	for fr in c["frames"]:
		if not fr is Array:
			continue
		for el in fr:
			if not el is Dictionary:
				continue
			var a: Variant = el.get("add", null)
			if a is Array and (a as Array).size() >= 3 and float(a[0]) + float(a[1]) + float(a[2]) > 0.0:
				has_add = true
			var sh: Dictionary = shapes.get(str(el.get("shape", "")), {})
			var m: Variant = el.get("m", null)
			if sh.is_empty() or not m is Array or (m as Array).size() != 6:
				continue
			var xf := Transform2D(Vector2(float(m[0]), float(m[1])), Vector2(float(m[2]), float(m[3])), Vector2(float(m[4]), float(m[5])))
			var r := xf * _poly_bounds(sh["pts"])
			bounds = r if bounds.size == Vector2.ZERO else bounds.merge(r)
	return {"fps": float(c.get("fps", 30)), "frames": c["frames"], "bounds": bounds, "has_add": has_add}

