extends SceneTree
## Compiles every GDScript in src/, tests/ and tools/ and reports errors.
## godot --headless --path . --script res://tools/ci/check_scripts.gd

func _initialize() -> void:
	var bad := 0
	var files := []
	for d in ["res://src", "res://tests", "res://tools"]:
		_collect(d, files)
	for f in files:
		var s: GDScript = load(f)
		if s == null or not s.can_instantiate():
			print("FAIL ", f)
			bad += 1
	print("%d scripts checked, %d failed" % [files.size(), bad])
	quit(1 if bad > 0 else 0)


func _collect(path: String, out: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".gd"):
			out.append(path.path_join(f))
	for d in dir.get_directories():
		_collect(path.path_join(d), out)
