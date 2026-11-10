class_name ClientLevel
extends RefCounted
## Pure reader for the game client's multi-section level CSV (level_0.csv) and
## for its plain data tables (expansions.csv, cars.csv, decorations.csv, ...).
## It only understands the file layout; no game data is embedded here, and the
## files themselves stay private (they are the user's own client data and are
## never copied into the repository).
##
## Level file layout: a row whose first column is non-empty starts a section.
##   TileMap         labels row (col 1..), types row, then one row per Y; column
##                   1 + X holds the raw cell (blank = 0). raw = expansion_id * 100
##                   + ground type for expansion land, else the ground type.
##   SpecialObjects, Sounds, WaterDecoZones, ...   header row (col 1..), types
##                   row, then data rows (col 1..).
##   Objects, Objects1..N   nested: a row with col 1 = object name starts a block,
##                   then a header (X, Y, Mirrored) and a types row in col 2..,
##                   then one data row per instance in col 2...
##
## Data tables: row 0 = header, row 1 = types, then data rows. A row with an
## empty Name continues the row above (levels, extra costs); read_table()
## groups them under the named row as "_extra".
##
##   parse_csv(text) -> Array[Array[String]]
##   parse_level(text) -> {ok, errors, sections, tilemap: {width, height, labels, raw},
##       special_objects: [{name, x, y, mirrored, x_offset, y_offset}], objects: {group: [{name, x, y, mirrored}]},
##       tables: {section: {header, rows}}}
##   read_table(text) -> {header, types, rows: [{...columns, _index, _line, _extra: [...]}], by_name: {Name: index}}
##   tile_size(row) -> Vector2i (TileWidth x TileHeight, ZERO when the row has none)

const SECTION_TILEMAP := "TileMap"
const SECTION_SPECIAL := "SpecialObjects"
const OBJECT_PREFIX := "Objects"
## Raw cell values of expansion land are expansion_id * EXPANSION_FACTOR + ground type.
const EXPANSION_FACTOR := 100


# --- CSV --------------------------------------------------------------------------------

static func parse_csv(text: String) -> Array:
	## RFC 4180-ish reader: quoted fields, doubled quotes and line breaks inside
	## quotes. Lines without quotes take a fast path (split on commas).
	var out: Array = []
	var lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var n := lines.size()
	# A trailing newline gives one empty last line: drop it.
	if n > 0 and lines[n - 1].is_empty():
		n -= 1
	var i := 0
	while i < n:
		var line: String = lines[i]
		i += 1
		if line.find("\"") < 0:
			out.append(Array(line.split(",", true)))
			continue
		# Join physical lines until the quotes balance.
		while line.count("\"") % 2 == 1 and i < n:
			line += "\n" + lines[i]
			i += 1
		out.append(_parse_quoted_line(line))
	return out


static func _parse_quoted_line(line: String) -> Array:
	var row: Array = []
	var field := ""
	var quoted := false
	var k := 0
	var L := line.length()
	while k < L:
		var ch := line[k]
		if quoted:
			if ch == "\"":
				if k + 1 < L and line[k + 1] == "\"":
					field += "\""
					k += 1
				else:
					quoted = false
			else:
				field += ch
		elif ch == "\"":
			quoted = true
		elif ch == ",":
			row.append(field)
			field = ""
		else:
			field += ch
		k += 1
	row.append(field)
	return row


static func _cell(row: Array, i: int) -> String:
	return str(row[i]).strip_edges() if i < row.size() else ""


static func _int(s: String, fallback: int = 0) -> int:
	var t := s.strip_edges()
	if t.is_valid_int():
		return int(t)
	if t.is_valid_float():
		return int(float(t))
	return fallback


static func _bool(s: String) -> bool:
	return s.strip_edges().to_lower() in ["true", "1", "yes"]


# --- level file ---------------------------------------------------------------------------

