class_name AccuracyReport
extends RefCounted
## Farm Accuracy Report: how far the farm on screen can be trusted when the
## user rebuilds it in Hay Day. Gathers what the data itself says (map
## provenance, plot and landmark confidence, footprint status, the layout's use
## of approximate data, screenshot calibration results) and never upgrades it:
## nothing is called exact or verified unless a calibration result says so,
## and even then only "matches a screenshot within N tiles".
##
## Pure core class (no scene / UI / App): build() returns plain dictionaries.
##
##   build(map, db, layout = null, references = []) -> {
##     headline: String (one plain-language sentence), level: String,
##     sections: [{id, title, status: "ok"|"info"|"warn"|"unknown", lines: [String]}],
##     source, version, start_land, expansion, landmarks, footprints, layout,
##     calibration: [CalibrationMath.summary()], uncertainties: [String]}
##   to_text(report) -> String (plain text for copy / export)
##
## `references` is a list of reference image dictionaries (layout.reference
## "images"); when empty, the layout's own images are used.

const LEVELS := ["public_approximation", "game_data_unverified", "game_data_calibrated", "unknown"]
## Plot / region statuses that are not approximations.
const SOLID_STATUSES := ["game_data", "verified", "verified-in-data", "confirmed"]
## Tiles around an approximate landmark in which an object counts as "near" it.
const NEAR_TILES := 2
const MAX_LISTED := 12


static func build(map: FarmMap, db: ItemDatabase, layout: FarmLayout = null, references: Array = []) -> Dictionary:
	var refs: Array = references
	if refs.is_empty() and layout != null:
		refs = (LayoutIO.normalize_reference(layout.reference).get("images", []) as Array)
	var r := {
		"source": _source(map),
		"version": _version(map),
		"start_land": _start_land(map),
		"expansion": _expansion(map),
		"landmarks": _landmarks(map),
		"footprints": _footprints(db, layout),
		"layout": _layout_use(map, db, layout),
		"calibration": _calibration(refs, map),
		"uncertainties": _uncertainties(map, db),
	}
	var hl := headline(r)
	r["headline"] = hl[0]
	r["level"] = hl[1]
	r["sections"] = _sections(r)
	return r


# --- parts -------------------------------------------------------------------------------

static func _source(map: FarmMap) -> Dictionary:
	if map == null:
		return {"kind": "unknown", "kind_text": "No map", "label": "", "active": "", "overrides": false}
	var pv := map.provenance
	var kind := str(pv.get("kind", ""))
	var overrides: Dictionary = pv.get("user_overrides", {}) if pv.get("user_overrides") is Dictionary else {}
	var kind_text := "Unknown origin"
	match kind:
		"public_approximation":
			kind_text = "Public approximation (reconstructed from wiki images and tables)"
		"private_game_data":
			kind_text = "Private pack world (derived from your own game files)"
	if not overrides.is_empty():
		kind_text += " + your landmark corrections"
	return {"kind": kind if not kind.is_empty() else "unknown", "kind_text": kind_text,
		"label": map.provenance_label(), "active": str(pv.get("active", "")), "map_id": map.id, "map_name": map.name,
		"pack_id": str(pv.get("pack_id", "")), "pack_version": str(pv.get("pack_version", "")),
		"overrides": not overrides.is_empty(), "override_landmarks": (overrides.get("landmarks", []) as Array).duplicate(),
		"rejected": (pv.get("rejected", []) as Array).size() if pv.get("rejected") is Array else 0,
		"geometry_status": map.geometry_status, "confidence": str(pv.get("confidence", "")),
		"source_text": str(pv.get("source", ""))}


static func _version(map: FarmMap) -> Dictionary:
	if map == null:
		return {"client_version": "", "generated": ""}
	var cv := str(map.provenance.get("client_version", ""))
	return {"client_version": cv, "generated": str(map.provenance.get("generated", "")),
		"text": ("game client %s" % cv) if not cv.is_empty() else "not tied to a known game version"}


