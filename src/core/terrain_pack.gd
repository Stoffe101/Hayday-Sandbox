class_name TerrainPack
extends RefCounted
## Data-driven terrain of an asset pack: format "hayday-sandbox-terrain"
## (docs/TERRAIN_PACKS.md). A pack declares it in pack.json ("terrain":
## "terrain/terrain.json") or a world declares it ("terrain" in world.json).
##
## Pure core class: parses and validates the manifest, maps world themes to
## art variants, resolves tile textures (tile_types[].art keys and per-kind
## fallbacks) and expands pieces (edges, cliffs, rivers, roads, water areas,
## animated pieces) into world coordinates. It never loads images: the
## renderer (PackTerrainLayer) does that and keeps what it loaded in `cache`.
## Problems are never fatal: the offending element is skipped (and the
## procedural terrain stays underneath) and a line is added to `errors`
## (element ignored) or `warnings` (questionable but used).

const FORMAT := "hayday-sandbox-terrain"
const SCHEMA_VERSION := 1
const DEFAULT_VARIANT := "default"
const FRAMES := ["game_tile"]
const BASES := ["procedural", "color"]
const PIECE_TYPES := ["image", "mesh", "polygon"]
## Piece layers: "ground" pieces draw under every object (the default; the
## game's background art), "foreground" pieces over the objects (never picked).
const LAYERS := ["ground", "foreground"]
## Piece blend modes (as in Flash / SC: normal, add, screen, multiply).
const BLENDS := ["normal", "add", "screen", "multiply"]
## Flash / SC blend numbers a converter may write instead of a name (0 and 1
## are normal, 2 "layer" composites like normal for a single piece).
const BLEND_NUMBERS := {0: "normal", 1: "normal", 2: "normal", 3: "multiply", 4: "screen", 8: "add"}
## Per-kind tile fallbacks for maps (or tiles) without ground data.
const KIND_TILE_KEYS := ["buildable", "plot", "plot_locked", "road", "blocked", "water", "scenery"]
const MAX_REPEAT := 512
const MAX_PIECES := 4096

var id := ""
var name := ""
var schema_version := 0
var source_path := ""          ## the manifest file ("" = built from data)
var base_dir := ""             ## pack-relative paths resolve against this folder
var pack_id := ""              ## asset pack that provides it ("" = a world file's own terrain)
var frame := "game_tile"
var maps: Array[String] = []   ## map ids it applies to ([] = any map in the game tile frame)
var base := "procedural"       ## "procedural": drawn over our own terrain; "color": replaces it
var scatter := true            ## SceneryLayer may still scatter placeholder trees and rocks
var land_edge := true          ## GroundLayer still draws its soil edge along the land
var alpha_bleed := false       ## images already carry colour under transparent edges
var background_color: Variant = null   ## Color, or null (base "color" then uses a neutral green)
var pixels_per_world_px := 1.0
var atlases: Dictionary = {}   ## atlas id -> {"file": rel}
var tiles: Dictionary = {}     ## art key -> {"atlas", "file", "rect": Rect2i, "variants": {variant: spec}}
var kind_tiles: Dictionary = {}   ## kind word (KIND_TILE_KEYS) -> art key
var themes: Dictionary = {}    ## theme id (lower case) -> variant
var variants: Array[String] = [DEFAULT_VARIANT]
var clips_file := ""           ## pack-relative JSON of clip animations ("" = none)
var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()
## Renderer-owned: loaded textures, meshes, clips (kept with the pack so a
## theme or ownership change never reloads files).
var cache: Dictionary = {}
var _piece_lists: Dictionary = {}   ## variant -> raw piece list (Array of Dictionary)
var _variant_bg: Dictionary = {}    ## variant -> Color
var _format_ok := false


# --- loading -----------------------------------------------------------------------

static func load_file(path: String, owner_pack: String = "") -> TerrainPack:
	var tp := TerrainPack.new()
	tp.source_path = path
	tp.pack_id = owner_pack
	tp.base_dir = path.get_base_dir()
	var data: Variant = JsonUtil.read_json(path)
	if data == null:
		tp.errors.append("terrain: %s is missing or not valid JSON" % path.get_file())
		return tp
	tp.parse(data, tp.base_dir)
	return tp


