class_name Vehicle extends CharacterBody3D
## BOARDABLE VEHICLES & MOUNTS (v3 — Wave 3 "motion profiles + mounts") — a world-level "vehicles"
## entry the player can walk up to, BOARD, and DRIVE/RIDE:
##   "vehicles": [{"pos": [x, z], "name": "...", "profile": "car"|"tank"|"boat"|"plane"|"horse"|
##                 "bull"|"dragon" (default "car"), "color": [r, g, b], "model": "<optional>"}]
## main.gd spawns these ONCE at boot onto the PERSISTENT layer (never cell-parented — chunk
## eviction and zone transitions can't touch them). The body is a CharacterBody3D with a box
## collider derived from the composed/scale-normalised AABB, so buildings/walls stop it
## (move_and_slide) while y terrain-follows the rendered surface via GTerrain.height. While
## driving, main.gd feeds its EXISTING input vector here and the player is parked ON the
## boardable every physics tick — so chunk streaming and reach_area quest notifications (both
## read player.global_position) follow the DRIVEN position with no extra wiring.
##
## PROFILES (Wave 3):
##   car    — Wave-2 articulated parametric car, byte-equivalent behavior (door choreography).
##   tank   — turn-in-place tracks; parametric hull/glacis/turret body; door-less Wave-1 style
##            swap-in boarding (hatch choreography is OUT OF SCOPE v1 — the driver is hidden,
##            exactly the Wave-1 fused-GLB idiom).
##   boat   — rides the WATER LEVEL (set_water) with a small bob, not the terrain; a world with
##            NO water degrades to car-on-terrain. Step-in boarding (no door) + GPose.sit.
##   plane  — arcade flight: car-like taxi, lift-off above takeoff speed, pitch/bank in the air,
##            SPEED_MAX 22 / ALT_MAX 32 envelope, lands when terrain-relative height < 0.5.
##            Step-in boarding + GPose.sit. Cosmetic spinning prop disc.
##   horse / bull / dragon — MOUNTS: no parametric body; "model" omitted resolves a LIBRARY
##            DEFAULT (main.gd asks Vehicle.default_model_path). Rider is VISIBLE, parked on a
##            "MountMarker" (AABB top centre, 25% back) and posed astride via GPose.ride. Gait
##            sync plays the model's EMBEDDED clips (walk/gallop/idle; dragon flap/glide) —
##            clipless creatures still ride, silently un-animated. Dragon shares the plane's
##            flight envelope and walks when landed.
##
## BODY MODES (decided by the SPEC, not by fetch success):
##   - VEHICLE profiles, "model" OMITTED  -> the profile's PARAMETRIC body (GShapes + GSurf).
##   - VEHICLE profiles, "model" PRESENT  -> the Wave-1 fused-GLB swap-in, byte-identical:
##     instant hide + attach, no choreography (a modeled tank GLB drives with tank physics but
##     boards swap-in style).
##   - MOUNT profiles -> ALWAYS the model path (library default or spec model) and ALWAYS the
##     mount boarding (visible rider at the MountMarker) — a mount has no cabin to hide in, so
##     the fused-GLB "hide the driver" fallback would strand an invisible rider on its back.
##
## HOT-RELOAD SAFETY: main.gd calls exit() before freeing. exit() mid-ENTER is guarded (no-op),
## exit() mid-FLIGHT is a guarded no-op too (no mid-air dismounts — the chunk movement contract
## has no gravity, a dropped player would float), and _exit_tree() force-restores the driver
## (pose/visibility/collision/position AT TERRAIN HEIGHT) if the node is freed mid-choreography,
## mid-drive or mid-flight, so a chat edit can never strand a hidden, posed or airborne player.

# Per-profile tuning. max_speed/accel/brake/turn_rate are the GROUND (or water) gait; flight
# uses the shared SPEED_MAX/ALT_MAX envelope below. Flags: steer_fixed (turn-in-place, steering
# NOT scaled by speed), water (rides the water level), fly (has the flight model, "takeoff" =
# lift-off speed), mount (creature: model path + MountMarker + GPose.ride + gait sync).
const PROFILES := {
	"car": {
		"length": 4.0,       # longest horizontal dim after scale-normalisation (same idiom as traffic)
		"max_speed": 12.0,   # m/s
		"accel": 14.0,       # m/s^2 toward the throttle target
		"brake": 22.0,       # m/s^2 shedding speed (throttle released / reversed)
		"turn_rate": 2.0,    # rad/s at full speed — scaled by speed so a parked car can't pirouette
		"exit_side": 2.0,    # metres to the vehicle's side where the driver steps out
		"board": "door",     # parametric boarding style (model-present always boards instant)
	},
	"tank": {
		"length": 5.2, "max_speed": 7.0, "accel": 6.0, "brake": 14.0,
		"turn_rate": 1.6, "exit_side": 2.4, "board": "instant",
		"steer_fixed": true,   # TURN-IN-PLACE: steering works at zero speed, never speed-scaled
	},
	"boat": {
		"length": 5.5, "max_speed": 9.0, "accel": 4.0, "brake": 6.0,   # slow spool-up, drifty stop
		"turn_rate": 1.6, "exit_side": 2.2, "board": "step",
		"water": true,       # y = water level (+bob) when the world has water; else terrain (car-like)
	},
	"plane": {
		"length": 7.0, "max_speed": 14.0, "accel": 8.0, "brake": 16.0,   # ground TAXI numbers
		"turn_rate": 1.2, "exit_side": 2.8, "board": "step",             # slower taxi turn than a car
		"fly": true, "takeoff": 9.0,   # throttle-held above 9 m/s lifts off (pinned envelope)
	},
	"horse": {
		"length": 2.2, "max_speed": 10.0, "accel": 8.0, "brake": 12.0,   # gallop feel
		"turn_rate": 2.4, "exit_side": 1.6, "board": "mount", "mount": true,
	},
	"bull": {
		"length": 2.2, "max_speed": 8.0, "accel": 5.0, "brake": 10.0,    # heavier
		"turn_rate": 1.4, "exit_side": 1.6, "board": "mount", "mount": true,   # slight turn resistance
	},
	"dragon": {
		"length": 4.5, "max_speed": 7.0, "accel": 6.0, "brake": 10.0,    # GROUND walk when landed
		"turn_rate": 1.8, "exit_side": 3.0, "board": "mount", "mount": true,
		"fly": true, "takeoff": 6.0,   # a dragon leaps from a run — its walk gait tops out at 7,
	},                                 # so the plane's 9.0 runway threshold would be unreachable
}
# LIBRARY DEFAULTS for mount models ("model" omitted). main.gd resolves these to absolute URLs
# via its _norm (they are bare library paths like the traffic set); all three exist, rig:true.
const MOUNT_MODELS := {
	"horse": "animals/farm_Horse.glb",
	"bull": "animals/farm_Cow.glb",
	"dragon": "animals/monster_Dragon.glb",
}
const PROMPT_RANGE := 2.8    # metres — the floating DRIVE/RIDE label range (~the interaction 2.9 use range)
const GROUND_LIFT := 0.1     # ride just above the surface (same cue as TrafficCar's +0.12)
const SNAP_RATE := 10.0      # y-lerp rate onto the terrain (fast enough to hug, soft enough not to pop)

