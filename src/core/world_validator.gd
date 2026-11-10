class_name WorldValidator
extends RefCounted
## Compares the app's world data (a private pack's world.json dictionary, or a
## loaded FarmMap) with the game client's own level data (ClientLevel) and
## tables, and returns a plain report dictionary. Pure core class: no scene,
## UI or App; nothing proprietary is embedded (rules only, no coordinates).
##
##   validate(level, world, opts = {}) -> report
##     level: ClientLevel.parse_level() result
##     world: Dictionary (world.json) or FarmMap
##     opts:  expansions: ClientLevel.read_table(expansions.csv)
##            tiles:      ClientLevel.read_table(tiles.csv)  (BlocksBuilding / Passable per ground type)
##            tables:     {table name: read_table()}  (special-object and item tables with TileWidth/TileHeight)
##            other_levels: {name: parse_level()}  (other TileMap files, only to explain absent expansion ids)
##            registration: {SpecialObject name: rule}  (defaults to REGISTRATION)
##            footprints: compare_footprints() result (merged into the checks)
##            game_version, generated, tool, max_examples
##   compare_footprints(db, tables, overrides, sprites = {}, max_examples) -> {item_footprints, footprint_corrections}
##
## Report: {format, version, game_version, generated, tool, world: {id, kind, client_version, generated},
##   status: "pass"|"warn"|"fail", counts, checks: [{id, title, status, compared, mismatches, examples, notes, ...}],
##   landmarks: [per SpecialObjects row], registration: [rules used], expansion_definitions_not_on_map: [...]}
## Every check counts what it compared and lists the first `max_examples` problems.

const FORMAT := "hayday-sandbox-world-validation"
const VERSION := 1
const TOOL := "WorldValidator 1"
const MAX_EXAMPLES := 10
const STATUSES := ["pass", "warn", "fail"]
## Default location of the latest report (read by AccuracyReport).
const DEFAULT_PATH := "user://private_data/world_validation.json"

const RULE_TOP_CORNER := "top_corner"
const RULE_CENTERED := "centered"

## How a client SpecialObjects (X, Y) relates to the footprint the object
## occupies. Evidence-backed, per object; no blanket offset.
##   top_corner: (X, Y) is the top (north) corner tile of the footprint; the
##               export's registration point is drawn at the top corner of (X, Y).
##   centered:   (X, Y) is the registration point the art is centred on; the
##               footprint is centred on it with integer halves:
##               origin = (X - W / 2, Y - H / 2) (W, H = TileWidth, TileHeight).
## `check` names an extra data test the validator runs for that object:
##   blocked_cells: the TileMap cells under the derived footprint are exactly
##   the object's non-passable road cells (see _blocked_cells_check).
const REGISTRATION := {
	"_default": {"rule": RULE_TOP_CORNER, "confidence": "verified-in-data",
		"evidence": [
			"Client seed objects (level Objects sections) placed with origin = (X, Y) never straddle an expansion border; any one-tile shift creates such conflicts.",
			"Building art drawn with its registration point on the top corner of tile (X, Y) lines up with the roads, driveway and house path of the TileMap.",
		]},
	"Car": {"rule": RULE_CENTERED, "confidence": "strong", "check": "blocked_cells",
		"meaning": "(X, Y) is the truck's registration point (logical position), not its footprint origin; the 1x2 footprint is centred on it, so the footprint origin is one row above (X - 0, Y - 1).",
		"evidence": [
			"TileMap: the only non-passable road cells (Road_01_Blocked) on the farm side form a vertical pair exactly the size of the Car table footprint (TileWidth 1 x TileHeight 2), starting one row above the Car row's Y.",
			"The top-corner rule would cover one ordinary passable road cell and leave one of the two blocked parking cells empty.",
			"The parked truck art (truck_0) is centred on its registration point (opaque bounds about -65..80 x -46..47 world px), unlike building art, which hangs below the top corner of its tile.",
			"The Car row has the same position in all three client builds examined (1.28.146, 1.60.231, 1.73.89).",
		]},
}


# --- entry point -------------------------------------------------------------------------

static func validate(level: Dictionary, world: Variant, opts: Dictionary = {}) -> Dictionary:
	var mx := int(opts.get("max_examples", MAX_EXAMPLES))
	var wm := world_model(world)
	var reg: Dictionary = opts.get("registration", REGISTRATION)
	var checks: Array = []
	checks.append(_check_map_size(level, wm))
	checks.append(_check_ground(level, wm, mx))
	checks.append(_check_expansion_tiles(level, wm, mx))
	checks.append(_check_plot_overlaps(wm, mx))
	checks.append(_check_plot_boundaries(wm, mx))
	var defs := _check_expansion_definitions(level, wm, opts.get("expansions", {}), opts.get("other_levels", {}), mx)
	checks.append(defs)
	var lms := _landmark_rows(level, wm, reg, opts.get("tables", {}), opts.get("tiles", {}))
	checks.append(_check_landmarks_present(lms, wm, mx))
	checks.append(_check_landmark_positions(lms, mx))
	checks.append(_check_landmark_footprints(lms, mx))
	checks.append(_check_rendering_anchors(lms, wm, mx))
	checks.append(_check_buildability(level, wm, opts.get("tiles", {}), mx))
	checks.append(_check_initial_objects(level, wm, mx))
	var fps: Variant = opts.get("footprints", null)
	if fps is Dictionary:
		for k in ["item_footprints", "footprint_corrections"]:
			if (fps as Dictionary).has(k):
				checks.append(fps[k])
	var counts := {"pass": 0, "warn": 0, "fail": 0}
	for c: Dictionary in checks:
		counts[c["status"]] = int(counts.get(c["status"], 0)) + 1
	var overall := "fail" if int(counts["fail"]) > 0 else ("warn" if int(counts["warn"]) > 0 else "pass")
	var gv := str(opts.get("game_version", ""))
	if gv.is_empty():
		gv = str(wm["provenance"].get("client_version", ""))
	var reg_rows: Array = []
	var names := reg.keys()
	names.sort()
	for k in names:
		var e: Dictionary = reg[k]
		reg_rows.append({"special_object": str(k), "rule": str(e.get("rule", RULE_TOP_CORNER)),
			"confidence": str(e.get("confidence", "")), "meaning": str(e.get("meaning", "")),
			"evidence": (e.get("evidence", []) as Array).duplicate()})
	return {
		"format": FORMAT, "version": VERSION, "game_version": gv,
		"generated": str(opts.get("generated", Time.get_datetime_string_from_system(true) + "Z")),
		"tool": str(opts.get("tool", TOOL)),
		"world": {"id": wm["id"], "kind": str(wm["provenance"].get("kind", "")),
			"client_version": str(wm["provenance"].get("client_version", "")),
			"generated": str(wm["provenance"].get("generated", ""))},
		"status": overall, "counts": counts, "checks": checks,
		"landmarks": lms, "registration": reg_rows,
		"expansion_definitions_not_on_map": (defs.get("not_on_map", []) as Array).duplicate(true),
	}


