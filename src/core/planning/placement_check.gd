class_name PlacementCheck
extends RefCounted
## Screenshot placement check: how well the world on screen (landmarks,
## objects) matches a calibrated screenshot of the user's real farm.
##
## Input: one reference image with a stored calibration (CalibrationMath record:
## pairs of screenshot pixel <-> grid point, usually footprint corners / centres
## of named landmarks), the active map and layout. Output: a JSON-safe report
## {format, version, image, n, fit, points, landmarks, alternatives, predicted,
##  conclusion, label, generated} and a Markdown rendering.
##
## Residuals per point are measured LEAVE-ONE-OUT: the transform is fitted on
## the other points (a similarity, the screenshot model, from 2+ points) and the
## left-out click is compared with where that fit puts its grid point. So three
## clicked landmarks already measure something (a fit through all points of
## an exact model would always show zero error).
##
## Alternatives: for a clicked landmark "center" whose sprite is anchored on a
## client registration point that differs from the footprint centre (the
## centred truck), the clicked pixel is compared with both candidates.
##
## Labels: "pending-screenshot" (fewer than 3 usable points: nothing measured),
## "screenshot-checked" (every point within TOL_TILES), "mismatch" (otherwise).
## Nothing here is ever called verified-in-data: a screenshot check is its own kind of evidence.
## Pure core class: no scene, UI or App dependencies.

const FORMAT := "hayday-sandbox-placement-check"
const VERSION := 1
const TOL_TILES := 0.25      ## a click this close to its grid point agrees (about 16 world px)
const FAR_TILES := 0.5


