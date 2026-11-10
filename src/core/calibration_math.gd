class_name CalibrationMath
extends RefCounted
## Screenshot calibration: fits the transform between the farm grid and a
## screenshot's pixels from N >= 2 point pairs, and says how well it fits.
##
## Model. Hay Day's camera is orthographic and never rotates, so a screenshot
## is the 2:1 isometric world (Iso world px) cropped, uniformly scaled and maybe
## slightly rotated: image = L * world + t with L a similarity. A screenshot that
## was resized non-uniformly (or a photo of a screen) adds stretch/shear, which
## an affine L still models exactly; real perspective is not modelled.
##   * 2 points  -> similarity (position, rotation, uniform scale), exact fit.
##   * 3+ points -> full affine, least squares in IMAGE pixels (the clicks on the
##     screenshot carry the error; grid points are snapped tile corners or
##     landmark anchors and are taken as exact).
## Accumulations use 64-bit scalars (Vector2 is 32-bit).
##
## Errors are reported per point both in screenshot pixels (clicked pixel vs the
## grid point mapped into the image) and in tiles (the clicked pixel mapped back
## onto the grid vs the grid point; Euclidean length in grid units).
##
## Quality thresholds (the constants below; the UI and AccuracyReport use them):
##   good  : RMS < 0.25 tile and max < 0.5 tile
##   fair  : RMS < 0.5 tile  and max < 1.0 tile
##   poor  : anything worse
##   unverified : the fit is exact (2 points for a similarity, 3 for an affine),
##                so the error cannot be measured: add another point.
## Isometric check (the affine part of the fit, world px -> image px): an ideal
## screenshot has aspect |L·ŷ|/|L·x̂| = 1 and skew 0. Within ISO_ASPECT_TOL and
## ISO_SKEW_TOL_DEG it is "iso" (cropped / rescaled only: expected), else
## "distorted" (stretched or sheared image, or badly placed points).
##
## Pure core class: no scene, UI or App dependencies.

const GOOD_RMS_TILES := 0.25
const GOOD_MAX_TILES := 0.5
const FAIR_RMS_TILES := 0.5
const FAIR_MAX_TILES := 1.0
const ISO_ASPECT_TOL := 0.03       ## |aspect - 1|
const ISO_SKEW_TOL_DEG := 2.0
const MAX_POINTS := 24
## Landmark anchor spots: footprint corners (Iso.footprint_polygon order) and centre.
const ANCHOR_SPOTS := ["top", "right", "bottom", "left", "center"]
const ANCHOR_SNAP_TILES := 0.3     ## grid clicks this close to a landmark anchor use it
const VERDICT_TEXT := {
	"good": "Good fit",
	"fair": "Fair fit",
	"poor": "Poor fit",
	"unverified": "Exact fit: error can't be measured",
	"invalid": "No usable fit",
}


# --- points ------------------------------------------------------------------------------

static func make_point(img: Vector2, grid: Vector2, landmark_id: String = "", spot: String = "", approximate: bool = false) -> Dictionary:
	## One calibration pair in its stored (JSON-safe) shape.
	var p := {"img": [img.x, img.y], "grid": [grid.x, grid.y]}
	if not landmark_id.is_empty():
		p["landmark"] = landmark_id
		p["spot"] = spot
		p["approximate"] = approximate
	return p


static func point_img(p: Dictionary) -> Vector2:
	return _vec(p.get("img"))


static func point_grid(p: Dictionary) -> Vector2:
	return _vec(p.get("grid"))


static func valid_point(p: Variant) -> bool:
	if not p is Dictionary:
		return false
	return _is_vec(p.get("img")) and _is_vec(p.get("grid"))


static func clean_points(points: Variant) -> Array:
	## The valid point dictionaries of a stored list (anything else is dropped).
	var out: Array = []
	if points is Array:
		for p in points:
			if valid_point(p):
				out.append(p)
	return out