static func check(report: Dictionary, check_id: String) -> Dictionary:
	for c: Dictionary in report.get("checks", []):
		if str(c.get("id", "")) == check_id:
			return c
	return {}


static func _mk(id: String, title: String) -> Dictionary:
	return {"id": id, "title": title, "status": "pass", "compared": 0, "mismatches": 0, "examples": [], "notes": []}


static func _ex(c: Dictionary, mx: int, e: Variant) -> void:
	if (c["examples"] as Array).size() < mx:
		(c["examples"] as Array).append(e)


static func _finish(c: Dictionary, fail_on_mismatch: bool = true) -> Dictionary:
	if int(c["mismatches"]) > 0:
		c["status"] = "fail" if fail_on_mismatch else "warn"
	return c


# --- world model --------------------------------------------------------------------------

static func world_model(world: Variant) -> Dictionary:
	## Normalises a world.json dictionary or a FarmMap into the fields the checks
	## read. Overlapping rects are kept (a FarmMap's painted grid would hide them).
	var m := {"id": "", "size": Vector2i.ZERO, "provenance": {}, "ground": PackedInt32Array(), "ground_rect": Rect2i(),
		"regions": [], "plots": [], "landmarks": [], "initial_objects": [], "tile_types": {}, "errors": []}
	if world is FarmMap:
		var fm: FarmMap = world
		m["id"] = fm.id
		m["size"] = fm.size
		m["provenance"] = fm.provenance.duplicate(true)
		if fm.has_ground():
			var g := PackedInt32Array()
			g.resize(fm.ground.size())
			for i in fm.ground.size():
				g[i] = fm.ground[i]
			m["ground"] = g
			m["ground_rect"] = fm.ground_rect
		for reg in fm.regions:
			m["regions"].append({"id": str(reg["id"]), "kind": str(reg["kind_name"]), "rects": (reg["rects"] as Array).duplicate()})
		for p in fm.plots:
			m["plots"].append({"id": str(p["id"]), "game_id": int(p.get("game_id", -1)), "section": str(p.get("section", "")),
				"rects": (p["rects"] as Array).duplicate(), "tiles_field": int(p.get("tiles", -1))})
		for lm in fm.landmarks:
			m["landmarks"].append(lm.to_dict())
		for o in fm.initial_objects:
			m["initial_objects"].append(o.duplicate())
		for k in fm.tile_types:
			m["tile_types"][int(k)] = fm.tile_types[k]
		return m
	if not world is Dictionary:
		m["errors"].append("world is neither a dictionary nor a FarmMap")
		return m
	var d: Dictionary = world
	m["id"] = str(d.get("id", ""))
	m["provenance"] = (d.get("provenance") as Dictionary).duplicate(true) if d.get("provenance") is Dictionary else {}
	var sz: Variant = d.get("size", [])
	if sz is Array and (sz as Array).size() == 2:
		m["size"] = Vector2i(int(sz[0]), int(sz[1]))
	var tt: Variant = d.get("tile_types", {})
	if tt is Dictionary:
		for k in tt:
			if str(k).is_valid_int() and tt[k] is Dictionary:
				m["tile_types"][int(str(k))] = tt[k]
	_model_ground(m, d.get("ground", null))
	# Regions (painted in order) and the plots among them; sections may list plots too.
	var region_list: Array = d.get("regions", []) if d.get("regions") is Array else []
	for r in region_list:
		if not r is Dictionary:
			continue
		var rects := _rects(r.get("rects", []))
		var kind := str(r.get("kind", "buildable"))
		m["regions"].append({"id": str(r.get("id", "")), "kind": kind, "rects": rects})
		if kind == "plot":
			var gid: Variant = r.get("game_id", -1)
			var tf: Variant = r.get("tiles", -1)
			m["plots"].append({"id": str(r.get("id", "")), "game_id": int(gid) if (gid is int or gid is float) else -1,
				"section": str(r.get("section", "")), "rects": rects,
				"tiles_field": int(tf) if (tf is int or tf is float) else -1})
	for l in d.get("landmarks", []) if d.get("landmarks") is Array else []:
		if l is Dictionary:
			m["landmarks"].append(l)
	for o in d.get("initial_objects", []) if d.get("initial_objects") is Array else []:
		if o is Dictionary:
			m["initial_objects"].append(o)
	return m


static func _rects(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for a in v:
			if a is Array and (a as Array).size() == 4:
				out.append(Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3])))
	return out


static func _model_ground(m: Dictionary, g: Variant) -> void:
	if not g is Dictionary:
		return
	if str(g.get("encoding", "rle-rows")) != "rle-rows":
		m["errors"].append("ground: unknown encoding")
		return
	var gr := Rect2i(Vector2i.ZERO, m["size"])
	if g.get("rect") is Array and (g["rect"] as Array).size() == 4:
		var a: Array = g["rect"]
		gr = Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))
	var rows: Variant = g.get("rows", [])
	if not rows is Array or (rows as Array).size() != gr.size.y:
		m["errors"].append("ground: expected %d rows" % gr.size.y)
		return
	var out := PackedInt32Array()
	out.resize(gr.size.x * gr.size.y)
	out.fill(-1)
	for y in gr.size.y:
		var x := 0
		var row: Variant = rows[y]
		if not row is Array:
			m["errors"].append("ground: row %d is not a list" % y)
			return
		for run in row:
			if not run is Array or (run as Array).size() != 2:
				m["errors"].append("ground: row %d has a bad run" % y)
				return
			var v := int(run[0])
			var c := int(run[1])
			for i in c:
				if x < gr.size.x:
					out[y * gr.size.x + x] = v
				x += 1
		if x != gr.size.x:
			m["errors"].append("ground: row %d covers %d of %d tiles" % [y, x, gr.size.x])
	m["ground"] = out
	m["ground_rect"] = gr


static func _ground_at(m: Dictionary, x: int, y: int) -> int:
	var gr: Rect2i = m["ground_rect"]
	if (m["ground"] as PackedInt32Array).is_empty() or not gr.has_point(Vector2i(x, y)):
		return -1
	return (m["ground"] as PackedInt32Array)[(y - gr.position.y) * gr.size.x + (x - gr.position.x)]


static func _plot_cover(m: Dictionary) -> Dictionary:
	## Per tile of the world grid: how many plot rect tiles cover it, and the game
	## id of the first plot covering it (-1 none, -2 plot without a game id).
	var sz: Vector2i = m["size"]
	var cnt := PackedInt32Array()
	var gid := PackedInt32Array()
	var owner := PackedInt32Array()
	cnt.resize(sz.x * sz.y)
	cnt.fill(0)
	gid.resize(sz.x * sz.y)
	gid.fill(-1)
	owner.resize(sz.x * sz.y)
	owner.fill(-1)
	var outside := 0
	for pi in (m["plots"] as Array).size():
		var p: Dictionary = m["plots"][pi]
		for r: Rect2i in p["rects"]:
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					if x < 0 or y < 0 or x >= sz.x or y >= sz.y:
						outside += 1
						continue
					var i := y * sz.x + x
					cnt[i] += 1
					if owner[i] < 0:
						owner[i] = pi
						gid[i] = int(p["game_id"]) if int(p["game_id"]) > 0 else -2
	return {"count": cnt, "game_id": gid, "owner": owner, "outside": outside}


