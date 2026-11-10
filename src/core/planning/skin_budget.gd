class_name SkinBudget
extends RefCounted
## Design-customization budget (docs/PLANNING.md §4 "Customization"): what the
## look chosen for the farmhouse, the truck and the roadside shop costs.
## Pure: no scene / UI / App dependencies; unit-tested with invented data.
##
## A customizable landmark (Landmark.skin_kind "house" | "truck" |
## "roadside_shop") shows a skin preset (layout world state landmark_skins;
## "original" = the farm's own look). A preset is a set of appearance parts
## (slot -> part name, Landmark.skins[].parts). Prices of parts come from the
## PriceBook's components (the private client-price supplement, customization_*
## tables). Parts are never items: choosing a look never adds a building, never
## counts as a second farmhouse and never moves the landmark.
##
## Charged: a non-default part the inventory does not list as owned.
##   * Default parts come with the farm: never charged.
##   * Owned parts (profile.owned_parts = {kind: [part names]}) are never
##     charged, in every cost mode (a look is bought once and kept).
##   * A charged part without a price (no client data, event part, unknown name)
##     is counted as unknown, never as 0.
## Optional: the cost joins the farm totals only when the plan says so
## (planning.customization.include, edited with an undoable SetPlanning). It is
## a whole-farm cost: areas, phases and selections never include it.

const PLAN_KEY := "customization"
const OWNED_KEY := "owned_parts"
const ORIGINAL := "original"
const GROUP := "Design customization"
const KIND_ROW := "customization"
const KIND_NAMES := {"house": "Farmhouse", "truck": "Truck", "roadside_shop": "Roadside shop"}


static func is_enabled(plan: Dictionary) -> bool:
	var c: Variant = plan.get(PLAN_KEY)
	return c is Dictionary and bool((c as Dictionary).get("include", false))


static func with_enabled(plan: Dictionary, on: bool) -> Dictionary:
	## A copy of `plan` with the toggle set (pass to PlanContext.set_plan).
	var p := plan.duplicate(true)
	var c: Dictionary = p.get(PLAN_KEY, {}) if p.get(PLAN_KEY) is Dictionary else {}
	c["include"] = on
	p[PLAN_KEY] = c
	return p


static func owned_parts(profile: Dictionary) -> Dictionary:
	## {kind: {part name: true}} from profile.owned_parts.
	var out := {}
	var o: Variant = profile.get(OWNED_KEY)
	if o is Dictionary:
		for k in o:
			var parts := {}
			if o[k] is Array:
				for p in o[k]:
					parts[str(p)] = true
			out[str(k)] = parts
	return out


static func with_owned(profile: Dictionary, kind: String, parts: Array, owned: bool) -> Dictionary:
	## A copy of `profile` with `parts` of `kind` marked owned / not owned (pass to
	## PlanContext.set_profile: one undoable step).
	var p := profile.duplicate(true)
	var all: Dictionary = p.get(OWNED_KEY, {}) if p.get(OWNED_KEY) is Dictionary else {}
	var cur: Array = (all.get(kind, []) as Array).duplicate() if all.get(kind) is Array else []
	for part in parts:
		var s := str(part)
		if owned and not s in cur:
			cur.append(s)
		elif not owned:
			cur.erase(s)
	cur.sort()
	if cur.is_empty():
		all.erase(kind)
	else:
		all[kind] = cur
	if all.is_empty():
		p.erase(OWNED_KEY)
	else:
		p[OWNED_KEY] = all
	return p


static func skin_of(lm: Landmark, layout: FarmLayout) -> String:
	## The preset a layout shows for `lm` (same rule as LandmarkView.skin_of).
	var sk := layout.landmark_skin(lm.id, ORIGINAL) if layout != null else ORIGINAL
	if sk.is_empty() or not lm.has_skin(sk):
		return ORIGINAL
	return sk


