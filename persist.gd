class_name GPersist extends Node
## SUPABASE PERSISTENCE — expedition saves + the RELIC HUNTERS leaderboard, over plain REST
## with the shared Gogi anon key (the standard Gogi game pattern; both tables are RLS-scoped
## to game data only). The save is keyed to the expedition owner's Gogi uid so progress
## follows the player across devices with no sign-in step.

signal loaded(save: Dictionary)          # emitted once at boot (empty dict = no save yet)
signal leaderboard_ready(rows: Array)    # emitted after fetch_leaderboard

const SB_URL := "https://xhhmxabftbyxrirvvihn.supabase.co"
const SB_KEY := "sb_publishable_NZHoIxqqpSvVBP8MrLHCYA_gmg1AbN-"
const T_SAVES := "usr_nmexs7bytxq2_saltwind_reach_saves"
const T_BOARD := "usr_nmexs7bytxq2_saltwind_reach_leaderboard"
const OWNER := "NMexs7BYTXQ2awKdNEFEWra3P0t1"

var _save_inflight := false
var _pending: Dictionary = {}   # a save requested while one was in flight (coalesced)


func _headers(extra: Array = []) -> PackedStringArray:
	var h := ["apikey: " + SB_KEY, "Authorization: Bearer " + SB_KEY, "Content-Type: application/json"]
	for e in extra:
		h.append(String(e))
	return PackedStringArray(h)


# ---------------- save / load ----------------

func load_save() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		var out: Dictionary = {}
		if code == 200:
			var rows = JSON.parse_string(body.get_string_from_utf8())
			if rows is Array and (rows as Array).size() > 0 and rows[0] is Dictionary:
				var d = (rows[0] as Dictionary).get("data", {})
				if d is Dictionary:
					out = d
		loaded.emit(out))
	var url := SB_URL + "/rest/v1/" + T_SAVES + "?id=eq." + OWNER + "&select=data"
	if req.request(url, _headers()) != OK:
		req.queue_free()
		loaded.emit({})


func save(data: Dictionary) -> void:
	if _save_inflight:
		_pending = data   # coalesce — the newest state wins when the in-flight write returns
		return
	_save_inflight = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, _c: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		req.queue_free()
		_save_inflight = false
		if not _pending.is_empty():
			var nxt := _pending
			_pending = {}
			save(nxt))
	var body := JSON.stringify({"id": OWNER, "user_id": OWNER, "data": data, "updated_at": Time.get_datetime_string_from_system(true) + "Z"})
	if req.request(SB_URL + "/rest/v1/" + T_SAVES, _headers(["Prefer: resolution=merge-duplicates"]),
			HTTPClient.METHOD_POST, body) != OK:
		req.queue_free()
		_save_inflight = false


# ---------------- leaderboard ----------------

func submit_time(display_name: String, seconds: float) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, _c: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
		req.queue_free())
	var body := JSON.stringify({"user_id": OWNER, "name": display_name, "seconds": snappedf(seconds, 0.1)})
	req.request(SB_URL + "/rest/v1/" + T_BOARD, _headers(), HTTPClient.METHOD_POST, body)


func fetch_leaderboard() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		var rows: Array = []
		if code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Array:
				rows = parsed
		leaderboard_ready.emit(rows))
	var url := SB_URL + "/rest/v1/" + T_BOARD + "?select=name,seconds&order=seconds.asc&limit=10"
	if req.request(url, _headers()) != OK:
		req.queue_free()
		leaderboard_ready.emit([])