static func _kinds(m: Dictionary) -> PackedStringArray:
	## World tile kind per grid tile, painted in region order like FarmMap.
	var sz: Vector2i = m["size"]
	var out := PackedStringArray()
	out.resize(sz.x * sz.y)
	out.fill("void")
	for reg: Dictionary in m["regions"]:
		for r: Rect2i in reg["rects"]:
			for y in range(maxi(r.position.y, 0), mini(r.end.y, sz.y)):
				for x in range(maxi(r.position.x, 0), mini(r.end.x, sz.x)):
					out[y * sz.x + x] = str(reg["kind"])
	return out


# --- tiles and expansions -------------------------------------------------------------------

static func _check_map_size(level: Dictionary, m: Dictionary) -> Dictionary:
	var c := _mk("map_size", "Map size")
	var tm: Dictionary = level.get("tilemap", {})
	var cs := Vector2i(int(tm.get("width", 0)), int(tm.get("height", 0)))
	var ws: Vector2i = m["size"]
	c["client"] = [cs.x, cs.y]
	c["world"] = [ws.x, ws.y]
	c["compared"] = 1
	if cs != ws:
		c["mismatches"] = 1
		_ex(c, 1, {"client": [cs.x, cs.y], "world": [ws.x, ws.y]})
	return _finish(c)


static func _check_ground(level: Dictionary, m: Dictionary, mx: int) -> Dictionary:
	## Ground type per tile: client raw % 100 against the world's ground layer.
	var c := _mk("ground", "Ground type per tile")
	var tm: Dictionary = level.get("tilemap", {})
	var w := int(tm.get("width", 0))
	var h := int(tm.get("height", 0))
	if (m["ground"] as PackedInt32Array).is_empty():
		c["status"] = "fail"
		c["notes"].append("The world has no ground layer to compare.")
		return c
	var raw: PackedInt32Array = tm.get("raw", PackedInt32Array())
	var missing := 0
	for y in h:
		for x in w:
			var want := ClientLevel.ground_of(raw[y * w + x])
			var got := _ground_at(m, x, y)
			c["compared"] = int(c["compared"]) + 1
			if got < 0:
				missing += 1
			if got != want:
				c["mismatches"] = int(c["mismatches"]) + 1
				_ex(c, mx, {"tile": [x, y], "client": want, "world": got})
	c["outside_world_ground"] = missing
	return _finish(c)


static func _check_expansion_tiles(level: Dictionary, m: Dictionary, mx: int) -> Dictionary:
	## Expansion id per tile: client raw // 100 against the union of the world's
	## plot rects (plot game_id).
	var c := _mk("expansion_tiles", "Expansion id per tile")
	var tm: Dictionary = level.get("tilemap", {})
	var w := int(tm.get("width", 0))
	var h := int(tm.get("height", 0))
	var raw: PackedInt32Array = tm.get("raw", PackedInt32Array())
	var cov := _plot_cover(m)
	var sz: Vector2i = m["size"]
	var wrong := 0
	var missing := 0
	var extra := 0
	for y in h:
		for x in w:
			var want := ClientLevel.expansion_of(raw[y * w + x])
			var got := -1
			if x < sz.x and y < sz.y:
				got = (cov["game_id"] as PackedInt32Array)[y * sz.x + x]
			if want > 0:
				c["compared"] = int(c["compared"]) + 1
				if got == -1:
					missing += 1
					_ex(c, mx, {"tile": [x, y], "client": want, "world": null, "problem": "missing"})
				elif got != want:
					wrong += 1
					_ex(c, mx, {"tile": [x, y], "client": want, "world": got, "problem": "different id"})
			elif got != -1:
				extra += 1
				_ex(c, mx, {"tile": [x, y], "client": null, "world": got, "problem": "extra"})
	# World plot tiles beyond the client map.
	for y in sz.y:
		for x in sz.x:
			if (x >= w or y >= h) and (cov["game_id"] as PackedInt32Array)[y * sz.x + x] != -1:
				extra += 1
	c["different_id"] = wrong
	c["missing"] = missing
	c["extra"] = extra
	c["outside_map"] = int(cov["outside"])
	c["mismatches"] = wrong + missing + extra + int(cov["outside"])
	return _finish(c)


static func _check_plot_overlaps(m: Dictionary, mx: int) -> Dictionary:
	var c := _mk("plot_overlaps", "Duplicate plot assignment (overlapping plot rects)")
	var cov := _plot_cover(m)
	var cnt: PackedInt32Array = cov["count"]
	var sz: Vector2i = m["size"]
	var tiles := 0
	for i in cnt.size():
		if cnt[i] > 0:
			tiles += 1
		if cnt[i] > 1:
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"tile": [i % sz.x, i / sz.x], "plots_covering": cnt[i]})
	c["compared"] = tiles
	# Two plots with the same game id are a duplicate assignment too.
	var seen := {}
	var dup := 0
	for p: Dictionary in m["plots"]:
		var g := int(p["game_id"])
		if g <= 0:
			continue
		if seen.has(g):
			dup += 1
			_ex(c, mx, {"game_id": g, "plots": [seen[g], p["id"]]})
		else:
			seen[g] = p["id"]
	c["duplicate_game_ids"] = dup
	c["mismatches"] = int(c["mismatches"]) + dup
	return _finish(c)


static func _check_plot_boundaries(m: Dictionary, mx: int) -> Dictionary:
	## Every plot rect must be non-empty and inside the map; every plot needs a
	## game id; a plot's tiles should be one 4-connected piece and its stored
	## tile count should equal its rects. Disconnected plots only warn.
	var c := _mk("plot_boundaries", "Plot boundaries")
	var sz: Vector2i = m["size"]
	var warn := 0
	for p: Dictionary in m["plots"]:
		c["compared"] = int(c["compared"]) + 1
		var tiles := {}
		var bad := ""
		if (p["rects"] as Array).is_empty():
			bad = "no rects"
		for r: Rect2i in p["rects"]:
			if r.size.x <= 0 or r.size.y <= 0:
				bad = "empty rect %s" % str(r)
			elif r.position.x < 0 or r.position.y < 0 or r.end.x > sz.x or r.end.y > sz.y:
				bad = "rect %s outside the %dx%d map" % [str(r), sz.x, sz.y]
			for y in range(r.position.y, r.end.y):
				for x in range(r.position.x, r.end.x):
					tiles[Vector2i(x, y)] = true
		if bad.is_empty() and int(p["game_id"]) <= 0:
			bad = "no game id"
		if not bad.is_empty():
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"plot": p["id"], "problem": bad})
			continue
		var tf := int(p.get("tiles_field", -1))
		if tf >= 0 and tf != tiles.size():
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"plot": p["id"], "problem": "tiles field %d but rects cover %d" % [tf, tiles.size()]})
			continue
		if not _connected(tiles):
			warn += 1
			_ex(c, mx, {"plot": p["id"], "problem": "tiles are not one connected piece"})
	c["disconnected"] = warn
	_finish(c)
	if c["status"] == "pass" and warn > 0:
		c["status"] = "warn"
	return c