# --- shared FLIGHT ENVELOPE (plane + dragon) — pinned Wave-3 numbers ---
const SPEED_MAX := 22.0            # m/s airborne top speed (<1.2 cells/s at cell_size 20 — streaming keeps up)
const ALT_MAX := 32.0              # metres above the LOCAL terrain (soft ceiling)
const PITCH_MAX_DEG := 35.0        # visual + kinematic pitch clamp
const ROLL_MAX_DEG := 40.0         # visual bank clamp
const PITCH_RATE := 1.2            # rad/s pitch slew toward the input target
const ROLL_RATE := 3.0             # rad/s visual roll slew
const AIR_TURN := 1.1              # rad/s yaw while banked (not speed-scaled — arcade)
# AIR_ACCEL: m/s^2 toward SPEED_MAX while airborne. Throttle is IMPLICIT (cruise power always
# on): airborne input.y is PITCH, so there is no lever left to map to power — arcade contract.
const AIR_ACCEL := 6.0
const CEIL_BAND := 6.0             # metres below ALT_MAX where the allowed climb fades to zero
const GROUNDED_H := 0.5            # terrain-relative height below which a DESCENDING flyer lands
const PROP_SPIN := 30.0            # rad/s cosmetic prop-disc spin while driving

# --- water ride (boat) ---
const BOB_AMP := 0.15              # small bob = 0.15 * sin(time * 1.2) (pinned)
const BOB_HZ := 1.2

# --- mount gait sync ---
const GAIT_MOVE_MIN := 0.5         # |speed| above this plays the move clip
const GAIT_FAST_FRAC := 0.55       # fraction of max_speed above which gallop/run wins over walk

# --- enter/exit state machine (choreographed boards; instant boards jump straight IDLE<->DRIVING) ---
const S_IDLE := 0
const S_ENTERING := 1
const S_DRIVING := 2
const S_EXITING := 3

# --- parametric body tuning ---
const BODY_COLOR_DEFAULT := Color(0.72, 0.16, 0.14)   # warm red (spec "color": [r,g,b] overrides)
const TANK_COLOR_DEFAULT := Color(0.32, 0.36, 0.25)   # olive drab
const BOAT_COLOR_DEFAULT := Color(0.85, 0.87, 0.90)   # white gelcoat
const PLANE_COLOR_DEFAULT := Color(0.78, 0.80, 0.84)  # silver
const DOOR_OPEN_DEG := -70.0   # hinge swing about local +Y; negative = outward on the +X (driver/left) side
const DOOR_TIME := 0.35        # seconds per door swing (open and close)
const WALK_TIME := 0.4         # seconds for the driver's walk-to-seat / step-out position tween
const SEAT_TOP := 0.58         # y of the car cushion top = its "SeatMarker" height (car-local)
const HIP_RATIO := 0.52        # hip height ≈ 52% of a standing humanoid's AABB height (seat drop)

# Emitted on enter/exit so main.gd can track the active vehicle (input routing + camera-arm exclusion).
# Choreographed boards emit `true` at sequence START (camera switch + control lockout, Wave-1
# behavior) and `false` at exit-sequence END.
signal drive_state_changed(vehicle: Vehicle, is_driving: bool)

var profile := "car"
var display_name := "Car"
var terrain: GTerrain = null    # set via set_terrain() after the streamer boots; null = flat world (y=0)
var player_ref: Node3D = null   # for the floating DRIVE/RIDE prompt proximity check (set by main at spawn)
var driving := false            # public Wave-1 flag: true from enter-start until exit completes
var water_level := 0.0          # the world's GWater level (set_water) — boats float here

var _state := S_IDLE
var _driver: CharacterBody3D = null
var _speed := 0.0               # signed m/s along -basis.z (negative = reversing)
var _input := Vector2.ZERO      # main.gd's shared input vector (x = steer, y = throttle, screen-up = -y)
var _label: Label3D = null
var _height := 1.6              # scaled model height (roof) — the floating label sits above it
var _snapped := false           # first ground snap is instant (no boot-time rise-from-y=0 lerp)
var _has_water := false         # set_water was called (the world HAS a water block)
var _time := 0.0                # local clock for the boat bob

# --- body/boarding wiring ---
var _parametric := false                  # a parametric VEHICLE body was built (never true for mounts)
var _water_rest := false                  # rests on the water surface (boat profile, or spec "water": true — a seaplane)
var _is_mount := false                    # horse/bull/dragon — model path + MountMarker + GPose.ride
var _board := "door"                      # "door" | "step" | "instant" | "mount"
var _board_local := Vector3(1.45, 0.0, -0.15)   # boarding spot beside the body (self-local, ground level)
var _visual: Node3D = null                # the body subtree that takes the cosmetic flight pitch/roll
var _seat_marker: Node3D = null           # "SeatMarker" — cushion-top centre where the seated hips rest
var _mount_marker: Node3D = null          # "MountMarker" — mount AABB top centre, 25% back (rider hips)
var _door_pivot: Node3D = null            # "DoorPivot" — hinge at the door opening's FRONT edge (car only)
var _door_shape: CollisionShape3D = null  # the leaf's blocking collider (disabled while open/driving)
var _door_body: StaticBody3D = null
var _prop: MeshInstance3D = null          # "PropDisc" — cosmetic spinner (plane parametric body)
var _seq: Tween = null                    # the running enter/exit choreography
var _seated := false                      # GPose.sit/ride succeeded — driver rides the marker, visible
var _seat_y_off := 0.0                    # driver-origin drop below the marker (per-rig hip height)

# --- flight state (plane + dragon) ---
var _airborne := false
var _pitch := 0.0               # radians, POSITIVE = climb (screen-up / W = climb; see _drive_air)
var _roll := 0.0                # radians, visual bank

# --- mount gait sync (embedded clips only; "" = clip absent -> silent degrade) ---
var _gait_ap: AnimationPlayer = null
var _clip_walk := ""            # substring "walk"
var _clip_fast := ""            # substring "gallop"/"run"
var _clip_idle := ""            # substring "idle" -> rest
var _clip_flap := ""            # substring "fly"/"flap" -> airborne move
var _clip_glide := ""           # substring "glide" -> airborne level/descending


# The library-default model for a profile whose spec omits "model" — main.gd calls this from its
# _vehicle_model_url so mounts fetch their creature GLB instead of the default sedan. Returns ""
# for VEHICLE profiles: those build a parametric body and need no fetch at all.
static func default_model_path(profile_name: String) -> String:
	return String(MOUNT_MODELS.get(profile_name, ""))


