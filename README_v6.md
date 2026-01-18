# Flagspawn v6 (Hybrid Reparent + Economy + Robust `tf_glow` Retarget)

This README describes the **current implementation plan** for Flagspawn v6 and how to wire it in Hammer (based on `fs3_test.vmf`).

---

## Goals (what v6 is trying to be)

1. **One Big Flag**: the spawner emits **one** `item_teamflag` worth as many points as possible (clamped to 100) so we don’t explode the entity count.
2. **Hard Active Limit (25)**: there may be at most **25 active flags** per team at once. When full:
   - the spawner does nothing
   - `point_worldtext` shows `0`
   - the lock sprite can show
3. **Economy Loop**:
   - **Spend**: spawning reduces the team pool
   - **Refund**: **Return/Capture** refunds the flag value into the pool and **kills** the flag so it doesn’t “return to base” and consume a slot
   - **Sink**: **Merge** is a money sink (no refund) to prevent infinite inflation
4. **Cosmetics / Visibility (“hybrid reparenting”)**:
   - **Dropped**: `item_teamflag` is visible
   - **Carried**: `item_teamflag` is hidden and (optional) a `prop_dynamic` meter is attached to the carrier’s head
5. **Glow Logic**:
   - **TopK highlights**: the **5 highest-value flags** are always glowed
   - **Event glow**: spawn/pickup/drop/pinata/damage briefly “force glows” additional flags

---

## Critical project rules

- **Never call `GetAbsOrigin()` on players.**
- Spawner prop meter uses **bodygroup index 1**: `SetBodyGroup(1, value)`.
- **Do not rely on `point_template` Name Fixup for `tf_glow` target.**
  - `tf_glow` has a known quirk: the `target` keyvalue does not behave like normal I/O fixups.
  - v6 fixes this by retargeting in VScript using `NetProps.SetPropEntity(glow, "m_hTarget", entityHandle)`.

---

## File install

- Put the script at:
  - `tf/scripts/vscripts/flagspawnv6.nut`
- Update your `logic_script` to load it:
  - `vscripts = flagspawnv6.nut`

---

## Entities required (Blu-side)

These names are what the script expects by default.

### Controller / script
- `logic_script` **`scripter`**
  - `vscripts = flagspawnv6.nut`

### Spawner
- `trigger_multiple` **`fs_spawner_blu`**
  - **OnStartTouch** → `scripter` **CallScriptFunction** `FS_OnSpawnerTouchBlu()`
  - (Optional) put your team filter here; v6 checks team in script anyway.

- `env_entity_maker` **`fs_flag_maker_blu`**
  - **IMPORTANT**: `spawnflags` must include **1** (unique name suffix / name fixup)
  - `EntityTemplate = bluflag_template`
  - **OnEntitySpawned** → `scripter` RunScriptCode `FS_OnMakerSpawned()`

### UI / feedback
- `point_worldtext` **`blu_pool_text`**
  - script uses input `SetMessage` to show **slots remaining**

- `env_sprite` **`blu_spawner_lock`**
  - script uses `ShowSprite` / `HideSprite` when full vs not full

- `prop_dynamic` **`blu_flagspawner_prop`**
  - script sets bodygroup **(1, clampedPool)** to show pool value (0–100)

---

## The template package (`point_template`) 

`point_template` **`bluflag_template`** should have **Name Fixup = 1** and include (minimum):

1. `item_teamflag` **`bluflag`**
2. `tf_glow` **`bluflag_glow`**
   - `StartDisabled = 1`
   - `Mode = 2` (outline)
   - NOTE: the template’s `target = bluflag` is **not reliable** for spawned copies → v6 retargets using NetProps.
3. `info_target` **`blu_lmm_target`** (optional but recommended if you’re using a follower)
4. `trigger_multiple` **`red_lock_bluflag`** (optional “deny pad”)

Optional visual add-ons (v6 supports them *if present*):
- `prop_dynamic` **`bluflag_prop`** (the meter mesh you attach to player)

> Your current `fs3_test.vmf` template includes `bluflag`, `bluflag_glow`, `blu_lmm_target`, `red_lock_bluflag`.
> It does **not** include `bluflag_prop` yet — v6 will simply skip prop attachment if it doesn’t exist.

---

## Event listeners (required for economy + pinata/chunks)

### Flag events
- `logic_eventlistener` **`flag_listener`**
  - `EventName = teamplay_flag_event`
  - `FetchEventData = 1`
  - **OnEventFired** → `scripter` **CallScriptFunction** `FS_OnFlagEvent()`

**Structure (no flag identifier):**
- `short player` — player this event involves
- `short carrier` — the carrier if needed
- `short eventtype` — see IDs below
- `byte home` — only set for PICKUP
- `byte team` — which team the flag belongs to

**Standard `eventtype` IDs (TF2):**
- `1` Picked Up
- `2` Captured
- `3` Defended
- `4` Dropped
- `5` Returned

