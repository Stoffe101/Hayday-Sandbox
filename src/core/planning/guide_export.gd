class_name GuideExport
extends RefCounted
## Text outputs of a recreation guide (RecreationGuide.build()): printable HTML,
## CSV checklist, JSON and plain text. Pure string generation, no file IO and no
## artwork: the caller decides which pictures (if any) to embed and passes them
## as a PNG/JPEG data URI or a plain relative file name.
##
## Common options (all optional):
##   title: String            heading (e.g. the layout name)
##   generated: String        date/time text shown in the header (caller supplies it)
##   overview_image: String   picture of the whole design (data URI or file name)
##   phase_images: {phase id: String}  one picture per phase section
##   include_done: bool       list steps already done (default true)

const FORMAT := "hayday-sandbox-guide"
const FORMAT_VERSION := 1
const CSV_COLUMNS := ["number", "done", "stage", "phase", "title", "items", "count", "tiles", "from_tiles",
	"description", "id"]


static func step_to_dict(step: Dictionary) -> Dictionary:
	## JSON-safe copy of a step (rects become [x, y, w, h]).
	var out := {}
	for k in step:
		out[k] = _plain(step[k])
	return out


static func to_json(guide: Dictionary, options: Dictionary = {}) -> String:
	var steps: Array = []
	for s: Dictionary in _steps(guide, options):
		steps.append(step_to_dict(s))
	var doc := {"format": FORMAT, "version": FORMAT_VERSION, "title": str(options.get("title", "")),
		"generated": str(options.get("generated", "")), "has_baseline": bool(guide.get("has_baseline", false)),
		"progress": _plain(guide.get("progress", {})), "phase_names": _plain(guide.get("phase_names", {})),
		"steps": steps}
	return JSON.stringify(doc, "\t", false)


static func to_csv(guide: Dictionary, options: Dictionary = {}) -> String:
	## One header row plus one row per step (a printable / spreadsheet checklist).
	var lines := PackedStringArray()
	lines.append(",".join(PackedStringArray(CSV_COLUMNS)))
	for s: Dictionary in _steps(guide, options):
		var row := PackedStringArray()
		row.append(str(int(s.get("number", 0))))
		row.append("yes" if bool(s.get("done", false)) else "no")
		row.append(_csv(str(s.get("stage_name", ""))))
		row.append(_csv(str(s.get("phase_name", ""))))
		row.append(_csv(str(s.get("title", ""))))
		row.append(_csv(" ".join(PackedStringArray(s.get("items", [])))))
		row.append(str(int(s.get("count", 0))))
		row.append(_csv(str(s.get("tiles_text", ""))))
		row.append(_csv(str(s.get("from_tiles_text", ""))))
		row.append(_csv(str(s.get("description", ""))))
		row.append(_csv(str(s.get("id", ""))))
		lines.append(",".join(row))
	return "\n".join(lines) + "\n"


static func to_text(guide: Dictionary, options: Dictionary = {}) -> String:
	var out := PackedStringArray()
	var title := str(options.get("title", "Recreation guide"))
	out.append(title)
	out.append("=".repeat(title.length()))
	out.append(_summary_line(guide, options))
	var stage := -1
	for s: Dictionary in _steps(guide, options):
		if int(s.get("stage", 0)) != stage:
			stage = int(s.get("stage", 0))
			out.append("")
			out.append("%d. %s" % [stage, str(s.get("stage_name", ""))])
			out.append("-".repeat(str(s.get("stage_name", "")).length() + 3))
		out.append("[%s] %d. %s  (%s)" % ["x" if bool(s.get("done", false)) else " ", int(s.get("number", 0)),
			str(s.get("title", "")), str(s.get("phase_name", ""))])
		if not str(s.get("description", "")).is_empty():
			out.append("      %s" % str(s["description"]))
		out.append("      %s" % str(s.get("tiles_text", "")))
	return "\n".join(out) + "\n"