static func from_data(data: Variant, dir: String = "") -> TerrainPack:
	var tp := TerrainPack.new()
	tp.base_dir = dir
	tp.parse(data, dir)
	return tp


func is_usable() -> bool:
	## The manifest itself is readable (individual elements may still be skipped).
	return _format_ok and schema_version > 0


func parse(data: Variant, dir: String) -> void:
	base_dir = dir
	if not data is Dictionary or str((data as Dictionary).get("format", "")) != FORMAT:
		errors.append("terrain: not a hayday-sandbox-terrain manifest")
		return
	_format_ok = true
	var d: Dictionary = data
	var sv: Variant = d.get("schema_version", 0)
	schema_version = int(sv) if (sv is int or sv is float) else 0
	if schema_version < 1:
		# The research prototype (schema 0) is read the same way; say so once.
		warnings.append("terrain: schema_version %s is a prototype; read as version %d" % [str(sv), SCHEMA_VERSION])
		schema_version = SCHEMA_VERSION
	elif schema_version > SCHEMA_VERSION:
		warnings.append("terrain: schema_version %d is newer than this app (%d); unknown fields are ignored" % [schema_version, SCHEMA_VERSION])
	id = str(d.get("id", source_path.get_base_dir().get_file() if not source_path.is_empty() else "terrain"))
	name = str(d.get("name", id))
	var fr: Variant = d.get("frame", "game_tile")
	frame = str((fr as Dictionary).get("name", "game_tile")) if fr is Dictionary else str(fr)
	if not frame in FRAMES:
		errors.append("terrain: frame '%s' is not supported (only %s)" % [frame, ", ".join(FRAMES)])
	for m in (d.get("maps", []) if d.get("maps", []) is Array else []):
		maps.append(str(m))
	base = str(d.get("base", "procedural"))
	if not base in BASES:
		warnings.append("terrain: unknown base '%s' (procedural used)" % base)
		base = "procedural"
	scatter = _bool(d.get("scatter", base == "procedural"))
	land_edge = _bool(d.get("land_edge", base == "procedural"))
	alpha_bleed = _bool(d.get("alpha_bleed", false))
	if d.has("background_color"):
		background_color = _color(d["background_color"], "background_color")
	var ppw: Variant = d.get("pixels_per_world_px", 1.0)
	pixels_per_world_px = float(ppw) if (ppw is int or ppw is float) and float(ppw) > 0.0 else 1.0
	_parse_atlases(d.get("atlases", {}))
	var tl: Variant = d.get("tiles", d.get("ground", null))
	if tl is String:
		# A separate tile file (the prototype's ground.json keeps "tile_textures" there).
		var rel := safe_rel(str(tl))
		var td: Variant = JsonUtil.read_json(base_dir.path_join(rel)) if not rel.is_empty() else null
		if td is Dictionary:
			tl = (td as Dictionary).get("tiles", (td as Dictionary).get("tile_textures", {}))
		else:
			errors.append("terrain: tile file '%s' is missing or not a JSON object" % str(tl))
			tl = {}
	_parse_tiles(tl)
	_parse_kind_tiles(d.get("kind_tiles", {}))
	# Variants: "variants" {name: {pieces?, background_color?}} and the
	# prototype's "seasons" {name: [pieces]}; the top-level "pieces" are the default.
	var seasons: Variant = d.get("seasons", {})
	if seasons is Dictionary:
		for v in seasons:
			if seasons[v] is Array:
				_add_variant(str(v))
				_piece_lists[str(v)] = seasons[v]
	var vs: Variant = d.get("variants", {})
	if vs is Dictionary:
		for v in vs:
			_add_variant(str(v))
			var vd: Variant = vs[v]
			if not vd is Dictionary:
				errors.append("terrain: variant '%s' is not an object" % str(v))
				continue
			if (vd as Dictionary).get("pieces") is Array:
				_piece_lists[str(v)] = vd["pieces"]
			if (vd as Dictionary).has("background_color"):
				var c: Variant = _color(vd["background_color"], "variants.%s.background_color" % str(v))
				if c != null:
					_variant_bg[str(v)] = c
	elif vs != null:
		errors.append("terrain: variants must be an object")
	if d.get("pieces") is Array:
		_piece_lists[DEFAULT_VARIANT] = d["pieces"]
	elif d.has("pieces"):
		errors.append("terrain: pieces must be a list")
	var th: Variant = d.get("themes", {})
	if th is Dictionary:
		for t in th:
			var v := str(th[t])
			if not v in variants and v != DEFAULT_VARIANT:
				warnings.append("terrain: theme '%s' maps to unknown variant '%s' (default used)" % [str(t), v])
				v = DEFAULT_VARIANT
			themes[str(t).to_lower()] = v
	var cf: Variant = d.get("clips", d.get("water_glints", null))
	if cf is String and not str(cf).is_empty():
		clips_file = safe_rel(str(cf))
		if clips_file.is_empty():
			errors.append("terrain: unsafe clips path '%s' ignored" % str(cf))
	# Validate every piece list once (bad pieces are reported here, skipped later).
	for v in variants:
		var tmp: Array = []
		_expand(_piece_lists.get(v, _piece_lists.get(DEFAULT_VARIANT, [])), v, tmp)
		for e in tmp:
			if not errors.has(e):
				errors.append(e)


