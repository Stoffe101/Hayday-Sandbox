class_name PlanUiKit
extends RefCounted
## Small UI building blocks shared by the Plan tabs and planning dialogs:
## tone colours and badges, progress bars, filter chips, segmented choices,
## native file dialogs that never write into the repository, and PagedList
## (a list view that reuses its row controls and shows a page at a time, so a
## shopping list of hundreds of rows refreshes in a few milliseconds).


static func tone_color(tone: String) -> Color:
	match tone:
		"danger": return UiTheme.c("danger")
		"warn": return UiTheme.c("warn")
		"info": return UiTheme.c("info")
		"accent": return UiTheme.c("accent")
		"dim": return UiTheme.c("text_dim")
	return UiTheme.c("text_faint")


static func badge(text: String, tone: String) -> PanelContainer:
	return UI.badge(text, tone_color(tone))


static func set_badge(b: PanelContainer, text: String, tone: String) -> void:
	## Re-labels / re-colours a badge made by badge() (row controls are reused);
	## does nothing when text and colour are unchanged.
	var col := tone_color(tone)
	var l := b.get_child(0) as Label
	l.text = text
	var k := col.to_html()
	if str(b.get_meta("badge_color", "")) == k:
		return
	b.set_meta("badge_color", k)
	b.add_theme_stylebox_override("panel", UiTheme.box(Color(col.r, col.g, col.b, 0.16), 999, Color.TRANSPARENT, 0, Vector4(8, 1, 8, 1)))
	l.add_theme_color_override("font_color", col)


