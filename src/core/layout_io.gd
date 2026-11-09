class_name LayoutIO
extends RefCounted
## Versioned (de)serialisation of FarmLayout documents.
##
## Robustness rules:
##  * Unknown item ids are kept as "missing" objects with their saved
##    footprint, and are written back unchanged — a missing image or retired
##    item never destroys a farm.
##  * Renamed items are mapped through ItemDef.aliases.
##  * If an item's footprint changed in newer metadata the new size is used and
##    the object is reported; overlaps are kept and flagged, not deleted.
##  * Older schema versions are migrated step by step (see MIGRATIONS).
##  * Unknown keys are preserved.

const FORMAT := "hayday-sandbox-layout"
const SCHEMA_VERSION := 1
const FILE_EXT := ".hdlayout"


class LoadReport:
	var ok: bool = true
	var error: String = ""
	var migrated_from: int = -1
	var recovered_from: String = ""
	var missing_items: Dictionary = {}      ## id -> count
	var renamed: Dictionary = {}            ## old -> new
	var footprint_changed: Array = []       ## uids
	var dropped: int = 0                    ## malformed records skipped
	var warnings: PackedStringArray = PackedStringArray()

	func summary() -> String:
		var parts := PackedStringArray()
		if migrated_from >= 0:
			parts.append("upgraded from format v%d" % migrated_from)
		if not recovered_from.is_empty():
			parts.append("recovered from %s" % recovered_from.get_file())
		if not missing_items.is_empty():
			var n := 0
			for k in missing_items:
				n += missing_items[k]
			parts.append("%d object(s) of %d unknown item type(s) kept as placeholders" % [n, missing_items.size()])
		if not renamed.is_empty():
			parts.append("%d renamed item type(s) updated" % renamed.size())
		if not footprint_changed.is_empty():
			parts.append("%d object(s) changed size" % footprint_changed.size())
		if dropped > 0:
			parts.append("%d malformed record(s) skipped" % dropped)
		return "; ".join(parts)


static func to_dict(l: FarmLayout) -> Dictionary:
	var objs: Array = []
	var uids := l.objects.keys()
	uids.sort()
	for u in uids:
		objs.append((l.objects[u] as PlacedObject).to_dict())
	var plots := l.unlocked_plots.keys()
	plots.sort()
	var groups := {}
	for g in l.groups:
		groups[str(g)] = l.groups[g]
	var d := l.extra.duplicate(true)
	d.merge({
		"format": FORMAT,
		"schema_version": SCHEMA_VERSION,
		"app_version": ProjectSettings.get_setting("application/config/version", "0.0.0"),
		"meta": {
			"id": l.id, "name": l.name, "description": l.description, "tags": Array(l.tags),
			"created": l.created, "modified": l.modified, "mode": l.mode,
		},
		"map": {"id": l.map_id, "unlocked_plots": plots},
		"next_uid": l.next_uid,
		"next_group": l.next_group,
		"objects": objs,
		"groups": groups,
		"annotations": l.annotations.duplicate(true),
		"profile": l.profile.duplicate(true),
		"reference": l.reference.duplicate(true),
		"camera": l.camera.duplicate(true),
	}, true)
	return d


