extends SceneTree
## Read-only QA of an installed asset pack (normally the private "hayday_original").
##
##   godot --headless --path . --script res://tools/private_assets/pack_qa.gd -- \
##     --pack-dir <installed pack folder> --out <report folder> [--pack-id hayday_original] [--max-examples N]
##   (or, simpler, through the wrapper: python3 tools/private_assets/pack_qa.py)
##
## What it does: loads the pack the way the app does (AssetLibrary + the
## catalogue with the pack's footprint corrections), resolves every sprite,
## variant (levels, stages, states, skins, seasonal themes), hand-drawn mirror,
## connection piece and thumbnail, decodes every image and measures it against
## its footprint (one tile = 64 x 32 world px):
##   * anchor = the texture pixel at the footprint's ground centre: the art's
##     solid part should be centred on it horizontally and reach about the
##     diamond's bottom corner ("bottom" 1.0) below it;
##   * scale: art width in world px against the footprint diamond's width;
##   * baked shadows: share of semi-transparent dark pixels (the pack bakes
##     shadows into the sprites; there are no separate shadow files);
##   * connection groups: which of the 16 neighbour masks each piece set has;
##   * landmarks (lm_*): art, states, skins and themes of every world landmark;
##   * missing art: placeable catalogue items that fall back to placeholders.
## Outliers are flagged against fixed sanity limits and against the item's
## category (median +- 4 MAD).
##
## Output (PRIVATE: it names files of the private pack and their measurements):
##   <out>/pack_qa.json   every measurement + the flagged list + sheet plan
##   <out>/pack_qa.md     readable summary
## The wrapper then draws contact sheets from pack_qa.json (Pillow).
##
## Read-only: nothing is written into the pack, the user's layouts or the
## settings; the output folder is refused inside a git work tree. Run it with an
## isolated user-data folder (the wrapper does) so not even the app's own
## user:// files are touched.
## Exit code: 0 report written, 1 bad input / refused output.

const MAX_SCAN := 96          ## images are downscaled to this many px for the per-pixel scan
const VERSION := 1

var _pack_id := "hayday_original"
var _max_ex := 60
var _lib: AssetLibrary
var _db: ItemDatabase
var _pack: Dictionary = {}
var _img_cache: Dictionary = {}   ## abs path -> measurement Dictionary


func _initialize() -> void:
	var a := _args(OS.get_cmdline_user_args())
	var pack_dir := str(a.get("pack-dir", ""))
	var out_dir := str(a.get("out", ""))
	_pack_id = str(a.get("pack-id", _pack_id))
	_max_ex = int(a.get("max-examples", _max_ex))
	if pack_dir.is_empty() or out_dir.is_empty():
		printerr("usage: -- --pack-dir <installed pack folder> --out <report folder> [--pack-id id]")
		quit(1)
		return
	pack_dir = pack_dir.simplify_path()
	if not FileAccess.file_exists(pack_dir.path_join("pack.json")):
		printerr("no pack.json in %s" % pack_dir)
		quit(1)
		return
	var git := _git_tree_of(out_dir)
	if not git.is_empty():
		printerr("refusing to write the private QA report inside the git work tree %s" % git)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	_db = ItemDatabase.new()
	_db.load_default()
	_lib = AssetLibrary.new()
	_lib.user_packs_dir = pack_dir.get_base_dir()
	_lib.dev_packs_dir = "res://__pack_qa_no_dev_packs__"
	_lib.load_all(_db)
	var corrections := _apply_catalog_overrides()
	_pack = _lib.pack_by_id(_pack_id)
	if _pack.is_empty() or str(_pack.get("base", "")).simplify_path() != pack_dir:
		printerr("pack %s not found in %s (loaded: %s)" % [_pack_id, pack_dir, ", ".join(_lib.packs.map(func(p: Dictionary) -> String: return str(p["id"])))])
		quit(1)
		return
	var report := _run(corrections)
	report["elapsed_s"] = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var jp := out_dir.path_join("pack_qa.json")
	JsonUtil.write_atomic(jp, JsonUtil.stringify(report, true), false)
	var mp := out_dir.path_join("pack_qa.md")
	JsonUtil.write_atomic(mp, _markdown(report), false)
	var s: Dictionary = report["summary"]
	print("PACK-QA %s %s: %d sprites, %d variants, %d mirrors, %d connection pieces, %d thumbs; load failures %d; flagged %d; missing art %d placeable items; %.1f s" % [
		_pack_id, report["pack"]["version"], s["base_sprites"], s["variants"], s["mirrors"], s["connection_pieces"], s["thumbs_ok"],
		s["load_failed"], s["flagged"], s["missing_art"], report["elapsed_s"]])
	print("PACK-QA report %s" % jp)
	quit(0)


