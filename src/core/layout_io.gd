class_name LayoutIO
extends RefCounted
## Versioned (de)serialisation of FarmLayout documents.
##
## Robustness rules:
##  * Unknown item ids are kept as "missing" objects with their saved
##    footprint, and are written back unchanged — a missing image or retired
##    item never destroys a farm.
##  * Renamed items are mapped through ItemDef.aliases.
##  * If an item's footprint changed in newer metadata (or in a private pack's
##    catalogue overrides) the object keeps its origin (top corner): an
##    axis-only change of a flippable item toggles `flipped` (same tiles,
##    lossless), anything else takes the new size. Every change is reported;
##    overlaps are kept and flagged, never deleted.
##  * Fixed landmarks (farmhouse, truck, ...) are world data, never objects:
##    catalogue items that duplicate a landmark are taken out of `objects` on
##    EVERY load/import (any schema) and stored verbatim in
##    `migration.migrated_landmarks` with a reason — never silently dropped.
##  * Older schema versions are migrated step by step (see migrate()).
##  * Unknown keys are preserved.
##  * Saving over a pre-v2 file first keeps its original bytes as
##    `<file>.v<N>-backup` (see save_file()).
##
## Schema 2 (W2 design s6) adds the game tile frame and the keys
##   "world": {theme, landmark_states, landmark_skins, landmark_visible}
##   "migration": {from, at, shifted_by, from_map, migrated_landmarks, review_uids, notes}
##   "footprint_source": {pack, pack_version, overrides_hash}
##
## Schema 3 makes "reference" a list of images (see normalize_reference()):
##   "reference": {"images": [{id, name, file, opacity, visible, locked,
##                             x, y, scale, rotation | affine}, ...], "above": bool}
## Earlier files hold one image directly in "reference"; first in the list = bottom.

const FORMAT := "hayday-sandbox-layout"
const SCHEMA_VERSION := 3
const FILE_EXT := ".hdlayout"
## Note the v1 starter template put on its auto-locked core buildings. The 1->2
## migration clears that automatic lock on movable items (user locks stay).
const V1_STARTER_NOTE := "Approximate starting position — unlock (L) and move to match your farm."
## The retired 48-wide-start-land hypothesis (map "hayday_farm_h1") put the main
## expansion section 16 columns further east: objects at v1 x >= this are
## flagged for review after migration.
const H1_REVIEW_MIN_X := 53
## Placement codes that make a loaded object a "collision" worth reporting
## (fixed landmarks or ground that is not buildable at all). Overlaps between
## objects and locked plots are ordinary editing states and are not reported.
const COLLISION_CODES := [PlacementRules.LANDMARK, PlacementRules.OUT_OF_BOUNDS, PlacementRules.ROAD,
	PlacementRules.WATER, PlacementRules.BLOCKED]
const KNOWN_KEYS := ["format", "schema_version", "app_version", "meta", "map", "next_uid", "next_group", "objects",
	"groups", "annotations", "profile", "reference", "camera", "world", "migration", "footprint_source"]