# Build the body from a world.json vehicle spec + an (optional) model duplicated from the builder
# cache. Called BEFORE the node enters the tree; main positions it afterwards.
func setup(spec: Dictionary, model: Node3D) -> void:
	profile = String(spec.get("profile", "car"))
	if not PROFILES.has(profile):
		profile = "car"
	var p: Dictionary = PROFILES[profile]
	_is_mount = bool(p.get("mount", false))
	# a boat rests on water by profile; any other ride can OPT IN via the spec (a moored seaplane)
	_water_rest = bool(p.get("water", false)) or bool(spec.get("water", false))
	display_name = String(spec.get("name", profile.capitalize() if _is_mount else "Car"))
	# world layer so the player bumps into a parked boardable; world mask so walls/buildings stop it
	collision_layer = 1
	collision_mask = 1
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING   # y is ours (terrain/water/flight) — no floor magic
	# THE SPEC decides the body mode. VEHICLE profiles: no "model"/"url"/"asset" key -> the
	# profile's parametric body; a model key present -> the Wave-1 fused-GLB swap-in path
	# (placeholder box fallback included when the fetch failed). MOUNT profiles ALWAYS take the
	# model path — main resolves the library default (default_model_path) when the spec omits one.
	_parametric = (not _is_mount) and not (spec.has("model") or spec.has("url") or spec.has("asset"))
	# Boarding style: mounts always mount-board (visible rider); parametric vehicles use their
	# profile's style ("door" car / "step" boat+plane / "instant" tank); modeled vehicles board
	# instant (Wave-1 swap-in — a fused GLB has no interior to choreograph into).
	if _is_mount:
		_board = "mount"
	elif _parametric:
		_board = String(p.get("board", "door"))
	else:
		_board = "instant"
	var body_ab: AABB
	if _parametric:
		if model != null:
			model.free()   # unused duplicate from main's default-model resolve (never entered the tree)
		match profile:
			"tank":
				body_ab = _build_parametric_tank(spec)
			"boat":
				body_ab = _build_parametric_boat(spec)
			"plane":
				body_ab = _build_parametric_plane(spec)
			_:
				body_ab = _build_parametric(spec)   # the Wave-2 car, unchanged
	else:
		body_ab = _mount_model(model)
	if _is_mount:
		_setup_mount(body_ab)
	_height = maxf(0.8, body_ab.size.y)
	# box collider from the composed/scaled AABB, centred on it (GLB origins are rarely dead-centre)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(0.5, body_ab.size.x), maxf(0.5, body_ab.size.y), maxf(0.5, body_ab.size.z))
	cs.shape = box
	cs.position = body_ab.position + body_ab.size * 0.5
	add_child(cs)
	# floating DRIVE/EXIT (RIDE/DISMOUNT for mounts) prompt over the roof (billboarded, the
	# add_sign idiom). ACTIVATION runs through the interaction system's USE mechanism — this
	# label is the visual affordance only.
	_label = Label3D.new()
	_label.font_size = 48
	_label.pixel_size = 0.012
	_label.modulate = Color(1.0, 1.0, 0.6)
	_label.outline_size = 12
	_label.outline_modulate = Color(0, 0, 0, 0.8)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position = Vector3(0.0, _height + 0.8, 0.0)
	_label.visible = false
	add_child(_label)


# A parked mount idles (clip resolution already done in _setup_mount); play() outside the tree is
# deferred by the engine until processing starts, but _ready is the unambiguous place.
func _ready() -> void:
	if _gait_ap != null and _clip_idle != "":
		_play_clip(_clip_idle, 1.0)


# Mount the model: scale-normalise the longest HORIZONTAL dim to the profile length (the same
# idiom the traffic cars use — horse/bull ~2.2m, dragon ~4.5m, vehicles per their table), then
# AABB-ground it (base -> origin, drop-only). Falls back to a simple box body when the GLB isn't
# in the cache, so the boardable still works. Returns the final local AABB the collider is
# derived from.
func _mount_model(model: Node3D) -> AABB:
	var target_len := float(PROFILES[profile]["length"])
	if model != null:
		var ab := _world_aabb(model)
		var dim := maxf(ab.size.x, ab.size.z)
		if dim > 0.001:
			model.scale *= target_len / dim
		ab = _world_aabb(model)
		model.position.y = -maxf(0.0, ab.position.y)   # base -> origin (drop-only, traffic idiom)
		add_child(model)
		_visual = model
		return _world_aabb(model)
	# placeholder body (model missing) — still boardable, clearly a body-sized box
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(target_len * 0.45, 1.3, target_len)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.75, 0.2, 0.2)
	mi.material_override = m
	mi.position.y = 0.65
	add_child(mi)
	_visual = mi
	return AABB(Vector3(bm.size.x * -0.5, 0.0, bm.size.z * -0.5), bm.size)


# Mount extras, computed at setup from the FINAL (scaled, grounded) AABB:
#   - "MountMarker": rider hips rest here — AABB top centre, 25% of the length BACK (forward is
#     +Z in this stack, so back = -Z).
#   - boarding spot: on the ground beside the creature's flank at the marker's z.
#   - gait AnimationPlayer + clip resolution by NAME SUBSTRING (pinned Wave-3 names). Library
#     animals and rig-lab outputs both carry EMBEDDED clips; a clipless creature leaves every
#     clip "" and rides silently un-animated.
func _setup_mount(ab: AABB) -> void:
	var centre := ab.position + ab.size * 0.5
	_mount_marker = Node3D.new()
	_mount_marker.name = "MountMarker"
	_mount_marker.position = Vector3(centre.x, ab.end.y, centre.z - 0.25 * ab.size.z)
	add_child(_mount_marker)
	_board_local = Vector3(ab.end.x + 0.5, 0.0, _mount_marker.position.z)
	_gait_ap = _find_anim(self)
	if _gait_ap != null:
		_clip_walk = _match_clip(["walk"])
		_clip_fast = _match_clip(["gallop", "run"])
		_clip_idle = _match_clip(["idle"])
		_clip_flap = _match_clip(["fly", "flap"])
		_clip_glide = _match_clip(["glide"])


# ---------------- parametric bodies (VEHICLE profiles, spec "model" omitted) ----------------