func _add_variant(v: String) -> void:
	if not v in variants:
		variants.append(v)


func _parse_atlases(a: Variant) -> void:
	if a == null:
		return
	if not a is Dictionary:
		errors.append("terrain: atlases must be an object")
		return
	for k in a:
		var e: Variant = a[k]
		var f := str((e as Dictionary).get("file", "")) if e is Dictionary else str(e)
		var rel := safe_rel(f)
		if rel.is_empty():
			errors.append("terrain: atlas '%s' has no safe file path" % str(k))
			continue
		atlases[str(k)] = {"file": rel}


func _tex_spec(e: Variant, what: String, errs: Array) -> Dictionary:
	## {"atlas": id, "file": rel, "rect": Rect2i (zero size = whole image)} or {} when unusable.
	if not e is Dictionary:
		errs.append("terrain: %s is not an object" % what)
		return {}
	var out := {"atlas": "", "file": "", "rect": Rect2i()}
	var at := str((e as Dictionary).get("atlas", ""))
	if not at.is_empty():
		if not atlases.has(at):
			errs.append("terrain: %s uses unknown atlas '%s'" % [what, at])
			return {}
		out["atlas"] = at
	elif (e as Dictionary).has("file"):
		var rel := safe_rel(str(e["file"]))
		if rel.is_empty():
			errs.append("terrain: %s has an unsafe file path" % what)
			return {}
		out["file"] = rel
	else:
		errs.append("terrain: %s needs an atlas or a file" % what)
		return {}
	var r: Variant = (e as Dictionary).get("rect_px", (e as Dictionary).get("rect", null))
	if r != null:
		if r is Array and (r as Array).size() == 4 and int(r[2]) > 0 and int(r[3]) > 0:
			out["rect"] = Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3]))
		else:
			errs.append("terrain: %s has a bad rect_px (want [x, y, w, h])" % what)
			return {}
	return out


func _parse_tiles(t: Variant) -> void:
	if t == null:
		return
	if not t is Dictionary:
		errors.append("terrain: tiles must be an object")
		return
	var errs: Array = []
	for k in t:
		var spec := _tex_spec(t[k], "tile '%s'" % str(k), errs)
		if spec.is_empty():
			continue
		var vs := {}
		var tv: Variant = (t[k] as Dictionary).get("variants", {})
		if tv is Dictionary:
			for v in tv:
				var s := _tex_spec(tv[v], "tile '%s' variant '%s'" % [str(k), str(v)], errs)
				if not s.is_empty():
					vs[str(v)] = s
		spec["variants"] = vs
		tiles[str(k)] = spec
	for e in errs:
		errors.append(e)