static func compute(layout: FarmLayout, landmarks: Array, prices: PriceBook, profile: Dictionary, plan: Dictionary) -> Dictionary:
	## {enabled, known (part prices installed for at least one kind), cost (Cost of
	##  the charged parts with a price), unknown_parts (charged parts without a price,
	##  "Kind: part"), charged, owned, defaults, landmarks: [{id, name, kind,
	##  skin, skin_name, cost, unknown, rows}], rows: [{landmark, landmark_name, kind,
	##  slot, part, name, price (Cost|null), default, owned, event, charged, status}]}.
	## status: "default" | "owned" | "to_buy" | "unknown" (to buy, price unknown).
	var owned := owned_parts(profile)
	var out := {"enabled": is_enabled(plan), "known": false, "cost": {}, "unknown_parts": [], "charged": 0, "owned": 0,
		"defaults": 0, "landmarks": [], "rows": []}
	for v in landmarks:
		var lm := v as Landmark
		if lm == null or lm.skin_kind.is_empty():
			continue
		if prices != null and not prices.components(lm.skin_kind).is_empty():
			out["known"] = true
		var sk := skin_of(lm, layout)
		if sk == ORIGINAL:
			continue
		var preset := {}
		for s in lm.skins:
			if str(s.get("id", "")) == sk:
				preset = s
		var parts: Dictionary = preset.get("parts", {}) if preset.get("parts") is Dictionary else {}
		var entry := {"id": lm.id, "name": lm.name, "kind": lm.skin_kind, "skin": sk, "skin_name": str(preset.get("name", sk)),
			"cost": {}, "unknown": [], "rows": []}
		var mine: Dictionary = owned.get(lm.skin_kind, {})
		var slots := parts.keys()
		slots.sort()
		for slot in slots:
			var part := str(parts[slot])
			var c: Dictionary = prices.component(lm.skin_kind, part) if prices != null else {}
			var row := {"landmark": lm.id, "landmark_name": lm.name, "kind": lm.skin_kind, "slot": str(slot), "part": part,
				"name": str(c.get("name", part)) if not str(c.get("name", "")).is_empty() else part,
				"price": c.get("price") if c.get("price") is Dictionary else null, "default": bool(c.get("default", false)),
				"owned": mine.has(part), "event": bool(c.get("event", false)), "charged": false, "status": "default"}
			if bool(row["default"]):
				out["defaults"] = int(out["defaults"]) + 1
			elif bool(row["owned"]):
				row["status"] = "owned"
				out["owned"] = int(out["owned"]) + 1
			else:
				row["charged"] = true
				out["charged"] = int(out["charged"]) + 1
				if row["price"] == null:
					row["status"] = "unknown"
					var label := "%s: %s" % [str(KIND_NAMES.get(lm.skin_kind, lm.skin_kind)), part]
					(out["unknown_parts"] as Array).append(label)
					(entry["unknown"] as Array).append(part)
				else:
					row["status"] = "to_buy"
					Currency.add_into(out["cost"], row["price"])
					Currency.add_into(entry["cost"], row["price"])
			(entry["rows"] as Array).append(row)
			(out["rows"] as Array).append(row)
		(out["landmarks"] as Array).append(entry)
	return out


static func applies(skin: Dictionary, scope_kind: String = "farm") -> bool:
	## True when the customization cost belongs in a total of this scope: the toggle
	## is on and the scope is the whole farm.
	return bool(skin.get("enabled", false)) and scope_kind == "farm"


static func total_cost(objects_cost: Dictionary, skin: Dictionary, scope_kind: String = "farm") -> Dictionary:
	## The cost shown for a scope: the budget's cost plus the customization when it applies.
	var out := objects_cost.duplicate()
	if applies(skin, scope_kind):
		Currency.add_into(out, skin.get("cost", {}))
	return out


static func unknown_count(skin: Dictionary, scope_kind: String = "farm") -> int:
	return (skin.get("unknown_parts", []) as Array).size() if applies(skin, scope_kind) else 0


static func shop_rows(skin: Dictionary) -> Array:
	## Shopping-list rows (kind "customization", group GROUP) for the charged and
	## owned parts: {kind, group, item ("part:<kind>:<part>"), name, landmark, slot,
	## part, price, owned, status, event}. Default parts are left out.
	var out: Array = []
	for r: Dictionary in skin.get("rows", []):
		if bool(r["default"]):
			continue
		out.append({"kind": KIND_ROW, "group": GROUP, "item": "part:%s:%s" % [r["kind"], r["part"]],
			"name": "%s: %s (%s)" % [str(r["landmark_name"]), str(r["name"]), str(r["slot"])], "landmark": r["landmark"],
			"slot": r["slot"], "part": r["part"], "price": r["price"], "owned": r["owned"], "status": r["status"],
			"event": r["event"]})
	return out


static func summary_text(skin: Dictionary) -> String:
	## "Design customization: 250,000 coins (2 parts; 1 owned; 1 without a price)" or "".
	if (skin.get("rows", []) as Array).is_empty():
		return ""
	var parts: PackedStringArray = []
	parts.append("%d part%s to buy" % [int(skin["charged"]), "" if int(skin["charged"]) == 1 else "s"])
	if int(skin["owned"]) > 0:
		parts.append("%d owned" % int(skin["owned"]))
	if not (skin["unknown_parts"] as Array).is_empty():
		parts.append("%d without a price" % (skin["unknown_parts"] as Array).size())
	return "Design customization: %s (%s)%s" % [Currency.format_line(skin["cost"], "nothing to pay"), ", ".join(parts),
		"" if bool(skin["enabled"]) else " — not in the totals"]