static func build(image: Dictionary, map: FarmMap, layout: FarmLayout = null, generated: String = "") -> Dictionary:
	var rec := CalibrationMath.record_of(image)
	var pts := CalibrationMath.refresh_anchor_flags(CalibrationMath.clean_points(rec.get("points", [])), map)
	var out := {"format": FORMAT, "version": VERSION, "PRIVATE": true, "generated": generated,
		"image": {"id": str(image.get("id", "")), "name": str(image.get("name", "")), "file": str(image.get("file", ""))},
		"n": pts.size(), "fit": {}, "points": [], "landmarks": [], "alternatives": [], "predicted": [],
		"conclusion": "", "label": "pending-screenshot"}
	if pts.size() < 2:
		out["conclusion"] = "Not calibrated: click at least 3 named landmark points on the screenshot (Calibrate)."
		return out
	var full := CalibrationMath.fit(pts, "similarity")
	out["fit"] = {"model": "similarity", "ok": bool(full.get("ok", false)), "rms_tiles": snappedf(float(full.get("rms_tiles", 0.0)), 0.0001),
		"max_tiles": snappedf(float(full.get("max_tiles", 0.0)), 0.0001), "iso": full.get("iso", {})}
	var measured := 0
	var worst := 0.0
	var by_lm := {}
	for k in pts.size():
		var p: Dictionary = pts[k]
		var row := {"index": k, "name": _point_name(p, map, layout), "landmark": str(p.get("landmark", "")),
			"spot": str(p.get("spot", "")), "grid": [snappedf(CalibrationMath.point_grid(p).x, 0.001), snappedf(CalibrationMath.point_grid(p).y, 0.001)],
			"img": [snappedf(CalibrationMath.point_img(p).x, 0.1), snappedf(CalibrationMath.point_img(p).y, 0.1)],
			"approximate": bool(p.get("approximate", false))}
		var loo := _leave_one_out(pts, k)
		if loo.is_empty():
			row["status"] = "not measured"
		else:
			measured += 1
			row["tiles"] = snappedf(float(loo["tiles"]), 0.001)
			row["px"] = snappedf(float(loo["px"]), 0.1)
			row["d_tiles"] = loo["d_tiles"]
			row["clicked_grid"] = loo["clicked_grid"]
			row["status"] = "agrees" if float(loo["tiles"]) <= TOL_TILES else ("off" if float(loo["tiles"]) <= FAR_TILES else "far off")
			worst = maxf(worst, float(loo["tiles"]))
			if not str(row["landmark"]).is_empty():
				var a: Array = by_lm.get(row["landmark"], [])
				a.append(row)
				by_lm[row["landmark"]] = a
			_alternatives(out, row, map)
		out["points"].append(row)
	for lid: String in by_lm:
		var rows: Array = by_lm[lid]
		var mx := 0.0
		for r: Dictionary in rows:
			mx = maxf(mx, float(r["tiles"]))
		var lm: Landmark = map.landmark(lid) if map != null else null
		out["landmarks"].append({"id": lid, "points": rows.size(), "max_tiles": snappedf(mx, 0.001),
			"status": "agrees" if mx <= TOL_TILES else "mismatch", "confidence": lm.confidence if lm else "missing"})
	# Where the fitted screenshot transform puts every landmark (overlay / manual checks).
	if bool(full.get("ok", false)) and map != null:
		var g2i := _xf(full.get("world_to_image", []))   # world px -> image px
		for lm: Landmark in map.landmarks:
			var c := Vector2(lm.origin) + Vector2(lm.footprint) * 0.5
			var e := {"id": lm.id, "center_img": _v(g2i * Iso.grid_to_world(c))}
			var reg: Variant = lm.extra.get("client_registration", null)
			if reg is Array and (reg as Array).size() == 2:
				e["registration_img"] = _v(g2i * Iso.grid_to_world(Vector2(float(reg[0]), float(reg[1]))))
			out["predicted"].append(e)
	if measured < 3:
		out["label"] = "pending-screenshot"
		out["conclusion"] = "%d point(s) measured: click at least 3 named landmark points (corners or centres) so each one is checked against the others." % measured
	elif worst <= TOL_TILES:
		out["label"] = "screenshot-checked"
		out["conclusion"] = "All %d clicked points agree with the world within %.2f tile (worst %.2f)." % [measured, TOL_TILES, worst]
	else:
		out["label"] = "mismatch"
		var bad: Array = []
		for r: Dictionary in out["points"]:
			if r.has("tiles") and float(r["tiles"]) > TOL_TILES:
				bad.append("%s (%.2f tile)" % [r["name"], r["tiles"]])
		out["conclusion"] = "Disagreement above %.2f tile at: %s. Check those clicks first; a real offset shows on several screenshots." % [TOL_TILES, ", ".join(PackedStringArray(bad))]
	return out


static func _leave_one_out(pts: Array, k: int) -> Dictionary:
	## Fit a similarity on every point but k; measure point k against it.
	var others: Array = []
	for i in pts.size():
		if i != k:
			others.append(pts[i])
	if others.size() < 2:
		return {}
	var f := CalibrationMath.fit(others, "similarity")
	if not bool(f.get("ok", false)):
		return {}
	var g2i := _xf(f.get("world_to_image", []))
	var i2w := _xf(f.get("image_to_world", []))
	var g := CalibrationMath.point_grid(pts[k])
	var img := CalibrationMath.point_img(pts[k])
	var pred := g2i * Iso.grid_to_world(g)
	var clicked := Iso.world_to_grid(i2w * img)
	var d := clicked - g
	return {"tiles": d.length(), "px": img.distance_to(pred), "d_tiles": [snappedf(d.x, 0.001), snappedf(d.y, 0.001)],
		"clicked_grid": [snappedf(clicked.x, 0.001), snappedf(clicked.y, 0.001)]}