static func _start_land(map: FarmMap) -> Dictionary:
	var out := {"tiles": 0, "rect": [], "statuses": {}}
	if map == null:
		return out
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-1, -1)
	var n := 0
	for y in map.size.y:
		for x in map.size.x:
			if map.kinds[y * map.size.x + x] == FarmMap.Kind.BUILDABLE:
				n += 1
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	var st := {}
	for reg in map.regions:
		if reg["kind"] == FarmMap.Kind.BUILDABLE:
			var s := str(reg.get("status", map.geometry_status))
			st[s] = int(st.get(s, 0)) + 1
	out["tiles"] = n
	out["statuses"] = st
	if n > 0:
		out["rect"] = [lo.x, lo.y, hi.x - lo.x + 1, hi.y - lo.y + 1]
		out["is_rect"] = (hi.x - lo.x + 1) * (hi.y - lo.y + 1) == n
	return out


static func _is_solid(status: String) -> bool:
	return status in SOLID_STATUSES


static func _expansion(map: FarmMap) -> Dictionary:
	var out := {"plots": 0, "by_section": {}, "geometry": {}, "cost_known": 0, "cost_unknown": 0,
		"level_known": 0, "client_locked": 0, "unmapped_sections": 0, "unmapped_plots": 0, "approximate_plots": 0}
	if map == null:
		return out
	var by_section := {}
	var geo := {}
	for p in map.plots:
		var sec := str(p.get("section", "main"))
		by_section[sec] = int(by_section.get(sec, 0)) + 1
		var st := str(p.get("status", map.geometry_status))
		geo[st] = int(geo.get(st, 0)) + 1
		if not _is_solid(st):
			out["approximate_plots"] = int(out["approximate_plots"]) + 1
		var cost: Variant = p.get("cost", {})
		if cost is Dictionary and not (cost as Dictionary).is_empty():
			out["cost_known"] = int(out["cost_known"]) + 1
		else:
			out["cost_unknown"] = int(out["cost_unknown"]) + 1
		if int(p.get("min_level", -1)) >= 0:
			out["level_known"] = int(out["level_known"]) + 1
		if bool(p.get("client_locked", false)):
			out["client_locked"] = int(out["client_locked"]) + 1
	out["plots"] = map.plots.size()
	out["by_section"] = by_section
	out["geometry"] = geo
	for u in map.unmapped_sections:
		if u is Dictionary:
			out["unmapped_sections"] = int(out["unmapped_sections"]) + 1
			var np: Variant = (u as Dictionary).get("plots", 0)
			out["unmapped_plots"] = int(out["unmapped_plots"]) + (int(np) if (np is int or np is float) else 0)
	return out


static func _landmarks(map: FarmMap) -> Dictionary:
	var out := {"total": 0, "by_confidence": {}, "blocking": 0, "approximate": [], "approximate_names": []}
	if map == null:
		return out
	var bc := {}
	for c: String in Landmark.CONFIDENCES:
		bc[c] = 0
	for lm in map.landmarks:
		bc[lm.confidence] = int(bc.get(lm.confidence, 0)) + 1
		if lm.blocks_placement():
			out["blocking"] = int(out["blocking"]) + 1
		if lm.confidence == "approximate":
			(out["approximate"] as Array).append(lm.id)
			(out["approximate_names"] as Array).append(lm.name)
	out["total"] = map.landmarks.size()
	out["by_confidence"] = bc
	return out


static func _footprints(db: ItemDatabase, layout: FarmLayout) -> Dictionary:
	var out := {"catalogue_total": 0, "trusted": 0, "unverified": 0, "by_status": {},
		"layout_objects": 0, "layout_unverified_objects": 0, "layout_unverified_items": [], "layout_unknown_items": 0}
	if db == null:
		return out
	var bs := {}
	for it: ItemDef in db.ordered:
		bs[it.footprint_status] = int(bs.get(it.footprint_status, 0)) + 1
		if it.is_footprint_trusted():
			out["trusted"] = int(out["trusted"]) + 1
		else:
			out["unverified"] = int(out["unverified"]) + 1
	out["catalogue_total"] = db.ordered.size()
	out["by_status"] = bs
	if layout == null:
		return out
	var items := {}
	var unknown := {}
	for o: PlacedObject in layout.objects.values():
		out["layout_objects"] = int(out["layout_objects"]) + 1
		var it := db.get_item(o.item_id)
		if it == null:
			unknown[o.item_id] = true
			out["layout_unverified_objects"] = int(out["layout_unverified_objects"]) + 1
		elif not it.is_footprint_trusted():
			items[it.id] = true
			out["layout_unverified_objects"] = int(out["layout_unverified_objects"]) + 1
	var ids := items.keys()
	ids.sort()
	out["layout_unverified_items"] = ids
	out["layout_unknown_items"] = unknown.size()
	return out


