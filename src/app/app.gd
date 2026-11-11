extends Node
## Application service locator (autoload "App").
## Owns the long-lived services and the currently open document; UI and
## editor code talk to these instead of to each other.

signal session_changed            ## a different layout is now open
signal notify(text: String, kind: String)
signal saved
signal assets_reloaded
signal art_changed(art_keys: Array)   ## overrides edited (anchor/scale/verified/rejected/assign)
## The farm world (FarmMap) was replaced: a private world pack was installed /
## removed / updated, or the world corrections file changed. App.map and
## App.session.map already point at the new map when this fires; the open
## layout itself is untouched.
signal map_changed

const VERSION := "0.1.0"

var settings: AppSettings
var db: ItemDatabase
var maps: Dictionary = {}         ## id -> FarmMap (public map, or the private world that replaces it)
var map: FarmMap                  ## world of the open layout / new layouts; see map.provenance
var assets: AssetLibrary
var library: LayoutLibrary
var session: EditorSession
## Resolved item prices (catalogue < data/prices < private client supplement < user://price_overrides.json).
var prices: PriceBook
## The one planning context of the app: Plan panel tabs, planning dialogs and the
## budget widget read it; rebound to every new session (docs/PLANNING.md §5).
var plan_ctx: PlanContext
var boot_ms := 0.0
var _autosave_timer: Timer
var headless_safe := false


func _ready() -> void:
	var t0 := Time.get_ticks_usec()
	settings = AppSettings.new()
	settings.load_settings()
	db = ItemDatabase.new()
	db.load_default()
	assets = AssetLibrary.new()
	assets.load_all(db)
	_apply_catalog_overrides()
	_load_maps()
	library = LayoutLibrary.new(db)
	library.map = map
	prices = PriceBook.load_default(db)
	for w in prices.errors:
		push_warning(w)
	plan_ctx = PlanContext.new()
	prices.changed.connect(plan_ctx.notify_changed)
	boot_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = 15.0
	_autosave_timer.timeout.connect(_on_autosave_tick)
	add_child(_autosave_timer)
	_autosave_timer.start()
	if not db.errors.is_empty():
		push_warning("Item data problems: %s" % "; ".join(db.errors.slice(0, 5)))


func _load_maps() -> void:
	## Every public map in res://data/maps, each possibly replaced by a private
	## pack's world (WorldLoader: highest-priority valid pack world with the
	## same id wins; broken ones are skipped with a warning) and patched by the
	## user's corrections in user://world_overrides/<map id>.json.
	maps.clear()
	var cands: Array = []
	for e in assets.world_data_files():
		if not str(e.get("world", "")).is_empty():
			cands.append(e)
	var dir := DirAccess.open("res://data/maps")
	if dir:
		var files := Array(dir.get_files())
		files.sort()
		for f: String in files:
			if not f.ends_with(".json"):
				continue
			var m := WorldLoader.load("res://data/maps".path_join(f), cands, WorldLoader.USER_OVERRIDES_DIR)
			if m.id.is_empty() or maps.has(m.id):
				continue
			maps[m.id] = m
			for w in m.warnings:
				if str(w).begins_with("Private world data") or str(w).begins_with("World corrections"):
					push_warning(w)
	if maps.is_empty():
		var fb := FarmMap.make_simple(48, 32)
		maps[fb.id] = fb
	var want := WorldLoader.canonical_map_id(str(settings.get_v("map_id")))
	map = maps.get(want, maps.get(WorldLoader.DEFAULT_MAP_ID, maps.values()[0]))


func _apply_catalog_overrides() -> bool:
	## Applies the catalogue corrections (footprints / unlock levels from the
	## user's game files) of the highest-priority installed pack that declares
	## "catalog_overrides" in its pack.json, or restores the public values when
	## there is none (pack disabled/removed). Returns true when the catalogue changed.
	var before := "%s|%s" % [db.overrides_pack, str(db.overrides_report.get("hash", ""))]
	var applied := false
	for e in assets.world_data_files():
		var path := str(e.get("catalog_overrides", ""))
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		var errs: Array = []
		var parsed := PackOverrides.parse_catalog_overrides(JsonUtil.read_json(path), errs)
		for x in errs:
			push_warning("Pack %s: %s" % [e.get("pack_id", "?"), x])
		if (parsed.get("items", {}) as Dictionary).is_empty() and not (parsed.get("additions") is Dictionary and not (parsed["additions"] as Dictionary).is_empty()):
			continue
		var rep := db.apply_overrides(parsed, str(e["pack_id"]))
		for x in rep.get("invalid", []):
			if str(x).begins_with("addition"):
				push_warning("Pack %s: %s" % [e.get("pack_id", "?"), x])
		if int(rep.get("applied", 0)) <= 0 and (rep.get("added", []) as Array).is_empty():
			continue
		db.overrides_report["pack_version"] = str(e.get("version", ""))
		applied = true
		break
	if not applied and not db.overrides_pack.is_empty():
		db.revert_overrides()
	var after := "%s|%s" % [db.overrides_pack, str(db.overrides_report.get("hash", ""))]
	return before != after