static func _alternatives(out: Dictionary, row: Dictionary, map: FarmMap) -> void:
	## A clicked landmark centre vs its sprite's registration point (when they differ).
	if map == null or str(row["landmark"]).is_empty() or str(row["spot"]) != "center":
		return
	var lm: Landmark = map.landmark(str(row["landmark"]))
	if lm == null:
		return
	var reg: Variant = lm.extra.get("client_registration", null)
	if not reg is Array or (reg as Array).size() != 2:
		return
	var c := Vector2(lm.origin) + Vector2(lm.footprint) * 0.5
	var r := Vector2(float(reg[0]), float(reg[1]))
	if c.distance_to(r) < 0.01:
		return
	var clicked := Vector2(float(row["clicked_grid"][0]), float(row["clicked_grid"][1]))
	var dc := clicked.distance_to(c)
	var dr := clicked.distance_to(r)
	var verdict := "undecided (difference below %.2f tile)" % (TOL_TILES * 0.5)
	if absf(dc - dr) >= TOL_TILES * 0.5:
		verdict = "registration point" if dr < dc else "footprint centre"
	out["alternatives"].append({"landmark": lm.id, "footprint_center": [c.x, c.y], "registration": [r.x, r.y],
		"tiles_to_center": snappedf(dc, 0.001), "tiles_to_registration": snappedf(dr, 0.001), "closer_to": verdict})


static func _point_name(p: Dictionary, map: FarmMap, layout: FarmLayout) -> String:
	var lid := str(p.get("landmark", ""))
	if not lid.is_empty():
		var lm: Landmark = map.landmark(lid) if map != null else null
		return "%s %s" % [lm.name if lm else lid, str(p.get("spot", ""))]
	var g := CalibrationMath.point_grid(p)
	if layout != null:
		var gi := Vector2i(roundi(g.x), roundi(g.y))
		if Vector2(gi).distance_to(g) < 0.01:
			for o: PlacedObject in layout.objects.values():
				var r := o.rect()
				for corner: Vector2i in [r.position, Vector2i(r.end.x, r.position.y), r.end, Vector2i(r.position.x, r.end.y)]:
					if corner == gi:
						return "%s corner (%d,%d)" % [o.item_id, gi.x, gi.y]
	return "tile corner (%s,%s)" % [str(snappedf(g.x, 0.01)), str(snappedf(g.y, 0.01))]


static func to_markdown(r: Dictionary) -> String:
	var L := PackedStringArray()
	L.append("# Placement check: %s" % str(r["image"].get("name", "")))
	L.append("")
	L.append("PRIVATE (made from your own screenshot). %s. Generated %s." % [str(r.get("label", "")), str(r.get("generated", ""))])
	L.append("")
	L.append(str(r.get("conclusion", "")))
	L.append("")
	if not (r.get("points", []) as Array).is_empty():
		L.append("| # | Point | Grid | Error (tiles, leave-one-out) | Error (px) | Status |")
		L.append("|---|---|---|---|---|---|")
		for p: Dictionary in r["points"]:
			L.append("| %d | %s | %s,%s | %s | %s | %s |" % [int(p["index"]) + 1, p["name"], p["grid"][0], p["grid"][1],
				str(p.get("tiles", "-")), str(p.get("px", "-")), p["status"]])
		L.append("")
	for a: Dictionary in r.get("alternatives", []):
		L.append("* %s: the clicked centre is %.2f tile from the footprint centre and %.2f tile from the client registration point -> %s." % [
			a["landmark"], a["tiles_to_center"], a["tiles_to_registration"], a["closer_to"]])
	L.append("")
	L.append("Error = distance between the clicked pixel (mapped onto the grid by a fit through the OTHER points) and the point's grid position; %.2f tile or less agrees." % TOL_TILES)
	return "\n".join(L)


static func _xf(a: Variant) -> Transform2D:
	if not a is Array or (a as Array).size() != 6:
		return Transform2D.IDENTITY
	return Transform2D(Vector2(float(a[0]), float(a[1])), Vector2(float(a[2]), float(a[3])), Vector2(float(a[4]), float(a[5])))


static func _v(p: Vector2) -> Array:
	return [snappedf(p.x, 0.1), snappedf(p.y, 0.1)]