class LoadReport:
	var ok: bool = true
	var error: String = ""
	var migrated_from: int = -1
	var recovered_from: String = ""
	var missing_items: Dictionary = {}      ## id -> count
	var renamed: Dictionary = {}            ## old -> new
	var footprint_changed: Array = []       ## uids whose footprint (size or orientation) was reconciled
	## [{uid, item, old: Vector2i, new: Vector2i, flipped_toggled: bool}] (new == old when only `flipped` toggled)
	var footprint_changes: Array = []
	var dropped: int = 0                    ## malformed records skipped
	var warnings: PackedStringArray = PackedStringArray()
	## Objects taken out because their item is a fixed landmark:
	## [{record: <original object dict>, landmark: <id>, reason: String, name: String}]
	var migrated_landmarks: Array = []
	var shifted: Vector2i = Vector2i.ZERO   ## frame shift applied to v1 coordinates
	var source_map: String = ""             ## map id the file named before migration
	var review_uids: Array = []             ## objects that need a look (e.g. old h1 map)
	var collisions: Array = []              ## [{uid, reason}] objects on landmarks / non-buildable ground
	## Where the pre-v2 original of this file is (or, before the first save, will be) kept. "" = n/a.
	var backup_path: String = ""
	var starter_unlocked: int = 0           ## v1 starter auto-locks cleared by the migration

	func summary() -> String:
		var parts := PackedStringArray()
		if migrated_from >= 0:
			if shifted != Vector2i.ZERO:
				parts.append("upgraded from format v%d (positions converted to the game's tile grid)" % migrated_from)
			else:
				parts.append("upgraded from format v%d" % migrated_from)
		if not recovered_from.is_empty():
			parts.append("recovered from %s" % recovered_from.get_file())
		if not migrated_landmarks.is_empty():
			var names := {}
			for e in migrated_landmarks:
				names[str(e.get("name", e.get("landmark", "?")))] = true
			var list: Array = names.keys()
			list.sort()
			parts.append("%d fixed landmark%s (%s) now belong to the farm itself and were taken out of the layout" % [
				migrated_landmarks.size(), "" if migrated_landmarks.size() == 1 else "s",
				", ".join(PackedStringArray(list.slice(0, 4))) + (" +%d more" % (list.size() - 4) if list.size() > 4 else "")])
		if starter_unlocked > 0:
			parts.append("%d starter building%s unlocked" % [starter_unlocked, "" if starter_unlocked == 1 else "s"])
		if not review_uids.is_empty():
			parts.append("%d object(s) to check: the old map placed their land elsewhere" % review_uids.size())
		if not collisions.is_empty():
			parts.append("%d object(s) overlap fixed landmarks or unbuildable ground (shown in red)" % collisions.size())
		if not missing_items.is_empty():
			var n := 0
			for k in missing_items:
				n += missing_items[k]
			parts.append("%d object(s) of %d unknown item type(s) kept as placeholders" % [n, missing_items.size()])
		if not renamed.is_empty():
			parts.append("%d renamed item type(s) updated" % renamed.size())
		if not footprint_changes.is_empty():
			var resized := 0
			var turned := 0
			for c in footprint_changes:
				if bool(c.get("flipped_toggled", false)):
					turned += 1
				else:
					resized += 1
			if resized > 0:
				parts.append("%d object(s) changed size" % resized)
			if turned > 0:
				parts.append("%d object(s) turned to match corrected footprints" % turned)
		elif not footprint_changed.is_empty():
			parts.append("%d object(s) changed size" % footprint_changed.size())
		if dropped > 0:
			parts.append("%d malformed record(s) skipped" % dropped)
		if not backup_path.is_empty():
			if FileAccess.file_exists(backup_path):
				parts.append("original kept as %s" % backup_path.get_file())
			else:
				parts.append("the original file is kept as %s when you save" % backup_path.get_file())
		return "; ".join(parts)


# --- writing ------------------------------------------------------------------------

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
		"world": FarmLayout.normalize_world_state(l.world_state),
	}, true)
	if not l.migration.is_empty():
		d["migration"] = l.migration.duplicate(true)
	else:
		d.erase("migration")
	if not l.footprint_source.is_empty():
		d["footprint_source"] = l.footprint_source.duplicate(true)
	else:
		d.erase("footprint_source")
	return d


# --- reading ------------------------------------------------------------------------

