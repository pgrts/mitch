// ============================================================================
// Flagspawn v6 (Hybrid Reparent + Economy + Robust tf_glow Retarget)
// ----------------------------------------------------------------------------
// BLU-side reference implementation for fs3_test-style maps.
//
// Core loop:
//   - Touch spawner -> ONE "big" flag worth min(Pool, 100) (also respects per-life class budget).
//   - Return/Capture -> refund to Pool + KILL the flag (frees a slot).
//   - Merge sink -> merged flags vanish without refund (prevents inflation).
//
// Visual truth table:
//   - DROPPED: Flag visible | (optional) prop parented to LMM but hidden | Glow -> Flag
//   - CARRIED: Flag hidden  | (optional) prop on player | Glow -> Player
//
// IMPORTANT PROJECT RULES:
//   - Never call GetAbsOrigin() on players.
//   - fs_meter.mdl fill bodygroup uses index 1: SetBodyGroup(1, value).
//   - Do NOT rely on point_template NameFixup for tf_glow "target" keyvalue.
//     Fix is NetProps.SetPropEntity(glow, "m_hTarget", ent) (see tf_glow VDC bug).
// ============================================================================

// --- Root Anchor (TF2 Squirrel Safety) --------------------------------------
local _rt = getroottable();
if (!("flagspawn" in _rt)) { _rt.flagspawn <- {}; }

// ----------------------------------------------------------------------------
// 1) CONFIG
// ----------------------------------------------------------------------------
flagspawn.CFG <- {
    VERSION = "v6_hybrid_glow_netprop",
    DBG = true,

    // --- VMF Names ---
    SCRIPTER_NAME = "scripter",              // logic_script

    // PD logic (tf_logic_player_destruction)
    PD_LOGIC_NAME = "fs_pd_logic",
    // Optional: keep PD Team Leader pointers cleared so the leader dispenser/HUD never shows.
    DISABLE_TEAM_LEADER = true,

    // Spawner
    SPAWNER_TRIG_BLU = "fs_spawner_blu",     // trigger_multiple
    MAKER_BLU = "fs_flag_maker_blu",         // env_entity_maker
    SPAWNER_PROP_BLU = "blu_flagspawner_prop",// legacy single meter prop
    // OPTIONAL: segmented meters to display pool >100 (e.g., 5 props => 0..500 display)
    // If SPAWNER_PROP_BLU_COUNT > 1, we look for names: <SPAWNER_PROP_BLU_PREFIX>01..05 etc.
    SPAWNER_PROP_BLU_PREFIX = "blu_flagspawner_prop",
    // Set to 5 if you have blu_flagspawner_prop01..05 to show a 0-500 pool as 5x 0-100 meters.
    SPAWNER_PROP_BLU_COUNT = 5,

    // UI
    ENT_TEXT_BLU = "blu_pool_text",          // point_worldtext (slots left)
    ENT_SPRITE_LOCK = "blu_spawner_lock",    // env_sprite (lock icon)

    // Event listeners (logic_eventlistener)
    FLAG_LISTENER_NAME = "flag_listener",         // teamplay_flag_event
    PLAYER_SPAWN_LISTENER_NAME = "player_spawn_listener",
    PLAYER_DEATH_LISTENER_NAME = "player_death_listener",
    PLAYER_HURT_LISTENER_NAME = "player_hurt_listener",

    // --- Template suffix bases ---
    PKG_FLAG_BASE = "bluflag",              // item_teamflag
    PKG_GLOW_BASE = "bluflag_glow",         // tf_glow
    PKG_LMM_TARGET_BASE = "blu_lmm_target", // info_target
    PKG_LOCK_BASE = "red_lock_bluflag",     // trigger_multiple (enemy deny)

    // Optional hybrid cosmetic prop (if your template includes it)
    PKG_PROP_BASE = "bluflag_prop",         // prop_dynamic
    PKG_PROP_GLOW_BASE = "bluflag_prop_glow",// tf_glow

    // Teams
    TEAM_RED = 2,
    TEAM_BLU = 3,

    // Economy
    POOL_START = 100,
    // Optional: cap pool growth (for UI / segment display). Set to 0 to disable.
    // With 5 meter props, set to 500 so UI matches physical meters.
    POOL_HARDCAP = 500,
    VALUE_CAP = 100,
    LIMIT_ACTIVE_FLAGS = 25,

    // Budgets (spawns-per-life per class)
    // TF2 class indices: 1 Scout, 2 Sniper, 3 Soldier, 4 Demo, 5 Medic, 6 Heavy, 7 Pyro, 8 Spy, 9 Engy
    BUDGET_CLASS_MAX = {
        [1] = 2,
        [2] = 8,
        [3] = 4,
        [4] = 3,
        [5] = 7,
        [6] = 10,
        [7] = 5,
        [8] = 1,
        [9] = 6
    },

    // Visuals
    ATTACH_POINT = "partyhat", // where to attach the prop to the player (if used)

    // Timing / retries
    PULSE_INTERVAL = 0.50,
    RETRY_COUNT = 8,          // re-apply parent/draw/lock state
    GLOW_RETRY_COUNT = 10,    // re-apply netprop target (esp. around merge/pickup)

    // Highlight logic
    TOPK_GLOW = 5,
    TOPK_RECALC_INTERVAL = 0.50,
    EVENT_GLOW_DURATION = 4.0,

    // Pinata + damage chunks
    ENABLE_PINATA = true,
    PINATA_COUNT = 5,
    PINATA_PCT = 0.20,

    ENABLE_DAMAGE_CHUNKS = true,
    DAMAGE_THRESHOLD_PCT = 0.125, // 12.5% of MaxHP
    DAMAGE_CHUNK_PCT = 0.20,      // chunk is 20% of carried flag

    // Spawn scatter
    PINATA_RADIUS = 40,
    CHUNK_Z_LIFT = 40
};

