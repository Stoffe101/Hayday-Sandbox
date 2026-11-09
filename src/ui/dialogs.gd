class_name Dialogs
extends RefCounted
## Export, settings, help/shortcuts and welcome dialogs.

const SHORTCUTS := [
	["Tools", ""],
	["V", "Select & move"], ["B", "Place / paint (with catalogue item)"], ["E", "Erase (Shift-drag clears an area)"],
	["I / Alt+click", "Eyedropper"], ["M", "Land: lock / unlock plots"], ["N", "Notes & zones (drag for a zone)"], ["H / Space-drag / middle-drag / right-drag", "Pan"],
	["Placing", ""],
	["Click / drag", "Place / paint repeatedly"], ["Shift+drag", "Line of items"], ["Ctrl+drag", "Rectangle fill"],
	["R", "Rotate (mirror) where the game allows it"], ["P", "Toggle planned (future) placement"], ["Esc / right-click", "Stop placing"],
	["Editing", ""],
	["Click / Shift+click", "Select / add to selection"], ["Drag on empty ground", "Box select"], ["Double-click", "Select all of that item"],
	["Arrow keys", "Nudge selection (↑ NE, → SE, ↓ SW, ← NW)"], ["Delete / Backspace", "Delete selection"],
	["Ctrl+C / Ctrl+X / Ctrl+V", "Copy / cut / paste (click to stamp, Esc to stop)"], ["Ctrl+D", "Duplicate selection"],
	["Ctrl+A", "Select all"], ["Ctrl+G / Ctrl+Shift+G", "Group / ungroup"], ["L", "Lock / unlock selection"],
	["Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y", "Undo / redo"],
	["View & file", ""],
	["Mouse wheel / + / -", "Zoom"], ["F / Home", "Fit the farm"], ["G", "Grid"], ["O", "Occupied-tile overlay"], ["Tab", "Hide / show panels"],
	["Ctrl+F", "Search catalogue"], ["Ctrl+M", "Switch Creative / Realistic"], ["Ctrl+S", "Save (keeps a revision)"], ["Ctrl+O", "Layouts"],
	["Ctrl+N", "New layout"], ["Ctrl+E", "Export image"], ["Ctrl+Shift+A", "Asset manager (art, anchors, review)"], ["F1", "This help"],
]


static func help(parent: Control) -> void:
	var m := Modal.open(parent, "Keyboard shortcuts", 760, "keyboard")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(700, 520)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 6)
	for s in SHORTCUTS:
		if s[1].is_empty():
			grid.add_child(UI.section(s[0]))
			grid.add_child(Control.new())
			continue
		var k := UI.label(s[0], "Heading")
		k.add_theme_font_size_override("font_size", 14)
		k.add_theme_color_override("font_color", UiTheme.c("accent"))
		grid.add_child(k)
		grid.add_child(UI.label(s[1], "Dim"))
	scroll.add_child(grid)
	m.body.add_child(scroll)
	var about := UI.label("Hayday Sandbox %s — unofficial, offline fan tool. Not affiliated with, endorsed, sponsored or approved by Supercell. Placeholder art is original. Item facts come from community wikis (see the Farm tab sources)." % App.VERSION, "Faint", true)
	m.body.add_child(about)
	m.add_button("Close", "Accent", m.close)


static func welcome(parent: Control, on_close: Callable) -> void:
	var m := Modal.open(parent, "Welcome to Hayday Sandbox", 640, "tent-tree")
	m.blocking = true
	var steps := [
		["package-open", "Pick anything from the catalogue", "1,900+ items with footprints from community research. Search instantly, star favourites."],
		["paintbrush", "Click to place, drag to paint", "Shift-drag draws a line, Ctrl-drag fills an area. Green tiles fit; red tiles explain why not."],
		["map", "Plan your land", "Unlock expansion plots with the Land tool (M) and reserve space for future buildings."],
		["clipboard-check", "Switch to Realistic when ready", "See what your level, inventory and budget allow — without changing your design."],
	]
	for s in steps:
		var row := UI.hbox(12)
		row.add_child(UI.icon_rect(s[0], 28, UiTheme.c("accent")))
		var v := UI.vbox(2)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(UI.label(s[1], "Heading"))
		v.add_child(UI.label(s[2], "Dim", true))
		row.add_child(v)
		m.body.add_child(row)
	m.body.add_child(UI.label("Unofficial fan tool, not affiliated with Supercell. Everything stays on this computer.", "Faint", true))
	m.add_button("Show shortcuts", "", func():
		m.close()
		on_close.call()
		help(parent))
	m.add_button("Start designing", "Accent", func():
		m.close()
		on_close.call())