static func from_dict(d: Dictionary, db: ItemDatabase, report: LoadReport = null, map: FarmMap = null) -> FarmLayout:
	## `map` (optional): the world the layout will be shown on. Used to name the
	## landmarks that replaced old objects and to report collisions with fixed
	## landmarks / unbuildable ground (objects are never moved or deleted).
	if report == null:
		report = LoadReport.new()
	var data := d.duplicate(true)
	var ver := int(data.get("schema_version", 0)) if (data.get("schema_version", 0) is int or data.get("schema_version", 0) is float) else 0
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
		data = migrate(data, ver, db, map)
		var mig: Variant = data.get("migration")
		if mig is Dictionary:
			var sb: Variant = mig.get("shifted_by", [0, 0])
			if sb is Array and (sb as Array).size() == 2:
				report.shifted = Vector2i(int(sb[0]), int(sb[1]))
			report.source_map = str(mig.get("from_map", ""))
			report.starter_unlocked = int(mig.get("starter_unlocked", 0))
			for e in mig.get("migrated_landmarks", []):
				if e is Dictionary:
					report.migrated_landmarks.append(_report_entry(e, db))
			for n in mig.get("notes", []):
				report.warnings.append(str(n))
	var l := FarmLayout.new()
	l.loaded_schema = ver
	var meta: Dictionary = data.get("meta", {}) if data.get("meta") is Dictionary else {}
	l.id = str(meta.get("id", ""))
	l.name = str(meta.get("name", "Untitled farm"))
	l.description = str(meta.get("description", ""))
	l.tags = PackedStringArray(meta.get("tags", []) if meta.get("tags") is Array else [])
	l.created = str(meta.get("created", ""))
	l.modified = str(meta.get("modified", ""))
	l.mode = str(meta.get("mode", FarmLayout.MODE_CREATIVE))
	if l.mode != FarmLayout.MODE_CREATIVE and l.mode != FarmLayout.MODE_REALISTIC:
		l.mode = FarmLayout.MODE_CREATIVE
	var mapd: Dictionary = data.get("map", {}) if data.get("map") is Dictionary else {}
	l.map_id = WorldLoader.canonical_map_id(str(mapd.get("id", "")))
	var plots: Variant = mapd.get("unlocked_plots", [])
	if plots is Array:
		for p in plots:
			l.unlocked_plots[str(p)] = true
	l.next_uid = maxi(1, int(data.get("next_uid", 1)))
	l.next_group = maxi(1, int(data.get("next_group", 1)))
	var groups: Variant = data.get("groups", {})
	if groups is Dictionary:
		for g in groups:
			l.groups[int(g)] = groups[g]
	var annotations: Variant = data.get("annotations", [])
	if annotations is Array:
		for a in annotations:
			if a is Dictionary:
				l.annotations.append(a)
				l.next_annotation = maxi(l.next_annotation, int(a.get("id", 0)) + 1)
	var prof: Variant = data.get("profile", {})
	if prof is Dictionary:
		l.profile.merge(prof, true)
	l.reference = normalize_reference(data.get("reference", {}))
	var cam: Variant = data.get("camera", {})
	l.camera = cam if cam is Dictionary else {}
	l.world_state = FarmLayout.normalize_world_state(data.get("world"))
	var migd: Variant = data.get("migration")
	l.migration = (migd as Dictionary).duplicate(true) if migd is Dictionary else {}
	var saved_src: Dictionary = (data.get("footprint_source") as Dictionary).duplicate(true) if data.get("footprint_source") is Dictionary else {}
	# --- objects ---
	var objs: Array = []
	var used := {}
	var review: Array = []                  ## PlacedObjects flagged by the migration
	var fp_changes: Array = []              ## [PlacedObject, record]
	var src_objects: Variant = data.get("objects", [])
	for rec in (src_objects if src_objects is Array else []):
		if not rec is Dictionary or not rec.has("item"):
			report.dropped += 1
			continue
		var flagged := bool(rec.get("_review", false))
		var original: Dictionary = (rec as Dictionary).duplicate(true)
		original.erase("_review")
		var o := PlacedObject.from_dict(original)
		var resolved := db.resolve_id(o.item_id) if db else o.item_id
		var it := db.get_item(resolved) if db else null
		# Landmark duplicates never enter layout.objects (any schema, any import path).
		var lm := landmark_of(resolved, it, map)
		if not lm.is_empty():
			var entry := {"record": original, "landmark": lm,
				"reason": landmark_reason(it.name if it else resolved, lm, map, ver < SCHEMA_VERSION)}
			if not l.migration.get("migrated_landmarks") is Array:
				l.migration["migrated_landmarks"] = []
			(l.migration["migrated_landmarks"] as Array).append(entry)
			report.migrated_landmarks.append(_report_entry(entry, db))
			continue
		if o.uid <= 0 or used.has(o.uid):
			o.uid = 0   # reassigned on add
		used[o.uid] = true
		if resolved != o.item_id:
			report.renamed[o.item_id] = resolved
			o.item_id = resolved
		if it == null:
			o.missing = true
			report.missing_items[o.item_id] = report.missing_items.get(o.item_id, 0) + 1
		else:
			var ch := reconcile_footprint(o, it)
			if not ch.is_empty():
				fp_changes.append([o, ch])
		if flagged:
			review.append(o)
		objs.append(o)
	l.add_objects(objs, false)
	for pair in fp_changes:
		var o: PlacedObject = pair[0]
		var ch: Dictionary = pair[1]
		ch["uid"] = o.uid
		report.footprint_changed.append(o.uid)
		report.footprint_changes.append(ch)
	if not review.is_empty() or l.migration.has("review_uids"):
		var ru: Array = []
		for o: PlacedObject in review:
			ru.append(o.uid)
		if ver < SCHEMA_VERSION:
			l.migration["review_uids"] = ru
			report.review_uids = ru.duplicate()
	# --- footprint source (which catalogue the sizes were reconciled with) ---
	if db != null:
		var cur := footprint_source_of(db)
		if str(saved_src.get("pack", "")) != str(cur.get("pack", "")):
			if not saved_src.is_empty():
				report.warnings.append("Saved with game footprints from pack '%s', which is not active now: sizes follow the %s" % [
					str(saved_src.get("pack", "")), "pack '%s'" % cur["pack"] if not cur.is_empty() else "public catalogue"])
		l.footprint_source = cur
	else:
		l.footprint_source = saved_src
	# --- collisions with the world ---
	if map != null and WorldLoader.canonical_map_id(map.id) == l.map_id:
		report.collisions = find_collisions(l, map)
	for k in data.keys():
		if not k in KNOWN_KEYS:
			l.extra[k] = data[k]
	return l


