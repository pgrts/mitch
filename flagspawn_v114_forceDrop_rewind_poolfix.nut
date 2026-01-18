// ============================================================================
// Flagspawn v114 (Timing-Hole Rewind + Round-Down Piñata) — fs3_test + PD Fuel / Flagspawn
// ----------------------------------------------------------------------------
// What changed vs v111:
//  - Implements death piñata math: (floor(20% of carried) * 5) and returns
//    remainder back to spawner pool (bodygroup economy).
//  - Adds event hooks for player_death + player_hurt (map logic_eventlistener
//    via CallScriptFunction is the reliable path; ListenToGameEvent is optional).
//  - Keeps per-player spawner cooldowns (no !self Disable/Enable loops).
//
// IMPORTANT LIMITATION (known / breadcrumb):
//  - Damage-chunk spawning *also* needs to subtract from PD"s internal carried
//    total, otherwise it can dupe economy. We DO NOT guess netprops.
//    By default: damage chunks are ON for *visual testing* but do NOT attempt
//    to modify PD internals. When you discover the correct PD netprop(s), flip
//    CFG.DMG_ADJUST_PD = true and fill _PD_AdjustCarrySafe().
//
// SAFETY RULE (hard):
//  - Never call GetAbsOrigin() on players. Use _GetOrigin() helper.
// ============================================================================

// --- Root-table anchor (TF2 Squirrel safety) --------------------------------
local _rt = getroottable();
if (!("flagspawn" in _rt)) {
    _rt.flagspawn <- {};
} else {
    try { if (typeof _rt.flagspawn != "table") _rt.flagspawn <- {}; } catch(_e) { _rt.flagspawn <- {}; }
}
local flagspawn = _rt.flagspawn;
try {
    if (!("flagspawn" in this)) this.flagspawn <- _rt.flagspawn;
    else this.flagspawn = _rt.flagspawn;
} catch(_e) {}

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------
	flagspawn.CFG <- {
	    VERSION = "v114_forceDrop_rewind_poolfix",

    // Core names
    SCRIPTER_NAME = "scripter",

    // PD controller entity (tf_logic_player_destruction)
    PD_LOGIC_NAME = "fs_pd_logic",
    PD_TOGGLE_MAXSCORE_ON_START = true,

    // TF2 teams
    TEAM_RED = 2,
    TEAM_BLU = 3,

    // Spawner trigger zones
    SPAWNER_TRIG_BLU = "fs_spawner_blu",
    SPAWNER_TRIG_RED = "fs_spawner_red", // future

    // Makers used for NORMAL spawner dispensing
    MAKER_BLU = "fs_flag_maker_blu",
    MAKER_RED = "fs_flag_maker_red", // future

    // Makers used for DYNAMIC spawns (death/damage chunks). Optional.
    // If not found, we fall back to MAKER_BLU/MAKER_RED (works, but can fight
    // with heavy rapid spawns).
    MAKER_BLU_DYN = "fs_flag_maker_blu_dyn",
    MAKER_RED_DYN = "fs_flag_maker_red_dyn",

    // Spawner pool props (bodygroup displays remaining supply)
    PROP_BLU = "blu_flagspawner_prop",
    PROP_RED = "red_flagspawner_prop",

	    // Starting pool values (script is authoritative; do NOT rely on reading model bodygroups)
	    START_POOL_BLU = 100,
	    START_POOL_RED = 100,


	    // IMPORTANT: our spawner model has a $body (bounds) at bodygroup index 0 and a $bodygroup (fill) at index 1
    // So SetBodygroup/GetBodygroup must use index 1.
    PROP_BG_INDEX = 1,
    POOL_MIN = 0,
    POOL_MAX = 100,

    // Spawner spawn behavior
    SPAWN_Z_OFFSET = 8,
    PICKUP_FAIL_GRACE = 0.20,

    // Think dt
    THINK_DT = 0.10,

    // Debug
    DBG = true,
    DBG_SPAWNER = true,
    DBG_CHUNKS = true,

    // -----------------------------------------------------------------------
    // CLASS ECONOMY (budget + dispense rate)
    // -----------------------------------------------------------------------
    CLASS_SETTINGS = {
        [1] = { budget = 1,  rate = 1.00 }, // Scout
        [2] = { budget = 8,  rate = 0.25 }, // Sniper
        [3] = { budget = 4,  rate = 0.25 }, // Soldier
        [4] = { budget = 3,  rate = 0.30 }, // Demo
        [5] = { budget = 7,  rate = 0.20 }, // Medic
        [6] = { budget = 10, rate = 0.10 }, // Heavy
        [7] = { budget = 5,  rate = 0.25 }, // Pyro
        [8] = { budget = 1,  rate = 0.50 }, // Spy
        [9] = { budget = 6,  rate = 0.20 }  // Engy
    },
    DEFAULT_CLASS_SETTING = { budget = 3, rate = 0.35 },

    // -----------------------------------------------------------------------
    // TEMPLATE PACKAGE BASE NAMES (must match point_template prototypes)
    // -----------------------------------------------------------------------
    PACKAGE_BLU = {
        flag = "bluflag",
        lock = "red_lock_bluflag",
        glow = "bluflag_glow",
        sfx  = "fs_lockpad_sfx_proto",

        // fs3_test follower pieces (logic_measure_movement + helper targets)
        lmm = "blu_lmm",
        lmm_ref = "blu_lmm_ref",
        lmm_target = "blu_lmm_target"
    },
    PACKAGE_RED = {
        flag = "redflag",
        lock = "blu_lock_redflag",
        glow = "redflag_glow",
        sfx  = "fs_lockpad_sfx_proto",

        // Future parity with BLU (names TBD in VMF)
        lmm = "red_lmm",
        lmm_ref = "red_lmm_ref",
        lmm_target = "red_lmm_target"
    },

    // -----------------------------------------------------------------------
    // CHUNK / PIÑATA RULES
    // -----------------------------------------------------------------------
    CHUNK_BURST_COUNT = 5,
    CHUNK_FRACTION_NUM = 1,  // 20%
    CHUNK_FRACTION_DEN = 5,

    // Chunk anti-pickup window (mid-air protection)
    CHUNK_NO_PICKUP_TIME = 0.50,

    // Chunk velocities (tune in-game)
    CHUNK_SPEED_H = 320.0,
    CHUNK_SPEED_U = 360.0,

    // Damage chunk gate
    DMG_CHUNKS_ENABLED = true,
    DMG_THRESHOLD_HP_FRAC = 0.10,      // 10% max hp
    DMG_CHUNK_COOLDOWN = 0.75,

    // IMPORTANT: PD carry subtraction not solved yet.
    DMG_ADJUST_PD = false
};

