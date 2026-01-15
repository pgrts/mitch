# Flagspawn (PD Team-Locked Pickups)

This repo uses TF2's built-in Player Destruction (PD) pickup + merge system, but adds a map/template pattern (see `fs2_test.vmf`) that makes pickups effectively team-locked even though PD wants neutral flags.

## How It Works (fs2_test pattern)

- Each pickup is an `item_teamflag` configured for PD (`GameType=6`, `TeamNum=0`, `NeutralType=1`), so PD merging works normally.
- Each pickup is packaged with an enemy-only `trigger_multiple` that acts like a "deny pad":
  - On enemy touch, the flag is `Disable`d (blocking pickup), and the enemy gets launched forward + slightly upward (a speed-pad feel).
  - Because the pad launches the enemy out of the trigger, the disable window is naturally brief and can't be held indefinitely by just standing there.
  - The speed pad taker (player - `!activator`) gets a brief `tf_glow` outline when the pad triggers (readability; configurable in `flagspawn.nut`).
  - With `VisibleWhenDisabled=0`, the flag disappears completely while disabled (good enough as a gameplay rule + avoids illegal "team flags" in PD).
- Optional: a friendly-only `trigger_catapult` pad (96x96) can be templated alongside the flag for a small team-only hop.
- `env_entity_maker` + `point_template` spawns the flag + denier trigger together as a unit.
- `teamplay_flag_event` is the authoritative signal for PD pickup + merge (a merge is just another pickup while already carrying).

## Map Setup (Recommended Naming)

### Script

- `logic_script` targetname: `scripter`
- `vscripts`: `flagspawn.nut`

### Merge Tracking (Required)

Add a `logic_eventlistener`:

- targetname: `flag_listener`
- `EventName`: `teamplay_flag_event`
- `FetchEventData`: `1`
- Connections:
  - `OnEventFired` -> `scripter` : `CallScriptFunction` : `FS_OnFlagEvent`

### Team Filters

Add two `filter_activator_tfteam`:

- `fs_filter_red` with `TeamNum=2`
- `fs_filter_blu` with `TeamNum=3`

### Prototypes (Template Sources)

Create prototype entities somewhere out of play (or in a sealed box) to be used by `point_template`:

- `item_teamflag` prototypes:
  - `fs_flag_proto_red`
  - `fs_flag_proto_blu`
  - Keyvalues (minimum):
    - `GameType=6`
    - `TeamNum=0`
    - `NeutralType=1`
    - `VisibleWhenDisabled=0`
    - `ReturnTime=60` (or whatever you want)
- Flag outline (recommended; include in the template so it fixups to the spawned clone):
  - `tf_glow` `fs_glow_flag_proto_red` with `target=fs_flag_proto_red` and `glowcolor="255 0 0"`
  - `tf_glow` `fs_glow_flag_proto_blu` with `target=fs_flag_proto_blu` and `glowcolor="0 128 255"`
- Lock pad SFX (copied from `jumppad_128a.vmf`):
  - `ambient_generic` `fs_lockpad_sfx_proto` with `message="hl1/ambience/steamburst1.wav"`
- Enemy-denier triggers:
  - `trigger_multiple` `fs_lock_proto_deny_red`
    - `filtername=fs_filter_red`
    - `OnStartTouch` -> `fs_lockpad_sfx_proto` : `PlaySound`
    - `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnDenyPadTouch` (does `Disable`/`Enable` internally, and preserves ReturnTime)
    - Optional lock-pad boost + player glow: `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnLockPadTouch`
  - `trigger_multiple` `fs_lock_proto_deny_blu`
    - `filtername=fs_filter_blu`
    - `OnStartTouch` -> `fs_lockpad_sfx_proto` : `PlaySound`
    - `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnDenyPadTouch` (does `Disable`/`Enable` internally, and preserves ReturnTime)
    - Optional lock-pad boost + player glow: `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnLockPadTouch`
- Friendly pad catapults (optional, 96x96, team-only):
  - `trigger_catapult` `fs_proto_red_friendly_pad`
    - `filtername=fs_filter_red`
    - `launchDirection="0 0 1"` (tweak `playerSpeed`/`physicsSpeed` to taste)
    - `OnCatapulted` -> `fs_lockpad_sfx_proto` : `PlaySound`
    - `OnCatapulted` -> `scripter` : `CallScriptFunction` : `FS_OnLockPadTouch` (for optional glow; script skips extra impulse on catapult triggers)
  - `trigger_catapult` `fs_proto_blu_friendly_pad`
    - `filtername=fs_filter_blu`
    - `launchDirection="0 0 1"` (tweak `playerSpeed`/`physicsSpeed` to taste)
    - `OnCatapulted` -> `fs_lockpad_sfx_proto` : `PlaySound`
    - `OnCatapulted` -> `scripter` : `CallScriptFunction` : `FS_OnLockPadTouch`