// ----------------------------------------------------------------------------
// 2) STATE
// ----------------------------------------------------------------------------
flagspawn.State <- {
    InitDone = false,

    // Team pool
    PoolBlu = flagspawn.CFG.POOL_START,

    // suffix -> pkg
    Flags = {},

    // Per-player bookkeeping (entindex string)
    // { used, dmgAcc, nextSpawnTime, lastLife, lastClass, lastTeam }
    Player = {},

    // Maker spawn queue (for pinata / chunk spawns)
    SpawnQueueValues = [],
    SpawnQueueOrigins = [],

    // TopK cadence
    NextTopKTime = 0.0
};

// ----------------------------------------------------------------------------
// 3) HELPERS (safe + noisy)
// ----------------------------------------------------------------------------
function FS_Log(msg) {
    if (flagspawn.CFG.DBG) printl("[FSv6] " + msg);
}

function FS_IsValid(ent) {
    try { return (ent && ent.IsValid()); } catch (e) { return false; }
}

function FS_IsPlayer(ent) {
    if (!FS_IsValid(ent)) return false;
    try { return ent.IsPlayer(); } catch (e) { return false; }
}

// --- Optional: disable PD Team Leader HUD/dispenser -------------------
// This avoids the PD "team leader" pulse/dispenser mechanic entirely.
flagspawn._DisableTeamLeader <- function() {
    if (!flagspawn.CFG.DISABLE_TEAM_LEADER) return;
    local pd = flagspawn._FindByName(flagspawn.CFG.PD_LOGIC_NAME);
    if (!FS_IsValid(pd)) return;
    try { NetProps.SetPropEntity(pd, "m_hRedTeamLeader", null); } catch(e0) {}
    try { NetProps.SetPropEntity(pd, "m_hBlueTeamLeader", null); } catch(e1) {}
};

// Never call GetAbsOrigin() on players.
function FS_GetOrigin(ent) {
    if (!FS_IsValid(ent)) return Vector(0,0,0);
    try {
        if (ent.IsPlayer()) return ent.EyePosition() - Vector(0,0,20);
    } catch (e0) {}
    try { return ent.GetOrigin(); } catch (e1) {}
    return Vector(0,0,0);
}

flagspawn._EntFire <- function(ent, input, param = "", delay = 0.0, activator = null, caller = null) {
    if (!FS_IsValid(ent)) return;
    try {
        EntFireByHandle(ent, input, param, delay, activator, caller);
    } catch (e) {
        if (flagspawn.CFG.DBG) FS_Log("EntFire failed input=" + input + " err=" + e);
    }
};

flagspawn._FindByName <- function(name) {
    if (!name || name == "") return null;
    return Entities.FindByName(null, name);
};

flagspawn._StartsWith <- function(s, prefix) {
    if (!s || !prefix) return false;
    if (s.len() < prefix.len()) return false;
    return (s.slice(0, prefix.len()) == prefix);
};

flagspawn._SuffixFromName <- function(fullName, baseName) {
    if (!fullName || !baseName) return "";
    if (!flagspawn._StartsWith(fullName, baseName)) return "";
    if (fullName.len() <= baseName.len()) return "";
    return fullName.slice(baseName.len());
};

// Safe setters
flagspawn._SafeSetOrigin <- function(ent, org) {
    if (!FS_IsValid(ent)) return;
    try {
        ent.SetOrigin(org);
    } catch (e) {
        // best-effort fallback
        try { EntFireByHandle(ent, "AddOutput", "origin " + org.x + " " + org.y + " " + org.z, 0.0, null, null); } catch (e2) {}
    }
};

flagspawn._SafeSetBodygroup <- function(ent, groupIdx, value) {
    if (!FS_IsValid(ent)) return;
    try { ent.SetBodygroup(groupIdx, value); return; } catch (e0) {}
    flagspawn._EntFire(ent, "SetBodyGroup", groupIdx.tostring() + " " + value.tostring(), 0.0, null, null);
};

flagspawn._ReadPointValue <- function(flag) {
    if (!FS_IsValid(flag)) return 0;
    try { return NetProps.GetPropInt(flag, "m_nPointValue"); } catch (e) { return 0; }
};

flagspawn._WritePointValue <- function(flag, v) {
    if (!FS_IsValid(flag)) return;
    try { NetProps.SetPropInt(flag, "m_nPointValue", v); } catch (e) {}
};

flagspawn._GetFlagOwner <- function(flag) {
    if (!FS_IsValid(flag)) return null;
    try {
        local o = flag.GetOwner();
        if (FS_IsValid(o)) return o;
    } catch (e0) {}
    try {
        local o2 = NetProps.GetPropEntity(flag, "m_hOwnerEntity");
        if (FS_IsValid(o2)) return o2;
    } catch (e1) {}
    return null;
};

flagspawn._GetMaxHealth <- function(ply) {
    if (!FS_IsPlayer(ply)) return 100;
    try { return ply.GetMaxHealth(); } catch (e) { return 100; }
};

// ----------------------------------------------------------------------------
// 4) tf_glow targeting (NETPROP FIX)
// ----------------------------------------------------------------------------

// tf_glow has a known issue: changing "target" keyvalue dynamically does not work reliably.
// The stable fix is to set NetProp m_hTarget to an entity handle.
flagspawn._GlowSetTargetEnt <- function(glow, ent) {
    if (!FS_IsValid(glow) || !FS_IsValid(ent)) return false;

    // Enable first (StartDisabled is common in templates)
    flagspawn._EntFire(glow, "Enable", "", 0.0, null, null);

    // Set netprop
    try {
        NetProps.SetPropEntity(glow, "m_hTarget", ent);
        return true;
    } catch (e0) {
        if (flagspawn.CFG.DBG) FS_Log("Glow netprop set failed: " + e0);
    }
    return false;
};