// ---------------------------------------------------------------------------
// STATE
// ---------------------------------------------------------------------------
flagspawn.State <- {
    InitDone = false,

    Pool = {
	    [flagspawn.CFG.TEAM_BLU] = flagspawn.CFG.START_POOL_BLU,
	    [flagspawn.CFG.TEAM_RED] = flagspawn.CFG.START_POOL_RED
    },

    // Player state by SteamID3
    PlayerStats = {},

    // Spawned packages keyed by suffix
    Pkgs = {},

    // Spawn context queues (one per team) to correlate ForceSpawn -> OnEntitySpawned
    SpawnCtxQ = {
        [flagspawn.CFG.TEAM_BLU] = [],
        [flagspawn.CFG.TEAM_RED] = []
    }
};

// ---------------------------------------------------------------------------
// SAFE HELPERS
// ---------------------------------------------------------------------------
function _Dbg(msg) { if (flagspawn.CFG.DBG) printl("[FS] " + msg); }
function _DbgSpawner(msg) { if (flagspawn.CFG.DBG_SPAWNER) printl("[FS][SPAWN] " + msg); }
function _DbgChunks(msg) { if (flagspawn.CFG.DBG_CHUNKS) printl("[FS][CHUNK] " + msg); }

function _Now() { return Time(); }

function _IsValid(ent) {
    try { return (ent != null && ent.IsValid()); } catch(_e) { return false; }
}

function _IsPlayer(ent) {
    if (!_IsValid(ent)) return false;
    try { return ent.IsPlayer(); } catch(_e) { return false; }
}

function _FindByName(name) {
    if (name == null || name == "") return null;
    try { return Entities.FindByName(null, name); } catch(_e) { return null; }
}

function _GetOrigin(ent) {
    if (!_IsValid(ent)) return Vector(0,0,0);
    // HARD RULE: never call GetAbsOrigin() on players.
    if (_IsPlayer(ent)) {
        try { return NetProps.GetPropVector(ent, "m_vecOrigin"); } catch(_eP) {}
        return Vector(0,0,0);
    }
    try { return ent.GetOrigin(); } catch(_e) {}
    try { return NetProps.GetPropVector(ent, "m_vecOrigin"); } catch(_e2) {}
    return Vector(0,0,0);
}

function _SetOrigin(ent, v) {
    if (!_IsValid(ent)) return;
    try { ent.SetAbsOrigin(v); } catch(_e) {}
}

function _SetVelocity(ent, v) {
    if (!_IsValid(ent) || v == null) return;
    try { ent.SetAbsVelocity(v); return; } catch(_e) {}
    try { NetProps.SetPropVector(ent, "m_vecAbsVelocity", v); } catch(_e2) {}
}

function _GetName(ent) {
    if (!_IsValid(ent)) return "";
    try { return ent.GetName(); } catch(_e) { return ""; }
}

