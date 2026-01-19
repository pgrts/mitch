# Flagspawn README v7 (In-Depth)
_Last updated: 2026-01-19 (America/New_York)_

This document captures the **last couple days of implementation work** and the current “correct” design for the Flagspawn PD/CTF hybrid: **stock-limited spawner**, **return/capture-driven economy**, **meter props starting empty**, **per-flag clamp to 100**, **per-player carry cap**, and the finalized **damage/death destruction rules**.

> If you’re coming from older versions: the biggest behavioral shift is that **the spawner is NOT gated by pool/budget being >0**, and **we never trust the point_template default point value** (which was causing 100-value flags at round start).

---

## Constant-Table Limit (“error constant too long”)

TF2’s VScript Squirrel can fail to compile large scripts with lots of string constants (especially debug logs built from many `'frag' + value + 'frag'` pieces). The engine usually reports it near the top of the file (e.g., line ~27) even if the real trigger is later.

Current approach:
- Keep v7 in **one file**, but **strip/comment most debug string-building** in `flagspawn.nut`.
- If you re-add logs, prefer **one** `format("...%d...", x)` string per log line.
- If it still trips the limit, the next step is splitting into 2–3 include files (last resort).

---

## 0) Core Goals (What We Are Building)
### The loop
1. **Team spawner dispenses “bonus” flags** (item_teamflag) when you touch it.
2. Those flags represent **temporary value** you can carry to a **PD capturezone**.
3. **Capturing** converts that carried value into:
   - **Team score** (PD score)
   - **Team economy** (spawner bonus pool)
4. **Returning** dropped flags also replenishes economy.
5. **Damage** and **death** on carriers causes **chunk drops** and **value destruction** (anti-snowball).

### Non-negotiables we just implemented
- **Spawner meter props start at 0** (empty).  
  No “500 visible at start”. Economy is earned via return/capture.
- **Per-flag point value clamps to 100**.
- **One player cannot drain 500**: the economy is dispensed in capped pieces and the player has a carry cap.
- Avoid crashes: **never use `GetAbsOrigin()` on players**; use safe wrappers (`_GetOrigin` etc.).
- Custom prop fill meter uses **bodygroup index 1**:
  - ✅ `SetBodygroup(1, value)`  
  - ❌ `SetBodygroup(0, value)`

---

## 1) Two Separate “Economies” (This Was The Confusing Part)
We split the concept cleanly:

### A) Spawner **Stock** (How many flags can exist at once)
- **Stock is a hard cap**: `LIMIT_ACTIVE_FLAGS = 25`
- Stock is **NOT** “points”. It’s **count of active/pending flags**.
- Spawner denies if stock == 0.

**Why:** This prevents runaway template spam and makes the spawner behave like a reliable dispenser even when budget is 0.

### B) Spawner **Bonus Pool** (The 0–500 “earned” meter)
- Starts at **0**.
- Grows when:
  - flags are **returned**
  - flags are **captured**
- This pool is visualized on **5 meter props** (0–100 each, total 0–500).
- The pool determines the **pool portion** of the next dispensed flag.

---

## 2) Spawner Meter Props (5 segments, start empty)
### Visual model expectations
- You have 5 `prop_dynamic` meter segments on the spawner.
- They represent **0–500 total** as **five 0–100 segments**.
- **Bodygroup index is 1** (critical project rule).

### Naming convention
- `blu_flagspawner_prop01`
- `blu_flagspawner_prop02`
- `blu_flagspawner_prop03`
- `blu_flagspawner_prop04`
- `blu_flagspawner_prop05`

Config:
- `SPAWNER_PROP_BLU_PREFIX = "blu_flagspawner_prop"`
- `SPAWNER_PROP_BLU_COUNT = 5`

### Meter rendering logic
Let:
- `PoolBluTotal` range: `[-∞ .. POOL_HARDCAP]` (we clamp for display)
- `POOL_HARDCAP = 500`

To render:
- Display value = `clamp(PoolBluTotal, 0, 500)`
- Segment i gets `clamp(DisplayValue - (i-1)*100, 0, 100)`
- Call: `prop.SetBodygroup(1, segmentValue)`  

At round start, `PoolBluTotal = 0`, so **all props show 0**.

---

