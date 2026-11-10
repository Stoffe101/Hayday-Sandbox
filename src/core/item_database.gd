class_name ItemDatabase
extends RefCounted
## Loads item metadata from JSON manifests (res://data/items and the user's
## data directory), validates it, and answers catalogue queries.

const FORMAT := "hayday-sandbox-items"
## Private-pack catalogue corrections (catalog_overrides.json, W2 design s9).
const OVERRIDES_FORMAT := "hayday-sandbox-catalog-overrides"
const OVERRIDES_VERSION := 1

var items: Dictionary = {}          ## id -> ItemDef
var ordered: Array[ItemDef] = []    ## stable display order
var categories: Array[Dictionary] = []
var category_index: Dictionary = {} ## id -> category dict
var aliases: Dictionary = {}        ## old id -> current id
var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()
## Pack whose catalogue overrides are applied ("" = public values) and the
## report apply_overrides() returned for it.
var overrides_pack: String = ""
var overrides_report: Dictionary = {}


func load_default() -> void:
	load_categories("res://data/items/categories.json")
	load_directory("res://data/items")
	load_directory("user://items")
	finalize()


func load_categories(path: String) -> void:
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary or not data.get("categories") is Array:
		errors.append("categories file missing or invalid: %s" % path)
		return
	categories.clear()
	category_index.clear()
	for c in data["categories"]:
		if c is Dictionary and c.has("id"):
			var cat := {
				"id": str(c["id"]), "name": str(c.get("name", c["id"])),
				"icon": str(c.get("icon", "box")), "color": Color(str(c.get("color", "#8a8a8a"))),
				"order": int(c.get("order", 999)), "group": str(c.get("group", "")),
			}
			categories.append(cat)
			category_index[cat["id"]] = cat
	categories.sort_custom(func(a, b): return a["order"] < b["order"])