function _ClampInt(v, lo, hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

function _GetSteamID3(p) {
    if (!_IsPlayer(p)) return null;
    try {
        local sid = NetProps.GetPropString(p, "m_szNetworkIDString");
        if (sid && sid != "") return sid;
    } catch(_e) {}
    try {
        local sid3 = NetProps.GetPropString(p, "m_szNetworkID3");
        if (sid3 && sid3 != "") return sid3;
    } catch(_e2) {}
    try { return "ent#" + p.entindex(); } catch(_e3) { return null; }
}

function _GetPlayerClass(p) {
    if (!_IsPlayer(p)) return 0;
    try { return NetProps.GetPropInt(p, "m_PlayerClass.m_iClass"); } catch(_e) {}
    return 0;
}

function _GetSpawnTime(p) {
    if (!_IsPlayer(p)) return 0.0;
    try { return NetProps.GetPropFloat(p, "m_flSpawnTime"); } catch(_e) {}
    return 0.0;
}

function _GetTeamSafe(p) {
    if (!_IsPlayer(p)) return 0;
    try { return p.GetTeam(); } catch(_e) {}
    try { return NetProps.GetPropInt(p, "m_iTeamNum"); } catch(_e2) {}
    return 0;
}

function _GetMaxHealthSafe(p) {
    if (!_IsPlayer(p)) return 0;
    try {
        if ("GetMaxHealth" in p) {
            local mh = p.GetMaxHealth();
            if (mh != null && mh > 0) return mh;
        }
    } catch(_e) {}
    try {
        local mh2 = NetProps.GetPropInt(p, "m_iMaxHealth");
        if (mh2 != null && mh2 > 0) return mh2;
    } catch(_e2) {}
    try {
        local h = p.GetHealth();
        if (h != null && h > 0) return h;
    } catch(_e3) {}
    return 0;
}

function _GetPlayerFromUserIDSafe(uid) {
    if (uid == null) return null;
    try {
        if ("GetPlayerFromUserID" in getroottable()) return GetPlayerFromUserID(uid);
    } catch(_e) {}
    try {
        if ("MaxClients" in getroottable() && "PlayerInstanceFromIndex" in getroottable()) {
            local mc = MaxClients();
            for (local i = 1; i <= mc; i++) {
                local p = PlayerInstanceFromIndex(i);
                if (!_IsPlayer(p)) continue;
                local puid = 0;
                try { puid = NetProps.GetPropInt(p, "m_iUserID"); } catch(_e2) { puid = 0; }
                if (puid == uid) return p;
            }
        }
    } catch(_e3) {}
    return null;
}

function _GetClassSetting(pClass) {
    if (pClass in flagspawn.CFG.CLASS_SETTINGS) return flagspawn.CFG.CLASS_SETTINGS[pClass];
    return flagspawn.CFG.DEFAULT_CLASS_SETTING;
}

// ---------------------------------------------------------------------------
// PLAYER STATS + RESET BUG FIX (class change / respawn)
// ---------------------------------------------------------------------------
function _EnsurePlayerStats(p) {
    local key = _GetSteamID3(p);
    if (!key) return null;

    if (!(key in flagspawn.State.PlayerStats)) {
        flagspawn.State.PlayerStats[key] <- {
            lastClass = 0,
            lastSpawnTime = 0.0,

            used = {
                [flagspawn.CFG.TEAM_BLU] = 0,
                [flagspawn.CFG.TEAM_RED] = 0
            },
            inZone = {
                [flagspawn.CFG.TEAM_BLU] = false,
                [flagspawn.CFG.TEAM_RED] = false
            },
            nextDispense = {
                [flagspawn.CFG.TEAM_BLU] = 0.0,
                [flagspawn.CFG.TEAM_RED] = 0.0
            },

            // Carried points ledger (authoritative for our chunk math)
            carry = {
                [flagspawn.CFG.TEAM_BLU] = 0,
                [flagspawn.CFG.TEAM_RED] = 0
            },

            lastDamageChunkAt = 0.0
        };
    }

    local st = flagspawn.State.PlayerStats[key];

    local c = _GetPlayerClass(p);
    local sp = _GetSpawnTime(p);

    if (st.lastClass != 0 && c != 0 && st.lastClass != c) {
        _ResetPlayerLimits(p, "class change");
    } else if (st.lastSpawnTime != 0.0 && sp != 0.0 && st.lastSpawnTime != sp) {
        _ResetPlayerLimits(p, "respawn");
    }

    st.lastClass = c;
    st.lastSpawnTime = sp;
    return st;
}

function _ResetPlayerLimits(p, why) {
    local key = _GetSteamID3(p);
    if (!key) return;

    if (!(key in flagspawn.State.PlayerStats)) {
        _EnsurePlayerStats(p);
        return;
    }

    local st = flagspawn.State.PlayerStats[key];
    local now = _Now();

    st.used[flagspawn.CFG.TEAM_BLU] = 0;
    st.used[flagspawn.CFG.TEAM_RED] = 0;
    st.inZone[flagspawn.CFG.TEAM_BLU] = false;
    st.inZone[flagspawn.CFG.TEAM_RED] = false;
    st.nextDispense[flagspawn.CFG.TEAM_BLU] = now;
    st.nextDispense[flagspawn.CFG.TEAM_RED] = now;

    _Dbg("Reset limits for " + key + " (" + why + ")");
}

// Optional helper for older map wiring
::FS_OnPlayerSpawn_Event <- function() {
    if (("activator" in this) && activator != null && _IsPlayer(activator)) {
        _ResetPlayerLimits(activator, "player_spawn activator");
        return;
    }
    if (("event_data" in this) && ("userid" in event_data)) {
        local p = _GetPlayerFromUserIDSafe(event_data.userid);
        if (_IsPlayer(p)) _ResetPlayerLimits(p, "player_spawn event_data");
    }
};

// ---------------------------------------------------------------------------
// CARRY LEDGER
// ---------------------------------------------------------------------------
function _CarryTotal(st) {
    if (st == null) return 0;
    return st.carry[flagspawn.CFG.TEAM_BLU] + st.carry[flagspawn.CFG.TEAM_RED];
}

function _CarryTeamBest(st) {
    if (st == null) return null;
    local b = st.carry[flagspawn.CFG.TEAM_BLU];
    local r = st.carry[flagspawn.CFG.TEAM_RED];
    if (b <= 0 && r <= 0) return null;
    return (b >= r) ? flagspawn.CFG.TEAM_BLU : flagspawn.CFG.TEAM_RED;
}

function _CarryAdd(p, team, delta, why) {
    if (!_IsPlayer(p) || delta == 0) return;
    local st = _EnsurePlayerStats(p);
    if (st == null) return;
    local v = st.carry[team] + delta;
    if (v < 0) v = 0;
    st.carry[team] = v;
    if (flagspawn.CFG.DBG) _Dbg("Carry " + _GetSteamID3(p) + " team=" + team + " now=" + v + " (" + why + ")");
}

function _CarryClear(p, why) {
    if (!_IsPlayer(p)) return;
    local st = _EnsurePlayerStats(p);
    if (st == null) return;
    st.carry[flagspawn.CFG.TEAM_BLU] = 0;
    st.carry[flagspawn.CFG.TEAM_RED] = 0;
    st.lastDamageChunkAt = 0.0;
    if (flagspawn.CFG.DBG) _Dbg("CarryClear " + _GetSteamID3(p) + " (" + why + ")");
}

// ---------------------------------------------------------------------------
// SPAWNER ZONE ENTER/EXIT (called by fs_spawner_* triggers)
// ---------------------------------------------------------------------------
function _ZoneEnter(team) {
    if (!("activator" in this) || !_IsPlayer(activator)) return;
    local p = activator;
    local st = _EnsurePlayerStats(p);
    if (!st) return;

    st.inZone[team] = true;

    // First dispense happens after class delay
    local cs = _GetClassSetting(_GetPlayerClass(p));
    local now = _Now();
    st.nextDispense[team] = now + cs.rate;

    _DbgSpawner("ZoneEnter team=" + team + " player=" + _GetSteamID3(p) + " rate=" + cs.rate);
}

function _ZoneExit(team) {
    if (!("activator" in this) || !_IsPlayer(activator)) return;
    local p = activator;
    local st = _EnsurePlayerStats(p);
    if (!st) return;

    st.inZone[team] = false;
    _DbgSpawner("ZoneExit team=" + team + " player=" + _GetSteamID3(p));
}

::FS_SpawnerZoneEnterBlu <- function() { _ZoneEnter(flagspawn.CFG.TEAM_BLU); };
::FS_SpawnerZoneExitBlu  <- function() { _ZoneExit(flagspawn.CFG.TEAM_BLU); };
::FS_SpawnerZoneEnterRed <- function() { _ZoneEnter(flagspawn.CFG.TEAM_RED); };
::FS_SpawnerZoneExitRed  <- function() { _ZoneExit(flagspawn.CFG.TEAM_RED); };

// ---------------------------------------------------------------------------
// SPAWNER POOL (prop bodygroup + trigger enable/disable)
// ---------------------------------------------------------------------------
function _SetSpawnerPool(team, value) {
    value = _ClampInt(value, flagspawn.CFG.POOL_MIN, flagspawn.CFG.POOL_MAX);
    flagspawn.State.Pool[team] = value;

    local propName = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.PROP_BLU : flagspawn.CFG.PROP_RED;
    local trigName = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.SPAWNER_TRIG_BLU : flagspawn.CFG.SPAWNER_TRIG_RED;

    local prop = _FindByName(propName);
    if (_IsValid(prop)) {
        try { prop.SetBodygroup(flagspawn.CFG.PROP_BG_INDEX, value); } catch(_e) {}
    }

    if (trigName != null && trigName != "") {
        if (value <= 0) EntFire(trigName, "Disable", "", 0.0, null);
        else EntFire(trigName, "Enable", "", 0.0, null);
    }
}

function _ModifySpawnerPool(team, delta) {
    _SetSpawnerPool(team, flagspawn.State.Pool[team] + delta);
}

// ---------------------------------------------------------------------------
// "CAN"T PICKUP" PLACEHOLDERS (bonk / deadringer / jumpers / etc.)
// ---------------------------------------------------------------------------
function _HasCond(p, condId) {
    if (!_IsPlayer(p)) return false;
    try { return p.InCond(condId); } catch(_e) {}
    return false;
}

function _PlayerCannotPickupFlags(p) {
    if (!_IsPlayer(p)) return true;

    // TODO: Replace placeholders with your real TF_COND ids
    local BONK = ("TF_COND_BONKED" in _rt) ? _rt.TF_COND_BONKED : 14; // placeholder
    local DEADRINGER = ("TF_COND_FEIGN_DEATH" in _rt) ? _rt.TF_COND_FEIGN_DEATH : 4; // placeholder
    local STEALTH = ("TF_COND_STEALTHED" in _rt) ? _rt.TF_COND_STEALTHED : 1; // placeholder

    if (_HasCond(p, BONK)) return true;
    if (_HasCond(p, DEADRINGER)) return true;
    if (_HasCond(p, STEALTH)) return true;

    // TODO (weapons): Rocket Jumper / Sticky Jumper checks via itemdef / weapon classname.
    // TODO (conditions): ubercharge / stun / megaheal etc.

    return false;
}

// ---------------------------------------------------------------------------
// ADDCOND(10) TIMING-HOLE GUARD (enemy pickup before AddCond fires)
// ---------------------------------------------------------------------------
// DO NOT teleport the player. Rewind by restoring the FLAG back to its last
// known dropped position. In PD, the flag entity may be consumed instantly,
// so this uses ForceDrop + snap-back (no kill/respawn).

function _GetTeamSafe(p) {
    if (!_IsPlayer(p)) return 0;
    try { return p.GetTeam(); } catch(_e) { return 0; }
}

function _InferOwnerTeamFromFlagName(name) {
    if (!name) return null;
    // Note: use prefix match (not just substring) to avoid false positives.
    if (name.len() >= flagspawn.CFG.PACKAGE_BLU.flag.len() && name.slice(0, flagspawn.CFG.PACKAGE_BLU.flag.len()) == flagspawn.CFG.PACKAGE_BLU.flag) return flagspawn.CFG.TEAM_BLU;
    if (name.len() >= flagspawn.CFG.PACKAGE_RED.flag.len() && name.slice(0, flagspawn.CFG.PACKAGE_RED.flag.len()) == flagspawn.CFG.PACKAGE_RED.flag) return flagspawn.CFG.TEAM_RED;
    return null;
}


// ---------------------------------------------------------------------------
// TIMING-HOLE GUARD HELPERS (NO PHOENIX METHOD)
// ---------------------------------------------------------------------------
// IMPORTANT: We do NOT kill or respawn item_teamflag for the denial timing window.
// We simply ForceDrop the *same* flag entity and then snap it back to the last
// known dropped position (prefer the LMM follower target if present).

flagspawn._RewindFlagByEntIndex <- function(entIdx, x, y, z) {
    local f = null;
    try { f = EntIndexToHScript(entIdx); } catch(_e) { f = null; }
    if (!_IsValid(f)) return;
    local pos = Vector(x, y, z);
    _SetOrigin(f, pos);
    _SetVelocity(f, Vector(0,0,0));
};

function _ScheduleFlagRewind(flag, pos, delay) {
    if (!_IsValid(flag) || pos == null) return;
    local idx = 0;
    try { idx = flag.entindex(); } catch(_e) { idx = 0; }
    if (idx <= 0) return;

    // Use the map"s scripter entity to execute in a stable scope.
    // (RunScriptCode won"t pass event_data, but we don"t need it.)
    local code = "flagspawn._RewindFlagByEntIndex(" + idx + "," + pos.x + "," + pos.y + "," + pos.z + ")";
    EntFire(flagspawn.CFG.SCRIPTER_NAME, "RunScriptCode", code, delay, null);
}


function _HandleInvalidEnemyPickup(flag, p, ownerTeam, pv, rewindPos, suf, pkg) {
    // NO PHOENIX METHOD: do not kill/respawn flags.
    // We ForceDrop the same flag and snap it back to its last dropped location.
    _Dbg("INVALID PICKUP (rewind flag only): player team=" + _GetTeamSafe(p) + " picked ownerTeam=" + ownerTeam + " suf=" + suf + " pv=" + pv);

    if (rewindPos == null) {
        // Prefer cached position (LMM target) if present
        try {
            if (pkg && ("lastDropOrigin" in pkg)) rewindPos = pkg.lastDropOrigin;
        } catch(_e) {}
    }
    if (rewindPos == null) rewindPos = _GetOrigin(flag);

    // ForceDrop should undo PD credit (the pickup is reverted).
    // Do this BEFORE moving the entity, so the engine settles into dropped state.
    try { EntFireByHandle(flag, "ForceDrop", "", 0.0, p, p); } catch(_e2) {}

    // Snap back immediately and also schedule a couple of rewinds to win races
    // against PD/physics updating the entity in the next tick.
    _SetOrigin(flag, rewindPos);
    _SetVelocity(flag, Vector(0,0,0));

    _ScheduleFlagRewind(flag, rewindPos, 0.05);
    _ScheduleFlagRewind(flag, rewindPos, 0.15);

    // Keep template extras alive — they are part of the package and should
    // continue to follow/deny the dropped flag (via LMM).
}

// ---------------------------------------------------------------------------
// PACKAGE TRACKING
// ---------------------------------------------------------------------------
function _ExtractSuffix(name) {
    if (!name) return null;
    local idx = name.find("&");
    if (idx == null) return null;
    return name.slice(idx + 1);
}

function _KillEnt(ent) {
    if (!_IsValid(ent)) return;
    try { ent.Kill(); } catch(_e) {}
}

function _CleanupPkg(pkg) {
    if (!pkg) return;
    if ("lock" in pkg) _KillEnt(pkg.lock);
    if ("glow" in pkg) _KillEnt(pkg.glow);
    if ("sfx"  in pkg) _KillEnt(pkg.sfx);

    // fs3_test follower pieces
    if ("lmm" in pkg) _KillEnt(pkg.lmm);
    if ("lmm_ref" in pkg) _KillEnt(pkg.lmm_ref);
    if ("lmm_target" in pkg) _KillEnt(pkg.lmm_target);
}

function _ReadFlagPointsSafe(flag) {
    if (!_IsValid(flag)) return 0;
    local pv = 0;
    try { pv = NetProps.GetPropInt(flag, "m_nPointValue"); } catch(_e) { pv = 0; }
    if (pv == null || pv < 0) pv = 0;
    return pv;
}

function _ApplyFlagPointValue(flag, pv) {
    if (!_IsValid(flag)) return;
    pv = _ClampInt(pv, 0, 999);
    try { NetProps.SetPropInt(flag, "m_nPointValue", pv); } catch(_e) {}
    try { EntFireByHandle(flag, "SetPointValue", "" + pv, 0.0, null, null); } catch(_e2) {}
}

// ---------------------------------------------------------------------------
// SPAWN CONTEXT QUEUE
// ---------------------------------------------------------------------------
function _CtxQ_Push(team, ctx) {
    if (!(team in flagspawn.State.SpawnCtxQ)) return;
    flagspawn.State.SpawnCtxQ[team].append(ctx);
}

function _CtxQ_Pop(team) {
    if (!(team in flagspawn.State.SpawnCtxQ)) return null;
    local q = flagspawn.State.SpawnCtxQ[team];
    if (q.len() <= 0) return null;
    // FIFO
    local ctx = q[0];
    q.remove(0);
    return ctx;
}

// ---------------------------------------------------------------------------
// MAKER SPAWN CALLBACK
// ---------------------------------------------------------------------------
// Called by env_entity_maker OnEntitySpawned output (RunScriptCode FS_OnMakerSpawned())
::FS_OnMakerSpawned <- function() {
    local maker = ("caller" in this) ? caller : null;
    if (!_IsValid(maker)) return;

    local makerName = _GetName(maker);

    // Team hint by maker name
    local teamHint = null;
    if (makerName == flagspawn.CFG.MAKER_BLU || makerName == flagspawn.CFG.MAKER_BLU_DYN) teamHint = flagspawn.CFG.TEAM_BLU;
    else if (makerName == flagspawn.CFG.MAKER_RED || makerName == flagspawn.CFG.MAKER_RED_DYN) teamHint = flagspawn.CFG.TEAM_RED;

    // Prefer activator (OnEntitySpawned sets activator=spawned entity)
    local f = null;
    if (("activator" in this) && _IsValid(activator)) {
        try { if (activator.GetClassname() == "item_teamflag") f = activator; } catch(_e) {}
    }

    // If needed, scan for newest untracked flag
    local team = teamHint;
    if (f == null) {
        local it = Entities.FindByName(null, flagspawn.CFG.PACKAGE_BLU.flag + "*");
        while (it != null) {
            local suf = _ExtractSuffix(_GetName(it));
            if (suf && !(suf in flagspawn.State.Pkgs)) { f = it; team = flagspawn.CFG.TEAM_BLU; break; }
            it = Entities.FindByName(it, flagspawn.CFG.PACKAGE_BLU.flag + "*");
        }
        if (f == null) {
            it = Entities.FindByName(null, flagspawn.CFG.PACKAGE_RED.flag + "*");
            while (it != null) {
                local suf2 = _ExtractSuffix(_GetName(it));
                if (suf2 && !(suf2 in flagspawn.State.Pkgs)) { f = it; team = flagspawn.CFG.TEAM_RED; break; }
                it = Entities.FindByName(it, flagspawn.CFG.PACKAGE_RED.flag + "*");
            }
        }
    }

    if (team == null || f == null) return;

    local sufFinal = _ExtractSuffix(_GetName(f));
    if (!sufFinal) return;

    local pkgNames = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.PACKAGE_BLU : flagspawn.CFG.PACKAGE_RED;

    // Handles for package extras (may be null)
    local lockEnt = _FindByName(pkgNames.lock + "&" + sufFinal);
    local glowEnt = _FindByName(pkgNames.glow + "&" + sufFinal);
    local sfxEnt  = _FindByName(pkgNames.sfx  + "&" + sufFinal);

    // fs3_test follower handles (may be null)
    local lmmEnt = _FindByName(pkgNames.lmm + "&" + sufFinal);
    local lmmRefEnt = _FindByName(pkgNames.lmm_ref + "&" + sufFinal);
    local lmmTargetEnt = _FindByName(pkgNames.lmm_target + "&" + sufFinal);

    local pkg = {
        team = team,
        suffix = sufFinal,
        flag = f,
        lock = lockEnt,
        glow = glowEnt,
        sfx  = sfxEnt,
        lmm = lmmEnt,
        lmm_ref = lmmRefEnt,
        lmm_target = lmmTargetEnt,
        created = _Now(),
        pointValue = _ReadFlagPointsSafe(f),

        // Last known dropped origin (correctness guard for AddCond(10) timing hole)
        lastDropOrigin = _GetOrigin(f),

        // pickup-fail cleanup window
        expectPickup = false,
        pickupDeadline = 0.0,
        spawnedByKey = null,

        // chunk marker
        isChunk = false,
        consumePool = true
    };

    // Apply ctx if present
    local ctx = _CtxQ_Pop(team);
    if (ctx != null) {
        // stale ctx protection (very loose)
        if (("time" in ctx) && (_Now() - ctx.time) > 1.0) ctx = null;
    }

    if (ctx != null) {
        if ("playerKey" in ctx) pkg.spawnedByKey = ctx.playerKey;
        if ("expectPickup" in ctx) pkg.expectPickup = ctx.expectPickup;
        if (pkg.expectPickup) pkg.pickupDeadline = _Now() + flagspawn.CFG.PICKUP_FAIL_GRACE;

        if ("consumePool" in ctx) pkg.consumePool = ctx.consumePool;
        if ("isChunk" in ctx) pkg.isChunk = ctx.isChunk;

        if ("pointValue" in ctx && ctx.pointValue != null) {
            _ApplyFlagPointValue(f, ctx.pointValue);
            pkg.pointValue = ctx.pointValue;
        }

        if ("velocity" in ctx && ctx.velocity != null) {
            _SetVelocity(f, ctx.velocity);
        }

        if ("noPickupTime" in ctx && ctx.noPickupTime != null && ctx.noPickupTime > 0.0) {
            // Mid-air protection: disable flag pickup briefly
            EntFireByHandle(f, "Disable", "", 0.0, null, null);
            EntFireByHandle(f, "Enable", "", ctx.noPickupTime, null, null);
        }
    }

    // Track
    flagspawn.State.Pkgs[sufFinal] <- pkg;

    // Consume pool only when requested (normal spawner dispense)
    if (pkg.consumePool) _ModifySpawnerPool(team, -1);

    _Dbg("Spawned pkg: " + pkgNames.flag + "&" + sufFinal + " team=" + team + " pv=" + pkg.pointValue + (pkg.isChunk ? " (chunk)" : ""));
};

// ---------------------------------------------------------------------------
// DIRECT FLAG OUTPUTS (caller=flag, activator=player)
// ---------------------------------------------------------------------------
::FS_Direct_Pickup <- function() {
    local flag = ("caller" in this) ? caller : null;
    local p = ("activator" in this) ? activator : null;
    if (!_IsValid(flag) || !_IsPlayer(p)) return;

    local pv = _ReadFlagPointsSafe(flag);
    if (pv <= 0) pv = 1;

    local name = _GetName(flag);
    local team = null;

    // Prefer pkg team if known
    local suf = _ExtractSuffix(name);
    if (suf && (suf in flagspawn.State.Pkgs)) {
        try {
            team = flagspawn.State.Pkgs[suf].team;
            flagspawn.State.Pkgs[suf].expectPickup <- false;
        } catch(_e) {}
    }

    if (team == null) {
        if (name != null && name.find(flagspawn.CFG.PACKAGE_BLU.flag) != null) team = flagspawn.CFG.TEAM_BLU;
        else if (name != null && name.find(flagspawn.CFG.PACKAGE_RED.flag) != null) team = flagspawn.CFG.TEAM_RED;
        else team = flagspawn.CFG.TEAM_BLU;
    }

    // AddCond(10) timing-hole guard: if enemy picks up a team-locked flag,
    // immediately rewind the FLAG back to its last known dropped position.
    // (Do NOT teleport the player.)
    local pTeam = _GetTeamSafe(p);
    local ownerTeam = team;

    // If we can"t infer team from tracking, fall back to name prefix
    if (ownerTeam == null) ownerTeam = _InferOwnerTeamFromFlagName(name);

    if (ownerTeam != null && pTeam != 0 && pTeam != ownerTeam) {
        local pkg = null;
        local rewindPos = null;
        if (suf && (suf in flagspawn.State.Pkgs)) {
            try {
                pkg = flagspawn.State.Pkgs[suf];
                rewindPos = ("lastDropOrigin" in pkg) ? pkg.lastDropOrigin : null;
            } catch(_e) {}
        }
        if (rewindPos == null) rewindPos = _GetOrigin(flag);

        _HandleInvalidEnemyPickup(flag, p, ownerTeam, pv, rewindPos, suf, pkg);
        return;
    }

    _CarryAdd(p, team, pv, "pickup");
};

::FS_Direct_Drop <- function() {
    // Placeholder — PD drop is mostly automatic.
};

// ---------------------------------------------------------------------------
// BANKING HOOK (call from func_capturezone outputs)
// ---------------------------------------------------------------------------
function _BankClear(team) {
    if (!("activator" in this) || !_IsPlayer(activator)) return;
    local p = activator;

    // We clear ONLY that team"s ledger (but also clear other to be safe)
    _CarryClear(p, "banked team=" + team);
}

::FS_OnBankBlu <- function() { _BankClear(flagspawn.CFG.TEAM_BLU); };
::FS_OnBankRed <- function() { _BankClear(flagspawn.CFG.TEAM_RED); };

// ---------------------------------------------------------------------------
// SPAWNER DISPENSE (Think-driven)
// ---------------------------------------------------------------------------
function _TryDispense(team, p, st) {
    if (!_IsPlayer(p) || st == null) return;

    // Gate: alive
    try { if (NetProps.GetPropInt(p, "m_lifeState") != 0) return; } catch(_e) {}

    // Gate: pool
    if (!(team in flagspawn.State.Pool)) return;
    if (flagspawn.State.Pool[team] <= 0) return;

    // Gate: can"t pick up
    if (_PlayerCannotPickupFlags(p)) return;

    // Gate: budget
    local cs = _GetClassSetting(_GetPlayerClass(p));
    local used = st.used[team];
    if (used >= cs.budget) return;

    // Gate: timing
    local now = _Now();
    if (now < st.nextDispense[team]) return;

    // Pick maker
    local makerName = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.MAKER_BLU : flagspawn.CFG.MAKER_RED;
    local maker = _FindByName(makerName);
    if (!_IsValid(maker)) return;

    // Move maker to player and spawn
    local pos = _GetOrigin(p) + Vector(0,0,flagspawn.CFG.SPAWN_Z_OFFSET);
    _SetOrigin(maker, pos);

    _CtxQ_Push(team, {
        time = now,
        playerKey = _GetSteamID3(p),
        expectPickup = true,
        consumePool = true,
        isChunk = false
    });

    EntFire(makerName, "ForceSpawn", "", 0.0, p);

    st.used[team] = used + 1;
    st.nextDispense[team] = now + cs.rate;

    _DbgSpawner("Dispensed team=" + team + " used=" + st.used[team] + "/" + cs.budget + " next=" + cs.rate);
}

// ---------------------------------------------------------------------------
// PIÑATA / CHUNK MATH
// ---------------------------------------------------------------------------
function _CalcChunkValue(carryTotal) {
    // floor(carryTotal * (NUM/DEN))
    if (carryTotal <= 0) return 0;
    local v = ((carryTotal * flagspawn.CFG.CHUNK_FRACTION_NUM) / flagspawn.CFG.CHUNK_FRACTION_DEN).tointeger();
    if (v < 0) v = 0;
    return v;
}

function _MakeRadialVel(i, n, speedH, speedU) {
    // Evenly spaced angles with slight jitter
    local baseDeg = (360.0 / n) * i;
    local jitter = 18.0 * (RandomFloat(-1.0, 1.0));
    local ang = (baseDeg + jitter) * 0.01745329252; // deg->rad
    local vx = cos(ang) * speedH;
    local vy = sin(ang) * speedH;
    local vz = speedU + RandomFloat(-40.0, 40.0);
    return Vector(vx, vy, vz);
}

function _GetDynMakerName(team) {
    if (team == flagspawn.CFG.TEAM_BLU) {
        local m = _FindByName(flagspawn.CFG.MAKER_BLU_DYN);
        return _IsValid(m) ? flagspawn.CFG.MAKER_BLU_DYN : flagspawn.CFG.MAKER_BLU;
    }
    if (team == flagspawn.CFG.TEAM_RED) {
        local m2 = _FindByName(flagspawn.CFG.MAKER_RED_DYN);
        return _IsValid(m2) ? flagspawn.CFG.MAKER_RED_DYN : flagspawn.CFG.MAKER_RED;
    }
    return flagspawn.CFG.MAKER_BLU;
}

function _SpawnChunk(team, origin, pv, vel) {
    if (pv <= 0) return;

    local makerName = _GetDynMakerName(team);
    local maker = _FindByName(makerName);
    if (!_IsValid(maker)) {
        _DbgChunks("WARN: no maker for chunks: " + makerName);
        return;
    }

    _SetOrigin(maker, origin + Vector(0,0,flagspawn.CFG.SPAWN_Z_OFFSET));

    _CtxQ_Push(team, {
        time = _Now(),
        playerKey = null,
        expectPickup = false,
        consumePool = false,
        isChunk = true,
        pointValue = pv,
        velocity = vel,
        noPickupTime = flagspawn.CFG.CHUNK_NO_PICKUP_TIME
    });

    EntFire(makerName, "ForceSpawn", "", 0.0, null);
}

// ---------------------------------------------------------------------------
// DEATH PIÑATA (20% x 5, round down; remainder -> spawner pool)
// ---------------------------------------------------------------------------
function _DoDeathPinata(pVictim) {
    if (!_IsPlayer(pVictim)) return;

    local st = _EnsurePlayerStats(pVictim);
    if (st == null) return;

    local carryTotal = _CarryTotal(st);
    if (carryTotal <= 0) return; // don"t apply to non-carriers

    local teamPool = _GetTeamSafe(pVictim);
    if (teamPool != flagspawn.CFG.TEAM_BLU && teamPool != flagspawn.CFG.TEAM_RED) {
        local tb = _CarryTeamBest(st);
        teamPool = (tb != null) ? tb : flagspawn.CFG.TEAM_BLU;
    }

    local chunkVal = _CalcChunkValue(carryTotal);
    local totalDrop = chunkVal * flagspawn.CFG.CHUNK_BURST_COUNT;
    local remainder = carryTotal - totalDrop;
    if (remainder < 0) remainder = 0;

    _DbgChunks("DeathPinata victim=" + _GetSteamID3(pVictim) + " carry=" + carryTotal + " chunk=" + chunkVal + " totalDrop=" + totalDrop + " remainder->pool=" + remainder);

    local o = _GetOrigin(pVictim) + Vector(0,0,48);

    // Spawn 5 chunks if chunkVal > 0
    if (chunkVal > 0) {
        for (local i = 0; i < flagspawn.CFG.CHUNK_BURST_COUNT; i++) {
            local vel = _MakeRadialVel(i, flagspawn.CFG.CHUNK_BURST_COUNT, flagspawn.CFG.CHUNK_SPEED_H, flagspawn.CFG.CHUNK_SPEED_U);
            _SpawnChunk(teamPool, o, chunkVal, vel);
        }
    }

    // Remainder refunds into spawner pool economy
    if (remainder > 0) {
        _ModifySpawnerPool(teamPool, remainder);
    }

    // Clear ledger (PD will handle actual carry reset on death)
    _CarryClear(pVictim, "death pinata");
}

// ---------------------------------------------------------------------------
// DAMAGE CHUNK (needs maxHP + carried value)
// ---------------------------------------------------------------------------
function _PD_AdjustCarrySafe(pVictim, delta) {
    // Placeholder: once you find the PD carry netprop, implement here.
    // Examples to try later (DO NOT ASSUME):
    //  - NetProps.GetPropInt(pVictim, "m_iNumCarriedItems")
    //  - NetProps.GetPropInt(pVictim, "m_nNumCarriedItems")
    //  - NetProps.GetPropInt(pVictim, "m_nPlayerDestructionPoints")
    // Return true if applied.
    return false;
}

function _DoDamageChunk(pVictim, damageAmount) {
    if (!_IsPlayer(pVictim)) return;
    if (!flagspawn.CFG.DMG_CHUNKS_ENABLED) return;

    local st = _EnsurePlayerStats(pVictim);
    if (st == null) return;

    local carryTotal = _CarryTotal(st);
    if (carryTotal <= 0) return;

    local mh = _GetMaxHealthSafe(pVictim);
    if (mh <= 0) return;

    local thresh = (mh.tofloat() * flagspawn.CFG.DMG_THRESHOLD_HP_FRAC);
    if (damageAmount.tofloat() < thresh) return;

    local now = _Now();
    if ((now - st.lastDamageChunkAt) < flagspawn.CFG.DMG_CHUNK_COOLDOWN) return;

    local chunkVal = _CalcChunkValue(carryTotal);
    if (chunkVal <= 0) return;

    // Which team "owns" the carried points (usually one). Prefer best team.
    local teamCarry = _CarryTeamBest(st);
    if (teamCarry == null) {
        local t = _GetTeamSafe(pVictim);
        teamCarry = (t == flagspawn.CFG.TEAM_BLU || t == flagspawn.CFG.TEAM_RED) ? t : flagspawn.CFG.TEAM_BLU;
    }

    // Spawn one chunk in a random direction
    local o = _GetOrigin(pVictim) + Vector(0,0,48);
    local vel = _MakeRadialVel(RandomInt(0, 4), 5, flagspawn.CFG.CHUNK_SPEED_H * 0.85, flagspawn.CFG.CHUNK_SPEED_U * 0.75);
    _SpawnChunk(teamCarry, o, chunkVal, vel);

    // Update our ledger
    _CarryAdd(pVictim, teamCarry, -chunkVal, "damage chunk");
    st.lastDamageChunkAt = now;

    // Optional: attempt PD carry subtraction once you know the netprop.
    if (flagspawn.CFG.DMG_ADJUST_PD) {
        local ok = _PD_AdjustCarrySafe(pVictim, -chunkVal);
        if (!ok) _DbgChunks("WARN: DMG_ADJUST_PD enabled but PD netprop unknown; chunk may dupe.");
    }

    _DbgChunks("DamageChunk victim=" + _GetSteamID3(pVictim) + " dmg=" + damageAmount + " mh=" + mh + " carry=" + carryTotal + " chunk=" + chunkVal);
}

// ---------------------------------------------------------------------------
// EVENT HANDLERS (preferred: map logic_eventlistener -> CallScriptFunction)
// ---------------------------------------------------------------------------
::FS_OnPlayerDeathEvent <- function() {
    // Called by logic_eventlistener (player_death)
    local uid = null;
    try { if (("event_data" in this) && ("userid" in event_data)) uid = event_data.userid; } catch(_e) {}

    local p = (uid != null) ? _GetPlayerFromUserIDSafe(uid) : null;
    if (!_IsPlayer(p)) {
        // fallback: activator
        if (("activator" in this) && _IsPlayer(activator)) p = activator;
    }

    if (_IsPlayer(p)) _DoDeathPinata(p);
};

::FS_OnPlayerHurtEvent <- function() {
    // Called by logic_eventlistener (player_hurt)
    local uid = null;
    local dmg = 0;
    try {
        if (("event_data" in this) && ("userid" in event_data)) uid = event_data.userid;
        if (("event_data" in this) && ("damageamount" in event_data)) dmg = event_data.damageamount;
    } catch(_e) {}

    local p = (uid != null) ? _GetPlayerFromUserIDSafe(uid) : null;
    if (!_IsPlayer(p)) {
        if (("activator" in this) && _IsPlayer(activator)) p = activator;
    }

    if (_IsPlayer(p) && dmg > 0) _DoDamageChunk(p, dmg);
};

// Optional: try registering directly if engine exposes ListenToGameEvent
function _TryListenToGameEvents() {
    try {
        if (!("ListenToGameEvent" in getroottable())) return;

        // NOTE: In TF2, these callbacks are called with (event_data)
        ListenToGameEvent("player_death", function(ev) {
            try {
                if (ev == null || !("userid" in ev)) return;
                local p = _GetPlayerFromUserIDSafe(ev.userid);
                if (_IsPlayer(p)) _DoDeathPinata(p);
            } catch(_e) {}
        }, null);

        ListenToGameEvent("player_hurt", function(ev) {
            try {
                if (ev == null || !("userid" in ev)) return;
                local dmg = ("damageamount" in ev) ? ev.damageamount : 0;
                if (dmg <= 0) return;
                local p = _GetPlayerFromUserIDSafe(ev.userid);
                if (_IsPlayer(p)) _DoDamageChunk(p, dmg);
            } catch(_e) {}
        }, null);

        _Dbg("ListenToGameEvent registered (optional path)");
    } catch(_e2) {
        _Dbg("ListenToGameEvent unavailable / failed (map listeners recommended)");
    }
}

// ---------------------------------------------------------------------------
// THINK
// ---------------------------------------------------------------------------
flagspawn.Think <- function() {
    // Init
    if (!flagspawn.State.InitDone) {
        flagspawn.State.InitDone = true;


	        // Initialize pools from configured defaults.
	        // IMPORTANT: Do NOT try to read bodygroups at runtime here.
	        // In TF2 VScript, GetBodygroup can be unreliable early, and a bad read (0)
	        // would disable the spawner even if the model is showing 100 in Hammer.
	        // The script is authoritative: Pool -> SetBodygroup (display), not vice versa.
	        _SetSpawnerPool(flagspawn.CFG.TEAM_BLU, flagspawn.State.Pool[flagspawn.CFG.TEAM_BLU]);
	        _SetSpawnerPool(flagspawn.CFG.TEAM_RED, flagspawn.State.Pool[flagspawn.CFG.TEAM_RED]);

        _Dbg("InitDone pools: BLU=" + flagspawn.State.Pool[flagspawn.CFG.TEAM_BLU] + " RED=" + flagspawn.State.Pool[flagspawn.CFG.TEAM_RED]);
        _Dbg("Init uses PROP_BG_INDEX=" + flagspawn.CFG.PROP_BG_INDEX);
    }

    // 1) Spawner dispense
    local ent = Entities.FindByClassname(null, "player");
    while (ent != null) {
        local p = ent;
        local st = _EnsurePlayerStats(p);
        if (st != null) {
            if (st.inZone[flagspawn.CFG.TEAM_BLU]) _TryDispense(flagspawn.CFG.TEAM_BLU, p, st);
            if (st.inZone[flagspawn.CFG.TEAM_RED]) _TryDispense(flagspawn.CFG.TEAM_RED, p, st);
        }
        ent = Entities.FindByClassname(ent, "player");
    }

    // 2) Package cleanup
    local _toDel = [];
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!pkg) { _toDel.append(suf); continue; }

        // While the flag entity exists in-world (PD-dropped), cache its current position.
        // This is used to rewind flags in the rare AddCond(10) timing-hole pickup.
        // Keep a last-known dropped position for rewind. Prefer the LMM follower target if present.
        try {
            if (("lmm_target" in pkg) && _IsValid(pkg.lmm_target)) pkg.lastDropOrigin = _GetOrigin(pkg.lmm_target);
            else pkg.lastDropOrigin = _GetOrigin(pkg.flag);
        } catch(_e) {}

        if (!_IsValid(pkg.flag)) {
            _CleanupPkg(pkg);
            _toDel.append(suf);
            continue;
        }

        // Pickup-fail cleanup
        if (pkg.expectPickup && pkg.pickupDeadline > 0.0 && _Now() > pkg.pickupDeadline) {
            _DbgSpawner("PickupFail: killing pkg " + suf);

            _KillEnt(pkg.flag);
            _CleanupPkg(pkg);

            // Refund pool
	            // NOTE: TF2 VScript's older Squirrel build can choke on unary "+".
	            // Use a plain literal instead of "+1".
	            if (pkg.team != null) _ModifySpawnerPool(pkg.team, 1);

            // Refund personal budget if known
            if (pkg.spawnedByKey != null && (pkg.spawnedByKey in flagspawn.State.PlayerStats)) {
                local st2 = flagspawn.State.PlayerStats[pkg.spawnedByKey];
                if (st2 && (pkg.team in st2.used) && st2.used[pkg.team] > 0) {
                    st2.used[pkg.team] = st2.used[pkg.team] - 1;
                }
            }

            _toDel.append(suf);
        }
    }

    foreach (_suf in _toDel) {
        try { flagspawn.State.Pkgs.rawdelete(_suf); } catch(_e) {}
    }

    return flagspawn.CFG.THINK_DT;
};

