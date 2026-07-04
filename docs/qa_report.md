# QA REPORT — SALTWIND REACH (feat/saltwind-reach-world)

## VERDICT: FAIL (2 P0)

Adversarial pass over the web export (/workspace/out), the live preview, and the real boot via headless in-engine probes (independent scripts in a **copy** of the project at /tmp/qa_proj — /workspace untouched). Screenshot evidence in /tmp/qa/*.png.

---

## ❌ P0-1 — Enemies can NEVER damage the player (combat is one-sided; potions/respawn/difficulty all dead code)

**Symptom:** Player HP never drops. I parked the player 1.0 m from a provoked bandit for 10 s (re-pinning position every 0.5 s); the bandit's attack cooldown was cycling (`atk_cd=0.23`, i.e. it WAS swinging) and HP stayed `100.0 -> 100.0`.

**Root cause (confirmed at runtime, not just read):** `enemy.gd:140-141`
```gdscript
if player.has_method("take_damage"):
    player.call("take_damage", 9.0)
```
`enemy.player` is the bare `CharacterBody3D` built in `main.gd::_build_player()` — it has **no script**, so `has_method("take_damage")` is **always false** (printed `false` live). `take_damage` lives on **main.gd:595** and nothing ever routes an enemy hit to it. Every enemy swing in the game silently no-ops. This also nullifies the POTION button, the "forgiving respawn" logic, and any danger from bandits / vault guardians / the drake arc.

**Fix direction:** pass `world_main` into the swing (enemy already holds `world`) and call `world.take_damage(9.0)`; or attach a tiny script / Callable meta on the player body forwarding to main.

**Note:** the builder's 39-check harness tests enemy-takes-damage + provoke, but never player-takes-damage — exactly the gap.

## ❌ P0-2 — The parked jeep spawns wedged INSIDE the outfitter building's colliders and cannot drive at all

**Symptom:** USE at the jeep (128,46) boards fine, camera follows — but the vehicle **cannot move**. Full throttle for 5 s: `moved=0.00 m` at `_speed=12` (velocity integrated, `move_and_slide` blocked). I then tried every input combination (reverse, reverse+steer both ways, forward+steer both ways, 5 s each — 30 s total): max displacement **2.4 m**, oscillating deeper into the building. Reproduced in BOTH Adventure and Explore headless runs.

**Root cause:** world.json `vehicles[0]` pos `[128,46]` lies inside cell [6,2]'s structure `{pos:[-6,-6], footprint:[9,8]}` → building spans x 119.5–128.5, z 40–48. Slide-collision log shows the jeep pinched between static faces at x=128.2 (normal −X) and x=125.475 (normal +X) — a ~2.7 m wall cavity narrower than the jeep. The headline "drive the jeep down the boulevard" feature is unusable (and the jeep presumably renders clipping through the outfitter's wall).

**Fix direction:** move the jeep spawn onto the road (e.g. `[131, 51]` — road band z 46–54 in that cell, clear of the footprint), or shrink/shift the outfitter structure. Re-verify by boarding + driving, not by registry count (the harness's `vehicles == 4` check passes while the vehicle is bricked).

---

## ❗ P1-1 — Hero model fetch has no retry: one observed live session played entirely as a flat blue capsule

On one full live-preview EXPLORE session (~90 s, screenshots /tmp/qa/L2_explore.png, L3_sky.png, L4_walk.png + crop_blue.png) the protagonist was the **blue placeholder capsule** (Color 0.3,0.6,0.95 egg) for the whole run while NPCs/jeeps/fountain all loaded. Cause: `main.gd::_setup_avatar()` fetches `hero.glb` once and `return`s silently if `builder._ensure` fails — no retry, permanent placeholder. Re-runs (live ADVENTURE /tmp/qa/live_p1.png, local runs, headless explore) load the hero fine, so it's an intermittent-fetch robustness hole — but on a flaky phone connection it ships a blue egg as the hero. Fix: retry with backoff / re-attempt on failure.

## ❗ P1-2 — Spawn camera sits under the tavern eave: a dark roof wedge occludes ~15-20 % of the frame on every fresh spawn

Every portrait boot (local + live + night: p2_plaza.png, live_p1.png, n1_night.png) shows a dark diagonal roof plane filling the top-left of the first gameplay frame, over the HUD area. It clears as soon as the player orbits/walks — but it's the game's first impression and reads broken. Fix: nudge the spawn point / initial camera yaw, or let the spring-arm mask include the roof so it pulls in.

---

## ⚠️ Warnings (should-fix, not blockers)

- **Boat boarding is chest-deep-wading only:** the player walks the riverbed fully submerged (~2.3 m under water, no swim state). The USE range (2.9 m, 3-D) only reaches the launch when standing ~1 m from the hull underwater (measured d=2.59); from the bank it's out of range. Works, feels janky — consider a bigger board range for `water` profiles or a mooring beside the dock.
- **Grass scatter grows through the asphalt:** plaza/boulevard cells scatter `Grass_Common_*` uniformly, including the road surface (visible in L2/L3/L4). Mask scatter out of road bands.
- **Traffic ignores the player:** a traffic jeep drove into/parked on top of the player (live_p2.png). Cosmetic, but odd at plaza density.
- **Portrait mode-panel subtitle** touches both screen edges at 420 px (p1_panel.png) — cosmetic.
- **Console (container-only, do not chase):** supabase TLS `Failed to fetch` + one `stream_peer_gzip` / `Parse JSON failed` pair from the failed save fetch — the game recovers to a fresh start as designed; verified the REST host + `/godot-assets/` + all Meshy model URLs return 200 via curl.

---

## ✅ What passed (real deltas, not assumptions)

| Check | Evidence |
|---|---|
| Engine boots, non-blank canvas, no real script errors | verify.mjs: only the known supabase fetch noise; my probes' consoles clean otherwise |
| Builder harness reproduced | 39/39 OK re-run by me (`--worldtest`) |
| Winnability (qgcheck) | "quest-graph OK — world is winnable (98 areas)" in /tmp/verify.log |
| Movement + facing | KeyW walks away showing the hero's BACK, quest distance ticks 5m→4m (p3_afterW.png) |
| Camera orbit + pitch | right-half drag yaws the view (p4_look.png); pitch clamps without floor-stare (p5_pitch.png); look-up shows a real sunset sky, no grey ceiling (L3_sky.png) |
| Input-binding sanity | ATTACK is a dedicated HUD button; look-drag/move never fires it (code path + drags in probes produced no swing; XP/HP unchanged) |
| Real attack path | `_attack()` with player deliberately faced AWAY: aim-snap landed, enemy hp 45→20 |
| Enemy AI approach | provoked bandit closed 6.15 m → 2.98 m (player-damage side is P0-1) |
| Hit feedback | harness: particle burst + provoke + hp deltas |
| World richness/density | plaza reads as a real 1930s town: EW road with lane dashes, stucco/brick parametric buildings with lit window facades + interiors, ornate Meshy fountain, benches/tables/streetlights, 8 animated townsfolk, traffic (L2/L4, live_p1) |
| No T-pose / frozen cast | all 13 Meshy GLBs ship idle/walk/run/attack clips; all 8 plaza characters had a clip actively playing (idle×7, walk×1) |
| Character sourcing (Meshy mandate) | hero, keeper, outfitter, townsfolk, bandits, guardian, drake, vehicles = Meshy (`/cloud-*/models/`); KayKit used only for furniture/props — appropriate |
| World boundary + persistence | invisible border walls verified by ray (hit x=0.5 west, z=139.5 south) + 3 s physics ram (player contained, x≥0.9); 6 cells still resident at the edge — world never vanishes |
| Vehicles (other 4) | boat drives (wading caveat), seaplane taxis + takes off (68 m), horse rides (16.7 m), Explore drake at (250,30) boards/rides/exits; Explore registry = 5 vs Adventure 4 (drake gated) ✓ |
| Explore mode button | live landscape run entered gameplay via EXPLORE (L2_explore.png) |
| Mobile fill | portrait 420×860 + landscape 860×400: scene fills all corners, HUD + USE/POTION/ATTACK inside the viewport, no overlaps, mode panel fully visible in both |
| Day/night | deterministic static-night probe (modified world.json copy): night measurably darker (world mean 48→35) yet fully readable — characters/road/buildings distinguishable, emissive windows on (n1_night.png); day not blown out |
| Vault/quest chain | harness end-to-end through real functions: keeper talk → kills+key → locked door refuses/opens → relic → drake wakes → Q4 done |
| Audio presence | AudioManager autoload + bus layout + play_sfx on attack/door/ui/hurt (playback itself unverifiable here) |

## Could not verify (sandbox limits)
Real-device audio playback; Supabase save/leaderboard round-trip (sandbox proxy rejects the TLS — REST endpoint itself returns 200 via curl); CONTINUE-from-save flow (needs a working save fetch); touch feel/multi-touch; true-GPU fidelity; keeper's exact visual placement inside the tavern (headless AABBs are degenerate for skinned meshes and browser walking is impractical at 1-5 fps — low risk since the same seating path renders street NPCs correctly); seaplane water-landing visuals.

**Bottom line:** the world, quests, streaming, boundary, art direction and mobile fill are genuinely solid — but ship is blocked by two P0s: combat that cannot hurt the player, and a headline vehicle that spawns bricked inside a building.
