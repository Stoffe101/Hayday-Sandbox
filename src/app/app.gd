extends Node
## Application service locator (autoload "App").
## Owns the long-lived services and the currently open document; UI and
## editor code talk to these instead of to each other.

signal session_changed            ## a different layout is now open
signal notify(text: String, kind: String)
signal saved
signal assets_reloaded
signal map_changed

const VERSION := "0.1.0"

var settings: AppSettings
var db: ItemDatabase
var maps: Dictionary = {}         ## id -> FarmMap
var map: FarmMap
var assets: AssetLibrary
var library: LayoutLibrary
var session: EditorSession
var boot_ms := 0.0
var _autosave_timer: Timer
var headless_safe := false


func _ready() -> void:
	var t0 := Time.get_ticks_usec()
	settings = AppSettings.new()
	settings.load_settings()
	db = ItemDatabase.new()
	db.load_default()
	_load_maps()
	assets = AssetLibrary.new()
	assets.load_all()
	library = LayoutLibrary.new(db)
	boot_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = 15.0
	_autosave_timer.timeout.connect(_on_autosave_tick)
	add_child(_autosave_timer)
	_autosave_timer.start()
	if not db.errors.is_empty():
		push_warning("Item data problems: %s" % "; ".join(db.errors.slice(0, 5)))


func _load_maps() -> void:
	maps.clear()
	var dir := DirAccess.open("res://data/maps")
	if dir:
		for f in dir.get_files():
			if f.ends_with(".json"):
				var m := FarmMap.load_file("res://data/maps".path_join(f))
				maps[m.id] = m
	if maps.is_empty():
		var fb := FarmMap.make_simple(48, 32)
		maps[fb.id] = fb
	map = maps.get(str(settings.get_v("map_id")), maps.get("hayday_farm", maps.values()[0]))


func map_for(id: String) -> FarmMap:
	return maps.get(id, map)


func reload_assets() -> void:
	assets.load_all()
	assets_reloaded.emit()


# --- documents ---------------------------------------------------------------

func open_layout(l: FarmLayout, report: LayoutIO.LoadReport = null) -> void:
	if maps.has(l.map_id):
		map = maps[l.map_id]
	else:
		l.map_id = map.id
	session = EditorSession.new(l, db, map)
	session.load_report = report
	if not l.id.is_empty():
		settings.set_v("last_layout", l.id)
		settings.push_recent("recent_layouts", l.id, 12)
	session_changed.emit()
	if report and not report.summary().is_empty():
		toast("Opened “%s”: %s" % [l.name, report.summary()], "warn")


func new_layout(name: String = "New farm", template: String = "starter") -> FarmLayout:
	var l := FarmLayout.new()
	l.id = LayoutLibrary.new_id()
	l.name = name
	l.map_id = map.id
	l.created = Time.get_datetime_string_from_system(true) + "Z"
	l.touch()
	match template:
		"expanded":
			l.set_unlocked(map.all_plot_ids(), false)
			_add_starter_buildings(l)
		"empty":
			pass
		_:
			_add_starter_buildings(l)
	return l


func _add_starter_buildings(l: FarmLayout) -> void:
	## Core buildings every farm has. Their real positions vary/are unverified,
	## so they start LOCKED at approximate spots: unlock and move them to match
	## your farm (a screenshot reference helps).
	var land := Rect2i()
	for r in map.regions:
		if r["id"] == "start":
			land = r["rects"][0]
	if land.size == Vector2i.ZERO:
		land = map.land_bounds()
	var o := land.position
	var plan := [
		["farmhouse", Vector2i(14, 12)], ["barn", Vector2i(4, 4)], ["silo", Vector2i(9, 4)],
		["truck_and_order_board", Vector2i(13, land.size.y - 4)], ["roadside_shop", Vector2i(19, land.size.y - 4)],
		["mailbox", Vector2i(18, 12)],
	]
	var objs: Array = []
	for p in plan:
		var it := db.get_item(p[0])
		if it == null:
			continue
		var po := PlacedObject.new()
		po.item_id = it.id
		po.origin = o + (p[1] as Vector2i)
		po.size = it.size_for(false)
		po.locked = true
		po.note = "Approximate starting position — unlock (L) and move to match your farm."
		if PlacementRules.check_rect(l, map, po.rect()).ok:
			objs.append(po)
	l.add_objects(objs, false)


func save_current(snapshot: bool = true) -> Error:
	if session == null:
		return ERR_UNAVAILABLE
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


func toast(text: String, kind: String = "info") -> void:
	notify.emit(text, kind)
	if kind == "error":
		push_warning(text)