func _args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < raw.size():
		var k := raw[i]
		if k.begins_with("--"):
			k = k.substr(2)
			if "=" in k:
				out[k.get_slice("=", 0)] = k.substr(k.find("=") + 1)
			elif i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
				out[k] = raw[i + 1]
				i += 1
			else:
				out[k] = "true"
		i += 1
	return out


static func _git_tree_of(path: String) -> String:
	## The git work tree containing `path` (or its nearest existing parent), "" if none.
	var p := ProjectSettings.globalize_path(path).simplify_path()
	while not p.is_empty():
		if DirAccess.dir_exists_absolute(p.path_join(".git")) or FileAccess.file_exists(p.path_join(".git")):
			return p
		var up := p.get_base_dir()
		if up == p:
			break
		p = up
	var res := ProjectSettings.globalize_path("res://").simplify_path()
	if ProjectSettings.globalize_path(path).simplify_path().begins_with(res):
		return res
	return ""


func _apply_catalog_overrides() -> Dictionary:
	## Same rule as App._apply_catalog_overrides: the highest-priority pack with
	## catalogue corrections wins (footprints change what "fits" means here).
	for e in _lib.world_data_files():
		var path := str(e.get("catalog_overrides", ""))
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		var errs: Array = []
		var parsed := PackOverrides.parse_catalog_overrides(JsonUtil.read_json(path), errs)
		if (parsed.get("items", {}) as Dictionary).is_empty():
			continue
		var rep := _db.apply_overrides(parsed, str(e["pack_id"]))
		return {"pack": e["pack_id"], "applied": int(rep.get("applied", 0)), "errors": errs.size()}
	return {"pack": "", "applied": 0, "errors": 0}


# --- measuring ------------------------------------------------------------------

func _measure_file(rel: String) -> Dictionary:
	## Decodes one pack image with the app's own loader and measures it:
	## {ok, w, h, used: [x, y, w, h] (alpha > 0), solid: [x0, y0, x1, y1] (alpha >= 50 %), shadow_frac}.
	var path := str(_pack["base"]).path_join(rel)
	if _img_cache.has(path):
		return _img_cache[path]
	var m := {"ok": false, "file": rel}
	if rel.is_empty() or not FileAccess.file_exists(path):
		m["error"] = "missing file"
		_img_cache[path] = m
		return m
	var img := AssetLibrary._load_image(path)
	if img == null or img.get_width() <= 0:
		m["error"] = "does not decode"
		_img_cache[path] = m
		return m
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var used := img.get_used_rect()
	m["ok"] = true
	m["w"] = w
	m["h"] = h
	m["used"] = [used.position.x, used.position.y, used.size.x, used.size.y]
	# Downscaled scan: solid bounds and baked-shadow share.
	var f := minf(1.0, float(MAX_SCAN) / maxf(w, h))
	var sw := maxi(1, roundi(w * f))
	var shh := maxi(1, roundi(h * f))
	var small := img.duplicate() as Image
	if sw != w or shh != h:
		small.resize(sw, shh, Image.INTERPOLATE_BILINEAR)
	var data := small.get_data()
	var x0 := sw
	var y0 := shh
	var x1 := -1
	var y1 := -1
	var visible := 0
	var dark_soft := 0
	var i := 0
	for y in shh:
		for x in sw:
			var al := data[i + 3]
			if al > 8:
				visible += 1
				if al >= 128:
					if x < x0: x0 = x
					if x > x1: x1 = x
					if y < y0: y0 = y
					if y > y1: y1 = y
				elif al < 230 and (data[i] + data[i + 1] + data[i + 2]) < 3 * 90:
					dark_soft += 1
			i += 4
	if x1 >= 0:
		m["solid"] = [x0 / f, y0 / f, (x1 + 1) / f, (y1 + 1) / f]
	else:
		m["solid"] = [0.0, 0.0, 0.0, 0.0]
	m["shadow_frac"] = snappedf(float(dark_soft) / maxf(1.0, visible), 0.001)
	_img_cache[path] = m
	return m


func _geom(m: Dictionary, anchor: Vector2, ppw: float, fp: Vector2i) -> Dictionary:
	## Measurements of an image against the footprint whose ground centre is `anchor`.
	var g := {}
	if not m.get("ok", false):
		return g
	var half_w := float(fp.x + fp.y) * 16.0          # diamond half width, world px
	var half_h := float(fp.x + fp.y) * 8.0           # diamond half height, world px
	var u: Array = m["used"]
	var s: Array = m["solid"]
	var solid_w := (float(s[2]) - float(s[0])) / ppw
	g["w_ratio"] = snappedf((float(u[2]) / ppw) / (2.0 * half_w), 0.01)               # whole art width / diamond width
	g["solid_w_ratio"] = snappedf(solid_w / (2.0 * half_w), 0.01)
	g["center_off"] = snappedf(((float(s[0]) + float(s[2])) * 0.5 - anchor.x) / ppw / half_w, 0.01)   # 0 = centred, +-1 = at a side corner
	g["bottom"] = snappedf((float(s[3]) - anchor.y) / ppw / half_h, 0.01)              # 1 = solid art ends at the diamond's bottom corner
	g["top_world_px"] = snappedf((anchor.y - float(s[1])) / ppw, 0.1)                  # art height above the ground centre
	g["anchor_inside"] = anchor.x >= -1.0 and anchor.y >= -1.0 and anchor.x <= float(m["w"]) + 1.0 and anchor.y <= float(m["h"]) + 1.0
	g["shadow_frac"] = m.get("shadow_frac", 0.0)
	return g