static func parse_level(text: String) -> Dictionary:
	var out := {"ok": false, "errors": [], "sections": [],
		"tilemap": {"width": 0, "height": 0, "labels": [], "raw": PackedInt32Array()},
		"special_objects": [], "objects": {}, "tables": {}}
	var rows := parse_csv(text)
	var starts: Array = []
	for i in rows.size():
		var r: Array = rows[i]
		if not r.is_empty() and not _cell(r, 0).is_empty():
			starts.append([_cell(r, 0), i])
	if starts.is_empty():
		out["errors"].append("no sections found (column 0 is empty everywhere)")
		return out
	for si in starts.size():
		var sname: String = starts[si][0]
		var start: int = starts[si][1]
		var end_row: int = starts[si + 1][1] if si + 1 < starts.size() else rows.size()
		out["sections"].append(sname)
		var body := rows.slice(start + 1, end_row)
		if sname == SECTION_TILEMAP:
			out["tilemap"] = _parse_tilemap(body, out["errors"])
		elif sname.begins_with(OBJECT_PREFIX):
			out["objects"][sname] = _parse_objects(body)
		else:
			var tbl := _parse_flat(body)
			out["tables"][sname] = tbl
			if sname == SECTION_SPECIAL:
				out["special_objects"] = _special_objects(tbl)
	if int(out["tilemap"]["width"]) <= 0:
		out["errors"].append("no TileMap section")
	out["ok"] = (out["errors"] as Array).is_empty()
	return out


static func _parse_tilemap(body: Array, errors: Array) -> Dictionary:
	var tm := {"width": 0, "height": 0, "labels": [], "raw": PackedInt32Array()}
	if body.size() < 2:
		errors.append("TileMap: missing label/type rows")
		return tm
	var labels: Array = (body[0] as Array).slice(1)
	var w := labels.size()
	while w > 0 and str(labels[w - 1]).strip_edges().is_empty():
		w -= 1
	labels = labels.slice(0, w)
	var data := body.slice(2)
	# Trailing fully empty rows are not map rows.
	var h := data.size()
	while h > 0 and _row_blank(data[h - 1]):
		h -= 1
	var raw := PackedInt32Array()
	raw.resize(w * h)
	raw.fill(0)
	var bad := 0
	for y in h:
		var r: Array = data[y]
		for x in w:
			var s := _cell(r, x + 1)
			if s.is_empty():
				continue
			if not s.is_valid_int():
				bad += 1
				continue
			raw[y * w + x] = int(s)
	if bad > 0:
		errors.append("TileMap: %d non-integer cell(s) read as 0" % bad)
	tm["width"] = w
	tm["height"] = h
	tm["labels"] = labels
	tm["raw"] = raw
	return tm


static func _row_blank(r: Array) -> bool:
	for c in r:
		if not str(c).strip_edges().is_empty():
			return false
	return true


static func _parse_flat(body: Array) -> Dictionary:
	## Header in col 1.., types row, then data rows in col 1...
	var tbl := {"header": [], "rows": []}
	if body.is_empty():
		return tbl
	var hdr: Array = (body[0] as Array).slice(1)
	var n := hdr.size()
	while n > 0 and str(hdr[n - 1]).strip_edges().is_empty():
		n -= 1
	hdr = hdr.slice(0, n)
	tbl["header"] = hdr
	for r: Array in body.slice(2):
		var rec := {}
		var empty := true
		for i in n:
			var v := _cell(r, i + 1)
			rec[str(hdr[i])] = v
			if not v.is_empty():
				empty = false
		if not empty:
			(tbl["rows"] as Array).append(rec)
	return tbl


static func _special_objects(tbl: Dictionary) -> Array:
	var out: Array = []
	for r: Dictionary in tbl["rows"]:
		var name := str(r.get("Name", ""))
		if name.is_empty():
			continue
		out.append({"name": name, "x": _int(str(r.get("X", ""))), "y": _int(str(r.get("Y", ""))),
			"mirrored": _bool(str(r.get("Mirrored", ""))), "x_offset": _int(str(r.get("Xoffset", ""))),
			"y_offset": _int(str(r.get("YoffSet", r.get("Yoffset", ""))))})
	return out


static func _parse_objects(body: Array) -> Array:
	var out: Array = []
	var cur := ""
	for r: Array in body:
		var c1 := _cell(r, 1)
		if not c1.is_empty():
			cur = c1
			continue
		var c2 := _cell(r, 2)
		if c2.is_empty() or c2 == "X" or c2.to_lower() == "int" or cur.is_empty():
			continue
		out.append({"name": cur, "x": _int(c2), "y": _int(_cell(r, 3)), "mirrored": _bool(_cell(r, 4))})
	return out


