class_name Readiness
extends RefCounted
## "Can I build this?" (Plan › Budget): what stands between the design and the
## real farm, apart from what it costs. Built from results the editor already
## keeps (ConflictIndex conflicts, the cached RealisticAnalyzer report, the
## budget's can't-buy counts), never by re-checking placement. Pure.
##
## Rows: {"id", "label", "detail", "severity": BLOCKING | CHECK, "objects": n,
##        "uids": [design uids to show], "items": [item ids]}; only rows with
## something in them. Blocking = the game won't let you build it as drawn;
## check = may well work but isn't confirmed (unverified data, unknown inventory).

const BLOCKING := 2
const CHECK := 1

## Row ids in display order.
const PLACEMENT := "placement"
const FIXED := "fixed"
const LOCKED_LAND := "locked_land"
const LAND_LEVEL := "land_level"
const LEVEL := "level"
const OVER_MAX := "over_max"
const CANT_BUY := "cant_buy"
const UNKNOWN_ITEM := "unknown_item"
const OUT_OF_SCOPE := "out_of_scope"
const UNVERIFIED := "unverified"
const NO_INVENTORY := "no_inventory"
const ORDER := [PLACEMENT, FIXED, LOCKED_LAND, LAND_LEVEL, LEVEL, OVER_MAX, CANT_BUY, OUT_OF_SCOPE, UNKNOWN_ITEM, UNVERIFIED, NO_INVENTORY]
## RealisticAnalyzer issue code -> row (placement and locked land come from the conflicts).
const ISSUE_ROWS := {"level": LEVEL, "over_max": OVER_MAX, "unverified_size": UNVERIFIED,
	"unknown_item": UNKNOWN_ITEM, "out_of_scope": OUT_OF_SCOPE}


static func build(layout: FarmLayout, db: ItemDatabase, conflicts: Dictionary, report: RealisticAnalyzer.Report,
		not_buyable: Dictionary = {}) -> Dictionary:
	## conflicts: uid -> PlacementRules.Result (EditorSession.conflicts());
	## report: RealisticAnalyzer report (EditorSession.analysis()); not_buyable:
	## item -> objects still to buy that the shop doesn't sell (BudgetEngine
	## item_breakdown "not_buyable", To-buy mode). Returns
	## {"rows": [...], "blocking": rows with BLOCKING, "checks": rows with CHECK,
	##  "blocking_objects": n, "ready": no blocking row, "realistic": bool}.
	var realistic := layout.mode == FarmLayout.MODE_REALISTIC
	var acc := {}
	for id in ORDER:
		acc[id] = {"uids": {}, "items": {}}
	# Placement: from the conflict index (planned objects included: they are
	# part of the design too). Locked land and fixed landmarks get their own rows.
	for u: int in conflicts:
		var o: PlacedObject = layout.objects.get(u)
		var res: PlacementRules.Result = conflicts[u]
		if o == null or res == null:
			continue
		var other := false
		for c in res.reason_counts:
			if int(c) == PlacementRules.LOCKED_LAND:
				_put(acc, LOCKED_LAND, u, o.item_id)
			elif int(c) == PlacementRules.LANDMARK:
				_put(acc, FIXED, u, o.item_id)
			else:
				other = true
		if other:
			_put(acc, PLACEMENT, u, o.item_id)
	if report != null:
		for u: int in report.issues:
			var o: PlacedObject = layout.objects.get(u)
			if o == null:
				continue
			for c in report.issues[u]:
				var row: String = ISSUE_ROWS.get(str(c), "")
				if row == LEVEL and not realistic:
					continue
				if not row.is_empty():
					_put(acc, row, u, o.item_id)
	# Can't buy / no inventory record: per item, every real (not planned) copy.
	var owned: Dictionary = layout.profile.get("owned", {}) if layout.profile.get("owned") is Dictionary else {}
	var nb := {}
	for k in not_buyable:
		if int(not_buyable[k]) > 0:
			nb[str(k)] = int(not_buyable[k])
	var nb_objects := 0
	for k in nb:
		nb_objects += int(nb[k])
	for o: PlacedObject in layout.objects.values():
		if o.planned:
			continue
		var item := db.resolve_id(o.item_id) if db != null else o.item_id
		if nb.has(item) or nb.has(o.item_id):
			_put(acc, CANT_BUY, o.uid, o.item_id)
		if db != null and db.get_item(o.item_id) != null and not owned.has(o.item_id) and not owned.has(item):
			_put(acc, NO_INVENTORY, o.uid, o.item_id)
	var rows: Array = []
	var blocking := 0
	var checks := 0
	var blocking_uids := {}
	for id: String in ORDER:
		var a: Dictionary = acc[id]
		var uids: Array = (a["uids"] as Dictionary).keys()
		uids.sort()
		var items: Array = (a["items"] as Dictionary).keys()
		items.sort()
		var n := uids.size()
		if id == CANT_BUY and nb_objects > 0:
			n = nb_objects
		var row := {"id": id, "uids": uids, "items": items, "objects": n, "severity": severity_of(id)}
		if id == LAND_LEVEL:
			if report == null or report.land_level_locked.is_empty() or not realistic:
				continue
			var lv := 0
			for p: Dictionary in report.land_level_locked:
				lv = maxi(lv, int(p.get("min_level", 0)))
			row["objects"] = 0
			row["plots"] = report.land_level_locked.size()
			row["label"] = "%d expansion%s need a higher farm level" % [report.land_level_locked.size(), "" if report.land_level_locked.size() == 1 else "s"]
			row["detail"] = "Up to level %d; your farm is level %d" % [lv, RealisticAnalyzer.farm_level(layout)]
		else:
			if n == 0:
				continue
			var t := texts(id, n, items.size(), report)
			row["label"] = t[0]
			row["detail"] = t[1]
		rows.append(row)
		if row["severity"] == BLOCKING:
			blocking += 1
			for u in uids:
				blocking_uids[u] = true
		else:
			checks += 1
	return {"rows": rows, "blocking": blocking, "checks": checks, "blocking_objects": blocking_uids.size(),
		"ready": blocking == 0, "realistic": realistic}