static func _anchor_of(e: Dictionary) -> Variant:
	var a: Variant = e.get("anchor", null)
	if a is Array and (a as Array).size() == 2:
		return Vector2(float(a[0]), float(a[1]))
	return null


func _ppw_of(e: Dictionary, base: Dictionary = {}) -> float:
	return float(e.get("pixels_per_world_px", base.get("pixels_per_world_px", _pack["ppw"]))) / float(e.get("scale", 1.0))


func _sprite_record(key: String, variant: String, e: Dictionary, fp: Vector2i, base: Dictionary = {}) -> Dictionary:
	var rel := str(e.get("file", ""))
	var m := _measure_file(rel)
	var ppw := _ppw_of(e, base)
	var r := {"key": key, "variant": variant, "file": rel, "ok": m.get("ok", false), "ppw": snappedf(ppw, 0.001),
		"fp": [fp.x, fp.y]}
	if not m.get("ok", false):
		r["error"] = m.get("error", "?")
		return r
	r["size"] = [m["w"], m["h"]]
	var a: Variant = _anchor_of(e)
	if a == null:
		r["error"] = "no anchor"
		r["ok"] = false
		return r
	r["anchor"] = [snappedf((a as Vector2).x, 0.01), snappedf((a as Vector2).y, 0.01)]
	r["geom"] = _geom(m, a, ppw, fp)
	return r


# --- the run --------------------------------------------------------------------