static func _connected(tiles: Dictionary) -> bool:
	if tiles.size() <= 1:
		return true
	var start: Vector2i = tiles.keys()[0]
	var seen := {start: true}
	var stack: Array[Vector2i] = [start]
	while not stack.is_empty():
		var t: Vector2i = stack.pop_back()
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := t + d
			if tiles.has(n) and not seen.has(n):
				seen[n] = true
				stack.append(n)
	return seen.size() == tiles.size()


static func _check_expansion_definitions(level: Dictionary, m: Dictionary, expansions: Dictionary,
		other_levels: Dictionary, mx: int) -> Dictionary:
	## Expansion definitions (expansions.csv: data row k = expansion id k) against
	## the ids on the client map and the world's plots. Definitions that are not
	## on the map are listed with the reason the data gives; they are not world
	## errors. Fails when the world's plot ids differ from the map's ids or when
	## the map uses an id without a definition.
	var c := _mk("expansion_definitions", "Expansion definitions vs map")
	var on_map := ClientLevel.expansion_ids(level)
	var world_ids := {}
	var section_of := {}
	for p: Dictionary in m["plots"]:
		var g := int(p["game_id"])
		if g > 0:
			world_ids[g] = true
			section_of[g] = str(p.get("section", ""))
	var defs: Array = expansions.get("rows", []) if expansions is Dictionary else []
	c["definitions"] = defs.size()
	c["on_map"] = on_map.size()
	c["world_plots"] = world_ids.size()
	c["compared"] = on_map.size()
	var not_in_world: Array = []
	var not_on_map_world: Array = []
	for g in on_map:
		if not world_ids.has(g):
			not_in_world.append(g)
	for g in world_ids:
		if not on_map.has(g):
			not_on_map_world.append(g)
	not_in_world.sort()
	not_on_map_world.sort()
	c["map_ids_without_world_plot"] = not_in_world
	c["world_plots_not_on_map"] = not_on_map_world
	c["mismatches"] = not_in_world.size() + not_on_map_world.size()
	for g in not_in_world.slice(0, mx):
		_ex(c, mx, {"game_id": g, "problem": "on the client map but no world plot"})
	for g in not_on_map_world.slice(0, mx):
		_ex(c, mx, {"game_id": g, "problem": "world plot not on the client map"})
	var not_on_map: Array = []
	if not defs.is_empty():
		var undefined: Array = []
		for g in on_map:
			if int(g) > defs.size():
				undefined.append(g)
		undefined.sort()
		c["map_ids_without_definition"] = undefined
		c["mismatches"] = int(c["mismatches"]) + undefined.size()
		for k in range(1, defs.size() + 1):
			if on_map.has(k):
				continue
			not_on_map.append(_absent_definition(k, defs, on_map, section_of, other_levels))
	else:
		c["notes"].append("No expansion table given: definitions not compared.")
	c["not_on_map"] = not_on_map
	var ids: Array = []
	for e: Dictionary in not_on_map:
		ids.append(e["id"])
	if not ids.is_empty():
		c["notes"].append("%d definition(s) have no tiles on the map: %s (listed with the reason found; not missing land)." % [ids.size(), ", ".join(PackedStringArray(ids.map(func(v): return str(v))))])
	return _finish(c)


static func _absent_definition(k: int, defs: Array, on_map: Dictionary, section_of: Dictionary, other_levels: Dictionary) -> Dictionary:
	var row: Dictionary = defs[k - 1]
	var amounts := ClientLevel.tool_amounts(row)
	var key_tool := str(row.get("LimitedCollectionTool", ""))
	var key_amount := str(row.get("LimitedCollectionToolAmount", "")).strip_edges()
	var reasons: Array = []
	var kind := "unused"
	var all_big := not amounts.is_empty()
	for t in amounts:
		all_big = all_big and int(amounts[t]) >= 1000
	if all_big:
		kind = "placeholder"
		reasons.append("placeholder cost: every tool amount is 1000 or more%s" % (" and no %s amount" % key_tool if not key_tool.is_empty() and key_amount.is_empty() else ""))
	for flag in ["Disabled", "Locked"]:
		if ClientLevel._bool(str(row.get(flag, ""))):
			reasons.append("%s=TRUE in the table" % flag)
	# Neighbouring ids on the map: a numbering gap inside a section?
	var lo := k - 1
	while lo > 0 and not on_map.has(lo):
		lo -= 1
	var hi := k + 1
	while hi <= defs.size() and not on_map.has(hi):
		hi += 1
	var sec_lo := str(section_of.get(lo, ""))
	var sec_hi := str(section_of.get(hi, ""))
	if lo > 0 and hi <= defs.size():
		if not sec_lo.is_empty() and sec_lo == sec_hi:
			reasons.append("numbering gap: ids %d and %d around it are both in world section '%s'" % [lo, hi, sec_lo])
		else:
			reasons.append("between map ids %d (%s) and %d (%s)" % [lo, sec_lo if not sec_lo.is_empty() else "?", hi, sec_hi if not sec_hi.is_empty() else "?"])
	if kind != "placeholder":
		var same := false
		if lo > 0:
			same = same or amounts == ClientLevel.tool_amounts(defs[lo - 1])
		if hi <= defs.size():
			same = same or amounts == ClientLevel.tool_amounts(defs[hi - 1])
		if same:
			reasons.append("regular cost, equal to a neighbouring definition's")
	var elsewhere: Array = []
	for ln in other_levels:
		if ClientLevel.expansion_ids(other_levels[ln]).has(k):
			elsewhere.append(str(ln))
	if elsewhere.is_empty():
		reasons.append("no tiles in this level%s" % (" or in the other level files given (%d)" % other_levels.size() if not other_levels.is_empty() else ""))
	else:
		kind = "other_level"
		reasons.append("has tiles in other level file(s) %s (those may use their own expansion table)" % ", ".join(PackedStringArray(elsewhere)))
	if kind == "unused" and not reasons.is_empty():
		reasons.append("purpose not stated in the data: an unused or retired definition")
	return {"id": k, "name": str(row.get(str((row.keys()[0])), "")), "kind": kind, "costs": amounts,
		"key_amount": key_amount, "other_levels": elsewhere, "reasons": reasons}


# --- landmarks ----------------------------------------------------------------------------

static func _footprint_source(lm: Dictionary) -> Array:
	## [table, row] of the client size table the landmark's footprint comes from:
	## explicit footprint_table / footprint_row, else the private builder's
	## evidence text "footprint <table>.csv <Row>".
	if lm.has("footprint_table") and lm.has("footprint_row"):
		return [str(lm["footprint_table"]), str(lm["footprint_row"])]
	var re := RegEx.create_from_string("footprint ([A-Za-z0-9_]+)\\.csv ([^;(]+)")
	var mt := re.search(str(lm.get("evidence", "")))
	if mt == null:
		return []
	return [mt.get_string(1), mt.get_string(2).strip_edges()]


