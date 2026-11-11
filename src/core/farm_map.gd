class_name FarmMap
extends RefCounted
## Data-driven farm geometry: which tiles exist, which are buildable, which
## belong to an unlockable expansion plot, and which are permanent terrain
## (roads, water, fixed scenery). Loaded from data/maps/*.json so the geometry
## can be corrected without code changes.
##
## Schema v2 ("frame": "game", see the W2 design) adds the world layer around
## the placement grid: fixed landmarks (Landmark), off-grid scenery, an optional
## per-tile ground layer (RLE), tile types, sections, initial objects, plot
## aliases and provenance. The placement grid stays [0, size.x) x [0, size.y);
## world content may use negative tile coordinates (never buildable).
## v1 files still parse (tests/fixtures, old user maps).

const FORMAT := "hayday-sandbox-map"
const SCHEMA_VERSION := 2

enum Kind { VOID = 0, BUILDABLE = 1, PLOT = 2, ROAD = 3, WATER = 4, BLOCKED = 5, SCENERY = 6 }
const KIND_NAMES := {"void": Kind.VOID, "buildable": Kind.BUILDABLE, "plot": Kind.PLOT, "road": Kind.ROAD,
	"water": Kind.WATER, "blocked": Kind.BLOCKED, "scenery": Kind.SCENERY}
const SCENERY_KINDS := ["river", "cliff", "forest", "edge"]
const SECTION_SIDES := ["main", "across_road"]
const PROVENANCE_KINDS := ["public_approximation", "private_game_data"]

var id: String = ""
var name: String = ""
var geometry_status: String = "approximation"
var size: Vector2i = Vector2i(40, 40)
var kinds: PackedByteArray = PackedByteArray()   ## per tile Kind
var plot_of: PackedInt32Array = PackedInt32Array() ## per tile plot index, -1 = none
var region_of: PackedInt32Array = PackedInt32Array()
var regions: Array[Dictionary] = []
## {id, name, section, number, cost, min_level, rects, tiles, neighbors, center, status, notes,
##  aliases: Array[String], game_id: int (-1 unknown), client_locked, locked_text,
##  exclusive_decorations: Array[String], wiki: Dictionary, touches_land: bool}
var plots: Array[Dictionary] = []
var plot_index: Dictionary = {}                 ## plot id -> index
var fixed_objects: Array[Dictionary] = []       ## v1 only: {id, item, origin: Vector2i, label}
var labels: Array[Dictionary] = []              ## decorative map labels {text, at: Vector2}
var sources: PackedStringArray = PackedStringArray()
var notes: PackedStringArray = PackedStringArray()
var errors: PackedStringArray = PackedStringArray()
## Non-fatal problems (unknown fields/values, overlaps, loader notes).
var warnings: PackedStringArray = PackedStringArray()

# --- schema v2 ---------------------------------------------------------------------
var schema_version: int = 1
var frame: String = "v1"                        ## "game" for v2 maps
## {kind, source, client_version, generated, confidence} + WorldLoader adds
## {active: "public"|"private", label, pack_id, pack_version, user_overrides, rejected}
var provenance: Dictionary = {}
var world_bounds: Rect2i = Rect2i()             ## camera + scenery extent (may be negative)
var landmarks: Array[Landmark] = []
var landmark_index: Dictionary = {}             ## landmark id -> index
var scenery: Array[Dictionary] = []             ## {id, kind, name, rect: Rect2i}
var ground: PackedByteArray = PackedByteArray() ## tile type id per tile of ground_rect (empty = none)
var ground_rect: Rect2i = Rect2i()
var tile_types: Dictionary = {}                 ## int id -> {name, kind, art}
var sections: Array[Dictionary] = []            ## {id, name, side, plots: Array[String], status}
var initial_objects: Array[Dictionary] = []     ## {item, x, y, origin: Vector2i, flip, group, game_name}
var terrain_path: String = ""                   ## resolved against the map file's folder ("" = none)
var source_path: String = ""                    ## file this map was loaded from ("" = built in code)
var alias_index: Dictionary = {}                ## plot alias -> canonical plot id
var unmapped_sections: Array = []
## Water-decoration zones (world data, schema v2 "water_deco_zones"): the only
## tiles where items tagged PlacementRules.ZONE_TAG (the game's WaterDeco
## decorations) may stand, usually along the river outside the placement grid.
## {id, name, rect: Rect2i, enabled: bool}. Values come from world data (the
## private world builder reads the client's level data); none are invented.
var water_deco_zones: Array[Dictionary] = []
var _lm_mask: PackedInt32Array = PackedInt32Array()  ## per in-grid tile landmark index, -1 = none
var _zone_tiles: Dictionary = {}                ## Occupancy.key(tile) -> zone index (enabled zones)


