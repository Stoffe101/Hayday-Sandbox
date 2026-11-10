class_name InventoryIO
extends RefCounted
## Inventory (profile.owned / purchased / balances, docs/PLANNING.md §2) export
## and import as CSV or JSON. Pure: import returns a NEW profile dictionary plus a
## report and never touches the layout (the UI applies it with an undoable
## SetProfile command).
##
## CSV columns: item_id,name,owned,purchased. Balances are rows whose item_id is
## "currency:<id>" (amount in the owned column). Import is tolerant: header or
## no header, "," ";" or tab separated, quoted fields, ids matched exactly, via
## aliases or by item name (case-insensitive); unknown rows are reported, not
## imported.

const FORMAT := "hayday-sandbox-inventory"
const SCHEMA_VERSION := 1
const CSV_HEADER := ["item_id", "name", "owned", "purchased"]
const BALANCE_PREFIX := "currency:"


# --- export ---------------------------------------------------------------------------------

static func export_csv(profile: Dictionary, db: ItemDatabase = null) -> String:
	var lines: PackedStringArray = [",".join(CSV_HEADER)]
	var bal := _dict(profile.get("balances"))
	for cur in Currency.sorted_ids(bal.keys()):
		lines.append(",".join([_csv_field(BALANCE_PREFIX + cur), _csv_field(Currency.name_of(cur)), str(int(bal[cur])), ""]))
	var owned := _dict(profile.get("owned"))
	var purch := _dict(profile.get("purchased"))
	var ids := {}
	for k in owned:
		ids[str(k)] = true
	for k in purch:
		ids[str(k)] = true
	var sorted := ids.keys()
	sorted.sort()
	for id: String in sorted:
		var it: ItemDef = db.get_item(id) if db != null else null
		lines.append(",".join([_csv_field(id), _csv_field(it.name if it != null else ""),
			str(int(owned[id])) if owned.has(id) else "", str(int(purch[id])) if purch.has(id) else ""]))
	return "\n".join(lines) + "\n"


static func export_json(profile: Dictionary) -> String:
	var doc := {"format": FORMAT, "schema_version": SCHEMA_VERSION,
		"owned": _int_dict(profile.get("owned")), "purchased": _int_dict(profile.get("purchased")),
		"balances": _int_dict(profile.get("balances"))}
	return JsonUtil.stringify(doc)


# --- import ---------------------------------------------------------------------------------

static func import_text(text: String, db: ItemDatabase, profile: Dictionary, replace: bool = false) -> Dictionary:
	## JSON when the text starts with "{", else CSV.
	if text.strip_edges().begins_with("{"):
		return import_json(text, db, profile, replace)
	return import_csv(text, db, profile, replace)


static func new_report() -> Dictionary:
	## {ok, profile, owned, purchased, balances (counts imported), unknown: [tokens],
	##  by_name: [{name, item}], aliases: [{from, to}], ambiguous: [{name, items}], errors: [text]}
	return {"ok": true, "profile": {}, "owned": 0, "purchased": 0, "balances": 0, "unknown": [], "by_name": [],
		"aliases": [], "ambiguous": [], "errors": []}


static func import_json(text: String, db: ItemDatabase, profile: Dictionary, replace: bool = false) -> Dictionary:
	var rep := new_report()
	var data: Variant = JsonUtil.parse(text)
	if not data is Dictionary:
		rep["ok"] = false
		rep["errors"].append("not a JSON object")
		rep["profile"] = profile.duplicate(true)
		return rep
	if data.has("format") and str(data["format"]) != FORMAT:
		rep["errors"].append("unexpected format '%s' (read anyway)" % str(data["format"]))
	var owned := {}
	var purch := {}
	var bal := {}
	var names := _name_index(db)
	for pair in [["owned", owned], ["purchased", purch]]:
		var src: Variant = data.get(pair[0])
		if src == null:
			continue
		if not src is Dictionary:
			rep["errors"].append("'%s' must be an object" % pair[0])
			continue
		for k in src:
			var n: Variant = _count(src[k])
			if n == null:
				rep["errors"].append("%s.%s: '%s' is not a whole number >= 0" % [pair[0], str(k), str(src[k])])
				continue
			var id := _resolve(str(k), "", db, names, rep)
			if id.is_empty():
				continue
			(pair[1] as Dictionary)[id] = n
	var bsrc: Variant = data.get("balances")
	if bsrc is Dictionary:
		for k in bsrc:
			var n: Variant = _count(bsrc[k])
			if n == null:
				rep["errors"].append("balances.%s: '%s' is not a whole number >= 0" % [str(k), str(bsrc[k])])
				continue
			bal[str(k)] = n
	return _finish(rep, profile, owned, purch, bal, replace, data.has("owned"), data.has("purchased"), data.has("balances"))