static func flow(hsep: int = 4, vsep: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", hsep)
	f.add_theme_constant_override("v_separation", vsep)
	return f


static func wrap_label(text: String, variation: String = "") -> Label:
	## A word-wrapped label that fills the row (never clips at large UI scales).
	var l := UI.label(text, variation, true)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 40
	return l


static func progress(fraction: float, height: float = 8.0) -> ProgressBar:
	var p := ProgressBar.new()
	p.min_value = 0.0
	p.max_value = 1.0
	p.step = 0.001
	p.value = clampf(fraction, 0.0, 1.0)
	p.show_percentage = false
	p.custom_minimum_size = Vector2(40, height)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


static func chip(text: String, tooltip: String = "") -> Button:
	var b := UI.button(text, "", tooltip, "Chip")
	b.toggle_mode = true
	return b


static func segmented(options: Array, selected: String, on_pick: Callable) -> PanelContainer:
	## options: [[id, label, tooltip]]. on_pick(id). Returns the bar; buttons
	## carry their id as metadata "id".
	var bar := PanelContainer.new()
	bar.theme_type_variation = "SegmentBar"
	var h := UI.hbox(2)
	bar.add_child(h)
	var group := ButtonGroup.new()
	for o in options:
		var b := UI.button(str(o[1]), "", str(o[2]) if o.size() > 2 else "", "Segment")
		b.toggle_mode = true
		b.button_group = group
		b.set_meta("id", str(o[0]))
		b.button_pressed = str(o[0]) == selected
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var id := str(o[0])
		b.pressed.connect(func(): on_pick.call(id))
		h.add_child(b)
	return bar


static func select_segment(bar: PanelContainer, id: String) -> void:
	for b in bar.get_child(0).get_children():
		(b as Button).set_pressed_no_signal(str(b.get_meta("id", "")) == id)


static func color_dot(col: Color, size: float = 10.0) -> ColorRect:
	var c := ColorRect.new()
	c.color = col
	c.custom_minimum_size = Vector2(size, size)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# --- files (never inside the repository) -------------------------------------------------

static func documents_dir() -> String:
	var d := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	return d if not d.is_empty() else OS.get_environment("USERPROFILE")


static func repo_dir() -> String:
	return ProjectSettings.globalize_path("res://").simplify_path()


static func is_inside_repo(path: String) -> bool:
	## True for paths in the project folder (exports never go there).
	if path.begins_with("res://"):
		return true
	var root := repo_dir().replace("\\", "/").to_lower().trim_suffix("/")
	var p := path.replace("\\", "/").simplify_path().to_lower()
	if root.is_empty():
		return false
	return p == root or p.begins_with(root + "/")


static func write_text(path: String, text: String) -> String:
	## Writes a UTF-8 file; returns "" or an error text. Refuses the repository.
	if is_inside_repo(path):
		return "Choose a folder outside the program folder (e.g. Documents)."
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(text)
	f.close()
	return ""


static func read_text(path: String) -> Variant:
	## File contents, or null when it can't be read.
	if not FileAccess.file_exists(path):
		return null
	return FileAccess.get_file_as_string(path)


static func _dialog(owner: Node, mode: FileDialog.FileMode, title: String, filters: PackedStringArray, file_name: String, cb: Callable) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = mode
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = title
	fd.filters = filters
	fd.current_dir = documents_dir()
	if not file_name.is_empty():
		fd.current_file = file_name
	var done := func(p: String) -> void:
		cb.call(p)
		if is_instance_valid(fd):
			fd.queue_free()
	if mode == FileDialog.FILE_MODE_OPEN_DIR:
		fd.dir_selected.connect(done)
	else:
		fd.file_selected.connect(done)
	fd.canceled.connect(func():
		if is_instance_valid(fd):
			fd.queue_free())
	var root: Node = owner.get_tree().root if owner.is_inside_tree() else owner
	root.add_child(fd)
	fd.popup_centered_ratio(0.6)
	return fd


static func save_file(owner: Node, title: String, filters: PackedStringArray, file_name: String, cb: Callable) -> FileDialog:
	## Native "save as" starting in the user's Documents; cb(path).
	return _dialog(owner, FileDialog.FILE_MODE_SAVE_FILE, title, filters, file_name, cb)


static func open_file(owner: Node, title: String, filters: PackedStringArray, cb: Callable) -> FileDialog:
	return _dialog(owner, FileDialog.FILE_MODE_OPEN_FILE, title, filters, "", cb)


static func pick_dir(owner: Node, title: String, cb: Callable) -> FileDialog:
	return _dialog(owner, FileDialog.FILE_MODE_OPEN_DIR, title, PackedStringArray(), "", cb)


static func now_text() -> String:
	return Time.get_datetime_string_from_system(false, true)


# --- paged list with reused row controls ----------------------------------------------------

class PagedList extends VBoxContainer:
	## Shows entries[0 .. limit) with one control per entry, reusing controls
	## per kind between refreshes (no rebuild), plus "Show more". Callbacks:
	##   kind_of(entry) -> String, make(kind) -> Control, bind(control, entry, index).
	var page_size := 60
	var limit := 60
	var entries: Array = []
	var kind_of: Callable
	var make: Callable
	var bind: Callable
	var empty_text := "Nothing to show."
	var _pools: Dictionary = {}
	var _more: Button
	var _empty: Label

	func _init(page: int = 60) -> void:
		page_size = page
		limit = page
		add_theme_constant_override("separation", 4)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_empty = UI.label("", "Faint", true)
		_empty.visible = false
		add_child(_empty)
		_more = UI.button("Show more", "", "", "Ghost")
		_more.visible = false
		_more.pressed.connect(func():
			limit += page_size
			rebind())
		add_child(_more)

	func set_entries(e: Array, reset_paging: bool = false) -> void:
		entries = e
		if reset_paging:
			limit = page_size
		rebind()

	func shown_count() -> int:
		return mini(limit, entries.size())

	func widgets() -> Array:
		## The visible entry controls in order (tests / selftest).
		var out: Array = []
		for c in get_children():
			if c != _more and c != _empty and (c as Control).visible:
				out.append(c)
		return out

	func rebind() -> void:
		var shown := shown_count()
		var used := {}
		var order: Array = []
		for i in shown:
			var e: Variant = entries[i]
			var k := str(kind_of.call(e)) if kind_of.is_valid() else "row"
			if not _pools.has(k):
				_pools[k] = []
			var pool: Array = _pools[k]
			var n: int = used.get(k, 0)
			if n >= pool.size():
				var w: Control = make.call(k)
				pool.append(w)
				add_child(w)
			used[k] = n + 1
			var c: Control = pool[n]
			c.visible = true
			bind.call(c, e, i)
			order.append(c)
		for k in _pools:
			var pool: Array = _pools[k]
			for j in range(int(used.get(k, 0)), pool.size()):
				(pool[j] as Control).visible = false
		for i in order.size():
			if (order[i] as Node).get_index() != i:
				move_child(order[i], i)
		_empty.text = empty_text
		_empty.visible = entries.is_empty()
		move_child(_empty, get_child_count() - 1)
		var left := entries.size() - shown
		_more.visible = left > 0
		_more.text = "Show %d more (%d not shown)" % [mini(page_size, left), left]
		move_child(_more, get_child_count() - 1)