func _run(corrections: Dictionary) -> Dictionary:
	var sprites: Dictionary = _pack["sprites"]
	var pk_json: Dictionary = JsonUtil.read_json(str(_pack["path"]))
	var max_ppw := float(pk_json.get("max_pixels_per_world_px", 3.0))
	var records: Array = []          # base sprites of catalogue items
	var variants: Array = []
	var mirrors: Array = []
	var pieces: Array = []
	var thumbs := {"ok": 0, "missing": [], "bad": []}
	var missing_art := {}
	var item_of_key := {}
	var keys_used := {}
	for it: ItemDef in _db.ordered:
		var src := _lib.art_source(it.art_key)
		if src != _pack_id:
			if it.can_place():
				var cat: Array = missing_art.get(it.category, [])
				cat.append(it.id)
				missing_art[it.category] = cat
			continue
		if keys_used.has(it.art_key):
			continue        # several items sharing one art key: measure it once
		keys_used[it.art_key] = it.id
		item_of_key[it.art_key] = it
	# Base sprites, variants, mirrors, thumbnails, connection pieces of catalogue art.
	for key: String in item_of_key:
		var it: ItemDef = item_of_key[key]
		var e: Variant = sprites.get(key)
		if not e is Dictionary:
			continue
		var r := _sprite_record(key, "", e, it.footprint)
		r["item"] = it.id
		r["category"] = it.category
		r["connect_style"] = it.connect_style
		r["verified"] = bool(e.get("verified", false))
		r["auto_anchor"] = bool(e.get("auto_anchor", false))
		r["source_kind"] = str((e.get("source", {}) as Dictionary).get("kind", "")) if e.get("source") is Dictionary else ""
		records.append(r)
		_thumb_check(key, "", e, thumbs)
		if e.get("variants") is Dictionary:
			for v: String in e["variants"]:
				var ve: Dictionary = e["variants"][v]
				var res: Array = _lib._resolve(e, v, -1)
				var vr := _sprite_record(key, v, res[0], it.footprint, e)
				vr["item"] = it.id
				vr["category"] = it.category
				vr["kind"] = _variant_kind(v)
				vr["resolves"] = str(res[1]) == v
				if not vr["resolves"]:
					vr["ok"] = false
					vr["error"] = "variant does not resolve"
				# Theme copies need their base look: "lvl_2__winter" -> "lvl_2".
				if "__" in v:
					var b := v.get_slice("__", 0)
					vr["theme_base_present"] = b.is_empty() or (e["variants"] as Dictionary).has(b)
				var bd: Variant = base_delta(r, vr)
				if bd != null:
					vr["anchor_vs_base"] = bd
				variants.append(vr)
				if ve.has("thumb"):
					_thumb_check(key, v, ve, thumbs)
		if e.get("mirror") is Dictionary:
			var me: Dictionary = AssetLibrary._inherit(e, e["mirror"])
			var mr := _sprite_record(key, "mirror", me, it.size_for(true) if it.flippable else it.footprint, e)
			mr["item"] = it.id
			mr["category"] = it.category
			# The hand-drawn mirror is drawn unflipped at its own anchor; its
			# anchor should sit as far from the right edge as the base anchor
			# from the left (in world px), give or take the drawing.
			if mr["ok"] and r["ok"]:
				var bw := float(r["size"][0]) / float(r["ppw"])
				var bax := float(r["anchor"][0]) / float(r["ppw"])
				var mw := float(mr["size"][0]) / float(mr["ppw"])
				var max_ := float(mr["anchor"][0]) / float(mr["ppw"])
				mr["mirror_anchor_dx_world_px"] = snappedf((mw - max_) - bax, 0.1)
				mr["width_dx_world_px"] = snappedf(mw - bw, 0.1)
			mirrors.append(mr)
		if not it.connect_group.is_empty() and e.get("connections") is Dictionary:
			for k: String in e["connections"]:
				var ce: Dictionary = e["connections"][k]
				var pr := _sprite_record(key, "mask_%s" % k, ce, it.footprint, e)
				pr["item"] = it.id
				pr["group"] = it.connect_group
				pr["mask"] = int(k)
				pieces.append(pr)
	# Connection groups: masks per item and per group.
	var groups := {}
	for it: ItemDef in _db.ordered:
		if it.connect_group.is_empty() or not it.can_place():
			continue
		var g: Dictionary = groups.get(it.connect_group, {"items": [], "complete": 0, "partial": [], "no_pieces": [], "placeholder": []})
		g["items"].append(it.id)
		if _lib.art_source(it.art_key) != _pack_id:
			g["placeholder"].append(it.id)
		else:
			var masks := _lib.connection_masks(it.art_key)
			if masks.is_empty():
				g["no_pieces"].append(it.id)
			elif masks.size() >= 16:
				g["complete"] += 1
			else:
				var miss: Array = []
				for m in 16:
					if not masks.has(m):
						miss.append(m)
				g["partial"].append({"item": it.id, "missing_masks": miss})
		groups[it.connect_group] = g
	# Pieces whose anchor line differs from the other pieces of the same item
	# that reach the same down-facing sides (SE / SW: they decide where the
	# solid art ends; a lone post ends near the ground centre by design).
	var by_item := {}
	for pr: Dictionary in pieces:
		if pr["ok"]:
			# Paths and tiles with diagonal corner pieces (masks 3, 6, 9, 12 cover
			# half a tile on purpose) are compared only with their own kind.
			var mk := int(pr["mask"])
			var corner := mk in [3, 6, 9, 12] and _db.get_item(pr["item"]) != null and _db.get_item(pr["item"]).connect_style != "fence"
			var bk := "%s|%d%s" % [pr["item"], mk & (Connections.SE | Connections.SW), "|corner%d" % mk if corner else ""]
			var arr: Array = by_item.get(bk, [])
			arr.append(pr)
			by_item[bk] = arr
	var piece_outliers: Array = []
	for iid: String in by_item:
		var arr: Array = by_item[iid]
		var bots: Array = arr.map(func(p: Dictionary) -> float: return float(p["geom"]["bottom"]))
		var med := _median(bots)
		for p: Dictionary in arr:
			if arr.size() >= 3 and absf(float(p["geom"]["bottom"]) - med) > 0.75:
				p["flags"] = ["piece bottom %.2f vs %.2f for the item's pieces with the same down-facing sides" % [p["geom"]["bottom"], med]]
				piece_outliers.append(p)
	# Landmarks.
	var landmarks := _landmarks(sprites)
	# Flags: fixed sanity limits, then outliers within the category.
	var flagged: Array = []
	for r: Dictionary in records + variants + mirrors + landmarks["records"]:
		var fl: Array = r.get("flags", [])
		if not r["ok"]:
			fl.append("load: %s" % r.get("error", "?"))
		else:
			var g: Dictionary = r["geom"]
			if not g["anchor_inside"]:
				fl.append("anchor outside the image")
			if absf(g["center_off"]) > 0.5:
				fl.append("art not centred on the anchor (%.2f of the half width)" % g["center_off"])
			if g["bottom"] < -0.25:
				fl.append("solid art ends above the ground centre (bottom %.2f)" % g["bottom"])
			elif g["bottom"] > 3.0:
				fl.append("art hangs far below the footprint (bottom %.2f)" % g["bottom"])
			if g["w_ratio"] < 0.3 and str(r.get("connect_style", "")) != "fence" and not r.has("group"):
				fl.append("undersize: %.2f x the footprint width" % g["w_ratio"])
			elif g["w_ratio"] > 2.6:
				fl.append("oversize: %.2f x the footprint width" % g["w_ratio"])
			var ppw := float(r["ppw"])
			if ppw < 0.5 or ppw > max_ppw + 0.001:
				fl.append("pixels_per_world_px %.3f outside [0.5, %.2f]" % [ppw, max_ppw])
			if r.has("theme_base_present") and not r["theme_base_present"]:
				fl.append("theme copy without its base look")
		r["flags"] = fl
	_category_outliers(records)
	for r: Dictionary in records + variants + mirrors + landmarks["records"] + piece_outliers:
		if not (r.get("flags", []) as Array).is_empty():
			flagged.append(r)
	# Baked shadows per category: share of sprites that carry one.
	var shadow := {}
	for r: Dictionary in records:
		if not r["ok"]:
			continue
		var c: Dictionary = shadow.get(r["category"], {"sprites": 0, "with_shadow": 0, "without": []})
		c["sprites"] += 1
		if float(r["geom"]["shadow_frac"]) >= 0.02:
			c["with_shadow"] += 1
		else:
			c["without"].append(r["item"])
		shadow[r["category"]] = c
	for k in shadow:
		var c: Dictionary = shadow[k]
		c["share"] = snappedf(float(c["with_shadow"]) / maxf(1.0, c["sprites"]), 0.01)
		# Only list the exceptions when most of the category has a shadow.
		c["without"] = (c["without"] as Array).slice(0, _max_ex) if c["share"] >= 0.6 else []
	var load_failed := 0
	for r: Dictionary in records + variants + mirrors + pieces + landmarks["records"]:
		if not r["ok"]:
			load_failed += 1
	var n_missing := 0
	for k in missing_art:
		n_missing += (missing_art[k] as Array).size()
	var by_cat := {}
	for r: Dictionary in records:
		var c: Dictionary = by_cat.get(r["category"], {"sprites": 0, "flagged": 0, "verified": 0})
		c["sprites"] += 1
		if r["verified"]:
			c["verified"] += 1
		if not (r["flags"] as Array).is_empty():
			c["flagged"] += 1
		by_cat[r["category"]] = c
	var stats := {}
	for f in ["w_ratio", "center_off", "bottom", "shadow_frac"]:
		var vals: Array = []
		for r: Dictionary in records:
			if r["ok"]:
				vals.append(float(r["geom"][f]))
		stats[f] = _dist(vals)
	return {
		"format": "hayday-sandbox-pack-qa", "version": VERSION, "PRIVATE": true,
		"generated": Time.get_datetime_string_from_system(true),
		"pack": {"id": _pack_id, "version": _pack.get("version", ""), "base": _pack["base"], "ppw": _pack["ppw"], "max_ppw": max_ppw,
			"client_build": str((pk_json.get("provenance", {}) as Dictionary).get("client_build", "")),
			"sprites_declared": sprites.size()},
		"catalog_overrides": corrections,
		"summary": {"catalogue_items": _db.count(), "items_with_pack_art": keys_used.size(), "base_sprites": records.size(),
			"variants": variants.size(), "mirrors": mirrors.size(), "connection_pieces": pieces.size(),
			"connection_groups": groups.size(), "thumbs_ok": thumbs["ok"], "thumbs_missing": (thumbs["missing"] as Array).size(),
			"thumbs_bad": (thumbs["bad"] as Array).size(), "load_failed": load_failed, "flagged": flagged.size(),
			"missing_art": n_missing, "landmarks": landmarks["landmarks"].size(), "lib_errors": _lib.errors.size()},
		"distributions": stats,
		"by_category": by_cat,
		"variant_kinds": _count_by(variants, "kind"),
		"connection_groups": groups,
		"shadows": shadow,
		"thumbs": {"ok": thumbs["ok"], "missing": (thumbs["missing"] as Array).slice(0, _max_ex), "bad": (thumbs["bad"] as Array).slice(0, _max_ex)},
		"missing_art": missing_art,
		"landmarks": landmarks["landmarks"],
		"flagged": flagged,
		"lib_errors": Array(_lib.errors).slice(0, _max_ex),
		"sheets": _sheet_plan(records, variants, mirrors, pieces, landmarks["records"], flagged),
	}


