extends Node3D
## RPG STREAMING TEMPLATE — orchestration. Fetches a FETCHABLE world.json + quests.json
## (loose files served next to index.html, NOT packed in the .pck) + the asset manifest,
## wires the streaming systems, and keeps the player / combat / HUD PERSISTENT across area
## transitions. Areas + their .glb stream from R2 at runtime.
##
## EDITS COME FROM THE CHAT, not in-game: a chat edit is validated by qgcheck server-side
## and the new world.json is written back to R2. This template POLLS world.json and
## hot-reloads the live area when it changes (no re-export), so an open preview updates live.
##
## CHUNK MODE: when world.mode=="chunk" the one-resident ZONE streamer (SceneManager) is replaced
## by ChunkManager (resident 3x3 ring around the player). All chunk wiring is ADDITIVE + guarded
## by chunk_mode, so a non-chunk world behaves exactly as before.

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4

# Default drivable-car model when a world-level "vehicles" entry omits "model" (resolved via _norm).
const VEHICLE_MODEL := "props/kk_city/car_sedan.glb"

# Third-person orbit camera (SpringArm rig) — see _build_player/_process/_input.
const CAM_DIST := 8.5
const CAM_HEAD := 1.5
const CAM_PITCH_MIN := -1.30
const CAM_PITCH_MAX := -0.18
const LOOK_SENS := 0.006

# Wave 4 ranged fire: auto-aim cone APEX angle (i.e. ±15° of the character's facing) and the
# muzzle's forward offset from the GEquipSlot (approximates the weapon tip for flash + spawn).
const FIRE_CONE_DEG := 30.0
const MUZZLE_FWD := 0.4

var origin := "https://preview.myapping.com"
var world_url := "https://preview.myapping.com/world.json"   # overridden from window.location on web
var build_id := ""
var props_pool: Array = []

var world_data := {}
var quests_data := {}
var _world_raw := ""          # last raw world.json text (change-detect for the poll)
var _polling := false

var env: Environment
var sun: DirectionalLight3D
var player: CharacterBody3D
var cam: Camera3D
var cam_rig: Node3D
var cam_spring: SpringArm3D
var cam_yaw := 0.9   # opening angle: camera SE of the spawn, framing the fountain + plaza (not the tavern eave)
var cam_pitch := -0.55
var look_idx := -1
var look_last := Vector2.ZERO
var swing_t := 0.0                 # melee swing window (visual + re-tap gate) — decays in _process
# Wave 4 equipped-weapon state. GEquip owns the attached visual; main tracks the "GEquipSlot"
# node it hangs on the player (the swing pivot AND the ranged muzzle origin) and keeps the
# visual in sync with rpg.equipped_weapon (_sync_equip_visual).
var weapon_slot: Node3D = null     # the GEquipSlot on the player (BoneAttachment3D or fixed offset)
var _equipped_visual_id := ""      # weapon id the attached visual represents (sync guard)
var _equip_busy := false           # _sync_equip_visual re-entrancy latch (its model fetch awaits)
var _fire_cd := 0.0                # ranged/thrown cooldown (1.0 / def rate) — decays in _process

var rpg: RpgState
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var quest: QuestSystem
var weather: Weather3D

# --- chunk-mode resident-ring streaming (behind world.mode=="chunk") ---
var chunk_manager: ChunkManager
var chunk_mode := false

# --- drivable vehicles (world-level "vehicles", vehicle.gd) — PERSISTENT, never cell-parented ---
var vehicle_root: Node3D = null   # persistent layer: chunk eviction / zone transitions never touch it
var vehicles: Array = []          # live Vehicle nodes
var active_vehicle: Vehicle = null   # the car being driven (input routed here; null = on foot)
var _vehicles_spec: Array = []    # snapshot of world "vehicles" for the hot-reload diff
var auto_roam := false          # ?soak=1 -> player auto-roams so peak memory can be measured headlessly
var _roam_t := 0.0

var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO

var hud_layer: CanvasLayer
var stats: Label
var hp_bar: ColorRect
var hp_bg: ColorRect

# --- SALTWIND REACH: play modes, persistence, hero avatar, nav aid, leaderboard ---
const POI := {
	"c7_2": "Porto Verde Plaza", "c6_1": "The River Quay", "c8_2": "The Old Clocktower",
	"c9_3": "Market Street", "c3_2": "Treeline Ranch", "c1_3": "The Bandit Camp",
	"c1_5": "The Ziggurat of the Sun", "c0_0": "Drake Crag", "c4_2": "The Deepwood Trail",
	"c12_1": "Marlin Park", "c11_3": "Hibiscus Lane", "c5_2": "The River Bridge",
}
const TITLES := ["Capt.", "Doc", "Ace", "Prof.", "Scout", "Pilot"]
const SURNAMES := ["Marlowe", "Vane", "Quill", "Harker", "Sable", "Frost", "Calloway", "Rook", "Vesper", "Bram"]

var game_mode := ""              # "" until chosen at the start screen; "adventure" | "explore"
var adventure_active := false
var adventure_start_ms := 0.0
var relic_submitted := false
var expedition_name := ""
var discovered := {}             # POI cell_id -> true
var persist: GPersist
var save_data := {}
var mode_layer: CanvasLayer = null
var board_layer: CanvasLayer = null
var _gated_vehicle_specs: Array = []   # world "vehicles" entries waiting on mode / a flag
var avatar: Node3D = null
var avatar_anim: AnimationPlayer = null
var _av_cur := ""
var _av_attack_t := 0.0
var _av_clips := {}              # idle/walk/run/attack -> resolved clip name
var nav_root: Control = null
var nav_arrow: Polygon2D = null
var nav_label: Label = null
var toast_label: Label = null
var _region := ""                # forest | city | suburbs (ambient bed switching)
var _btn_attack: Button = null
var _btn_use: Button = null
var _btn_potion: Button = null