static func load_file(path: String) -> FarmMap:
	var m := FarmMap.new()
	m.source_path = path
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary:
		m.errors.append("map file missing or invalid: %s" % path)
		m._build_fallback()
		return m
	m.from_dict(data, path.get_base_dir())
	return m


static func from_data(d: Dictionary, base_dir: String = "") -> FarmMap:
	var m := FarmMap.new()
	m.from_dict(d, base_dir)
	return m


static func make_simple(w: int, h: int) -> FarmMap:
	## A plain rectangular, fully-buildable map (tests and fallback).
	var m := FarmMap.new()
	m.from_dict({"id": "simple_%dx%d" % [w, h], "name": "Open field", "size": [w, h],
		"regions": [{"id": "all", "kind": "buildable", "rects": [[0, 0, w, h]]}]})
	return m


func _build_fallback() -> void:
	from_dict({"id": "fallback", "name": "Fallback field", "size": [40, 40],
		"regions": [{"id": "all", "kind": "buildable", "rects": [[0, 0, 40, 40]]}]})


func from_dict(d: Dictionary, base_dir: String = "") -> void:
	id = str(d.get("id", "map"))
	name = str(d.get("name", id))
	geometry_status = str(d.get("geometry_status", "approximation"))
	schema_version = int(d.get("schema_version", 1)) if (d.get("schema_version", 1) is int or d.get("schema_version", 1) is float) else 1
	frame = str(d.get("frame", "game" if schema_version >= 2 else "v1"))
	var fmt: Variant = d.get("format", FORMAT)
	if str(fmt) != FORMAT:
		errors.append("map %s: format must be '%s'" % [id, FORMAT])
	if schema_version > SCHEMA_VERSION:
		warnings.append("map %s: schema_version %d is newer than this app (%d)" % [id, schema_version, SCHEMA_VERSION])
	var sz: Variant = d.get("size", [40, 40])
	if sz is Array and (sz as Array).size() == 2 and int(sz[0]) > 0 and int(sz[1]) > 0:
		size = Vector2i(int(sz[0]), int(sz[1]))
	else:
		errors.append("map %s: size must be [w, h] positive integers" % id)
		size = Vector2i(40, 40)
	var n := size.x * size.y
	kinds.resize(n)
	kinds.fill(Kind.VOID)
	plot_of.resize(n)
	plot_of.fill(-1)
	region_of.resize(n)
	region_of.fill(-1)
	regions.clear()
	plots.clear()
	plot_index.clear()
	alias_index.clear()
	landmarks.clear()
	landmark_index.clear()
	_lm_mask = PackedInt32Array()
	scenery.clear()
	water_deco_zones.clear()
	_zone_tiles.clear()
	sections.clear()
	initial_objects.clear()
	tile_types.clear()
	ground = PackedByteArray()
	ground_rect = Rect2i()
	terrain_path = ""
	provenance = (d.get("provenance") as Dictionary).duplicate(true) if d.get("provenance") is Dictionary else {}
	unmapped_sections = (d.get("unmapped_sections") as Array).duplicate(true) if d.get("unmapped_sections") is Array else []
	for s in d.get("sources", []):
		sources.append(str(s))
	for s in d.get("notes", []):
		notes.append(str(s))
	_parse_regions(d.get("regions", []))
	_compute_plot_geometry()
	_parse_aliases()
	for f in d.get("fixed_objects", []):
		if f is Dictionary and f.has("origin"):
			fixed_objects.append({"id": str(f.get("id", "")), "item": str(f.get("item", "")),
				"origin": Vector2i(int(f["origin"][0]), int(f["origin"][1])), "label": str(f.get("label", ""))})
	for l in d.get("labels", []):
		if l is Dictionary and l.has("at"):
			labels.append({"text": str(l.get("text", "")), "at": Vector2(float(l["at"][0]), float(l["at"][1]))})
	_parse_tile_types(d.get("tile_types", {}))
	_parse_ground(d.get("ground", null))
	_parse_landmarks(d.get("landmarks", []))
	_parse_scenery(d.get("scenery", []))
	_parse_water_deco_zones(d.get("water_deco_zones", null))
	_parse_sections(d.get("sections", []))
	_parse_initial_objects(d.get("initial_objects", []))
	_parse_terrain(d.get("terrain", null), base_dir)
	_compute_world_bounds(d.get("world_bounds", null))
	if schema_version >= 2:
		if frame != "game":
			errors.append("map %s: schema v2 maps must use frame 'game'" % id)
		var pk := str(provenance.get("kind", ""))
		if not provenance.is_empty() and not pk in PROVENANCE_KINDS:
			warnings.append("map %s: unknown provenance kind '%s'" % [id, pk])