# The articulated default car (Wave 2, unchanged): GShapes boxes/cylinders + GSurf triplanar
# materials. Grounded (base y=0), forward +Z (Wave-1 convention), so the LEFT/driver side is +X —
# which is exactly where Wave-1's exit_side (+basis.x) already steps the driver out. Cabin is a
# composed CAVITY (floor/walls/dash/roof panels, open where the door is) with two seats, a dash,
# a steering wheel, and a "SeatMarker" Node3D on the cushion top. The driver-side DOOR LEAF
# hinges at its FRONT edge ("DoorPivot"), carries its own StaticBody3D collider (collision-
# excepted from this body, disabled while open or driving), and is NOT in the "gogi_door" group —
# building-door consumers must never discover a car door. Returns the composed local AABB
# (door closed).
func _build_parametric(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, BODY_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.35, "metal": 0.25, "bump": 0.0, "tile": 6.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "CarBody"
	add_child(root)
	_visual = root
	# shell — hood/trunk/bumpers around an open cabin (z -1.225 .. 0.95, belt line y 1.05)
	_part(root, Vector3(1.5, 0.30, 0.18), Vector3(0.0, 0.45, 1.93), trim)     # front bumper
	_part(root, Vector3(1.5, 0.30, 0.18), Vector3(0.0, 0.45, -1.93), trim)    # rear bumper
	_part(root, Vector3(1.5, 0.42, 1.0), Vector3(0.0, 0.55, 1.45), paint)     # hood
	_part(root, Vector3(1.5, 0.55, 0.75), Vector3(0.0, 0.62, -1.60), paint)   # trunk
	_part(root, Vector3(1.5, 0.10, 2.4), Vector3(0.0, 0.35, -0.15), trim)     # cabin floor
	_part(root, Vector3(0.07, 0.65, 2.1), Vector3(-0.765, 0.725, -0.15), paint)    # right wall (solid)
	_part(root, Vector3(0.07, 0.65, 0.48), Vector3(0.765, 0.725, -0.99), paint)    # left wall behind the door
	_part(root, Vector3(0.07, 0.65, 0.40), Vector3(0.765, 0.725, 0.75), paint)     # left wall ahead of the door
	for sx in [-1.0, 1.0]:   # window-band pillars up to the roof
		_part(root, Vector3(0.07, 0.21, 0.14), Vector3(0.765 * sx, 1.155, -1.15), trim)
		_part(root, Vector3(0.07, 0.21, 0.14), Vector3(0.765 * sx, 1.155, 0.88), trim)
	_part(root, Vector3(1.6, 0.09, 2.2), Vector3(0.0, 1.30, -0.15), paint)    # roof
	var shield := _part(root, Vector3(1.44, 0.62, 0.05), Vector3(0.0, 1.00, 1.02), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-28.0)   # raked back toward the roof
	var rear_glass := _part(root, Vector3(1.44, 0.50, 0.05), Vector3(0.0, 1.02, -1.24), glass)
	rear_glass.rotation.x = deg_to_rad(30.0)
	# interior — dash, steering wheel, two seats, the SeatMarker
	_part(root, Vector3(1.40, 0.22, 0.35), Vector3(0.0, 0.86, 0.72), trim)    # dash block
	var wheel := GShapes.cylinder(0.17, 0.17, 0.05, 20)
	GShapes.set_material(wheel, tire)
	wheel.position = Vector3(0.38, 0.95, 0.50)
	wheel.rotation.x = deg_to_rad(65.0)   # tilted toward the driver
	root.add_child(wheel)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.60, 0.16, 0.55), Vector3(0.38 * sx, 0.50, -0.15), cloth)          # cushion
		var back := _part(root, Vector3(0.60, 0.55, 0.12), Vector3(0.38 * sx, 0.82, -0.47), cloth)
		back.rotation.x = deg_to_rad(-8.0)                                                       # recline
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.38, SEAT_TOP, -0.15)   # driver cushion top — hips rest here
	root.add_child(_seat_marker)
	# lights (emissive fills, NOT OmniLights — no light budget spent on cars)
	var head_mat := GSurf.emissive(Color(1.0, 0.95, 0.75), 1.4)
	var tail_mat := GSurf.emissive(Color(0.9, 0.10, 0.08), 1.4)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.28, 0.12, 0.06), Vector3(0.48 * sx, 0.62, 1.96), head_mat)
		_part(root, Vector3(0.25, 0.10, 0.06), Vector3(0.52 * sx, 0.72, -1.99), tail_mat)
	# wheels — cylinders lying on their sides (axis along X)
	for wp in [Vector3(0.78, 0.32, 1.25), Vector3(-0.78, 0.32, 1.25), Vector3(0.78, 0.32, -1.25), Vector3(-0.78, 0.32, -1.25)]:
		var wh := GShapes.cylinder(0.32, 0.32, 0.24, 18)
		GShapes.set_material(wh, tire)
		wh.position = wp
		wh.rotation.z = PI * 0.5
		root.add_child(wh)
	# the driver-side DOOR — hinge pivot at the opening's FRONT edge, leaf swings outward (+X)
	_door_pivot = Node3D.new()
	_door_pivot.name = "DoorPivot"
	_door_pivot.position = Vector3(0.795, 0.40, 0.55)
	root.add_child(_door_pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	_door_pivot.add_child(leaf)
	var leaf_mi := GShapes.box(Vector3(0.07, 0.65, 1.30))
	GShapes.set_material(leaf_mi, paint)
	leaf_mi.position = Vector3(0.0, 0.325, -0.65)
	leaf.add_child(leaf_mi)
	var handle := GShapes.box(Vector3(0.04, 0.05, 0.16))
	GShapes.set_material(handle, trim)
	handle.position = Vector3(0.06, 0.50, -1.05)
	leaf.add_child(handle)
	_door_body = StaticBody3D.new()
	_door_body.name = "DoorBody"
	_door_body.collision_layer = 1
	var dcs := CollisionShape3D.new()
	var dbs := BoxShape3D.new()
	dbs.size = Vector3(0.07, 0.65, 1.30)
	dcs.shape = dbs
	dcs.position = Vector3(0.0, 0.325, -0.65)
	_door_body.add_child(dcs)
	leaf.add_child(_door_body)
	_door_shape = dcs
	add_collision_exception_with(_door_body)   # the car must never move_and_slide against its own door
	_board_local = Vector3(1.45, 0.0, -0.15)   # on the ground just outside the open door
	return _world_aabb(root)


# The parametric TANK: hull box + sloped glacis (ramp wedge) + dark track skirts low on the
# sides + a rotating-look turret group (ring cylinder + box) + a thin long barrel forward +Z.
# The turret is grouped under one "Turret" Node3D so a later wave can aim it — v1 is COSMETIC
# (no aiming). No door, no SeatMarker: tank boarding is the Wave-1 swap-in (driver hidden);
# hatch choreography is OUT OF SCOPE v1. Grounded (base y=0), forward +Z.
func _build_parametric_tank(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, TANK_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.7, "metal": 0.3, "bump": 0.0, "tile": 5.0})
	var track := GSurf.surface({"color": [0.09, 0.09, 0.10], "rough": 0.95, "metal": 0.1, "bump": 0.0, "tile": 4.0})
	var root := Node3D.new()
	root.name = "TankBody"
	add_child(root)
	_visual = root
	# track skirts — dark boxes LOW on the sides (they read as the running gear)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.60, 0.55, 5.0), Vector3(0.95 * sx, 0.35, 0.0), track)
	# hull slab between/above the tracks (top at y 1.15)
	_part(root, Vector3(1.9, 0.60, 4.4), Vector3(0.0, 0.85, -0.20), paint)
	# sloped GLACIS: GShapes.ramp rises along +X; rotation.y = +90° maps +X -> -Z (basis rotation:
	# x' = (cos90, 0, -sin90) = -Z), so the slope rises toward -Z = up toward the hull top, with
	# the low edge at +Z = the nose. Width (pre-rotation Z) becomes the X span.
	var glacis := GShapes.ramp(0.9, 0.55, 1.9)
	GShapes.set_material(glacis, paint)
	glacis.position = Vector3(0.0, 0.875, 2.30)   # centre: y 0.6..1.15, z 1.85..2.75
	glacis.rotation.y = PI * 0.5
	root.add_child(glacis)
	# rear plate
	_part(root, Vector3(1.9, 0.35, 0.30), Vector3(0.0, 0.70, -2.35), paint)
	# TURRET group — ring cylinder + turret box + barrel, one pivot for future aiming
	var turret := Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0.0, 1.15, -0.30)   # sits on the hull top
	root.add_child(turret)
	var ring := GShapes.cylinder(0.85, 0.75, 0.22, 20)
	GShapes.set_material(ring, paint)
	ring.position = Vector3(0.0, 0.11, 0.0)   # centre-positioned (overwrites base-lift; _part idiom)
	turret.add_child(ring)
	var tbox := GShapes.box(Vector3(1.35, 0.50, 1.70))
	GShapes.set_material(tbox, paint)
	tbox.position = Vector3(0.0, 0.47, -0.05)
	turret.add_child(tbox)
	# barrel — thin long cylinder FORWARD +Z: rotation.x = +90° maps the cylinder's +Y axis to +Z
	# ((0,1,0) -> (0, cos90, sin90) = (0,0,1)), so its length lies along the heading.
	var barrel := GShapes.cylinder(0.07, 0.06, 2.3, 12)
	GShapes.set_material(barrel, track)
	barrel.position = Vector3(0.0, 0.42, 1.85)   # turret-local: from the turret face out past the nose
	barrel.rotation.x = PI * 0.5
	turret.add_child(barrel)
	return _world_aabb(root)


