class_name FarmMap
extends RefCounted
## Data-driven farm geometry: which tiles exist, which are buildable, which
## belong to an unlockable expansion plot, and which are permanent terrain
## (roads, water, fixed scenery). Loaded from data/maps/*.json so the geometry
## can be corrected without code changes.

const FORMAT := "hayday-sandbox-map"

enum Kind { VOID = 0, BUILDABLE = 1, PLOT = 2, ROAD = 3, WATER = 4, BLOCKED = 5, SCENERY = 6 }
const KIND_NAMES := {"void": Kind.VOID, "buildable": Kind.BUILDABLE, "plot": Kind.PLOT, "road": Kind.ROAD,
	"water": Kind.WATER, "blocked": Kind.BLOCKED, "scenery": Kind.SCENERY}

var id: String = ""
var name: String = ""
var geometry_status: String = "approximation"
var size: Vector2i = Vector2i(40, 40)
var kinds: PackedByteArray = PackedByteArray()   ## per tile Kind
var plot_of: PackedInt32Array = PackedInt32Array() ## per tile plot index, -1 = none
var region_of: PackedInt32Array = PackedInt32Array()
var regions: Array[Dictionary] = []
var plots: Array[Dictionary] = []               ## {id, name, section, number, cost, min_level, rects, tiles, neighbors, center}
var plot_index: Dictionary = {}                 ## plot id -> index
var fixed_objects: Array[Dictionary] = []       ## {id, item, origin: Vector2i, label}
var labels: Array[Dictionary] = []              ## decorative map labels {text, at: Vector2}
var sources: PackedStringArray = PackedStringArray()
var notes: PackedStringArray = PackedStringArray()
var errors: PackedStringArray = PackedStringArray()


static func load_file(path: String) -> FarmMap:
	var m := FarmMap.new()
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary:
		m.errors.append("map file missing or invalid: %s" % path)
		m._build_fallback()
		return m
	m.from_dict(data)
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


func from_dict(d: Dictionary) -> void:
	id = str(d.get("id", "map"))
	name = str(d.get("name", id))
	geometry_status = str(d.get("geometry_status", "approximation"))
	var sz: Variant = d.get("size", [40, 40])
	size = Vector2i(int(sz[0]), int(sz[1]))
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
	for s in d.get("sources", []):
		sources.append(str(s))
	for s in d.get("notes", []):
		notes.append(str(s))
	# Regions are painted in file order; later regions override earlier ones.
	for r in d.get("regions", []):
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
			pidx = plots.size()
			var plot := {
				"id": region["id"], "name": str(r.get("name", region["id"])),
				"section": str(r.get("section", "main")), "number": int(r.get("number", pidx + 1)),
				"cost": r.get("cost", {}), "min_level": int(r.get("min_level", -1)),
				"rects": rects, "tiles": 0, "neighbors": [], "center": Vector2.ZERO,
				"status": region["status"], "notes": str(r.get("notes", "")),
			}
			plots.append(plot)
			plot_index[plot["id"]] = pidx
		for rect in rects:
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if x < 0 or y < 0 or x >= size.x or y >= size.y:
						continue
					var i := y * size.x + x
					kinds[i] = kind
					plot_of[i] = pidx
					region_of[i] = region_idx
	_compute_plot_geometry()
	for f in d.get("fixed_objects", []):
		if f is Dictionary and f.has("origin"):
			fixed_objects.append({"id": str(f.get("id", "")), "item": str(f.get("item", "")),
				"origin": Vector2i(int(f["origin"][0]), int(f["origin"][1])), "label": str(f.get("label", ""))})
	for l in d.get("labels", []):
		if l is Dictionary and l.has("at"):
			labels.append({"text": str(l.get("text", "")), "at": Vector2(float(l["at"][0]), float(l["at"][1]))})


func _compute_plot_geometry() -> void:
	var sums: Array[Vector2] = []
	sums.resize(plots.size())
	sums.fill(Vector2.ZERO)
	var nb: Array[Dictionary] = []
	for i in plots.size():
		nb.append({})
	for y in size.y:
		for x in size.x:
			var p := plot_of[y * size.x + x]
			if p < 0:
				continue
			plots[p]["tiles"] += 1
			sums[p] += Vector2(x + 0.5, y + 0.5)
			for d in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if nx < size.x and ny < size.y:
					var q := plot_of[ny * size.x + nx]
					if q >= 0 and q != p:
						nb[p][q] = true
						nb[q][p] = true
	for i in plots.size():
		if plots[i]["tiles"] > 0:
			plots[i]["center"] = sums[i] / float(plots[i]["tiles"])
		var ids: Array = []
		for q in nb[i].keys():
			ids.append(plots[q]["id"])
		ids.sort()
		plots[i]["neighbors"] = ids


func in_bounds(t: Vector2i) -> bool:
	return t.x >= 0 and t.y >= 0 and t.x < size.x and t.y < size.y


func kind_at(t: Vector2i) -> int:
	if not in_bounds(t):
		return Kind.VOID
	return kinds[t.y * size.x + t.x]


func plot_id_at(t: Vector2i) -> String:
	if not in_bounds(t):
		return ""
	var p := plot_of[t.y * size.x + t.x]
	return "" if p < 0 else str(plots[p]["id"])


func plot(plot_id: String) -> Dictionary:
	if not plot_index.has(plot_id):
		return {}
	return plots[plot_index[plot_id]]


func all_plot_ids() -> Array[String]:
	var out: Array[String] = []
	for p in plots:
		out.append(str(p["id"]))
	return out


func is_land(t: Vector2i, unlocked: Dictionary) -> bool:
	## True when objects may stand on this tile given the unlocked plots.
	var k := kind_at(t)
	if k == Kind.BUILDABLE:
		return true
	if k == Kind.PLOT:
		return unlocked.has(plot_id_at(t))
	return false


func unlockable_plots(unlocked: Dictionary) -> Array[String]:
	## Plots adjacent to starting land or an unlocked plot (Hay Day unlocks
	## plots outward from already-owned land).
	var out: Array[String] = []
	for p in plots:
		var pid := str(p["id"])
		if unlocked.has(pid):
			continue
		if _touches_buildable(p) or (p["neighbors"] as Array).any(func(n): return unlocked.has(n)):
			out.append(pid)
	return out


func _touches_buildable(p: Dictionary) -> bool:
	for rect: Rect2i in p["rects"]:
		for y in range(rect.position.y - 1, rect.end.y + 1):
			for x in range(rect.position.x - 1, rect.end.x + 1):
				var inside := x >= rect.position.x and x < rect.end.x and y >= rect.position.y and y < rect.end.y
				if inside:
					continue
				var diag := (x < rect.position.x or x >= rect.end.x) and (y < rect.position.y or y >= rect.end.y)
				if not diag and kind_at(Vector2i(x, y)) == Kind.BUILDABLE:
					return true
	return false


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