static func landmark_anchor(lm: Landmark, spot: String) -> Vector2:
	## Grid position of a landmark's footprint corner ("top" = origin, "right",
	## "bottom", "left" as in Iso.footprint_polygon) or "center".
	var o := Vector2(lm.origin)
	var f := Vector2(lm.footprint)
	match spot:
		"right":
			return o + Vector2(f.x, 0.0)
		"bottom":
			return o + f
		"left":
			return o + Vector2(0.0, f.y)
		"center":
			return o + f * 0.5
		_:
			return o


static func nearest_anchor(map: FarmMap, grid: Vector2, max_dist: float = ANCHOR_SNAP_TILES) -> Dictionary:
	## The landmark anchor nearest to `grid` within max_dist tiles:
	## {"landmark", "spot", "grid": Vector2, "approximate": bool, "confidence"}, or {}.
	var best := {}
	var best_d := max_dist
	if map == null:
		return best
	for lm in map.landmarks:
		for spot: String in ANCHOR_SPOTS:
			var a := landmark_anchor(lm, spot)
			var d := a.distance_to(grid)
			if d <= best_d:
				best_d = d
				best = {"landmark": lm.id, "spot": spot, "grid": a, "approximate": lm.confidence == "approximate",
					"confidence": lm.confidence}
	return best


static func snap_grid_point(map: FarmMap, grid: Vector2) -> Dictionary:
	## Where a grid-side click lands: a nearby landmark anchor (flagged when the
	## landmark is approximate), else the nearest tile corner.
	## {"grid": Vector2, "landmark": id or "", "spot", "approximate": bool}
	var a := nearest_anchor(map, grid)
	if not a.is_empty():
		return {"grid": a["grid"], "landmark": a["landmark"], "spot": a["spot"], "approximate": a["approximate"]}
	return {"grid": Vector2(roundf(grid.x), roundf(grid.y)), "landmark": "", "spot": "", "approximate": false}


static func refresh_anchor_flags(points: Array, map: FarmMap) -> Array:
	## Copies of the points with "approximate" re-read from the current map (the
	## active world may have changed since they were taken). Unknown landmarks
	## keep their stored flag and get "missing_landmark": true.
	var out: Array = []
	for p in clean_points(points):
		var q: Dictionary = (p as Dictionary).duplicate(true)
		var lid := str(q.get("landmark", ""))
		if not lid.is_empty() and map != null:
			var lm := map.landmark(lid)
			if lm == null:
				q["missing_landmark"] = true
			else:
				q["approximate"] = lm.confidence == "approximate"
				q.erase("missing_landmark")
		out.append(q)
	return out


# --- fitting -----------------------------------------------------------------------------

