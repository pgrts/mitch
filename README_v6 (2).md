# Flagspawn v6 (Hybrid Reparent + Economy + NetProp `tf_glow`)

This README is the **current v6 plan + wiring guide** for `fs3_test.vmf`.

The two biggest takeaways (based on your latest findings/logs):

1) **Do NOT use `teamplay_flag_event` to identify a specific flag.** It does *not* provide an entity index for “which flag”.
2) **Drive refunds (Return/Capture) from the `item_teamflag` outputs**, because in those outputs, **`caller` IS the specific flag**.

---

## Hard project rules

- **Never call `GetAbsOrigin()` on players.**
- Spawner prop meter uses **bodygroup index 1**: `SetBodyGroup(1, value)`.
- `env_entity_maker` must have **spawnflags 1** (unique name suffix + fixup).
- **Do not rely on point_template Name Fixup to make `tf_glow` follow a suffix targetname.**
  - v6 retargets glow by **writing the entity handle** into `tf_glow`’s netprop.

---

## What v6 implements

### Economy loop
- **Spend**: spawning a flag subtracts from the team pool.
- **Refund**: **Return/Capture** adds the flag’s value back into the pool and **kills the flag** so it doesn’t “return to base” and consume a slot.
- **Sink**: **Merge** deletes a flag with **no refund**.

### Hard active limit (25)
- The script tracks how many unique flags exist (dropped + carried).
- When `active >= LIMIT_ACTIVE_FLAGS`:
  - the spawner refuses to spawn
  - worldtext displays `0`
  - optional lock sprite shows

### Visual truth table
- **Dropped**
  - Flag model visible (PD)
  - Meter prop parented to `blu_lmm_target` follower
  - Glow targets the flag (or the prop, depending on your preference)

- **Carried**
  - Flag model hidden (PD)
  - Meter prop parented to player attachment (`partyhat`)
  - Glow targets the **player**

### Glow control
- `tf_glow` target is set via:
  - `NetProps.SetPropEntity(glow, "m_hTarget", entityHandle)`

This avoids the “Name Fixup doesn’t touch the `tf_glow` internal target handle” problem.

---

## Files

- VScript: `scripts/vscripts/flagspawn.nut` (or whatever name you load)

---

## Required entities (Blu side)

### Controller
- `logic_script` **`scripter`**
  - `vscripts = flagspawn.nut`

### Spawner
- `trigger_multiple` **`fs_spawner_blu`**
  - OnStartTouch → `scripter` → `CallScriptFunction` → `FS_OnSpawnerTouchBlu()`

- `env_entity_maker` **`fs_flag_maker_blu`**
  - `spawnflags` includes **1**
  - `EntityTemplate = bluflag_template`
  - OnEntitySpawned → `scripter` → `RunScriptCode` → `FS_OnMakerSpawned()`
    - (RunScriptCode is fine here; we don’t need event_data, just `caller`.)

### UI / meters
- `point_worldtext` **`blu_pool_text`**
  - IMPORTANT: **point_worldtext has no SetMessage input**.
  - v6 updates the text via `AddOutput` → `message <value>`.

- `env_sprite` **`blu_spawner_lock`** (optional)
  - v6 uses `ShowSprite` / `HideSprite`

- Pool meter props:
  - **single meter:** `blu_flagspawner_prop`
  - **OR segmented meters for pool > 100:** `blu_flagspawner_prop01`..`blu_flagspawner_prop05`

#### Showing a pool up to 500 on 5 props
In the script config:
- `SPAWNER_PROP_BLU_COUNT = 5`
- `SPAWNER_PROP_BLU_PREFIX = "blu_flagspawner_prop"`
- (optional) `POOL_HARDCAP = 500`

Segment display behavior:
- Prop01 shows `min(pool,100)`
- Prop02 shows `min(max(pool-100,0),100)`
- ...
- Prop05 shows `min(max(pool-400,0),100)`

---

## Template package (`point_template` bluflag_template)

Name Fixup must be enabled.

Minimum members:
- `item_teamflag` **`bluflag`**
- `tf_glow` **`bluflag_glow`**
- `info_target` **`blu_lmm_target`** (if you’re using a follower)
- `trigger_multiple` **`red_lock_bluflag`** (deny pad)

Optional member:
- `prop_dynamic` **`bluflag_prop`** (the meter that gets reparented)

---

## The IMPORTANT wiring change: refunds must be direct outputs

### Why
`teamplay_flag_event` tells you *what happened*, but not *which flag entity did it*.
So **refunds cannot be reliably attributed** when multiple flags exist.

### What to do
On the `item_teamflag` inside your template (`bluflag`), add:

- **OnPickup** → `scripter` → `CallScriptFunction` → `FS_Direct_Pickup()`
- **OnDrop** → `scripter` → `CallScriptFunction` → `FS_Direct_Drop()`
- **OnReturn** → `scripter` → `CallScriptFunction` → `FS_Direct_Refund()`
- **OnCapture** → `scripter` → `CallScriptFunction` → `FS_Direct_Refund()`

Now the script gets:
- `caller = the specific bluflag&#### entity`
- `activator = player (for pickup/drop)`

…and refunds work reliably.

---

## Player event listeners (for pinata + damage chunks)

These need `event_data`, so **FetchEventData must be spelled correctly**.

- `logic_eventlistener` `player_spawn_listener`
  - EventName: `player_spawn`
  - FetchEventData: **1**
  - OnEventFired → `scripter` → `CallScriptFunction` → `FS_OnPlayerSpawn_Event()`

- `logic_eventlistener` `player_death_listener`
  - EventName: `player_death`
  - FetchEventData: **1**
  - OnEventFired → `scripter` → `CallScriptFunction` → `FS_OnPlayerDeathEvent()`

- `logic_eventlistener` `player_hurt_listener`
  - EventName: `player_hurt`
  - FetchEventData: **1**
  - OnEventFired → `scripter` → `CallScriptFunction` → `FS_OnPlayerHurtEvent()`

If you ever see missing `event_data` in console:
- 99% of the time it’s **FetchEventData typo** or **using RunScriptCode instead of CallScriptFunction**.

---

## Team leader / pd_dispenser note

If you’re trying to kill the “team leader dispenser / leader pulse” behavior:
- Prefer: **clear leader netprops on your `tf_logic_player_destruction`** (e.g. `fs_pd_logic`)
- Avoid repeatedly killing `pd_dispenser` (it can produce the `NULL pstudiohdr` warnings you saw)

---

## Debug checklist

1) Turn on:
- `developer 2`
- `glow_outline_effect_enable 1`

2) Validate text is updated:
- worldtext should change (via AddOutput), no “unhandled input SetMessage” spam

3) Validate refunds:
- Return/Capture should log `Direct Refund` and refill pool meters

4) Validate pinata/chunks:
- If no chunks, look for missing `event_data` logs → fix listeners