func _world_signature() -> String:
	var parts := PackedStringArray()
	var ids := maps.keys()
	ids.sort()
	for id in ids:
		var m: FarmMap = maps[id]
		var p := m.provenance
		var mt := FileAccess.get_modified_time(m.source_path) if not m.source_path.is_empty() and FileAccess.file_exists(m.source_path) else 0
		parts.append("%s|%s|%s|%s|%d|%s" % [id, m.source_path, str(p.get("active", "")), str(p.get("pack_version", "")), mt, str(p.get("user_overrides", {}))])
	return "\n".join(parts)


func map_for(id: String) -> FarmMap:
	return maps.get(WorldLoader.canonical_map_id(id), map)


func world_label() -> String:
	## "Public approximation" / "Game data (private pack 2026.11.xx)" (+ corrections).
	return map.provenance_label() if map else ""


func reload_assets() -> void:
	## Re-scans the asset packs. Pack world data and catalogue corrections are
	## re-applied too: the world is reloaded (map_changed when it differs) and
	## an open layout gets corrected footprints as one undoable step.
	assets.load_all(db)
	var catalogue_changed := _apply_catalog_overrides()
	var old_maps := maps.duplicate()
	var old_map := map
	var old_sig := _world_signature()
	_load_maps()
	var world_changed := _world_signature() != old_sig
	if not world_changed:
		maps = old_maps
		map = old_map
	library.map = map
	if catalogue_changed and prices != null:
		prices.set_catalogue(db)   # catalogue cost fields are the lowest price layer
	if session:
		if world_changed:
			map = map_for(session.layout.map_id)
			library.map = map
			session.set_map(map)
			_bind_plan()
		if catalogue_changed:
			session.refresh_catalogue_rules()   # landmark copies / water decorations may differ now
			_reconcile_open_layout()
	assets_reloaded.emit()
	if world_changed:
		toast("Farm world: %s" % world_label(), "info")
		map_changed.emit()


func _reconcile_open_layout() -> void:
	## Catalogue footprints changed while a layout is open: apply them the same
	## way loading does (keep origins; axis-only change on a flippable item
	## toggles `flipped`), as one undoable command.
	var l := session.layout
	var uids: Array = []
	var vals: Array = []
	var keys := l.objects.keys()
	keys.sort()
	for u in keys:
		var o: PlacedObject = l.objects[u]
		var it := db.get_item(o.item_id)
		if it == null:
			continue
		var probe := o.duplicate_obj()
		if LayoutIO.reconcile_footprint(probe, it).is_empty():
			continue
		uids.append(o.uid)
		vals.append({"size": probe.size, "flipped": probe.flipped})
	l.footprint_source = LayoutIO.footprint_source_of(db)
	if uids.is_empty():
		return
	session.execute(EditCommands.SetGeometry.new(uids, vals, "Apply corrected footprints"))
	toast("%d object%s adjusted to the %s footprints (Ctrl+Z undoes it)" % [uids.size(), "" if uids.size() == 1 else "s",
		"game-data" if not db.overrides_pack.is_empty() else "public catalogue"], "info")


func notify_art_changed(art_keys: Array) -> void:
	## Cheap refresh after an override edit: only these art keys are redrawn.
	art_changed.emit(art_keys)


func install_pack(zip_path: String) -> PackInstaller.Result:
	## Installs an asset pack .zip into user://asset_packs/<id>/ and reloads art.
	var r := PackInstaller.install_zip(zip_path)
	if r.ok:
		reload_assets()
	return r


# --- documents ---------------------------------------------------------------