static func base_delta(base: Dictionary, v: Dictionary) -> Variant:
	## How far a variant's solid art bottom moves against its base look (only when notable).
	if not base.get("ok", false) or not v.get("ok", false):
		return null
	var d := float(v["geom"]["bottom"]) - float(base["geom"]["bottom"])
	var c := float(v["geom"]["center_off"]) - float(base["geom"]["center_off"])
	if absf(d) > 0.6 or absf(c) > 0.35:
		return {"bottom": snappedf(d, 0.01), "center": snappedf(c, 0.01)}
	return null


static func _variant_kind(v: String) -> String:
	var b := v.get_slice("__", 0)
	if "__" in v and b.is_empty():
		return "theme"
	if b.begins_with("lvl_") or b.begins_with("level_"):
		return "level" + (" + theme" if "__" in v else "")
	if b.begins_with("stage_") or b == "dead":
		return "stage"
	if b.begins_with("skin_"):
		return "skin" + (" + theme" if "__" in v else "")
	if b in ["broken", "repaired", "locked", "default", "customizable"]:
		return "state" + (" + theme" if "__" in v else "")
	if "mastered" in b or b.begins_with("look_"):
		return "look"
	return "other" + (" + theme" if "__" in v else "")


func _thumb_check(key: String, variant: String, e: Dictionary, thumbs: Dictionary) -> void:
	var rel := str(e.get("thumb", ""))
	var tag := key if variant.is_empty() else "%s:%s" % [key, variant]
	if rel.is_empty():
		thumbs["missing"].append(tag)
		return
	var path := str(_pack["base"]).path_join(rel)
	var img := AssetLibrary._load_image(path) if FileAccess.file_exists(path) else null
	if img == null or img.get_width() <= 0 or maxi(img.get_width(), img.get_height()) > 512:
		thumbs["bad"].append(tag)
	else:
		thumbs["ok"] += 1


