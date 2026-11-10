class_name PackTerrainLayer
extends Node2D
## Terrain art from an asset pack (TerrainPack, docs/TERRAIN_PACKS.md). A child
## of GroundLayer drawn behind it, after the procedural TerrainLayer:
##   background colour (base "color") -> ground tiles -> pieces (by z) -> animated pieces
## and below every object (the whole ground layer is). Everything is cached:
## the tile triangles are rebuilt only when the map, the theme variant or plot
## ownership changes, the pieces only on a map / variant change, never on a
## camera move. Files load once per pack (TerrainPack.cache / AssetLibrary).
##
## Fallback per element: a tile whose art the pack lacks is not `covered`, so
## GroundLayer / the procedural terrain draw it; a piece that fails to load is
## skipped and keeps `backdrop_ok` false, so the procedural terrain stays
## underneath instead of leaving a hole. Problems go to the pack's diagnostics
## (TerrainPack.errors, listed by the Asset Manager), never to an error dialog.

const BACKDROP_MARGIN := 64      ## tiles of background colour beyond the world bounds
const TILE_INSET := 0.5          ## texels kept off a tile rect's border (no atlas bleeding)
const DEFAULT_BACKGROUND := Color("#5f9a49")
const ADD_SHADER_CODE := """shader_type canvas_item;
// Pack meshes with a colour-transform add term (vertex CUSTOM0.rgb). Godot's
// fragment COLOR already holds texture * vertex colour, so rebuild it.
varying vec3 add_rgb;
varying vec4 mul;
void vertex() { add_rgb = CUSTOM0.rgb; mul = COLOR; }
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	COLOR = vec4(clamp(t.rgb * mul.rgb + add_rgb, 0.0, 1.0), t.a * mul.a);
}
"""

static var _add_material: ShaderMaterial

var pack: TerrainPack
var assets: AssetLibrary
var map: FarmMap
var variant := ""
var ambient: int = ObjectRenderer.Ambient.FULL
var cover_rect := Rect2i()
var covered := PackedByteArray()  ## per tile of cover_rect: 1 = the pack draws that tile's ground
var backdrop_ok := false          ## base "color" and every piece loaded: the procedural terrain may hide
var failed_pieces := 0
var stats := {"tiles": 0, "tile_batches": 0, "pieces": 0, "vertices": 0, "anims": 0, "clips": 0}
var last_tiles_usec := 0
var last_pieces_usec := 0
var tiles_version := 0            ## bumped whenever `covered` is rebuilt

