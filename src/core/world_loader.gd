class_name WorldLoader
extends RefCounted
## Chooses and loads the farm world (FarmMap) for a map id:
##   1. the public map file (data/maps/<id>.json, approximate geometry), unless
##   2. an installed private pack declares a world file ("world": "world/world.json"
##      in its pack.json) with the same map id, format and schema_version 2 that
##      validates without errors -> it REPLACES the public map entirely
##      (candidates are tried highest priority first; a broken one is skipped
##      with a warning and the next / the public map is used);
##   3. finally an optional user override patch (map authoring) is applied:
##      user://world_overrides/<map id>.json =
##      {"landmarks": {"<landmark id>": {"origin": [x, y], ...}}}.
## FarmMap.provenance records what is active ("label" is UI text) and
## FarmMap.warnings explains anything that was skipped.
## Pure core class: no App, no AssetLibrary (the caller passes the candidates,
## e.g. from AssetLibrary.world_data_files()).

const DEFAULT_MAP_ID := "hayday_farm"
const USER_OVERRIDES_DIR := "user://world_overrides"
## Retired map ids -> the map their layouts migrate to (layout schema 1 -> 2).
const LEGACY_MAP_IDS := {"hayday_farm_h1": "hayday_farm"}
## Every map id a schema-1 layout may name; all convert with V1_TO_GAME_SHIFT.
const V1_MAP_IDS := ["hayday_farm", "hayday_farm_h1"]
## v1 app tile -> game tile frame: game = v1 + V1_TO_GAME_SHIFT.
const V1_TO_GAME_SHIFT := Vector2i(-5, -3)
## Landmark fields a user override patch may change.
const PATCHABLE_LANDMARK_FIELDS := ["origin", "footprint", "blocks", "draw_anchor", "mirrored", "hidden_by_default",
	"selectable", "note", "name"]


static func canonical_map_id(map_id: String) -> String:
	## Retired ids map to their replacement ("" -> DEFAULT_MAP_ID).
	if map_id.is_empty():
		return DEFAULT_MAP_ID
	return LEGACY_MAP_IDS.get(map_id, map_id)


static func is_legacy_map_id(map_id: String) -> bool:
	return LEGACY_MAP_IDS.has(map_id)


static func load(public_path: String, private_candidates: Array = [], user_overrides_dir: String = USER_OVERRIDES_DIR) -> FarmMap:
	## private_candidates: Array of Dictionary, highest priority first:
	##   {"world": <path of the world json> (or "path"), "pack_id", "version", "name", "priority"}
	## user_overrides_dir: folder holding "<map id>.json" patches ("" = none).
	var warnings: PackedStringArray = PackedStringArray()
	var rejected: Array = []
	var pub_data: Variant = JsonUtil.read_json(public_path)
	var map: FarmMap = null
	var raw: Dictionary = {}
	var base_dir := public_path.get_base_dir()
	var active := "public"
	var cand_used: Dictionary = {}
	var pub_id := ""
	if pub_data is Dictionary:
		pub_id = str((pub_data as Dictionary).get("id", ""))
	for c in private_candidates:
		if not c is Dictionary:
			continue
		var path := str(c.get("world", c.get("path", "")))
		var pack_id := str(c.get("pack_id", c.get("id", "?")))
		if path.is_empty():
			continue
		var reason := ""
		var data: Variant = JsonUtil.read_json(path)
		var cand: FarmMap = null
		if not data is Dictionary:
			reason = "file missing or not a JSON object (%s)" % path.get_file()
		else:
			reason = validate_private_world(data, pub_id)
			if reason.is_empty():
				cand = FarmMap.new()
				cand.source_path = path
				cand.from_dict(data, path.get_base_dir())
				if not cand.errors.is_empty():
					reason = "%d error(s): %s" % [cand.errors.size(), "; ".join(cand.errors.slice(0, 3))]
		if not reason.is_empty():
			rejected.append({"pack_id": pack_id, "path": path, "reason": reason})
			warnings.append("Private world data of pack '%s' ignored: %s" % [pack_id, reason])
			continue
		map = cand
		raw = data
		base_dir = path.get_base_dir()
		active = "private"
		cand_used = c
		break
	if map == null:
		map = FarmMap.load_file(public_path)
		raw = pub_data if pub_data is Dictionary else {}
	map.warnings.append_array(warnings)
	var prov: Dictionary = map.provenance
	prov["active"] = active
	prov["rejected"] = rejected
	if active == "private":
		var ver := str(cand_used.get("version", ""))
		if ver.is_empty():
			ver = str(prov.get("generated", "")).left(10)
		prov["pack_id"] = str(cand_used.get("pack_id", ""))
		prov["pack_version"] = ver
		prov["label"] = "Game data (private pack %s)" % ver if not ver.is_empty() else "Game data (private pack)"
	else:
		prov["label"] = "Public approximation"
	if not user_overrides_dir.is_empty() and not map.id.is_empty():
		var opath := user_overrides_dir.path_join(map.id + ".json")
		if FileAccess.file_exists(opath):
			var patch: Variant = JsonUtil.read_json(opath)
			var res := apply_user_overrides(map, raw, patch, base_dir)
			if res["map"] != null:
				map = res["map"]
				map.provenance = prov
			for w in res["warnings"]:
				map.warnings.append(w)
			if not (res["applied"] as Array).is_empty():
				prov["user_overrides"] = {"path": opath, "landmarks": res["applied"]}
				prov["label"] = str(prov["label"]) + " + your corrections"
	return map