# --- parsing ------------------------------------------------------------------------

func _parse_regions(list: Variant) -> void:
	if not list is Array:
		errors.append("map %s: regions must be a list" % id)
		return
	# Regions are painted in file order; later regions override earlier ones.
	for r in list:
		if not r is Dictionary:
			continue
		var kind_name := str(r.get("kind", "buildable"))
		if not KIND_NAMES.has(kind_name):
			errors.append("region %s: unknown kind %s" % [r.get("id", "?"), kind_name])
			continue
		var kind: int = KIND_NAMES[kind_name]
		var rects: Array[Rect2i] = []
		for a in r.get("rects", []):
			if a is Array and a.size() == 4:
				rects.append(Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3])))
		var region := {"id": str(r.get("id", "region_%d" % regions.size())), "kind": kind, "kind_name": kind_name,
			"name": str(r.get("name", "")), "rects": rects, "status": str(r.get("status", geometry_status))}
		var region_idx := regions.size()
		regions.append(region)
		var pidx := -1
		if kind == Kind.PLOT:
			if plot_index.has(region["id"]):
				errors.append("map %s: duplicate plot id %s" % [id, region["id"]])
			pidx = plots.size()
			var gid: Variant = r.get("game_id", -1)
			var plot := {
				"id": region["id"], "name": str(r.get("name", region["id"])),
				"section": str(r.get("section", "main")), "number": int(r.get("number", pidx + 1)),
				"cost": r.get("cost", {}), "min_level": int(r.get("min_level", -1)) if r.get("min_level") != null else -1,
				"rects": rects, "tiles": 0, "neighbors": [], "center": Vector2.ZERO,
				"status": region["status"], "notes": str(r.get("notes", "")),
				"aliases": Landmark._str_list(r.get("aliases", [])),
				"game_id": int(gid) if (gid is int or gid is float) else -1,
				"client_locked": Landmark._bool(r.get("client_locked", false)),
				"locked_text": str(r.get("locked_text", "")) if r.get("locked_text") != null else "",
				"exclusive_decorations": Landmark._str_list(r.get("exclusive_decorations", [])),
				"wiki": (r.get("wiki") as Dictionary).duplicate(true) if r.get("wiki") is Dictionary else {},
				"touches_land": false,
			}
			plots.append(plot)
			plot_index[plot["id"]] = pidx
		var w := size.x
		for rect in rects:
			var x0 := maxi(rect.position.x, 0)
			var x1 := mini(rect.end.x, size.x)
			var y0 := maxi(rect.position.y, 0)
			var y1 := mini(rect.end.y, size.y)
			for y in range(y0, y1):
				var row := y * w
				for x in range(x0, x1):
					var i := row + x
					kinds[i] = kind
					plot_of[i] = pidx
					region_of[i] = region_idx


func _parse_aliases() -> void:
	for p in plots:
		for a: String in p["aliases"]:
			if plot_index.has(a) and a != p["id"]:
				errors.append("map %s: plot alias '%s' of %s collides with a plot id" % [id, a, p["id"]])
			elif alias_index.has(a) and alias_index[a] != p["id"]:
				errors.append("map %s: plot alias '%s' used by %s and %s" % [id, a, alias_index[a], p["id"]])
			elif a != p["id"]:
				alias_index[a] = p["id"]