static func reconcile_footprint(o: PlacedObject, it: ItemDef) -> Dictionary:
	## Brings o.size in line with the item's current footprint. Keeps the origin
	## (top corner). An axis-only change of a flippable item toggles `flipped`
	## instead (same tiles, lossless). Returns {} when nothing changed, else
	## {item, old: Vector2i, new: Vector2i, flipped_toggled: bool}.
	var want := it.size_for(o.flipped)
	if want == o.size:
		return {}
	var old := o.size
	if it.flippable and it.footprint.x != it.footprint.y and it.size_for(not o.flipped) == o.size:
		o.flipped = not o.flipped
		return {"item": it.id, "old": old, "new": o.size, "flipped_toggled": true}
	o.size = want
	return {"item": it.id, "old": old, "new": want, "flipped_toggled": false}


static func find_collisions(l: FarmLayout, map: FarmMap) -> Array:
	## Objects standing on fixed landmarks or on unbuildable ground:
	## [{uid, reason}] (sorted by uid). Objects are never moved or deleted.
	var out: Array = []
	var uids := l.objects.keys()
	uids.sort()
	for u in uids:
		var o: PlacedObject = l.objects[u]
		var r := PlacementRules.check_rect(l, map, o.rect(), {o.uid: true})
		if r.ok:
			continue
		var parts := PackedStringArray()
		if r.reason_counts.has(PlacementRules.LANDMARK):
			var names: Array = []
			for lid in r.landmark_ids:
				var lm := map.landmark(str(lid))
				names.append(lm.name if lm else str(lid))
			names.sort()
			parts.append("Fixed landmark: %s" % ", ".join(PackedStringArray(names)))
		for c in COLLISION_CODES:
			if c != PlacementRules.LANDMARK and r.reason_counts.has(c):
				parts.append(PlacementRules.REASON_TEXT[c])
		if not parts.is_empty():
			out.append({"uid": o.uid, "reason": " · ".join(parts)})
	return out