static func expected_origin(rule: String, source: Vector2i, size: Vector2i) -> Vector2i:
	## Footprint origin implied by a registration rule (see REGISTRATION).
	if rule == RULE_CENTERED:
		return source - Vector2i(size.x / 2, size.y / 2)
	return source


static func _landmark_rows(level: Dictionary, m: Dictionary, reg: Dictionary, tables: Dictionary, tiles: Dictionary) -> Array:
	var by_so := {}
	for lm: Dictionary in m["landmarks"]:
		var so := str(lm.get("special_object", ""))
		if not so.is_empty():
			by_so[so] = lm
	var rows: Array = []
	var seen := {}
	for so: Dictionary in level.get("special_objects", []):
		var name := str(so["name"])
		var src := Vector2i(int(so["x"]), int(so["y"]))
		var rule_rec: Dictionary = reg.get(name, reg.get("_default", {"rule": RULE_TOP_CORNER}))
		var rule := str(rule_rec.get("rule", RULE_TOP_CORNER))
		var row := {"special_object": name, "source": [src.x, src.y], "mirrored": bool(so.get("mirrored", false)),
			"rule": rule, "rule_confidence": str(rule_rec.get("confidence", "")), "landmark": "", "status": "pass", "problems": []}
		if not by_so.has(name):
			row["status"] = "fail"
			row["problems"].append("missing in the world")
			rows.append(row)
			continue
		var lm: Dictionary = by_so[name]
		seen[name] = true
		row["landmark"] = str(lm.get("id", ""))
		var wo := _v2i(lm.get("origin", []))
		var wf := _v2i(lm.get("footprint", []), Vector2i.ONE)
		row["world_origin"] = [wo.x, wo.y]
		row["world_footprint"] = [wf.x, wf.y]
		row["draw_anchor"] = str(lm.get("draw_anchor", "top_corner"))
		# Client footprint (TileWidth x TileHeight; mirrored swaps it).
		var csize := Vector2i.ZERO
		var fs := _footprint_source(lm)
		if not fs.is_empty() and tables.has(fs[0]):
			csize = ClientLevel.tile_size(ClientLevel.table_row(tables[fs[0]], fs[1]))
			row["client_table"] = "%s/%s" % [fs[0], fs[1]]
		if csize != Vector2i.ZERO and bool(row["mirrored"]):
			csize = Vector2i(csize.y, csize.x)
		row["client_footprint"] = [csize.x, csize.y] if csize != Vector2i.ZERO else null
		var size_for_rule := csize if csize != Vector2i.ZERO else wf
		var eo := expected_origin(rule, src, size_for_rule)
		row["expected_origin"] = [eo.x, eo.y]
		row["delta_from_source"] = [wo.x - src.x, wo.y - src.y]
		row["shift"] = [wo.x - eo.x, wo.y - eo.y]
		if wo != eo:
			row["status"] = "fail"
			row["problems"].append("origin %s, expected %s by the %s rule" % [str(wo), str(eo), rule])
		if csize != Vector2i.ZERO and csize != wf:
			row["status"] = "fail"
			row["problems"].append("footprint %s, client %s" % [str(wf), str(csize)])
		if str(rule_rec.get("check", "")) == "blocked_cells":
			row["evidence_check"] = _blocked_cells_check(level, tiles, src, size_for_rule, eo)
			if not bool(row["evidence_check"].get("supports_rule", false)):
				if row["status"] == "pass":
					row["status"] = "warn"
				row["problems"].append("the data no longer supports the %s rule: %s" % [rule, str(row["evidence_check"].get("text", ""))])
		rows.append(row)
	for lm: Dictionary in m["landmarks"]:
		var so := str(lm.get("special_object", ""))
		if so.is_empty() or not seen.has(so):
			rows.append({"special_object": so, "landmark": str(lm.get("id", "")), "source": null, "status": "fail" if not so.is_empty() else "warn",
				"problems": ["world landmark without a client SpecialObjects row" if not so.is_empty() else "world landmark not linked to a SpecialObjects row"],
				"world_origin": lm.get("origin", null), "rule": "", "extra": true})
	return rows


static func _blocked_cells_check(level: Dictionary, tiles: Dictionary, src: Vector2i, size: Vector2i, eo: Vector2i) -> Dictionary:
	## Evidence test for centred objects: the non-passable, building-blocking
	## ground cells of the TileMap that touch the object's column/row near its
	## source position. The rule is supported when those cells are exactly the
	## derived footprint and the plain top-corner footprint is not.
	var rows: Array = tiles.get("rows", []) if tiles is Dictionary else []
	if rows.is_empty():
		return {"supports_rule": false, "text": "no tile table given", "blocked": []}
	var span := Rect2i(src - size, size * 3)
	var blocked: Array = []
	for y in range(span.position.y, span.end.y):
		for x in range(span.position.x, span.end.x):
			var raw := ClientLevel.raw_at(level, x, y)
			if raw < 0 or raw >= ClientLevel.EXPANSION_FACTOR:
				continue
			if raw >= rows.size():
				continue
			var t: Dictionary = rows[raw]
			if ClientLevel._bool(str(t.get("BlocksBuilding", ""))) and not ClientLevel._bool(str(t.get("Passable", ""))) \
					and _is_road_name(str(t.get("Name", ""))):
				blocked.append(Vector2i(x, y))
	var derived := Rect2i(eo, size)
	var top := Rect2i(src, size)
	var in_derived := 0
	var in_top := 0
	for b: Vector2i in blocked:
		if derived.has_point(b):
			in_derived += 1
		if top.has_point(b):
			in_top += 1
	var n := size.x * size.y
	var ok := blocked.size() == n and in_derived == n and (in_top < n or derived == top)
	var cells: Array = []
	for b: Vector2i in blocked:
		cells.append([b.x, b.y])
	return {"supports_rule": ok, "blocked": cells, "in_derived_footprint": in_derived, "in_top_corner_footprint": in_top,
		"text": "%d non-passable road cell(s) near the source; %d of %d under the derived footprint, %d under the top-corner footprint" % [blocked.size(), in_derived, n, in_top]}


static func _is_road_name(n: String) -> bool:
	return n.to_lower().begins_with("road")


static func _v2i(v: Variant, fallback: Vector2i = Vector2i.ZERO) -> Vector2i:
	if v is Array and (v as Array).size() == 2:
		return Vector2i(int(v[0]), int(v[1]))
	if v is Vector2i:
		return v
	return fallback


static func _check_landmarks_present(rows: Array, m: Dictionary, mx: int) -> Dictionary:
	var c := _mk("landmarks_present", "Landmarks present (SpecialObjects rows vs world landmarks)")
	var missing := 0
	var extra := 0
	for r: Dictionary in rows:
		if r.get("extra", false):
			extra += 1
			_ex(c, mx, {"landmark": r["landmark"], "problem": r["problems"][0]})
		else:
			c["compared"] = int(c["compared"]) + 1
			if str(r["landmark"]).is_empty():
				missing += 1
				_ex(c, mx, {"special_object": r["special_object"], "problem": "missing in the world"})
	c["client_rows"] = int(c["compared"])
	c["world_landmarks"] = (m["landmarks"] as Array).size()
	c["missing"] = missing
	c["extra"] = extra
	c["mismatches"] = missing + extra
	return _finish(c)


