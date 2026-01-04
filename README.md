# Flagspawn Gamemode Helpers

This repository contains the experimental TF2 VScript prototypes for the Flagspawn gamemode. The scripts are intended to be dropped into your local `tf/scripts/vscripts` folder while debugging maps built around `fs_gamemode.vmf` / `flagspawn.nut`.

## Files
- `flagspawn.nut` — core logic for spawning pooled intel items via spawner props.
- `flagspawn_agentic_tf2_fixed.nut` — earlier prototype of the same logic using TF2-friendly function syntax.
- `fs_spawner_diag.nut` — diagnostic helper that logs spawner/capper trigger touches and optionally disables capture triggers so spawner touches are not intercepted.
- `flagspawn_spawner_replacement.nut` — drop-in spawner/capper touch logger that you can load instead of `flagspawn.nut` when you only want to validate trigger wiring in `fs_gamemode.vmf` / `flagspawngamemode.vmf`.

## Quickstart: diagnosing spawner triggers
1. Copy all `.nut` scripts into your `tf/scripts/vscripts` directory.
2. Load your map, then run the following in the developer console:
   ```
   script_execute flagspawn.nut          // load core logic
   script_execute fs_spawner_diag.nut    // load diagnostics
   fs_spawner_diag.Setup();              // disable cappers + hook touch logging
   ```
3. Walk a player through the spawner triggers. The console will print `OnStartTouch`/`OnEndTouch` entries for `blutrigger`, `redtrigger`, `blucapper`, and `redcapper`. Missing triggers are also reported.
4. When you are ready to test full capture flows again, re-enable the capper triggers:
   ```
   fs_spawner_diag.EnableCappers();
   ```

## Alternate: drop-in spawner-only replacement
If you just want to see spawner/capper touches fire without the full flagspawn logic running, swap the script executed by the map:

1. Copy `flagspawn_spawner_replacement.nut` into your `tf/scripts/vscripts` directory.
2. In-game, run:
   ```
   script_execute flagspawn_spawner_replacement.nut
   flagspawn.Setup();  // disables capper triggers and reports missing spawner/capper names
   ```
3. Walk through the spawner trigger volumes. The console will print each `OnSpawnerTouch` and `OnCaptureTouch` along with player names and teams. Capture triggers stay disabled until you re-enable them:
   ```
   flagspawn.EnableCappers();
   ```

### Notes
- `fs_spawner_diag.Setup()` turns on `flagspawn.DEBUG` if the base script is loaded so you see both spawner/capper touches and the flagspawn debug output together.
- The helper does not create or move entities; it only hooks trigger outputs. If touches still do not fire, verify your trigger names in Hammer match `blutrigger`/`redtrigger` (spawners) and `blucapper`/`redcapper` (capture areas).

## Workflow tips
- Keep the diagnostic script loaded while iterating on Hammer trigger volumes so you can immediately confirm when player touches reach the spawner triggers.
- Once spawner touches behave as expected, call `fs_spawner_diag.EnableCappers()` or reload the map to resume normal capture behavior.