flagspawn._ApplyGlowForState <- function(pkg, carried) {
    if (!pkg) return;

    // Decide if glow should be enabled
    local now = Time();
    local enableWanted = false;
    if (pkg.isTopK) enableWanted = true;
    if (now < pkg.glowUntil) enableWanted = true;

    // No glow entity
    if (!FS_IsValid(pkg.glow)) return;

    if (!enableWanted) {
        flagspawn._EntFire(pkg.glow, "Disable", "", 0.0, null, null);
        return;
    }

    // Choose target
    local targetEnt = null;
    if (carried && FS_IsValid(pkg.carrier) && FS_IsPlayer(pkg.carrier)) {
        targetEnt = pkg.carrier;
    } else {
        // Dropped: outline the visible thing (the flag)
        if (FS_IsValid(pkg.flag)) targetEnt = pkg.flag;
    }

    if (FS_IsValid(targetEnt)) {
        flagspawn._GlowSetTargetEnt(pkg.glow, targetEnt);
    }
};

// Optional: if you have a separate prop glow, keep it targeting the prop only.
flagspawn._ApplyPropGlow <- function(pkg, enableWanted) {
    if (!pkg) return;
    if (!FS_IsValid(pkg.propGlow) || !FS_IsValid(pkg.prop)) return;
    if (!enableWanted) {
        flagspawn._EntFire(pkg.propGlow, "Disable", "", 0.0, null, null);
        return;
    }
    flagspawn._GlowSetTargetEnt(pkg.propGlow, pkg.prop);
};

// ----------------------------------------------------------------------------
// 5) VISUAL STATE MACHINE
// ----------------------------------------------------------------------------
flagspawn._SyncBodygroups <- function(pkg) {
    if (!pkg) return;

    local v = pkg.pointValue;
    if (v < 1) v = 1;
    if (v > flagspawn.CFG.VALUE_CAP) v = flagspawn.CFG.VALUE_CAP;

    // Update both (flag is authoritative even if hidden)
    if (FS_IsValid(pkg.flag)) flagspawn._SafeSetBodygroup(pkg.flag, 1, v);
    if (FS_IsValid(pkg.prop)) flagspawn._SafeSetBodygroup(pkg.prop, 1, v);
};

flagspawn._ApplyVisualState <- function(pkg) {
    if (!pkg || !FS_IsValid(pkg.flag)) return;

    // Refresh owner + pointValue
    local owner = flagspawn._GetFlagOwner(pkg.flag);
    pkg.pointValue = flagspawn._ReadPointValue(pkg.flag);

    flagspawn._SyncBodygroups(pkg);

    if (FS_IsValid(owner) && FS_IsPlayer(owner)) {
        // --- CARRIED ---
        pkg.carrier = owner;

        // NOTE: item_teamflag does not support DisableDraw/EnableDraw inputs.
        // PD already hides the carried flag automatically; we just show the prop.

        // Disable deny trigger while carried
        if (FS_IsValid(pkg.lock)) flagspawn._EntFire(pkg.lock, "Disable", "", 0.0, null, null);

        // Hybrid prop: attach to player
        if (FS_IsValid(pkg.prop)) {
            local mp = null;
            try { mp = pkg.prop.GetMoveParent(); } catch (e0) { mp = null; }
            if (mp != owner) {
                flagspawn._EntFire(pkg.prop, "ClearParent", "", 0.0, null, null);
                flagspawn._EntFire(pkg.prop, "SetParent", "!activator", 0.02, owner, null);
                flagspawn._EntFire(pkg.prop, "SetParentAttachment", flagspawn.CFG.ATTACH_POINT, 0.04, owner, null);
            }
            flagspawn._EntFire(pkg.prop, "Enable", "", 0.0, null, null);
        }

        // Glow -> player
        flagspawn._ApplyGlowForState(pkg, true);

        // Optional prop glow (if you want prop outlined instead of player)
        // flagspawn._ApplyPropGlow(pkg, false);

    } else {
        // --- DROPPED ---
        pkg.carrier = null;

        // NOTE: PD shows the dropped flag automatically.

        // Enable deny trigger while dropped
        if (FS_IsValid(pkg.lock)) flagspawn._EntFire(pkg.lock, "Enable", "", 0.0, null, null);

        // Hybrid prop: parent to LMM target but keep hidden (flag is the visible thing)
        if (FS_IsValid(pkg.prop)) {
            if (FS_IsValid(pkg.lmm)) {
                local mp2 = null;
                try { mp2 = pkg.prop.GetMoveParent(); } catch (e1) { mp2 = null; }
                if (mp2 != pkg.lmm) {
                    local pnm = "";
                    try { pnm = pkg.lmm.GetName(); } catch (e2) { pnm = ""; }
                    if (pnm != "") {
                        flagspawn._EntFire(pkg.prop, "ClearParent", "", 0.0, null, null);
                        flagspawn._EntFire(pkg.prop, "SetParent", pnm, 0.02, null, null);
                        flagspawn._EntFire(pkg.prop, "SetLocalOrigin", "0 0 0", 0.04, null, null);
                        flagspawn._EntFire(pkg.prop, "SetLocalAngles", "0 0 0", 0.04, null, null);
                    }
                }
            }
            flagspawn._EntFire(pkg.prop, "Disable", "", 0.0, null, null);
        }

        // Glow -> flag
        flagspawn._ApplyGlowForState(pkg, false);

        // Optional prop glow
        // flagspawn._ApplyPropGlow(pkg, false);
    }
};