func _ready() -> void:
	if OS.has_feature("web"):
		var o = JavaScriptBridge.eval("window.location.origin", true)
		if typeof(o) == TYPE_STRING and String(o) != "":
			origin = String(o)
		var dir = JavaScriptBridge.eval("window.location.href.replace(/[^/]*$/, '')", true)
		if typeof(dir) == TYPE_STRING and String(dir) != "":
			world_url = String(dir) + "world.json"
		var bid = JavaScriptBridge.eval("location.pathname.split('/').filter(Boolean)[0] || ''", true)
		if typeof(bid) == TYPE_STRING and String(bid) != "":
			build_id = String(bid)
		var soak = JavaScriptBridge.eval("window.location.search.indexOf('soak=1')>=0", true)
		if typeof(soak) == TYPE_BOOL and soak:
			auto_roam = true

	_build_env()
	_build_player()
	# Prompt-driven sky + weather owns the env/sun from here; defaults to clear day
	# until world.json's "sky" block is read in _boot. (See _apply_weather.)
	weather = Weather3D.new()
	add_child(weather)
	weather.setup(env, sun, cam_rig)
	_build_hud()
	AudioManager.show_tap_overlay()   # web: gesture-gate so audio unlocks (autoplay policy) + a loading veil

	rpg = RpgState.new()
	add_child(rpg)
	rpg.changed.connect(_update_stats)
	rpg.changed.connect(_on_rpg_changed)   # Wave 4: chest auto-equip -> swap the weapon visual

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.world_url = world_url   # lets _region_base_dir() resolve region_*.json next to world.json
	builder.env = env
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)
	quest.objective_changed.connect(_update_stats)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	interaction.main_ref = self   # Wave 3: _nearest reads active_vehicle so seats are gated while driving/riding
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)   # reach_area objectives progress on arrival

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(player, builder, self, env, interaction, rpg)
	chunk_manager.area_entered.connect(quest.notify_area)   # chunk-mode reach_area parity (only the active streamer emits)
	chunk_manager.area_entered.connect(_on_area_visited)    # discovery toasts + region ambient beds

	# poll world.json so a chat edit (qgcheck-gated, written to R2) hot-reloads live
	var poll := Timer.new()
	poll.wait_time = 4.0
	poll.autostart = true
	poll.timeout.connect(_poll_world)
	add_child(poll)

	# Wave 4: attach the default melee weapon NOW (parametric — no fetch), replacing the old
	# hardcoded sword MeshInstance, so the player isn't bare-handed while world.json streams.
	# _boot re-syncs if "start_weapon" names something else.
	_sync_equip_visual()

	# force the expand scale at runtime + relayout the HUD on every resize (web first-frame race)
	var w := get_window()
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	w.size_changed.connect(_relayout_ui)
	_relayout_ui()

	persist = GPersist.new()
	add_child(persist)
	persist.loaded.connect(_on_save_loaded)
	persist.load_save()
	quest.quest_completed.connect(_on_quest_completed)

	var save_timer := Timer.new()
	save_timer.wait_time = 8.0
	save_timer.autostart = true
	save_timer.timeout.connect(_save_now)
	add_child(save_timer)

	_update_stats()
	_boot()
	# a headless world-test harness can ride the REAL boot (dev tool; the file is not shipped)
	if OS.get_cmdline_user_args().has("--worldtest") and ResourceLoader.exists("res://_test_world.gd"):
		var tk = load("res://_test_world.gd").new()
		add_child(tk)
	# settle the web canvas size race, then lay the HUD out against the REAL viewport
	await get_tree().process_frame
	await get_tree().process_frame
	_relayout_ui()


func _boot() -> void:
	# manifest -> props pool (best effort)
	var man := HTTPRequest.new()
	add_child(man)
	man.request(origin + "/godot-assets/manifest.json")
	var mr = await man.request_completed
	man.queue_free()
	if mr[1] == 200:
		_parse_manifest(mr[3])
	builder.props_pool = props_pool

	# world.json (required) — a loose file served next to index.html on web;
	# read straight from the project dir on desktop/headless (offline dev + tests)
	var raw := ""
	if not OS.has_feature("web") and FileAccess.file_exists("res://world.json"):
		raw = FileAccess.get_file_as_string("res://world.json")
	else:
		var wq := HTTPRequest.new()
		add_child(wq)
		wq.request(world_url)
		var wr = await wq.request_completed
		wq.queue_free()
		if wr[1] != 200:
			stats.text = "world.json fetch failed (HTTP %s) @ %s" % [str(wr[1]), world_url]
			return
		raw = (wr[3] as PackedByteArray).get_string_from_utf8()
	var world = JSON.parse_string(raw)
	if not (world is Dictionary):
		stats.text = "world.json parse error"
		return
	world_data = world
	_world_raw = raw
	_apply_weather(world)
	rpg.load_weapons(world.get("weapons", {}))   # Wave 4: world "weapons" merge over inline ITEMS

	# quests.json (fetched alongside world.json — the same data qgcheck validates)
	var qraw := ""
	if not OS.has_feature("web") and FileAccess.file_exists("res://quests.json"):
		qraw = FileAccess.get_file_as_string("res://quests.json")
	else:
		var qq := HTTPRequest.new()
		add_child(qq)
		qq.request(world_url.replace("world.json", "quests.json"))
		var qr = await qq.request_completed
		qq.queue_free()
		if qr[1] == 200:
			qraw = (qr[3] as PackedByteArray).get_string_from_utf8()
	if qraw != "":
		var qdata = JSON.parse_string(qraw)
		if qdata is Dictionary:
			quests_data = qdata
			quest.load_quests(qdata)
			# quests do NOT auto-start: the arc begins when the ADVENTURE begins —
			# mode select, or (in Explore) talking to the tavern keeper. See begin_adventure().

	# world-level drivable vehicles — spawned ONCE onto the persistent layer BEFORE the streamer
	# starts, so their builder._ensure can't interleave with a cell build's parallel downloads.
	await _spawn_vehicles(world)

	# Wave 4: "start_weapon" equips at spawn. Its model prefetch is SERIALIZED here (like the
	# vehicles above) so a library//BUILD_ID weapon GLB can't interleave with the streamer's
	# parallel downloads; "parametric:*" models need no fetch at all.
	var start_id := String(world.get("start_weapon", ""))
	if start_id != "":
		if not rpg.has_item(start_id):
			rpg.add_item(start_id)
		rpg.equip(start_id, true)   # force: the authored start weapon wins regardless of damage
	await _sync_equip_visual()

	# the hero: a real 1930s expedition character streamed like any other model
	await _setup_avatar()
	_start_soundtrack()

	if String(world.get("mode", "")) == "chunk":
		chunk_mode = true
		scene_manager._fade.visible = false   # chunk mode never fades -> hide the opaque black overlay
		sun.shadow_enabled = true              # restored: the floor slab is cast_shadow=OFF (no self-acne),
		sun.shadow_normal_bias = 2.0           # so props/buildings cast real contact shadows + read as planted
		sun.directional_shadow_max_distance = 42.0   # ring is only ~24u -> tight cascade = sharper + cheaper (mobile)
		await chunk_manager.start(world)
		_wire_vehicle_terrain()   # GTerrain exists only after start() — hand it to the parked cars
		interaction.terrain = chunk_manager.terrain   # Wave 3: grounds the stand-up-from-a-seat spot
	else:
		scene_manager.start(world)


func _physics_process(delta: float) -> void:
	if player == null:
		return
	if _ui_blocked():
		move_vec = Vector2.ZERO
		move_idx = -1
		look_idx = -1
		return
	if active_vehicle != null:
		# DRIVING: feed the car the SAME input vector that walks the player (one input path, no
		# second binding). The vehicle integrates it in its own physics tick and parks the hidden
		# player on itself, so chunk streaming + reach_area quest notifications (both read
		# player.global_position) keep following the driven position.
		if not is_instance_valid(active_vehicle):
			active_vehicle = null   # freed under us (hot-reload edge) — fall through to on-foot
		else:
			active_vehicle.drive_input(_keyboard_vec() + move_vec)
			return
	# Wave 3 (sittable furniture): a SEATED player doesn't move — but movement input IS the intent
	# to leave, so it stands them up first (interaction restores the pose + places them beside the
	# seat, grounded); motion resumes next tick. This ONE gate covers BOTH the zone and chunk
	# physics paths below. The camera is untouched — the SpringArm rig follows the seated player.
	if interaction != null and interaction.player_seated:
		if (_keyboard_vec() + move_vec).length() > 0.1:
			interaction.stand_player()
		return
	if chunk_mode:
		_chunk_physics(delta)
		return
	if scene_manager == null:
		return
	if scene_manager.transitioning or scene_manager.current_root == null:
		return
	var v := _keyboard_vec() + move_vec
	if v.length() > 1.0:
		v = v.normalized()
	# Camera-relative: forward = away from the camera, rotated by the orbit yaw.
	var dir := Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	player.velocity = dir * 6.0 + Vector3.DOWN * 14.0   # gravity: hug the terrain downhill too
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()