func _parse_kind_tiles(k: Variant) -> void:
	if not k is Dictionary:
		errors.append("terrain: kind_tiles must be an object")
		return
	for kind in k:
		if not str(kind) in KIND_TILE_KEYS:
			warnings.append("terrain: kind_tiles '%s' is not a known kind (%s)" % [str(kind), ", ".join(KIND_TILE_KEYS)])
			continue
		kind_tiles[str(kind)] = str(k[kind])


# --- queries -----------------------------------------------------------------------

func applies_to(m: FarmMap, own_world: bool = false) -> bool:
	## Terrain for this map? A pack's terrain applies to the world it provides
	## (own_world), to the maps it lists, or (no list) to any map in the game
	## tile frame.
	if m == null or not is_usable() or not frame in FRAMES:
		return false
	if not maps.is_empty():
		return m.id in maps
	return own_world or m.frame == "game"


func variant_for(theme_id: String) -> String:
	## World theme -> art variant: the "themes" table, then a variant of the
	## same name, else the default art (never a guessed season).
	var t := theme_id.strip_edges().to_lower()
	if t.is_empty():
		return DEFAULT_VARIANT
	if themes.has(t):
		return themes[t]
	if t in variants:
		return t
	return DEFAULT_VARIANT


func background_for(variant: String) -> Variant:
	return _variant_bg.get(variant, background_color)


func tile_spec(art: String, variant: String = DEFAULT_VARIANT) -> Dictionary:
	## Texture of a tile art key in a variant: the tile's own "variants" entry,
	## then a key "<art>_<variant>" (the game's export-name suffix rule), then
	## the base texture. {} when the pack has no texture for it.
	if art.is_empty():
		return {}
	if variant != DEFAULT_VARIANT:
		var b: Dictionary = tiles.get(art, {})
		if (b.get("variants", {}) as Dictionary).has(variant):
			return b["variants"][variant]
		if tiles.has(art + "_" + variant):
			return tiles[art + "_" + variant]
	return tiles.get(art, {})


func pieces_for(variant: String = DEFAULT_VARIANT) -> Array[Dictionary]:
	## Normalised pieces of a variant in draw order (lowest z first, then file
	## order). A variant without its own list uses the default list with each
	## piece's "variants" overrides applied.
	var src: Variant = _piece_lists.get(variant, _piece_lists.get(DEFAULT_VARIANT, []))
	var tmp: Array = []
	return _expand(src, variant, tmp)