// ----------------------------------------------------------------------------
// 6) TOP-K selection (highest value flags)
// ----------------------------------------------------------------------------
flagspawn._BuildSortedSuffixesByValue <- function() {
    local arr = [];

    foreach (suf, pkg in flagspawn.State.Flags) {
        if (!pkg || !FS_IsValid(pkg.flag)) continue;
        pkg.pointValue = flagspawn._ReadPointValue(pkg.flag);

        local inserted = false;
        for (local i = 0; i < arr.len(); i++) {
            local other = flagspawn.State.Flags[arr[i]];
            local ov = (other) ? other.pointValue : 0;
            if (pkg.pointValue > ov) {
                arr.insert(i, suf);
                inserted = true;
                break;
            }
        }
        if (!inserted) arr.append(suf);
    }

    return arr;
};

flagspawn._RecalcTopK <- function() {
    local sorted = flagspawn._BuildSortedSuffixesByValue();

    foreach (suf, pkg in flagspawn.State.Flags) {
        if (pkg) pkg.isTopK = false;
    }

    local k = flagspawn.CFG.TOPK_GLOW;
    for (local i = 0; i < sorted.len() && i < k; i++) {
        local suf = sorted[i];
        if (suf in flagspawn.State.Flags) flagspawn.State.Flags[suf].isTopK = true;
    }

    foreach (suf2, pkg2 in flagspawn.State.Flags) {
        if (!pkg2) continue;
        pkg2.glowRetry = flagspawn.CFG.GLOW_RETRY_COUNT;
    }
};

flagspawn._BumpGlowUntil <- function(pkg, seconds) {
    if (!pkg) return;
    local t = Time() + seconds;
    if (t > pkg.glowUntil) pkg.glowUntil = t;
    pkg.glowRetry = flagspawn.CFG.GLOW_RETRY_COUNT;
};

// ----------------------------------------------------------------------------
// 7) UI helpers
// ----------------------------------------------------------------------------
// ---- worldtext + pool meter helpers ------------------------------------
flagspawn._UpdatePoolMetersBlu <- function() {
    local pool = flagspawn.State.PoolBlu;

    local hardcap = flagspawn.CFG.POOL_HARDCAP;
    if (hardcap && hardcap > 0 && pool > hardcap) pool = hardcap;

    if (pool < 0) pool = 0;

    local count = 1;
    try { count = flagspawn.CFG.SPAWNER_PROP_BLU_COUNT; } catch(e) { count = 1; }
    if (count <= 1) {
        local prop = flagspawn._FindByName(flagspawn.CFG.SPAWNER_PROP_BLU);
        if (FS_IsValid(prop)) {
            local v = pool;
            if (v > 100) v = 100;
            flagspawn._SafeSetBodygroup(prop, 1, v);
        }
        return;
    }

    // Segmented display (01..N). Each prop shows 0..100, total display = N*100.
    local prefix = flagspawn.CFG.SPAWNER_PROP_BLU_PREFIX;
    local rem = pool;
    for (local i = 1; i <= count; i++) {
        local nm = prefix + format("%02d", i);
        local prop2 = flagspawn._FindByName(nm);
        if (!FS_IsValid(prop2)) continue;
        local seg = 0;
        if (rem > 0) { seg = rem; if (seg > 100) seg = 100; }
        flagspawn._SafeSetBodygroup(prop2, 1, seg);
        rem -= seg;
    }
};

flagspawn._GetThinkEnt <- function() {
    // script_execute sometimes has no self; use scripter logic_script instead
    local rt = getroottable();
    if ("self" in rt) {
        local s = rt.self;
        if (FS_IsValid(s)) return s;
    }
    local sc = flagspawn._FindByName(flagspawn.CFG.SCRIPTER_NAME);
    if (FS_IsValid(sc)) return sc;
    return null;
};

flagspawn._UpdateUI <- function() {
    // Slots left
    local activeCount = flagspawn.State.Flags.len();
    local slotsLeft = flagspawn.CFG.LIMIT_ACTIVE_FLAGS - activeCount;
    if (slotsLeft < 0) slotsLeft = 0;

    local txt = flagspawn._FindByName(flagspawn.CFG.ENT_TEXT_BLU);
    // point_worldtext does NOT support SetMessage (that's game_text). Use AddOutput to set its "message" KV.
    if (FS_IsValid(txt)) flagspawn._EntFire(txt, "AddOutput", "message " + slotsLeft.tostring(), 0.0, null, null);

    // Lock sprite
    local spr = flagspawn._FindByName(flagspawn.CFG.ENT_SPRITE_LOCK);
    if (FS_IsValid(spr)) {
        if (slotsLeft == 0) flagspawn._EntFire(spr, "ShowSprite", "", 0.0, null, null);
        else flagspawn._EntFire(spr, "HideSprite", "", 0.0, null, null);
    }

    // Spawner meter(s) show pool (segmented if COUNT>1)
    flagspawn._UpdatePoolMetersBlu();
};

