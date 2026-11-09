class_name ItemDatabase
extends RefCounted
## Loads item metadata from JSON manifests (res://data/items and the user's
## data directory), validates it, and answers catalogue queries.

const FORMAT := "hayday-sandbox-items"

var items: Dictionary = {}          ## id -> ItemDef
var ordered: Array[ItemDef] = []    ## stable display order
var categories: Array[Dictionary] = []
var category_index: Dictionary = {} ## id -> category dict
var aliases: Dictionary = {}        ## old id -> current id
var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()


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
	ordered.sort_custom(func(a: ItemDef, b: ItemDef):
		var oa: int = category_index.get(a.category, {}).get("order", 999)
		var ob: int = category_index.get(b.category, {}).get("order", 999)
		if oa != ob:
			return oa < ob
		return a.name.naturalnocasecmp_to(b.name) < 0)
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
##   status: "trusted" | "unverified", connectable: bool
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
	for it: ItemDef in ordered:
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