static func from_dict(d: Dictionary, db: ItemDatabase, report: LoadReport = null) -> FarmLayout:
	if report == null:
		report = LoadReport.new()
	var data := d.duplicate(true)
	var ver := int(data.get("schema_version", 0))
	if str(data.get("format", "")) != FORMAT and ver != 0:
		report.ok = false
		report.error = "Not a Hayday Sandbox layout file"
		return null
	if ver > SCHEMA_VERSION:
		report.ok = false
		report.error = "Layout was saved by a newer version (format v%d; this app reads up to v%d)" % [ver, SCHEMA_VERSION]
		return null
	if ver < SCHEMA_VERSION:
		report.migrated_from = ver
		data = migrate(data, ver)
	var l := FarmLayout.new()
	var meta: Dictionary = data.get("meta", {})
	l.id = str(meta.get("id", ""))
	l.name = str(meta.get("name", "Untitled farm"))
	l.description = str(meta.get("description", ""))
	l.tags = PackedStringArray(meta.get("tags", []))
	l.created = str(meta.get("created", ""))
	l.modified = str(meta.get("modified", ""))
	l.mode = str(meta.get("mode", FarmLayout.MODE_CREATIVE))
	if l.mode != FarmLayout.MODE_CREATIVE and l.mode != FarmLayout.MODE_REALISTIC:
		l.mode = FarmLayout.MODE_CREATIVE
	var mapd: Dictionary = data.get("map", {})
	l.map_id = str(mapd.get("id", "hayday_farm"))
	for p in mapd.get("unlocked_plots", []):
		l.unlocked_plots[str(p)] = true
	l.next_uid = maxi(1, int(data.get("next_uid", 1)))
	l.next_group = maxi(1, int(data.get("next_group", 1)))
	var groups: Variant = data.get("groups", {})
	if groups is Dictionary:
		for g in groups:
			l.groups[int(g)] = groups[g]
	for a in data.get("annotations", []):
		if a is Dictionary:
			l.annotations.append(a)
			l.next_annotation = maxi(l.next_annotation, int(a.get("id", 0)) + 1)
	var prof: Variant = data.get("profile", {})
	if prof is Dictionary:
		l.profile.merge(prof, true)
	var refd: Variant = data.get("reference", {})
	l.reference = refd if refd is Dictionary else {}
	var cam: Variant = data.get("camera", {})
	l.camera = cam if cam is Dictionary else {}
	var objs: Array = []
	var used := {}
	for rec in data.get("objects", []):
		if not rec is Dictionary or not rec.has("item"):
			report.dropped += 1
			continue
		var o := PlacedObject.from_dict(rec)
		if o.uid <= 0 or used.has(o.uid):
			o.uid = 0   # reassigned on add
		used[o.uid] = true
		var resolved := db.resolve_id(o.item_id) if db else o.item_id
		if resolved != o.item_id:
			report.renamed[o.item_id] = resolved
			o.item_id = resolved
		var it := db.get_item(o.item_id) if db else null
		if it == null:
			o.missing = true
			report.missing_items[o.item_id] = report.missing_items.get(o.item_id, 0) + 1
		else:
			var want := it.size_for(o.flipped)
			if want != o.size:
				report.footprint_changed.append(o.uid)
				o.size = want
		objs.append(o)
	l.add_objects(objs, false)
	var known := ["format", "schema_version", "app_version", "meta", "map", "next_uid", "next_group", "objects",
		"groups", "annotations", "profile", "reference", "camera"]
	for k in data.keys():
		if not k in known:
			l.extra[k] = data[k]
	return l


static func migrate(d: Dictionary, from_version: int) -> Dictionary:
	var data := d
	var v := from_version
	while v < SCHEMA_VERSION:
		match v:
			0:
				data = _migrate_0_to_1(data)
		v += 1
	data["schema_version"] = SCHEMA_VERSION
	data["format"] = FORMAT
	return data


static func _migrate_0_to_1(d: Dictionary) -> Dictionary:
	## v0 was the pre-release prototype shape:
	##   {"version":0,"name":..,"items":[{"id":..,"pos":[x,y],"size":[w,h],"mirrored":bool}],
	##    "land":[plot ids]}
	var out := {"meta": {"name": str(d.get("name", "Imported farm")), "mode": "creative"},
		"map": {"id": "hayday_farm", "unlocked_plots": d.get("land", [])}, "objects": []}
	var uid := 1
	for it in d.get("items", []):
		if not it is Dictionary:
			continue
		var pos: Array = it.get("pos", [0, 0])
		var sz: Array = it.get("size", [1, 1])
		out["objects"].append({"uid": uid, "item": str(it.get("id", "")), "x": int(pos[0]), "y": int(pos[1]),
			"w": int(sz[0]), "h": int(sz[1]), "flip": bool(it.get("mirrored", false))})
		uid += 1
	out["next_uid"] = uid
	return out


static func save_file(l: FarmLayout, path: String) -> Error:
	var text := JsonUtil.stringify(to_dict(l), true)
	return JsonUtil.write_atomic(path, text)


static func load_file(path: String, db: ItemDatabase, report: LoadReport) -> FarmLayout:
	var use := JsonUtil.recover(path)
	if use.is_empty():
		report.ok = false
		report.error = "File is missing or corrupted: %s" % path.get_file()
		return null
	if use != path:
		report.recovered_from = use
	var data: Variant = JsonUtil.parse(JsonUtil.read_text(use))
	if not data is Dictionary:
		report.ok = false
		report.error = "File is not a layout"
		return null
	return from_dict(data, db, report)