var _tiles: _Canvas
var _pieces: Node2D
var _anim: _AnimNode
var _open := PackedByteArray([255])
var _batches: Array = []          ## [Texture2D, PackedInt32Array, PackedVector2Array, PackedColorArray, PackedVector2Array]
var _bg_poly := PackedVector2Array()
var _bg_color := Color()


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
	## an instance in view changes. Ambient animation: Off = static, Reduced =
	## every third instance at half speed, Full = all.
	var sheets: Array = []   ## {tex, at, origin, scale, flip, frames, columns, fps, fs, overlay, index, bounds}
	var clips: Array = []    ## {clip: {fps, frames}, xform, shapes, index, bounds}
	var mode: int = ObjectRenderer.Ambient.FULL
	var clock := 0.0
	var redraws := 0
	var _shown := {}         ## instance key -> frame drawn last

	func has_work() -> bool:
		return not sheets.is_empty() or not clips.is_empty()

	func set_mode(m: int) -> void:
		mode = m
		set_process(has_work() and mode != ObjectRenderer.Ambient.OFF)
		queue_redraw()

	func _animates(index: int) -> bool:
		return mode == ObjectRenderer.Ambient.FULL or (mode == ObjectRenderer.Ambient.REDUCED and posmod(index, 3) == 0)

	func frame_of(fps: float, frames: int, index: int) -> int:
		## Frame shown now (-1 = the static look).
		if frames < 2 or not _animates(index):
			return -1
		var f := fps * (0.5 if mode == ObjectRenderer.Ambient.REDUCED else 1.0)
		return (floori(clock * f) + posmod(index * 7, frames)) % frames

	func advance(dt: float, view: Rect2) -> bool:
		## Moves the clock; true when something in view changed (a redraw was queued).
		if mode == ObjectRenderer.Ambient.OFF:
			return false
		clock += dt
		var changed := false
		for i in sheets.size():
			var s: Dictionary = sheets[i]
			if not (s["bounds"] as Rect2).intersects(view):
				continue
			var f := frame_of(s["fps"], s["frames"], s["index"])
			if _shown.get("s%d" % i, -2) != f:
				changed = true
		for i in clips.size():
			var c: Dictionary = clips[i]
			if not (c["bounds"] as Rect2).intersects(view):
				continue
			var f := frame_of(float(c["clip"]["fps"]), (c["clip"]["frames"] as Array).size(), c["index"])
			if _shown.get("c%d" % i, -2) != f:
				changed = true
		if changed:
			queue_redraw()
		return changed

	func _process(dt: float) -> void:
		advance(dt, get_canvas_transform().affine_inverse() * get_viewport_rect())

	func _draw() -> void:
		redraws += 1
		for i in sheets.size():
			var s: Dictionary = sheets[i]
			var f := frame_of(s["fps"], s["frames"], s["index"])
			_shown["s%d" % i] = f
			if f < 0:
				if bool(s["overlay"]):
					continue   # the static image is the piece itself
				f = 0
			var fs: Vector2 = s["fs"]
			var src := Rect2(Vector2(f % int(s["columns"]), f / int(s["columns"])) * fs, fs)
			var sc: float = s["scale"]
			draw_set_transform(s["at"], 0.0, Vector2(-1, 1) if bool(s["flip"]) else Vector2.ONE)
			draw_texture_rect_region(s["tex"], Rect2(-(s["origin"] as Vector2) * sc, fs * sc), src, s["mod"])
		for i in clips.size():
			var c: Dictionary = clips[i]
			var frames: Array = c["clip"]["frames"]
			var f := frame_of(float(c["clip"]["fps"]), frames.size(), c["index"])
			_shown["c%d" % i] = f
			if f < 0:
				continue   # clips have no static look (their first frame is often empty)
			var xf: Transform2D = c["xform"]
			for el in frames[f]:
				if not el is Dictionary:
					continue
				var sh: Dictionary = (c["shapes"] as Dictionary).get(str(el.get("shape", "")), {})
				var m: Variant = el.get("m", null)
				if sh.is_empty() or not m is Array or (m as Array).size() != 6:
					continue
				var mul: Variant = el.get("mul", [1, 1, 1, 1])
				var col := Color(float(mul[0]), float(mul[1]), float(mul[2]), float(mul[3])) if mul is Array and (mul as Array).size() == 4 else Color.WHITE
				draw_set_transform_matrix(xf * Transform2D(Vector2(float(m[0]), float(m[1])), Vector2(float(m[2]), float(m[3])), Vector2(float(m[4]), float(m[5]))))
				draw_polygon(sh["pts"], PackedColorArray([col]), sh["uvs"], sh["tex"])
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
	for n: CanvasItem in [_tiles, _pieces, _anim]:
		n.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_pieces.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func active() -> bool:
	return pack != null and map != null


func setup(m: FarmMap, tp: TerrainPack, lib: AssetLibrary, open_plots: PackedByteArray, theme_id: String) -> void:
	## Cheap when nothing changed: compares map / pack / variant / ownership.
	var v := tp.variant_for(theme_id) if tp else ""
	if m != map or tp != pack or lib != assets or v != variant or (tp != null and lib == null):
		map = m
		pack = tp if lib != null else null
		assets = lib
		variant = v
		_open = PackedByteArray([255])
		_build_pieces()
	if open_plots != _open:
		_open = open_plots.duplicate()
		_build_tiles(open_plots)


func set_ambient_mode(mode: int) -> void:
	ambient = mode
	_anim.set_mode(mode)


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


# --- ground tiles -------------------------------------------------------------------