static func landmark_of(item_id: String, it: ItemDef, map: FarmMap = null) -> String:
	## Id of the fixed landmark the item duplicates ("" = an ordinary item).
	if it != null and not it.landmark.is_empty():
		return it.landmark
	if map != null:
		var ids := map.landmarks_replacing(item_id)
		if not ids.is_empty():
			return ids[0]
	return ""


static func landmark_reason(item_name: String, landmark_id: String, map: FarmMap = null, upgrading: bool = false) -> String:
	var lm := map.landmark(landmark_id) if map else null
	var why := "%s is a fixed landmark in Hay Day: it can't be placed, moved or copied" % item_name
	if lm != null:
		why += ", and the farm world draws it at its fixed position"
	else:
		why += " (this map doesn't show it; the private world data does)"
	return why + (". The placed copy was taken out when upgrading the layout; its record is kept in the file." if upgrading
		else ". The placed copy was taken out of the layout; its record is kept in the file.")


static func _report_entry(e: Dictionary, db: ItemDatabase) -> Dictionary:
	var out := e.duplicate(true)
	var rec: Dictionary = e.get("record", {}) if e.get("record") is Dictionary else {}
	var iid := str(rec.get("item", ""))
	var it := db.get_item(iid) if db else null
	out["name"] = it.name if it else iid.capitalize()
	return out


static func footprint_source_of(db: ItemDatabase) -> Dictionary:
	## {pack, pack_version, overrides_hash} of the catalogue overrides active in
	## `db`, {} for the public catalogue.
	if db == null or db.overrides_pack.is_empty():
		return {}
	var rep: Dictionary = db.overrides_report
	return {"pack": db.overrides_pack, "pack_version": str(rep.get("pack_version", "")),
		"overrides_hash": str(rep.get("hash", ""))}


# --- migration ------------------------------------------------------------------------

static func migrate(d: Dictionary, from_version: int, db: ItemDatabase = null, map: FarmMap = null) -> Dictionary:
	## Pure, step-wise upgrade of a layout dictionary to SCHEMA_VERSION.
	## `db` / `map` (optional) let 1->2 recognise landmark duplicates and
	## movable starter buildings; without them those steps are skipped (and
	## from_dict still takes landmark items out on load).
	var data := d
	var v := from_version
	while v < SCHEMA_VERSION:
		match v:
			0:
				data = _migrate_0_to_1(data)
			1:
				data = _migrate_1_to_2(data, db, map)
			2:
				data["reference"] = normalize_reference(data.get("reference", {}))
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


