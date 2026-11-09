class_name PackOverrides
extends RefCounted
## Pure helpers for an asset pack's local fine-tuning file
## `<pack_dir>/overrides.json`:
##
##   {"version": 1,
##    "sprites": {"<art_key>": {"anchor": [x, y], "pixels_per_world_px": f, "scale": f,
##                              "default_variant": "id", "verified": bool, "rejected": bool,
##                              "variants": {"<variant>": {"anchor": [x, y], "pixels_per_world_px": f, "scale": f}}}},
##    "assign":  {"<pack-relative image path>": "<item_id>"}}
##
## Overrides never modify pack.json, so a pack can be re-installed/updated
## without losing the user's review work. Applied at load time:
##   * assign   -> creates/replaces the sprite entry of that item's art key, using
##                 that image with an anchor estimated from its alpha bbox + footprint;
##   * sprites  -> per-field overrides; `rejected` removes the sprite from the pack
##                 (lower-priority packs, ultimately the placeholder, show instead).
## No scene, UI or App dependencies: unit-tested in --script mode.

const VERSION := 1
const NUM_FIELDS := ["pixels_per_world_px", "scale"]
const BOOL_FIELDS := ["verified", "rejected"]
const VARIANT_FIELDS := ["anchor", "pixels_per_world_px", "scale"]


static func empty() -> Dictionary:
	return {"version": VERSION, "sprites": {}, "assign": {}}


static func safe_rel_path(p: String) -> String:
	## Normalises a pack-relative path ("items\\a.png", "./items/a.png" ->
	## "items/a.png"). Returns "" for anything that could escape the pack folder
	## (absolute paths, drive letters, URLs, "..").
	var s := p.strip_edges().replace("\\", "/")
	if s.is_empty() or s.begins_with("/") or s.contains("://") or s.contains(":"):
		return ""
	var parts := PackedStringArray()
	for part in s.split("/", false):
		if part == ".":
			continue
		if part == "..":
			return ""
		parts.append(part)
	return "/".join(parts)


static func parse(data: Variant, errors: Array = []) -> Dictionary:
	## Validates and normalises raw JSON. Bad fields are dropped (and reported),
	## unknown fields are kept untouched so newer files survive a round trip.
	var out := empty()
	if data == null:
		return out
	if not data is Dictionary:
		errors.append("overrides: not a JSON object")
		return out
	var d: Dictionary = data
	var ver := int(d.get("version", VERSION)) if (d.get("version", VERSION) is int or d.get("version", VERSION) is float) else VERSION
	if ver > VERSION:
		errors.append("overrides: version %d is newer than this app (%d); unknown fields are kept" % [ver, VERSION])
	var sp: Variant = d.get("sprites", {})
	if sp is Dictionary:
		for k in sp:
			var key := str(k).strip_edges()
			if key.is_empty():
				continue
			if not sp[k] is Dictionary:
				errors.append("overrides: sprite '%s' is not an object" % key)
				continue
			var clean := _clean_sprite(sp[k], errors, key, true)
			if not clean.is_empty():
				out["sprites"][key] = clean
	elif sp != null:
		errors.append("overrides: 'sprites' is not an object")
	var asg: Variant = d.get("assign", {})
	if asg is Dictionary:
		for p in asg:
			var rel := safe_rel_path(str(p))
			var item := str(asg[p]).strip_edges() if asg[p] != null else ""
			if rel.is_empty():
				errors.append("overrides: unsafe image path '%s'" % str(p))
			elif item.is_empty():
				errors.append("overrides: '%s' is assigned to no item" % rel)
			else:
				out["assign"][rel] = item
	elif asg != null:
		errors.append("overrides: 'assign' is not an object")
	for k in d:
		if not k in ["version", "sprites", "assign"]:
			out[k] = d[k]
	return out