func ground_art(m: FarmMap, open_plots: PackedByteArray) -> Dictionary:
	## Art key per tile: {"rect": Rect2i, "keys": Array[String], "ids": PackedInt32Array
	## (index into keys, -1 = the pack has no art for that tile)}. Tiles with
	## ground data use tile_types[].art (an expansion tile of an unlocked plot
	## shows its "unlocked_type"); the others use kind_tiles by map kind.
	## open_plots: 1 per map plot index when that plot is unlocked.
	var area := Rect2i(Vector2i.ZERO, m.size)
	if m.has_ground():
		area = area.merge(m.ground_rect)
	var keys: Array[String] = []
	var key_index := {}
	var ids := PackedInt32Array()
	ids.resize(area.size.x * area.size.y)
	ids.fill(-1)
	# Per tile type: art index when locked / unlocked (-2 = use the kind fallback).
	var by_type := {}
	for tid in m.tile_types:
		var tt: Dictionary = m.tile_types[tid]
		var a := _key_id(str(tt.get("art", "")) if tt.get("art") != null else "", keys, key_index)
		var u := a
		if tt.has("unlocked_type") and tt["unlocked_type"] != null:
			var ut: Dictionary = m.tile_type(int(tt["unlocked_type"]))
			if ut.get("art") != null:
				u = _key_id(str(ut["art"]), keys, key_index)
		by_type[int(tid)] = Vector2i(a, u)
	var kind_ids := {}
	for k in KIND_TILE_KEYS:
		kind_ids[k] = _key_id(str(kind_tiles.get(k, "")), keys, key_index)
	if kind_ids["plot"] < 0:
		kind_ids["plot"] = kind_ids["buildable"]
	if kind_ids["plot_locked"] < 0:
		kind_ids["plot_locked"] = kind_ids["plot"]
	var w := m.size.x
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var t := Vector2i(x, y)
			var in_grid := x >= 0 and y >= 0 and x < w and y < m.size.y
			var gi := y * w + x
			var open := false
			if in_grid:
				var p := m.plot_of[gi]
				open = p >= 0 and p < open_plots.size() and open_plots[p] == 1
			var v := -1
			var g := m.ground_at(t) if m.has_ground() else -1
			if g >= 0 and by_type.has(g):
				var pair: Vector2i = by_type[g]
				v = pair.y if open else pair.x
			if v < 0 and in_grid:
				match int(m.kinds[gi]):
					FarmMap.Kind.BUILDABLE: v = kind_ids["buildable"]
					FarmMap.Kind.PLOT: v = kind_ids["plot"] if open else kind_ids["plot_locked"]
					FarmMap.Kind.ROAD: v = kind_ids["road"]
					FarmMap.Kind.BLOCKED: v = kind_ids["blocked"]
					FarmMap.Kind.WATER: v = kind_ids["water"]
					FarmMap.Kind.SCENERY: v = kind_ids["scenery"]
			ids[(y - area.position.y) * area.size.x + (x - area.position.x)] = v
	return {"rect": area, "keys": keys, "ids": ids}


static func _key_id(k: String, keys: Array[String], index: Dictionary) -> int:
	if k.is_empty():
		return -1
	if not index.has(k):
		index[k] = keys.size()
		keys.append(k)
	return index[k]


func files() -> PackedStringArray:
	## Every pack-relative file the manifest references (all variants).
	var out := {}
	for a in atlases:
		out[atlases[a]["file"]] = true
	for k in tiles:
		var s: Dictionary = tiles[k]
		if not str(s["file"]).is_empty():
			out[s["file"]] = true
		for v in s["variants"]:
			if not str(s["variants"][v]["file"]).is_empty():
				out[s["variants"][v]["file"]] = true
	if not clips_file.is_empty():
		out[clips_file] = true
	for v in variants:
		for p in pieces_for(v):
			for f in ["mesh", "file", "sheet", "texture_file"]:
				if not str(p.get(f, "")).is_empty():
					out[p[f]] = true
	var arr := PackedStringArray(out.keys())
	arr.sort()
	return arr


func missing_files() -> PackedStringArray:
	var out := PackedStringArray()
	for f in files():
		var p := base_dir.path_join(f)
		if not FileAccess.file_exists(p) and not (p.begins_with("res://") and ResourceLoader.exists(p)):
			out.append(f)
	return out


func report(msg: String) -> void:
	## A problem found while loading/drawing (missing file, bad mesh): listed once.
	var m := "terrain: " + msg
	if not errors.has(m):
		errors.append(m)


func diagnostics() -> PackedStringArray:
	var out := PackedStringArray()
	out.append_array(errors)
	out.append_array(warnings)
	return out


static func validate_file(path: String) -> Dictionary:
	## For pack authors and CI: {"ok", "errors", "warnings", "files", "missing", "variants", "pieces"}.
	var tp := load_file(path)
	var missing := tp.missing_files() if tp.is_usable() else PackedStringArray()
	var n := {}
	for v in tp.variants:
		n[v] = tp.pieces_for(v).size()
	return {"ok": tp.errors.is_empty() and missing.is_empty(), "errors": tp.errors, "warnings": tp.warnings,
		"files": tp.files().size() if tp.is_usable() else 0, "missing": missing, "variants": tp.variants, "pieces": n}


# --- pieces ------------------------------------------------------------------------