static func _check_landmark_positions(rows: Array, mx: int) -> Dictionary:
	var c := _mk("landmark_positions", "Landmark positions (registration rule per object)")
	var by_rule := {}
	var offset := 0
	for r: Dictionary in rows:
		if r.get("extra", false) or str(r["landmark"]).is_empty():
			continue
		c["compared"] = int(c["compared"]) + 1
		by_rule[r["rule"]] = int(by_rule.get(r["rule"], 0)) + 1
		var d: Array = r.get("delta_from_source", [0, 0])
		if int(d[0]) != 0 or int(d[1]) != 0:
			offset += 1
		var sh: Array = r.get("shift", [0, 0])
		if int(sh[0]) != 0 or int(sh[1]) != 0:
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"landmark": r["landmark"], "source": r["source"], "world_origin": r["world_origin"],
				"expected_origin": r["expected_origin"], "rule": r["rule"]})
		elif r.get("evidence_check") is Dictionary and not bool(r["evidence_check"].get("supports_rule", false)):
			_ex(c, mx, {"landmark": r["landmark"], "problem": "rule evidence not found", "detail": r["evidence_check"].get("text", "")})
	c["by_rule"] = by_rule
	c["world_origin_differs_from_source"] = offset
	c["notes"].append("%d landmark(s) are stored at an origin other than the client (X, Y); each is explained by its registration rule unless listed." % offset)
	_finish(c)
	for r: Dictionary in rows:
		if c["status"] == "pass" and str(r.get("status", "")) == "warn" and not r.get("extra", false):
			c["status"] = "warn"
	return c


static func _check_landmark_footprints(rows: Array, mx: int) -> Dictionary:
	var c := _mk("landmark_footprints", "Landmark footprints (client TileWidth x TileHeight)")
	var unknown := 0
	for r: Dictionary in rows:
		if r.get("extra", false) or str(r["landmark"]).is_empty():
			continue
		if r.get("client_footprint") == null:
			unknown += 1
			continue
		c["compared"] = int(c["compared"]) + 1
		if r["client_footprint"] != r["world_footprint"]:
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"landmark": r["landmark"], "client": r["client_footprint"], "world": r["world_footprint"]})
	c["no_client_size"] = unknown
	if unknown > 0:
		c["notes"].append("%d landmark(s) have no size in their client table (the world's size is an assumption)." % unknown)
	_finish(c)
	if c["status"] == "pass" and unknown > 0:
		c["status"] = "warn"
	return c


static func _check_rendering_anchors(rows: Array, m: Dictionary, mx: int) -> Dictionary:
	## The app draws a sprite with its anchor on the footprint centre; a pack
	## sprite whose anchor is the export's registration point ("center") is
	## therefore drawn where the client draws it only if the client's
	## registration point is that centre. The data can measure that distance;
	## whether top-corner sprites line up depends on art that is not checked
	## here. Never "pass": rendering is not verified against the game.
	var c := _mk("rendering_anchors", "Rendering anchors (not verified against the game)")
	c["verified"] = false
	var top := 0
	for r: Dictionary in rows:
		if r.get("extra", false) or str(r["landmark"]).is_empty():
			continue
		c["compared"] = int(c["compared"]) + 1
		if str(r.get("draw_anchor", "top_corner")) != "center":
			top += 1
			continue
		var o := _v2i(r["world_origin"])
		var f := _v2i(r["world_footprint"], Vector2i.ONE)
		var app_pt := Vector2(o) + Vector2(f) * 0.5
		var src := _v2i(r["source"])
		var client_pt := Vector2(src) if str(r["rule"]) == RULE_CENTERED else Vector2(src) + Vector2(f) * 0.5
		var d := Iso.grid_to_world(app_pt) - Iso.grid_to_world(client_pt)
		r["anchor_offset_px"] = [snappedf(d.x, 0.01), snappedf(d.y, 0.01)]
		if d.length() > 0.5:
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"landmark": r["landmark"], "app_anchor_grid": [app_pt.x, app_pt.y], "client_registration_grid": [client_pt.x, client_pt.y],
				"offset_world_px": [snappedf(d.x, 0.01), snappedf(d.y, 0.01)], "distance_px": snappedf(d.length(), 0.01)})
	c["top_corner_sprites"] = top
	c["notes"].append("%d landmark sprite(s) are anchored on the top corner of their footprint by construction; not compared with game screenshots." % top)
	if int(c["mismatches"]) > 0:
		c["notes"].append("Centre-anchored sprites are drawn at the footprint centre, which differs from the client registration point by the listed offset (world px; one tile is 64 x 32).")
	c["status"] = "warn"
	return c


static func _check_buildability(level: Dictionary, m: Dictionary, tiles: Dictionary, mx: int) -> Dictionary:
	## Buildable (or expansion) world tiles must be exactly the client tiles
	## whose ground type does not block building.
	var c := _mk("buildability", "Buildability vs ground type")
	var blocks := {}
	var src := ""
	var trows: Array = tiles.get("rows", []) if tiles is Dictionary else []
	if not trows.is_empty():
		for i in trows.size():
			blocks[i] = ClientLevel._bool(str(trows[i].get("BlocksBuilding", "")))
		src = "client tile table"
	else:
		for k in m["tile_types"]:
			blocks[int(k)] = bool(m["tile_types"][k].get("blocks_building", false))
		src = "world tile_types (no client tile table given)"
	c["rule_source"] = src
	if blocks.is_empty():
		c["status"] = "warn"
		c["notes"].append("No tile type table: buildability not compared.")
		return c
	var kinds := _kinds(m)
	var tm: Dictionary = level.get("tilemap", {})
	var w := int(tm.get("width", 0))
	var h := int(tm.get("height", 0))
	var raw: PackedInt32Array = tm.get("raw", PackedInt32Array())
	var sz: Vector2i = m["size"]
	var unknown_types := {}
	for y in mini(h, sz.y):
		for x in mini(w, sz.x):
			var gt := ClientLevel.ground_of(raw[y * w + x])
			if not blocks.has(gt):
				unknown_types[gt] = true
				continue
			c["compared"] = int(c["compared"]) + 1
			var client_buildable := not bool(blocks[gt])
			var k := kinds[y * sz.x + x]
			var world_buildable := k == "buildable" or k == "plot"
			if client_buildable != world_buildable:
				c["mismatches"] = int(c["mismatches"]) + 1
				_ex(c, mx, {"tile": [x, y], "ground_type": gt, "client_buildable": client_buildable, "world_kind": k})
	if not unknown_types.is_empty():
		c["notes"].append("Ground types without a tile-table row: %s" % str(unknown_types.keys()))
	_finish(c)
	if c["status"] == "pass" and src.begins_with("world"):
		c["status"] = "warn"
	return c