func _texture_of(atlas: String, file: String) -> Texture2D:
	var rel := file
	if not atlas.is_empty():
		rel = str((pack.atlases.get(atlas, {}) as Dictionary).get("file", ""))
	return assets.terrain_texture(pack, rel) if assets else null


func _build_tiles(open_plots: PackedByteArray) -> void:
	var t0 := Time.get_ticks_usec()
	_batches.clear()
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
	if pack.base == "color":
		var wb := map.world_bounds if map.world_bounds.size != Vector2i.ZERO else Rect2i(Vector2i.ZERO, map.size)
		_bg_poly = Iso.grid_rect_polygon(wb.grow(BACKDROP_MARGIN))
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
	_tiles.queue_redraw()
	last_tiles_usec = Time.get_ticks_usec() - t0


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
	for c in _pieces.get_children():
		_pieces.remove_child(c)
		c.queue_free()
	_anim.sheets.clear()
	_anim.clips.clear()
	failed_pieces = 0
	backdrop_ok = false
	var verts := 0
	if active():
		var clips_data := _clips() if not pack.clips_file.is_empty() else {}
		var n := 0
		for p in pack.pieces_for(variant):
			var node := _make_piece(p)
			if node == null:
				failed_pieces += 1
				continue
			node.name = "%s_%d" % [str(p["id"]).validate_node_name(), n]
			n += 1
			_pieces.add_child(node)
			if node.mesh:
				verts += node.mesh.surface_get_array_len(0)
			for c in p["clips"]:
				var clip: Variant = (clips_data.get("clips", {}) as Dictionary).get(c["clip"], null)
				if clip == null:
					pack.report("piece '%s' uses unknown clip '%s'" % [p["id"], c["clip"]])
					continue
				var xf := Transform2D(0.0, p["at"]) * (c["xform"] as Transform2D)
				_anim.clips.append({"clip": clip, "xform": xf, "shapes": clips_data["shapes"], "index": _anim.clips.size(),
					"bounds": Rect2(xf.origin - Vector2(256, 256), Vector2(512, 512))})
		backdrop_ok = pack.base == "color" and failed_pieces == 0
	stats["pieces"] = _pieces.get_child_count()
	stats["vertices"] = verts
	stats["anims"] = _anim.sheets.size()
	stats["clips"] = _anim.clips.size()
	_anim.set_mode(ambient)
	last_pieces_usec = Time.get_ticks_usec() - t0


func _make_piece(p: Dictionary) -> _PieceNode:
	var node := _PieceNode.new()
	node.piece = p
	node.position = p["at"]
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
					_anim.sheets.append({"tex": sheet, "at": at, "origin": o, "scale": sc, "flip": p["flip_h"],
						"frames": int(a["frames"]), "columns": int(a["columns"]), "fps": float(a["fps"]), "fs": fs,
						"overlay": bool(a["overlay"]), "mod": p["modulate"], "index": _anim.sheets.size(),
						"bounds": Rect2(at - o * sc, fs * sc).abs()})
		"mesh":
			var md := _mesh(p["mesh"])
			if md.is_empty():
				node.free()
				return null
			node.mesh = md["mesh"]
			node.tex = md["tex"]
			if bool(md["add"]):
				node.material = _shader()
		"polygon":
			if not str(p["texture_file"]).is_empty():
				node.tex = assets.terrain_texture(pack, p["texture_file"])
				if node.tex == null:
					node.free()
					return null
				if float(p["uv_world"]) <= 0.0:
					p["uv_world"] = node.tex.get_width() / pack.pixels_per_world_px
	return node


static func _shader() -> ShaderMaterial:
	if _add_material == null:
		var sh := Shader.new()
		sh.code = ADD_SHADER_CODE
		_add_material = ShaderMaterial.new()
		_add_material.shader = sh
	return _add_material


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
				clips[str(cid)] = {"fps": float(c.get("fps", 30)), "frames": c["frames"]}
		out = {"shapes": shapes, "clips": clips}
	pack.cache["clips"] = out
	return out