static func fit(points: Array, model: String = "auto") -> Dictionary:
	## Fits the screenshot transform. model: "auto" (2 points -> similarity,
	## 3+ -> affine), "similarity" or "affine". Returns:
	##   ok, error, model, n, params, redundancy,
	##   world_to_image / image_to_world / grid_to_image: [ax, ay, bx, by, ox, oy]
	##     (Transform2D columns; image_to_world is ReferenceLayer's "affine"),
	##   residuals: [{index, tiles, px, d_tiles: [dx, dy], d_px: [dx, dy], landmark, approximate}],
	##   rms_tiles, max_tiles, rms_px, max_px, worst (index, -1 when none),
	##   iso: see iso_check(), verdict, verdict_text, approximate_points.
	var pts := clean_points(points)
	var n := pts.size()
	var out := {"ok": false, "error": "", "model": model, "n": n, "params": 0, "redundancy": 0,
		"residuals": [], "rms_tiles": 0.0, "max_tiles": 0.0, "rms_px": 0.0, "max_px": 0.0, "worst": -1,
		"iso": {}, "verdict": "invalid", "verdict_text": VERDICT_TEXT["invalid"], "approximate_points": 0}
	for p: Dictionary in pts:
		if bool(p.get("approximate", false)):
			out["approximate_points"] = int(out["approximate_points"]) + 1
	if model == "auto":
		model = "similarity" if n == 2 else "affine"
	out["model"] = model
	if not model in ["similarity", "affine"]:
		out["error"] = "unknown model '%s'" % model
		return out
	var need := 2 if model == "similarity" else 3
	if n < need:
		out["error"] = "needs at least %d points (has %d)" % [need, n]
		return out
	if n > MAX_POINTS:
		out["error"] = "at most %d points" % MAX_POINTS
		return out
	# Centred sums in 64-bit floats.
	var wx := PackedFloat64Array()
	var wy := PackedFloat64Array()
	var ix := PackedFloat64Array()
	var iy := PackedFloat64Array()
	var mwx := 0.0
	var mwy := 0.0
	var mix := 0.0
	var miy := 0.0
	for p: Dictionary in pts:
		var g := point_grid(p)
		var im := point_img(p)
		# Iso.grid_to_world, written out in doubles.
		var w_x := (float(g.x) - float(g.y)) * Iso.HALF_W
		var w_y := (float(g.x) + float(g.y)) * Iso.HALF_H
		wx.append(w_x)
		wy.append(w_y)
		ix.append(float(im.x))
		iy.append(float(im.y))
		mwx += w_x
		mwy += w_y
		mix += float(im.x)
		miy += float(im.y)
	mwx /= n
	mwy /= n
	mix /= n
	miy /= n
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var bxx := 0.0   # sum ix_c * wx_c
	var bxy := 0.0   # sum ix_c * wy_c
	var byx := 0.0   # sum iy_c * wx_c
	var byy := 0.0   # sum iy_c * wy_c
	for k in n:
		var a := wx[k] - mwx
		var b := wy[k] - mwy
		var c := ix[k] - mix
		var d := iy[k] - miy
		sxx += a * a
		sxy += a * b
		syy += b * b
		bxx += c * a
		bxy += c * b
		byx += d * a
		byy += d * b
	var spread := sxx + syy
	if spread < 1e-6:
		out["error"] = "the grid points coincide"
		return out
	var lxx := 0.0   # L = [[lxx, lxy], [lyx, lyy]]: image = L * world + t
	var lxy := 0.0
	var lyx := 0.0
	var lyy := 0.0
	if model == "similarity":
		var sa := (bxx + byy) / spread
		var sb := (byx - bxy) / spread
		lxx = sa
		lxy = -sb
		lyx = sb
		lyy = sa
		out["params"] = 4
	else:
		var det := sxx * syy - sxy * sxy
		if det <= 1e-9 * spread * spread:
			out["error"] = "the grid points are in a line"
			return out
		lxx = (syy * bxx - sxy * bxy) / det
		lxy = (sxx * bxy - sxy * bxx) / det
		lyx = (syy * byx - sxy * byy) / det
		lyy = (sxx * byy - sxy * byx) / det
		out["params"] = 6
	var ldet := lxx * lyy - lxy * lyx
	var lnorm := lxx * lxx + lxy * lxy + lyx * lyx + lyy * lyy
	if absf(ldet) < 1e-9 * maxf(lnorm, 1e-12) or lnorm < 1e-12:
		out["error"] = "the screenshot points coincide or are in a line"
		return out
	var tx := mix - (lxx * mwx + lxy * mwy)
	var ty := miy - (lyx * mwx + lyy * mwy)
	# Inverse (image -> world) in doubles.
	var ixx := lyy / ldet
	var ixy := -lxy / ldet
	var iyx := -lyx / ldet
	var iyy := lxx / ldet
	var itx := -(ixx * tx + ixy * ty)
	var ity := -(iyx * tx + iyy * ty)
	out["world_to_image"] = [lxx, lyx, lxy, lyy, tx, ty]
	out["image_to_world"] = [ixx, iyx, ixy, iyy, itx, ity]
	# grid -> image = L * G (G = grid_to_world's matrix) + t
	var gxx := lxx * Iso.HALF_W + lxy * Iso.HALF_H
	var gyx := lyx * Iso.HALF_W + lyy * Iso.HALF_H
	var gxy := -lxx * Iso.HALF_W + lxy * Iso.HALF_H
	var gyy := -lyx * Iso.HALF_W + lyy * Iso.HALF_H
	out["grid_to_image"] = [gxx, gyx, gxy, gyy, tx, ty]
	out["redundancy"] = 2 * n - int(out["params"])
	# Residuals.
	var res: Array = []
	var s_t := 0.0
	var s_p := 0.0
	var max_t := 0.0
	var max_p := 0.0
	var worst := -1
	for k in n:
		var px_pred := lxx * wx[k] + lxy * wy[k] + tx
		var py_pred := lyx * wx[k] + lyy * wy[k] + ty
		var dpx := px_pred - ix[k]
		var dpy := py_pred - iy[k]
		# clicked pixel -> world -> grid
		var w_x := ixx * ix[k] + ixy * iy[k] + itx
		var w_y := iyx * ix[k] + iyy * iy[k] + ity
		var ga := w_x / Iso.HALF_W
		var gb := w_y / Iso.HALF_H
		var g_x := (ga + gb) * 0.5
		var g_y := (gb - ga) * 0.5
		var g := point_grid(pts[k])
		var dtx := g_x - float(g.x)
		var dty := g_y - float(g.y)
		var et := sqrt(dtx * dtx + dty * dty)
		var ep := sqrt(dpx * dpx + dpy * dpy)
		s_t += et * et
		s_p += ep * ep
		if et > max_t:
			max_t = et
			worst = k
		max_p = maxf(max_p, ep)
		res.append({"index": k, "tiles": et, "px": ep, "d_tiles": [dtx, dty], "d_px": [dpx, dpy],
			"landmark": str(pts[k].get("landmark", "")), "approximate": bool(pts[k].get("approximate", false))})
	out["residuals"] = res
	out["rms_tiles"] = sqrt(s_t / n)
	out["rms_px"] = sqrt(s_p / n)
	out["max_tiles"] = max_t
	out["max_px"] = max_p
	out["worst"] = worst if int(out["redundancy"]) > 0 else -1
	out["iso"] = iso_check(Vector2(lxx, lyx), Vector2(lxy, lyy), model)
	out["verdict"] = verdict_for(float(out["rms_tiles"]), max_t, int(out["redundancy"]))
	out["verdict_text"] = VERDICT_TEXT[out["verdict"]]
	out["ok"] = true
	return out