static func load_world(public_path: String, private_candidates: Array = [], user_overrides_dir: String = USER_OVERRIDES_DIR) -> FarmMap:
	## Same as load() (name without the GDScript built-in clash, for callers that prefer it).
	return WorldLoader.load(public_path, private_candidates, user_overrides_dir)


static func validate_private_world(data: Dictionary, public_id: String) -> String:
	## "" when `data` may replace the public map `public_id`, else the reason.
	if str(data.get("format", "")) != FarmMap.FORMAT:
		return "format is not '%s'" % FarmMap.FORMAT
	var sv: Variant = data.get("schema_version", 0)
	if not (sv is int or sv is float) or int(sv) != 2:
		return "schema_version must be 2"
	if str(data.get("frame", "")) != "game":
		return "frame must be 'game'"
	var wid := str(data.get("id", ""))
	if wid.is_empty() or (not public_id.is_empty() and wid != public_id):
		return "map id '%s' does not match '%s'" % [wid, public_id]
	var sz: Variant = data.get("size", null)
	if not sz is Array or (sz as Array).size() != 2 or int(sz[0]) <= 0 or int(sz[1]) <= 0:
		return "size must be [w, h]"
	if int(sz[0]) * int(sz[1]) > 4096 * 4096:
		return "size is implausibly large"
	if not data.get("regions") is Array or (data["regions"] as Array).is_empty():
		return "no regions"
	return ""


static func apply_user_overrides(map: FarmMap, raw: Dictionary, patch: Variant, base_dir: String = "") -> Dictionary:
	## Applies a sparse landmark patch on top of the raw map data and rebuilds
	## the map. Invalid entries are skipped with a warning (the map is never
	## broken by a bad patch). Returns {"map": FarmMap or null (unchanged),
	## "applied": [landmark ids], "warnings": [str]}.
	var out := {"map": null, "applied": [], "warnings": []}
	if not patch is Dictionary:
		out["warnings"].append("World corrections file is not a JSON object; ignored")
		return out
	var lm_patch: Variant = (patch as Dictionary).get("landmarks", {})
	if not lm_patch is Dictionary or (lm_patch as Dictionary).is_empty():
		return out
	var data: Dictionary = raw.duplicate(true)
	var list: Array = data.get("landmarks", []) if data.get("landmarks") is Array else []
	var by_id := {}
	for i in list.size():
		if list[i] is Dictionary:
			by_id[str(list[i].get("id", ""))] = i
	for lid in lm_patch:
		var sid := str(lid)
		var ch: Variant = lm_patch[lid]
		if not by_id.has(sid) or map.landmark(sid) == null:
			out["warnings"].append("World corrections: unknown landmark '%s' skipped" % sid)
			continue
		if not ch is Dictionary:
			out["warnings"].append("World corrections: '%s' is not an object; skipped" % sid)
			continue
		var rec: Dictionary = (list[by_id[sid]] as Dictionary).duplicate(true)
		var touched := false
		for f in ch:
			if str(f) in PATCHABLE_LANDMARK_FIELDS:
				rec[str(f)] = ch[f]
				touched = true
			else:
				out["warnings"].append("World corrections: %s.%s cannot be changed; skipped" % [sid, f])
		if not touched:
			continue
		var errs: Array = []
		if Landmark.from_dict(rec, errs) == null:
			out["warnings"].append("World corrections for '%s' are invalid (%s); skipped" % [sid, "; ".join(PackedStringArray(errs))])
			continue
		list[by_id[sid]] = rec
		out["applied"].append(sid)
	if (out["applied"] as Array).is_empty():
		return out
	data["landmarks"] = list
	var m := FarmMap.new()
	m.source_path = map.source_path
	m.from_dict(data, base_dir)
	if not m.errors.is_empty():
		out["warnings"].append("World corrections made the map invalid (%s); ignored" % "; ".join(m.errors.slice(0, 2)))
		out["applied"] = []
		return out
	m.warnings.append_array(map.warnings)
	out["map"] = m
	return out