static func _migrate_1_to_2(d: Dictionary, db: ItemDatabase = null, map: FarmMap = null) -> Dictionary:
	## v1 used the app's own tile frame; v2 uses the game's (W2 design s1/s6):
	##  a) maps "hayday_farm" / "hayday_farm_h1" / none: every object, annotation
	##     rect, the camera and the reference overlay shift by
	##     WorldLoader.V1_TO_GAME_SHIFT; the map becomes "hayday_farm". Objects
	##     of the retired h1 map at v1 x >= H1_REVIEW_MIN_X are flagged for review.
	##  b) objects whose item duplicates a fixed landmark leave `objects` and are
	##     kept verbatim (original v1 record) in migration.migrated_landmarks.
	##  c) collisions are not resolved here (from_dict reports them).
	##  d) the v1 starter template's automatic lock is cleared on movable items
	##     (only when the note is exactly the starter note; user locks stay).
	var out := d
	var mapd: Dictionary = (out.get("map") as Dictionary) if out.get("map") is Dictionary else {}
	var src_map := str(mapd.get("id", ""))
	var shift := Vector2i.ZERO
	var mig := {"from": 1, "at": Time.get_datetime_string_from_system(true) + "Z", "shifted_by": [0, 0],
		"from_map": src_map if not src_map.is_empty() else WorldLoader.DEFAULT_MAP_ID,
		"migrated_landmarks": [], "review_uids": [], "notes": []}
	if src_map.is_empty() or src_map in WorldLoader.V1_MAP_IDS:
		shift = WorldLoader.V1_TO_GAME_SHIFT
		mapd["id"] = WorldLoader.canonical_map_id(src_map)
	else:
		mig["notes"].append("Map '%s' is not a known v1 map; its coordinates were kept as they were." % src_map)
	mig["shifted_by"] = [shift.x, shift.y]
	out["map"] = mapd
	var h1 := src_map == "hayday_farm_h1"
	var objs_in: Array = out.get("objects", []) if out.get("objects") is Array else []
	var objs_out: Array = []
	var starter := 0
	for rec in objs_in:
		if not rec is Dictionary or not (rec as Dictionary).has("item"):
			objs_out.append(rec)   # from_dict counts it as malformed
			continue
		var r: Dictionary = rec
		var iid := str(r.get("item", ""))
		var it := db.get_item(iid) if db else null
		var lm := landmark_of(db.resolve_id(iid) if db else iid, it, map)
		if not lm.is_empty():
			mig["migrated_landmarks"].append({"record": r.duplicate(true), "landmark": lm,
				"reason": landmark_reason(it.name if it else iid, lm, map, true)})
			continue
		if shift != Vector2i.ZERO:
			var x0 := int(r.get("x", 0)) if _is_num(r.get("x", 0)) else 0
			var y0 := int(r.get("y", 0)) if _is_num(r.get("y", 0)) else 0
			r["x"] = x0 + shift.x
			r["y"] = y0 + shift.y
			if h1 and x0 >= H1_REVIEW_MIN_X:
				r["_review"] = true
				mig["review_uids"].append(int(r.get("uid", 0)) if _is_num(r.get("uid", 0)) else 0)
		if it != null and it.movable and it.can_place() and bool(r.get("locked", false)) \
				and str(r.get("note", "")) == V1_STARTER_NOTE:
			r.erase("locked")
			r.erase("note")
			starter += 1
		objs_out.append(r)
	out["objects"] = objs_out
	if shift != Vector2i.ZERO:
		var anns: Variant = out.get("annotations", [])
		if anns is Array:
			for a in anns:
				if a is Dictionary and a.get("rect") is Array and (a["rect"] as Array).size() == 4:
					var rc: Array = a["rect"]
					rc[0] = int(rc[0]) + shift.x
					rc[1] = int(rc[1]) + shift.y
		var dw := Iso.grid_to_world(Vector2(shift))
		var cam: Variant = out.get("camera", {})
		if cam is Dictionary and _is_num(cam.get("x")) and _is_num(cam.get("y")):
			cam["x"] = float(cam["x"]) + dw.x
			cam["y"] = float(cam["y"]) + dw.y
		var ref: Variant = out.get("reference", {})
		if ref is Dictionary:
			if ref.get("affine") is Array and (ref["affine"] as Array).size() == 6:
				var af: Array = ref["affine"]
				af[4] = float(af[4]) + dw.x
				af[5] = float(af[5]) + dw.y
			elif ref.has("x") or ref.has("y"):
				ref["x"] = float(ref.get("x", 0.0)) + dw.x
				ref["y"] = float(ref.get("y", 0.0)) + dw.y
	if h1:
		mig["notes"].append("Made on the retired 48-wide starting-land map: objects east of the old starting land are flagged for review.")
	if starter > 0:
		mig["starter_unlocked"] = starter
		mig["notes"].append("%d starter building(s) placed by the old template were unlocked so you can move them." % starter)
	if not mig["migrated_landmarks"].is_empty():
		mig["notes"].append("%d fixed landmark object(s) were taken out of the layout (kept in migration.migrated_landmarks)." % mig["migrated_landmarks"].size())
	if not out.has("world"):
		out["world"] = FarmLayout.default_world_state()
	out["migration"] = mig
	return out


