# Flagspawn Gamemode Helpers

This repository contains the experimental TF2 VScript prototypes for the Flagspawn gamemode. The scripts are intended to be dropped into your local `tf/scripts/vscripts` folder while debugging maps built around `fs_gamemode.vmf` / `flagspawn.nut`.

## Files
- `flagspawn.nut` — core logic for spawning pooled intel items via spawner props.
- `flagspawn_agentic_tf2_fixed.nut` — earlier prototype of the same logic using TF2-friendly function syntax.
- `fs_spawner_diag.nut` — diagnostic helper that logs spawner/capper trigger touches and optionally disables capture triggers so spawner touches are not intercepted.

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

### Notes
- `fs_spawner_diag.Setup()` turns on `flagspawn.DEBUG` if the base script is loaded so you see both spawner/capper touches and the flagspawn debug output together.
- The helper does not create or move entities; it only hooks trigger outputs. If touches still do not fire, verify your trigger names in Hammer match `blutrigger`/`redtrigger` (spawners) and `blucapper`/`redcapper` (capture areas).

## Workflow tips
- Keep the diagnostic script loaded while iterating on Hammer trigger volumes so you can immediately confirm when player touches reach the spawner triggers.
- Once spawner touches behave as expected, call `fs_spawner_diag.EnableCappers()` or reload the map to resume normal capture behavior.