func _chunk_physics(delta: float) -> void:
	var v := _keyboard_vec() + move_vec
	if auto_roam and chunk_manager != null:
		_roam_t += delta
		# diagonal ping-pong across the whole grid -> the resident ring shifts + evicts repeatedly
		var rect := chunk_manager.grid_world_rect()
		var tt := fmod(_roam_t * 0.05, 2.0)
		var f := tt if tt <= 1.0 else (2.0 - tt)
		var target := Vector3(rect.position.x, 0.0, rect.position.y).lerp(
			Vector3(rect.end.x, 0.0, rect.end.y), f)
		var to := target - player.global_position
		v = Vector2(to.x, to.z)
	if v.length() > 1.0:
		v = v.normalized()
	# Camera-relative when the player drives; world-relative during the headless
	# soak roam (auto_roam computes a world-space target, cam_yaw must not rotate it).
	var dir := Vector3(v.x, 0.0, v.y) if auto_roam else Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	player.velocity = dir * 6.0 + Vector3.DOWN * 14.0   # gravity: hug the terrain downhill too
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	# ANALYTIC floor clamp: the trimesh collider only exists once a cell has BUILT, so
	# gravity must never drop the player through a still-streaming cell (boot especially).
	if chunk_manager != null and chunk_manager.terrain != null:
		var gy: float = chunk_manager.terrain.height(player.global_position.x, player.global_position.z)
		if player.global_position.y < gy + 0.02:
			player.global_position.y = gy + 0.02


func _process(delta: float) -> void:
	if cam_rig and player:
		# Rig follows the player; yaw/pitch come from drag-look. The SpringArm
		# keeps the camera aimed at the head and pulls it in through walls.
		cam_rig.global_position = player.global_position + Vector3(0.0, CAM_HEAD, 0.0)
		cam_rig.rotation.y = cam_yaw
		cam_spring.rotation.x = cam_pitch
	# Wave 4: attack timers + the melee swing visual moved HERE from the two physics paths
	# (which early-return while DRIVING) so a MOUNTED rider's swing still animates/decays and
	# the ranged cooldown keeps ticking — riders fire too. Same 0.22s window and the exact
	# hardcoded-sword formula, now routed at the GEquipSlot pivot. Non-melee weapons keep the
	# orientation GEquip gave them (no -10° idle stomp on a bow).
	swing_t = maxf(0.0, swing_t - delta)
	_fire_cd = maxf(0.0, _fire_cd - delta)
	if weapon_slot != null and is_instance_valid(weapon_slot) \
			and String(_equipped_def().get("kind", "melee")) == "melee":
		weapon_slot.rotation_degrees.x = (-90.0 + (1.0 - swing_t / 0.22) * 120.0) if swing_t > 0.0 else -10.0
	if chunk_mode and chunk_manager != null:
		chunk_manager.tick(delta)
	_tick_avatar(delta)
	_tick_nav()
	if stats:
		_refresh_stats()


# ---------------- HUD ----------------

func _update_stats() -> void:
	_refresh_stats()
	if hp_bar and rpg:
		hp_bar.size.x = 240.0 * clamp(rpg.hp / rpg.max_hp, 0.0, 1.0)


func _refresh_stats() -> void:
	if rpg == null:
		return
	var streamer = chunk_manager if chunk_mode else scene_manager
	var alive := 0
	if streamer:
		for e in streamer.enemies:
			if is_instance_valid(e) and not e.dead:
				alive += 1
	var area: String = String(streamer.current_id) if streamer != null else ""
	stats.text = "Lv %d  HP %d/%d  XP %d/%d  Gold %d\n%s   %s\nInv: %s" % [
		rpg.level, int(rpg.hp), int(rpg.max_hp), rpg.xp, rpg.xp_next, rpg.gold,
		rpg.item_name(rpg.equipped_weapon), String(POI.get(area, "")),
		rpg.inventory_summary()]


# ---------------- combat / hooks ----------------

# The ONE attack entry (the HUD ATTACK button): routes by the equipped weapon's kind.
# melee -> the Wave-1 swing, byte-identical semantics (2.6u reach, forward half-cone,
# enemy.take_hit). ranged/thrown -> _fire_ranged (auto-aim + pooled GProjectile). The button
# stays LIVE while DRIVING/MOUNTED — only _physics_process's movement routing is gated on
# active_vehicle, Button.pressed never passes through it — so riders fire too.
func _attack() -> void:
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer == null or streamer.transitioning or _ui_blocked():
		return
	var def := _equipped_def()
	var kind := String(def.get("kind", "melee"))
	if kind == "ranged" or kind == "thrown":
		_fire_ranged(def, streamer)
		return
	if swing_t > 0.0:
		return
	swing_t = 0.22
	AudioManager.play_sfx("attack")
	_av_oneshot("attack")
	var dmg := rpg.weapon_damage()
	# mobile aim assist: a stationary tap shouldn't whiff — snap the hero's facing (+Z,
	# the stack convention movement and ranged fire already use) toward the nearest live
	# enemy in melee reach, then run the half-cone test on that SAME +Z facing.
	var near: Node3D = null
	var nd := 2.6
	for en in streamer.enemies:
		if not is_instance_valid(en) or en.dead:
			continue
		var t0: Vector3 = (en as Node3D).global_position - player.global_position
		t0.y = 0.0
		if t0.length() < nd:
			nd = t0.length()
			near = en
	if near != null:
		var away := near.global_position - player.global_position
		away.y = 0.0
		if away.length() > 0.05:
			var face := player.global_position - away   # look_at aims -Z there -> +Z at the enemy
			player.look_at(Vector3(face.x, player.global_position.y, face.z), Vector3.UP)
	var fwd: Vector3 = player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.BACK
	for e in streamer.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var to: Vector3 = e.global_position - player.global_position
		to.y = 0.0
		if to.length() < 2.6 and fwd.dot(to.normalized()) > 0.25:
			e.take_hit(dmg)


# The live equipped-weapon def: GEquip stamps "gequip_def" on the character at equip time;
# before the first equip lands (async boot) fall back to the catalog def for the equipped id.
func _equipped_def() -> Dictionary:
	if player != null and player.has_meta("gequip_def"):
		var d = player.get_meta("gequip_def")
		if d is Dictionary:
			return d
	return rpg.weapon_def(rpg.equipped_weapon) if rpg != null else {}


# Wave 4 ranged/thrown fire — mobile-first AUTO-AIM: the NEAREST live enemy inside the
# FIRE_CONE_DEG cone of the character's facing AND inside weapon range is aimed at its chest
# (+1.0m); none in the cone -> straight ahead. The per-weapon rate gates repeat taps.
# MOUNTED riders compose for free: the GEquipSlot rides the player, which vehicle.gd's
# _track_driver parks (and faces) on the boardable every tick — origin + facing follow, no
# special casing. Facing is +basis.z, the stack convention (characters FACE +Z — see
# vehicle.gd / GPose).
func _fire_ranged(def: Dictionary, streamer) -> void:
	if _fire_cd > 0.0:
		return
	var root: Node3D = streamer.current_root
	if root == null or not is_instance_valid(root):
		return
	_fire_cd = 1.0 / maxf(0.1, float(def.get("rate", 1.2)))
	var fwd: Vector3 = player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.BACK
	var rng := maxf(1.0, float(def.get("range", 20.0)))
	var cone := cos(deg_to_rad(FIRE_CONE_DEG * 0.5))
	var best: Node3D = null
	var bd := rng   # nearest-wins inside the cone
	for e in streamer.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var to: Vector3 = (e as Node3D).global_position - player.global_position
		to.y = 0.0
		var d := to.length()
		if d < 0.01 or d > bd:
			continue
		if fwd.dot(to / d) < cone:
			continue
		bd = d
		best = e
	# muzzle = the GEquipSlot (weapon tip-ish) + a small forward offset; slot not attached
	# yet (async equip in flight) -> chest height on the player. in_tree guard: NEVER read a
	# global transform off a detached node (doctrine).
	var muzzle: Vector3 = player.global_position + Vector3(0.0, 1.2, 0.0)
	if weapon_slot != null and is_instance_valid(weapon_slot) and weapon_slot.is_inside_tree():
		muzzle = weapon_slot.global_position
	muzzle += fwd * MUZZLE_FWD
	var dir: Vector3 = fwd
	if best != null:
		dir = ((best.global_position + Vector3(0.0, 1.0, 0.0)) - muzzle).normalized()
	AudioManager.play_sfx("attack")
	GProjectile.flash(muzzle, root)
	GProjectile.fire(root, muzzle, dir, def, _live_enemies)