static func normalize_reference(r: Variant) -> Dictionary:
	## The canonical reference document, as a fresh copy: {} (no reference) or
	## {"images": [...], "above": bool}. Accepts the single-image shape of schema
	## 1 and 2, keeps unknown fields and gives every image a unique id.
	if not r is Dictionary or (r as Dictionary).is_empty():
		return {}
	var doc: Dictionary = (r as Dictionary).duplicate(true)
	if not doc.get("images") is Array:
		var above := bool(doc.get("above", false))
		doc.erase("above")
		doc = {"images": [doc], "above": above}
	var imgs: Array = []
	for im in doc["images"]:
		if im is Dictionary:
			imgs.append(im)
	if imgs.is_empty():
		return {}
	var used := {}
	var next := 1
	for im: Dictionary in imgs:
		var id := str(im.get("id", ""))
		if id.is_empty() or used.has(id):
			while used.has("r%d" % next) or _reference_id_taken(imgs, "r%d" % next):
				next += 1
			id = "r%d" % next
			im["id"] = id
		used[id] = true
		if str(im.get("name", "")).is_empty():
			im["name"] = str(im.get("file", "")).get_file().get_basename()
	doc["images"] = imgs
	doc["above"] = bool(doc.get("above", false))
	return doc


static func _reference_id_taken(imgs: Array, id: String) -> bool:
	for im: Dictionary in imgs:
		if str(im.get("id", "")) == id:
			return true
	return false


static func _is_num(v: Variant) -> bool:
	return v is int or v is float


# --- files ------------------------------------------------------------------------------

static func backup_path_for(path: String, from_version: int = 1) -> String:
	return "%s.v%d-backup" % [path, from_version]


static func file_schema_version(path: String) -> int:
	## Schema version of the layout file at `path` (0 for the v0 prototype
	## format), -1 when it is missing or not a layout. Cheap: sniffs the head of
	## the file first (the key is written near the top) before parsing it all.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var head := f.get_buffer(4096).get_string_from_utf8()
	f.close()
	var m := RegEx.create_from_string("\"schema_version\"\\s*:\\s*(\\d+)").search(head)
	if m != null and head.contains("\"" + FORMAT + "\""):
		return int(m.get_string(1))
	var data: Variant = JsonUtil.parse(JsonUtil.read_text(path))
	if not data is Dictionary:
		return -1
	var sv: Variant = (data as Dictionary).get("schema_version", 0)
	if str((data as Dictionary).get("format", "")) != FORMAT and not (data as Dictionary).has("items"):
		return -1
	return int(sv) if (sv is int or sv is float) else 0


static func backup_original(path: String) -> String:
	## If `path` holds a pre-v2 layout and no backup exists yet, copies its
	## original bytes to backup_path_for(path, <its version>). Returns the backup
	## path (existing or new), "" when no backup is needed, or "error:<message>"
	## when the copy failed.
	var ver := file_schema_version(path)
	if ver < 0 or ver >= SCHEMA_VERSION:
		return ""
	var bk := backup_path_for(path, ver)
	if FileAccess.file_exists(bk):
		return bk
	var err := DirAccess.copy_absolute(path, bk)
	if err != OK:
		return "error:%s" % error_string(err)
	return bk


static func save_file(l: FarmLayout, path: String) -> Error:
	## Atomic save. A pre-v2 layout file is never overwritten without keeping
	## its original bytes as `<file>.v<N>-backup` first (the first save over a
	## migrated file); if that copy fails nothing is written.
	if FileAccess.file_exists(path):
		var bk := backup_original(path)
		if bk.begins_with("error:"):
			push_warning("Not saving %s: could not keep a backup of the old file (%s)" % [path, bk.substr(6)])
			return ERR_CANT_CREATE
	var text := JsonUtil.stringify(to_dict(l), true)
	var err := JsonUtil.write_atomic(path, text)
	if err == OK:
		l.loaded_schema = SCHEMA_VERSION if l.loaded_schema >= 0 else l.loaded_schema
	return err


static func load_file(path: String, db: ItemDatabase, report: LoadReport, map: FarmMap = null) -> FarmLayout:
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
	return from_dict(data, db, report, map)