func _expand(list: Variant, variant: String, errs: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not list is Array:
		return out
	var own_list := _piece_lists.has(variant) and variant != DEFAULT_VARIANT
	var i := 0
	for raw in list:
		i += 1
		if not raw is Dictionary:
			errs.append("terrain: piece %d is not an object" % i)
			continue
		var e: Dictionary = raw
		if not own_list and e.get("variants") is Dictionary and (e["variants"] as Dictionary).has(variant):
			var ov: Variant = e["variants"][variant]
			if ov is Dictionary:
				e = e.duplicate()
				for k in ov:
					e[k] = ov[k]
		if _bool(e.get("hidden", false)):
			continue
		var p := _piece(e, i, errs)
		if p.is_empty():
			continue
		var at: Vector2 = p["at"]
		var rep: Variant = e.get("repeat", null)
		var count := 1
		var step := Vector2.ZERO
		if rep is Dictionary:
			count = clampi(int(rep.get("count", 1)), 1, MAX_REPEAT)
			if rep.get("step_tile") is Array and (rep["step_tile"] as Array).size() == 2:
				step = Iso.grid_to_world(Vector2(float(rep["step_tile"][0]), float(rep["step_tile"][1])))
			elif rep.get("step_world") is Array and (rep["step_world"] as Array).size() == 2:
				step = Vector2(float(rep["step_world"][0]), float(rep["step_world"][1]))
			else:
				errs.append("terrain: piece '%s' repeat needs step_tile or step_world" % p["id"])
				count = 1
		for k in count:
			var q := p if k == 0 else p.duplicate()
			q["at"] = at + step * k
			q["copy"] = k
			out.append(q)
			if out.size() >= MAX_PIECES:
				errs.append("terrain: more than %d pieces; the rest are ignored" % MAX_PIECES)
				return _sorted(out)
	return _sorted(out)


static func _sorted(a: Array[Dictionary]) -> Array[Dictionary]:
	var idx := 0
	for p in a:
		p["order"] = idx
		idx += 1
	a.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return p["z"] < q["z"] if p["z"] != q["z"] else p["order"] < q["order"])
	return a