static func severity_of(id: String) -> int:
	return CHECK if id in [UNVERIFIED, NO_INVENTORY, UNKNOWN_ITEM] else BLOCKING


static func texts(id: String, n: int, types: int, report: RealisticAnalyzer.Report = null) -> Array:
	## [label, detail] of a row.
	var objs := "%d object%s" % [n, "" if n == 1 else "s"]
	var kinds := "%d item type%s" % [types, "" if types == 1 else "s"]
	match id:
		PLACEMENT:
			return ["%s overlap or stand where they can't" % objs, "Overlapping, on the road, in water, outside the farm or on blocked ground"]
		FIXED:
			return ["%s on fixed farm buildings" % objs, "They overlap a landmark that can't be moved (farmhouse, truck, shop…)"]
		LOCKED_LAND:
			var plots := report.plots_needed.size() if report != null else 0
			return ["%s on locked land" % objs, ("Unlock %d expansion%s first" % [plots, "" if plots == 1 else "s"]) if plots > 0 else "Unlock the expansions under them first"]
		LEVEL:
			return ["%s above your farm level" % objs, "Raise the farm level or wait until these unlock (%s)" % kinds]
		OVER_MAX:
			return ["%s more than the game allows" % objs, "Over the maximum count of %s" % kinds]
		CANT_BUY:
			return ["%s can't be bought" % objs, "Rewards or items the shop doesn't sell, and not in your inventory (%s)" % kinds]
		OUT_OF_SCOPE:
			return ["%s belong to another area" % objs, "Not placeable on the main farm"]
		UNKNOWN_ITEM:
			return ["%s of unknown item types" % objs, "Not in the catalogue: their size and rules can't be checked"]
		UNVERIFIED:
			return ["%s with unverified footprints" % objs, "Their size isn't confirmed: check the spot in Hay Day (%s)" % kinds]
		NO_INVENTORY:
			return ["Inventory unknown for %s" % kinds, "%s whose owned count isn't recorded: record your inventory" % objs]
	return [id, ""]


static func _put(acc: Dictionary, id: String, uid: int, item: String) -> void:
	(acc[id]["uids"] as Dictionary)[uid] = true
	(acc[id]["items"] as Dictionary)[item] = true