static func to_html(guide: Dictionary, options: Dictionary = {}) -> String:
	## A self-contained printable page: header with the overview picture, then
	## one section per phase (build order, Unphased last) starting on a new
	## printed page, each listing its numbered steps with a checkbox.
	var title := str(options.get("title", "Recreation guide"))
	var h := PackedStringArray()
	h.append("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">")
	h.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
	h.append("<title>%s</title>" % _esc(title))
	h.append("<style>\n" + _CSS + "</style>\n</head>\n<body>")
	h.append("<header>\n<h1>%s</h1>" % _esc(title))
	h.append("<p class=\"meta\">%s</p>" % _esc(_summary_line(guide, options)))
	var ov := _img_src(str(options.get("overview_image", "")))
	if not ov.is_empty():
		h.append("<figure><img src=\"%s\" alt=\"Overview of the design\"></figure>" % _esc(ov))
	h.append("<p class=\"note\">Steps are numbered in build order: unlock land, clear obstacles, make room, large buildings, paths and fences, trees and flowers, then decorations. Positions are exact tile coordinates; landmark directions are as seen on screen.</p>")
	h.append("</header>")
	var steps := _steps(guide, options)
	var by_phase := {}
	for s: Dictionary in steps:
		var ph := str(s.get("phase", ""))
		if not by_phase.has(ph):
			by_phase[ph] = []
		by_phase[ph].append(s)
	var imgs: Dictionary = options.get("phase_images", {}) if options.get("phase_images") is Dictionary else {}
	var prog: Dictionary = guide.get("progress", {})
	for pp: Dictionary in prog.get("phases", []):
		var ph := str(pp.get("phase", ""))
		if not by_phase.has(ph):
			continue
		h.append("<section class=\"phase\" id=\"phase-%s\">" % _esc(ph if not ph.is_empty() else "unphased"))
		h.append("<h2>%s</h2>" % _esc(str(pp.get("name", ph))))
		h.append("<p class=\"meta\">%d of %d steps done (%s%%)</p>" % [int(pp.get("completed", 0)), int(pp.get("total", 0)),
			_num(float(pp.get("percent", 0.0)))])
		var src := _img_src(str(imgs.get(ph, "")))
		if not src.is_empty():
			h.append("<figure><img src=\"%s\" alt=\"%s\"></figure>" % [_esc(src), _esc(str(pp.get("name", ph)))])
		h.append("<ol class=\"steps\">")
		for s: Dictionary in by_phase[ph]:
			var done := bool(s.get("done", false))
			h.append("<li class=\"step%s\" value=\"%d\" id=\"step-%s\">" % [" done" if done else "", int(s.get("number", 0)), _esc(str(s.get("id", "")))])
			h.append("<span class=\"box\" aria-label=\"%s\">%s</span> <span class=\"num\">%d.</span> <strong>%s</strong> <span class=\"stage\">%s</span>" % [
				"done" if done else "to do", "&#9745;" if done else "&#9744;", int(s.get("number", 0)),
				_esc(str(s.get("title", ""))), _esc(str(s.get("stage_name", "")))])
			if not str(s.get("description", "")).is_empty():
				h.append("<div class=\"desc\">%s</div>" % _esc(str(s["description"])))
			var tiles := str(s.get("tiles_text", ""))
			if not str(s.get("from_tiles_text", "")).is_empty():
				tiles = "to %s (from %s)" % [tiles, str(s["from_tiles_text"])]
			h.append("<div class=\"tiles\">%s</div>" % _esc(tiles))
			h.append("</li>")
		h.append("</ol>\n</section>")
	h.append("</body>\n</html>")
	return "\n".join(h) + "\n"


# --- helpers ------------------------------------------------------------------------------

const _CSS := """body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;margin:24px;color:#222;background:#fff;line-height:1.4}
h1{font-size:1.6em;margin:0 0 4px}h2{font-size:1.25em;margin:24px 0 4px}
.meta{color:#555;margin:0 0 8px}.note{color:#555;font-size:.9em}
figure{margin:12px 0}img{max-width:100%;height:auto;border:1px solid #ccc}
ol.steps{list-style:none;padding:0;margin:8px 0}
li.step{border-bottom:1px solid #ddd;padding:6px 0;break-inside:avoid;page-break-inside:avoid}
li.step.done{color:#777}.box{font-size:1.2em}.num{font-weight:700}
.stage{color:#777;font-size:.85em;margin-left:6px}.desc{margin-left:2.2em}
.tiles{margin-left:2.2em;font-family:ui-monospace,Consolas,monospace;font-size:.9em}
section.phase{break-before:page;page-break-before:always}
@media screen{section.phase{border-top:2px solid #444;margin-top:24px}}
"""


static func _steps(guide: Dictionary, options: Dictionary) -> Array:
	var all: Array = guide.get("steps", [])
	if bool(options.get("include_done", true)):
		return all
	return all.filter(func(s: Dictionary) -> bool: return not bool(s.get("done", false)))


static func _summary_line(guide: Dictionary, options: Dictionary) -> String:
	var p: Dictionary = guide.get("progress", {})
	var line := "%d steps, %d done (%s%%)" % [int(p.get("total", 0)), int(p.get("completed", 0)), _num(float(p.get("percent", 0.0)))]
	if int(p.get("current_number", -1)) > 0:
		line += ", next: step %d" % int(p["current_number"])
	if not str(options.get("generated", "")).is_empty():
		line += " · %s" % str(options["generated"])
	return line


static func _num(f: float) -> String:
	return str(int(f)) if is_equal_approx(f, roundf(f)) else "%.1f" % f


static func _plain(v: Variant) -> Variant:
	if v is Rect2i:
		var r: Rect2i = v
		return [r.position.x, r.position.y, r.size.x, r.size.y]
	if v is Vector2i:
		return [(v as Vector2i).x, (v as Vector2i).y]
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y]
	if v is Dictionary:
		var d := {}
		for k in v:
			d[str(k)] = _plain(v[k])
		return d
	if v is Array:
		var a: Array = []
		for e in v:
			a.append(_plain(e))
		return a
	if v is PackedStringArray:
		return Array(v)
	return v


static func csv_text_guard(s: String) -> String:
	## Spreadsheets run a cell that starts with = + - @ as a formula: text cells
	## (never numbers) get a leading apostrophe so they stay plain text.
	if not s.is_empty() and s[0] in ["=", "+", "-", "@"] and not s.is_valid_float():
		return "'" + s
	return s


static func _csv(s: String) -> String:
	s = csv_text_guard(s)
	if s.contains(",") or s.contains("\"") or s.contains("\n") or s.contains("\r"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s


static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")


static func _img_src(src: String) -> String:
	## Only raster data URIs and plain relative image file names are embedded.
	var s := src.strip_edges()
	if s.is_empty():
		return ""
	var data := RegEx.create_from_string("^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$")
	if data.search(s) != null:
		return s
	var file := RegEx.create_from_string("^[A-Za-z0-9_][A-Za-z0-9_ .\\-/]*\\.(png|jpg|jpeg|webp)$")
	if file.search(s) != null and not ".." in s.split("/"):
		return s
	return ""
