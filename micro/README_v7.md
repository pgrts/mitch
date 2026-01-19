# Flagspawn README v7 (In-Depth)
_Last updated: 2026-01-19 (America/New_York)_

This document captures the **last couple days of implementation work** and the current "correct" design for the Flagspawn PD/CTF hybrid: **stock-limited spawner**, **return/capture-driven economy**, **meter props starting empty**, **per-flag clamp to 100**, **per-player carry cap**, and the finalized **damage/death destruction rules**.

> If you're coming from older versions: the biggest behavioral shift is that **the spawner is NOT gated by pool/budget being >0**, and **we never trust the point_template default point value** (which was causing 100-value flags at round start).

---

## Install (Micro Folder)
TF2 expects these paths:
- `tf/scripts/vscripts/flagspawn.nut`
- `tf/scripts/vscripts/flagspawn/` (folder)

Copy from this repo:
- `micro/flagspawn.nut` -> `tf/scripts/vscripts/flagspawn.nut`
- `micro/flagspawn/` -> `tf/scripts/vscripts/flagspawn/`

---

## 0) Core Goals (What We Are Building)
### The loop
1. **Team spawner dispenses "bonus" flags** (item_teamflag) when you touch it.
2. Those flags represent **temporary value** you can carry to a **PD capturezone**.
3. **Capturing** converts that carried value into:
   - **Team score** (PD score)
   - **Team economy** (spawner bonus pool)
4. **Returning** dropped flags also replenishes economy.
5. **Damage** and **death** on carriers causes **chunk drops** and **value destruction** (anti-snowball).

### Non-negotiables we just implemented
- **Spawner meter props start at 0** (empty).  
  No "300 visible at start". Economy is earned via return/capture.
- **Per-flag point value clamps to 100**.
- **One player cannot drain 300**: the economy is dispensed in capped pieces and the player has a carry cap.
- Avoid crashes: **never use `GetAbsOrigin()` on players**; use safe wrappers (`_GetOrigin` etc.).
- Custom prop fill meter uses **bodygroup index 1**:
  - DO: `SetBodygroup(1, value)`
  - DON'T: `SetBodygroup(0, value)`

---

## 1) Two Separate "Economies" (This Was The Confusing Part)
We split the concept cleanly:

### A) Spawner **Stock** (How many flags can exist at once)
- **Stock is a hard cap**: `STOCK_LIMIT = 25`
- Stock is **NOT** "points". It's **count of active/pending flags**.
- Spawner denies if stock == 0.
- Stock counts **spawner-dispensed flags only** (pinata/damage chunks bypass stock).
- Optional lock icon: an `env_sprite` near the worldtext is shown when stock == 0 (`blu_spawner_lock` / `red_spawner_lock`).

**Why:** This prevents runaway template spam and makes the spawner behave like a reliable dispenser even when budget is 0.

### B) Spawner **Bonus Pool** (The 0-300 "earned" meter)
- Starts at **0**.
- Grows when:
  - flags are **returned**
  - flags are **captured**
- We visualize the **on-deck** pool portion on **3 synced meter props** (all show the same 0-60 number).
- The pool determines the **pool portion** of the next dispensed flag.

---