static func verdict_for(rms_tiles: float, max_tiles: float, redundancy: int) -> String:
	## "good" | "fair" | "poor" | "unverified" (see the thresholds above).
	if redundancy <= 0:
		return "unverified"
	if rms_tiles < GOOD_RMS_TILES and max_tiles < GOOD_MAX_TILES:
		return "good"
	if rms_tiles < FAIR_RMS_TILES and max_tiles < FAIR_MAX_TILES:
		return "fair"
	return "poor"


static func iso_check(ex: Vector2, ey: Vector2, model: String = "affine") -> Dictionary:
	## Deviation of the world px -> image px map (columns ex, ey) from an ideal
	## screenshot (a similarity of the 2:1 view). Returns {scale (image px per
	## world px), rotation_deg, aspect, skew_deg, mirrored, tile_px: [w, h],
	## tile_aspect (2.0 ideal), verdict: "iso" | "distorted" | "mirrored" |
	## "assumed" (similarity model: stretch can't be seen), text}.
	var lx := float(ex.length())
	var ly := float(ey.length())
	var det := float(ex.x) * float(ey.y) - float(ex.y) * float(ey.x)
	var out := {"scale": sqrt(absf(det)), "rotation_deg": rad_to_deg(atan2(ex.y, ex.x)),
		"aspect": ly / lx if lx > 0.0 else 0.0, "skew_deg": 0.0, "mirrored": det < 0.0,
		"tile_px": [lx * Iso.TILE_W, ly * Iso.TILE_H], "tile_aspect": (lx * Iso.TILE_W) / (ly * Iso.TILE_H) if ly > 0.0 else 0.0}
	if lx > 0.0 and ly > 0.0:
		var c := clampf((float(ex.x) * float(ey.x) + float(ex.y) * float(ey.y)) / (lx * ly), -1.0, 1.0)
		out["skew_deg"] = 90.0 - rad_to_deg(acos(c))
	if model == "similarity":
		out["verdict"] = "assumed"
		out["text"] = "Two points assume an undistorted screenshot; add a third point to check for stretching."
	elif bool(out["mirrored"]):
		out["verdict"] = "mirrored"
		out["text"] = "The points describe a mirrored image: check that the points were clicked in the same order."
	elif absf(float(out["aspect"]) - 1.0) <= ISO_ASPECT_TOL and absf(float(out["skew_deg"])) <= ISO_SKEW_TOL_DEG:
		out["verdict"] = "iso"
		out["text"] = "Matches Hay Day's 2:1 view (tile %.0f×%.0f px): the screenshot is only cropped or rescaled." % [out["tile_px"][0], out["tile_px"][1]]
	else:
		out["verdict"] = "distorted"
		out["text"] = "Not a plain 2:1 view (aspect %.3f, skew %.1f°): the image may be stretched, or a point is off." % [out["aspect"], out["skew_deg"]]
	return out