The important detail is that the denier trigger is included in the same template as the flag, so the I/O fixup targets the spawned clone (not the prototype).

### Templates + Makers (2 variants)

Create two `point_template` + `env_entity_maker` pairs so each spawned pickup denies the enemy team:

- On the `point_template`, keep the prototypes in the map, but keep name fixup enabled (so each spawned deny trigger/glow only targets its own spawned flag).
- Do **not** enable `Preserve entity names` on the `point_template` (it disables name fixup and causes `tf_glow: only one target is supported` when multiple clones exist).
- Align the `point_template` origin with the flag prototype origin (keeps `ForceSpawnAtEntityOrigin` spawns centered on the player).
- If you still see non-suffixed names, add a dummy keyvalue to each template entity that references its own name (example: `template_fixup=fs_flag_proto_red`) to force name fixup.
- `point_template` `fs_flag_template_red`
  - `Template01=fs_flag_proto_red`
  - `Template02=fs_lock_proto_deny_blu`
  - `Template03=fs_glow_flag_proto_red` (recommended)
  - `Template04=fs_lockpad_sfx_proto` (recommended)
  - `Template05=fs_proto_red_friendly_pad` (optional)
- `env_entity_maker` `fs_flag_maker_red`
  - `EntityTemplate=fs_flag_template_red`
- `point_template` `fs_flag_template_blu`
  - `Template01=fs_flag_proto_blu`
  - `Template02=fs_lock_proto_deny_red`
  - `Template03=fs_glow_flag_proto_blu` (recommended)
  - `Template04=fs_lockpad_sfx_proto` (recommended)
  - `Template05=fs_proto_blu_friendly_pad` (optional)
- `env_entity_maker` `fs_flag_maker_blu`
  - `EntityTemplate=fs_flag_template_blu`

Optional: on the makers, use `PostSpawnDirection`/`PostSpawnSpeed` for a tiny pop so the spawned pickup immediately touches the player.

### Team Spawners (Dispense Zones)

Create `trigger_multiple` zones where players get a pickup "teleported onto them":

- Red spawner triggers:
  - set `filtername=fs_filter_red`
  - `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnSpawnerTouchRed`
- Blu spawner triggers:
  - set `filtername=fs_filter_blu`
  - `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnSpawnerTouchBlu`

The script calls `ForceSpawnAtEntityOrigin` on the matching maker, using the player as the spawn origin, so PD consumes the pickup immediately.

## Script Notes

- Cooldown: `flagspawn.CFG.DISPENSE_COOLDOWN`
- Lock pad tuning + player glow: `flagspawn.CFG.LOCKPAD_*`
- Merge-proof cleanup (recommended): `flagspawn.CFG.CLEANUP_ON_PICKUP` + `flagspawn.CFG.CLEANUP_BASE_NAMES`
- Cleanup eventtypes (if pickup codes differ on your build): `flagspawn.CFG.CLEANUP_EVENTTYPES`
- Debug: `script flagspawn.DumpCarriers()`
- Meter (optional, off by default): `flagspawn.CFG.ENABLE_PLAYER_METER`
  - Uses `SetBodyGroup` on `flagspawn.CFG.METER_MODEL` to reflect current carried points (driven by `teamplay_flag_event`).

## Dropped-only pad/glow/FX (lifecycle)

`point_template` spawns persistent entities (nothing auto-cleans), so if you add pad/glow/FX entities alongside the flag you must manage their lifecycle.

If you want the pad + glow + SFX/VFX to exist only while the flag is on the ground:

- Enable/show while dropped (ground flag).
- Disable/hide immediately when the flag is picked up.
- Re-enable on drop.
- Kill/clean up on return/capture.

You can *try* to do this with `item_teamflag` outputs on the flag prototype:

- `OnPickup1` -> disable/stop pad entities (deny trigger, catapult, idle particles, glows, loops)
- `OnDrop1` -> enable/start them again
- `OnReturn` / `OnCapture` -> `Kill` them

Important: in PD, merges while already carrying can be unreliable for `item_teamflag` outputs. For merge-proof cleanup, do it in VScript using `teamplay_flag_event` (flagname + eventtype) and kill/disable the associated spawned pad entities there.