func _piece(e: Dictionary, i: int, errs: Array) -> Dictionary:
	var pid := str(e.get("id", e.get("export", "piece_%d" % i)))
	var p := {"id": pid, "kind": str(e.get("kind", e.get("role", ""))), "z": float(e.get("z", 0.0)) if (e.get("z", 0) is int or e.get("z", 0) is float) else 0.0,
		"modulate": Color.WHITE, "clips": []}
	# Position: a tile corner (game tile frame) or world px, plus an offset in world px.
	var at := Vector2.ZERO
	var tile_v: Variant = e.get("anchor_tile", e.get("at_tile", null))
	var world_v: Variant = e.get("anchor_world", e.get("at_world", null))
	if tile_v is Array and (tile_v as Array).size() == 2:
		at = Iso.grid_to_world(Vector2(float(tile_v[0]), float(tile_v[1])))
	elif world_v is Array and (world_v as Array).size() == 2:
		at = Vector2(float(world_v[0]), float(world_v[1]))
	if e.get("offset") is Array and (e["offset"] as Array).size() == 2:
		at += Vector2(float(e["offset"][0]), float(e["offset"][1]))
	p["at"] = at
	if e.has("modulate"):
		var c: Variant = _color(e["modulate"], "piece '%s' modulate" % pid, errs)
		if c != null:
			p["modulate"] = c
	p["layer"] = str(e.get("layer", "ground"))
	if not p["layer"] in LAYERS:
		errs.append("terrain: piece '%s' has unknown layer '%s' (drawn on the ground)" % [pid, p["layer"]])
		p["layer"] = "ground"
	p["blend"] = blend_name(e.get("blend", "normal"))
	if p["blend"].is_empty():
		errs.append("terrain: piece '%s' has unknown blend '%s' (drawn normal)" % [pid, str(e.get("blend"))])
		p["blend"] = "normal"
	var ty := str(e.get("type", ""))
	if ty.is_empty():
		if e.has("mesh"):
			ty = "mesh"
		elif e.has("polygon_tiles") or e.has("rect_tiles") or e.has("polygon_world"):
			ty = "polygon"
		else:
			ty = "image"
	if not ty in PIECE_TYPES:
		errs.append("terrain: piece '%s' has unknown type '%s'" % [pid, ty])
		return {}
	p["type"] = ty
	match ty:
		"mesh":
			var rel := safe_rel(str(e.get("mesh", "")))
			if rel.is_empty():
				errs.append("terrain: piece '%s' has no safe mesh path" % pid)
				return {}
			p["mesh"] = rel
		"polygon":
			if not _polygon(e, p, errs):
				return {}
		"image":
			if not _image(e, p, errs):
				return {}
	# Clip animations placed on this piece (the prototype calls them water_glints).
	var cl: Variant = e.get("clips", e.get("water_glints", []))
	if cl is Array:
		for c in cl:
			if not c is Dictionary or str(c.get("clip", "")).is_empty():
				errs.append("terrain: piece '%s' has a clip without a name" % pid)
				continue
			var xa: Variant = c.get("x_axis", [1, 0])
			var ya: Variant = c.get("y_axis", [0, 1])
			var o: Variant = c.get("origin_world", c.get("at_world", [0, 0]))
			if not (xa is Array and ya is Array and o is Array and (xa as Array).size() == 2 and (ya as Array).size() == 2 and (o as Array).size() == 2):
				errs.append("terrain: piece '%s' clip '%s' has a bad transform" % [pid, str(c["clip"])])
				continue
			# Instance colour transform: multiplier and add term (rgb, 0..1).
			var mul: Variant = _color(c["mul"], "piece '%s' clip mul" % pid, errs) if c.has("mul") else Color.WHITE
			var add: Variant = _color(c["add"], "piece '%s' clip add" % pid, errs) if c.has("add") else Color(0, 0, 0, 0)
			p["clips"].append({"clip": str(c["clip"]), "xform": Transform2D(Vector2(float(xa[0]), float(xa[1])),
				Vector2(float(ya[0]), float(ya[1])), Vector2(float(o[0]), float(o[1]))),
				"mul": mul if mul is Color else Color.WHITE,
				"add": Color((add as Color).r, (add as Color).g, (add as Color).b, 0.0) if add is Color else Color(0, 0, 0, 0)})
	return p


func _image(e: Dictionary, p: Dictionary, errs: Array) -> bool:
	var img: Dictionary = e["image"] if e.get("image") is Dictionary else e
	var pid: String = p["id"]
	var has_tex := img.has("atlas") or img.has("file")
	var an: Variant = e.get("anim", null)
	if not has_tex and not an is Dictionary:
		errs.append("terrain: piece '%s' needs an image (atlas or file), a mesh, a polygon or an anim" % pid)
		return false
	p["atlas"] = ""
	p["file"] = ""
	p["rect"] = Rect2i()
	if has_tex:
		var spec := _tex_spec(img, "piece '%s' image" % pid, errs)
		if spec.is_empty():
			return false
		p["atlas"] = spec["atlas"]
		p["file"] = spec["file"]
		p["rect"] = spec["rect"]
	var o: Variant = img.get("origin", img.get("anchor", [0, 0]))
	p["origin"] = Vector2(float(o[0]), float(o[1])) if o is Array and (o as Array).size() == 2 else Vector2.ZERO
	var sc: Variant = img.get("scale", null)
	p["scale"] = float(sc) if (sc is int or sc is float) and float(sc) > 0.0 else 1.0 / pixels_per_world_px
	p["flip_h"] = _bool(img.get("flip_h", false))
	if an is Dictionary:
		var sheet := safe_rel(str(an.get("sheet", "")))
		var frames := int(an.get("frames", 0))
		if sheet.is_empty() or frames < 1:
			errs.append("terrain: piece '%s' anim needs a sheet and frames >= 1" % pid)
			return has_tex
		var cols := maxi(1, int(an.get("columns", frames)))
		var fps := float(an.get("fps", 6.0))
		var fs: Variant = an.get("frame_size", null)
		p["anim"] = {"sheet": sheet, "frames": frames, "columns": cols, "fps": fps if fps > 0.0 else 6.0,
			"frame_size": Vector2(float(fs[0]), float(fs[1])) if fs is Array and (fs as Array).size() == 2 else Vector2.ZERO,
			"overlay": has_tex}
		p["sheet"] = sheet
	return true