## 2) Spawner Meter Props (3 synced meters, start empty)
### Visual model expectations
- You have 3 `prop_dynamic` meter props on the spawner.
- They do **not** show total pool. They show the **on-deck** budget bonus (poolPortion) the spawner will add to the next flag.
- Class bonus is not included (it's per-player).
- **Bodygroup index is 1** (critical project rule).

### Naming convention
- `blu_flagspawner_prop01`
- `blu_flagspawner_prop02`
- `blu_flagspawner_prop03`

All three props are kept **in sync** (same bodygroup value). `prop01` is the main "budget bonus" meter; `prop02/03` are optional duplicates for visibility.

Config:
- `POOL_CAP = 300`
- `METER_COUNT = 3`

### Meter rendering logic
Let:
- `PoolBluTotal` range: `[0 .. POOL_CAP]` (we clamp for display)
- `POOL_CAP = 300` and `POOL_SHARE_DEN = 5` (so max onDeck is 60)

To render (same number on all 3 props):
- `onDeckMax = floor(POOL_CAP / POOL_SHARE_DEN)` (with current config: `300/5 = 60`)
- `onDeck = clamp(floor(PoolBluTotal / 5), 0, onDeckMax)`
- Call: `prop01/02/03.SetBodygroup(1, onDeck)`  

At round start, `PoolBluTotal = 0`, so **all props show 0**.

---

## 3) Spawner Dispense Value (Pool / 5 + Class Bonus, then clamps)
When a player touches the spawner:

### Step 1: Stock gate (NOT pool gate)
- Deny if active + pending flags >= 25.

### Step 2: Compute pool portion
- `poolPortion = floor(PoolBluTotal / 5)`  
This is the "20% of the earned bonus".

Examples:
- Pool=0 -> poolPortion=0
- Pool=200 -> poolPortion=40
- Pool=300 -> poolPortion=60

### Step 3: Add class bonus
- `dispenseValue = poolPortion + classBonus[playerClass]`

### Step 4: Clamp and carry cap
- Per-flag clamp: `dispenseValue = clamp(dispenseValue, SPAWN_MIN_VALUE, VALUE_CAP)` where `VALUE_CAP=100`
- Per-player carry cap: `carryLeft = max(0, CARRY_CAP - playerCurrentCarry)` where `CARRY_CAP=100`
- Final: `dispenseValue = min(dispenseValue, carryLeft)`

If `carryLeft <= 0`, deny (player already carrying 100).

### Step 5: Pool consumption
Default behavior: only the **pool portion** consumes the pool:
- `PoolBluTotal -= poolPortion`  
Class bonus does **not** drain the pool (meters stay "budget bonus only").

Optional variant (config toggle): if you want the spawner to drain **poolPortion + classBonus** instead, set:
- `POOL_CONSUME_CLASS_BONUS = true`

**Design effect:** Even at 300, the spawner dispenses in small capped pieces, and it takes multiple players (or multiple deposit cycles) to extract the full pool.

---

## 4) The "100-Value Flag At Start" Bug (Fixed)
**Problem:** Point template / item_teamflag default `point_value` was leaking into gameplay.  
If your template has 100, you'd spawn 100 even when pool=0.

**Fix (current standard):**
- Every spawned flag gets its `m_nPointValue` set explicitly from our computed spawn context.
- We never trust the template's point value.

---

## 5) Required VMF Wiring (Event Listener Reliability)
Over the last couple days, multiple failures came from VMF wiring mistakes:

### A) Spawner trigger output
Your `fs_spawner_blu` must call:

- `OnStartTouch` -> `scripter RunScriptCode` -> `FS_OnSpawnerTouchBlu()`

**Common mistake:** calling `FS_OnMakerSpawned()` on touch, which corrupts the spawn pipeline.

### B) logic_eventlistener: FetchEventData typo
If your entity has:
- `FetchEventDate` (wrong)

It must be:
- `FetchEventData` `"1"` (correct)

Without this, `event_data` is missing and your event handlers break.

### C) player_hurt vs player_death
If you want damage chunks, you MUST listen to:
- `EventName` `"player_hurt"`

Not `"player_death"`.

### D) Use CallScriptFunction for event handlers that need event_data
- DO: `CallScriptFunction(FS_OnPlayerHurtEvent)`
- DO: `CallScriptFunction(FS_OnPlayerDeathEvent)`
- DON'T: `RunScriptCode(FS_OnPlayerHurtEvent())` (drops event_data)

---

## 6) Capture / Return Hooks (Two different meanings)
We now treat capture and return as **economically different**:

### OnReturn -> `FS_Direct_Return`
- Refunds economy to the flag's owning team pool.
- Intended for "recovering dropped value".

### OnCapture -> `FS_Direct_Capture`
- Awards economy to the **capturer's team pool**.
- Uses the special capture formula (see below).

> Backward compatible alias:
> - `FS_Direct_Refund` = return

But: **capture tripling + first-blood bonus requires OnCapture to call `FS_Direct_Capture`.**

---

## 7) Capture Economy Bonus (3x + First Blood Timer)
When a player captures value `V`:

### Base award
- `award = V * 3`

### First Blood Timer bonus (first 3 capturers per team, per life)
We track a separate "first blood" window of:
- `FIRST_BLOOD_WINDOW = 180` seconds (3 minutes)

Timer starts when the script initializes (can be moved to a true round-start trigger later).

Within that 180s:
- `timeRemaining = max(0, 180 - elapsedSeconds)`
- If the player qualifies as one of the first 3 capturers **for their team**, and has not used their "first blood per life":
  - `award += timeRemaining`

**Examples**
- Capture 10 with 120 seconds left:
  - `10*3 + 120 = 150`
- Capture 10 with 1 second left:
  - `10*3 + 1 = 31`

### Per-person rules
- This bonus is tied to the **capturing player**, not "team capture total".
- It does NOT multiply per PD "point tick"; it applies to the capture event (per person / per capture).
- We also reset "one per life spawner use" on capture and triple your class budget

---

## 8) Damage Chunking (NEW: 10% destroyed + 20% chunk)
When a carrier hits the damage threshold, we apply:

Let `V` be current carried value:

### Damage destruction
- `destroy = max(1, floor(V * 0.10))`  
This value is removed from the game.

### Damage chunk spawn
- `chunk = max(1, floor(V * 0.20))`  
This becomes a spawned chunk flag Sent at a random trajectory opposite-ish of players forward velocity.


**Example: V=10**
- destroy = 1
- chunk = 2
- carrier keeps: 10 - 1 - 2 = 7
- one 2-point chunk spawns

**Small-value safety**
- We never set a flag's point value to 0 (it breaks PD merging).
- If damage-chunk math would force the carried flag to become 0/1 (or the flag is already tiny, like 1-2), we simply **kill the flag** instead.

---

## 9) Death Pinata (NEW: 20% destroyed "to the grave" + up to 4 shards)
On death, we intentionally destroy more value.

Let `V` be carried value at death:

### Grave destruction
- `grave = max(1, floor(V * 0.20))`
- Remaining: `R = V - grave`

### Shard size
- `shard = max(1, floor(V * 0.20))`

### Drop rule
- Drop up to **4 shards** of size `shard`:
  - `dropCount = min(4, floor(R / shard))`
  - Drop `dropCount` flags worth `shard` each

### Remainder destruction
- Any leftover remainder after those shards is destroyed:
  - `remainderDestroyed = R - (dropCount * shard)`

**Example: V=10**
- grave = 2
- R = 8
- shard=2
- dropCount=4
- drop 4 flags of 2
- remainderDestroyed=0

**Design intent:** killing carriers permanently deletes 20% and often deletes any odd remainder, ensuring carry value doesn't endlessly recycle.

**Small-value safety**
- If the carried flag is tiny (like 1-2), we just **kill it** on death (no 1-point shard spam).

---

## 10) Glow / Bodygroup Reliability Notes
### Bodygroup index
Spawner prop meter uses:
- `SetBodygroup(1, value)`

Flag models / dropped props must be assigned appropriately; if you are seeing bodygroups not change:
- verify you're calling SetBodygroup on the correct entity (teamflag vs prop)
- add retries after spawn/drop if needed (some entities aren't fully initialized on the exact tick)

### Dropped flag glow not showing
If `tf_glow` is attached to a prop_dynamic you never enable, you will "think it exists" but it won't render.

Our current best practice:
- OnDrop:
  - enable glow on the **item_teamflag**
  - disable glow on the prop
- OnPickup:
  - disable glow on the **item_teamflag**
  - enable glow on the prop

Add a short delay + a few retries if the entity isn't ready instantly.

---

## 11) Debugging Checklist (Use This Every Test)
### Console setup
- `developer 2`
- `glow_outline_effect_enable 1`
- `showtriggers 1`
- (optional) `mp_respawnwavetime 0`, `mp_waitingforplayers_cancel 1`

### Expected logs on map start
- Init logs
- Meter props set to 0
- Stock text set to 25

### Expected logs on spawner touch
- Stock decreases by 1
- Spawned value matches:
  - floor(pool/5) + classBonus, clamped
- Pool decreases by **poolPortion**, not by full dispense value

### Hurt tests
- By default we require **enemy-caused** damage (`DMG_REQUIRE_ENEMY = true`), so `hurtme` / world damage will **not** trigger chunk spawns.
- To test reliably:
  - Use an enemy bot/player to shoot you while you're carrying.
  - Or temporarily set `DMG_REQUIRE_ENEMY = false` in `micro/flagspawn/cfg.nut`.
- If chunks never trigger:
  - verify your logic_eventlistener: `EventName player_hurt`, `FetchEventData 1`
  - make sure it uses `CallScriptFunction` (not `RunScriptCode`)

### Death tests
- `kill` while carrying should call `FS_OnPlayerDeathEvent`
- If it does not:
  - verify `player_death` listener and CallScriptFunction wiring

---

## 12) Known Issues / Warnings Seen in Logs
### "No such variable $C0_X for material dev/halo_add_to_screen"
This is a common shader/material param warning. It is usually harmless and does not indicate a vscript failure. It can occur when glow-related materials are used in contexts they weren't authored for.

Treat it as cosmetic unless it correlates with missing glow rendering; if glow isn't rendering, focus first on:
- enabling/disabling the correct entity's glow
- delay/retry timing
- ensuring the glow entity isn't attached to an entity that never gets enabled

---

## 13) Implementation Notes (Script Version)
Current script basis (microservices):
- `micro/flagspawn.nut`
- `micro/flagspawn/cfg.nut`
- `micro/flagspawn/core.nut`
- `micro/flagspawn/spw.nut`
- `micro/flagspawn/eco.nut`
- `micro/flagspawn/dmg.nut`

Key systems included:
- Stock gating (25)
- On-deck meter (floor(pool/5) mirrored across 3 props; pool is 0-300, overflow discarded)
- Dispense = floor(pool/5) + class bonus, clamped
- Capture award = 3x + first blood time remaining (first 3 per team, per life)
- Damage chunk: destroy 10% + spawn 20% chunk; keep >=1
- Death pinata: destroy 20% to grave + up to 4 shards of 20%; remainder destroyed

---

## 14) TODO / Next Up
- Move First Blood timer start from "script init" to a true round-start event (once we confirm a reliable event in your map setup).
- Event-driven + (minimal pulse) bodygroup/glow retries:
  - on drop
  - on merge
  - on newly spawned chunks
  - on pulse
- Confirm merge behavior does not accidentally "re-add" to pool or over-count stock.

---

## Appendix A: 
we need a way to:
  - destroy point spawned on death
  - Cosmetics
SetBodyGroup - fired on both the prop and the teamflag
tf_glow - controlled by a glow outline for ALL flags and props (not templated for bluflag or bluflag_prop)

OnPickupEvent
-> attach prop (SetParentAttachment) to the !activator (player)
-> Enable prop/set to render. This will automatically show its glow.
-> flag automatically stops rendering, so managing the glow is not a problem

OnDropevent
-> attach prop (SetParentAttachment) to the blu_lmm_target (flag follower)
-> Disable prop/set not render

glows start enabled, flag prop start disabled

### Micro v7: standardized glows (timer-based)
We now do this automatically in VScript by:
- Retargeting the templated `tf_glow` using `NetProps.SetPropEntity(glow, "m_hTarget", ent)` (keyvalue target is unreliable with point_template NameFixup).
- Enabling/disabling glow via a per-flag `glowUntil` timer.

Config (in `micro/flagspawn/cfg.nut`):
- `GLOW_DURATION_DROP` (default 10s): used on spawn + on drop.
- `GLOW_DURATION_PICKUP` (default 2s): brief pickup flash (player glows).

Behavior:
- Dropped: flag draws, prop hidden, glow targets the **flag** while timer is active.
- Picked up: flag hidden, prop draws on player, glow targets the **player** while timer is active.

### Remainder SFX (death pinata)
When death pinata destroys *extra* value beyond the 20% grave tax (rounding/cap remainder), we play `SOUND_REMAINDER` at the death location.

### Killing the PD "1 point on death" drop
We do **not** set any flag to 0 (breaks PD merging). Instead, after `player_death` we search near the death origin for **untracked** `item_teamflag` with `m_nPointValue == 1` and kill it after a short delay. This removes the built-in PD "drop 1 on death" without touching merge logic.


It seems like we cannot spawn a new glow for a template'd flag without bugs? like a tf_glow for bluflag_prop_glow001 that we control like you are saying...vscript does this fine tho?
 Gemini: Yes, VScript does this perfectly, and it is the only way to do it without bugs.

Here is the technical reality of why you might have thought it was "buggy" before, and how v9 fixes it:

The "Bug" (Hammer-only)
If you rely purely on Hammer's point_template, the tf_glow creates a hard link to the prop name (e.g., bluflag_prop&001).

Problem: When a player picks it up, you can't tell the glow to "switch to the player" using only Hammer I/O easily, because you don't know the player's name.

Result: The glow sits on the floor (or vanishes) while the player runs away unglowed.

The Fix (VScript)
VScript bypasses the naming problem entirely by using Handles.

We spawn the template.

We capture the specific glow entity handle for that specific flag.

On Pickup: We tell that specific glow handle: SetTarget -> !activator (The Player).

On Drop: We tell that specific glow handle: SetTarget -> bluflag_prop (The Meter).

This allows us to recycle the same single tf_glow entity for both the floor meter and the player model.

Me: Further customizability on these glows: add to our event-driven logic. set tf_glows to Enable all in a 'vscript flagspawner template' for a configurable duration on our events:
on pinata -> 5 damage chunks + (add to readme: optional SFX For the remainder 6th piece ForceReturn)
    On damage chunk -> same thing 
    On flagspawner used -> same thing
    On pickup 
    On drop
    
blu_flagspawner_prop01 <- this is the prop where ALL Flags will come from. we want this to be where you get the budgetbonus which i believe is clamped at 20% of the total budgetbonus value to be given out at a time (so a solo carry isnt the end all be all, it requires a lot of players). so we can use the setbodygroup on this to show the current bonus applied 0-60 (onDeck) ! yay ! just one prop's bodygroups to manage

I think I want to show 20% of it in the prop01 bodygroup and sync the other props so it shows the 'on deck' bonus as well. They will be the same number - albeit dynamic with flags returning incrementing the bodygroups - and oncapture 3x effect....then when they get the flag - it will update the bodygroup with what was taken - 20% + class_bonus is then subtracted from all 3 props yay . make senses right?

class_bonus is how heavy gets 10, scout gets 2,etc.. the faster 'flagspawn' rate applies to all of it thats fun. prop01 and prop02 and prop03 all need to have sync'd bodygroups in our events.
