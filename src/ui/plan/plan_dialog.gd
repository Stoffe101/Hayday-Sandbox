class_name PlanDialog
extends VBoxContainer
## Base of the planning dialogs (inventory, prices, baseline). The content is
## shown by whoever handles PlanContext.request_dialog(content, title) (the
## Plan panel puts it in a Modal). Contract with the host:
##   * the dialog emits `close_requested` when it is done (Apply / Cancel /
##     Close); the host closes its modal, which frees the dialog;
##   * `closed` is emitted once when the dialog is freed (however it closed).
## Without a listener on close_requested the dialog closes the Modal it sits
## in (or frees itself).

signal close_requested
signal closed

var ctx: PlanContext
var footer: HBoxContainer
## Wanted width; clamped to the window when shown.
var preferred_width := 600.0
var _closed := false


func _init() -> void:
	add_theme_constant_override("separation", 10)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	var vs := get_viewport_rect().size
	custom_minimum_size.x = clampf(vs.x - 96.0, 280.0, preferred_width)
	_fit(vs)


func _fit(_viewport: Vector2) -> void:
	## Subclasses size their scrolling parts here.
	pass


func list_height(fraction: float = 0.45, lo: float = 140.0, hi: float = 460.0) -> float:
	var vs := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	return clampf(vs.y * fraction, lo, hi)


func present(c: PlanContext, title_text: String) -> bool:
	## Asks the host to show this dialog. False (and the dialog is freed) when
	## nothing can show dialogs.
	ctx = c
	if c == null or c.request_dialog.get_connections().is_empty():
		if c != null:
			c.toast("Dialogs are not available here", "error")
		free()
		return false
	c.request_dialog.emit(self, title_text)
	return true


func make_footer() -> HBoxContainer:
	footer = UI.hbox(8)
	footer.alignment = BoxContainer.ALIGNMENT_END
	add_child(footer)
	return footer


func add_footer_button(text: String, variation: String, cb: Callable, icon_name: String = "") -> Button:
	if footer == null:
		make_footer()
	var b := UI.button(text, icon_name, "", variation)
	b.custom_minimum_size.x = 96
	b.pressed.connect(cb)
	footer.add_child(b)
	return b


func request_close() -> void:
	if not close_requested.get_connections().is_empty():
		close_requested.emit()
		return
	var n := get_parent()
	while n != null:
		if n is Modal:
			(n as Modal).close()
			return
		n = n.get_parent()
	queue_free()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _closed:
		_closed = true
		closed.emit()