func _parse_tile_types(tt: Variant) -> void:
	if tt == null:
		return
	if not tt is Dictionary:
		errors.append("map %s: tile_types must be an object" % id)
		return
	for k in tt:
		var ks := str(k)
		if not ks.is_valid_int() or int(ks) < 0 or int(ks) > 255:
			errors.append("map %s: tile type id '%s' must be an integer 0..255" % [id, ks])
			continue
		var e: Variant = tt[k]
		if not e is Dictionary:
			errors.append("map %s: tile type %s is not an object" % [id, ks])
			continue
		var rec: Dictionary = (e as Dictionary).duplicate(true)
		rec["name"] = str(e.get("name", ks))
		rec["kind"] = str(e.get("kind", "buildable"))
		# "art": a terrain-pack tile key (docs/TERRAIN_PACKS.md) or null = drawn by the app.
		var art: Variant = e.get("art")
		if art != null and not art is String:
			warnings.append("map %s: tile type %s art must be a string or null (ignored)" % [id, ks])
			art = null
		rec["art"] = null if art == null or str(art).strip_edges().is_empty() else str(art).strip_edges()
		tile_types[int(ks)] = rec


func _parse_ground(g: Variant) -> void:
	if g == null:
		return
	if not g is Dictionary:
		errors.append("map %s: ground must be an object" % id)
		return
	var enc := str(g.get("encoding", "rle-rows"))
	if enc != "rle-rows":
		errors.append("map %s: unknown ground encoding '%s'" % [id, enc])
		return
	var gr := Rect2i(Vector2i.ZERO, size)
	if g.has("rect"):
		gr = Landmark._rect(g["rect"])
		if gr.size.x <= 0 or gr.size.y <= 0:
			errors.append("map %s: ground.rect must be [x, y, w, h]" % id)
			return
	var rows: Variant = g.get("rows", [])
	if not rows is Array or (rows as Array).size() != gr.size.y:
		errors.append("map %s: ground needs %d rows" % [id, gr.size.y])
		return
	var out := PackedByteArray()
	out.resize(gr.size.x * gr.size.y)
	var w := gr.size.x
	for y in gr.size.y:
		var row: Variant = rows[y]
		if not row is Array:
			errors.append("map %s: ground row %d is not a list" % [id, y])
			return
		var x := 0
		var base := y * w
		for run in row:
			if not run is Array or (run as Array).size() != 2:
				errors.append("map %s: ground row %d: runs must be [value, count]" % [id, y])
				return
			var v := int(run[0])
			var c := int(run[1])
			if v < 0 or v > 255 or c <= 0 or x + c > w:
				errors.append("map %s: ground row %d: bad run %s" % [id, y, str(run)])
				return
			if not tile_types.is_empty() and not tile_types.has(v):
				warnings.append("map %s: ground uses undeclared tile type %d" % [id, v])
			for i in range(base + x, base + x + c):
				out[i] = v
			x += c
		if x != w:
			errors.append("map %s: ground row %d covers %d of %d tiles" % [id, y, x, w])
			return
	ground = out
	ground_rect = gr


func _parse_landmarks(list: Variant) -> void:
	if list == null:
		return
	if not list is Array:
		errors.append("map %s: landmarks must be a list" % id)
		return
	var errs: Array = []
	var warns: Array = []
	for rec in list:
		var lm := Landmark.from_dict(rec, errs, warns)
		if lm == null:
			continue
		if landmark_index.has(lm.id):
			errs.append("duplicate landmark id '%s'" % lm.id)
			continue
		landmark_index[lm.id] = landmarks.size()
		landmarks.append(lm)
	for e in errs:
		errors.append("map %s: %s" % [id, e])
	for w in warns:
		warnings.append("map %s: %s" % [id, w])
	_rebuild_landmark_mask()


