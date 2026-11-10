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
	"left_panel": true,         ## catalogue expanded (false = collapsed to its category rail)
	"right_panel": true,        ## inspector shown (when it doesn't auto-hide)
	"catalog_width": 0.0,       ## remembered panel widths in logical px (0 = automatic)
	"inspector_width": 0.0,
	"inspector_auto_hide": true, ## the inspector only appears when something needs it
	"smooth_zoom": true,
	"wheel_zoom_factor": 1.15,  ## zoom per mouse-wheel notch
	"drag_snap_valid": false,   ## dragged objects jump to the nearest free spot
	"catalog_icon_size": 76,
	"catalog_sort": "relevance",
	"show_unplaceable": false,
	## Farm level given to new layouts (profile.level). Realistic mode treats the
	## layout as "my farm at this level"; Creative mode is the full sandbox.
	"default_farm_level": 1,
	## "off" | "reduced" | "full", or "auto" = from the OS reduce-motion preference.
	"ambient_animation": "auto",
	## Planning (docs/PLANNING.md): budget widget on the canvas and the Plan panel.
	"budget_visible": true,
	"budget_corner": "bl",      ## bl | br | tl | tr
	"budget_collapsed": false,  ## one line only
	"budget_expanded": false,   ## breakdown card open
	"budget_mode": "to_buy",    ## design | to_buy | remaining
	"budget_scope": "auto",     ## auto (selection → area → phase → farm) | farm
	"plan_tab": "budget",       ## last Plan panel tab
	"plan_width": 0.0,          ## Plan panel width in logical px (0 = automatic)
	"plan_show_areas": true,    ## planning layers on the canvas
	"plan_show_progress": true,
	"plan_show_heatmap": false,
	"plan_show_guide": true,
}
## Stored values of "ambient_animation", in the order the settings dialog lists them.
const AMBIENT_CHOICES := ["off", "reduced", "full"]

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


static func os_reduce_motion() -> int:
	## The OS "reduce motion" preference: 1 on, 0 off, -1 unknown.
	if DisplayServer.has_method("accessibility_should_reduce_animation"):
		return int(DisplayServer.call("accessibility_should_reduce_animation"))
	return -1


static func ambient_default(reduce_motion: int) -> String:
	return "reduced" if reduce_motion == 1 else "full"


func ambient_animation() -> String:
	## The effective choice: "off" | "reduced" | "full".
	var v := str(get_v("ambient_animation"))
	return v if v in AMBIENT_CHOICES else ambient_default(os_reduce_motion())


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