Important: `teamplay_flag_event` does **not** include a flag entindex/name, so you can’t reliably know *which* specific flag instance was returned/captured when multiple flags exist.

This powers:
- Generic event-driven retries/FX/logging.
- Pickup/Drop catchups (plus direct pickup/drop outputs if you add them).

### Player events
You want **separate** listeners:

- `logic_eventlistener` **`player_spawn_listener`**
  - `EventName = player_spawn`
  - `FetchEventData = 1`
  - OnEventFired → `FS_OnPlayerSpawn_Event()`

- `logic_eventlistener` **`player_death_listener`**
  - `EventName = player_death`
  - `FetchEventData = 1`
  - OnEventFired → `FS_OnPlayerDeathEvent()`

- `logic_eventlistener` **`player_hurt_listener`**
  - `EventName = player_hurt`
  - `FetchEventData = 1`
  - OnEventFired → `FS_OnPlayerHurtEvent()`

---

## Direct outputs (recommended “instant catch”)

Even with `teamplay_flag_event`, the engine can be a frame late (merges, fast pickups). Add these outputs on the spawned flag:

- `item_teamflag` output **OnPickup** → `scripter` CallScriptFunction `FS_Direct_Pickup()`
- `item_teamflag` output **OnDrop** → `scripter` CallScriptFunction `FS_Direct_Drop()`
- `item_teamflag` output **OnReturn** → `scripter` CallScriptFunction `FS_Direct_Refund()`
- `item_teamflag` output **OnCapture** → `scripter` CallScriptFunction `FS_Direct_Refund()`

v6 will then do a few retry ticks for that specific flag to make sure the cosmetic state “sticks”.

---

## What v6 does internally

### Tracking
- On spawn, v6 registers a “package” by suffix:
  - `bluflag&####`
  - optional siblings: `bluflag_glow&####`, `blu_lmm_target&####`, `red_lock_bluflag&####`, `bluflag_prop&####`

### Bodygroups
- When a flag’s point value changes, v6 tries to set bodygroup **1** on:
  - the authoritative `item_teamflag`
  - the optional `prop_dynamic` meter

### Visual state
- **Carried**
  - `flag.DisableDraw`
  - attach `prop` to player and `prop.Enable`
  - glow target → **player**

- **Dropped**
  - `flag.EnableDraw`
  - `prop.Disable` (and optionally parent it back to LMM target)
  - glow target → **flag**

### Glow retarget (the important part)
- `point_template` fixups don’t reliably fix `tf_glow.target`.
- v6 calls:
  - `NetProps.SetPropEntity(glow, "m_hTarget", <entityHandle>)`

So even if the glow still thinks its target is `bluflag`, the netprop is the real target.

---

## Pinata & damage chunks

### Pinata (death)
If a player is carrying a flag and they die:
- delete the carried flag
- spawn up to **5** chunks
  - each chunk value = `floor(totalValue * 0.20)`
  - remainder is destroyed

### Damage chunks (hurt)
If enabled:
- accumulate damage
- every time you cross `MaxHP * 0.125` damage, drop a chunk:
  - chunk value = `floor(currentValue * 0.20)`
  - subtract from carried flag (minimum 1)

Both events also temporarily “force glow” involved flags.

---

## Known required fixes in `fs3_test.vmf`

Your uploaded `fs3_test.vmf` has a few wiring/typo issues that will break events:

1. **Spawner trigger calls the wrong function**
   - Currently: `FS_OnMakerSpawned()` on touch
   - Should be: `FS_OnSpawnerTouchBlu()`

2. **logic_eventlistener key typo**
   - Several listeners use `FetchEventDate` (wrong)
   - Should be: `FetchEventData`

3. **The second “death” listener is actually hurt**
   - There is a `logic_eventlistener` named `player_death_listener` whose output calls `FS_OnPlayerHurtEvent()`
   - It should be:
     - `targetname = player_hurt_listener`
     - `EventName = player_hurt`
     - output calls `FS_OnPlayerHurtEvent()`

If you fix those three, v6’s event-driven pieces behave much more predictably.

---

## Debugging checklist

1. In console:
   - `developer 2`
   - `glow_outline_effect_enable 1`

2. Validate spawn pipeline:
   - touch spawner → should print `[FS6] SpawnerTouch...`
   - maker OnEntitySpawned → should print `Registered flag suffix...`

3. Validate glow targeting:
   - on drop: glow should outline the flag
   - on pickup: glow should outline the player

If something doesn’t stick, v6 will re-try a few times on the next pulse after the direct event.

---

## Next TODOs

- Add RED-side parity (duplicate CFG + state tables, or generalize to team loops)
- Tune thresholds / chunk sizing
- Decide whether dropped glow should be flag vs prop meter (config toggle)
- Optional: keep TopK flags always “forced glow” across events