func _landmarks(sprites: Dictionary) -> Dictionary:
	## Every world landmark: art present, base + states + skins + themes load, geometry.
	var out := {"landmarks": [], "records": []}
	var wpath := ""
	for e in _lib.world_data_files():
		if str(e["pack_id"]) == _pack_id:
			wpath = str(e.get("world", ""))
	if wpath.is_empty() or not FileAccess.file_exists(wpath):
		return out
	var world: Variant = JsonUtil.read_json(wpath)
	if not world is Dictionary:
		return out
	for lm: Dictionary in world.get("landmarks", []):
		var key := str(lm.get("art", ""))
		var fp := Vector2i(int(lm["footprint"][0]), int(lm["footprint"][1])) if lm.get("footprint") is Array else Vector2i.ONE
		var row := {"id": lm.get("id", ""), "art": key, "footprint": [fp.x, fp.y], "draw_anchor": lm.get("draw_anchor", "top_corner"),
			"confidence": lm.get("confidence", ""), "art_present": sprites.has(key)}
		if sprites.get(key) is Dictionary:
			var e: Dictionary = sprites[key]
			var r := _sprite_record(key, "", e, fp)
			r["landmark"] = lm["id"]
			r["category"] = "landmark"
			r["draw_anchor"] = row["draw_anchor"]
			out["records"].append(r)
			row["base_ok"] = r["ok"]
			row["geom"] = r.get("geom", {})
			var vars: Dictionary = e.get("variants", {}) if e.get("variants") is Dictionary else {}
			var miss_states: Array = []
			for st in lm.get("states", []):
				if not vars.has(str(st)) and str(st) != str(lm.get("default_state", "")):
					miss_states.append(st)
			var miss_skins: Array = []
			for sk: Dictionary in lm.get("skins", []):
				if not vars.has("skin_%s" % sk.get("id", "")):
					miss_skins.append(sk.get("id", ""))
			var bad: Array = []
			for v: String in vars:
				var vr := _sprite_record(key, v, _lib._resolve(e, v, -1)[0], fp, e)
				if not vr["ok"]:
					bad.append(v)
			row["variants"] = vars.size()
			row["variants_failed"] = bad
			row["states_without_art"] = miss_states
			row["skins_without_art"] = miss_skins
			if not bad.is_empty() or not miss_states.is_empty():
				r["flags"] = ["landmark variants: %d fail to load, states without art %s" % [bad.size(), str(miss_states)]]
		out["landmarks"].append(row)
	return out


func _category_outliers(records: Array) -> void:
	## Median +- 4 MAD within the category (at least 8 sprites) for width and anchor line.
	var by := {}
	for r: Dictionary in records:
		if r["ok"]:
			# Fence posts (a lone piece) and paths are compared with their own kind.
			var k := str(r["category"]) + ("/" + str(r["connect_style"]) if not str(r.get("connect_style", "")).is_empty() else "")
			var a: Array = by.get(k, [])
			a.append(r)
			by[k] = a
	for cat: String in by:
		var arr: Array = by[cat]
		if arr.size() < 8:
			continue
		for f in ["w_ratio", "bottom"]:
			var vals: Array = arr.map(func(r: Dictionary) -> float: return float(r["geom"][f]))
			var med := _median(vals)
			var mad := _median(vals.map(func(x: float) -> float: return absf(x - med)))
			var lim := maxf(4.0 * mad * 1.4826, 0.35 if f == "bottom" else 0.25 * med)
			for r: Dictionary in arr:
				var x := float(r["geom"][f])
				if absf(x - med) > lim:
					var fl: Array = r.get("flags", [])
					fl.append("%s %.2f is an outlier in %s (median %.2f)" % [f, x, cat, med])
					r["flags"] = fl