# enemies_provider handed to GProjectile.fire — always the ACTIVE streamer's live union
# (chunk resident ring / zone area), so a projectile in flight never holds a stale list.
func _live_enemies() -> Array:
	var streamer = chunk_manager if chunk_mode else scene_manager
	return streamer.enemies if streamer != null else []


# Keep the ATTACHED weapon visual in sync with rpg.equipped_weapon (boot start_weapon, chest
# auto-equip upgrades, hot-reload re-stats). "parametric:*" models attach with no fetch;
# library//BUILD_ID GLBs prefetch through the SHARED builder cache (the vehicles' path).
# Loops because equipped_weapon can change again during the await; GEquip.equip is
# idempotent, one weapon at a time.
func _sync_equip_visual() -> void:
	if _equip_busy or player == null or rpg == null:
		return
	_equip_busy = true
	while _equipped_visual_id != rpg.equipped_weapon:
		var id: String = rpg.equipped_weapon
		var def: Dictionary = rpg.weapon_def(id)
		var model: Node3D = null
		var mu := String(def.get("model", ""))
		if mu != "" and not mu.begins_with("parametric:"):
			var u := _norm(mu)
			if u != "":
				await builder._ensure([u])
				if builder.cache.has(u) and builder.cache[u] != null:
					model = (builder.cache[u] as Node).duplicate() as Node3D
		GEquip.equip(player, def, model)
		weapon_slot = player.find_child("GEquipSlot", true, false) as Node3D
		_equipped_visual_id = id
	_equip_busy = false


func _on_rpg_changed() -> void:
	if rpg != null and _equipped_visual_id != rpg.equipped_weapon:
		_sync_equip_visual()   # fire-and-forget — the latch + loop absorb re-entry
	_check_gated_vehicles()    # a fresh flag/item may wake a gated ride (the drake)
	# the timed run: taking the Sunstone submits the expedition to the RELIC HUNTERS board
	if adventure_active and not relic_submitted and rpg != null and rpg.has_item("sunstone_relic"):
		relic_submitted = true
		var secs := maxf(1.0, (Time.get_unix_time_from_system() * 1000.0 - adventure_start_ms) / 1000.0)
		persist.submit_time(expedition_name, secs)
		_toast("Sunstone recovered in " + _fmt_time(secs) + " - inscribed on the tavern plaque")
		_save_now()


func take_damage(d: float) -> void:
	AudioManager.play_sfx("hurt")
	_av_oneshot("hit")
	_shake_camera()
	if chunk_mode:
		if rpg.take_damage(d):
			rpg.hp = rpg.max_hp   # forgiving respawn in place (no area transition in chunk mode)
		return
	if scene_manager == null or scene_manager.transitioning:
		return
	if rpg.take_damage(d):
		rpg.hp = rpg.max_hp        # forgiving respawn: full heal in the current area
		scene_manager.goto_area(scene_manager.current_id, scene_manager.areas[scene_manager.current_id].spawns.keys()[0])


func on_enemy_killed(type: String) -> void:   # called by enemy.gd on death
	AudioManager.play_sfx("death")
	if rpg:
		rpg.grant_xp(15)
	if quest:
		quest.notify_kill(type)


# ---------------- live hot-reload from chat edits ----------------

func _poll_world() -> void:
	# re-fetch world.json; if a chat edit changed it (qgcheck already gated it server-side),
	# hot-reload the current area live. Cache-buster bypasses the edge cache.
	if scene_manager == null or scene_manager.transitioning or world_data.is_empty() or _polling:
		return
	_polling = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request(world_url + "?t=" + str(Time.get_ticks_msec()))
	var res = await req.request_completed
	req.queue_free()
	_polling = false
	if res[1] != 200:
		return
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw == _world_raw or raw.strip_edges() == "":
		return
	var w = JSON.parse_string(raw)
	if not (w is Dictionary):
		return
	# chunk worlds carry "cells"/"grid" (not "areas"); zone worlds carry "areas"
	if chunk_mode:
		if not w.has("cells"):
			return
	elif not w.has("areas"):
		return
	_world_raw = raw
	world_data = w
	_apply_weather(w)
	# Wave 4: a chat edit can re-stat "weapons" (damage/model/…). Reload the merged catalog and
	# re-attach the visual ONLY when the equipped def's content actually changed (deep ==).
	# Awaited so a weapon-model fetch is serialized BEFORE the streamer reload's downloads.
	var eq_before: Dictionary = rpg.weapon_def(rpg.equipped_weapon)
	rpg.load_weapons(w.get("weapons", {}))
	if rpg.weapon_def(rpg.equipped_weapon) != eq_before:
		_equipped_visual_id = ""
		await _sync_equip_visual()
	# vehicles-only rebuild when the world "vehicles" list changed (never touches the player or the
	# streamer). Awaited so its model fetch is serialized BEFORE the streamer reload's downloads.
	await _reload_vehicles(w)
	if chunk_mode:
		chunk_manager.reload(world_data)   # rebuild only CHANGED resident cells in place — no player move
	else:
		scene_manager.reload(world_data)   # no re-export — the live area rebuilds


# ---------------- drivable vehicles (world-level "vehicles", vehicle.gd) ----------------

# Spawn the world's "vehicles" ONCE onto a persistent layer (a direct child of main — chunk cell
# eviction and zone area frees can never reclaim it). Zone worlds get the same world-space
# placement. Models fetch through the SHARED builder cache (parallel, dedup'd); a world with no
# "vehicles" returns immediately — zero behavior change.
func _spawn_vehicles(world: Dictionary) -> void:
	var list = world.get("vehicles", [])
	if not (list is Array) or (list as Array).is_empty():
		_vehicles_spec = []
		return
	_vehicles_spec = (list as Array).duplicate(true)   # snapshot for the hot-reload diff
	if vehicle_root == null:
		vehicle_root = Node3D.new()
		add_child(vehicle_root)
	var urls: Array = []
	for spec in list:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		var u := _vehicle_model_url(spec)
		if u != "" and not urls.has(u):
			urls.append(u)
	await builder._ensure(urls)
	_gated_vehicle_specs = []
	for spec in list:
		if typeof(spec) != TYPE_DICTIONARY:
			continue
		# SALTWIND gating: a ride can be mode-tagged ("mode": "adventure"|"explore") and/or
		# flag/item-gated ("requires": token). The Adventure storm-drake only appears on the
		# crag once the Sunstone wakes it; the Explore one waits saddled in the park.
		if not _vehicle_available(spec):
			_gated_vehicle_specs.append(spec)
			continue
		_spawn_one_vehicle(spec)


