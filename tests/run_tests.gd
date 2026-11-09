extends SceneTree
## Headless test runner.
##   godot --headless --path . --script res://tests/run_tests.gd [-- --filter=name] [--junit=path]
## Discovers tests/unit/test_*.gd and tests/integration/test_*.gd, runs every
## test_* method and exits with status 1 if anything failed.

const DIRS := ["res://tests/unit", "res://tests/integration"]


func _initialize() -> void:
	var filter := ""
	var junit := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.substr(9)
		elif a.begins_with("--junit="):
			junit = a.substr(8)
	var total := 0
	var failed := 0
	var asserts := 0
	var lines: PackedStringArray = []
	var cases: Array = []
	var t0 := Time.get_ticks_msec()
	for dir_path in DIRS:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		var files := Array(dir.get_files())
		files.sort()
		for f: String in files:
			if not (f.begins_with("test_") and f.ends_with(".gd")):
				continue
			var script: GDScript = load(dir_path.path_join(f))
			if script == null:
				lines.append("LOAD ERROR %s" % f)
				failed += 1
				continue
			var methods: Array = []
			for m in script.get_script_method_list():
				var n: String = m["name"]
				if n.begins_with("test_") and not n in methods:
					methods.append(n)
			methods.sort()
			for m: String in methods:
				var full := "%s::%s" % [f.get_basename(), m]
				if not filter.is_empty() and full.find(filter) < 0:
					continue
				var tc: TestCase = script.new()
				tc.current_test = full
				var ts := Time.get_ticks_usec()
				tc.before_each()
				var r: Variant = tc.call(m)
				if r is Object and r.has_method("is_valid"):
					pass
				tc.after_each()
				var dt := (Time.get_ticks_usec() - ts) / 1000.0
				total += 1
				asserts += tc.assertions
				if tc.failures.is_empty():
					lines.append("  ok   %s (%.1f ms)" % [full, dt])
					cases.append([full, dt, ""])
				else:
					failed += 1
					lines.append("  FAIL %s" % full)
					for msg in tc.failures:
						lines.append("       - %s" % msg)
					cases.append([full, dt, "\n".join(tc.failures)])
	for l in lines:
		print(l)
	var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
	print("\n%d tests, %d assertions, %d failed (%.2fs)" % [total, asserts, failed, elapsed])
	if not junit.is_empty():
		_write_junit(junit, cases, elapsed)
	quit(1 if failed > 0 or total == 0 else 0)


func _write_junit(path: String, cases: Array, elapsed: float) -> void:
	var fails := cases.filter(func(c): return c[2] != "").size()
	var xml := '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="hayday-sandbox" tests="%d" failures="%d" time="%.3f">\n' % [cases.size(), fails, elapsed]
	for c in cases:
		xml += '  <testcase name="%s" time="%.4f">' % [str(c[0]).xml_escape(), c[1] / 1000.0]
		if c[2] != "":
			xml += '<failure message="failed">%s</failure>' % str(c[2]).xml_escape()
		xml += "</testcase>\n"
	xml += "</testsuite>\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(xml)