func open_layout(l: FarmLayout, report: LayoutIO.LoadReport = null) -> void:
	var mid := WorldLoader.canonical_map_id(l.map_id)
	if maps.has(mid):
		map = maps[mid]
		l.map_id = mid
	else:
		l.map_id = map.id
	library.map = map
	if session != null:
		session.dispose()
	session = EditorSession.new(l, db, map, prices)
	session.load_report = report
	_connect_plan(session)
	_bind_plan()
	if not l.id.is_empty():
		settings.set_v("last_layout", l.id)
		settings.push_recent("recent_layouts", l.id, 12)
	session_changed.emit()
	if report and not report.summary().is_empty():
		toast("Opened “%s”: %s" % [l.name, report.summary()], "warn")


func _connect_plan(s: EditorSession) -> void:
	## Once per session: everything that changes a budget, the plan or the scope
	## reaches the planning context (coalesced to one `changed` per frame). The
	## session's own emitters hold these, so they go away with the session.
	if plan_ctx == null:
		return
	if s.budget != null:
		s.budget.changed.connect(plan_ctx.notify_changed)
	s.layout.planning_changed.connect(plan_ctx.notify_changed)
	s.selection_changed.connect(plan_ctx.notify_changed)
	s.history_changed.connect(plan_ctx.notify_changed)


func _bind_plan() -> void:
	if plan_ctx != null and session != null:
		plan_ctx.bind(session, session.budget, prices, db, session.map)


func layout_templates() -> Array[Dictionary]:
	## Templates for new layouts. "new_farm" is offered only when the active
	## world carries the game's initial objects (private world data).
	var out: Array[Dictionary] = [
		{"id": "starter", "name": "Starter farm", "description": "Barn and silo near their usual spots. The farmhouse, truck, shop and mailbox are fixed parts of the farm."},
	]
	if has_initial_objects():
		out.append({"id": "new_farm", "name": "Brand-new game farm", "description": "Everything a fresh farm starts with in the game (from your private world data)."})
	out.append({"id": "expanded", "name": "Fully expanded", "description": "All mapped land unlocked, with barn and silo."})
	out.append({"id": "empty", "name": "Empty", "description": "Just the land and the fixed landmarks."})
	return out


func has_initial_objects() -> bool:
	for io in map.initial_objects:
		if str(io.get("group", "start")) == "start":
			return true
	return false


func default_farm_level() -> int:
	return clampi(int(settings.get_v("default_farm_level")), AppSettings.LEVEL_MIN, AppSettings.LEVEL_MAX)


func new_layout(name: String = "New farm", template: String = "starter") -> FarmLayout:
	## Templates: "starter" (barn + silo, movable), "new_farm" (the game's fresh
	## farm objects; falls back to "starter" without world data), "expanded"
	## (all land + barn + silo), "empty". Fixed landmarks are never placed as
	## objects: the world layer draws them.
	var l := FarmLayout.new()
	l.id = LayoutLibrary.new_id()
	l.name = name
	l.map_id = map.id
	l.created = Time.get_datetime_string_from_system(true) + "Z"
	l.profile["level"] = default_farm_level()
	l.footprint_source = LayoutIO.footprint_source_of(db)
	# Landmark copies (also items a world landmark replaces) never become objects.
	l.fixed_items = EditorSession.fixed_item_ids(db, map)
	l.touch()
	match template:
		"expanded":
			l.set_unlocked(map.all_plot_ids(), false)
			_add_starter_buildings(l)
		"empty":
			pass
		"new_farm":
			if not _add_initial_objects(l):
				_add_starter_buildings(l)
		_:
			_add_starter_buildings(l)
	return l


## Approximate public positions of the movable starter buildings, relative to
## the starting land (app-made approximation carried over from v1).
const STARTER_BUILDINGS := {"barn": Vector2i(4, 4), "silo": Vector2i(9, 4)}