static func _check_initial_objects(level: Dictionary, m: Dictionary, mx: int) -> Dictionary:
	## The world's initial (seed) objects must exist in the client's Objects
	## sections at the same tile and mirroring (and in the same section when the
	## world names it). The world's `game_name` may be a display name rather
	## than the client row name, so a different name at the same place is only
	## counted. Client objects that the world does not carry are counted, not
	## failed (the pack may skip objects it cannot map to a catalogue item).
	var c := _mk("initial_objects", "Initial objects (client Objects sections)")
	var by_place := {}
	var n_client := 0
	for o: Dictionary in ClientLevel.all_objects(level):
		o["_i"] = n_client
		for key in [_place_key(str(o["group"]), int(o["x"]), int(o["y"]), bool(o["mirrored"])),
				_place_key("", int(o["x"]), int(o["y"]), bool(o["mirrored"]))]:
			if not by_place.has(key):
				by_place[key] = []
			(by_place[key] as Array).append(o)
		n_client += 1
	c["client_objects"] = n_client
	c["world_objects"] = (m["initial_objects"] as Array).size()
	if (m["initial_objects"] as Array).is_empty():
		c["notes"].append("The world carries no initial objects.")
		c["status"] = "warn" if n_client > 0 else "pass"
		return c
	var used := {}
	var renamed := 0
	var matched := 0
	for o: Dictionary in m["initial_objects"]:
		c["compared"] = int(c["compared"]) + 1
		var x := int(o.get("x", 0))
		var y := int(o.get("y", 0))
		var fl := bool(o.get("flip", false))
		var cands: Array = by_place.get(_place_key(str(o.get("source_group", "")), x, y, fl), [])
		var hit: Dictionary = {}
		for cand: Dictionary in cands:
			if not used.has(int(cand["_i"])):
				hit = cand
				break
		if hit.is_empty():
			c["mismatches"] = int(c["mismatches"]) + 1
			_ex(c, mx, {"game_name": str(o.get("game_name", "")), "tile": [x, y], "flip": fl, "group": str(o.get("source_group", "")),
				"problem": "no client object at this tile with this mirroring"})
			continue
		used[int(hit["_i"])] = true
		matched += 1
		var gn := str(o.get("game_name", ""))
		if not gn.is_empty() and gn != str(hit["name"]):
			renamed += 1
	c["matched"] = matched
	c["name_differs"] = renamed
	c["client_not_in_world"] = n_client - matched
	if renamed > 0:
		c["notes"].append("%d matched object(s) carry a display name instead of the client row name (same tile, mirroring and section)." % renamed)
	if n_client - matched > 0:
		c["notes"].append("%d client object(s) are not carried by the world (not mapped to a catalogue item, or skipped by the pack builder)." % (n_client - matched))
	return _finish(c)


static func _place_key(group: String, x: int, y: int, mirrored: bool) -> String:
	return "%s|%d|%d|%s" % [group, x, y, "m" if mirrored else "-"]


# --- item footprints --------------------------------------------------------------------

static func client_size_index(tables: Dictionary) -> Dictionary:
	## {"by_name": {"table/Name": {table, name, size, export, file}}, "by_export": {export: [rec, ...]}}
	## over every table with TileWidth / TileHeight (first row of each entry).
	var by_name := {}
	var by_export := {}
	var names := tables.keys()
	names.sort()
	for tn in names:
		var t: Dictionary = tables[tn]
		if not ClientLevel.has_size(t):
			continue
		for r: Dictionary in t["rows"]:
			var nm := str(r.get(str(t["header"][0]), ""))
			var sz := ClientLevel.tile_size(r)
			var rec := {"table": str(tn), "name": nm, "size": sz, "export": str(r.get("ExportName", "")),
				"file": str(r.get("FileName", "")).get_file().get_basename()}
			by_name["%s/%s" % [tn, nm]] = rec
			if not str(rec["export"]).is_empty():
				if not by_export.has(rec["export"]):
					by_export[rec["export"]] = []
				(by_export[rec["export"]] as Array).append(rec)
	return {"by_name": by_name, "by_export": by_export}


static func _override_link(entry: Dictionary) -> Array:
	## [table, Name] from a catalogue-override evidence text
	## ("assets/data/<table>.csv line N Name=<Name> TileWidth=...").
	var re := RegEx.create_from_string("([A-Za-z0-9_]+)\\.csv line \\d+ Name=(.+?)(?: TileWidth=| UnlockLevel=| \\(|$)")
	for k in ["evidence", "unlock_evidence"]:
		var mt := re.search(str(entry.get(k, "")))
		if mt != null:
			return [mt.get_string(1), mt.get_string(2).strip_edges()]
	return []