# The parametric BOAT: box hull with a V-keel wedge + raked bow ramp + deck + small fore cabin +
# raked windshield + open cockpit seat with a "SeatMarker". No door — boarding is the step-in
# choreography. Grounded at base y=0 (the WATER ride puts the waterline partway up the keel).
func _build_parametric_boat(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, BOAT_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.3, "metal": 0.1, "bump": 0.0, "tile": 5.0})
	var deck_mat := GSurf.surface({"color": [0.55, 0.42, 0.28], "rough": 0.8, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "BoatBody"
	add_child(root)
	_visual = root
	# hull slab (freeboard) + V-KEEL: a wedge flipped upside down (rotation.z = PI turns the
	# gable peak downward), so the ridge line runs along Z at y=0 — the keel.
	_part(root, Vector3(1.9, 0.65, 4.4), Vector3(0.0, 0.50, -0.30), paint)
	var keel := GShapes.wedge(Vector3(1.9, 0.35, 4.4))
	GShapes.set_material(keel, paint)
	keel.position = Vector3(0.0, 0.18, -0.30)   # centre: peak (keel) at ~y 0, merging into the hull
	keel.rotation.z = PI
	root.add_child(keel)
	# raked BOW: same ramp-rotation trace as the tank glacis (rotation.y = +90° -> rises toward -Z),
	# so the low edge points forward at +Z — the nose — and the top meets the deck.
	var bow := GShapes.ramp(1.3, 0.60, 1.9)
	GShapes.set_material(bow, paint)
	bow.position = Vector3(0.0, 0.55, 2.20)
	bow.rotation.y = PI * 0.5
	root.add_child(bow)
	# deck + gunwale rails
	_part(root, Vector3(1.7, 0.10, 4.2), Vector3(0.0, 0.88, -0.35), deck_mat)
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.08, 0.25, 4.2), Vector3(0.88 * sx, 1.00, -0.35), paint)
	# small FORE cabin (cuddy) + windshield raked back toward the cockpit
	_part(root, Vector3(1.5, 0.70, 1.5), Vector3(0.0, 1.25, 1.00), paint)
	var shield := _part(root, Vector3(1.3, 0.50, 0.05), Vector3(0.0, 1.62, 0.15), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-22.0)
	# helm console + cockpit seat + SeatMarker
	_part(root, Vector3(0.9, 0.45, 0.35), Vector3(0.0, 1.10, 0.28), trim)
	_part(root, Vector3(0.60, 0.16, 0.55), Vector3(0.0, 1.00, -0.60), cloth)          # cushion
	var back := _part(root, Vector3(0.60, 0.50, 0.12), Vector3(0.0, 1.30, -0.92), cloth)
	back.rotation.x = deg_to_rad(-8.0)
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.0, 1.08, -0.60)   # cushion top — hips rest here
	root.add_child(_seat_marker)
	_board_local = Vector3(1.35, 0.0, -0.60)   # step in beside the cockpit
	return _world_aabb(root)


# The parametric PLANE: tapered cylinder fuselage (capsule-ish, fat nose / thin tail after the
# +90° X rotation maps the cylinder's +Y to +Z), thin wide straight wings, tailplane + fin, a
# cosmetic "PropDisc" nose spinner (spins while driving), fixed landing gear, and an open
# cockpit seat with a "SeatMarker". No door — step-in boarding. Grounded (wheels at y=0).
func _build_parametric_plane(spec: Dictionary) -> AABB:
	var body_col := _spec_color(spec, PLANE_COLOR_DEFAULT)
	var paint := GSurf.surface({"color": [body_col.r, body_col.g, body_col.b], "rough": 0.35, "metal": 0.45, "bump": 0.0, "tile": 5.0})
	var trim := GSurf.surface({"color": [0.15, 0.15, 0.17], "rough": 0.6, "metal": 0.35, "bump": 0.0, "tile": 6.0})
	var tire := GSurf.surface({"color": [0.07, 0.07, 0.08], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 4.0})
	var cloth := GSurf.surface({"color": [0.24, 0.20, 0.17], "rough": 0.95, "metal": 0.0, "bump": 0.0, "tile": 3.0})
	var glass := _glass_mat()
	var root := Node3D.new()
	root.name = "PlaneBody"
	add_child(root)
	_visual = root
	# fuselage — cylinder axis +Y; rotation.x = +90° maps +Y -> +Z, so top_r (0.5) becomes the
	# NOSE radius at +Z and bottom_r (0.25) the tapering tail at -Z.
	var fus := GShapes.cylinder(0.25, 0.50, 6.2, 16)
	GShapes.set_material(fus, paint)
	fus.position = Vector3(0.0, 1.10, -0.10)   # centre: z -3.2 .. 3.0
	fus.rotation.x = PI * 0.5
	root.add_child(fus)
	# cosmetic PROP DISC on the nose (same axis trace as the fuselage) — spun in _physics_process
	# about its LOCAL +Y (the cylinder axis, = world +Z after the rotation).
	_prop = GShapes.cylinder(0.95, 0.95, 0.06, 24)
	GShapes.set_material(_prop, trim)
	_prop.name = "PropDisc"
	_prop.position = Vector3(0.0, 1.10, 3.10)
	_prop.rotation.x = PI * 0.5
	root.add_child(_prop)
	# straight wings + tailplane + fin (thin boxes)
	_part(root, Vector3(7.4, 0.12, 1.5), Vector3(0.0, 1.28, 0.50), paint)     # main wings
	_part(root, Vector3(2.8, 0.10, 0.9), Vector3(0.0, 1.35, -2.90), paint)    # tailplane
	_part(root, Vector3(0.12, 1.05, 1.0), Vector3(0.0, 1.90, -3.00), paint)   # vertical fin
	# open cockpit — windshield, seat, SeatMarker
	var shield := _part(root, Vector3(0.9, 0.40, 0.05), Vector3(0.0, 1.85, 1.35), glass)
	shield.name = "Windshield"
	shield.rotation.x = deg_to_rad(-30.0)
	_part(root, Vector3(0.55, 0.14, 0.50), Vector3(0.0, 1.55, 0.90), cloth)   # cushion
	_part(root, Vector3(0.55, 0.45, 0.10), Vector3(0.0, 1.80, 0.60), cloth)   # seat back
	_seat_marker = Node3D.new()
	_seat_marker.name = "SeatMarker"
	_seat_marker.position = Vector3(0.0, 1.62, 0.90)
	root.add_child(_seat_marker)
	# fixed landing gear — two main struts + wheels under the wing, one tail wheel. Wheel
	# cylinders lie on their sides (rotation.z = 90° -> axis along X), bottoms at y=0.
	for sx in [-1.0, 1.0]:
		_part(root, Vector3(0.08, 0.50, 0.08), Vector3(0.90 * sx, 0.42, 0.90), trim)
		var wh := GShapes.cylinder(0.22, 0.22, 0.15, 14)
		GShapes.set_material(wh, tire)
		wh.position = Vector3(0.90 * sx, 0.22, 0.90)
		wh.rotation.z = PI * 0.5
		root.add_child(wh)
	var tw := GShapes.cylinder(0.14, 0.14, 0.12, 12)
	GShapes.set_material(tw, tire)
	tw.position = Vector3(0.0, 0.15, -2.90)
	tw.rotation.z = PI * 0.5
	root.add_child(tw)
	_board_local = Vector3(1.30, 0.0, 0.90)   # step in beside the cockpit, inside the wing span
	return _world_aabb(root)


# One placed box part: GShapes.box + GSurf material, positioned by its CENTRE (BoxMesh is
# origin-centred; overwriting .position discards box()'s base-at-y=0 lift on purpose).
func _part(parent: Node3D, size: Vector3, center: Vector3, mat: Material) -> MeshInstance3D:
	var mi := GShapes.box(size)
	mi.position = center
	GShapes.set_material(mi, mat)
	parent.add_child(mi)
	return mi


