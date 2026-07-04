# SALTWIND REACH

A 1930s pulp-adventure open world you can explore end to end — built with Godot 4.6.3
(Compatibility renderer, single-threaded web export) on the Gogi RPG chunk-streaming template.

**Play it:** https://preview.myapping.com/cloud-m4bvyncum9o246jzt6zs/index.html

## One seamless map, three regions

- **The Deepwood** (west) — old-growth forest, a winding carved river, a treeline ranch,
  a bandit camp in a clearing, and the vine-choked Ziggurat of the Sun with a sealed relic vault.
- **Porto Verde** (center) — a sun-bleached riverfront city: plaza with a fountain, market
  street with vendors and crowds, a river quay with docked boats, and buildings you can walk
  into — the Saltwind Tavern (with a back room), the outfitter's shop, and a clocktower you can
  climb floor by floor to the top.
- **The Suburbs** (east) — hedged yards, porches, kids' bikes on lawns, slow traffic,
  two family houses you can enter (sittable sofas downstairs, stairs up to the bedrooms),
  and Marlin Park.

A bridge road joins the forest trail to the city; the boulevard runs out the other side into
the suburban streets. No loading breaks — cells stream in around you.

## Two ways to play

Chosen right after the tap-to-start screen (and remembered in your save):

- **ADVENTURE** — the quest arc: hear the rumor at the tavern, take the Bronze Sun Key from
  the bandit camp, unseal the ziggurat vault, take the Sunstone Relic — which wakes the
  storm-drake on the crag — then fly it home to Marlin Park.
- **EXPLORE** — no objectives, enemies stay in their camps unless provoked, and every ride is
  available from minute one, including a saddled storm-drake in the suburban park. Talking to
  the tavern keeper starts the Adventure at any time, no restart.

## Getting around

Jeep (boulevard), river launch (pilot upstream into the forest), seaplane (take off from the
river and see the regions from the air), ranch horse (jungle trails), and the **storm-drake** — an
original Meshy-generated feathered wind-serpent, rigged so its wings actually flap
(idle/walk/flap/glide clips via the G_DRAGON rig lab).

## Weapons

Start with a machete; find a long bow in a chest on the forest trail; recover an expedition
rifle in the bandit camp. Ranged fire auto-aims and works from horseback (and drake-back).

## Persistence (Supabase)

- Expedition saves (mode, position, inventory, quest state, discovered places) upsert to
  `usr_nmexs7bytxq2_saltwind_reach_saves` every few seconds and on key events — resume on
  any device.
- **RELIC HUNTERS leaderboard** — your time from accepting the Adventure to taking the
  Sunstone is submitted to `usr_nmexs7bytxq2_saltwind_reach_leaderboard`; the top ten are
  readable on the plaque outside the tavern.

Environment configuration is in `.env.example`.

## Development

- Run `tools/fetch_assets.sh` once after cloning (pulls the CC0 audio + rig libraries the
  repo intentionally does not track).
- `world.json` + `quests.json` are the data-driven source of truth (chunk mode, 14×7 cells,
  cell size 20). They are served loose next to `index.html` and hot-reload on change.
- Export: `godot --headless --path . --export-release "Web" out/index.html`, then copy
  `world.json`/`quests.json` into `out/`.
- Characters, vehicles and the drake stream from R2 (`/cloud-m4bvyncum9o246jzt6zs/models/`);
  library props stream from `/godot-assets/`.

## Credits

CC0/CC-BY assets: KayKit, Kenney, Quaternius, FertileSoil, Vostok (props/audio via the Gogi
asset library). Original characters, vehicles and the storm-drake generated with Meshy AI.