func _vehicle_available(spec: Dictionary) -> bool:
	var m := String(spec.get("mode", ""))
	if m != "" and m != game_mode:
		return false
	var r := String(spec.get("requires", ""))
	if r != "" and not (rpg.has_item(r) or rpg.has_flag(r)):
		return false
	return true


func _spawn_one_vehicle(spec: Dictionary) -> void:
	var pos = spec.get("pos", [])
	if not (pos is Array) or (pos as Array).size() < 2:
		return
	if vehicle_root == null:
		vehicle_root = Node3D.new()
		add_child(vehicle_root)
	var mu := _vehicle_model_url(spec)
	var model: Node3D = null
	if mu != "" and builder.cache.has(mu) and builder.cache[mu] != null:
		model = (builder.cache[mu] as Node).duplicate() as Node3D
	var car := Vehicle.new()
	car.player_ref = player
	car.setup(spec, model)   # scale-normalize (4m car) + AABB-ground + box collider + prompt
	vehicle_root.add_child(car)
	car.global_position = Vector3(float(pos[0]), 0.0, float(pos[1]))
	car.drive_state_changed.connect(_on_vehicle_drive_state)
	interaction.add_vehicle(car)   # same touch/USE mechanism chests/NPCs use -> enter/exit
	vehicles.append(car)
	if chunk_mode and chunk_manager != null and chunk_manager.terrain != null:
		car.set_terrain(chunk_manager.terrain)
		if chunk_manager.water_cfg != null:
			car.set_water(chunk_manager.water_level)


# Re-check the deferred rides (mode chosen, or a gating flag/item just landed) and spawn
# the newly-available ones. The waking drake gets its moment.
func _check_gated_vehicles() -> void:
	if _gated_vehicle_specs.is_empty():
		return
	var still: Array = []
	for spec in _gated_vehicle_specs:
		if _vehicle_available(spec):
			await builder._ensure([_vehicle_model_url(spec)])
			_spawn_one_vehicle(spec)
			if String(spec.get("requires", "")) != "":
				AudioManager.play_sfx("secret")
				_toast("Wings over the Deepwood - the STORM-DRAKE has woken on the crag!")
		else:
			still.append(spec)
	_gated_vehicle_specs = still


# world.json vehicle "model" (or url/asset) -> absolute URL. Defaults are
# PER-PROFILE (Wave 3): mounts resolve their pinned library creature
# (farm_Horse / farm_Cow / monster_Dragon via Vehicle.default_model_path);
# parametric profiles (car/tank/boat/plane) return "" — the Vehicle builds
# its own body, so prefetching the sedan for them would be wasted.
func _vehicle_model_url(spec: Dictionary) -> String:
	var u := String(spec.get("model", spec.get("url", spec.get("asset", ""))))
	if u == "":
		u = Vehicle.default_model_path(String(spec.get("profile", "car")))
	if u == "":
		return ""   # parametric profile with no explicit model — nothing to fetch
	return _norm(u)


# Hot-reload: the polled world.json changed — if (and only if) its "vehicles" list differs from the
# spawned snapshot, rebuild the vehicles alone. The player is untouched UNLESS they are driving a
# rebuilt car, in which case they step out first (a hidden player must never be left attached to a
# freed node).
func _reload_vehicles(w: Dictionary) -> void:
	var list = w.get("vehicles", [])
	if not (list is Array):
		list = []
	if (list as Array) == _vehicles_spec:   # deep == on nested Arrays/Dictionaries
		return
	if active_vehicle != null and is_instance_valid(active_vehicle):
		active_vehicle.exit()   # clears active_vehicle via _on_vehicle_drive_state
	active_vehicle = null
	for v in vehicles:
		if is_instance_valid(v):
			(v as Node).queue_free()
	vehicles = []
	interaction.remove_vehicles()
	await _spawn_vehicles(w)
	_wire_vehicle_terrain()


# Vehicles spawn before ChunkManager builds GTerrain — hand them the heightfield afterwards so a
# parked car snaps onto the rendered surface (no-op for flat/zone worlds: terrain stays null -> y=0).
func _wire_vehicle_terrain() -> void:
	if not chunk_mode or chunk_manager == null:
		return
	for v: Vehicle in vehicles:
		if is_instance_valid(v):
			v.set_terrain(chunk_manager.terrain)
			# Wave 3: boats ride the water surface — hand them the level when
			# the world opted into water (else they keep the terrain degrade).
			if chunk_manager.water_cfg != null:
				v.set_water(chunk_manager.water_level)


# Enter/exit bookkeeping: route input to the active car and exclude its body from the camera
# SpringArm sweep (the car is on the world layer the arm collides with — without the exclusion the
# arm hits the car's own box and jams the camera against the roof).
func _on_vehicle_drive_state(v: Vehicle, is_driving: bool) -> void:
	if is_driving:
		active_vehicle = v
		cam_spring.add_excluded_object(v.get_rid())
	else:
		if active_vehicle == v:
			active_vehicle = null
		cam_spring.remove_excluded_object(v.get_rid())


# ---------------- input ----------------

func _ui_blocked() -> bool:
	return mode_layer != null or board_layer != null


func _input(event: InputEvent) -> void:
	if scene_manager == null or scene_manager.transitioning or _ui_blocked():
		return
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x < half and move_idx == -1:
				move_idx = event.index
				move_origin = event.position
				move_vec = Vector2.ZERO
			elif event.position.x >= half and look_idx == -1:
				# right half of the screen = drag to orbit the camera
				look_idx = event.index
				look_last = event.position
		else:
			if event.index == move_idx:
				move_idx = -1
				move_vec = Vector2.ZERO
			elif event.index == look_idx:
				look_idx = -1
	elif event is InputEventScreenDrag:
		if event.index == move_idx:
			move_vec = ((event.position - move_origin) / 80.0).limit_length(1.0)
		elif event.index == look_idx:
			_apply_look(event.position - look_last)
			look_last = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and move_idx == -1 and look_idx == -1:
		# desktop drag-look (no active touches → ignores emulated-from-touch motion)
		_apply_look(event.relative)


func _apply_look(d: Vector2) -> void:
	cam_yaw -= d.x * LOOK_SENS
	cam_pitch = clampf(cam_pitch - d.y * LOOK_SENS, CAM_PITCH_MIN, CAM_PITCH_MAX)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	return v


# ---------------- manifest ----------------