// ----------------------------------------------------------------------------
// 8) Registration (OnEntitySpawned)
// ----------------------------------------------------------------------------
function FS_OnMakerSpawned() {
    flagspawn.Init();

    local maker = caller;
    if (!FS_IsValid(maker)) maker = flagspawn._FindByName(flagspawn.CFG.MAKER_BLU);
    if (!FS_IsValid(maker)) return;

    local org = FS_GetOrigin(maker);

    local best = null;
    local bestDist = 999999.0;
    local ent = null;

    while ((ent = Entities.FindByClassnameWithin(ent, "item_teamflag", org, 256.0)) != null) {
        local nm = "";
        try { nm = ent.GetName(); } catch (e0) { nm = ""; }
        if (!flagspawn._StartsWith(nm, flagspawn.CFG.PKG_FLAG_BASE)) continue;

        local suf = flagspawn._SuffixFromName(nm, flagspawn.CFG.PKG_FLAG_BASE);
        if (suf == "") continue;
        if (suf in flagspawn.State.Flags) continue;

        local d = (FS_GetOrigin(ent) - org).Length();
        if (d < bestDist) {
            best = ent;
            bestDist = d;
        }
    }

    if (!FS_IsValid(best)) {
        FS_Log("OnMakerSpawned: could not find new flag near maker.");
        return;
    }

    // Pop queued value/origin (if any)
    local val = 1;
    if (flagspawn.State.SpawnQueueValues.len() > 0) {
        val = flagspawn.State.SpawnQueueValues[0];
        flagspawn.State.SpawnQueueValues.remove(0);
    }

    local tpOrg = null;
    if (flagspawn.State.SpawnQueueOrigins.len() > 0) {
        tpOrg = flagspawn.State.SpawnQueueOrigins[0];
        flagspawn.State.SpawnQueueOrigins.remove(0);
    }

    if (val < 1) val = 1;
    if (val > flagspawn.CFG.VALUE_CAP) val = flagspawn.CFG.VALUE_CAP;

    flagspawn._WritePointValue(best, val);

    if (tpOrg != null) {
        flagspawn._SafeSetOrigin(best, tpOrg);
    }

    local name = "";
    try { name = best.GetName(); } catch (e1) { name = ""; }
    local suffix = flagspawn._SuffixFromName(name, flagspawn.CFG.PKG_FLAG_BASE);

    local pkg = {
        suffix = suffix,
        flag = best,
        glow = flagspawn._FindByName(flagspawn.CFG.PKG_GLOW_BASE + suffix),
        lock = flagspawn._FindByName(flagspawn.CFG.PKG_LOCK_BASE + suffix),
        lmm  = flagspawn._FindByName(flagspawn.CFG.PKG_LMM_TARGET_BASE + suffix),
        prop = flagspawn._FindByName(flagspawn.CFG.PKG_PROP_BASE + suffix),
        propGlow = flagspawn._FindByName(flagspawn.CFG.PKG_PROP_GLOW_BASE + suffix),
        pointValue = val,
        carrier = null,
        retry = flagspawn.CFG.RETRY_COUNT,
        glowRetry = flagspawn.CFG.GLOW_RETRY_COUNT,
        glowUntil = 0.0,
        isTopK = false
    };

    flagspawn.State.Flags[suffix] <- pkg;

    // Fix tf_glow template target immediately (NameFixup does NOT fix tf_glow's target keyvalue)
    if (FS_IsValid(pkg.glow)) {
        pkg.glowRetry = flagspawn.CFG.GLOW_RETRY_COUNT;
        flagspawn._GlowSetTargetEnt(pkg.glow, best);
    }

    // Hide prop by default
    if (FS_IsValid(pkg.prop)) flagspawn._EntFire(pkg.prop, "Disable", "", 0.0, null, null);

    // Bump highlight
    flagspawn._BumpGlowUntil(pkg, flagspawn.CFG.EVENT_GLOW_DURATION);

    flagspawn._ApplyVisualState(pkg);
    flagspawn._UpdateUI();

    // Force a TopK rebuild soon
    flagspawn.State.NextTopKTime = 0.0;

    FS_Log("Registered " + name + " value=" + val);
}

// ----------------------------------------------------------------------------
// 9) Spawner touch
// ----------------------------------------------------------------------------
function FS_OnSpawnerTouchBlu() {
    flagspawn.Init();

    local ply = activator;
    if (!FS_IsPlayer(ply)) return;

    local team = 0;
    try { team = ply.GetTeam(); } catch (e0) { team = 0; }
    if (team != flagspawn.CFG.TEAM_BLU) return;

    // Active limit
    if (flagspawn.State.Flags.len() >= flagspawn.CFG.LIMIT_ACTIVE_FLAGS) {
        flagspawn._UpdateUI();
        return;
    }

    // Ensure budget record
    flagspawn._ResetBudgetIfNeeded(ply);
    local rec = flagspawn._EnsurePlayerRec(ply);

    local cls = 0;
    try { cls = ply.GetPlayerClass(); } catch (e1) { cls = 0; }

    local maxSpawns = 1;
    if (cls in flagspawn.CFG.BUDGET_CLASS_MAX) maxSpawns = flagspawn.CFG.BUDGET_CLASS_MAX[cls];

    if (rec.used >= maxSpawns) return;

    // Pool
    if (flagspawn.State.PoolBlu <= 0) {
        flagspawn._UpdateUI();
        return;
    }

    // Rate limit
    if (Time() < rec.nextSpawnTime) return;

    // One big flag (cap 100)
    local val = flagspawn.State.PoolBlu;
    if (val > flagspawn.CFG.VALUE_CAP) val = flagspawn.CFG.VALUE_CAP;
    if (val < 1) val = 1;

    local maker = flagspawn._FindByName(flagspawn.CFG.MAKER_BLU);
    if (!FS_IsValid(maker)) return;

    // Queue value (registration uses it)
    flagspawn.State.SpawnQueueValues.append(val);
    flagspawn.State.SpawnQueueOrigins.append(null);

    // Spawn
    flagspawn._EntFire(maker, "ForceSpawn", "", 0.0, null, null);

    // Deduct and consume 1 spawn
    flagspawn.State.PoolBlu -= val;
    if (flagspawn.State.PoolBlu < 0) flagspawn.State.PoolBlu = 0;
    rec.used += 1;
    rec.nextSpawnTime = Time() + 0.75;

    flagspawn._UpdateUI();

    FS_Log("Spawner touch: spawned value=" + val + " pool=" + flagspawn.State.PoolBlu);
}

