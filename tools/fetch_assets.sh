#!/usr/bin/env bash
# Fetch the binary assets the repo intentionally does not track (CC0 audio + the KayKit
# retarget rig libraries). Run once after cloning, before opening the project in Godot.
set -euo pipefail
O=https://preview.myapping.com/godot-assets
cd "$(dirname "$0")/.."
mkdir -p audio models

# baked template SFX + weather beds (Kenney / Ninja Adventure, CC0) — from the template zip
TMP=$(mktemp -d)
curl -sfL "https://preview.myapping.com/godot-tmpl-rpg/godot-tmpl-rpg.zip" -o "$TMP/t.zip"
unzip -o -q "$TMP/t.zip" -d "$TMP" 'audio/*' || unzip -o -q "$TMP/t.zip" -d "$TMP"
cp -f "$TMP"/audio/*.ogg "$TMP"/audio/*.wav audio/ 2>/dev/null || true
rm -rf "$TMP"

# Saltwind Reach soundtrack + region beds (CC0, realistic tier)
curl -sfL "$O/audio/realistic/music/town_theme.ogg"      -o audio/music_town.ogg
curl -sfL "$O/audio/realistic/ambient/forest_birds.ogg"  -o audio/amb_forest.ogg
curl -sfL "$O/audio/realistic/ambient/ocean_surf.ogg"    -o audio/amb_city.ogg
curl -sfL "$O/audio/realistic/ambient/forest.ogg"        -o audio/amb_suburbs.ogg
curl -sfL "$O/audio/realistic/ambient/town_crowd.ogg"    -o audio/town_crowd.ogg
curl -sfL "$O/audio/sfx/secret.wav"                      -o audio/secret.wav
curl -sfL "$O/audio/sfx/success.wav"                     -o audio/success.wav

# KayKit retarget clip libraries (fallback for clipless rigs)
for f in kk_rig_medium_general kk_rig_medium_movementbasic kk_rig_medium_combatmelee; do
  curl -sfL "$O/animations/$f.glb" -o "models/$f.glb"
done

echo "assets fetched. The game's characters/vehicles stream at runtime from R2 and need no local copy."