func _parse_manifest(body: PackedByteArray) -> void:
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary):
		return
	# Scatter = ambient NATURE clutter ONLY (rocks/plants/trees/logs). The manifest tags every prop
	# with a `category`; pulling the WHOLE library scattered buildings/walls/swords/pipes into every
	# area (incongruous, odd-shaped "floating" junk). Named PALETTE props are a separate path, unaffected.
	for p in data.get("props", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if String(p.get("category", "")) != "nature":
			continue
		# within "nature", skip terrain/tiling pieces (cliffs, paths, beach/road edges) — those tile
		# the ground, they're not free-standing scatter clutter
		var fn := String(p.get("file", "")).get_file().to_lower()
		if "terrain" in fn or "path" in fn or "cliff" in fn or "beach" in fn or "railway" in fn or "road" in fn or "fence" in fn:
			continue
		var u := _norm(String(p.get("file", "")))   # relative → resolves against origin (portable)
		if u != "" and "/godot-assets/props/" in u:
			props_pool.append(u)


func _collect(v, out_arr: Array) -> void:
	match typeof(v):
		TYPE_STRING:
			if (v as String).to_lower().ends_with(".glb"):
				out_arr.append(v)
		TYPE_DICTIONARY:
			for k in v:
				_collect(v[k], out_arr)
		TYPE_ARRAY:
			for e in v:
				_collect(e, out_arr)


func _norm(s: String) -> String:
	if s.begins_with("http"):
		return s
	if s.begins_with("/"):
		return origin + s
	if "/" in s:
		return origin + "/godot-assets/" + s
	return ""


# Prompt-driven sky/weather: the agent sets a top-level "sky" block in world.json
# (a fixed {time,weather} or a {cycle:[...],loop}). Re-applied on hot-reload.
func _apply_weather(world: Dictionary) -> void:
	if weather == null:
		return
	var sky = world.get("sky", null)
	if sky is Dictionary:
		weather.apply(sky)


# ---------------- world build (persistent player/env/hud) ----------------

func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	# Look upgrade (env is shared; the Weather3D system reuses it and only overrides sky/ambient, so
	# these survive). ACES tonemap = warm/filmic vs the flat linear default; a touch of contrast +
	# saturation so nothing reads washed-out. Both are Compatibility/WebGL2-safe (Environment GLOW is
	# NOT — neon is faked with emissive + an additive quad per art.md, never env.glow_enabled).
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.12
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -45.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true   # contact shadows GROUND props. In CHUNK mode _boot tightens the cascade +
	add_child(sun)              # the floor slab is cast_shadow=OFF, so props cast but the flat floor can't acne.


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD | L_ENEMY
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.6
	cs.shape = cap
	cs.position.y = 0.85
	player.add_child(cs)
	# DEFAULT body = a placeholder capsule; _setup_avatar streams the Meshy hero over it
	# (character GLB origins sit at the hips, so feet sink under the floor without seating).
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.6
	body.mesh = cm
	body.position.y = 0.85
	body.material_override = _mat(Color(0.3, 0.6, 0.95))
	player.add_child(body)
	# Third-person SpringArm orbit rig: a yaw pivot that follows the player, a
	# collision-aware spring arm (pulls the cam in at walls), and the camera on
	# the tip — empirically the cam lands at +Z*length, auto-aimed at the pivot.
	# Pitch is clamped so it can never dive to the floor; movement is camera-relative.
	cam_rig = Node3D.new()
	add_child(cam_rig)
	cam_spring = SpringArm3D.new()
	cam_spring.spring_length = CAM_DIST
	cam_spring.collision_mask = L_WORLD
	cam_spring.margin = 0.3
	cam_spring.rotation.x = cam_pitch
	cam_rig.add_child(cam_spring)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.1   # up from the 0.05 default — better distant depth precision (far stays 4000)
	cam_spring.add_child(cam)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


# Seat a MODEL avatar so its feet rest on the floor (y=0 at the body origin).
# Library/Meshy character GLBs often have their origin at the hips/centre, so
# without this the feet sink under the floor — props get the same treatment in
# the AreaBuilder; this is the player-side equivalent. Call after add_child().
func _seat_avatar(node: Node3D) -> void:
	node.position.y -= _subtree_aabb(node).position.y


func _subtree_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	stats = Label.new()
	stats.position = Vector2(12, 12)
	stats.add_theme_font_size_override("font_size", 18)
	stats.add_theme_color_override("font_color", Color(0.9, 1.0, 0.9))
	hud_layer.add_child(stats)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.position = Vector2(12, 120)
	bg.size = Vector2(320, 20)
	hud_layer.add_child(bg)
	hp_bg = bg
	hp_bar = ColorRect.new()
	hp_bar.color = Color(0.85, 0.25, 0.25)
	hp_bar.position = Vector2(12, 120)
	hp_bar.size = Vector2(320, 20)
	hud_layer.add_child(hp_bar)
	var vp := get_viewport().get_visible_rect().size
	_btn_attack = _button("ATTACK", vp - Vector2(250, 180), Vector2(220, 130), _attack)
	_btn_use = _button("USE", vp - Vector2(250, 330), Vector2(220, 120), func() -> void: interaction.try_use())
	_btn_potion = _button("POTION", vp - Vector2(490, 180), Vector2(220, 130), func() -> void: rpg.use_potion())
	_build_nav_ui()


func _button(text: String, pos: Vector2, sz: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 28)
	b.position = pos
	b.size = sz
	b.pressed.connect(cb)
	hud_layer.add_child(b)
	return b


# ════════════════════════ SALTWIND REACH systems ════════════════════════

# A short camera-shake on damage taken (bound to the camera node, dies with it).
func _shake_camera() -> void:
	if cam == null:
		return
	var tw := cam.create_tween()
	for i in 4:
		var off := Vector3(randf_range(-0.12, 0.12), randf_range(-0.09, 0.09), 0.0)
		tw.tween_property(cam, "position", off, 0.04)
	tw.tween_property(cam, "position", Vector3.ZERO, 0.05)

# ---------------- responsive HUD layout (phones fill the screen) ----------------

func _relayout_ui() -> void:
	if hud_layer == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var ins := _safe_insets()
	var m := maxf(16.0, float(ins.get("right", 0.0)) + 10.0)
	var ml := maxf(16.0, float(ins.get("left", 0.0)) + 10.0)
	var top := maxf(12.0, float(ins.get("top", 0.0)) + 6.0)
	var bot := maxf(30.0, float(ins.get("bottom", 0.0)) + 12.0)
	var bw := clampf(vp.x * 0.24, 150.0, 240.0)
	var bh := clampf(vp.y * 0.16, 90.0, 132.0)
	if stats != null:
		stats.position = Vector2(ml, top)
	if hp_bg != null:
		hp_bg.position = Vector2(ml, top + 78.0)
		hp_bg.size = Vector2(240.0, 14.0)
	if hp_bar != null:
		hp_bar.position = Vector2(ml, top + 78.0)
		hp_bar.size.y = 14.0
	if _btn_attack != null:
		_btn_attack.position = Vector2(vp.x - bw - m, vp.y - bh - bot)
		_btn_attack.size = Vector2(bw, bh)
	if _btn_use != null:
		_btn_use.position = Vector2(vp.x - bw - m, vp.y - bh * 2.0 - bot - 12.0)
		_btn_use.size = Vector2(bw, bh * 0.85)
	if _btn_potion != null:
		_btn_potion.position = Vector2(vp.x - bw * 2.0 - m - 12.0, vp.y - bh - bot)
		_btn_potion.size = Vector2(bw * 0.9, bh)
	if nav_root != null:
		nav_root.position = Vector2(vp.x * 0.5, top + 128.0)
	if toast_label != null:
		toast_label.position = Vector2(vp.x * 0.5 - 300.0, vp.y * 0.30)
		toast_label.size = Vector2(600.0, 60.0)


# Real device insets (notch / Dynamic Island / home indicator) via a CSS env() probe —
# requires viewport-fit=cover in the export shell (set in export_presets.cfg).
func _safe_insets() -> Dictionary:
	if not OS.has_feature("web"):
		return {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	var js := """(() => { const d = document.createElement('div'); d.style.cssText =
	  'position:fixed;top:env(safe-area-inset-top);bottom:env(safe-area-inset-bottom);left:env(safe-area-inset-left);right:env(safe-area-inset-right)';
	  document.body.appendChild(d); const r = getComputedStyle(d);
	  const o = {top:parseFloat(r.top)||0, bottom:parseFloat(r.bottom)||0, left:parseFloat(r.left)||0, right:parseFloat(r.right)||0};
	  d.remove(); return JSON.stringify(o); })()"""
	var raw: String = str(JavaScriptBridge.eval(js, true))
	if raw == "" or raw == "<null>":
		return {}
	var d = JSON.parse_string(raw)
	return d if d is Dictionary else {}


# ---------------- hero avatar (streamed Meshy character) ----------------

func _setup_avatar() -> void:
	var hm := String(world_data.get("hero_model", ""))
	if hm == "":
		return
	var u := _norm(hm)
	# retry the fetch a few times: a transient miss here would strand the whole session
	# on the placeholder capsule (the hero IS the game's face)
	for attempt in 3:
		await builder._ensure([u])
		if builder.cache.has(u) and builder.cache[u] != null:
			break
		builder.cache.erase(u)
		await get_tree().create_timer(2.0).timeout
	if not (builder.cache.has(u) and builder.cache[u] != null):
		return
	avatar = (builder.cache[u] as Node).duplicate() as Node3D
	player.add_child(avatar)
	_seat_avatar(avatar)
	for c in player.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = false   # retire the capsule placeholder
	avatar_anim = _find_ap(avatar)
	if avatar_anim != null:
		_av_clips = {
			"idle": _av_pick(["idle"]),
			"walk": _av_pick(["walk"]),
			"run": _av_pick(["run", "sprint", "jog"]),
			"attack": _av_pick(["attack", "melee", "slash", "punch", "swing"]),
			"hit": _av_pick(["hit", "hurt", "impact"]),
		}
		if String(_av_clips["walk"]) == "":
			_av_clips["walk"] = _av_clips["run"]
		if String(_av_clips["run"]) == "":
			_av_clips["run"] = _av_clips["walk"]
		_av_play("idle")


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null


func _av_pick(keys: Array) -> String:
	if avatar_anim == null:
		return ""
	for nm in avatar_anim.get_animation_list():
		var l := String(nm).to_lower()
		for k in keys:
			if String(k) in l:
				return String(nm)
	return ""


func _av_play(key: String, loop := true) -> void:
	if avatar_anim == null:
		return
	var clip := String(_av_clips.get(key, ""))
	if clip == "" or _av_cur == clip:
		return
	_av_cur = clip
	if avatar_anim.has_animation(clip):
		var a := avatar_anim.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		avatar_anim.play(clip)


func _av_oneshot(key: String) -> void:
	if avatar_anim == null:
		return
	var clip := String(_av_clips.get(key, ""))
	if clip == "":
		return
	_av_cur = clip
	if avatar_anim.has_animation(clip):
		avatar_anim.get_animation(clip).loop_mode = Animation.LOOP_NONE
		avatar_anim.play(clip)
		_av_attack_t = avatar_anim.get_animation(clip).length


# Drive the hero's gait from the ACTUAL velocity (walk vs run genuinely differ);
# paused entirely while driving / riding / seated (GPose owns the skeleton then).
func _tick_avatar(delta: float) -> void:
	if avatar_anim == null:
		return
	if active_vehicle != null or (interaction != null and interaction.player_seated):
		return
	if _av_attack_t > 0.0:
		_av_attack_t = maxf(0.0, _av_attack_t - delta)
		return
	var sp := Vector2(player.velocity.x, player.velocity.z).length()
	if sp > 4.2:
		_av_play("run")
	elif sp > 0.4:
		_av_play("walk")
	else:
		_av_play("idle")


# ---------------- soundtrack ----------------

func _start_soundtrack() -> void:
	if ResourceLoader.exists("res://audio/music_town.ogg"):
		AudioManager.play_music(load("res://audio/music_town.ogg"))
	for extra in ["secret", "success"]:
		if ResourceLoader.exists("res://audio/%s.wav" % extra):
			AudioManager.register_sfx(extra, load("res://audio/%s.wav" % extra))
	_apply_region_ambient("city")


func _apply_region_ambient(region: String) -> void:
	if region == _region:
		return
	_region = region
	var path := ""
	match region:
		"forest": path = "res://audio/amb_forest.ogg"
		"city": path = "res://audio/amb_city.ogg"
		"suburbs": path = "res://audio/amb_suburbs.ogg"
	if path != "" and ResourceLoader.exists(path):
		AudioManager.play_ambient(load(path))


# ---------------- discovery + region tracking ----------------

func _on_area_visited(area_id: String) -> void:
	if not area_id.begins_with("c"):
		return
	var gx := int(area_id.substr(1).split("_")[0])
	_apply_region_ambient("forest" if gx < 5 else ("city" if gx < 10 else "suburbs"))
	if POI.has(area_id) and not discovered.has(area_id):
		discovered[area_id] = true
		AudioManager.play_sfx("pickup", -4.0, 1.3)
		_toast("Discovered: " + String(POI[area_id]))
		_save_now()


# ---------------- toasts + banners ----------------

func _toast(text: String) -> void:
	if toast_label == null:
		return
	toast_label.text = text
	toast_label.modulate = Color(1, 1, 1, 0.0)
	var tw := toast_label.create_tween()
	tw.tween_property(toast_label, "modulate:a", 1.0, 0.25)
	tw.tween_interval(3.2)
	tw.tween_property(toast_label, "modulate:a", 0.0, 0.6)


func _on_quest_completed(id: String) -> void:
	AudioManager.play_sfx("success", 0.0, 1.0)
	var nm := String(quest.defs.get(id, {}).get("name", id))
	_toast("Quest complete: " + nm)
	if id == "ride_the_storm":
		_toast("THE EXPEDITION IS COMPLETE - Saltwind Reach is yours to roam")
	_save_now()


# ---------------- save / load ----------------

func _on_save_loaded(s: Dictionary) -> void:
	save_data = s
	expedition_name = String(s.get("name", ""))
	if expedition_name == "":
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		expedition_name = TITLES[rng.randi() % TITLES.size()] + " " + SURNAMES[rng.randi() % SURNAMES.size()]
	_build_mode_panel()


func _collect_save() -> Dictionary:
	return {
		"mode": game_mode,
		"adventure_active": adventure_active,
		"adventure_start_ms": adventure_start_ms,
		"relic_submitted": relic_submitted,
		"name": expedition_name,
		"pos": [player.global_position.x, player.global_position.y, player.global_position.z],
		"rpg": rpg.serialize(),
		"quests": quest.serialize(),
		"discovered": discovered.duplicate(),
	}


func _save_now() -> void:
	if game_mode == "" or persist == null or player == null:
		return
	persist.save(_collect_save())


func _apply_save(s: Dictionary) -> void:
	game_mode = String(s.get("mode", "explore"))
	adventure_active = bool(s.get("adventure_active", false))
	adventure_start_ms = float(s.get("adventure_start_ms", 0.0))
	relic_submitted = bool(s.get("relic_submitted", false))
	var disc = s.get("discovered", {})
	if disc is Dictionary:
		discovered = (disc as Dictionary).duplicate()
	var rd = s.get("rpg", {})
	if rd is Dictionary:
		rpg.restore(rd)
	var qd = s.get("quests", {})
	if qd is Dictionary:
		quest.restore(qd)
	quest.chain_enabled = adventure_active
	# resume exactly where they left off (wait for the streamer, then teleport)
	var p = s.get("pos", null)
	if p is Array and (p as Array).size() >= 3:
		var target := Vector3(float(p[0]), float(p[1]) + 0.6, float(p[2]))
		while chunk_manager == null or not chunk_manager._started:
			await get_tree().process_frame
		player.global_position = target
		player.velocity = Vector3.ZERO


# ---------------- play modes ----------------

func _build_mode_panel() -> void:
	if mode_layer != null:
		return
	mode_layer = CanvasLayer.new()
	mode_layer.layer = 150
	add_child(mode_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.06, 0.05, 0.03, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	mode_layer.add_child(dim)
	var centre := VBoxContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_theme_constant_override("separation", 18)
	mode_layer.add_child(centre)
	var title := Label.new()
	title.text = "SALTWIND REACH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.98, 0.86, 0.5))
	centre.add_child(title)
	var sub := Label.new()
	sub.text = "a 1930s pulp adventure - forest, city and suburbs, one seamless map"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 22)
	sub.add_theme_color_override("font_color", Color(0.9, 0.85, 0.72))
	centre.add_child(sub)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 14)
	centre.add_child(spacer)
	var has_save := save_data.has("mode") and String(save_data.get("mode", "")) != ""
	if has_save:
		var cont_label := "CONTINUE - " + String(save_data.get("mode", "")).to_upper()
		centre.add_child(_mode_btn(cont_label, "Pick up your expedition where you left it",
			func() -> void: _choose_mode("", true)))
	centre.add_child(_mode_btn("ADVENTURE", "The full quest arc - the vault, the bandits, the storm-drake",
		func() -> void: _choose_mode("adventure", false)))
	centre.add_child(_mode_btn("EXPLORE", "No objectives - the whole world and every ride from minute one",
		func() -> void: _choose_mode("explore", false)))
	var hint := Label.new()
	hint.text = "left side: drag to move   -   right side: drag to look\nwalk up to things and tap USE"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.75, 0.72, 0.62))
	centre.add_child(hint)