// ----------------------------------------------------------------------------
// 10) Flag events (teamplay_flag_event)
// ----------------------------------------------------------------------------
function FS_OnFlagEvent() {
    // NOTE: teamplay_flag_event does NOT include a flag entindex, so do NOT try to refund by index.
    // Use item_teamflag outputs (FS_Direct_Pickup/Drop/Refund) for per-flag instance logic.
    flagspawn.Init();

    if (!("event_data" in getroottable())) {
        if (flagspawn.CFG.DBG) FS_Log("FS_OnFlagEvent: missing event_data (listener must use CallScriptFunction + FetchEventData)." );
        return;
    }

    local evt = event_data;
    local type = 0;
    try { type = evt.eventtype; } catch (e0) { type = 0; }

    // 1: Pickup, 2: Capture, 3: Defend, 4: Dropped, 5: Returned
    // We keep this hook for optional debugging / generic effects (e.g., recalcing TopK),
    // but all per-flag logic must be driven by direct item_teamflag outputs.

    if (type == 3) {
        // Defend is useful as a global signal; force TopK refresh.
        flagspawn.State.NextTopKTime = 0.0;
    }

    // Immediate pulse catch (best-effort)
    flagspawn._Pulse();
}

// ----------------------------------------------------------------------------
// 11) Direct pickup/drop (optional item_teamflag outputs)
// ----------------------------------------------------------------------------
function FS_Direct_Pickup() {
    flagspawn.Init();
    // caller is usually the flag
    local flag = caller;
    if (!FS_IsValid(flag)) return;

    local nm = "";
    try { nm = flag.GetName(); } catch (e0) { nm = ""; }
    if (!flagspawn._StartsWith(nm, flagspawn.CFG.PKG_FLAG_BASE)) return;

    local suf = flagspawn._SuffixFromName(nm, flagspawn.CFG.PKG_FLAG_BASE);
    if (suf in flagspawn.State.Flags) {
        local pkg = flagspawn.State.Flags[suf];
        pkg.retry = flagspawn.CFG.RETRY_COUNT;
        flagspawn._BumpGlowUntil(pkg, flagspawn.CFG.EVENT_GLOW_DURATION);
        flagspawn._Pulse();
    }
}

function FS_Direct_Drop() {
    // Same handling as pickup
    FS_Direct_Pickup();
}


// ----------------------------------------------------------------------------
// 11b) Direct refund (item_teamflag OnReturn / OnCapture outputs)
// ----------------------------------------------------------------------------
function FS_Direct_Refund() {
    flagspawn.Init();

    // caller MUST be the specific item_teamflag instance firing OnReturn/OnCapture.
    local flag = caller;
    if (!FS_IsValid(flag)) return;

    local nm = "";
    try { nm = flag.GetName(); } catch (e0) { nm = ""; }
    if (!flagspawn._StartsWith(nm, flagspawn.CFG.PKG_FLAG_BASE)) return;

    local suf = flagspawn._SuffixFromName(nm, flagspawn.CFG.PKG_FLAG_BASE);
    if (suf == "") return;

    if (!(suf in flagspawn.State.Flags)) {
        if (flagspawn.CFG.DBG) FS_Log("FS_Direct_Refund: flag not registered: " + nm);
        return;
    }

    local pkg = flagspawn.State.Flags[suf];

    // Refund value (clamped)
    local refund = pkg.pointValue;
    if (refund > flagspawn.CFG.VALUE_CAP) refund = flagspawn.CFG.VALUE_CAP;
    if (refund < 0) refund = 0;

    flagspawn.State.PoolBlu += refund;

    // Optional pool hardcap
    local hardcap = flagspawn.CFG.POOL_HARDCAP;
    if (hardcap && hardcap > 0 && flagspawn.State.PoolBlu > hardcap) flagspawn.State.PoolBlu = hardcap;

    // Kill everything; we don't want returned/captured flags to respawn at base taking a slot.
    flagspawn._CleanupDeadPkg(pkg);
    try { if (FS_IsValid(pkg.flag)) pkg.flag.Kill(); } catch (e1) {}

    delete flagspawn.State.Flags[suf];

    flagspawn._UpdateUI();
    flagspawn.State.NextTopKTime = 0.0;

    FS_Log("Direct Refund: " + nm + " +" + refund + " pool=" + flagspawn.State.PoolBlu);
}

// ----------------------------------------------------------------------------
// 12) Pinata / Hurt
// ----------------------------------------------------------------------------
function FS_OnPlayerDeathEvent() {
    flagspawn.Init();

    if (!flagspawn.CFG.ENABLE_PINATA) return;

    local victim = null;
    if (("event_data" in getroottable())) {
        try { victim = GetPlayerFromUserID(event_data.userid); } catch (e0) { victim = null; }
    }
    // Fallback: some Hammer I/O paths don't provide event_data; try activator.
    if (!FS_IsPlayer(victim)) {
        local a = null;
        try { a = activator; } catch (e1) { a = null; }
        if (FS_IsPlayer(a)) victim = a;
    }
    if (!FS_IsPlayer(victim)) {
        if (flagspawn.CFG.DBG) FS_Log("FS_OnPlayerDeathEvent: no victim (missing event_data + activator)");
        return;
    }

    // Find flags carried by victim
    local carried = [];
    foreach (suf, pkg in flagspawn.State.Flags) {
        if (!pkg || !FS_IsValid(pkg.flag)) continue;
        if (pkg.carrier == victim) carried.append(suf);
    }
    if (carried.len() == 0) return;

    local vOrg = FS_GetOrigin(victim);

    for (local i = 0; i < carried.len(); i++) {
        local suf2 = carried[i];
        if (!(suf2 in flagspawn.State.Flags)) continue;

        local pkg2 = flagspawn.State.Flags[suf2];
        local total = pkg2.pointValue;
        if (total < 1) total = 1;

        // Kill original entities (merge sink behavior)
        if (FS_IsValid(pkg2.flag)) pkg2.flag.Kill();
        if (FS_IsValid(pkg2.prop)) pkg2.prop.Kill();
        if (FS_IsValid(pkg2.glow)) pkg2.glow.Kill();
        if (FS_IsValid(pkg2.propGlow)) pkg2.propGlow.Kill();
        if (FS_IsValid(pkg2.lock)) pkg2.lock.Kill();
        if (FS_IsValid(pkg2.lmm)) pkg2.lmm.Kill();

        delete flagspawn.State.Flags[suf2];

        // Spawn chunks
        local chunkVal = floor(total * flagspawn.CFG.PINATA_PCT);
        if (chunkVal < 1) chunkVal = 1;

        local maker = flagspawn._FindByName(flagspawn.CFG.MAKER_BLU);
        if (!FS_IsValid(maker)) continue;

        for (local k = 0; k < flagspawn.CFG.PINATA_COUNT; k++) {
            if (flagspawn.State.Flags.len() + flagspawn.State.SpawnQueueValues.len() >= flagspawn.CFG.LIMIT_ACTIVE_FLAGS) break;

            flagspawn.State.SpawnQueueValues.append(chunkVal);

            local off = Vector(RandomInt(-flagspawn.CFG.PINATA_RADIUS, flagspawn.CFG.PINATA_RADIUS), RandomInt(-flagspawn.CFG.PINATA_RADIUS, flagspawn.CFG.PINATA_RADIUS), flagspawn.CFG.CHUNK_Z_LIFT);
            flagspawn.State.SpawnQueueOrigins.append(vOrg + off);

            // stagger a bit for reliability
            flagspawn._EntFire(maker, "ForceSpawn", "", 0.02 * k, null, null);
        }

        FS_Log("Pinata: victim=" + victim.GetName() + " total=" + total + " chunk=" + chunkVal);
    }

    flagspawn._UpdateUI();
    flagspawn.State.NextTopKTime = 0.0;
}