static func import_csv(text: String, db: ItemDatabase, profile: Dictionary, replace: bool = false) -> Dictionary:
	var rep := new_report()
	var rows := parse_csv(text)
	var owned := {}
	var purch := {}
	var bal := {}
	var names := _name_index(db)
	var cols := {"item": 0, "name": 1, "owned": 2, "purchased": 3}
	var start := 0
	if not rows.is_empty() and _is_header(rows[0]):
		cols = _header_columns(rows[0])
		start = 1
		if not cols.has("item") and not cols.has("name"):
			rep["ok"] = false
			rep["errors"].append("header has no item_id or name column")
			rep["profile"] = profile.duplicate(true)
			return rep
	for i in range(start, rows.size()):
		var r: PackedStringArray = rows[i]
		var line := i + 1
		var tok := _cell(r, cols.get("item", -1))
		var nm := _cell(r, cols.get("name", -1))
		if tok.is_empty() and nm.is_empty():
			continue
		var owned_s := _cell(r, cols.get("owned", -1))
		var purch_s := _cell(r, cols.get("purchased", -1))
		var cur := ""
		var key := (tok if not tok.is_empty() else nm).to_lower()
		if key.begins_with(BALANCE_PREFIX):
			cur = key.substr(BALANCE_PREFIX.length()).strip_edges()
		elif Currency.is_known(key) and (db == null or db.get_item(key) == null):
			cur = key
		if not cur.is_empty():
			var amount: Variant = _count(owned_s)
			if amount == null:
				rep["errors"].append("line %d: balance '%s' is not a whole number >= 0" % [line, owned_s])
			else:
				bal[cur] = amount
			continue
		var id := _resolve(tok, nm, db, names, rep)
		if id.is_empty():
			continue
		if not owned_s.is_empty():
			var n: Variant = _count(owned_s)
			if n == null:
				rep["errors"].append("line %d: owned '%s' is not a whole number >= 0" % [line, owned_s])
			else:
				owned[id] = n
		if not purch_s.is_empty():
			var n2: Variant = _count(purch_s)
			if n2 == null:
				rep["errors"].append("line %d: purchased '%s' is not a whole number >= 0" % [line, purch_s])
			else:
				purch[id] = n2
	return _finish(rep, profile, owned, purch, bal, replace, true, true, true)


static func parse_csv(text: String) -> Array:
	## Rows of fields (PackedStringArray). Separator detected from the first line
	## ("," ";" or tab); double-quoted fields may contain separators, quotes ("")
	## and newlines.
	var t := text.replace("\r\n", "\n").replace("\r", "\n")
	if t.begins_with("﻿"):
		t = t.substr(1)
	var first := t.get_slice("\n", 0)
	var sep := ","
	if first.count(";") > first.count(",") and first.count(";") >= first.count("\t"):
		sep = ";"
	elif first.count("\t") > first.count(","):
		sep = "\t"
	var rows: Array = []
	var row := PackedStringArray()
	var field := ""
	var quoted := false
	var i := 0
	var n := t.length()
	while i < n:
		var ch := t[i]
		if quoted:
			if ch == "\"":
				if i + 1 < n and t[i + 1] == "\"":
					field += "\""
					i += 1
				else:
					quoted = false
			else:
				field += ch
		elif ch == "\"" and field.strip_edges().is_empty():
			quoted = true
			field = ""
		elif ch == sep:
			row.append(field.strip_edges())
			field = ""
		elif ch == "\n":
			row.append(field.strip_edges())
			field = ""
			if not (row.size() == 1 and row[0].is_empty()):
				rows.append(row)
			row = PackedStringArray()
		else:
			field += ch
		i += 1
	if not field.is_empty() or not row.is_empty():
		row.append(field.strip_edges())
		if not (row.size() == 1 and row[0].is_empty()):
			rows.append(row)
	return rows