# --- stored record -----------------------------------------------------------------------

static func to_record(points: Array, f: Dictionary, at: String = "") -> Dictionary:
	## The "calibration" dictionary kept on a reference image:
	## {points, fit: {model, n, redundancy, world_to_image, image_to_world,
	##  grid_to_image, rms_px, max_px, verdict, iso, residuals: [{tiles, px}]},
	##  rms_tiles, max_tiles, verdict, at}. JSON-safe.
	var res: Array = []
	for r: Dictionary in f.get("residuals", []):
		res.append({"tiles": snappedf(float(r["tiles"]), 0.0001), "px": snappedf(float(r["px"]), 0.01)})
	var iso: Dictionary = (f.get("iso", {}) as Dictionary).duplicate(true)
	# Copies: the image's "affine" is usually the same fit array, and a drag edits that in place.
	var fit_d := {"model": str(f.get("model", "")), "n": int(f.get("n", 0)), "redundancy": int(f.get("redundancy", 0)),
		"world_to_image": (f.get("world_to_image", []) as Array).duplicate(),
		"image_to_world": (f.get("image_to_world", []) as Array).duplicate(),
		"grid_to_image": (f.get("grid_to_image", []) as Array).duplicate(), "rms_px": float(f.get("rms_px", 0.0)),
		"max_px": float(f.get("max_px", 0.0)), "verdict": str(f.get("verdict", "invalid")), "iso": iso, "residuals": res}
	return {"points": clean_points(points).duplicate(true), "fit": fit_d,
		"rms_tiles": float(f.get("rms_tiles", 0.0)), "max_tiles": float(f.get("max_tiles", 0.0)),
		"verdict": str(f.get("verdict", "invalid")), "at": at}


static func record_of(image: Dictionary) -> Dictionary:
	## The image's calibration record ({} when there is none or it is malformed).
	var c: Variant = image.get("calibration")
	if not c is Dictionary or not (c as Dictionary).get("points") is Array:
		return {}
	return c


static func record_applied(image: Dictionary, eps: float = 0.01) -> bool:
	## True while the image is still placed by its calibration (not dragged,
	## rescaled or rotated by hand since): its "affine" equals fit.image_to_world.
	var rec := record_of(image)
	if rec.is_empty():
		return false
	var want: Variant = (rec.get("fit", {}) as Dictionary).get("image_to_world")
	var have: Variant = image.get("affine")
	if not want is Array or not have is Array or (want as Array).size() != 6 or (have as Array).size() != 6:
		return false
	for i in 6:
		if absf(float(want[i]) - float(have[i])) > eps * maxf(1.0, absf(float(want[i]))):
			return false
	return true