# --- level queries ------------------------------------------------------------------------

static func raw_at(level: Dictionary, x: int, y: int) -> int:
	## Raw TileMap cell, -1 outside the map.
	var tm: Dictionary = level.get("tilemap", {})
	var w := int(tm.get("width", 0))
	var h := int(tm.get("height", 0))
	if x < 0 or y < 0 or x >= w or y >= h:
		return -1
	return (tm["raw"] as PackedInt32Array)[y * w + x]


static func ground_of(raw: int) -> int:
	return raw % EXPANSION_FACTOR


static func expansion_of(raw: int) -> int:
	return raw / EXPANSION_FACTOR


static func expansion_ids(level: Dictionary) -> Dictionary:
	## {expansion id: tile count} over the whole TileMap.
	var out := {}
	var raw: PackedInt32Array = level.get("tilemap", {}).get("raw", PackedInt32Array())
	for v in raw:
		if v >= EXPANSION_FACTOR:
			var e := v / EXPANSION_FACTOR
			out[e] = int(out.get(e, 0)) + 1
	return out


static func all_objects(level: Dictionary) -> Array:
	## Every Objects* instance with its group: [{group, name, x, y, mirrored}].
	var out: Array = []
	var groups: Array = (level.get("objects", {}) as Dictionary).keys()
	groups.sort()
	for g in groups:
		for o: Dictionary in level["objects"][g]:
			var rec := o.duplicate()
			rec["group"] = str(g)
			out.append(rec)
	return out


# --- data tables --------------------------------------------------------------------------

static func read_table(text: String) -> Dictionary:
	var rows := parse_csv(text)
	var out := {"header": [], "types": [], "rows": [], "by_name": {}}
	if rows.is_empty():
		return out
	var hdr: Array = rows[0]
	var n := hdr.size()
	while n > 0 and str(hdr[n - 1]).strip_edges().is_empty():
		n -= 1
	hdr = hdr.slice(0, n)
	for i in hdr.size():
		hdr[i] = str(hdr[i]).strip_edges()
	out["header"] = hdr
	if rows.size() > 1:
		out["types"] = (rows[1] as Array).slice(0, n)
	var last: Dictionary = {}
	for li in range(2, rows.size()):
		var r: Array = rows[li]
		if _row_blank(r):
			continue
		var rec := {}
		for i in n:
			rec[hdr[i]] = _cell(r, i)
		rec["_line"] = li + 1
		var first := str(rec.get(hdr[0], "")) if n > 0 else ""
		if first.is_empty():
			if not last.is_empty():
				(last["_extra"] as Array).append(rec)
			continue
		rec["_extra"] = []
		rec["_index"] = (out["rows"] as Array).size() + 1
		(out["rows"] as Array).append(rec)
		if not (out["by_name"] as Dictionary).has(first):
			out["by_name"][first] = (out["rows"] as Array).size() - 1
		last = rec
	return out


static func table_row(table: Dictionary, name: String) -> Dictionary:
	var i: Variant = table.get("by_name", {}).get(name)
	return {} if i == null else table["rows"][int(i)]


static func has_size(table: Dictionary) -> bool:
	var hdr: Array = table.get("header", [])
	return "TileWidth" in hdr and "TileHeight" in hdr


static func tile_size(row: Dictionary) -> Vector2i:
	## TileWidth x TileHeight of a table row (= app footprint [x, y]); ZERO when absent.
	var w := str(row.get("TileWidth", "")).strip_edges()
	var h := str(row.get("TileHeight", "")).strip_edges()
	if not w.is_valid_int() or not h.is_valid_int():
		return Vector2i.ZERO
	return Vector2i(int(w), int(h))


static func tool_amounts(row: Dictionary, tool_col: String = "CollectionTool", amount_col: String = "CollectionToolAmount") -> Dictionary:
	## {tool name: amount} over a grouped row and its continuation rows (cost tables).
	var out := {}
	for r: Dictionary in [row] + (row.get("_extra", []) as Array):
		var t := str(r.get(tool_col, "")).strip_edges()
		if not t.is_empty():
			out[t] = _int(str(r.get(amount_col, "")), -1)
	return out