static func _median(vals: Array) -> float:
	if vals.is_empty():
		return 0.0
	var s := vals.duplicate()
	s.sort()
	var n := s.size()
	return float(s[n / 2]) if n % 2 == 1 else (float(s[n / 2 - 1]) + float(s[n / 2])) * 0.5


static func _dist(vals: Array) -> Dictionary:
	if vals.is_empty():
		return {}
	var s := vals.duplicate()
	s.sort()
	var q := func(p: float) -> float: return snappedf(float(s[clampi(int(round(p * (s.size() - 1))), 0, s.size() - 1)]), 0.01)
	return {"n": s.size(), "p01": q.call(0.01), "p05": q.call(0.05), "p50": q.call(0.5), "p95": q.call(0.95), "p99": q.call(0.99)}


static func _count_by(arr: Array, f: String) -> Dictionary:
	var out := {}
	for r: Dictionary in arr:
		var k := str(r.get(f, ""))
		out[k] = int(out.get(k, 0)) + 1
	return out


func _sheet_plan(records: Array, variants: Array, mirrors: Array, pieces: Array, lms: Array, flagged: Array) -> Dictionary:
	## What the wrapper draws: absolute image paths with anchor, scale and footprint.
	var base := str(_pack["base"])
	var cell := func(r: Dictionary, label: String) -> Dictionary:
		return {"path": base.path_join(str(r["file"])), "anchor": r.get("anchor", [0, 0]), "ppw": r["ppw"], "fp": r["fp"],
			"label": label, "flags": r.get("flags", []), "ok": r["ok"]}
	var plan := {"flagged": [], "landmarks": [], "connections": [], "mirrors": [], "categories": {}}
	for r: Dictionary in flagged:
		if r["ok"]:
			plan["flagged"].append(cell.call(r, _label(r)))
	for r: Dictionary in lms:
		if r["ok"]:
			plan["landmarks"].append(cell.call(r, "%s (%s)" % [r["landmark"], r.get("draw_anchor", "")]))
	var seen := {}
	for p: Dictionary in pieces:
		if p["ok"]:
			var arr: Array = seen.get(p["item"], [])
			if arr.size() < 16:
				arr.append(cell.call(p, "%s m%02d" % [p["item"], p["mask"]]))
			seen[p["item"]] = arr
	# One row per connection group (its first item with pieces), masks in order;
	# the groups with a flagged piece first, then a sample of the others.
	var groups_done := {}
	var flagged_items := {}
	for r: Dictionary in flagged:
		if r.has("group"):
			flagged_items[r["item"]] = true
	var order: Array = seen.keys().filter(func(k: String) -> bool: return flagged_items.has(k))
	order.append_array(seen.keys().filter(func(k: String) -> bool: return not flagged_items.has(k)).slice(0, 12))
	for iid: String in order:
		var it := _db.get_item(iid)
		if it == null or groups_done.has(it.connect_group):
			continue
		groups_done[it.connect_group] = true
		var row: Array = seen[iid]
		row.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["label"]).naturalnocasecmp_to(str(b["label"])) < 0)
		plan["connections"].append({"group": it.connect_group, "item": iid, "cells": row})
	var base_of := {}
	for r: Dictionary in records:
		base_of[r["item"]] = r
	for m: Dictionary in mirrors:
		var b: Dictionary = base_of.get(m["item"], {})
		if m["ok"] and b.get("ok", false):
			# The base look as the app flips it, next to the client's own mirror drawing.
			var bc: Dictionary = cell.call(b, "%s (flipped by the app)" % m["item"])
			bc["flip"] = true
			bc["fp"] = m["fp"]
			plan["mirrors"].append([bc, cell.call(m, "%s mirror art" % m["item"])])
	# A sample of every category (up to 24, the verified ones first).
	var by := {}
	for r: Dictionary in records:
		if r["ok"]:
			var a: Array = by.get(r["category"], [])
			a.append(r)
			by[r["category"]] = a
	for cat: String in by:
		var arr: Array = by[cat]
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["verified"] and not b["verified"])
		plan["categories"][cat] = arr.slice(0, 24).map(func(r: Dictionary) -> Dictionary: return cell.call(r, _label(r)))
	return plan


static func _label(r: Dictionary) -> String:
	var id := str(r.get("item", r.get("landmark", r.get("key", ""))))
	return id if str(r.get("variant", "")).is_empty() else "%s:%s" % [id, r["variant"]]


# --- markdown -------------------------------------------------------------------