func load_directory(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var files := Array(dir.get_files())
	files.sort()
	for f: String in files:
		if f.ends_with(".json") and f != "categories.json":
			load_file(dir_path.path_join(f))


func load_file(path: String) -> int:
	## Returns number of items loaded from the file.
	var data: Variant = JsonUtil.read_json(path)
	if not data is Dictionary:
		errors.append("%s: not a JSON object" % path)
		return 0
	if str(data.get("schema", "")) != FORMAT:
		warnings.append("%s: missing schema '%s'" % [path, FORMAT])
	var list: Variant = data.get("items", [])
	if not list is Array:
		errors.append("%s: 'items' must be an array" % path)
		return 0
	var n := 0
	for rec in list:
		if not rec is Dictionary:
			continue
		var errs: Array = []
		var it := ItemDef.from_dict(rec, errs)
		for e in errs:
			errors.append("%s: %s" % [path.get_file(), e])
		if it == null:
			continue
		it.source_file = path
		if items.has(it.id):
			if path.begins_with("user://"):
				# User manifests may override built-in records deliberately.
				ordered.erase(items[it.id])
				warnings.append("%s overrides built-in item %s" % [path.get_file(), it.id])
			else:
				errors.append("duplicate item id '%s' in %s" % [it.id, path.get_file()])
				continue
		items[it.id] = it
		ordered.append(it)
		n += 1
	return n


func add_item(it: ItemDef) -> void:
	if items.has(it.id):
		ordered.erase(items[it.id])
	items[it.id] = it
	ordered.append(it)


func finalize() -> void:
	# Stable display order: category order, then name.
	_sort_ordered()
	aliases.clear()
	for it: ItemDef in ordered:
		if not category_index.has(it.category):
			warnings.append("%s: unknown category '%s'" % [it.id, it.category])
		for a in it.aliases:
			if items.has(a):
				errors.append("alias '%s' of %s collides with an item id" % [a, it.id])
			else:
				aliases[a] = it.id


func get_item(id: String) -> ItemDef:
	if items.has(id):
		return items[id]
	if aliases.has(id):
		return items.get(aliases[id])
	return null


func resolve_id(id: String) -> String:
	## Maps renamed ids to their current id (identity for unknown ids).
	if items.has(id):
		return id
	return aliases.get(id, id)


func has_item(id: String) -> bool:
	return get_item(id) != null


func category(id: String) -> Dictionary:
	return category_index.get(id, {"id": id, "name": id.capitalize(), "icon": "box", "color": Color(0.55, 0.55, 0.55), "order": 999, "group": ""})


func count() -> int:
	return ordered.size()


## Catalogue query. `filters` keys (all optional):
##   category: String, max_level: int, footprint: Vector2i, ids: Dictionary (whitelist),
##   status: "trusted" | "unverified", connectable: bool,
##   include_hidden: bool (default false: landmark duplicates and items of other
##   areas such as the Fishing Lake are left out, see ItemDef.is_catalogue_hidden())
## sort: "name" | "level" | "size" | "relevance"
func search(query: String, filters: Dictionary = {}, sort: String = "relevance") -> Array[ItemDef]:
	var q := query.strip_edges().to_lower()
	var tokens := q.split(" ", false)
	var scored: Array = []
	var cat: String = filters.get("category", "")
	var max_level: int = filters.get("max_level", -1)
	var ids: Dictionary = filters.get("ids", {})
	var use_ids := filters.has("ids")
	var fp: Vector2i = filters.get("footprint", Vector2i.ZERO)
	var status: String = filters.get("status", "")
	var include_hidden: bool = bool(filters.get("include_hidden", false))
	for it: ItemDef in ordered:
		if not include_hidden and it.is_catalogue_hidden():
			continue
		if not cat.is_empty() and it.category != cat:
			continue
		if use_ids and not ids.has(it.id):
			continue
		if max_level >= 0 and it.unlock_level > max_level:
			continue
		if fp != Vector2i.ZERO and it.footprint != fp and it.footprint != Vector2i(fp.y, fp.x):
			continue
		if status == "trusted" and not it.is_footprint_trusted():
			continue
		if status == "unverified" and it.is_footprint_trusted():
			continue
		var score := 0
		if not tokens.is_empty():
			var ok := true
			var lname := it.name.to_lower()
			for t in tokens:
				var pos := it.search_text.find(t)
				if pos < 0:
					ok = false
					break
				if lname.begins_with(t):
					score += 30
				elif lname.find(" " + t) >= 0:
					score += 20
				elif lname.find(t) >= 0:
					score += 10
				else:
					score += 2
			if not ok:
				continue
			if lname == q:
				score += 100
		scored.append([score, it])
	match sort:
		"name":
			scored.sort_custom(func(a, b): return a[1].name.naturalnocasecmp_to(b[1].name) < 0)
		"level":
			scored.sort_custom(func(a, b):
				var la: int = a[1].unlock_level if a[1].unlock_level >= 0 else 9999
				var lb: int = b[1].unlock_level if b[1].unlock_level >= 0 else 9999
				if la == lb:
					return a[1].name.naturalnocasecmp_to(b[1].name) < 0
				return la < lb)
		"size":
			scored.sort_custom(func(a, b):
				var sa: int = a[1].footprint.x * a[1].footprint.y
				var sb: int = b[1].footprint.x * b[1].footprint.y
				if sa == sb:
					return a[1].name.naturalnocasecmp_to(b[1].name) < 0
				return sa > sb)
		_:
			if not tokens.is_empty():
				scored.sort_custom(func(a, b):
					if a[0] == b[0]:
						return a[1].name.naturalnocasecmp_to(b[1].name) < 0
					return a[0] > b[0])
	var out: Array[ItemDef] = []
	for s in scored:
		out.append(s[1])
	return out


func landmark_items() -> Array[ItemDef]:
	## Catalogue entries that duplicate a fixed world landmark.
	var out: Array[ItemDef] = []
	for it: ItemDef in ordered:
		if not it.landmark.is_empty():
			out.append(it)
	return out


func items_for_landmark(landmark_id: String) -> Array[ItemDef]:
	var out: Array[ItemDef] = []
	for it: ItemDef in ordered:
		if landmark_id in it.landmarks:
			out.append(it)
	return out


# --- private-pack catalogue overrides ------------------------------------------------

func apply_overrides(data: Variant, pack_id: String) -> Dictionary:
	## Applies a pack's catalog_overrides.json ({"format", "version", "items":
	## {"<id>": {"footprint": [w, h], "footprint_status": "game_data",
	## "unlock_level": n, "change": ..., "was": ...}}}) on top of the public
	## catalogue. Any previously applied overrides are reverted first, so this
	## is idempotent and switching packs is safe. Bad entries are skipped and
	## reported, never guessed. Returns a report:
	##   {pack_id, applied: int, records: [{id, old, new, axis_swap, old_status, new_status,
	##    old_unlock, new_unlock, change}], footprint_changed: [{id, old, new, axis_swap}],
	##    unknown: [ids], invalid: [messages], hash: String, added: [ids]}
	## The optional "additions" object ({"<new id>": item record in the catalogue
	## schema}) adds items the public catalogue does not have (client-only items
	## with facts from the user's own game files); they are removed again by
	## revert_overrides(). An addition never replaces a catalogue item or alias.
	revert_overrides()
	var rep := {"pack_id": pack_id, "applied": 0, "records": [], "footprint_changed": [], "unknown": [],
		"invalid": [], "hash": "", "added": []}
	if not data is Dictionary:
		rep["invalid"].append("catalogue overrides: not a JSON object")
		return rep
	var d: Dictionary = data
	if d.has("format") and str(d["format"]) != OVERRIDES_FORMAT:
		rep["invalid"].append("catalogue overrides: format must be '%s'" % OVERRIDES_FORMAT)
		return rep
	var ver: Variant = d.get("version", OVERRIDES_VERSION)
	if (ver is int or ver is float) and int(ver) > OVERRIDES_VERSION:
		rep["invalid"].append("catalogue overrides: version %d is newer than this app (%d); known fields used" % [int(ver), OVERRIDES_VERSION])
	var list: Variant = d.get("items", {})
	if not list is Dictionary:
		rep["invalid"].append("catalogue overrides: 'items' must be an object")
		return rep
	var adds: Variant = d.get("additions", {})
	rep["hash"] = JSON.stringify(list, "", true).md5_text()
	if adds is Dictionary and not (adds as Dictionary).is_empty():
		rep["hash"] = JSON.stringify([list, adds], "", true).md5_text()
		_apply_additions(adds, pack_id, rep)
	elif adds != null and not adds is Dictionary:
		rep["invalid"].append("catalogue overrides: 'additions' must be an object")
	var ids: Array = (list as Dictionary).keys()
	ids.sort()
	for raw_id in ids:
		var key := str(raw_id)
		var e: Variant = list[raw_id]
		var it := get_item(key)
		if it == null:
			rep["unknown"].append(key)
			continue
		if not e is Dictionary:
			rep["invalid"].append("%s: entry is not an object" % key)
			continue
		var new_fp := it.footprint
		var new_status := it.footprint_status
		var new_level := it.unlock_level
		var touched := false
		var bad := ""
		if e.has("footprint") and e["footprint"] != null:
			var fp: Variant = e["footprint"]
			if fp is Array and (fp as Array).size() == 2 and _is_pos_int(fp[0]) and _is_pos_int(fp[1]):
				new_fp = Vector2i(int(fp[0]), int(fp[1]))
				new_status = "game_data"
				touched = true
			else:
				bad = "footprint must be [w, h] positive integers"
		if bad.is_empty() and e.has("footprint_status") and e["footprint_status"] != null:
			var st := str(e["footprint_status"])
			if not st in ItemDef.STATUS_ORDER:
				bad = "unknown footprint_status '%s'" % st
			else:
				new_status = st
				touched = true
		if bad.is_empty() and e.has("unlock_level") and e["unlock_level"] != null:
			var ul: Variant = e["unlock_level"]
			if (ul is int or (ul is float and float(ul) == floorf(ul))) and int(ul) >= 0:
				new_level = int(ul)
				touched = true
			else:
				bad = "unlock_level must be a non-negative integer"
		if not bad.is_empty():
			rep["invalid"].append("%s: %s" % [key, bad])
			continue
		if not touched:
			continue
		var old := it.footprint
		var rec := {"id": it.id, "old": old, "new": new_fp,
			"axis_swap": new_fp != old and new_fp == Vector2i(old.y, old.x),
			"old_status": it.footprint_status, "new_status": new_status,
			"old_unlock": it.unlock_level, "new_unlock": new_level, "change": str(e.get("change", ""))}
		it.footprint = new_fp
		it.footprint_status = new_status
		it.unlock_level = new_level
		it.footprint_source = pack_id
		rep["records"].append(rec)
		if new_fp != old:
			rep["footprint_changed"].append({"id": it.id, "old": old, "new": new_fp, "axis_swap": rec["axis_swap"]})
		rep["applied"] += 1
	overrides_pack = pack_id if int(rep["applied"]) > 0 or not (rep["added"] as Array).is_empty() else ""
	overrides_report = rep
	return rep


func _apply_additions(adds: Dictionary, pack_id: String, rep: Dictionary) -> void:
	## Adds client-only items (see apply_overrides()); bad or colliding entries are
	## reported in rep.invalid and skipped, never guessed.
	var ids: Array = adds.keys()
	ids.sort()
	for raw in ids:
		var key := str(raw).strip_edges()
		var e: Variant = adds[raw]
		if not e is Dictionary:
			rep["invalid"].append("addition %s: entry is not an object" % key)
			continue
		if items.has(key) or aliases.has(key):
			rep["invalid"].append("addition %s: the catalogue already has this id; ignored" % key)
			continue
		var rec: Dictionary = (e as Dictionary).duplicate(true)
		rec["id"] = key
		var errs: Array = []
		var it := ItemDef.from_dict(rec, errs)
		if it == null or not errs.is_empty():
			rep["invalid"].append("addition %s: %s" % [key, "; ".join(PackedStringArray(errs))])
			continue
		if not category_index.is_empty() and not category_index.has(it.category):
			rep["invalid"].append("addition %s: unknown category '%s'" % [key, it.category])
			continue
		it.added_by_pack = pack_id
		it.source_file = "pack:%s" % pack_id
		items[key] = it
		ordered.append(it)
		(rep["added"] as Array).append(key)
	if not (rep["added"] as Array).is_empty():
		_sort_ordered()


func _sort_ordered() -> void:
	ordered.sort_custom(func(a: ItemDef, b: ItemDef):
		var oa: int = category_index.get(a.category, {}).get("order", 999)
		var ob: int = category_index.get(b.category, {}).get("order", 999)
		if oa != ob:
			return oa < ob
		return a.name.naturalnocasecmp_to(b.name) < 0)


func added_items() -> Array[ItemDef]:
	## Items a private pack added (catalogue additions), in display order.
	var out: Array[ItemDef] = []
	for it: ItemDef in ordered:
		if not it.added_by_pack.is_empty():
			out.append(it)
	return out


func revert_overrides() -> int:
	## Restores the public catalogue values of every overridden item (e.g. when
	## the private pack is disabled/removed) and removes the items a pack added.
	## Returns how many items were restored or removed.
	var n := 0
	var added: Array = []
	for it: ItemDef in items.values():
		if not it.added_by_pack.is_empty():
			added.append(it)
	for it: ItemDef in added:
		items.erase(it.id)
		ordered.erase(it)
		n += 1
	for it: ItemDef in items.values():
		if it.footprint_source.is_empty():
			continue
		it.footprint = it.public_footprint
		it.footprint_status = it.public_footprint_status
		it.unlock_level = it.public_unlock_level
		it.footprint_source = ""
		n += 1
	overrides_pack = ""
	overrides_report = {}
	return n


static func _is_pos_int(v: Variant) -> bool:
	return (v is int or (v is float and float(v) == floorf(v))) and int(v) > 0


func stats() -> Dictionary:
	## Honest coverage numbers for the catalogue report.
	var by_status := {}
	var with_level := 0
	var with_cost := 0
	for it: ItemDef in ordered:
		by_status[it.footprint_status] = by_status.get(it.footprint_status, 0) + 1
		if it.unlock_level >= 0:
			with_level += 1
		if it.has_known_cost():
			with_cost += 1
	return {"total": ordered.size(), "footprint_status": by_status, "with_level": with_level, "with_cost": with_cost}
