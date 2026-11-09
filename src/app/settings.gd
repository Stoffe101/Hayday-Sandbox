class_name AppSettings
extends RefCounted
## Persistent user preferences (user://settings.cfg).

signal changed(key: String)

const PATH := "user://settings.cfg"
## Farm level range accepted for "default_farm_level" / layout profile.level.
const LEVEL_MIN := 1
const LEVEL_MAX := 9999
const DEFAULTS := {
	"theme": "dark",            ## dark | light
	"ui_scale": 0.0,            ## 0 = automatic from screen DPI
	"show_grid": true,
	"show_shadows": true,
	"show_labels": false,
	"show_occupancy": false,
	"show_annotations": true,
	"autosave_minutes": 2,
	"map_id": "hayday_farm",
	"favorites": [],
	"recent_items": [],
	"recent_layouts": [],
	"last_layout": "",
	"onboarding_done": false,
	"left_panel": true,
	"right_panel": true,
	"smooth_zoom": true,
	"catalog_icon_size": 76,
	"catalog_sort": "relevance",
	"show_unplaceable": false,
	## Farm level given to new layouts (profile.level). Realistic mode treats the
	## layout as "my farm at this level"; Creative mode is the full sandbox.
	"default_farm_level": 1,
}

var values: Dictionary = {}
var _path := PATH


func _init(path: String = PATH) -> void:
	_path = path
	values = DEFAULTS.duplicate(true)


func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(_path) != OK:
		return
	for k in DEFAULTS:
		if cf.has_section_key("app", k):
			var v: Variant = cf.get_value("app", k)
			if typeof(v) == typeof(DEFAULTS[k]) or (DEFAULTS[k] is float and v is int):
				values[k] = v
	values["default_farm_level"] = clampi(int(values["default_farm_level"]), LEVEL_MIN, LEVEL_MAX)


func save_settings() -> void:
	var cf := ConfigFile.new()
	for k in values:
		cf.set_value("app", k, values[k])
	var tmp := _path + ".tmp"
	if cf.save(tmp) == OK:
		if FileAccess.file_exists(_path):
			DirAccess.remove_absolute(_path)
		DirAccess.rename_absolute(tmp, _path)


func get_v(key: String) -> Variant:
	return values.get(key, DEFAULTS.get(key))


func set_v(key: String, v: Variant, persist: bool = true) -> void:
	if values.get(key) == v:
		return
	values[key] = v
	if persist:
		save_settings()
	changed.emit(key)


func toggle_favorite(item_id: String) -> bool:
	var f: Array = values["favorites"]
	var on := not item_id in f
	if on:
		f.append(item_id)
	else:
		f.erase(item_id)
	save_settings()
	changed.emit("favorites")
	return on


func push_recent(key: String, value: String, limit: int = 24) -> void:
	var r: Array = values[key]
	r.erase(value)
	r.push_front(value)
	while r.size() > limit:
		r.pop_back()
	values[key] = r
	save_settings()
	changed.emit(key)
