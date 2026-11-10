class_name PlanTab
extends VBoxContainer
## Base of every Plan panel tab. Subclasses build their widgets in _build(),
## fill them in refresh() (called when the tab is visible and the context
## changed; never per frame) and act only through `ctx`.

var ctx: PlanContext
var tab_id := ""
var title := ""
var icon := ""
var _dirty := true


func setup(context: PlanContext) -> void:
	ctx = context
	add_theme_constant_override("separation", 8)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	ctx.changed.connect(_on_changed)
	ctx.session_changed.connect(_on_changed)
	visibility_changed.connect(func():
		if is_visible_in_tree() and _dirty:
			_do_refresh())
	_on_changed()


func _on_changed() -> void:
	_dirty = true
	if is_visible_in_tree():
		_do_refresh()


func _do_refresh() -> void:
	_dirty = false
	if ctx != null and ctx.session != null:
		refresh()


func _build() -> void:
	pass


func refresh() -> void:
	pass