func _rebuild_landmark_mask() -> void:
	## Per in-grid tile landmark index for O(1) placement checks. The first
	## landmark listed wins where two blocks overlap (reported as a warning),
	## except that a landmark which really blocks beats an approximate one.
	_lm_mask = PackedInt32Array()
	if landmarks.is_empty():
		return
	_lm_mask.resize(size.x * size.y)
	_lm_mask.fill(-1)
	var overlaps := {}
	for li in landmarks.size():
		for r: Rect2i in landmarks[li].block_rects():
			var x0 := maxi(r.position.x, 0)
			var x1 := mini(r.end.x, size.x)
			var y0 := maxi(r.position.y, 0)
			var y1 := mini(r.end.y, size.y)
			for y in range(y0, y1):
				var row := y * size.x
				for x in range(x0, x1):
					var cur := _lm_mask[row + x]
					if cur < 0:
						_lm_mask[row + x] = li
					elif cur != li:
						overlaps["%s/%s" % [landmarks[cur].id, landmarks[li].id]] = true
						if landmarks[li].blocks_placement() and not landmarks[cur].blocks_placement():
							_lm_mask[row + x] = li
	for k in overlaps:
		warnings.append("map %s: landmark blocks overlap (%s)" % [id, k])


func _parse_scenery(list: Variant) -> void:
	if list == null:
		return
	if not list is Array:
		errors.append("map %s: scenery must be a list" % id)
		return
	for s in list:
		if not s is Dictionary:
			continue
		var r := Landmark._rect(s.get("rect", null))
		if r.size.x <= 0 or r.size.y <= 0:
			errors.append("map %s: scenery %s needs rect [x, y, w, h]" % [id, s.get("id", "?")])
			continue
		var k := str(s.get("kind", "edge"))
		if not k in SCENERY_KINDS:
			warnings.append("map %s: scenery %s: unknown kind '%s'" % [id, s.get("id", "?"), k])
		var rec: Dictionary = (s as Dictionary).duplicate(true)
		rec["id"] = str(s.get("id", "scenery_%d" % scenery.size()))
		rec["kind"] = k
		rec["name"] = str(s.get("name", ""))
		rec["rect"] = r
		scenery.append(rec)


func _parse_water_deco_zones(list: Variant) -> void:
	## "water_deco_zones": [{"id", "name", "rect": [x, y, w, h], "enabled": true}].
	if list == null:
		return
	if not list is Array:
		errors.append("map %s: water_deco_zones must be a list" % id)
		return
	var seen := {}
	for z in list:
		if not z is Dictionary:
			errors.append("map %s: water_deco_zones entries must be objects" % id)
			continue
		var r := Landmark._rect(z.get("rect", null))
		var zid := str(z.get("id", "zone_%d" % water_deco_zones.size()))
		if r.size.x <= 0 or r.size.y <= 0:
			errors.append("map %s: water deco zone %s needs rect [x, y, w, h]" % [id, zid])
			continue
		if seen.has(zid):
			errors.append("map %s: duplicate water deco zone id %s" % [id, zid])
			continue
		seen[zid] = true
		var en: Variant = z.get("enabled", true)
		var rec := {"id": zid, "name": str(z.get("name", zid)), "rect": r, "enabled": Landmark._bool(en) if en != null else true}
		var zi := water_deco_zones.size()
		water_deco_zones.append(rec)
		if not rec["enabled"]:
			continue
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var k := Occupancy.key(Vector2i(x, y))
				if not _zone_tiles.has(k):
					_zone_tiles[k] = zi


func _parse_sections(list: Variant) -> void:
	if list == null:
		return
	if not list is Array:
		errors.append("map %s: sections must be a list" % id)
		return
	var seen := {}
	for s in list:
		if not s is Dictionary or str(s.get("id", "")).is_empty():
			errors.append("map %s: section without id" % id)
			continue
		var sid := str(s["id"])
		if seen.has(sid):
			errors.append("map %s: duplicate section id %s" % [id, sid])
			continue
		seen[sid] = true
		var side := str(s.get("side", "main"))
		if not side in SECTION_SIDES:
			warnings.append("map %s: section %s: unknown side '%s'" % [id, sid, side])
		var pl: Array[String] = []
		for p in Landmark._str_list(s.get("plots", [])):
			var cid := resolve_plot_id(p)
			if not plot_index.has(cid):
				warnings.append("map %s: section %s lists unknown plot %s" % [id, sid, p])
			pl.append(cid)
		var rec: Dictionary = (s as Dictionary).duplicate(true)
		rec["id"] = sid
		rec["name"] = str(s.get("name", sid))
		rec["side"] = side
		rec["plots"] = pl
		rec["status"] = str(s.get("status", geometry_status))
		sections.append(rec)