func _spec_color(spec: Dictionary, fallback: Color) -> Color:
	var c = spec.get("color", null)
	if c is Array and (c as Array).size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return fallback


func _glass_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.75, 0.85, 0.32)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.05
	m.metallic = 0.4
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ---------------- per-tick ----------------

func _physics_process(delta: float) -> void:
	_time += delta
	if _state == S_DRIVING:
		_drive(delta)
	else:
		_snap_to_ground(delta)   # parked / mid-choreography: still hug the (possibly late-wired) rest height
	if _prop != null and _state == S_DRIVING:
		_prop.rotate_object_local(Vector3.UP, PROP_SPIN * delta)   # cosmetic — local +Y = the disc axis
	_update_gait()
	_update_label()


# Integrate one drive tick from the shared input vector main.gd feeds via drive_input().
func _drive(delta: float) -> void:
	var p: Dictionary = PROFILES[profile]
	if _airborne:
		_drive_air(delta)
	else:
		_drive_ground(delta, p)
	# keep the driver ATTACHED: chunk streaming (_player_cell) and quest reach_area notifications
	# all read player.global_position, so parking the player on the boardable keeps the whole
	# ring/quest pipeline fed while driving. A SEATED/RIDING driver rides its marker (visible);
	# the Wave-1 hidden fallback rides the body origin — identical streaming semantics either way.
	_track_driver()


# Ground gait — cars/tanks/boats/taxiing planes/walking mounts. Boats replace the terrain target
# with the water level inside _rest_y (via _snap_to_ground); flyers hand off to _drive_air once
# past takeoff speed with the throttle held.
func _drive_ground(delta: float, p: Dictionary) -> void:
	var max_speed := float(p["max_speed"])
	var target := -_input.y * max_speed   # screen-up / W = forward (same sign as _keyboard_vec)
	var rate := float(p["accel"]) if absf(target) > absf(_speed) else float(p["brake"])
	_speed = move_toward(_speed, target, rate * delta)
	# steering: scaled by speed (no pirouette when parked, flips in reverse — like a real car)
	# EXCEPT steer_fixed profiles (tank): tracks TURN IN PLACE, full authority at zero speed.
	var sf := 1.0 if bool(p.get("steer_fixed", false)) else clampf(_speed / max_speed, -1.0, 1.0)
	rotation.y += -_input.x * float(p["turn_rate"]) * sf * delta
	# forward = +basis.z: library/Meshy models FACE +Z in this stack (TrafficCar's atan2(dir.x,
	# dir.z) and the player's look_at(pos - dir) both point +Z along the heading).
	velocity = global_transform.basis.z * _speed
	velocity.y = 0.0
	move_and_slide()              # buildings/walls (layer 1) stop it; slides along them
	_snap_to_ground(delta)
	# TAKEOFF (plane + dragon): past takeoff speed with the throttle still held, pitch up and fly.
	# The initial +10° pitch clears the GROUNDED_H band before the landing check can re-trigger
	# (landing requires DESCENDING: _pitch <= 0).
	if bool(p.get("fly", false)) and _speed > float(p.get("takeoff", 9.0)) and -_input.y > 0.4:
		_airborne = true
		_pitch = deg_to_rad(10.0)


# Arcade FLIGHT (plane + dragon, shared envelope): input.y = pitch, input.x = bank+yaw, speed
# runs toward SPEED_MAX on implicit cruise throttle. Soft ceiling at ALT_MAX above the LOCAL
# terrain; descending into the GROUNDED_H band lands (back to ground steering).
func _drive_air(delta: float) -> void:
	_speed = move_toward(_speed, SPEED_MAX, AIR_ACCEL * delta)
	var gy := _ground_h()
	var rel := global_position.y - gy
	# PITCH sign: screen-up / W gives _input.y = -1 (the _keyboard_vec convention), and
	# -(-1) * PITCH_MAX = +35° = CLIMB — so holding W through takeoff keeps climbing.
	var tp := -_input.y * deg_to_rad(PITCH_MAX_DEG)
	# soft ceiling: inside the CEIL_BAND below ALT_MAX the allowed climb fades to 0, and ABOVE
	# ALT_MAX it goes negative — pitch is forced down approaching/at the lid.
	var allowed := clampf((ALT_MAX - rel) / CEIL_BAND, -1.0, 1.0) * deg_to_rad(PITCH_MAX_DEG)
	tp = minf(tp, allowed)
	_pitch = move_toward(_pitch, tp, PITCH_RATE * delta)
	# BANKED TURN: same steer sign as the ground path (A / x=-1 -> +yaw); not speed-scaled.
	rotation.y += -_input.x * AIR_TURN * delta
	# visual ROLL sign: rotation about local +Z by -θ dips the +X side ((1,0,0) -> (cosθ, -sinθ, 0));
	# steering toward +X (input.x = -1, yaw+) should dip +X, so roll target = input.x * ROLL_MAX
	# (input.x = -1 -> -40° -> +X wing down = banking INTO the turn).
	_roll = move_toward(_roll, _input.x * deg_to_rad(ROLL_MAX_DEG), ROLL_RATE * delta)
	if _visual != null:
		# visual PITCH sign: rotation about local +X by +θ pitches +Z (the nose) DOWN
		# ((0,0,1) -> (0,-sinθ,cosθ)), so nose-UP for a positive climb pitch needs -_pitch.
		_visual.rotation.x = -_pitch
		_visual.rotation.z = _roll
	# kinematics: forward along the yaw heading, vertical from the pitch angle
	velocity = global_transform.basis.z * (_speed * cos(_pitch)) + Vector3.UP * (_speed * sin(_pitch))
	move_and_slide()   # buildings still stop a low flyer; slides along them
	# hard envelope clamp (the soft ceiling handles the approach; this catches terrain rising fast)
	global_position.y = clampf(global_position.y, gy + GROUND_LIFT, gy + ALT_MAX)
	rel = global_position.y - _ground_h()
	if rel < GROUNDED_H and _pitch <= 0.0:
		_land()


func _land() -> void:
	_airborne = false
	_pitch = 0.0
	_roll = 0.0
	if _visual != null:
		_visual.rotation.x = 0.0
		_visual.rotation.z = 0.0
	# _snap_to_ground lerps the last half-metre down at SNAP_RATE — a soft touchdown, no pop


# Park the driver on the boardable for this tick: its marker (posed, visible — SeatMarker for
# seats, MountMarker for mounts) or the origin (hidden fallback).
func _track_driver() -> void:
	if _driver == null or not is_instance_valid(_driver):
		return
	var marker := _mount_marker if _is_mount else _seat_marker
	# Mounts park the rider on the marker even when the pose failed (visible
	# perch); cabin vehicles only when actually seated (else hidden at origin).
	if marker != null and (_seated or _is_mount):
		_driver.global_position = marker.global_position + Vector3(0.0, _seat_y_off, 0.0)
		_driver.global_rotation = Vector3(0.0, global_rotation.y, 0.0)   # face where the body faces
	else:
		_driver.global_position = global_position
	_driver.velocity = Vector3.ZERO


# Rest-height target for the ground snap. Ground profiles: GTerrain.height(x, z) — the RENDERED-
# SURFACE height (mesh-accurate by contract), so the body hugs the visible ground; flat worlds
# (terrain == null) ride the y=0 slab. WATER profiles (boat) in a world WITH water: the GWater
# level + the pinned bob — maxed with the terrain so a boat driven over ground above the
# waterline beaches on it instead of sinking in; NO water block -> plain terrain (car-like).
func _rest_y() -> float:
	var ty := _ground_h() + GROUND_LIFT
	if _has_water and _water_rest:
		return maxf(water_level + BOB_AMP * sin(_time * BOB_HZ), ty)
	return ty


