# Flagspawn v6 (Hybrid Reparent + Budget Bonus + NetProp `tf_glow`)

This README is the current v6 plan + wiring guide for `fs3_test.vmf`.

## Two biggest takeaways (latest)

1) Do NOT use `teamplay_flag_event` to identify a specific flag. It does not include a flag entindex/name.
2) Drive Return/Capture refunds from `item_teamflag` outputs, because in those outputs `caller` IS the specific flag.

## Hard project rules

- Never call `GetAbsOrigin()` on players.
- `fs_meter` fill bodygroup uses index `1`: `SetBodyGroup(1, value)`.
- Do not rely on `point_template` NameFixup to fix `tf_glow` targets for spawned copies.
  - v6 retargets glows via `NetProps.SetPropEntity(glow, "m_hTarget", handle)`.

## Economy model (v6)

- Spawn slots: max `25` active spawned flags (`LIMIT_ACTIVE_FLAGS`); this is what `point_worldtext` shows.
- Budget bonus (points): starts at `0`, increases only on Return/Capture, and does not decrement on spawn.
  - Merges destroy flags without Return/Capture, so they do not add to the budget bonus.
- Spawned flag value: `budgetBonus + classBonus` clamped to `VALUE_CAP` (default `100`).
  - Default class bonus: Heavy=5, Sniper=3, Soldier=2, everyone else=1 (`CLASS_VALUE_BONUS`).

## Visual truth table

- Dropped: flag visible (PD), optional meter prop parented to `blu_lmm_target` but hidden, glow targets flag.
- Carried: flag hidden (PD), optional meter prop attached to player, glow targets player mesh.

## Files

- Script: `tf/scripts/vscripts/flagspawn.nut`

## Required entities (Blu side)

### Controller
- `logic_script` `scripter`
  - `vscripts = flagspawn.nut`

### Spawner trigger
- `trigger_multiple` `fs_spawner_blu`
  - `OnStartTouch` -> `scripter` -> `RunScriptCode` -> `FS_OnSpawnerTouchBlu()`

### Maker
- `env_entity_maker` `fs_flag_maker_blu`
  - `spawnflags` includes `1` (name fixup / unique suffix)
  - `EntityTemplate = bluflag_template`
  - `OnEntitySpawned` -> `scripter` -> `RunScriptCode` -> `FS_OnMakerSpawned()`

### UI / meters
- `point_worldtext` `blu_pool_text`
  - v6 updates text via `AddOutput` -> `message <slotsRemaining>`
  - IMPORTANT: `point_worldtext` does not have `SetMessage` (that is `game_text`)

- `env_sprite` `blu_spawner_lock`
  - place this near `blu_pool_text`
  - v6 uses `ShowSprite` / `HideSprite` when slots reach `0`

- `prop_dynamic` meters (segmented): `blu_flagspawner_prop01..05`
  - each prop shows `0..100` using bodygroup index `1`
  - total display is `0..500` (5 segments)

## Template package (`point_template`)

`point_template` `bluflag_template` should have `Name Fixup = 1` and include (minimum):

1) `item_teamflag` `bluflag`
2) `tf_glow` `bluflag_glow` (often `StartDisabled = 1`, `Mode = 2`)
3) `info_target` `blu_lmm_target` (recommended)
4) `trigger_multiple` `red_lock_bluflag` (optional deny trigger)

Optional (if included, v6 will use it):
- `prop_dynamic` `bluflag_prop` (meter model to attach to player)

### Required direct outputs on `item_teamflag`

These outputs run in the context of the specific flag instance, so `caller` is correct.

- `OnPickup`  -> `scripter` -> `CallScriptFunction` -> `FS_Direct_Pickup`
- `OnDrop`    -> `scripter` -> `CallScriptFunction` -> `FS_Direct_Drop`
- `OnReturn`  -> `scripter` -> `CallScriptFunction` -> `FS_Direct_Refund`
- `OnCapture` -> `scripter` -> `CallScriptFunction` -> `FS_Direct_Refund`

Note: `CallScriptFunction` wants the function name only (no parentheses).

## Event listeners (required for pinata/chunks + debug cadence)

### Flag events (global)
- `logic_eventlistener` `flag_listener`
  - `EventName = teamplay_flag_event`
  - `FetchEventData = 1`
  - `OnEventFired` -> `scripter` -> `CallScriptFunction` -> `FS_OnFlagEvent`

`teamplay_flag_event` structure (no flag identifier):
- `short player`
- `short carrier`
- `short eventtype` (1 pickup, 2 capture, 3 defend, 4 dropped, 5 returned)
- `byte home` (only set for pickup)
- `byte team`

### Player events
- `logic_eventlistener` `player_spawn_listener` (`player_spawn`, `FetchEventData = 1`)
  - `OnEventFired` -> `FS_OnPlayerSpawn_Event`
- `logic_eventlistener` `player_death_listener` (`player_death`, `FetchEventData = 1`)
  - `OnEventFired` -> `FS_OnPlayerDeathEvent`
- `logic_eventlistener` `player_hurt_listener` (`player_hurt`, `FetchEventData = 1`)
  - `OnEventFired` -> `FS_OnPlayerHurtEvent`

## Enemy pickup guard (RED denied)

If a RED player manages to pick up a spawned `bluflag&####` (timing hole), v6 does ForceDrop + snap-back to the last known dropped position.

