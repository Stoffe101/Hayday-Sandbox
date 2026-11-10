class_name ObjectLayers
extends RefCounted
## View layers of placed objects by catalogue category (View tab): each group is
## shown, dimmed or hidden. Purely a way of looking at the farm: it never changes
## an object, the layout or its file, and hidden objects can't be picked
## (ObjectRenderer). Pure (no scene / App dependencies).

const SHOW := "show"
const DIM := "dim"
const HIDE := "hide"
const STATES := [SHOW, DIM, HIDE]

## [group id, name, icon, categories]. Categories not listed fall into "other".
const GROUPS := [
	["decorations", "Decorations", "sparkles", ["decoration", "flowers", "furniture", "structures", "seasonal", "water"]],
	["production", "Production buildings", "factory", ["production", "farm_building"]],
	["animals", "Animal homes", "paw-print", ["animal_home"]],
	["trees", "Trees & bushes", "trees", ["fruit_tree", "bush", "nature"]],
	["fences", "Fences", "fence", ["fence"]],
	["paths", "Paths", "footprints", ["path"]],
	["other", "Fields & other", "sprout", []],
]
const OTHER := "other"

static var _by_category: Dictionary = {}


static func group_ids() -> Array:
	var out: Array = []
	for g in GROUPS:
		out.append(g[0])
	return out


static func group_name(id: String) -> String:
	for g in GROUPS:
		if g[0] == id:
			return g[1]
	return id


static func group_of_category(category: String) -> String:
	if _by_category.is_empty():
		for g in GROUPS:
			for c in g[3]:
				_by_category[c] = g[0]
	return str(_by_category.get(category, OTHER))


static func group_of(db: ItemDatabase, item_id: String) -> String:
	## Unknown items (no catalogue entry) count as "other".
	var it := db.get_item(item_id) if db != null else null
	return group_of_category(it.category) if it != null else OTHER


static func normalize(states: Variant) -> Dictionary:
	## Only known groups with a dim / hide state are kept ("show" is the default).
	var out := {}
	if not states is Dictionary:
		return out
	var ids := group_ids()
	for k in states:
		var st := str(states[k])
		if str(k) in ids and st in [DIM, HIDE]:
			out[str(k)] = st
	return out


static func state_of(states: Dictionary, group: String) -> String:
	return str(states.get(group, SHOW))


static func with_state(states: Dictionary, group: String, state: String) -> Dictionary:
	var out := normalize(states)
	if state == SHOW or not state in STATES:
		out.erase(group)
	else:
		out[group] = state
	return out


static func is_all_shown(states: Dictionary) -> bool:
	return normalize(states).is_empty()


static func counts(layout: FarmLayout, db: ItemDatabase) -> Dictionary:
	## Objects per group (every group present, 0 when none).
	var out := {}
	for id in group_ids():
		out[id] = 0
	if layout == null:
		return out
	var cache := {}
	for o: PlacedObject in layout.objects.values():
		var g: Variant = cache.get(o.item_id)
		if g == null:
			g = group_of(db, o.item_id)
			cache[o.item_id] = g
		out[g] = int(out[g]) + 1
	return out


static func filter(layout: FarmLayout, db: ItemDatabase, states: Dictionary) -> Dictionary:
	## {"hidden": [uids], "dimmed": [uids]} under these states (sorted).
	var hidden: Array = []
	var dimmed: Array = []
	var st := normalize(states)
	if layout != null and not st.is_empty():
		for o: PlacedObject in layout.objects.values():
			match state_of(st, group_of(db, o.item_id)):
				HIDE: hidden.append(o.uid)
				DIM: dimmed.append(o.uid)
	hidden.sort()
	dimmed.sort()
	return {"hidden": hidden, "dimmed": dimmed}