func _mode_btn(text: String, tip: String, cb: Callable) -> Control:
	var wrap := VBoxContainer.new()
	wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(360, 74)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 30)
	b.pressed.connect(cb)
	wrap.add_child(b)
	var t := Label.new()
	t.text = tip
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 16)
	t.add_theme_color_override("font_color", Color(0.72, 0.68, 0.58))
	wrap.add_child(t)
	return wrap


func _choose_mode(mode: String, from_save: bool) -> void:
	if mode_layer != null:
		mode_layer.queue_free()
		mode_layer = null
	AudioManager.play_sfx("ui")
	if from_save:
		await _apply_save(save_data)
		if adventure_active:
			_toast("Welcome back, " + expedition_name)
		else:
			_toast("Welcome back to Saltwind Reach, " + expedition_name)
	else:
		game_mode = mode
		if mode == "adventure":
			begin_adventure()
		else:
			_toast("Saltwind Reach is open - every ride is yours. The tavern keeper has a story, when you want it.")
	_check_gated_vehicles()
	_apply_enemy_mood()
	_save_now()


func begin_adventure() -> void:
	if adventure_active:
		return
	adventure_active = true
	quest.chain_enabled = true
	quest.start("word_at_the_tavern")
	if adventure_start_ms <= 0.0:
		adventure_start_ms = Time.get_unix_time_from_system() * 1000.0
	_toast("THE EXPEDITION BEGINS - the clock is running, " + expedition_name)
	_apply_enemy_mood()
	_save_now()