func _polygon(e: Dictionary, p: Dictionary, errs: Array) -> bool:
	var pid: String = p["id"]
	var pts := PackedVector2Array()
	if e.get("rect_tiles") is Array and (e["rect_tiles"] as Array).size() == 4:
		var r: Array = e["rect_tiles"]
		var rr := Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
		for g: Vector2 in [rr.position, Vector2(rr.end.x, rr.position.y), rr.end, Vector2(rr.position.x, rr.end.y)]:
			pts.append(Iso.grid_to_world(g) - p["at"])
	elif e.get("polygon_tiles") is Array:
		for q in e["polygon_tiles"]:
			if q is Array and (q as Array).size() == 2:
				pts.append(Iso.grid_to_world(Vector2(float(q[0]), float(q[1]))) - p["at"])
	elif e.get("polygon_world") is Array:
		for q in e["polygon_world"]:
			if q is Array and (q as Array).size() == 2:
				pts.append(Vector2(float(q[0]), float(q[1])))
	if pts.size() < 3:
		errs.append("terrain: piece '%s' polygon needs at least 3 points" % pid)
		return false
	if Geometry2D.triangulate_polygon(pts).is_empty():
		errs.append("terrain: piece '%s' polygon cannot be triangulated (self-crossing?)" % pid)
		return false
	p["polygon"] = pts
	p["color"] = Color.WHITE
	if e.has("color"):
		var c: Variant = _color(e["color"], "piece '%s' color" % pid, errs)
		if c != null:
			p["color"] = c
	p["texture_file"] = ""
	if e.has("texture"):
		var t: Variant = e["texture"]
		var f := safe_rel(str((t as Dictionary).get("file", "")) if t is Dictionary else str(t))
		if f.is_empty():
			errs.append("terrain: piece '%s' texture needs a safe file (whole image, it repeats)" % pid)
		else:
			p["texture_file"] = f
	var uw: Variant = e.get("uv_world", null)
	p["uv_world"] = float(uw) if (uw is int or uw is float) and float(uw) > 0.0 else 0.0   ## 0 = texture px / pixels_per_world_px
	return true


# --- helpers -----------------------------------------------------------------------

static func safe_rel(p: String) -> String:
	## A pack-relative path or "" when it could leave the pack folder.
	var rel := p.strip_edges().replace("\\", "/")
	if rel.is_empty() or rel.begins_with("/") or rel.contains("://") or rel.contains(":") or ".." in rel.split("/"):
		return ""
	return rel


static func blend_name(v: Variant) -> String:
	## "normal" / "add" / "screen" / "multiply" from a name or a Flash / SC
	## blend number; "" when unknown.
	if v is int or v is float:
		return BLEND_NUMBERS.get(int(v), "")
	var s := str(v).strip_edges().to_lower()
	if s.is_valid_int():
		return BLEND_NUMBERS.get(int(s), "")
	return s if s in BLENDS else ""


static func _bool(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	return str(v).to_lower() in ["true", "yes", "1"]


func _color(v: Variant, what: String, errs: Variant = null) -> Variant:
	## errs: an Array to report into (null = `errors`).
	var c: Variant = null
	if v is String and Color.html_is_valid(v):
		c = Color.html(v)
	elif v is Array and (v as Array).size() >= 3:
		c = Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if (v as Array).size() > 3 else 1.0)
	if c == null:
		var msg := "terrain: %s is not a colour ('#rrggbb' or [r, g, b(, a)])" % what
		if errs is Array:
			(errs as Array).append(msg)
		else:
			errors.append(msg)
	return c