static func summary(image: Dictionary, map: FarmMap = null) -> Dictionary:
	## Calibration status of one reference image for reports and the UI:
	## {id, name, calibrated, points, rms_tiles, max_tiles, verdict, verdict_text,
	##  iso_verdict, iso_text, applied, approximate_points, missing_landmarks, text}.
	var rec := record_of(image)
	var out := {"id": str(image.get("id", "")), "name": str(image.get("name", "")), "calibrated": false,
		"points": 0, "rms_tiles": 0.0, "max_tiles": 0.0, "verdict": "none", "verdict_text": "Not calibrated",
		"iso_verdict": "", "iso_text": "", "applied": false, "approximate_points": 0, "missing_landmarks": 0,
		"text": "Not calibrated with points"}
	if rec.is_empty():
		if image.get("affine") is Array:
			out["text"] = "Aligned with the older 2/3-point tool (no stored points, error unknown)"
			out["verdict"] = "legacy"
			out["verdict_text"] = "Calibrated, error unknown"
		return out
	var pts := refresh_anchor_flags(rec.get("points", []), map)
	var fd: Dictionary = rec.get("fit", {}) if rec.get("fit") is Dictionary else {}
	var iso: Dictionary = fd.get("iso", {}) if fd.get("iso") is Dictionary else {}
	out["calibrated"] = true
	out["points"] = pts.size()
	out["rms_tiles"] = float(rec.get("rms_tiles", 0.0))
	out["max_tiles"] = float(rec.get("max_tiles", 0.0))
	out["verdict"] = str(rec.get("verdict", "invalid"))
	out["verdict_text"] = VERDICT_TEXT.get(out["verdict"], str(out["verdict"]))
	out["iso_verdict"] = str(iso.get("verdict", ""))
	out["iso_text"] = str(iso.get("text", ""))
	out["applied"] = record_applied(image)
	for p: Dictionary in pts:
		if bool(p.get("approximate", false)):
			out["approximate_points"] = int(out["approximate_points"]) + 1
		if bool(p.get("missing_landmark", false)):
			out["missing_landmarks"] = int(out["missing_landmarks"]) + 1
	var t := "%d points, %s" % [pts.size(), str(out["verdict_text"]).to_lower()]
	if out["verdict"] in ["good", "fair", "poor"]:
		t = "%d points, RMS %.2f tile, max %.2f tile (%s)" % [pts.size(), out["rms_tiles"], out["max_tiles"], out["verdict"]]
	if not bool(out["applied"]):
		t += "; moved or adjusted by hand since"
	if int(out["approximate_points"]) > 0:
		t += "; %d point(s) on approximate landmarks" % int(out["approximate_points"])
	out["text"] = t
	return out


static func live_residuals(image: Dictionary) -> Array:
	## Residuals of the stored points under the image's CURRENT placement
	## (xform from "affine", or x/y/scale/rotation): what the canvas shows.
	## [{index, world_grid: Vector2 (true grid point, world px), world_img:
	##   Vector2 (clicked pixel in world px), tiles}]
	var rec := record_of(image)
	var out: Array = []
	if rec.is_empty():
		return out
	var xf := image_xform(image)
	var pts := clean_points(rec.get("points", []))
	for k in pts.size():
		var g := point_grid(pts[k])
		var w_img := xf * point_img(pts[k])
		var wg := Iso.grid_to_world(g)
		out.append({"index": k, "world_grid": wg, "world_img": w_img,
			"tiles": Iso.world_to_grid(w_img).distance_to(g), "landmark": str(pts[k].get("landmark", "")),
			"approximate": bool(pts[k].get("approximate", false))})
	return out


static func image_xform(im: Dictionary) -> Transform2D:
	## Image px -> world px of a reference image dictionary (same rule as
	## ReferenceLayer.xform_of: "affine" wins over x/y/scale/rotation).
	if im.get("affine") is Array and (im["affine"] as Array).size() == 6:
		var a: Array = im["affine"]
		return Transform2D(Vector2(a[0], a[1]), Vector2(a[2], a[3]), Vector2(a[4], a[5]))
	var sc := float(im.get("scale", 1.0))
	return Transform2D(deg_to_rad(float(im.get("rotation", 0.0))), Vector2(sc, sc), 0.0,
		Vector2(float(im.get("x", 0.0)), float(im.get("y", 0.0))))


# --- helpers -----------------------------------------------------------------------------

static func _is_vec(v: Variant) -> bool:
	if v is Vector2 or v is Vector2i:
		return true
	if v is Array and (v as Array).size() == 2:
		return (v[0] is int or v[0] is float) and (v[1] is int or v[1] is float) and is_finite(float(v[0])) and is_finite(float(v[1]))
	return false


static func _vec(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Vector2i:
		return Vector2(v)
	if v is Array and (v as Array).size() == 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