static func compare_footprints(db: ItemDatabase, tables: Dictionary, overrides: Variant, sprites: Dictionary = {},
		mx: int = MAX_EXAMPLES) -> Dictionary:
	## Client TileWidth x TileHeight against the catalogue footprints as the app
	## uses them (after the pack's catalog_overrides were applied to `db`).
	## Items are linked to a client row by the override's evidence (table + Name)
	## or by the pack sprite's export name (the sprite only identifies the row;
	## its pixel size is never used). Sizes come from the tables alone.
	var idx := client_size_index(tables)
	var ov: Dictionary = (overrides.get("items", {}) if overrides is Dictionary else {}) as Dictionary
	var structural: Dictionary = (overrides.get("structural", {}) if overrides is Dictionary else {}) as Dictionary
	var fpc := _mk("item_footprints", "Item footprints (client size vs catalogue after pack overrides)")
	var links := {"override": 0, "export": 0}
	var unlinked := 0
	var ambiguous := 0
	var no_size := 0
	var swaps := 0
	var n_match := 0
	var skipped := 0
	if db == null:
		fpc["status"] = "warn"
		fpc["notes"].append("No catalogue given.")
		return {"item_footprints": fpc, "footprint_corrections": _mk("footprint_corrections", "Footprint corrections from the pack")}
	for it: ItemDef in db.ordered:
		if structural.has(it.id) or it.category == "planning":
			skipped += 1
			continue
		var rec: Dictionary = {}
		var how := ""
		if ov.has(it.id) and ov[it.id] is Dictionary:
			var l := _override_link(ov[it.id])
			if not l.is_empty() and idx["by_name"].has("%s/%s" % [l[0], l[1]]):
				rec = idx["by_name"]["%s/%s" % [l[0], l[1]]]
				how = "override"
		if rec.is_empty() and sprites.has(it.id) and sprites[it.id] is Dictionary:
			var src: Variant = sprites[it.id].get("source", {})
			if src is Dictionary and str(src.get("kind", "")) == "apk" and not str(src.get("export", "")).is_empty():
				var cands: Array = idx["by_export"].get(str(src["export"]), [])
				var sc := str(src.get("sc", ""))
				var same_file := cands.filter(func(r): return sc.is_empty() or str(r["file"]).is_empty() or str(r["file"]) == sc)
				if not same_file.is_empty():
					cands = same_file
				var sizes := {}
				for r: Dictionary in cands:
					sizes[r["size"]] = r
				if sizes.size() == 1:
					rec = sizes.values()[0]
					how = "export"
				elif sizes.size() > 1:
					ambiguous += 1
		if rec.is_empty():
			unlinked += 1
			continue
		var cs: Vector2i = rec["size"]
		if cs == Vector2i.ZERO:
			no_size += 1
			continue
		links[how] = int(links[how]) + 1
		fpc["compared"] = int(fpc["compared"]) + 1
		if it.footprint == cs:
			n_match += 1
		elif it.footprint == Vector2i(cs.y, cs.x):
			swaps += 1
			_ex(fpc, mx, {"item": it.id, "app": [it.footprint.x, it.footprint.y], "client": [cs.x, cs.y], "client_row": "%s/%s" % [rec["table"], rec["name"]],
				"problem": "axes swapped (same tiles)", "flippable": it.flippable})
		else:
			fpc["mismatches"] = int(fpc["mismatches"]) + 1
			_ex(fpc, mx, {"item": it.id, "app": [it.footprint.x, it.footprint.y], "client": [cs.x, cs.y], "client_row": "%s/%s" % [rec["table"], rec["name"]],
				"status": it.footprint_status, "linked_by": how})
	fpc["matched"] = n_match
	fpc["axis_swapped"] = swaps
	fpc["unlinked"] = unlinked
	fpc["ambiguous_links"] = ambiguous
	fpc["client_row_without_size"] = no_size
	fpc["skipped_structural_or_planning"] = skipped
	fpc["linked_by"] = links
	fpc["catalogue_items"] = db.ordered.size()
	fpc["overrides_pack"] = db.overrides_pack
	fpc["notes"].append("Sizes are client TileWidth x TileHeight only; sprite art identifies the client row but its size is never used as occupancy.")
	fpc["notes"].append("%d catalogue item(s) could not be linked to a client row (no override evidence and no unique export)." % unlinked)
	_finish(fpc)
	if fpc["status"] == "pass" and swaps > 0:
		fpc["status"] = "warn"
	# Corrections shipped by the pack: present in the catalogue the app uses?
	var cc := _mk("footprint_corrections", "Footprint corrections from the pack applied")
	var applied_pack := db.overrides_pack
	var with_fp := 0
	var present := 0
	var agrees := 0
	var unknown_items := 0
	for iid in ov:
		var e: Variant = ov[iid]
		if not e is Dictionary or not (e as Dictionary).has("footprint") or e["footprint"] == null:
			continue
		with_fp += 1
		var it := db.get_item(str(iid))
		if it == null:
			unknown_items += 1
			_ex(cc, mx, {"item": str(iid), "problem": "not in the catalogue"})
			continue
		var want := Vector2i(int(e["footprint"][0]), int(e["footprint"][1]))
		cc["compared"] = int(cc["compared"]) + 1
		if it.footprint == want and it.footprint_status == "game_data":
			present += 1
		else:
			cc["mismatches"] = int(cc["mismatches"]) + 1
			_ex(cc, mx, {"item": str(iid), "override": [want.x, want.y], "app": [it.footprint.x, it.footprint.y], "status": it.footprint_status})
		var l := _override_link(e)
		if not l.is_empty() and idx["by_name"].has("%s/%s" % [l[0], l[1]]) and idx["by_name"]["%s/%s" % [l[0], l[1]]]["size"] == want:
			agrees += 1
	cc["overrides_with_footprint"] = with_fp
	cc["present"] = present
	cc["agree_with_client_tables"] = agrees
	cc["unknown_items"] = unknown_items
	cc["overrides_pack"] = applied_pack
	if with_fp == 0:
		cc["status"] = "warn"
		cc["notes"].append("No footprint corrections given (no pack catalog_overrides).")
	elif applied_pack.is_empty():
		cc["notes"].append("The catalogue has no pack overrides applied.")
	_finish(cc)
	if unknown_items > 0 and cc["status"] == "pass":
		cc["status"] = "warn"
	return {"item_footprints": fpc, "footprint_corrections": cc}


# --- text ---------------------------------------------------------------------------------

static func to_markdown(report: Dictionary) -> String:
	## Readable summary (private: it contains coordinates from the user's client).
	var out: PackedStringArray = []
	out.append("# World validation (%s)" % str(report.get("status", "?")).to_upper())
	out.append("")
	out.append("PRIVATE: derived from your own game client files. Do not commit or share.")
	out.append("")
	out.append("* Client version: %s" % str(report.get("game_version", "")))
	var w: Dictionary = report.get("world", {})
	out.append("* World: %s (%s, client %s, generated %s)" % [w.get("id", ""), w.get("kind", ""), w.get("client_version", ""), w.get("generated", "")])
	out.append("* Generated: %s by %s" % [report.get("generated", ""), report.get("tool", "")])
	var cn: Dictionary = report.get("counts", {})
	out.append("* Checks: %d pass, %d warn, %d fail" % [int(cn.get("pass", 0)), int(cn.get("warn", 0)), int(cn.get("fail", 0))])
	out.append("")
	out.append("| Check | Status | Compared | Mismatches |")
	out.append("|---|---|---|---|")
	for c: Dictionary in report.get("checks", []):
		out.append("| %s | %s | %d | %d |" % [c.get("title", c.get("id", "")), c.get("status", ""), int(c.get("compared", 0)), int(c.get("mismatches", 0))])
	for c: Dictionary in report.get("checks", []):
		out.append("")
		out.append("## %s [%s]" % [c.get("title", ""), c.get("status", "")])
		var skip := ["id", "title", "status", "examples", "notes", "not_on_map"]
		for k in c:
			if not str(k) in skip:
				out.append("* %s: %s" % [k, JSON.stringify(c[k])])
		for n in c.get("notes", []):
			out.append("* note: %s" % str(n))
		for e in c.get("examples", []):
			out.append("  * example: %s" % JSON.stringify(e))
	out.append("")
	out.append("## Expansion definitions not on the map")
	for e: Dictionary in report.get("expansion_definitions_not_on_map", []):
		out.append("* id %d (%s, %s): %s" % [int(e["id"]), e.get("name", ""), e.get("kind", ""), "; ".join(PackedStringArray(e.get("reasons", [])))])
	out.append("")
	out.append("## Landmarks")
	out.append("| SpecialObject | landmark | source | world origin | rule | expected | client fp | world fp | status |")
	out.append("|---|---|---|---|---|---|---|---|---|")
	for r: Dictionary in report.get("landmarks", []):
		out.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % [r.get("special_object", ""), r.get("landmark", ""), JSON.stringify(r.get("source")),
			JSON.stringify(r.get("world_origin")), r.get("rule", ""), JSON.stringify(r.get("expected_origin")), JSON.stringify(r.get("client_footprint")),
			JSON.stringify(r.get("world_footprint")), r.get("status", "")])
	out.append("")
	out.append("## Registration rules used")
	for g: Dictionary in report.get("registration", []):
		out.append("* %s: %s (%s)%s" % [g["special_object"], g["rule"], g["confidence"], (" - " + str(g["meaning"])) if not str(g.get("meaning", "")).is_empty() else ""])
		for ev in g.get("evidence", []):
			out.append("  * %s" % str(ev))
	return "\n".join(out) + "\n"
