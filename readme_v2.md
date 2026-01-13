# Flagspawn (PD Fuel)

Hybrid TF2 mode: the engine's Player Destruction (PD) system owns pickup/merge physics; this VScript owns value accounting, damage/death spill, banking, and visuals.

This README documents the locked-in architecture and event model. Some implementation details may still be mid-migration in `flagspawn.nut`.

## Core Rules (Non-Negotiable)

1. PD owns merging.
   - Script does not try to "force merge" with teleport/delete hacks.
2. Script owns VALUE.
   - The authoritative carried total is tracked in script state, not in PD internals.
3. Event-driven, not pulse-driven.
   - `teamplay_flag_event` is the authoritative signal for pickups and PD merges.
   - `item_teamflag` outputs (`OnPickup*`) are unreliable in PD merges (they often do not fire when already carrying).
4. Keep PD's carry system alive.
   - Set `tf_logic_player_destruction.PointsOnPlayerDeath = 1`.
   - Then remove the engine's death-dropped flags in script and replace with controlled "pinata" spill.

## Mental Model (One Sentence)

PD decides how pickups attach/merge onto players; the script decides how much they are worth and what gets spawned/removed on damage/death/capture.

## Required Events

### `teamplay_flag_event` (authoritative)

- Use this for pickup AND merge detection.
- `eventtype == 1` behaves like "pickup semantics" (including PD merges while already carrying).
- `eventtype == 4` is "dropped" (and other values exist; treat unknowns carefully).

Why: PD merges are not a separate event; a merge is simply a pickup while already carrying.

### `player_hurt`

Drives the damage-to-spill system (see "Damage -> Flag Chunking").

### `player_death`

Used to:

- flush pending damage once (so damage still counts)
- kill engine-spawned PD death drops (ASAP)
- spawn controlled death spill (script-owned pickups)

## Authoritative Data Model

Per player (script truth):

- `CarryValue[player]` (integer)

Per spawned pickup (script-owned; set in script scope):

- `fs_isFlagspawn = true`
- `fs_value = <int>`
- `fs_beneficiaryTeam = <2|3|0>`
- optional: `fs_no_return = true` for special chunks

Entity state (conceptual):

- WORLD -> CARRIED (by PD) -> CONSUMED (PD may delete the world entity on merge)

Important: PD may delete the world `item_teamflag` when it merges; treat the entity as disposable and do not rely on it existing after pickup.

## Damage -> Flag Chunking (Final Agreed Plan)

### Goal

- All damage "counts" (burst, DoT, minigun).
- No 1-damage spam (avoid constant tiny entities).
- Responsive: chunks happen during damage.
- One chunk at a time: readable visuals, sane entity counts.

### 1) Windowed accumulation with a fixed tick

- Accumulate `pendingDamage` per carrier.
- Spawn at most one spill chunk every `0.5s` per carrier while damage continues.
- If damage stops, the system goes idle naturally.

Per carrier state:

- `pendingDamage` (float)
- `lastDamageAt` (time)
- `nextTickAt` (time)

Timer logic:

- On first damage: `nextTickAt = now + 0.5`
- On tick fire: resolve once, clear `pendingDamage`, reschedule if damage continues
- If no damage for ~`0.6s`: stop ticking and clear state

### 2) Damage ladder -> points (no zero-point chunks)

Compute:

```
frac = pendingDamage / maxHP
```

Then apply:

```
if frac < 0.125:
    pts = 1
else:
    pts = 2 + floor((frac - 0.125) / 0.08)
```

Clamp:

```
pts = min(pts, carry - 1)  // carrier never drops below 1
```

Rules:

- If any damage happened, there is never a 0-point chunk.
- 12% -> 1 point; 13% -> 2 points.

### 3) Spawn behavior

- Spawn exactly 1 pickup per tick with value = `pts`.
- Launch backward (catapult/trajectory system).
- Subtract from `CarryValue[player]` immediately (script truth).

## Death & Interrupt Rules

### Flush immediately (damage still counts)

- On `player_death`: spawn one final chunk using current `pendingDamage`, then clear damage state.
  - Only do this if death spill is not already handled elsewhere (pick one owner).

### Clear without flushing

Use when carrying legitimately ends (no payout):

- capture/deposit
- round end/restart
- script reload/init
- carry value <= 1
- disconnect / team change / class change
- carrier loses flag via script/system

## Death Drop Interception (Keep Merges, Kill Vanilla Drops)

We do NOT want the engine's PD death vomit, but we DO want PD merging to remain intact.

1. Map setting:
   - `tf_logic_player_destruction.PointsOnPlayerDeath = 1` (keeps PD carry system active)
2. Script action:
   - On `player_death`, wait a tiny delay (`0.0` to `0.05s`) so the engine spawns its drops.
   - Find nearby `item_teamflag` entities and kill/stash any that are NOT script-owned:
     - not in pool
     - no `fs_isFlagspawn` marker in script scope
   - Then spawn controlled death spill pickups (script-owned) using the economy rules.

Result:

- PD merging remains intact
- vanilla death drops are removed ASAP
- only script-owned spill remains (and those merge normally)

## Mergeable Spawn Requirements (For Every Spawned Pickup)

To reliably merge in PD, every spawned pickup must be:

- classname: `item_teamflag`
- `GameType = 6` (PD)
- neutral/team setup consistent with your rules
- spawned slightly offset so touch triggers immediately
- fully configured (value + script markers) before it can be touched

## Map Wiring (Recommended)

### Logic script

- `logic_script` targetname: `scripter`
- script file: `flagspawn.nut`

### Flag event listener (required for merges)

`logic_eventlistener` (targetname: `flag_listener`):

- `EventName`: `teamplay_flag_event`
- `Fetch Event Data`: `Yes`

Output:

- `OnEventFired -> scripter -> CallScriptFunction -> FS_OnFlagEvent`

### PD logic

`tf_logic_player_destruction` (targetname: `fs_pd_logic`):

- `PointsOnPlayerDeath = 1`

## Debug Checklist (Console)

- `script printl("flagspawn" in getroottable())`
- `script printl("ListenToGameEvent" in getroottable())`
- `script local l=Entities.FindByName(null,"flag_listener"); if(l&&l.ValidateScriptScope()){ local sc=l.GetScriptScope(); printl("event_data" in sc); }`

## Notes on the Current Prototype

Some older iterations used pooled `item_teamflag` entities (`fs_pool_red_*` / `fs_pool_blu_*`) to avoid dynamic spawn costs. The long-term architecture does not depend on pools; it depends on `teamplay_flag_event` + script-owned value accounting.