# Explore-mode hook: talking to the tavern keeper starts the Adventure (no restart needed).
func on_npc_talked(npc_id: String) -> void:
	if npc_id == "keeper" and game_mode == "explore" and not adventure_active:
		begin_adventure()


# Enemies hold their camps in Explore until the adventure starts (or they're provoked).
func _apply_enemy_mood() -> void:
	var streamer = chunk_manager if chunk_mode else scene_manager
	if streamer == null:
		return
	var calm := game_mode == "explore" and not adventure_active
	for e in streamer.enemies:
		if is_instance_valid(e):
			e.passive = calm


# ---------------- RELIC HUNTERS leaderboard ----------------

func show_leaderboard() -> void:
	if board_layer != null:
		return
	AudioManager.play_sfx("ui")
	board_layer = CanvasLayer.new()
	board_layer.layer = 140
	add_child(board_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.02, 0.9)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	board_layer.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	board_layer.add_child(box)
	var title := Label.new()
	title.text = "RELIC HUNTERS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(0.98, 0.86, 0.5))
	box.add_child(title)
	var sub := Label.new()
	sub.text = "fastest expeditions to recover the Sunstone"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.85, 0.8, 0.66))
	box.add_child(sub)
	var rows_label := Label.new()
	rows_label.text = "consulting the ledger..."
	rows_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows_label.add_theme_font_size_override("font_size", 24)
	box.add_child(rows_label)
	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size = Vector2(220, 64)
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.add_theme_font_size_override("font_size", 26)
	close.pressed.connect(func() -> void:
		if board_layer != null:
			board_layer.queue_free()
			board_layer = null)
	box.add_child(close)
	var handler := func(rows: Array) -> void:
		if rows_label == null or not is_instance_valid(rows_label):
			return
		if rows.is_empty():
			rows_label.text = "No expedition has claimed the Sunstone yet.\nYours could be the first name on this plaque."
			return
		var lines: Array = []
		var i := 1
		for r in rows:
			if r is Dictionary:
				lines.append("%2d.  %s   %s" % [i, String(r.get("name", "?")), _fmt_time(float(r.get("seconds", 0.0)))])
				i += 1
		rows_label.text = "\n".join(lines)
	persist.leaderboard_ready.connect(handler, CONNECT_ONE_SHOT)
	persist.fetch_leaderboard()


func _fmt_time(secs: float) -> String:
	var m := int(secs) / 60
	var s := fmod(secs, 60.0)
	return "%d:%04.1f" % [m, s]


# ---------------- objective nav aid ----------------

func _nav_target() -> Dictionary:
	if quest == null:
		return {}
	for id in quest.defs:
		if String(quest.st[id].status) != "active":
			continue
		for step in quest.defs[id].get("steps", []):
			if quest._step_done(id, step.get("objective", {})):
				continue
			var nv = step.get("nav", null)
			if nv is Array and (nv as Array).size() >= 2:
				return {"pos": Vector2(float(nv[0]), float(nv[1])), "desc": String(step.get("desc", ""))}
			return {}
	return {}


func _tick_nav() -> void:
	if nav_root == null or player == null:
		return
	var t := _nav_target()
	if t.is_empty():
		nav_root.visible = false
		return
	nav_root.visible = true
	var tp: Vector2 = t["pos"]
	var to := tp - Vector2(player.global_position.x, player.global_position.z)
	var dist := to.length()
	var fwd3 := Basis(Vector3.UP, cam_yaw) * Vector3(0, 0, -1)
	var fwd := Vector2(fwd3.x, fwd3.z)
	nav_arrow.rotation = fwd.angle_to(to)
	nav_label.text = String(t["desc"]) + "  (" + str(int(dist)) + "m)"


func _build_nav_ui() -> void:
	nav_root = Control.new()
	nav_root.visible = false
	hud_layer.add_child(nav_root)
	nav_arrow = Polygon2D.new()
	nav_arrow.polygon = PackedVector2Array([Vector2(0, -16), Vector2(11, 10), Vector2(0, 4), Vector2(-11, 10)])
	nav_arrow.color = Color(0.98, 0.86, 0.5)
	nav_root.add_child(nav_arrow)
	nav_label = Label.new()
	nav_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav_label.add_theme_font_size_override("font_size", 19)
	nav_label.add_theme_color_override("font_color", Color(0.98, 0.9, 0.65))
	nav_label.position = Vector2(-220, 18)
	nav_label.size = Vector2(440, 26)
	nav_root.add_child(nav_label)
	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 26)
	toast_label.add_theme_color_override("font_color", Color(0.98, 0.9, 0.6))
	toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	toast_label.add_theme_constant_override("outline_size", 8)
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.modulate = Color(1, 1, 1, 0)
	hud_layer.add_child(toast_label)