function FS_OnPlayerHurtEvent() {
    flagspawn.Init();

    if (!flagspawn.CFG.ENABLE_DAMAGE_CHUNKS) return;
    if (!("event_data" in getroottable())) {
        FS_Log("FS_OnPlayerHurtEvent: missing event_data (listener must use CallScriptFunction + FetchEventData)");
        return;
    }

    local victim = null;
    try { victim = GetPlayerFromUserID(event_data.userid); } catch (e0) { victim = null; }
    if (!FS_IsPlayer(victim)) return;

    local dmg = 0.0;
    try { dmg = event_data.damageamount.tofloat(); } catch (e1) { dmg = 0.0; }
    if (dmg <= 0.0) return;

    local prec = flagspawn._EnsurePlayerRec(victim);

    local maxHp = flagspawn._GetMaxHealth(victim).tofloat();
    local threshold = maxHp * flagspawn.CFG.DAMAGE_THRESHOLD_PCT;
    if (threshold < 1.0) threshold = 1.0;

    prec.dmgAcc += dmg;

    while (prec.dmgAcc >= threshold) {
        prec.dmgAcc -= threshold;
        flagspawn._DropDamageChunk(victim);
    }
}

flagspawn._DropDamageChunk <- function(ply) {
    if (!FS_IsPlayer(ply)) return;

    // Find carried flag
    local src = null;
    foreach (suf, pkg in flagspawn.State.Flags) {
        if (!pkg || !FS_IsValid(pkg.flag)) continue;
        if (pkg.carrier == ply) { src = pkg; break; }
    }
    if (!src) return;

    // Limit
    if (flagspawn.State.Flags.len() + flagspawn.State.SpawnQueueValues.len() >= flagspawn.CFG.LIMIT_ACTIVE_FLAGS) return;

    // Compute chunk value (20% of current carried flag)
    local cur = src.pointValue;
    if (cur < 1) cur = 1;

    local chunkVal = floor(cur * flagspawn.CFG.DAMAGE_CHUNK_PCT);
    if (chunkVal < 1) chunkVal = 1;

    // Reduce source flag by chunk amount (never below 1)
    local newVal = cur - chunkVal;
    if (newVal < 1) newVal = 1;

    src.pointValue = newVal;
    flagspawn._WritePointValue(src.flag, newVal);
    src.retry = flagspawn.CFG.RETRY_COUNT;
    src.glowRetry = flagspawn.CFG.GLOW_RETRY_COUNT;

    // Queue spawn near player
    local org = FS_GetOrigin(ply);
    local off = Vector(RandomInt(-16, 16), RandomInt(-16, 16), flagspawn.CFG.CHUNK_Z_LIFT);

    flagspawn.State.SpawnQueueValues.append(chunkVal);
    flagspawn.State.SpawnQueueOrigins.append(org + off);

    local maker = flagspawn._FindByName(flagspawn.CFG.MAKER_BLU);
    if (FS_IsValid(maker)) flagspawn._EntFire(maker, "ForceSpawn", "", 0.0, null, null);

    FS_Log("Damage chunk: ply=" + ply.GetName() + " chunk=" + chunkVal + " remain=" + newVal);
};

// ----------------------------------------------------------------------------
// 13) Player spawn budget reset (event-driven)
// ----------------------------------------------------------------------------
function FS_OnPlayerSpawn_Event() {
    flagspawn.Init();

    if (!("event_data" in getroottable())) {
        FS_Log("FS_OnPlayerSpawn_Event: missing event_data (listener must use CallScriptFunction + FetchEventData)");
        return;
    }

    local ply = null;
    try { ply = GetPlayerFromUserID(event_data.userid); } catch (e0) { ply = null; }
    if (!FS_IsPlayer(ply)) return;

    local rec = flagspawn._EnsurePlayerRec(ply);
    rec.used = 0;
    rec.dmgAcc = 0.0;
    rec.nextSpawnTime = 0.0;

    // record lasts
    rec.lastLife = 0;
    try { rec.lastClass = ply.GetPlayerClass(); } catch (e1) { rec.lastClass = -1; }
    try { rec.lastTeam = ply.GetTeam(); } catch (e2) { rec.lastTeam = -1; }

    if (flagspawn.CFG.DBG) FS_Log("Budget reset for " + ply.GetName());
}

