class_name QuestSystem extends Node
## QUEST SYSTEM — tracks quests.json objectives, completes a quest when all steps are
## satisfied, grants rewards, and SETS FLAGS that gate seams (e.g. the vault door requires
## the 'dungeon_cleared' flag this sets). Collect objectives auto-update from
## RpgState.changed; kills come via notify_kill(). This flag-gating is exactly what
## qgcheck validates against world.json so a build can never ship an unwinnable quest graph.

signal objective_changed
signal quest_completed(id: String)

var rpg: RpgState
var defs := {}          # id -> quest def
var st := {}            # id -> {status, kills:{type:n}, reached:{area:true}}
var chain_enabled := false   # true once the adventure is accepted -> prereq'd quests auto-start


func setup(state: RpgState) -> void:
	rpg = state
	rpg.changed.connect(_recheck)


func load_quests(data: Dictionary) -> void:
	for q in data.get("quests", []):
		defs[q.id] = q
		st[q.id] = {status = "inactive", kills = {}, reached = {}, talked = {}}


func start(id: String) -> void:
	if defs.has(id) and st[id].status == "inactive":
		st[id].status = "active"
		objective_changed.emit()


# Start every inactive quest whose prereq ({flags:[...], quests:[...]}) is satisfied.
# Called after each completion + on rpg flag changes while the chain is enabled.
func start_eligible() -> void:
	if not chain_enabled:
		return
	for id in defs:
		if st[id].status != "inactive":
			continue
		if _prereq_met(defs[id].get("prereq", {})):
			st[id].status = "active"
			objective_changed.emit()


func _prereq_met(p: Dictionary) -> bool:
	for f in p.get("flags", []):
		if not rpg.has_flag(String(f)):
			return false
	for q in p.get("quests", []):
		if String(st.get(String(q), {}).get("status", "")) != "done":
			return false
	return true


# ---------------- save / restore ----------------

func serialize() -> Dictionary:
	return {"st": st.duplicate(true), "chain": chain_enabled}


func restore(data: Dictionary) -> void:
	chain_enabled = bool(data.get("chain", false))
	var saved = data.get("st", {})
	if saved is Dictionary:
		for id in saved:
			if st.has(id) and saved[id] is Dictionary:
				st[id] = (saved[id] as Dictionary).duplicate(true)
	objective_changed.emit()


func notify_kill(type: String) -> void:
	for id in st:
		if st[id].status == "active":
			st[id].kills[type] = int(st[id].kills.get(type, 0)) + 1
	_recheck()


func notify_area(area: String) -> void:
	for id in st:
		if st[id].status == "active":
			st[id].reached[area] = true
	_recheck()


func notify_talk(npc_id: String) -> void:
	for id in st:
		if st[id].status == "active":
			st[id].talked[npc_id] = true
	_recheck()


func _recheck() -> void:
	for id in defs:
		if st[id].status == "active" and _all_done(id):
			_complete(id)
	start_eligible()   # a flag set by a completion (or the world) may unlock the next quest


func _all_done(id: String) -> bool:
	for step in defs[id].get("steps", []):
		if not _step_done(id, step.get("objective", {})):
			return false
	return true


func _step_done(id: String, o: Dictionary) -> bool:
	match o.get("type", ""):
		"kill_count": return int(st[id].kills.get(o.target, 0)) >= int(o.get("count", 1))
		"collect", "have_item": return rpg.has_item(o.target)
		"reach_area": return st[id].reached.has(o.target)
		"talk_to": return st[id].talked.has(o.target)
		"set_flag": return rpg.has_flag(o.target)
		_: return false


func _complete(id: String) -> void:
	st[id].status = "done"
	var q: Dictionary = defs[id]
	var r: Dictionary = q.get("rewards", {})
	if r.has("xp"): rpg.grant_xp(int(r.xp))
	if r.has("gold"): rpg.add_gold(int(r.gold))
	for it in r.get("items", []): rpg.add_item(it)
	for f in q.get("on_complete_flags", []): rpg.set_flag(f)   # opens the gated seam
	objective_changed.emit()
	quest_completed.emit(id)
	start_eligible()


func current_objective() -> String:
	for id in defs:
		if st[id].status == "active":
			var parts: Array = []
			for step in defs[id].get("steps", []):
				var mark := "[x] " if _step_done(id, step.get("objective", {})) else "[ ] "
				parts.append(mark + str(step.get("desc", "")))
			return "QUEST: " + str(defs[id].get("name", id)) + "\n" + "\n".join(parts)
		elif st[id].status == "done":
			return "QUEST: " + str(defs[id].get("name", id)) + " - COMPLETE"
	return ""