static func _clean_sprite(v: Dictionary, errors: Array, key: String, top: bool) -> Dictionary:
	var out := {}
	for f in v:
		var val: Variant = v[f]
		match str(f):
			"anchor":
				var a := _vec2(val)
				if a.is_empty():
					errors.append("overrides: %s.anchor must be [x, y]" % key)
				else:
					out["anchor"] = a
			"pixels_per_world_px", "scale":
				if (val is float or val is int) and is_finite(float(val)) and float(val) > 0.0:
					out[f] = clampf(float(val), 0.001, 1000.0)
				else:
					errors.append("overrides: %s.%s must be a positive number" % [key, f])
			"default_variant":
				if top and val is String:
					if not (val as String).is_empty():
						out["default_variant"] = val
				elif top:
					errors.append("overrides: %s.default_variant must be text" % key)
			"verified", "rejected":
				if top and (val is bool or val is int or val is float):
					if bool(val):
						out[f] = true
					elif f == "verified":
						out[f] = false   # explicit "not verified": overrides a pack-level verified (e.g. builder QA)
				elif top:
					errors.append("overrides: %s.%s must be true/false" % [key, f])
			"variants":
				if top and val is Dictionary:
					var vs := {}
					for vid in val:
						if val[vid] is Dictionary:
							var c := _clean_sprite(val[vid], errors, "%s.variants.%s" % [key, vid], false)
							if not c.is_empty():
								vs[str(vid)] = c
					if not vs.is_empty():
						out["variants"] = vs
				elif top:
					errors.append("overrides: %s.variants must be an object" % key)
			_:
				if top:
					out[f] = val
	return out


static func _vec2(val: Variant) -> Array:
	if not val is Array or (val as Array).size() != 2:
		return []
	var a: Array = val
	if not (a[0] is float or a[0] is int) or not (a[1] is float or a[1] is int):
		return []
	if not is_finite(float(a[0])) or not is_finite(float(a[1])):
		return []
	return [float(a[0]), float(a[1])]


static func set_sprite(ov: Dictionary, art_key: String, changes: Dictionary, variant: String = "", errors: Array = []) -> void:
	## Merges `changes` into ov.sprites[art_key] (or its variants[variant]).
	## A null value removes that field. Empty records are pruned.
	if not ov.get("sprites") is Dictionary:
		ov["sprites"] = {}
	var sprites: Dictionary = ov["sprites"]
	var rec: Dictionary = sprites.get(art_key, {})
	var target := rec
	if not variant.is_empty():
		var vs: Dictionary = rec.get("variants", {})
		target = vs.get(variant, {})
		vs[variant] = target
		rec["variants"] = vs
	var to_set := {}
	for k in changes:
		if changes[k] == null:
			target.erase(k)
		else:
			to_set[k] = changes[k]
	var clean := _clean_sprite(to_set, errors, art_key, variant.is_empty())
	for k in clean:
		target[k] = clean[k]
	if to_set.has("rejected") and not bool(to_set["rejected"]):
		target.erase("rejected")
	if not variant.is_empty() and target.is_empty():
		(rec["variants"] as Dictionary).erase(variant)
	if rec.get("variants") is Dictionary and (rec["variants"] as Dictionary).is_empty():
		rec.erase("variants")
	if rec.is_empty():
		sprites.erase(art_key)
	else:
		sprites[art_key] = rec


static func set_assign(ov: Dictionary, rel_path: String, item_id: String) -> bool:
	## Assigns a pack image to an item ("" removes the assignment).
	var rel := safe_rel_path(rel_path)
	if rel.is_empty():
		return false
	if not ov.get("assign") is Dictionary:
		ov["assign"] = {}
	if item_id.strip_edges().is_empty():
		(ov["assign"] as Dictionary).erase(rel)
	else:
		ov["assign"][rel] = item_id.strip_edges()
	return true


static func auto_anchor(img_size: Vector2i, used: Rect2i, footprint: Vector2i) -> Dictionary:
	## Estimates where the footprint's ground centre is in an image: the
	## footprint diamond spans the opaque width; its bottom vertex sits at the
	## lowest opaque pixel. (The diamond is symmetric about its centre, so the
	## centre is at the middle of the opaque width for any w×h.)
	if used.size.x <= 0 or used.size.y <= 0:
		used = Rect2i(Vector2i.ZERO, img_size)
	var diag := float(maxi(1, footprint.x) + maxi(1, footprint.y))
	var ppw := maxf(0.01, used.size.x / (diag * Iso.HALF_W))
	var ax := used.position.x + used.size.x * 0.5
	var ay := used.end.y - diag * Iso.HALF_H * 0.5 * ppw
	return {"anchor": [ax, ay], "pixels_per_world_px": ppw}