func _parse_initial_objects(list: Variant) -> void:
	if list == null:
		return
	if not list is Array:
		errors.append("map %s: initial_objects must be a list" % id)
		return
	var bad := 0
	for o in list:
		if not o is Dictionary or str(o.get("item", "")).is_empty() or not Landmark._is_int(o.get("x")) or not Landmark._is_int(o.get("y")):
			bad += 1
			continue
		var x := int(o["x"])
		var y := int(o["y"])
		initial_objects.append({"item": str(o["item"]), "x": x, "y": y, "origin": Vector2i(x, y),
			"flip": Landmark._bool(o.get("flip", false)), "group": str(o.get("group", "start")),
			"game_name": str(o.get("game_name", ""))})
	if bad > 0:
		warnings.append("map %s: %d initial objects without item/x/y ignored" % [id, bad])


func _parse_terrain(t: Variant, base_dir: String) -> void:
	if t == null or str(t).is_empty():
		return
	var rel := str(t).strip_edges().replace("\\", "/")
	if rel.begins_with("/") or rel.contains("://") or rel.contains(":") or ".." in rel.split("/"):
		warnings.append("map %s: unsafe terrain path '%s' ignored" % [id, rel])
		return
	terrain_path = base_dir.path_join(rel) if not base_dir.is_empty() else rel


func _compute_world_bounds(wb: Variant) -> void:
	var grid := Rect2i(Vector2i.ZERO, size)
	if wb != null:
		var r := Landmark._rect(wb)
		if r.size.x <= 0 or r.size.y <= 0:
			errors.append("map %s: world_bounds must be [x, y, w, h]" % id)
		else:
			if not r.encloses(grid):
				warnings.append("map %s: world_bounds did not enclose the placement grid (extended)" % id)
			world_bounds = r.merge(grid)
			return
	var b := grid
	for lm in landmarks:
		b = b.merge(lm.rect())
	for s in scenery:
		b = b.merge(s["rect"])
	for z in water_deco_zones:
		b = b.merge(z["rect"])
	world_bounds = b


func _compute_plot_geometry() -> void:
	var np := plots.size()
	var sx := PackedFloat64Array()
	var sy := PackedFloat64Array()
	var cnt := PackedInt32Array()
	var touch := PackedByteArray()
	sx.resize(np)
	sy.resize(np)
	cnt.resize(np)
	touch.resize(np)
	sx.fill(0.0)
	sy.fill(0.0)
	cnt.fill(0)
	touch.fill(0)
	var nb: Array[Dictionary] = []
	for i in np:
		nb.append({})
	var w := size.x
	var h := size.y
	var buildable := Kind.BUILDABLE
	for y in h:
		var row := y * w
		for x in w:
			var p := plot_of[row + x]
			if p < 0:
				continue
			cnt[p] += 1
			sx[p] += x + 0.5
			sy[p] += y + 0.5
			if x + 1 < w:
				var q := plot_of[row + x + 1]
				if q >= 0 and q != p:
					nb[p][q] = true
					nb[q][p] = true
			if y + 1 < h:
				var q2 := plot_of[row + w + x]
				if q2 >= 0 and q2 != p:
					nb[p][q2] = true
					nb[q2][p] = true
			if touch[p] == 0:
				if (x > 0 and kinds[row + x - 1] == buildable) or (x + 1 < w and kinds[row + x + 1] == buildable) \
						or (y > 0 and kinds[row - w + x] == buildable) or (y + 1 < h and kinds[row + w + x] == buildable):
					touch[p] = 1
	for i in np:
		plots[i]["tiles"] = cnt[i]
		if cnt[i] > 0:
			plots[i]["center"] = Vector2(sx[i] / cnt[i], sy[i] / cnt[i])
		plots[i]["touches_land"] = touch[i] == 1
		var ids: Array = []
		for q in nb[i].keys():
			ids.append(plots[q]["id"])
		ids.sort()
		plots[i]["neighbors"] = ids