static func _layout_use(map: FarmMap, db: ItemDatabase, layout: FarmLayout) -> Dictionary:
	## Does the design rely on approximate data? Objects standing on plots
	## whose geometry is an approximation, or near an approximate landmark.
	var out := {"has_layout": layout != null, "objects": 0, "on_approximate_plots": 0, "near_approximate_landmarks": 0,
		"approximate_landmarks_near": [], "on_approximate_land": 0, "uses_approximate": false}
	if layout == null or map == null:
		return out
	var near_rects: Array = []
	for lm in map.landmarks:
		if lm.confidence == "approximate":
			near_rects.append([lm.id, lm.rect().grow(NEAR_TILES)])
	# Approximate starting land too (region status), per tile.
	var approx_region := PackedByteArray()
	approx_region.resize(map.regions.size())
	for i in map.regions.size():
		var reg: Dictionary = map.regions[i]
		approx_region[i] = 0 if _is_solid(str(reg.get("status", map.geometry_status))) else 1
	var lm_hit := {}
	for o: PlacedObject in layout.objects.values():
		out["objects"] = int(out["objects"]) + 1
		var r := o.rect()
		var on_plot := false
		var on_land := false
		for t in Iso.tiles_of(r.position, r.size):
			if not map.in_bounds(t):
				continue
			var i := t.y * map.size.x + t.x
			var pi := map.plot_of[i]
			if pi >= 0 and not _is_solid(str(map.plots[pi].get("status", map.geometry_status))):
				on_plot = true
			var ri := map.region_of[i]
			if ri >= 0 and approx_region[ri] == 1:
				on_land = true
		if on_plot:
			out["on_approximate_plots"] = int(out["on_approximate_plots"]) + 1
		if on_land:
			out["on_approximate_land"] = int(out["on_approximate_land"]) + 1
		var near := false
		for nr in near_rects:
			if (nr[1] as Rect2i).intersects(r):
				near = true
				lm_hit[nr[0]] = true
		if near:
			out["near_approximate_landmarks"] = int(out["near_approximate_landmarks"]) + 1
	var ids := lm_hit.keys()
	ids.sort()
	out["approximate_landmarks_near"] = ids
	out["uses_approximate"] = int(out["on_approximate_land"]) > 0 or int(out["near_approximate_landmarks"]) > 0
	return out


static func _calibration(refs: Array, map: FarmMap) -> Array:
	var out: Array = []
	for im in refs:
		if im is Dictionary:
			out.append(CalibrationMath.summary(im, map))
	return out


static func _uncertainties(map: FarmMap, db: ItemDatabase) -> Array:
	## The map's own notes and unmapped sections, then the catalogue's open points.
	var out: Array = []
	if map != null:
		for n in map.notes:
			out.append(str(n))
		for u in map.unmapped_sections:
			if u is Dictionary:
				var loc := str((u as Dictionary).get("location", ""))
				out.append("Not drawn: %s (%s plots)%s" % [str(u.get("name", u.get("id", "?"))), str(u.get("plots", "?")),
					("; " + loc) if not loc.is_empty() else ""])
	if db != null:
		var n_unv := 0
		for it: ItemDef in db.ordered:
			if not it.is_footprint_trusted():
				n_unv += 1
		if n_unv > 0:
			out.append("%d catalogue item(s) have unverified or provisional footprints." % n_unv)
	return out


# --- headline ------------------------------------------------------------------------------

static func best_calibration(report: Dictionary) -> Dictionary:
	## The best measured calibration that still places its image (verdict
	## good/fair/poor, applied), {} when there is none.
	var best := {}
	for c: Dictionary in report.get("calibration", []):
		if not bool(c.get("applied", false)) or not str(c.get("verdict", "")) in ["good", "fair", "poor"]:
			continue
		if best.is_empty() or float(c["rms_tiles"]) < float(best["rms_tiles"]):
			best = c
	return best