# --- helpers --------------------------------------------------------------------------------

static func _finish(rep: Dictionary, profile: Dictionary, owned: Dictionary, purch: Dictionary, bal: Dictionary,
		replace: bool, has_owned: bool, has_purch: bool, has_bal: bool) -> Dictionary:
	var p := profile.duplicate(true)
	for pair in [["owned", owned, has_owned], ["purchased", purch, has_purch], ["balances", bal, has_bal]]:
		var key: String = pair[0]
		var cur: Dictionary = _dict(p.get(key)).duplicate(true)
		if replace and bool(pair[2]):
			cur = {}
		cur.merge(pair[1], true)
		p[key] = cur
	rep["owned"] = owned.size()
	rep["purchased"] = purch.size()
	rep["balances"] = bal.size()
	rep["profile"] = p
	return rep


static func _name_index(db: ItemDatabase) -> Dictionary:
	## lower-case name -> Array of item ids.
	var out := {}
	if db == null:
		return out
	for it: ItemDef in db.items.values():
		var k := it.name.strip_edges().to_lower()
		if not out.has(k):
			out[k] = []
		(out[k] as Array).append(it.id)
	return out


static func _resolve(tok: String, nm: String, db: ItemDatabase, names: Dictionary, rep: Dictionary) -> String:
	## Item id for a row ("" = unknown / ambiguous, reported).
	var t := tok.strip_edges()
	if db == null:
		return t
	for cand in [t, t.to_lower(), t.to_lower().replace(" ", "_").replace("-", "_")]:
		if cand.is_empty():
			continue
		if db.items.has(cand):
			return cand
		if db.aliases.has(cand):
			var to := db.resolve_id(cand)
			rep["aliases"].append({"from": t, "to": to})
			return to
	for label in [nm, t]:
		var k := str(label).strip_edges().to_lower()
		if k.is_empty() or not names.has(k):
			continue
		var ids: Array = names[k]
		if ids.size() == 1:
			rep["by_name"].append({"name": label, "item": ids[0]})
			return ids[0]
		var sorted := ids.duplicate()
		sorted.sort()
		rep["ambiguous"].append({"name": label, "items": sorted})
		return ""
	rep["unknown"].append(t if not t.is_empty() else nm)
	return ""


static func _is_header(r: PackedStringArray) -> bool:
	for c in r:
		var l := c.to_lower()
		if l in ["item_id", "item", "id", "owned", "name", "purchased"]:
			return true
	return false


static func _header_columns(r: PackedStringArray) -> Dictionary:
	var cols := {}
	for i in r.size():
		var l := r[i].strip_edges().to_lower().replace(" ", "_")
		if l in ["item_id", "item", "id"] and not cols.has("item"):
			cols["item"] = i
		elif l in ["name", "item_name"] and not cols.has("name"):
			cols["name"] = i
		elif l in ["owned", "count", "quantity", "qty", "have"] and not cols.has("owned"):
			cols["owned"] = i
		elif l in ["purchased", "bought"] and not cols.has("purchased"):
			cols["purchased"] = i
	return cols


static func _cell(r: PackedStringArray, i: int) -> String:
	return r[i].strip_edges() if i >= 0 and i < r.size() else ""


static func _count(v: Variant) -> Variant:
	## A whole number >= 0 from JSON / CSV, or null.
	if v is int:
		return v if int(v) >= 0 else null
	if v is float:
		return int(v) if v >= 0.0 and is_equal_approx(v, roundf(v)) else null
	if v is String:
		var s := (v as String).strip_edges().replace(",", "").replace(" ", "")
		if s.is_valid_int() and s.to_int() >= 0:
			return s.to_int()
	return null


static func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


static func _int_dict(v: Variant) -> Dictionary:
	var out := {}
	var d := _dict(v)
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out[str(k)] = int(d[k])
	return out


static func _csv_field(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n") or s.contains(";"):
		return "\"" + s.replace("\"", "\"\"") + "\""
	return s