# --- grid queries ---------------------------------------------------------------------

func in_bounds(t: Vector2i) -> bool:
	return t.x >= 0 and t.y >= 0 and t.x < size.x and t.y < size.y


func grid_rect() -> Rect2i:
	return Rect2i(Vector2i.ZERO, size)


func kind_at(t: Vector2i) -> int:
	if not in_bounds(t):
		return Kind.VOID
	return kinds[t.y * size.x + t.x]


func plot_id_at(t: Vector2i) -> String:
	## Canonical plot id of the tile ("" when it is not expansion land).
	if not in_bounds(t):
		return ""
	var p := plot_of[t.y * size.x + t.x]
	return "" if p < 0 else str(plots[p]["id"])


func plot(plot_id: String) -> Dictionary:
	## Plot record by canonical id or alias ({} when unknown).
	if plot_index.has(plot_id):
		return plots[plot_index[plot_id]]
	if alias_index.has(plot_id):
		return plots[plot_index[alias_index[plot_id]]]
	return {}


func has_plot(plot_id: String) -> bool:
	return plot_index.has(plot_id) or alias_index.has(plot_id)


func resolve_plot_id(plot_id: String) -> String:
	## Alias (e.g. "exp_<game id>") -> canonical plot id; identity for canonical
	## and unknown ids (unknown ids are never dropped from layouts).
	if plot_index.has(plot_id):
		return plot_id
	return alias_index.get(plot_id, plot_id)


func canonical_unlocked(unlocked: Variant) -> Dictionary:
	## Normalises a set/list of unlocked plot ids (any alias) to canonical ids.
	## Unknown ids are kept as they are (they may belong to another map).
	var out := {}
	var keys: Array = (unlocked as Dictionary).keys() if unlocked is Dictionary else (unlocked as Array if unlocked is Array else [])
	for k in keys:
		out[resolve_plot_id(str(k))] = true
	return out


func is_plot_unlocked(plot_id: String, unlocked: Dictionary) -> bool:
	## True when `unlocked` holds the plot under its canonical id or any alias.
	if unlocked.has(plot_id):
		return true
	var idx: int = plot_index.get(plot_id, -1)
	if idx < 0:
		var cid: String = alias_index.get(plot_id, "")
		if cid.is_empty():
			return false
		if unlocked.has(cid):
			return true
		idx = plot_index[cid]
	for a: String in plots[idx]["aliases"]:
		if unlocked.has(a):
			return true
	return false


func all_plot_ids() -> Array[String]:
	var out: Array[String] = []
	for p in plots:
		out.append(str(p["id"]))
	return out


func is_land(t: Vector2i, unlocked: Dictionary) -> bool:
	## True when objects may stand on this tile given the unlocked plots
	## (`unlocked` may use canonical ids or aliases).
	var k := kind_at(t)
	if k == Kind.BUILDABLE:
		return true
	if k == Kind.PLOT:
		return is_plot_unlocked(plot_id_at(t), unlocked)
	return false


func unlockable_plots(unlocked: Dictionary, level: int = -1) -> Array[String]:
	## Plots adjacent to starting land or an unlocked plot (Hay Day unlocks
	## plots outward from already-owned land). With `level` >= 0, plots whose
	## known min_level is above it are left out (see plot_level_block()).
	var out: Array[String] = []
	for p in plots:
		var pid := str(p["id"])
		if is_plot_unlocked(pid, unlocked):
			continue
		if level >= 0 and int(p.get("min_level", -1)) > level:
			continue
		var ok := bool(p.get("touches_land", false))
		if not ok:
			for nid in p["neighbors"]:
				if is_plot_unlocked(str(nid), unlocked):
					ok = true
					break
		if ok:
			out.append(pid)
	return out


func plot_level_block(plot_id: String, level: int) -> String:
	## "" when the plot may be unlocked at farm `level` (or its level is
	## unknown), else a short reason such as "Requires level 45".
	var p := plot(plot_id)
	var ml := int(p.get("min_level", -1))
	if level < 0 or ml < 0 or ml <= level:
		return ""
	return "Requires level %d" % ml


