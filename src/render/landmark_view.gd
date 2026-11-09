class_name LandmarkView
extends RefCounted
## How the fixed landmarks of a farm world look in one design: builds the
## ObjectRenderer world entries (W2 design s8) from FarmMap.landmarks and the
## layout's world state (theme + per-landmark state / skin / visibility), and
## resolves the art variant the way the design (s3) describes:
##   base = the landmark's state;
##   the default state of a customizable landmark shows the chosen skin preset
##   ("skin_<id>") when the art has it (the Original preset only when the pack
##   ships a corrected "skin_original" render);
##   a theme other than "default" uses base + "__" + theme when that variant
##   exists, else base.
## Without landmark art (public build) the renderer falls back to the
## catalogue placeholder (`fallback_art`) or a footprint marker.
##
## Pure helpers (no App / UI); main.gd, the inspector and the self-test use them.

const KEY_PREFIX := "lm:"
const AREA_NAMES := {"farm_side": "Farm side", "road_verge": "By the road", "across_road": "Across the road",
	"river": "Riverside", "cliff": "Cliff top"}
const CONFIDENCE_NAMES := {"verified-in-data": "Verified in game data", "strong": "Strong evidence",
	"plausible": "Plausible", "approximate": "Approximate"}
const APPROXIMATE_SOURCE := "Approximate public position"


static func key_of(landmark_id: String) -> String:
	return KEY_PREFIX + landmark_id


static func id_of(key: String) -> String:
	## Landmark id of a world-entry key ("" for other keys).
	return key.substr(KEY_PREFIX.length()) if key.begins_with(KEY_PREFIX) else ""


static func state_of(lm: Landmark, layout: FarmLayout) -> String:
	## The state shown in this design (unknown saved states fall back to the default).
	var st := layout.landmark_state(lm.id, lm.default_state) if layout else lm.default_state
	if not lm.states.is_empty() and not st in lm.states:
		return lm.default_state
	return st


static func skin_of(lm: Landmark, layout: FarmLayout) -> String:
	## Chosen skin preset id ("original" = the original look).
	var sk := layout.landmark_skin(lm.id, "original") if layout else "original"
	if sk.is_empty() or not lm.has_skin(sk):
		return "original"
	return sk


static func is_visible(lm: Landmark, layout: FarmLayout) -> bool:
	return layout.is_landmark_visible(lm.id, not lm.hidden_by_default) if layout else not lm.hidden_by_default


static func _variant_set(assets: AssetLibrary, art: String) -> Dictionary:
	var out := {}
	if assets == null or art.is_empty() or not assets.has_art(art):
		return out
	for v in assets.variants_of(art):
		out[str(v)] = true
	return out


static func variant_for(lm: Landmark, layout: FarmLayout, assets: AssetLibrary) -> String:
	var vars := _variant_set(assets, lm.art)
	var state := state_of(lm, layout)
	var base := state
	if lm.is_customizable() and (lm.states.is_empty() or state == lm.default_state):
		var sv := "skin_" + skin_of(lm, layout)
		if vars.has(sv):
			base = sv
	var theme := layout.theme() if layout else FarmLayout.DEFAULT_THEME
	if theme != FarmLayout.DEFAULT_THEME and vars.has(base + "__" + theme):
		return base + "__" + theme
	return base


static func entry_for(lm: Landmark, layout: FarmLayout, assets: AssetLibrary, tint: Color = Color.WHITE) -> Dictionary:
	return {"key": key_of(lm.id), "rect": lm.rect(), "art": lm.art, "fallback_art": lm.fallback_art,
		"variant": variant_for(lm, layout, assets), "draw_anchor": lm.draw_anchor, "selectable": lm.selectable,
		"visible": is_visible(lm, layout), "flipped": lm.mirrored, "tint": tint}


static func entries_for(map: FarmMap, layout: FarmLayout, assets: AssetLibrary, tints: Dictionary = {}) -> Array:
	## One world entry per landmark of the map; `tints` = landmark id -> Color.
	var out: Array = []
	if map == null:
		return out
	for lm in map.landmarks:
		out.append(entry_for(lm, layout, assets, tints.get(lm.id, Color.WHITE)))
	return out


static func themes_with_art(map: FarmMap, assets: AssetLibrary) -> Array[String]:
	## "default" plus every theme some landmark has real art for (a
	## "<variant>__<theme>" image in the installed packs). Public build: default only.
	var found := {}
	if map != null:
		for lm in map.landmarks:
			if lm.themes.is_empty():
				continue
			var vars := _variant_set(assets, lm.art)
			for t in lm.themes:
				if found.has(t):
					continue
				for v: String in vars:
					if v.ends_with("__" + t):
						found[t] = true
						break
	var list: Array = found.keys()
	list.sort()
	var out: Array[String] = [FarmLayout.DEFAULT_THEME]
	for t in list:
		out.append(str(t))
	return out


static func theme_name(theme_id: String) -> String:
	return "Default" if theme_id == FarmLayout.DEFAULT_THEME else theme_id.replace("_", " ").capitalize()


static func skin_choices(lm: Landmark) -> Array[Dictionary]:
	## Presets offered for a customizable landmark: Original first, then the
	## pack's skins (public build: Original only).
	var out: Array[Dictionary] = [{"id": "original", "name": "Original"}]
	for s in lm.skins:
		if str(s.get("id", "")) != "original":
			out.append({"id": str(s["id"]), "name": str(s.get("name", s["id"]))})
	return out


static func state_name(state: String) -> String:
	return state.replace("_", " ").capitalize() if not state.is_empty() else "Default"


static func area_name(area: String) -> String:
	return AREA_NAMES.get(area, area.replace("_", " ").capitalize())


static func confidence_name(c: String) -> String:
	return CONFIDENCE_NAMES.get(c, c.capitalize())


static func source_label(map: FarmMap, lm: Landmark) -> String:
	## Where the landmark's position comes from, for the inspector.
	if map != null and map.is_game_data():
		return map.provenance_label()
	if lm.confidence == "approximate":
		return APPROXIMATE_SOURCE
	return map.provenance_label() if map else APPROXIMATE_SOURCE


static func home_tile_point(map: FarmMap) -> Vector2:
	## Grid point (fractional tiles) the camera's Home goes to: the farmhouse's
	## centre when the world has one, else the centre of the starting land, else
	## the centre of the placement grid.
	if map == null:
		return Vector2.ZERO
	var fh := map.landmark("farmhouse")
	if fh != null:
		return Vector2(fh.origin) + Vector2(fh.footprint) * 0.5
	for r in map.regions:
		if str(r.get("id", "")) == "start" and not (r.get("rects", []) as Array).is_empty():
			var rr: Rect2i = r["rects"][0]
			return Vector2(rr.position) + Vector2(rr.size) * 0.5
	return Vector2(map.size) * 0.5