// ---------------------------------------------------------------------------
// DEBUG COMMANDS
// ---------------------------------------------------------------------------
::FS_Dump <- function() {
    printl("[FS] ---- DUMP ----");
    printl("[FS] Version=" + flagspawn.CFG.VERSION);
    printl("[FS] Pool BLU=" + flagspawn.State.Pool[flagspawn.CFG.TEAM_BLU] + " RED=" + flagspawn.State.Pool[flagspawn.CFG.TEAM_RED]);
    printl("[FS] Pkgs=" + flagspawn.State.Pkgs.len());

    foreach (k, st in flagspawn.State.PlayerStats) {
        if (!st) continue;
        printl("[FS] Player " + k +
            " usedBlu=" + st.used[flagspawn.CFG.TEAM_BLU] +
            " usedRed=" + st.used[flagspawn.CFG.TEAM_RED] +
            " carryBlu=" + st.carry[flagspawn.CFG.TEAM_BLU] +
            " carryRed=" + st.carry[flagspawn.CFG.TEAM_RED] +
            " inBluZone=" + st.inZone[flagspawn.CFG.TEAM_BLU] +
            " inRedZone=" + st.inZone[flagspawn.CFG.TEAM_RED]
        );
    }
};

::FS_SetPoolBlu <- function(v) { _SetSpawnerPool(flagspawn.CFG.TEAM_BLU, v); };
::FS_AddPoolBlu <- function(d) { _ModifySpawnerPool(flagspawn.CFG.TEAM_BLU, d); };