func _ground_h() -> float:
	var h := terrain.height(global_position.x, global_position.z) if terrain != null else 0.0
	if _has_water and _water_rest:
		h = maxf(h, water_level)   # a float-hulled flyer lands ON the river, not the riverbed
	return h


func _snap_to_ground(delta: float) -> void:
	var gy := _rest_y()
	if _snapped:
		global_position.y = lerpf(global_position.y, gy, minf(1.0, SNAP_RATE * delta))
	else:
		global_position.y = gy
		_snapped = true


# Wire (or re-wire) the terrain AFTER the streamer boots — vehicles spawn before ChunkManager
# builds GTerrain. Re-snaps instantly so a parked body doesn't visibly ride up to the new surface.
func set_terrain(t: GTerrain) -> void:
	terrain = t
	_snapped = false


# Wire the world's water level (ChunkManager's `water_level`, read from world.json "water".level —
# the same number GWater.body renders the surface at). Only called for worlds WITH a water block;
# without it boats keep the terrain (car-on-terrain degrade, per the Wave-3 contract).
func set_water(level: float) -> void:
	_has_water = true
	water_level = level
	_snapped = false


# ---------------- enter / exit (discrete API; choreographed boards wrap them in tweens) ----------------

# USE dispatch from the interaction system: walk up -> board; while driving -> exit.
# Mid-choreography USE is a no-op (this is the exit-mid-enter guard for the player path;
# the hot-reload free path is covered by _exit_tree's force-restore).
func use(driver: CharacterBody3D) -> void:
	if _state == S_ENTERING or _state == S_EXITING:
		return
	if driving:
		exit()
	else:
		enter(driver)


# Swap the player IN. Instant boards (fused-GLB vehicles + the parametric tank): the Wave-1
# swap-in, hide + attach. Choreographed boards (car door / boat+plane step-in / mount): start the
# sequence with the camera switch + input routing (drive_state_changed) at sequence START,
# Wave-1 style; drive_input is ignored until the state machine reaches DRIVING.
func enter(driver: CharacterBody3D) -> void:
	if _state != S_IDLE or driver == null:
		return
	driving = true
	_driver = driver
	_speed = 0.0
	_input = Vector2.ZERO
	driver.velocity = Vector3.ZERO
	_set_body_collision(driver, true)   # the capsule must not fight the body's box from inside
	if _board == "instant":
		_state = S_DRIVING
		driver.visible = false          # hidden driver (tank: hatch choreography out of scope v1)
		driver.global_position = global_position
		AudioManager.play_sfx("door")
		drive_state_changed.emit(self, true)
		return
	_state = S_ENTERING
	drive_state_changed.emit(self, true)   # controls locked out from here: main routes input to the
	_set_door_blocking(false)              # body, and drive_input is ignored until _state == S_DRIVING
	_begin_enter_choreo()


# Swap the player OUT. Instant boards: the Wave-1 swap-out. Choreographed boards (while DRIVING):
# stop + run the exit choreography, releasing control (emit false) only when the driver is fully
# restored. Mid-ENTER exits are ignored (guard). AIRBORNE exits are ignored too — the chunk
# movement contract has no gravity, so a mid-air dismount would strand a floating player: land
# first (descend until terrain-relative height < 0.5), then exit. The hot-reload free path is
# restored by _exit_tree (which drops the driver at TERRAIN height, so even a freed-mid-flight
# session leaves them safely grounded).
func exit() -> void:
	if _state != S_DRIVING:
		return
	if _airborne:
		return
	_speed = 0.0
	_input = Vector2.ZERO
	velocity = Vector3.ZERO
	if _board == "instant":
		driving = false
		_state = S_IDLE
		var driver := _driver
		_driver = null
		if driver != null and is_instance_valid(driver):
			var spot := global_position + global_transform.basis.x.normalized() * float(PROFILES[profile]["exit_side"])
			spot.y = (terrain.height(spot.x, spot.z) if terrain != null else 0.0) + 0.1
			_set_body_collision(driver, false)
			driver.global_position = spot
			driver.velocity = Vector3.ZERO
			driver.visible = true
		AudioManager.play_sfx("door")
		drive_state_changed.emit(self, false)
		return
	_state = S_EXITING
	_begin_exit_choreo()


# Fed by main._physics_process while this vehicle is active — the SAME input vector that walks the
# player (no second input path). Ground: x = steer, y = throttle (screen-up negative, like
# _keyboard_vec). Airborne: x = bank+yaw, y = pitch. Ignored (stored but never integrated)
# unless the state machine has reached DRIVING.
func drive_input(v: Vector2) -> void:
	_input = v.normalized() if v.length() > 1.0 else v


# Interaction-registry prompt text, re-read each query. Mounts: "Ride <name>" / "Dismount";
# vehicles: "Exit <name>" / "Drive <name>" (Wave-2 behavior, unchanged).
func prompt_label() -> String:
	if _is_mount:
		return "Dismount" if driving else "Ride " + display_name
	return ("Exit " if driving else "Drive ") + display_name


# ---------------- enter/exit choreography (door / step-in / mount boards) ----------------

# Generalised Wave-2 sequence. Door segments only exist on the car (its _door_pivot); door-less
# boards (boat/plane step-in, mounts) run walk -> pose directly with a single boarding sfx.
func _begin_enter_choreo() -> void:
	_kill_seq()
	var d := _driver
	var beside := to_global(_board_local)   # on the ground beside the opening/cockpit/flank
	_seq = create_tween()
	# 1) door swings open (car only)
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_TIME).set_trans(Tween.TRANS_SINE)
	else:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))   # one boarding thunk for door-less boards
	# 2) the driver visibly walks to beside the seat / saddle
	_seq.tween_property(d, "global_position", beside, WALK_TIME).set_trans(Tween.TRANS_SINE)
	# 3) aboard: snap onto the marker + GPose.sit / GPose.ride (or the Wave-1 hide fallback)
	_seq.tween_callback(_seat_driver)
	# 4) door swings closed (car only) -> driving enabled
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", 0.0, DOOR_TIME).set_trans(Tween.TRANS_SINE)
	_seq.tween_callback(func() -> void:
		_state = S_DRIVING)


func _begin_exit_choreo() -> void:
	_kill_seq()
	var d := _driver
	var spot := global_position + global_transform.basis.x.normalized() * float(PROFILES[profile]["exit_side"])
	spot.y = (terrain.height(spot.x, spot.z) if terrain != null else 0.0) + 0.1
	_seq = create_tween()
	# 1) door swings open (car only)
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_TIME).set_trans(Tween.TRANS_SINE)
	# 2) the driver stands (pose restored / unhidden — GPose.stand reverses sit AND ride, same
	#    meta) and visibly steps out/off to exit_side
	_seq.tween_callback(func() -> void:
		_seated = false
		if d != null and is_instance_valid(d):
			GPose.stand(d)
			d.visible = true)
	if d != null and is_instance_valid(d):
		_seq.tween_property(d, "global_position", spot, WALK_TIME).set_trans(Tween.TRANS_SINE)
	# 3) door swings closed (car only) -> driver fully restored, control released
	if _door_pivot != null:
		_seq.tween_callback(func() -> void:
			AudioManager.play_sfx("door"))
		_seq.tween_property(_door_pivot, "rotation:y", 0.0, DOOR_TIME).set_trans(Tween.TRANS_SINE)
	_seq.tween_callback(func() -> void:
		_finish_exit(spot))