static func headline(report: Dictionary) -> Array:
	## [sentence, level]. One plain-language sentence; never claims exactness.
	var src: Dictionary = report.get("source", {})
	var kind := str(src.get("kind", "unknown"))
	var best := best_calibration(report)
	var good := not best.is_empty() and str(best["verdict"]) == "good" and int(best.get("approximate_points", 0)) == 0
	match kind:
		"private_game_data":
			if good:
				return ["Game-derived map; a screenshot calibration matches it within %.2f tile RMS over %d points." % [float(best["rms_tiles"]), int(best["points"])],
					"game_data_calibrated"]
			return ["Game-derived map, placement correspondence not yet visually verified.", "game_data_unverified"]
		"public_approximation":
			return ["Public approximate map: positions are approximations reconstructed from wiki images.", "public_approximation"]
	return ["Map of unknown origin: positions have not been checked against the game.", "unknown"]


# --- sections ------------------------------------------------------------------------------

static func _sections(r: Dictionary) -> Array:
	var out: Array = []
	var src: Dictionary = r["source"]
	var lines: Array = [str(src["kind_text"]), "Active: %s" % str(src.get("label", ""))]
	if not str(src.get("pack_id", "")).is_empty():
		lines.append("Pack: %s %s" % [src["pack_id"], src.get("pack_version", "")])
	if bool(src.get("overrides", false)):
		lines.append("Your corrections move: %s" % ", ".join(PackedStringArray(src.get("override_landmarks", []))))
	if int(src.get("rejected", 0)) > 0:
		lines.append("%d private world file(s) were rejected and not used" % int(src["rejected"]))
	out.append({"id": "source", "title": "Map source", "lines": lines,
		"status": "ok" if src["kind"] == "private_game_data" else ("warn" if src["kind"] == "public_approximation" else "unknown")})
	var ver: Dictionary = r["version"]
	out.append({"id": "version", "title": "Game version", "lines": [str(ver.get("text", "")),
		("Generated %s" % ver["generated"]) if not str(ver.get("generated", "")).is_empty() else "Generation date unknown"],
		"status": "info" if not str(ver.get("client_version", "")).is_empty() else "unknown"})
	var sl: Dictionary = r["start_land"]
	var sl_lines: Array = []
	if (sl.get("rect", []) as Array).size() == 4:
		var rc: Array = sl["rect"]
		sl_lines.append("%d tiles, %d×%d at (%d, %d)%s" % [int(sl["tiles"]), rc[2], rc[3], rc[0], rc[1],
			"" if bool(sl.get("is_rect", true)) else " (not a full rectangle)"])
	else:
		sl_lines.append("No starting land in this map")
	sl_lines.append("Status: %s" % _counts_text(sl.get("statuses", {})))
	var sl_solid := true
	for s in (sl.get("statuses", {}) as Dictionary):
		sl_solid = sl_solid and _is_solid(str(s))
	out.append({"id": "start_land", "title": "Starting land", "lines": sl_lines, "status": "ok" if sl_solid else "warn"})
	var ex: Dictionary = r["expansion"]
	var ex_lines: Array = ["%d plots drawn (%s)" % [int(ex["plots"]), _counts_text(ex["by_section"], false, "%d in %s")],
		"Geometry: %s" % _counts_text(ex["geometry"]),
		"Cost known for %d, unknown for %d; unlock level known for %d" % [int(ex["cost_known"]), int(ex["cost_unknown"]), int(ex["level_known"])]]
	if int(ex["unmapped_sections"]) > 0:
		ex_lines.append("%d section(s) with %d plots are not drawn (geometry unknown)" % [int(ex["unmapped_sections"]), int(ex["unmapped_plots"])])
	if int(ex["client_locked"]) > 0:
		ex_lines.append("%d plot(s) are locked in the game client" % int(ex["client_locked"]))
	out.append({"id": "expansion", "title": "Expansion land", "lines": ex_lines,
		"status": "ok" if int(ex["approximate_plots"]) == 0 and int(ex["unmapped_sections"]) == 0 else "warn"})
	var lm: Dictionary = r["landmarks"]
	var lm_lines: Array = ["%d landmarks: %s" % [int(lm["total"]), _counts_text(lm["by_confidence"], true)],
		"%d block placement" % int(lm["blocking"])]
	if not (lm["approximate"] as Array).is_empty():
		lm_lines.append("Approximate (guide only, don't block): %s" % ", ".join(PackedStringArray(lm["approximate_names"])))
	out.append({"id": "landmarks", "title": "Landmarks", "lines": lm_lines,
		"status": "ok" if (lm["approximate"] as Array).is_empty() else "warn"})
	var fp: Dictionary = r["footprints"]
	var fp_lines: Array = ["Catalogue: %d trusted, %d unverified of %d" % [int(fp["trusted"]), int(fp["unverified"]), int(fp["catalogue_total"])]]
	if int(fp["layout_objects"]) > 0:
		fp_lines.append("This design: %d of %d objects have unverified footprints" % [int(fp["layout_unverified_objects"]), int(fp["layout_objects"])])
		var ids: Array = fp["layout_unverified_items"]
		if not ids.is_empty():
			fp_lines.append("Items: %s%s" % [", ".join(PackedStringArray(ids.slice(0, MAX_LISTED))),
				(" +%d more" % (ids.size() - MAX_LISTED)) if ids.size() > MAX_LISTED else ""])
	out.append({"id": "footprints", "title": "Footprints", "lines": fp_lines,
		"status": "ok" if int(fp["layout_unverified_objects"]) == 0 else "warn"})
	var lu: Dictionary = r["layout"]
	if bool(lu["has_layout"]):
		var lu_lines: Array = []
		lu_lines.append("%d object(s) stand on land whose shape is an approximation" % int(lu["on_approximate_land"]))
		lu_lines.append("%d of them on approximate expansion plots" % int(lu["on_approximate_plots"]))
		lu_lines.append("%d object(s) within %d tiles of an approximate landmark%s" % [int(lu["near_approximate_landmarks"]), NEAR_TILES,
			(" (%s)" % ", ".join(PackedStringArray(lu["approximate_landmarks_near"]))) if not (lu["approximate_landmarks_near"] as Array).is_empty() else ""])
		out.append({"id": "layout", "title": "This design", "lines": lu_lines,
			"status": "warn" if bool(lu["uses_approximate"]) else "ok"})
	var cal: Array = r["calibration"]
	var cal_lines: Array = []
	var cal_status := "unknown"
	for c: Dictionary in cal:
		cal_lines.append("%s: %s" % [str(c.get("name", c.get("id", ""))), str(c.get("text", ""))])
		if str(c.get("verdict", "")) == "good" and bool(c.get("applied", false)):
			cal_status = "ok"
		elif cal_status != "ok" and str(c.get("verdict", "")) in ["fair", "poor"]:
			cal_status = "warn"
	if cal.is_empty():
		cal_lines.append("No screenshot references: placement has not been compared with the game")
	out.append({"id": "calibration", "title": "Screenshot calibration", "lines": cal_lines, "status": cal_status})
	out.append({"id": "uncertainties", "title": "Remaining uncertainties", "lines": (r["uncertainties"] as Array).duplicate(),
		"status": "info" if (r["uncertainties"] as Array).is_empty() else "warn"})
	return out


## Status / confidence ids as words after a count ("52 approximate").
const COUNT_WORDS := {"approximation": "approximate", "game_data": "from game data", "verified-in-data": "verified in the data"}


static func _counts_text(d: Dictionary, keep_zero: bool = false, pattern: String = "%d %s") -> String:
	## "52 approximate, 3 confirmed": the count first, then what it counts.
	if d.is_empty():
		return "none"
	var parts: PackedStringArray = []
	var keys := d.keys()
	keys.sort()
	for k in keys:
		if keep_zero or int(d[k]) != 0:
			var word := str(COUNT_WORDS.get(str(k), str(k).replace("_", " ").replace("-", " ")))
			parts.append(pattern % [int(d[k]), word])
	return ", ".join(parts) if not parts.is_empty() else "none"


static func to_text(report: Dictionary) -> String:
	var out: PackedStringArray = ["Farm accuracy report", str(report.get("headline", "")), ""]
	for s: Dictionary in report.get("sections", []):
		out.append("%s [%s]" % [str(s["title"]), str(s["status"])])
		for l in s["lines"]:
			out.append("  - " + str(l))
	return "\n".join(out)