// ----------------------------------------------------------------------------
// 14) Player bookkeeping (polling fallback)
// ----------------------------------------------------------------------------
flagspawn._EnsurePlayerRec <- function(ply) {
    local key = ply.entindex().tostring();
    if (!(key in flagspawn.State.Player)) {
        flagspawn.State.Player[key] <- { used = 0, dmgAcc = 0.0, nextSpawnTime = 0.0, lastLife = -1, lastClass = -1, lastTeam = -1 };
    }
    return flagspawn.State.Player[key];
};

flagspawn._GetLifeState <- function(ply) {
    if (!FS_IsPlayer(ply)) return 0;
    try { return NetProps.GetPropInt(ply, "m_lifeState"); } catch (e) { return 0; }
};

flagspawn._ResetBudgetIfNeeded <- function(ply) {
    if (!FS_IsPlayer(ply)) return;

    local rec = flagspawn._EnsurePlayerRec(ply);
    local life = flagspawn._GetLifeState(ply);

    local cls = 0;
    local team = 0;
    try { cls = ply.GetPlayerClass(); } catch (e0) { cls = 0; }
    try { team = ply.GetTeam(); } catch (e1) { team = 0; }

    local respawned = (rec.lastLife != -1 && rec.lastLife != 0 && life == 0);
    local classChanged = (rec.lastClass != -1 && cls != 0 && cls != rec.lastClass);
    local teamChanged = (rec.lastTeam != -1 && team != rec.lastTeam);

    if (respawned || classChanged || teamChanged) {
        rec.used = 0;
        rec.dmgAcc = 0.0;
        rec.nextSpawnTime = 0.0;
    }

    rec.lastLife = life;
    rec.lastClass = cls;
    rec.lastTeam = team;
};

flagspawn._RepairAllBudgets <- function() {
    local ply = null;
    while ((ply = Entities.FindByClassname(ply, "player")) != null) {
        if (!FS_IsPlayer(ply)) continue;
        flagspawn._ResetBudgetIfNeeded(ply);
    }
};

// ----------------------------------------------------------------------------
// 15) Pulse / cleanup
// ----------------------------------------------------------------------------
flagspawn._CleanupDeadPkg <- function(pkg) {
    if (!pkg) return;
    if (FS_IsValid(pkg.prop)) pkg.prop.Kill();
    if (FS_IsValid(pkg.glow)) pkg.glow.Kill();
    if (FS_IsValid(pkg.propGlow)) pkg.propGlow.Kill();
    if (FS_IsValid(pkg.lock)) pkg.lock.Kill();
    if (FS_IsValid(pkg.lmm)) pkg.lmm.Kill();
};

flagspawn._Pulse <- function() {
    // Fallback budgets
    flagspawn._RepairAllBudgets();

    local removedAny = false;

    foreach (suf, pkg in flagspawn.State.Flags) {
        if (!pkg) continue;

        // Prune dead flags (merged / killed)
        if (!FS_IsValid(pkg.flag)) {
            flagspawn._CleanupDeadPkg(pkg);
            delete flagspawn.State.Flags[suf];
            removedAny = true;
            continue;
        }

        // Detect pointValue changes
        local rv = flagspawn._ReadPointValue(pkg.flag);
        if (rv != pkg.pointValue) {
            pkg.pointValue = rv;
            pkg.retry = flagspawn.CFG.RETRY_COUNT;
            pkg.glowRetry = flagspawn.CFG.GLOW_RETRY_COUNT;
        }

        // Visual retries
        if (pkg.retry > 0) {
            pkg.retry -= 1;
            flagspawn._ApplyVisualState(pkg);
        }

        // Glow retries
        if (pkg.glowRetry > 0) {
            pkg.glowRetry -= 1;
            local owner = flagspawn._GetFlagOwner(pkg.flag);
            local carried = (FS_IsValid(owner) && FS_IsPlayer(owner));
            if (carried) pkg.carrier = owner;
            flagspawn._ApplyGlowForState(pkg, carried);
        }
    }

    // TopK refresh
    local now = Time();
    if (now >= flagspawn.State.NextTopKTime) {
        flagspawn.State.NextTopKTime = now + flagspawn.CFG.TOPK_RECALC_INTERVAL;
        flagspawn._RecalcTopK();
    }

    if (removedAny) {
        flagspawn._UpdateUI();
        flagspawn.State.NextTopKTime = 0.0;
    }
};

flagspawn.Think <- function() {
    flagspawn._Pulse();
    return flagspawn.CFG.PULSE_INTERVAL;
};

// ----------------------------------------------------------------------------
// 16) Init
// ----------------------------------------------------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.InitDone) return;
    flagspawn.State.InitDone = true;

    local te = flagspawn._GetThinkEnt();
    if (flagspawn.CFG.DISABLE_TEAM_LEADER) {
        flagspawn._DisableTeamLeader();
        if (FS_IsValid(te)) {
            EntFireByHandle(te, "RunScriptCode", "flagspawn._DisableTeamLeader()", 0.2, null, null);
            EntFireByHandle(te, "RunScriptCode", "flagspawn._DisableTeamLeader()", 1.0, null, null);
        }
    }
    if (FS_IsValid(te)) {
        local sc = te.GetScriptScope();
        sc.Think <- flagspawn.Think;
        AddThinkToEnt(te, "Think");
    } else {
        FS_Log("WARN: no think-anchor found (no self, no scripter)");
    }

    flagspawn._UpdateUI();

    FS_Log("Initialized " + flagspawn.CFG.VERSION);
    FS_Log("tf_glow retarget uses NetProps.SetPropEntity(glow, m_hTarget, ent)." );
};

// Auto-init
flagspawn.Init();
