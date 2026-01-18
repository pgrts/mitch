# Flagspawn — README_v5 (PD Hard Truth + Cosmetic Carried Prop + Per-Package Glow)

**Goal (v5+ / current implementation v17):** stop fighting `item_teamflag` for visuals.

- **`item_teamflag` stays the PD “Hard Truth”** (pickup/merge/HUD accounting).
- **Everything cosmetic is ours** (carried meter model, bodygroups, glows, spawner meter).

This README is written to match the **fs3_test / fs2_test entity pattern** and current project rules:
- **env_entity_maker must have spawnflags 1** (unique suffix / name fixup)
- **Spawner meter prop uses bodygroup index 1** (`SetBodygroup(1, value)`, not 0)
- **Never call `GetAbsOrigin()` on players** (use wrappers / netprops)

---

## 1) Map Entities (Blu side only)

### Core logic
- `logic_script` named **`scripter`** (runs `flagspawn.nut`)
- `tf_logic_player_destruction` named **`fs_pd_logic`** (optional, HUD control)

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
- per-package glow: **`bluflag_glow`** (spawns as `bluflag_glow&####`)
- optional deny trigger: **`red_lock_bluflag`** (spawns as `red_lock_bluflag&####`)

**Important:** we do **not** try to parent the real `item_teamflag` to players.

---

## 2) Architecture

### 2.1 Truth Layer (engine / PD)
PD is authoritative for:
- pickup / drop / return
- merges (absorbed flags vanish)
- HUD “banked” behavior

We still track flags because **merge is not reliably exposed as a dedicated event**.

### 2.2 Cosmetic Layer (ours)
We own:
- **carried meter prop** (`bluflag_prop&####`) attached to player back attachment
- **bodygroup value** applied to both the teamflag *and* the prop
- **glow retarget** on events using `m_hTarget` netprop (see below)
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

## 4) Per-package tf_glow retarget (recommended)

### 4.1 The core limitation
`tf_glow` has a `target` keyvalue, but **you cannot reliably change it at runtime using Hammer `AddOutput`**.
The standard workaround is **VScript setting `m_hTarget`** on the `tf_glow` entity.

### 4.2 What we do
Each spawned package includes a glow entity `bluflag_glow&####`. The script stores its **handle** and retargets it:
- **OnDrop:** `glow -> item_teamflag` (dropped intel glows)
- **OnPickup:** `glow -> bluflag_prop` (carried meter prop glows)

Because it’s a handle, suffix/name issues do not matter.

### 4.3 Template setup
Set your template `bluflag_glow` to:
- `StartDisabled = 0` (enabled all game)
- `Mode = 2` (through walls)
- any placeholder `target` is fine (the script overwrites `m_hTarget`)

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

## 8) File list
- `scripts/vscripts/flagspawn.nut` (current implementation)
- `README_v5.md` (this file)

