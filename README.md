# Flagspawn (PD Team-Locked Pickups)

This repo uses TF2's built-in Player Destruction (PD) pickup + merge system, but adds a map/template pattern (see `fs1_test.vmf`) that makes pickups effectively team-locked even though PD wants neutral flags.

## How It Works (fs1_test pattern)

- Each pickup is an `item_teamflag` configured for PD (`GameType=6`, `TeamNum=0`, `NeutralType=1`), so PD merging works normally.
- Each pickup is packaged with an enemy-only `trigger_multiple` that acts like a "deny pad":
  - On enemy touch, the flag is `Disable`d (blocking pickup), and the enemy gets launched forward + slightly upward (a speed-pad feel).
  - Because the pad launches the enemy out of the trigger, the disable window is naturally brief and can't be held indefinitely by just standing there.
  - Optional: give the speed pad taker (player - `!activator`) a brief `tf_glow` outline when the pad triggers (readability).
  - With `VisibleWhenDisabled=0`, the flag disappears completely while disabled (good enough as a gameplay rule + avoids illegal "team flags" in PD).
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
- Enemy-denier triggers:
  - `trigger_multiple` `fs_lock_proto_deny_red`
    - `filtername=fs_filter_red`
    - `OnStartTouch` -> `fs_flag_proto_blu` : `Disable`
    - `OnEndTouchAll` -> `fs_flag_proto_blu` : `Enable`
    - Optional speed pad: `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnLockPadTouch`
    - Optional SFX/VFX (copy from `jumppad_128a.vmf`):
      - `ambient_generic` sound: `message=hl1/ambience/steamburst1.wav` (`jumpsfx_*`)
      - `info_particle_system`: `effect_name=fx_jumppad_a_cloudburst` (`jumpfx_*`)
      - `OnStartTouch` -> `jumpsfx_*` : `PlaySound`
      - `OnStartTouch` -> `jumpfx_*` : `Start`
      - `OnStartTouch` -> `jumpfx_*` : `Stop` (delay ~1.0s)
  - `trigger_multiple` `fs_lock_proto_deny_blu`
    - `filtername=fs_filter_blu`
    - `OnStartTouch` -> `fs_flag_proto_red` : `Disable`
    - `OnEndTouchAll` -> `fs_flag_proto_red` : `Enable`
    - Optional speed pad: `OnStartTouch` -> `scripter` : `CallScriptFunction` : `FS_OnLockPadTouch`
    - Optional SFX/VFX (copy from `jumppad_128a.vmf`):
      - `ambient_generic` sound: `message=hl1/ambience/steamburst1.wav` (`jumpsfx_*`)
      - `info_particle_system`: `effect_name=fx_jumppad_a_cloudburst` (`jumpfx_*`)
      - `OnStartTouch` -> `jumpsfx_*` : `PlaySound`
      - `OnStartTouch` -> `jumpfx_*` : `Start`
      - `OnStartTouch` -> `jumpfx_*` : `Stop` (delay ~1.0s)

The important detail is that the denier trigger is included in the same template as the flag, so the I/O fixup targets the spawned clone (not the prototype).

### Templates + Makers (2 variants)

Create two `point_template` + `env_entity_maker` pairs so each spawned pickup denies the enemy team:

- `point_template` `fs_flag_template_red`
  - `Template01=fs_flag_proto_red`
  - `Template02=fs_lock_proto_deny_blu`
- `env_entity_maker` `fs_flag_maker_red`
  - `EntityTemplate=fs_flag_template_red`
- `point_template` `fs_flag_template_blu`
  - `Template01=fs_flag_proto_blu`
  - `Template02=fs_lock_proto_deny_red`
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
- Lock pad (deny pad) tuning: `flagspawn.CFG.LOCKPAD_*`
- Debug: `script flagspawn.DumpCarriers()`
- Meter (optional, off by default): `flagspawn.CFG.ENABLE_PLAYER_METER`
  - Uses `SetBodyGroup` on `flagspawn.CFG.METER_MODEL` to reflect current carried points (driven by `teamplay_flag_event`).