::FS_TestDeathPinata <- function() {
    // For quick testing: run while looking at a player or set activator via ent_fire.
    if (("activator" in this) && _IsPlayer(activator)) _DoDeathPinata(activator);
};

// ---------------------------------------------------------------------------
// STARTUP
// ---------------------------------------------------------------------------
::FS_Start <- function() {
    try {
        local sc = self.GetScriptScope();
        if (sc) {
            sc.Think <- flagspawn.Think;
            AddThinkToEnt(self, "Think");
        }
    } catch(_e) {}

    // PD HUD quirk
    if (flagspawn.CFG.PD_TOGGLE_MAXSCORE_ON_START) {
        local pd = _FindByName(flagspawn.CFG.PD_LOGIC_NAME);
        if (_IsValid(pd)) {
            EntFire(flagspawn.CFG.PD_LOGIC_NAME, "EnableMaxScoreUpdating", "", 0.0, null);
            EntFire(flagspawn.CFG.PD_LOGIC_NAME, "DisableMaxScoreUpdating", "", 1.0, null);
        }
    }

    // Optional event registration (map listeners still recommended)
    _TryListenToGameEvents();

    _Dbg("System Started (" + flagspawn.CFG.VERSION + ")");
};

try { if (self && self.IsValid()) FS_Start(); } catch(_e) {}
