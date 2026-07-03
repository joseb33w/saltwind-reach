# Goal
Build "SALTWIND REACH" — a 1930s pulp-adventure open world as a Godot 4.6.3 web (nothreads, Compatibility) game on the godot-tmpl-rpg CHUNK streamer: ONE seamless map with three regions (Deepwood forest west, Porto Verde riverfront city center, Suburbs east) joined by a bridge road and a boulevard, a carved river running through forest + city quay, full day/night + storm weather cycle, five distinct rides (jeep, river boat, seaplane, horse, Meshy-generated rigged storm-drake), enterable buildings (tavern w/ back room, outfitter, climbable clocktower, two suburban houses), a winnable quest arc (tavern keeper -> bandit camp Bronze Sun Key -> ziggurat vault -> Sunstone Relic -> drake finale), TWO play modes (Adventure / Explore) chosen at start, Supabase persistence (mode, position, inventory, quest state, discovered places) + a Relic Hunters leaderboard on a tavern plaque.

# Files to touch
- world.json / quests.json — the authored chunk world (14x7 cells, cell_size 20) + quest chain (generated once, committed as data).
- terrain.gd — extend the analytic heightfield with a data-driven `river` polyline carve + `flats` rectangles (city/suburb leveling, bridge abutments).
- main.gd — mode-select overlay after tap-to-start, Meshy hero avatar + locomotion clips, mode/flag-gated vehicles (storm-drake earned in Adventure, parked in the park in Explore), objective nav arrow, discovered-location toasts, persistence + leaderboard wiring.
- quest.gd — prereq chaining (flags/quests) + serialize/restore.
- enemy.gd — passive-until-provoked behavior for Explore mode.
- interaction.gd — leaderboard plaque interactable, ASCII-safe prompts, pretty item names.
- chunk_manager.gd — `plaque` cell field; structure `y_off` for the river bridge deck.
- persist.gd (new) — Supabase REST save/load + leaderboard client (anon key).
- audio/ — curl realistic-tier music + ambient beds.
- .env/.env.example, README.md, .gitignore.

# Verification approach
Supabase: positive + negative REST tests (done: anon upsert/read save, insert/read leaderboard, delete blocked). qgcheck winnability gate on world.json+quests.json. Static pre-import grep gates (Variant inference, Node-member shadowing). Headless export + vetted smoke verifier (boot, console, frames at portrait+landscape). Targeted in-engine checks: clip resolution on hero/NPC/drake, W/S facing frames, combat delta (bandit hp before/after + particles), trigger/door lock (vault door refuses without key, opens with it), quest chain progression to drake_awoken, leaderboard submit + top-10 fetch, mode-select both paths, save round-trip. QA specialist gate before PR.

# Out of scope
Multiplayer; account sign-in (saves keyed to the requesting Gogi user); interior furnishing beyond the five enterable buildings; authoritative anti-cheat leaderboard.