## 3) Spawner Dispense Value (Pool / 5 + Class Bonus, then clamps)
When a player touches the spawner:

### Step 1: Stock gate (NOT pool gate)
- Deny if active + pending flags >= 25.

### Step 2: Compute pool portion
- `poolPortion = floor(PoolBluTotal / 5)`  
This is the “20% of the earned bonus”.

Examples:
- Pool=0 → poolPortion=0
- Pool=200 → poolPortion=40
- Pool=500 → poolPortion=100

### Step 3: Add class bonus
- `dispenseValue = poolPortion + classBonus[playerClass]`

### Step 4: Clamp and carry cap
- Per-flag clamp: `dispenseValue = clamp(dispenseValue, SPAWN_MIN_VALUE, VALUE_CAP)` where `VALUE_CAP=100`
- Per-player carry cap: `carryLeft = max(0, CARRY_CAP - playerCurrentCarry)` where `CARRY_CAP=100`
- Final: `dispenseValue = min(dispenseValue, carryLeft)`

If `carryLeft <= 0`, deny (player already carrying 100).

### Step 5: Pool consumption
Only the **pool portion** consumes the pool:
- `PoolBluTotal -= poolPortion`  
Class bonus does **not** drain the pool.

**Design effect:** Even at 500, the spawner dispenses in 100-point chunks, and it takes multiple players (or multiple deposit cycles) to extract the full pool.

---

## 4) The “100-Value Flag At Start” Bug (Fixed)
**Problem:** Point template / item_teamflag default `point_value` was leaking into gameplay.  
If your template has 100, you’d spawn 100 even when pool=0.

**Fix (current standard):**
- Every spawned flag gets its `m_nPointValue` set explicitly from our computed spawn context.
- We never trust the template’s point value.

---

## 5) Required VMF Wiring (Event Listener Reliability)
Over the last couple days, multiple failures came from VMF wiring mistakes:

### A) Spawner trigger output
Your `fs_spawner_blu` must call:

- `OnStartTouch` → `scripter RunScriptCode` → `FS_OnSpawnerTouchBlu()`

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
- ✅ `CallScriptFunction(FS_OnPlayerHurtEvent)`
- ✅ `CallScriptFunction(FS_OnPlayerDeathEvent)`
- ❌ `RunScriptCode(FS_OnPlayerHurtEvent())` (drops event_data)

Note: In Hammer outputs, `CallScriptFunction` expects the **function name only** (no `()`), e.g. `FS_OnPlayerHurtEvent`.

---

## 6) Capture / Return Hooks (Two different meanings)
We now treat capture and return as **economically different**:

### OnReturn → `FS_Direct_Return`
- Refunds economy to the flag’s owning team pool.
- Intended for “recovering dropped value”.

### OnCapture → `FS_Direct_Capture`
- Awards economy to the **capturer’s team pool**.
- Uses the special capture formula (see below).

> Backward compatible alias:
> - `FS_Direct_Refund` = return

But: **capture doubling + first-blood bonus requires OnCapture to call `FS_Direct_Capture`.**

---

## 7) Capture Economy Bonus (2x + First Blood Timer)
When a player captures value `V`:

### Base award
- `award = V * 2`

### First Blood Timer bonus (first 3 capturers per team, per life)
We track a separate “first blood” window of:
- `FIRST_BLOOD_WINDOW = 180` seconds (3 minutes)

Timer starts when the script initializes (can be moved to a true round-start trigger later).

Within that 180s:
- `timeRemaining = max(0, 180 - elapsedSeconds)`
- If the player qualifies as one of the first 3 capturers **for their team**, and has not used their “first blood per life”:
  - `award += timeRemaining`

**Examples**
- Capture 10 with 120 seconds left:
  - `10*2 + 120 = 140`
- Capture 10 with 1 second left:
  - `10*2 + 1 = 21`

### Per-person rules
- This bonus is tied to the **capturing player**, not “team capture total”.
- It does NOT multiply per PD “point tick” — it applies to the capture event (per person / per capture).
- We also reset “one per life spawner use” on capture (capture refreshes your dispenser use).

---

## 8) Damage Chunking (NEW: 10% destroyed + 20% chunk)
When a carrier hits the damage threshold, we apply:

Let `V` be current carried value:

### Damage destruction
- `destroy = max(1, floor(V * 0.10))`  
This value is removed from the game.

### Damage chunk spawn
- `chunk = max(1, floor(V * 0.20))`  
This becomes a spawned chunk flag.

### Safety rule
Damage chunking must never delete the entire flag:
- Must satisfy: `V - destroy - chunk >= 1`
- If not possible, we do not chunk (we preserve the flag).

**Example: V=10**
- destroy = 1
- chunk = 2
- carrier keeps: 10 - 1 - 2 = 7
- one 2-point chunk spawns

---

## 9) Death Piñata (NEW: 20% destroyed “to the grave” + up to 4 shards)
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

**Design intent:** killing carriers permanently deletes 20% and often deletes any odd remainder, ensuring carry value doesn’t endlessly recycle.

---

## 10) Glow / Bodygroup Reliability Notes
### Bodygroup index
Spawner prop meter uses:
- `SetBodygroup(1, value)`

Flag models / dropped props must be assigned appropriately; if you are seeing bodygroups not change:
- verify you’re calling SetBodygroup on the correct entity (teamflag vs prop)
- add retries after spawn/drop if needed (some entities aren’t fully initialized on the exact tick)

### Dropped flag glow not showing
If `tf_glow` is attached to a prop_dynamic you never enable, you will “think it exists” but it won’t render.

Our current best practice:
- OnDrop:
  - enable glow on the **item_teamflag**
  - disable glow on the prop
- OnPickup:
  - disable glow on the **item_teamflag**
  - enable glow on the prop

Add a short delay + a few retries if the entity isn’t ready instantly.

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
- `hurtme 50` while carrying should call `FS_OnPlayerHurtEvent`
- If it does not:
  - fix your logic_eventlistener: `EventName player_hurt`, `FetchEventData 1`
  - make sure it uses `CallScriptFunction`

### Death tests
- `kill` while carrying should call `FS_OnPlayerDeathEvent`
- If it does not:
  - verify `player_death` listener and CallScriptFunction wiring

---

## 12) Known Issues / Warnings Seen in Logs
### “No such variable $C0_X for material dev/halo_add_to_screen”
This is a common shader/material param warning. It is usually harmless and does not indicate a vscript failure. It can occur when glow-related materials are used in contexts they weren’t authored for.

Treat it as cosmetic unless it correlates with missing glow rendering; if glow isn’t rendering, focus first on:
- enabling/disabling the correct entity’s glow
- delay/retry timing
- ensuring the glow entity isn’t attached to an entity that never gets enabled

---

## 13) Implementation Notes (Script Version)
Current script basis:
- `flagspawn_new_v66.nut`

Key systems included:
- Stock gating (25)
- Pool meter (0–500 across 5 props)
- Dispense = floor(pool/5) + class bonus, clamped
- Carry cap = 100
- Capture award = 2x + first blood time remaining (first 3 per team, per life)
- Damage chunk: destroy 10% + spawn 20% chunk; keep >=1
- Death pinata: destroy 20% to grave + up to 4 shards of 20%; remainder destroyed

---

## 14) TODO / Next Up
- Move First Blood timer start from “script init” to a true round-start event (once we confirm a reliable event in your map setup).
- Event-driven (minimal pulse) bodygroup/glow retries:
  - on drop
  - on merge
  - on newly spawned chunks
- Confirm merge behavior does not accidentally “re-add” to pool or over-count stock.
- Hook pickup denial for carry cap (if we want to stop ground pickup overflow too, not just spawner overflow).

---

## Appendix A: VMF “Must Fix” Summary (Fast Copy)
1. `fs_spawner_blu` OnStartTouch → `RunScriptCode(FS_OnSpawnerTouchBlu())`
2. Any `logic_eventlistener` must have `FetchEventData = 1` (not FetchEventDate)
3. Hurt listener:
   - `EventName = player_hurt`
   - `OnEventFired -> CallScriptFunction(FS_OnPlayerHurtEvent)`
4. Death listener:
   - `EventName = player_death`
   - `OnEventFired -> CallScriptFunction(FS_OnPlayerDeathEvent)`
5. Capture and return:
   - OnCapture -> `FS_Direct_Capture`
   - OnReturn  -> `FS_Direct_Return` (or `FS_Direct_Refund` alias)