func _add_starter_buildings(l: FarmLayout) -> void:
	## Barn and silo: movable, NOT locked. With private world data they start
	## where the game puts them (map.initial_objects); otherwise at approximate
	## spots on the starting land (moved to the nearest free spot if needed).
	var land := Rect2i()
	for r in map.regions:
		if r["id"] == "start" and not (r["rects"] as Array).is_empty():
			land = r["rects"][0]
	if land.size == Vector2i.ZERO:
		land = map.land_bounds()
	var game := {}
	for io in map.initial_objects:
		var iid := db.resolve_id(str(io.get("item", "")))
		if STARTER_BUILDINGS.has(iid) and not game.has(iid):
			game[iid] = io
	for id: String in STARTER_BUILDINGS:
		var it := db.get_item(id)
		if it == null or not it.can_place():
			continue
		var po := PlacedObject.new()
		po.item_id = it.id
		if game.has(id):
			po.origin = game[id]["origin"]
			po.flipped = bool(game[id].get("flip", false)) and it.flippable
		else:
			po.origin = land.position + (STARTER_BUILDINGS[id] as Vector2i)
		po.size = it.size_for(po.flipped)
		var at := _free_spot(l, po.rect(), land)
		if at.x == -99999:
			continue
		po.origin = at
		l.add_objects([po], false)


func _free_spot(l: FarmLayout, r: Rect2i, within: Rect2i) -> Vector2i:
	## `r.position` when free, else the nearest free origin (ring search inside
	## `within`), else (-99999, -99999).
	if PlacementRules.check_rect(l, map, r).ok:
		return r.position
	for d in range(1, 12):
		for dy in range(-d, d + 1):
			for dx in range(-d, d + 1):
				if absi(dx) != d and absi(dy) != d:
					continue
				var o := r.position + Vector2i(dx, dy)
				var c := Rect2i(o, r.size)
				if within.size != Vector2i.ZERO and not within.encloses(c):
					continue
				if PlacementRules.check_rect(l, map, c).ok:
					return o
	return Vector2i(-99999, -99999)


func _add_initial_objects(l: FarmLayout) -> bool:
	## The game's fresh-farm objects of the starting land (map.initial_objects,
	## group "start"). Unknown / unplaceable items and blocked spots are skipped
	## and reported. Returns false when the world has no initial objects.
	var placed := 0
	var skipped := 0
	var any := false
	for io in map.initial_objects:
		if str(io.get("group", "start")) != "start":
			continue
		any = true
		var it := db.get_item(str(io.get("item", "")))
		if it != null and l.fixed_items.has(it.id):
			continue   # a fixed landmark: the world layer draws it
		if it == null or not it.can_place():
			skipped += 1
			continue
		var po := PlacedObject.new()
		po.item_id = it.id
		po.origin = io["origin"]
		po.flipped = bool(io.get("flip", false)) and it.flippable
		po.size = it.size_for(po.flipped)
		if not PlacementRules.check_rect(l, map, po.rect()).ok:
			skipped += 1
			continue
		l.add_objects([po], false)
		placed += 1
	if skipped > 0:
		toast("Fresh farm: %d object(s) placed, %d skipped (unknown items or blocked spots)" % [placed, skipped], "warn")
	return any


func save_current(snapshot: bool = true) -> Error:
	if session == null:
		return ERR_UNAVAILABLE
	session.layout.footprint_source = LayoutIO.footprint_source_of(db)
	var err := library.save(session.layout, snapshot)
	if err == OK:
		session.stack.mark_saved()
		settings.set_v("last_layout", session.layout.id)
		saved.emit()
	else:
		toast("Could not save: %s" % error_string(err), "error")
	return err


func _on_autosave_tick() -> void:
	if session == null or not session.stack.is_dirty():
		return
	var minutes := float(settings.get_v("autosave_minutes"))
	if minutes <= 0:
		return
	var age_ms := Time.get_ticks_msec() - _last_autosave_ms
	if age_ms < minutes * 60000.0:
		return
	_last_autosave_ms = Time.get_ticks_msec()
	library.autosave(session.layout)


var _last_autosave_ms := 0


func reload_client_prices() -> void:
	## Re-reads the private client-price supplement (after an import, rollback or removal).
	if FileAccess.file_exists(PriceBook.DEFAULT_CLIENT):
		prices.load_client(PriceBook.DEFAULT_CLIENT)
	else:
		prices.clear_client()


func client_build() -> String:
	## The game version of the installed art pack / private world ("" = none).
	for p in assets.pack_list():
		var prov: Variant = p.get("provenance")
		if prov is Dictionary and not str(prov.get("client_build", "")).is_empty():
			return str(prov["client_build"])
	return ""


func toast(text: String, kind: String = "info") -> void:
	notify.emit(text, kind)
	if kind == "error":
		push_warning(text)
