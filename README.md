# Flagspawn (PD Fuel) — Technical Documentation

A TF2 VScript game mode combining **Player Destruction** mechanics with **Fuel-based spawner resources**.

---

## Core Mechanics Overview

- **Base System:** Player Destruction (carrying, merging, scoring via PD logic)
- **Win Condition:** First team to capture **100 points** wins the round OR 5:00 timer hits 0 and whichever team has more wins (tiebreak: TBD) <- whichever comes first
- **Fuel System:** Team-owned resource (0–99) that increases when players touch flagspawner + flag is returned or captured
- **Spawner Dispensing:** Touch enemy base trigger to spawn a PD pickup (item_teamflag) with class-based value
- **Return Timer:** Dropped pickups return after **60 seconds**, depositing value into beneficiary team's Fuel

---

## Terminology

| Term | Definition |
|------|------------|
| **Fuel** | Team-owned resource (0–99) displayed at spawner locations |
| **Spawner** | Enemy base trigger zone — touching it dispenses a PD pickup |
| **Beneficiary Team** | The team that "owns" a pickup's value (gains Fuel when it returns) |
| **Pool Team** | The flag entity's original team assignment (determines which pool it came from) |
| **Carry Clamp** | Maximum 99 points can be carried; overflow auto-deposits to Fuel |

---

## Map Requirements

### VMF Entities

#### Logic Script
- **targetname:** `scripter`
- **Entity Script File:** `flagspawn.nut`

#### Spawner Triggers
- **redtrigger** (BLU base): `OnStartTouch → scripter → RunScriptCode → flagspawn.OnSpawnerTouch(activator, 3)`
- **blutrigger** (RED base): `OnStartTouch → scripter → RunScriptCode → flagspawn.OnSpawnerTouch(activator, 2)`

#### Capture Triggers
- **redcapper** (RED scoring): `OnStartTouch → scripter → RunScriptCode → flagspawn.OnCaptureTouch(activator, 2)`
- **blucapper** (BLU scoring): `OnStartTouch → scripter → RunScriptCode → flagspawn.OnCaptureTouch(activator, 3)`

#### Pooled Flags (25 per team minimum)
- **RED pool:** `fs_pool_red_01` through `fs_pool_red_25` (item_teamflag)
- **BLU pool:** `fs_pool_blu_01` through `fs_pool_blu_25` (item_teamflag)

#### Display Entities
- **fs_stock_red** — point_worldtext for RED Fuel display
- **fs_stock_blu** — point_worldtext for BLU Fuel display
- **redflag** — prop_dynamic parent for RED spawner visuals (optional)
- **bluflag** — prop_dynamic parent for BLU spawner visuals (optional)

#### PD Logic
- **fs_pd_logic** — tf_logic_player_destruction entity

#### Custom Model
- **models/props_custom/fs_meter/fs_meter_slab_grid.mdl** - meter model with bodygroup 0 values 0-100

---

## Gameplay Flow

### 1. Spawner Dispensing

**Trigger:** Player touches enemy base spawner trigger

**Rules:**
- Anti-spam cooldown: **0.35 seconds** per player
- Spawns one `item_teamflag` from enemy pool
- Base value: **class bonus** (see table below)
- Pickup immediately available for PD system to assign to player
- Beneficiary team = player's team

**Class Bonuses:**
| Class | Value |
|-------|-------|
| Heavy | 5 |
| Sniper | 3 |
| Soldier | 2 |
| All others | 1 |

### 2. Carrying & Merging

- **Important PD quirk:** `item_teamflag` `OnPickup` / `OnPickup1` does **not** fire when the player already carries points (merge). The reliable merge signal is the global `teamplay_flag_event`.
- **Merge detection (server/script):**
  - Hook `teamplay_flag_event`.
  - `eventtype` values: `1 = pickup`, `2 = capture`, `4 = dropped`.
  - On `eventtype == 1`, compare previous carry total vs current to decide pickup-start vs merge.
  - The engine increments the player's carried total on merge (NetProp like `m_nNumCarriedPoints` / `m_nNumCarried`), so treat that delta as the source of truth.
- **Map-only workaround:**
  - Use a `logic_eventlistener` with `EventName` = `teamplay_flag_event`.
  - `FetchEventData` = `eventtype`, filter for `eventtype == 1`.

- Players can carry and merge PD pickups normally
- **Carry Clamp:** If carried value exceeds **99**:
  - Clamped back to 99
  - Overflow deposited into carrier's team Fuel
  - Example: merge takes you to 107 → carry 99, +8 Fuel

### 3. Piñata on Damage

**Trigger:** Every **25 damage** taken while carrying points

**Spill Calculation:**
```
n = current carried value
P = ceil(n / 5)
P = clamp(P, 1, n - 1)  // carrier keeps at least 1 point
```

**Effect:**
- Carrier loses `P` points
- One pickup worth `P` spawns and is tossed backward with spread
- Maximum 3 spills per damage event (anti-machinegun spam)
- Gate: minimum **0.20 seconds** between damage checks per player

### 4. Death Split

**Trigger:** Carrier dies with `n` points

**Calculation:**
```
base = floor(n / 5)
rem  = n % 5
```

**Spawning:**
- **5 chunks** worth `base` points each (if base > 0)
  - Normal behavior: return after 60s
- **1 remainder chunk** worth `rem` points (if rem > 0)
  - **Special:** `fs_no_return = true` — NEVER returns, stays on field until picked up
  - THIS REMAINDER CHUNK SHOULD BE SENT BACK TO THE FUEL BANK
- All chunks burst in circular pattern around corpse

**Example:** Die with 23 points
- 5 chunks × 4 points = 20 points (returnable)
- 1 chunk × 3 points = 3 points (**no-return**)

### 5. Capture Scoring

**Trigger:** Player with carried flag touches friendly capture zone

**Effects:**
1. Score `n` points via `tf_logic_player_destruction` (fires input `n` times)
2. Add `n` to capturing team's **Fuel**
3. Add `n` to capturing team's **Score** (win at 100)
4. **Fuel Nullification:** Subtract `n` from enemy team's Fuel (min 0)
5. Recycle carried flag back to pool
6. Check win condition

**Example:** BLU captures 15 points
- BLU Score: +15 (check if ≥100 for win)
- BLU Fuel: +15
- RED Fuel: -15 (clamped at 0)

### 6. Return Timer

**Trigger:** Pickup dropped for **60 seconds**

**Rules:**
- Applies to normal dropped pickups
- Does **NOT** apply to remainder chunks from death (`fs_no_return = true`)
- On return:
  - Value deposited to beneficiary team's Fuel
  - Flag recycled back to pool

---

## Visual Systems

### Flag Value Meter (fs_meter)

Each carried/dropped pickup shows its value with a meter proxy instead of digits:
- The `item_teamflag` briefcase is hidden (NODRAW/transparent).
- A `prop_dynamic` using `models/props_custom/fs_meter/fs_meter_slab_grid.mdl` is parented to the flag center.
- Bodygroup 0 represents 0-100 points and is updated on dispense/merge.
- A `tf_glow` targets the proxy with team-colored glow (red/blue/neutral).
- The meter model uses block segments (no digits) for clean outlines.

---

## Current Issues

- Flag drop is unreliable; still troubleshooting drop behavior in PD.
- Merge testing for the meter blocks is blocked until drop works.

---

## State & Configuration

### CFG Table
```squirrel
::flagspawn.CFG <- {
    WIN_SCORE   = 100,           // Points to win
    RETURN_DELAY = 60.0,         // Seconds before return
    CARRY_MAX    = 99,           // Max carried value
    HURT_CHUNK_DAMAGE = 15.0,    // Damage threshold for piñata
    HURT_MIN_INTERVAL = 0.20,    // Anti-spam gate
    METER_MODEL  = "models/props_custom/fs_meter/fs_meter_slab_grid.mdl",
    METER_LOCAL_OFFSET = Vector(0, 0, 0),
    DISPENSE_COOLDOWN = 0.35,
    POOL_STASH_ORIGIN = Vector(0, 0, -8000),
    DEBUG = true
};
```

### State Table
```squirrel
::flagspawn.State <- {
    Fuel = { [2] = 0, [3] = 0 },          // Team fuel (0-99)
    Score = { [2] = 0, [3] = 0 },         // Captured points (win at 100)
    Pool = { [2] = [], [3] = [] },        // Available flag entities
    Spawner = { [2] = null, [3] = null }, // Parent props (optional)
    SpawnerMeter = { [2] = null, [3] = null }, // Spawner meter props (optional)
    SpawnerText = { [2] = null, [3] = null },   // point_worldtext
    NextDispenseAt = {},                  // Player cooldowns
    LastCarryValue = {},                  // Clamp tracking
    NextUid = 1,                          // Unique ID generator
    HurtAcc = {},                         // Damage accumulator
    HurtNextAt = {}                       // Damage rate gate
};
```

---

## Flag Script Scope Variables

Each pooled flag has a ValidateScriptScope with:

| Variable | Type | Description |
|----------|------|-------------|
| `fs_isFlagspawn` | bool | Marks script-managed flags |
| `fs_poolTeam` | int | Original team (2=RED, 3=BLU) |
| `fs_beneficiaryTeam` | int | Team that gains Fuel on return |
| `fs_dropTime` | float/null | Time() when dropped, null if carried |
| `fs_value` | int | Cached PointsValue for meter display |
| `fs_vis_eidx` | int | Entindex of meter proxy prop_dynamic |
| `fs_glow_eidx` | int | Entindex of tf_glow attached to meter |
| `fs_no_return` | bool | If true, never returns (remainder chunks) |

---

## Event Hooks

### player_hurt
- Tracks damage accumulation per player
- Triggers piñata spill every 15 damage
- Rate-limited to 0.20s intervals

### player_death
- Splits carried value into 5 + 1 chunks
- Remainder chunk flagged as no-return

---

## Technical Notes

### TF2 VScript Compatibility

**Safe Practices:**
- ✅ Use `QAngle(x, y, z)` for SetAbsAngles
- ✅ Avoid Vector for angle parameters (causes crashes)
- ✅ Use bodygroup inputs for prop_dynamic, not animations
- ✅ Parent entities via `EntFireByHandle(child, "SetParent", parentName, ...)`

**Meter Model Requirements:**
- Must have bodygroup 0 with values 0-100
- No animation sequences required (bodygroup-only display)

### Pool Management

- Flags stashed at `(0, 0, -8000)` when inactive
- Pool scanning on init looks for `fs_pool_red_*` and `fs_pool_blu_*` prefixes
- Recycled flags return to their original pool team

### Think Loop

Runs every **0.25 seconds**, handles:
1. Return timer checks (skip no-return chunks)
2. Carry clamp overflow → Fuel
3. Digit display updates
4. Flag scope validation

---

## Fuel Flow Summary

| Event | Fuel Change |
|-------|-------------|
| Spawner Touch | None (just spawns pickup) |
| Carry Overflow (>99) | +overflow to carrier's team |
| Capture N points | Capturing team: +N<br>Enemy team: -N |
| Return (60s) | +value to beneficiary team |
| Death Remainder | None (chunk stays on field, no return) |

---

## Win Condition

**First team to capture 100 total points wins**

Check happens in `OnCaptureTouch()`:
```squirrel
if (::flagspawn.State.Score[teamParam] >= ::flagspawn.CFG.WIN_SCORE) {
    ::flagspawn._TryEndRound(teamParam);
}
```

Uses `game_round_win` entity:
1. `SetTeam <2|3>`
2. `RoundWin` (0.01s delay)

---

## Debug Logging

Set `CFG.DEBUG = true` to enable console output:
- DISPENSE events
- CAPTURE flow
- CLAMP overflow
- DEATH splits
- RETURN cycles
- FUEL nullification

**Format:** `[FLAGSPAWN] <message>`

---

## Quick Reference

| Parameter | Value | Description |
|-----------|-------|-------------|
| Win Score | 100 | Points to win round |
| Fuel Cap | 99 | Per-team maximum |
| Carry Cap | 99 | Auto-overflow to Fuel |
| Return Delay | 60s | Normal pickups |
| Piñata Threshold | 15 dmg | Per spill trigger |
| Spill Formula | `ceil(n/5)` | Clamped to n-1 |
| Death Split | `floor(n/5)` × 5 + remainder | 6 total chunks |
| Dispense Cooldown | 0.35s | Per player |
| Damage Rate Gate | 0.20s | Anti-spam |

---

## Version History

**FS_GM1 PATCHED** (Current)
- ✅ Crash-safe QAngle handling
- ✅ Bodygroup-only meter display (no animations)
- ✅ Team-colored tf_glow on meter proxy
- ✅ Fuel nullification on capture
- ✅ Death 5+1 split with no-return remainder
- ✅ Improved pool management
- ✅ Event-based piñata/death systems

---

## Future Considerations

- Custom HUD elements (not implemented)
- Top-K glow selection for dropped pickups (not implemented)
- Flicker/timer visuals for return countdown (not implemented)
- Dynamic hotspot-based glow priority (not implemented)

Current implementation focuses on core mechanics with a meter display and Fuel economy.