static func export_image(parent: Control, on_export: Callable) -> void:
	var m := Modal.open(parent, "Export image", 480, "image-down")
	var opts := {"area": "land", "scale": 1.0, "transparent": false, "grid": false, "overlay": false}
	m.body.add_child(UI.label("Area", "Dim"))
	var area := OptionButton.new()
	area.add_item("Whole farm (all land)")
	area.add_item("Unlocked land only")
	area.add_item("Just the objects")
	area.add_item("Current view")
	area.item_selected.connect(func(i): opts["area"] = ["land", "unlocked", "objects", "view"][i])
	m.body.add_child(area)
	m.body.add_child(UI.label("Resolution", "Dim"))
	var res := OptionButton.new()
	for r in [["Standard (1×)", 1.0], ["High (2×)", 2.0], ["Poster (3×)", 3.0], ["Preview (0.5×)", 0.5]]:
		res.add_item(r[0])
	res.item_selected.connect(func(i): opts["scale"] = [1.0, 2.0, 3.0, 0.5][i])
	m.body.add_child(res)
	for c in [["transparent", "Transparent background"], ["grid", "Include tile grid"], ["overlay", "Include labels, notes & selection"]]:
		var cb := CheckBox.new()
		cb.text = c[1]
		cb.toggled.connect(func(on): opts[c[0]] = on)
		m.body.add_child(cb)
	m.body.add_child(UI.label("Large exports are rendered in tiles, so even poster sizes work. PNG files are written to the folder you choose.", "Faint", true))
	m.add_button("Cancel", "", m.close)
	m.add_button("Export PNG…", "Accent", func():
		m.close()
		on_export.call(opts), "image-down")


static func settings(parent: Control, on_change: Callable) -> void:
	var m := Modal.open(parent, "Settings", 560, "settings")
	var s := App.settings
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 10)
	grid.add_child(UI.label("Theme", "Dim"))
	var th := OptionButton.new()
	th.add_item("Night barn (dark)")
	th.add_item("Morning meadow (light)")
	th.selected = 0 if s.get_v("theme") == "dark" else 1
	th.item_selected.connect(func(i):
		s.set_v("theme", "dark" if i == 0 else "light")
		on_change.call("theme"))
	grid.add_child(th)
	grid.add_child(UI.label("Interface size", "Dim"))
	var sc := OptionButton.new()
	var scales := [0.0, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
	for v in scales:
		sc.add_item("Automatic" if v == 0.0 else "%d%%" % int(v * 100))
	sc.selected = maxi(0, scales.find(float(s.get_v("ui_scale"))))
	sc.item_selected.connect(func(i):
		s.set_v("ui_scale", scales[i])
		on_change.call("ui_scale"))
	grid.add_child(sc)
	grid.add_child(UI.label("Farm geometry", "Dim"))
	var mp := OptionButton.new()
	var ids := App.maps.keys()
	ids.sort()
	for id in ids:
		mp.add_item(App.maps[id].name)
	mp.selected = maxi(0, ids.find(App.map.id))
	mp.item_selected.connect(func(i):
		s.set_v("map_id", ids[i])
		on_change.call("map_id"))
	grid.add_child(mp)
	grid.add_child(UI.label("Autosave", "Dim"))
	var au := OptionButton.new()
	var mins := [0, 1, 2, 5, 10]
	for v in mins:
		au.add_item("Off" if v == 0 else "Every %d min" % v)
	au.selected = maxi(0, mins.find(int(s.get_v("autosave_minutes"))))
	au.item_selected.connect(func(i): s.set_v("autosave_minutes", mins[i]))
	grid.add_child(au)
	grid.add_child(UI.label("Smooth zoom", "Dim"))
	var sz := CheckButton.new()
	sz.button_pressed = bool(s.get_v("smooth_zoom"))
	sz.toggled.connect(func(on):
		s.set_v("smooth_zoom", on)
		on_change.call("smooth_zoom"))
	grid.add_child(sz)
	m.body.add_child(grid)
	m.body.add_child(HSeparator.new())
	m.body.add_child(UI.section("Artwork"))
	var packs := PackedStringArray()
	for p in App.assets.pack_list():
		packs.append("%s%s (%s sprites, %s)" % [p["name"], (" v" + str(p["version"])) if not str(p["version"]).is_empty() else "",
			UI.fmt_int((p["sprites"] as Dictionary).size()), p["license"]])
	m.body.add_child(UI.label("Loaded packs: " + "; ".join(packs), "Faint", true))
	var art_row := HFlowContainer.new()
	art_row.add_theme_constant_override("h_separation", 8)
	art_row.add_theme_constant_override("v_separation", 8)
	var am := UI.button("Asset manager…", "image", "Review art, fine-tune anchors and scale, assign images (Ctrl+Shift+A)")
	am.pressed.connect(func():
		m.close()
		on_change.call("asset_manager"))
	art_row.add_child(am)
	var inst := UI.button("Install asset pack (.zip)…", "package-open", "Install a prepared asset pack (pack.json + images) into your private data folder")
	inst.pressed.connect(func():
		m.close()
		on_change.call("install_pack"))
	art_row.add_child(inst)
	var imp := UI.button("Import artwork…", "upload", "Import your own images for items (stored privately in your data folder)")
	imp.pressed.connect(func():
		m.close()
		on_change.call("import_art"))
	art_row.add_child(imp)
	var folder := UI.button("Open data folder", "folder-open")
	folder.pressed.connect(func(): OS.shell_open(ProjectSettings.globalize_path("user://")))
	art_row.add_child(folder)
	m.body.add_child(art_row)
	m.body.add_child(UI.label("Data folder: %s" % ProjectSettings.globalize_path("user://"), "Faint", true))
	m.add_button("Done", "Accent", m.close)