func _markdown(r: Dictionary) -> String:
	var s: Dictionary = r["summary"]
	var L := PackedStringArray()
	L.append("# Pack QA: %s %s" % [r["pack"]["id"], r["pack"]["version"]])
	L.append("")
	L.append("PRIVATE report (names and measurements of private pack files). Generated %s by tools/private_assets/pack_qa.gd; read-only run." % r["generated"])
	L.append("")
	L.append("| What | Count |")
	L.append("|---|---|")
	for k in ["catalogue_items", "items_with_pack_art", "base_sprites", "variants", "mirrors", "connection_pieces", "connection_groups",
			"thumbs_ok", "thumbs_missing", "thumbs_bad", "load_failed", "flagged", "missing_art", "landmarks", "lib_errors"]:
		L.append("| %s | %s |" % [k.replace("_", " "), str(s[k])])
	L.append("")
	L.append("Catalogue corrections applied: %s (pack %s)." % [r["catalog_overrides"]["applied"], r["catalog_overrides"]["pack"]])
	L.append("")
	L.append("## Geometry distributions (base sprites)")
	L.append("")
	L.append("`w_ratio` = art width / footprint diamond width; `center_off` = solid-art centre minus anchor in half diamond widths; `bottom` = solid-art bottom below the anchor in half diamond heights (1 = the diamond's bottom corner); `shadow_frac` = share of semi-transparent dark pixels.")
	L.append("")
	L.append("| Metric | n | p01 | p05 | p50 | p95 | p99 |")
	L.append("|---|---|---|---|---|---|---|")
	for k in r["distributions"]:
		var d: Dictionary = r["distributions"][k]
		if not d.is_empty():
			L.append("| %s | %d | %s | %s | %s | %s | %s |" % [k, d["n"], d["p01"], d["p05"], d["p50"], d["p95"], d["p99"]])
	L.append("")
	L.append("## Variant kinds")
	L.append("")
	for k in r["variant_kinds"]:
		L.append("* %s: %d" % [k, r["variant_kinds"][k]])
	L.append("")
	L.append("## Connection groups")
	L.append("")
	var gk: Array = r["connection_groups"].keys()
	gk.sort()
	var n_items := 0
	var n_complete := 0
	var odd: PackedStringArray = PackedStringArray()
	for g in gk:
		var d: Dictionary = r["connection_groups"][g]
		n_items += d["items"].size()
		n_complete += int(d["complete"])
		if int(d["complete"]) != d["items"].size():
			odd.append("| %s | %d | %d | %s | %s | %s |" % [g, d["items"].size(), d["complete"], str(d["partial"]), ", ".join(PackedStringArray(d["no_pieces"])), ", ".join(PackedStringArray(d["placeholder"]))])
	L.append("%d groups, %d placeable items; %d items have all 16 neighbour masks." % [gk.size(), n_items, n_complete])
	L.append("")
	if not odd.is_empty():
		L.append("| Group | Items | Complete (16 masks) | Partial (missing masks) | No pieces | Placeholder art |")
		L.append("|---|---|---|---|---|---|")
		L.append_array(odd)
	L.append("")
	L.append("## Baked shadows by category")
	L.append("")
	L.append("| Category | Sprites | With a baked shadow | Share | Exceptions (when most have one) |")
	L.append("|---|---|---|---|---|")
	var sk: Array = r["shadows"].keys()
	sk.sort()
	for k in sk:
		var d: Dictionary = r["shadows"][k]
		L.append("| %s | %d | %d | %s | %s |" % [k, d["sprites"], d["with_shadow"], d["share"], ", ".join(PackedStringArray((d["without"] as Array).slice(0, 12)))])
	L.append("")
	L.append("## Landmarks")
	L.append("")
	L.append("| Landmark | Art | Footprint | Draw anchor | Variants | Failed | States without art | w_ratio | center_off | bottom |")
	L.append("|---|---|---|---|---|---|---|---|---|---|")
	for lm: Dictionary in r["landmarks"]:
		var g: Dictionary = lm.get("geom", {})
		L.append("| %s | %s | %dx%d | %s | %s | %s | %s | %s | %s | %s |" % [lm["id"], "yes" if lm["art_present"] else "**missing**", lm["footprint"][0], lm["footprint"][1],
			lm["draw_anchor"], lm.get("variants", "-"), (lm.get("variants_failed", []) as Array).size(), str(lm.get("states_without_art", [])),
			g.get("w_ratio", "-"), g.get("center_off", "-"), g.get("bottom", "-")])
	L.append("")
	L.append("## Missing art (placeable items drawn with placeholders)")
	L.append("")
	var mk: Array = r["missing_art"].keys()
	mk.sort()
	for k in mk:
		var arr: Array = r["missing_art"][k]
		L.append("* **%s** (%d): %s%s" % [k, arr.size(), ", ".join(PackedStringArray(arr.slice(0, 40))), " …" if arr.size() > 40 else ""])
	L.append("")
	L.append("## Flagged (%d)" % r["flagged"].size())
	L.append("")
	for f: Dictionary in (r["flagged"] as Array).slice(0, 300):
		L.append("* `%s` %s" % [_label(f), "; ".join(PackedStringArray(f.get("flags", [])))])
	if r["flagged"].size() > 300:
		L.append("* … %d more in pack_qa.json" % (r["flagged"].size() - 300))
	L.append("")
	return "\n".join(L)