static func apply(raw_sprites: Dictionary, ov: Dictionary, item_info: Callable, measure: Callable) -> Dictionary:
	## Merges overrides into a pack's sprites. `raw_sprites` is never modified;
	## the result is a shallow copy where only touched entries are deep-copied
	## (cheap for packs with thousands of sprites).
	##   item_info(item_id) -> {"art_key": String, "footprint": Vector2i} or {} if unknown
	##   measure(rel_path)  -> {"size": Vector2i, "used": Rect2i} or {} if unreadable
	## Returns {"sprites", "rejected": {key: true}, "verified": {key: true},
	##          "assigned": {key: rel_path}, "errors": Array}.
	var sprites := raw_sprites.duplicate(false)
	var res := {"sprites": sprites, "rejected": {}, "verified": {}, "assigned": {}, "errors": []}
	var asg: Dictionary = ov.get("assign", {}) if ov.get("assign") is Dictionary else {}
	var paths := asg.keys()
	paths.sort()
	var thumbs := {}       # image -> thumb, so assigned images keep a known thumbnail
	if not paths.is_empty():
		for k in raw_sprites:
			var re: Variant = raw_sprites[k]
			if re is Dictionary and re.has("thumb") and re.has("file"):
				thumbs[str(re["file"])] = re["thumb"]
	for rel in paths:
		var item_id := str(asg[rel])
		var info: Dictionary = item_info.call(item_id)
		if info.is_empty():
			res["errors"].append("assign %s: unknown item '%s'" % [rel, item_id])
			continue
		var m: Dictionary = measure.call(rel)
		if m.is_empty():
			res["errors"].append("assign %s: image missing or unreadable" % rel)
			continue
		var fp: Vector2i = info.get("footprint", Vector2i.ONE)
		var aa := auto_anchor(m["size"], m["used"], fp)
		var key := str(info["art_key"])
		sprites[key] = {"file": rel, "anchor": aa["anchor"], "pixels_per_world_px": aa["pixels_per_world_px"],
			"auto_anchor": true, "assigned": true}
		if thumbs.has(rel):
			sprites[key]["thumb"] = thumbs[rel]
		res["assigned"][key] = rel
	var sov: Dictionary = ov.get("sprites", {}) if ov.get("sprites") is Dictionary else {}
	for key in sov:
		var o: Dictionary = sov[key]
		if bool(o.get("rejected", false)):
			res["rejected"][key] = true
			sprites.erase(key)
			continue
		if not sprites.get(key) is Dictionary:
			continue   # kept in the file; this pack has no such sprite (yet)
		var e: Dictionary = (sprites[key] as Dictionary).duplicate(true)
		for f in ["anchor", "pixels_per_world_px", "scale", "default_variant"]:
			if o.has(f):
				e[f] = o[f].duplicate() if o[f] is Array else o[f]
		if o.has("anchor"):
			e.erase("auto_anchor")
		if o.has("verified"):
			if bool(o["verified"]):
				e["verified"] = true
			else:
				e.erase("verified")
				e.erase("verified_by")
		if o.get("variants") is Dictionary and e.get("variants") is Dictionary:
			for vid in o["variants"]:
				if (e["variants"] as Dictionary).get(vid) is Dictionary:
					var ve: Dictionary = e["variants"][vid]
					for f in VARIANT_FIELDS:
						if (o["variants"][vid] as Dictionary).has(f):
							var val: Variant = o["variants"][vid][f]
							ve[f] = val.duplicate() if val is Array else val
		sprites[key] = e
	for key in sprites:
		if sprites[key] is Dictionary and bool((sprites[key] as Dictionary).get("verified", false)):
			res["verified"][key] = true
	return res
