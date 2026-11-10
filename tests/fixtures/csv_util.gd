extends RefCounted
## Test helper shared by unit tests and the in-app selftest. It lives in
## tests/fixtures because exported self-test builds leave tests/unit out.


static func parse_csv(text: String) -> Array:
	## Minimal RFC 4180 reader (quoted fields, doubled quotes, commas and newlines inside quotes).
	var rows: Array = []
	var row: Array = []
	var field := ""
	var quoted := false
	var i := 0
	while i < text.length():
		var ch := text[i]
		if quoted:
			if ch == "\"":
				if i + 1 < text.length() and text[i + 1] == "\"":
					field += "\""
					i += 1
				else:
					quoted = false
			else:
				field += ch
		elif ch == "\"":
			quoted = true
		elif ch == ",":
			row.append(field)
			field = ""
		elif ch == "\n":
			row.append(field)
			rows.append(row)
			row = []
			field = ""
		elif ch != "\r":
			field += ch
		i += 1
	if not field.is_empty() or not row.is_empty():
		row.append(field)
		rows.append(row)
	return rows