# Put the driver aboard: measure the rig's standing height FIRST (the pose changes the AABB),
# drop the character origin so the hips land on the marker, then pose. Seats use GPose.sit
# (hips sink slightly into the cushion); mounts use GPose.ride (astride, hips a touch above the
# back-line so the spread thighs wrap the flanks). A false return (capsule / unrecognized rig):
# cabin vehicles hide the driver (Wave-1 fallback); MOUNTS keep the rider VISIBLE, perched on
# the MountMarker (rider-always-visible contract).
func _seat_driver() -> void:
	var d := _driver
	if d == null or not is_instance_valid(d):
		return
	var dh := _world_aabb(d).size.y
	if dh < 0.5:
		dh = 1.7
	if _is_mount:
		_seat_y_off = 0.12 - HIP_RATIO * dh   # astride: hips just above the AABB back-line
		_seated = GPose.ride(d)
	else:
		_seat_y_off = 0.06 - HIP_RATIO * dh   # seated: hips just above the cushion (+0.06 sink)
		_seated = GPose.sit(d)
	if not _seated:
		if _is_mount:
			# CONTRACT: a mount's rider is ALWAYS visible — there is no cabin
			# to hide in, and an invisible rider reads as a riderless horse.
			# Capsule/unposeable rigs PERCH visibly on the MountMarker instead
			# (same graceful degrade as the furniture seat).
			_seat_y_off = 0.0
		else:
			d.visible = false
			_seat_y_off = 0.0
	_track_driver()   # snap onto the marker (or origin) immediately; _drive re-parks every tick


# Final exit bookkeeping — the driver is standing at `spot`, solid, visible; the body is parked.
func _finish_exit(spot: Vector3) -> void:
	var d := _driver
	_driver = null
	_seated = false
	if d != null and is_instance_valid(d):
		_set_body_collision(d, false)
		d.global_position = spot
		d.velocity = Vector3.ZERO
		d.visible = true
	_set_door_blocking(true)   # parked + closed -> the leaf blocks again (no-op without a door)
	driving = false
	_state = S_IDLE
	drive_state_changed.emit(self, false)


# HOT-RELOAD SAFETY NET: main.gd calls exit() then frees rebuilt vehicles — if the free lands
# mid-choreography (exit() mid-ENTER is a guarded no-op), mid-drive, or MID-FLIGHT (exit() while
# airborne is a guarded no-op too), the vehicle-bound tweens die with this node. Restore the
# DRIVER synchronously — pose, visibility, collision, and a position at TERRAIN height — so a
# chat edit can never strand a hidden, posed, collision-less or floating player. (Also covers
# any future non-exit() free path.)
func _exit_tree() -> void:
	if _state == S_IDLE:
		return
	_kill_seq()
	var d := _driver
	_driver = null
	_state = S_IDLE
	driving = false
	_seated = false
	_airborne = false
	if d != null and is_instance_valid(d):
		GPose.stand(d)
		_set_body_collision(d, false)
		var spot := global_position + global_transform.basis.x.normalized() * float(PROFILES[profile]["exit_side"])
		spot.y = (terrain.height(spot.x, spot.z) if terrain != null else 0.0) + 0.1
		d.global_position = spot
		d.velocity = Vector3.ZERO
		d.visible = true
	drive_state_changed.emit(self, false)


func _kill_seq() -> void:
	if _seq != null and _seq.is_valid():
		_seq.kill()
	_seq = null


# The car door leaf's blocking collider: solid ONLY when parked with the door closed. Disabled
# while open (walk through the opening) and while entering/driving/exiting (the body's own box
# collider already covers the closed door, and a live child StaticBody would jam the camera
# SpringArm). No-op for door-less bodies.
func _set_door_blocking(on: bool) -> void:
	if _door_shape != null:
		_door_shape.disabled = not on


# ---------------- mount gait sync (embedded clips only) ----------------

# Drive the mount's own AnimationPlayer from the motion state. Ground: move clip while
# |speed| > 0.5 with speed_scale = clamp(speed/6, 0.6, 2.2) (gallop/run above 55% of max when
# the model carries one, else walk), idle when stopped/parked. Airborne (dragon): FLAP while
# climbing/accelerating, GLIDE when level/descending. Any missing clip is "" -> _play_clip
# no-ops -> a clipless creature rides silently (pinned degrade).
func _update_gait() -> void:
	if _gait_ap == null:
		return
	if _state == S_DRIVING and _airborne:
		var climbing := _pitch > deg_to_rad(3.0) or _speed < SPEED_MAX * 0.6
		var air_clip := _clip_flap if climbing else _clip_glide
		if air_clip == "":
			air_clip = _clip_flap if _clip_flap != "" else _clip_glide   # whichever exists
		_play_clip(air_clip, 1.0)
		return
	if _state == S_DRIVING and absf(_speed) > GAIT_MOVE_MIN:
		var mv := _clip_walk
		if _clip_fast != "" and absf(_speed) > float(PROFILES[profile]["max_speed"]) * GAIT_FAST_FRAC:
			mv = _clip_fast
		if mv == "":
			mv = _clip_fast   # only a gallop/run clip shipped — better than freezing
		_play_clip(mv, clampf(absf(_speed) / 6.0, 0.6, 2.2))
		return
	_play_clip(_clip_idle, 1.0)


# Play a clip if it isn't already playing (the WanderAgent._play idiom: force looping so gaits
# cycle) and set the playback rate. "" or no player -> silent no-op.
func _play_clip(clip: String, rate: float) -> void:
	if _gait_ap == null or clip == "":
		return
	_gait_ap.speed_scale = rate
	if _gait_ap.current_animation != clip:
		var a := _gait_ap.get_animation(clip)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
		_gait_ap.play(clip)


func _match_clip(keys: Array) -> String:
	if _gait_ap == null:
		return ""
	for k in keys:
		for c in _gait_ap.get_animation_list():
			if String(k) in String(c).to_lower():
				return String(c)
	return ""


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null


# ---------------- internals ----------------

# Toggle every CollisionShape3D directly on a body (the player's capsule) off/on.
func _set_body_collision(body: Node, off: bool) -> void:
	for c in body.get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).disabled = off


# Floating prompt: EXIT/DISMOUNT while driven; DRIVE/RIDE when the player is within reach;
# hidden otherwise (and hidden during the enter/exit choreography — USE is a no-op then anyway).
func _update_label() -> void:
	if _label == null:
		return
	if _state == S_ENTERING or _state == S_EXITING:
		_label.visible = false
		return
	if driving:
		_label.text = "DISMOUNT" if _is_mount else "EXIT"
		_label.visible = true
		return
	var near_player := false
	if player_ref != null and is_instance_valid(player_ref):
		near_player = player_ref.global_position.distance_to(global_position) < PROMPT_RANGE
	_label.text = "RIDE" if _is_mount else "DRIVE"
	_label.visible = near_player


# Merged mesh bounds of a subtree — DETACHMENT-SAFE (mirrors AreaBuilder._world_aabb): setup()
# measures the model BEFORE it is parented, where global_transform is identity + an error line.
# Accumulates transforms manually, root's own included. Local copy so this module stays
# self-contained (it is copied verbatim into the 3d template for parity).
func _world_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [[root, root.transform]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		for c in n.get_children():
			var cx := xf
			if c is Node3D:
				cx = xf * (c as Node3D).transform
			stack.append([c, cx])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var wa: AABB = xf * (n as MeshInstance3D).get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged
