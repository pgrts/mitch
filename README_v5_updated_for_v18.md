# Flagspawn — README_v5 (PD Hard Truth + Cosmetic Carried Prop + Global Glows)

**Goal (v5+ / current implementation v18):** stop fighting `item_teamflag` for visuals.

- **`item_teamflag` stays the PD “Hard Truth”** (pickup/merge/HUD accounting).
- **Everything cosmetic is ours** (carried meter model, bodygroups, glows, spawner meter).

This README is written to match the **fs3_test entity pattern** and current project rules:
- **env_entity_maker must have spawnflags 1** (unique suffix / name fixup)
- **Spawner meter prop uses bodygroup index 1** (`SetBodygroup(1, value)`, not 0)
- **Never call `GetAbsOrigin()` on players** (use wrappers / netprops)

---

## 1) Map Entities (Blu side only)

### Core logic
- `logic_script` named **`scripter`** (runs `flagspawn.nut`)
- `tf_logic_player_destruction` named **`fs_pd_logic`** (optional, HUD control)

### Global glows (NOT templated)
Place these once in the map (Blu side for now):
- `tf_glow` named **`bluflag_glow`** with `target = bluflag` (glows dropped flags)
- `tf_glow` named **`bluflag_prop_glow`** with `target = bluflag_prop` (glows carried meter props)

**Important:** these stay enabled all game. We never spawn or suffix them.

### Blu spawner
- `trigger_multiple` named **`fs_spawner_blu`** (filtered to Blu)
  - Output: `OnStartTouch -> scripter CallScriptFunction FS_OnSpawnerTouchBlu`
- `env_entity_maker` named **`fs_flag_maker_blu`**
  - `spawnflags = 1` (**IMPORTANT: suffix/fixup**)
  - Output: `OnEntitySpawned -> scripter CallScriptFunction FS_OnMakerSpawned`

### Template contents (per spawned pickup package)
Your `point_template` (e.g. `flagtemplate_blu`) should spawn:
- `item_teamflag` base name: **`bluflag`** (spawns as `bluflag&####`)
- follower anchor moved by LMM: **`blu_lmm_target`** (spawns as `blu_lmm_target&####`)
- carried meter prop: **`bluflag_prop`** (spawns as `bluflag_prop&####`)
- optional deny trigger: **`red_lock_bluflag`** (spawns as `red_lock_bluflag&####`)

**Important:** we do **not** try to parent the real `item_teamflag` to players.

---

## 2) Architecture

### 2.1 Truth Layer (engine / PD)
PD is authoritative for:
- pickup / drop / return
- merges (absorbed flags vanish)
- HUD “banked” behavior

We still track flags because merges delete entities and timing can be funky.

### 2.2 Cosmetic Layer (ours)
We own:
- **carried meter prop** (`bluflag_prop&####`) attached to player back attachment
- **bodygroup value** applied to both the teamflag *and* the prop
- glows are **global by name** (script doesn’t enable/disable them)
- **spawner meter** prop bodygroup updates

Cosmetics are updated primarily from events, with a slow fallback pulse.

---

## 3) Carried Prop Plan

### 3.1 Why we need a prop
In PD, the carried `item_teamflag` is often hidden/managed internally and merges delete entities.
Parenting the real intel is unreliable.

So:
- **DROPPED:** PD shows the `item_teamflag` (you can set `flag_model` to your meter if desired)
- **CARRIED:** we show **`bluflag_prop&####`** on the carrier’s back

### 3.2 Required behavior
- On pickup: show prop, parent to the carrier attachment (try `flag`, then fallbacks)
- On drop: hide prop, re-parent prop back to `blu_lmm_target&####` (so it “lives with” the dropped package)
- On respawn/class/team change: detach any stuck props from players and hide them (repair pulse)

---

## 4) tf_glow strategy

### 4.1 Global-by-name (default)
We keep two always-enabled global glows:
- `bluflag_glow` targets `bluflag`
- `bluflag_prop_glow` targets `bluflag_prop`

**In practice in TF2, these glows hit all suffix'd instances of that base name**, so `bluflag&0001`, `bluflag&0002` etc all outline.

Because the glows stay enabled, all we do in script is:
- hide/show the prop (carry prop glow appears automatically when the prop is visible)
- rely on PD rendering (flag renders dropped, hides when carried)

### 4.2 Optional fallback (single-target netprop)
If the map ever stops outlining all suffix'd instances on your build, the script has a fallback:
- `CFG.GLOW_MODE = "NETPROP_SINGLE"`

This uses `m_hTarget` (VScript) to bind a single glow target as an emergency fallback.

---

## 5) Events

### 5.1 Recommended: direct flag outputs
In fs3_test, the flag already calls these:
- `bluflag OnPickup -> scripter CallScriptFunction FS_Direct_Pickup()`
- `bluflag OnDrop   -> scripter CallScriptFunction FS_Direct_Drop()`

These are ideal because `caller` is the flag and `activator` is the player.

### 5.2 Retry strategy
Cosmetic changes are applied **immediately** and then retried a few times (v44-style) to “catch” late-spawned followers or late-updated netprops.

---

## 6) Merge + Economy Tracking (Blu only)

### 6.1 Economy
- Spawner pool starts at `CFG.SPAWNER_POOL_BLU_START` (script: `PoolBlu`)
- Each spawn decrements pool
- Spawner meter prop updates via `SetBodygroup(1, poolValue)`

### 6.2 Merges
Merges are inferred when a dropped flag entity disappears (killed/absorbed) without a terminal event.
The script prunes invalid records on the slow pulse.

---

## 7) Slow correctness pulse (fallback)

We keep a **slow** pulse (default 3.0s) to:
- prune dead flag records
- repair player budget resets (respawn/class/team)
- detach any props stuck on players
- optionally re-enforce last-known cosmetic state if an event was missed

---

## 9) Pinata + damage chunks (experimental)

The script contains working hooks for:
- **Pinata on death**: split a carrier’s value into 5 chunks (each ~20%), clamp so neither the chunks nor the remainder hit 0.
- **Damage chunks**: optional (disabled by default), spawns a single ~20% chunk on a cooldown when the carrier takes damage.

### 9.1 Hammer wiring
Add two `logic_eventlistener` entities:

#### player_death
- `EventName = player_death`
- `FetchEventData = 1`
- Output: `OnEventFired -> scripter CallScriptFunction FS_OnPlayerDeath`

#### player_hurt
- `EventName = player_hurt`
- `FetchEventData = 1`
- Output: `OnEventFired -> scripter CallScriptFunction FS_OnPlayerHurt`

### 9.2 Config toggles
In `flagspawn.CFG`:
- `PINATA_ENABLED = true/false`
- `DAMAGE_CHUNKS_ENABLED = true/false`

These features use the normal maker/template so every chunk is a full pickup package (flag + follower + prop + deny trigger).

## 8) File list
- `scripts/vscripts/flagspawn.nut` (current implementation)
- `README_v5.md` (this file)