func buildable_tile_count(unlocked: Dictionary) -> int:
	var n := 0
	for y in size.y:
		for x in size.x:
			if is_land(Vector2i(x, y), unlocked):
				n += 1
	return n


func land_bounds() -> Rect2i:
	## Tile bounds of all non-void tiles.
	var lo := size
	var hi := Vector2i(-1, -1)
	for y in size.y:
		for x in size.x:
			if kinds[y * size.x + x] != Kind.VOID:
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	if hi.x < 0:
		return Rect2i(Vector2i.ZERO, size)
	return Rect2i(lo, hi - lo + Vector2i.ONE)


# --- world layer ------------------------------------------------------------------------

func landmark_at(t: Vector2i) -> int:
	## Index (into `landmarks`) of the landmark whose `blocks` cover tile t, or
	## -1. O(1) for grid tiles; off-grid tiles scan the (few) landmarks.
	if landmarks.is_empty():
		return -1
	if in_bounds(t):
		return _lm_mask[t.y * size.x + t.x]
	for i in landmarks.size():
		if landmarks[i].blocks_tile(t):
			return i
	return -1


func blocking_landmark_at(t: Vector2i) -> int:
	## Like landmark_at(), but only landmarks that refuse placement count.
	if landmarks.is_empty():
		return -1
	if in_bounds(t):
		var li := _lm_mask[t.y * size.x + t.x]
		return li if li >= 0 and landmarks[li].blocks_placement() else -1
	for i in landmarks.size():
		if landmarks[i].blocks_placement() and landmarks[i].blocks_tile(t):
			return i
	return -1


func landmark_id_at(t: Vector2i) -> String:
	var i := landmark_at(t)
	return "" if i < 0 else landmarks[i].id


func landmark_covering(t: Vector2i) -> int:
	## Index of a landmark whose FOOTPRINT covers t (picking / tooltips), -1.
	for i in landmarks.size():
		if landmarks[i].rect().has_point(t):
			return i
	return -1


func landmark(landmark_id: String) -> Landmark:
	var i: int = landmark_index.get(landmark_id, -1)
	return null if i < 0 else landmarks[i]


func landmark_ids() -> Array[String]:
	var out: Array[String] = []
	for lm in landmarks:
		out.append(lm.id)
	return out


func landmarks_replacing(item_id: String) -> Array[String]:
	## Landmarks that list `item_id` in replaces_items (catalogue duplicates).
	var out: Array[String] = []
	for lm in landmarks:
		if item_id in lm.replaces_items:
			out.append(lm.id)
	return out


func has_ground() -> bool:
	return not ground.is_empty()


func ground_at(t: Vector2i) -> int:
	## Tile type id of the ground layer at t, -1 when there is no ground data.
	if ground.is_empty() or not ground_rect.has_point(t):
		return -1
	var p := t - ground_rect.position
	return ground[p.y * ground_rect.size.x + p.x]


func tile_type(type_id: int) -> Dictionary:
	return tile_types.get(type_id, {})


func section(section_id: String) -> Dictionary:
	for s in sections:
		if s["id"] == section_id:
			return s
	return {}


func is_game_data() -> bool:
	return str(provenance.get("kind", "")) == "private_game_data"


func provenance_label() -> String:
	## Short text for the UI: which world data is active.
	if provenance.has("label"):
		return str(provenance["label"])
	return "Game data (private pack)" if is_game_data() else "Public approximation"


# --- water-decoration zones ----------------------------------------------------------

func has_water_deco_zones() -> bool:
	## True when the world data names at least one enabled zone.
	return not _zone_tiles.is_empty()


func water_deco_zone_at(t: Vector2i) -> int:
	## Index into water_deco_zones of the enabled zone covering the tile, -1 = none.
	return int(_zone_tiles.get(Occupancy.key(t), -1))


func water_deco_zone_rects() -> Array[Rect2i]:
	## Rects of the enabled zones (the placement overlay draws them).
	var out: Array[Rect2i] = []
	for z in water_deco_zones:
		if z["enabled"]:
			out.append(z["rect"])
	return out
