// ============================================================================
// Flagspawn v6.2 — Return Economy + Slot Stock (25) + Event-Driven Glow/Chunks
// ----------------------------------------------------------------------------
// Goals (per your latest notes/logs):
//  - STOP spawning 100-value flags by accident (template default).
//  - Separate TWO concepts:
//      (A) Stock / slots remaining (max 25 active flags) -> shown on worldtext.
//      (B) Budget bonus / point pool (0..500) -> shown on spawner meter prop(s).
//  - Spawner gating is based on STOCK (slots), NOT budget.
//  - Spawn value is derived from budget (with a safe starter minimum), and is
//    applied explicitly to the spawned item_teamflag (and meter prop) so it
//    never falls back to template defaults.
//  - Refund budget on Return/Capture (direct outputs), BUT do NOT refund on
//    Merge (absorbed flag deletion).
//  - Piñata death + damage chunks work off our carry ledger (no unknown PD
//    netprops). We therefore MUST add to ledger on spawner dispense (because
//    PD may not fire OnPickup when spawning directly into the player).
//
// Hard rules:
//  - Never call GetAbsOrigin() on players.
//  - Spawner prop meter uses bodygroup INDEX 1: SetBodygroup(1, value).
//  - env_entity_maker spawnflags must include 1 (name fixup unique suffix).
// ============================================================================

// --- Root-table anchor (TF2 Squirrel safety) --------------------------------
local _rt = getroottable();
if (!('flagspawn' in _rt) || typeof _rt.flagspawn != 'table') _rt.flagspawn <- {};
local flagspawn = _rt.flagspawn;
try {
    if (!('flagspawn' in this)) this.flagspawn <- flagspawn;
    else this.flagspawn = flagspawn;
} catch(_e) {}

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------
flagspawn.CFG <- {
    VERSION = 'fs_v6.5_firstblood_capture_destruction',

    // Core
    SCRIPTER_NAME = 'scripter',

    // Teams
    TEAM_RED = 2,
    TEAM_BLU = 3,

    // Spawner trigger zones
    SPAWNER_TRIG_BLU = 'fs_spawner_blu',
    SPAWNER_TRIG_RED = 'fs_spawner_red',

    // Makers
    MAKER_BLU = 'fs_flag_maker_blu',
    MAKER_RED = 'fs_flag_maker_red',
    MAKER_BLU_DYN = 'fs_flag_maker_blu_dyn',
    MAKER_RED_DYN = 'fs_flag_maker_red_dyn',

    // Package base names (prototype names inside point_template)
    PACKAGE_BLU = {
        flag = 'bluflag',
        prop = 'bluflag_prop',
        lock = 'red_lock_bluflag',
        glow = 'bluflag_glow',
        lmm_target = 'blu_lmm_target',
        lmm_ref    = 'blu_lmm_ref'
    },
    PACKAGE_RED = {
        flag = 'redflag',
        prop = 'redflag_prop',
        lock = 'blu_lock_redflag',
        glow = 'redflag_glow',
        lmm_target = 'red_lmm_target',
        lmm_ref    = 'red_lmm_ref'
    },

    // STOCK (slots)
    LIMIT_ACTIVE_FLAGS = 25,

    // STOCK display (worldtext)
    STOCK_TEXT_BLU = 'blu_pool_text',
    STOCK_TEXT_RED = 'fs_stock_red',

    // Optional lock sprite (shows when stock is 0)
    LOCK_SPRITE_BLU = 'blu_spawner_lock',
    LOCK_SPRITE_RED = 'red_spawner_lock',
    // BUDGET (bonus pool) display (spawner meter prop(s))
    // If you place 5 props, name them: blu_flagspawner_prop01..05
    // This mode shows the bonus as 5 equal-ish shares (each <=100).
    SPAWNER_PROP_BLU_COUNT = 5,
    SPAWNER_PROP_BLU_PREFIX = 'blu_flagspawner_prop',
    SPAWNER_PROP_RED_COUNT = 0,
    SPAWNER_PROP_RED_PREFIX = 'red_flagspawner_prop',

    // Budget pool settings (team bonus pool)
    POOL_START_BLU = 0,
    POOL_START_RED = 0,

    // Team bonus pool hard cap (total across all shares)
    POOL_HARDCAP = 500,

    // Bonus is split into N shares. Each spawner dispense draws from ONE share.
    POOL_SHARES = 5,

    // Per-flag max point value (engine-friendly)
    VALUE_CAP = 100,

    // Player carry cap (prevents one player from draining the whole pool)
    // This is enforced at the SPAWNER: once your carried total hits this cap,
    // the spawner stops dispensing to you until you deposit/return/die.
    CARRY_CAP = 100,

    // Never spawn a 0-value flag (PD edge cases)
    SPAWN_MIN_VALUE = 1,

    // Capture -> economy award (goes to CAPTURER team)
    CAPTURE_MULT = 2,

    // First-blood economy bonus (first 3 capturers per team within first 3 minutes)
    FIRSTBLOOD_ENABLED = true,
    FIRSTBLOOD_WINDOW = 180,
    FIRSTBLOOD_MAX_CLAIMS = 3,

    // Extra destruction tuning (CLARIFIED)
    //  - On DAMAGE chunk: destroy 10% of carried value (min 1) + spawn a 20% chunk.
    //  - On DEATH: destroy 20% of carried value (min 1) and ONLY drop up to 4 full 20% chunks.
    DAMAGE_DESTROY_FRAC_NUM = 1,
    DAMAGE_DESTROY_FRAC_DEN = 10, // 10% (min 1) destroyed on damage-chunk
    DEATH_DESTROY_FRAC_NUM  = 1,
    DEATH_DESTROY_FRAC_DEN  = 5,  // 20% (min 1) destroyed on death
    DEATH_MAX_CHUNKS = 4,

    // Bodygroup index for meter fill

    METER_BODYGROUP_INDEX = 1,

    // Prop parenting
    ATTACHMENT_NAME = 'partyhat',
    DROP_PARENT_TO_LMM_TARGET = true,

    // Class economy gates for spawner touch
    //  - budget: flags per life
    //  - rate: min seconds between dispenses
    //  - bonus: baseline value added to each spawned flag (starter economy)
    CLASS_SETTINGS = {
        [1] = { budget = 2,  rate = 0.50, bonus = 2 },  // Scout
        [2] = { budget = 8,  rate = 0.50, bonus = 8 },  // Sniper
        [3] = { budget = 4,  rate = 0.50, bonus = 4 },  // Soldier
        [4] = { budget = 3,  rate = 0.60, bonus = 3 },  // Demoman
        [5] = { budget = 7,  rate = 0.60, bonus = 7 },  // Medic
        [6] = { budget = 10, rate = 0.80, bonus = 10 }, // Heavy
        [7] = { budget = 5,  rate = 0.55, bonus = 5 },  // Pyro
        [8] = { budget = 1,  rate = 0.70, bonus = 1 },  // Spy
        [9] = { budget = 6,  rate = 0.60, bonus = 6 }   // Engineer
    },
    DEFAULT_CLASS_SETTING = { budget = 3, rate = 0.60, bonus = 3 },
    // Glow policy
    TOPK_GLOWS = 5,
    FORCE_GLOW_EVENT_TIME = 1.25, // seconds

    // Chunk / piñata
    CHUNK_BURST_COUNT = 5,
    CHUNK_FRACTION_NUM = 1,
    CHUNK_FRACTION_DEN = 5,
    CHUNK_NO_PICKUP_TIME = 0.50,
    CHUNK_SPEED_H = 320.0,
    CHUNK_SPEED_U = 360.0,

    // Damage chunk
    DMG_CHUNKS_ENABLED = true,
    DMG_THRESHOLD_HP_FRAC = 0.125,  // 12.5% max hp
    DMG_CHUNK_COOLDOWN = 0.75,

    // Think / retries
    THINK_DT = 0.35,
    RETRY_COUNT = 3,
    RETRY_DT = 0.12

    // Debug intentionally stripped (constant-table safe release build)
};

// ---------------------------------------------------------------------------
// STATE
// ---------------------------------------------------------------------------
flagspawn.State <- {
    InitDone = false,    // Budget pool (team bonus) split into shares (one prop each).
    // Shares are always clamped 0..100; total is clamped to POOL_HARDCAP.
    PoolShares = {
        [flagspawn.CFG.TEAM_BLU] = [0,0,0,0,0],
        [flagspawn.CFG.TEAM_RED] = [0,0,0,0,0]
    },

    // Per-player (SteamID3) spawner limits / timing + carry ledger
    Player = {},

    // Spawned packages by suffix (e.g. '0004')
    Pkgs = {},

    // Spawn context queues by team (ForceSpawn -> OnEntitySpawned correlation)
    SpawnCtxQ = {
        [flagspawn.CFG.TEAM_BLU] = [],
        [flagspawn.CFG.TEAM_RED] = []
    },

   // Pending stock spawns (prevents race: touch-spam before maker callback)
    PendingStock = {
        [flagspawn.CFG.TEAM_BLU] = 0,
        [flagspawn.CFG.TEAM_RED] = 0
    },

   // Retry queue (closures)
    RetryQ = [],

    // Forced glow windows keyed by entindex (flag or player)
    ForceGlowUntil = {},

    // TopK cache refresh
    NextTopKAt = 0.0,

    // First-blood timer (independent of PD round timer)
    RoundStartAt = 0.0,
    FirstBloodClaims = {
        [flagspawn.CFG.TEAM_BLU] = 0,
        [flagspawn.CFG.TEAM_RED] = 0
    }
};

// ---------------------------------------------------------------------------
// DEBUG
// ---------------------------------------------------------------------------
function _Dbg(_msg) {}
function _DbgSpawner(_msg) {}
function _DbgEcon(_msg) {}
function _DbgGlow(_msg) {}
function _DbgChunks(_msg) {}

function _Now() { return Time(); }

// ---------------------------------------------------------------------------
// SAFE HELPERS (NO GetAbsOrigin on players)
// ---------------------------------------------------------------------------
function _IsValid(ent) { try { return (ent != null && ent.IsValid()); } catch(_e) { return false; } }
function _IsPlayer(ent) { if (!_IsValid(ent)) return false; try { return ent.IsPlayer(); } catch(_e) { return false; } }

function _FindByName(name) {
    if (name == null || name == '') return null;
    try { return Entities.FindByName(null, name); } catch(_e) { return null; }
}

function _GetName(ent) { if (!_IsValid(ent)) return ''; try { return ent.GetName(); } catch(_e) { return ''; } }

function _GetOrigin(ent) {
    if (!_IsValid(ent)) return Vector(0,0,0);
    try { return ent.GetOrigin(); } catch(_e) {}
    try { return NetProps.GetPropVector(ent, 'm_vecOrigin'); } catch(_e2) {}
    return Vector(0,0,0);
}

function _SetOrigin(ent, v) {
    if (!_IsValid(ent) || v == null) return;
    try { ent.SetAbsOrigin(v); return; } catch(_e) {}
    try { ent.SetOrigin(v); } catch(_e2) {}
}

function _SetVelocity(ent, v) {
    if (!_IsValid(ent) || v == null) return;
    try { ent.SetAbsVelocity(v); return; } catch(_e) {}
    try { NetProps.SetPropVector(ent, 'm_vecAbsVelocity', v); } catch(_e2) {}
}

function _ClampInt(v, lo, hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

function _EntIndexSafe(ent) { try { return _IsValid(ent) ? ent.entindex() : -1; } catch(_e) { return -1; } }

function _GetSteamID3(p) {
    if (!_IsPlayer(p)) return null;
    try {
        local sid = NetProps.GetPropString(p, 'm_szNetworkIDString');
        if (sid && sid != '') return sid;
    } catch(_e) {}
    try {
        local sid3 = NetProps.GetPropString(p, 'm_szNetworkID3');
        if (sid3 && sid3 != '') return sid3;
    } catch(_e2) {}
    try { return 'ent#' + p.entindex(); } catch(_e3) { return null; }
}

function _FindPlayerByKey(key) {
    if (key == null) return null;
    local p = null;
    while (null != (p = Entities.FindByClassname(p, 'player'))) {
        if (_IsPlayer(p) && _GetSteamID3(p) == key) return p;
    }
    return null;
}

function _GetTeamSafe(p) {
    if (!_IsPlayer(p)) return 0;
    try { return NetProps.GetPropInt(p, 'm_iTeamNum'); } catch(_e) {}
    try { return p.GetTeam(); } catch(_e2) {}
    return 0;
}

function _GetPlayerClass(p) {
    if (!_IsPlayer(p)) return 0;
    try { return NetProps.GetPropInt(p, 'm_iClass'); } catch(_e) {}
    try { return p.GetPlayerClass(); } catch(_e2) {}
    return 0;
}

function _GetSpawnTime(p) {
    if (!_IsPlayer(p)) return 0.0;
    try { return NetProps.GetPropFloat(p, 'm_flSpawnTime'); } catch(_e) {}
    return 0.0;
}

function _GetMaxHealthSafe(p) {
    if (!_IsPlayer(p)) return 0;
    try { return NetProps.GetPropInt(p, 'm_iMaxHealth'); } catch(_e) {}
    try { return p.GetMaxHealth(); } catch(_e2) {}
    return 0;
}

function _GetPlayerFromUserIDSafe(uid) {
    // Prefer engine helper if present
    try {
        if ('GetPlayerFromUserID' in _rt) {
            local p = _rt.GetPlayerFromUserID(uid);
            if (_IsPlayer(p)) return p;
        }
    } catch(_e) {}

    // Fallback: scan all players and match m_iUserID
    local p = null;
    while (null != (p = Entities.FindByClassname(p, 'player'))) {
        if (!_IsPlayer(p)) continue;
        try {
            if (NetProps.GetPropInt(p, 'm_iUserID') == uid) return p;
        } catch(_e2) {}
    }
    return null;
}

// ---------------------------------------------------------------------------
// WORLD TEXT (point_worldtext has NO SetMessage input)
// ---------------------------------------------------------------------------
function _WorldTextSet(name, msg) {
    local wt = _FindByName(name);
    if (!_IsValid(wt)) return;
    try { wt.AddOutput('message ' + msg); } catch(_e) {}
}

// ---------------------------------------------------------------------------
// BUDGET POOL DISPLAY (spawner props)
// ---------------------------------------------------------------------------
function _GetSpawnerPropName(prefix, idx, count) {
    if (count <= 1) return prefix;

    // Prefer 2-digit suffix: prefix01..prefix05
    local s = idx.tostring();
    if (idx < 10) s = '0' + s;
    return prefix + s;
}

function _SetPropBodygroupSafe(prop, val01_100) {
    if (!_IsValid(prop)) return;
    val01_100 = _ClampInt(val01_100, 0, 100);
    try { prop.SetBodygroup(flagspawn.CFG.METER_BODYGROUP_INDEX, val01_100); } catch(_e) {}
}

function _PoolEnsure(team) {
    if (!(team in flagspawn.State.PoolShares)) return null;
    local arr = flagspawn.State.PoolShares[team];
    if (typeof arr != "array") {
        arr = [];
        flagspawn.State.PoolShares[team] = arr;
    }

    local n = flagspawn.CFG.POOL_SHARES;
    if (n == null || n < 1) n = 1;

    while (arr.len() < n) arr.append(0);
    while (arr.len() > n) arr.pop();

    // clamp 0..100
    for (local i = 0; i < arr.len(); i++) {
        if (arr[i] == null) arr[i] = 0;
        if (arr[i] < 0) arr[i] = 0;
        if (arr[i] > 100) arr[i] = 100;
    }

    // enforce total cap
    local cap = flagspawn.CFG.POOL_HARDCAP;
    if (cap != null && cap >= 0) {
        local total = _PoolTotal(team);
        if (total > cap) _PoolTrimToCap(team, cap);
    }

    return arr;
}

function _PoolTotal(team) {
    if (!(team in flagspawn.State.PoolShares)) return 0;
    local arr = flagspawn.State.PoolShares[team];
    if (typeof arr != "array") return 0;
    local t = 0;
    for (local i = 0; i < arr.len(); i++) t += arr[i];
    return t;
}

function _PoolTrimToCap(team, cap) {
    if (!(team in flagspawn.State.PoolShares)) return;
    local arr = flagspawn.State.PoolShares[team];
    if (typeof arr != "array") return;

    local total = _PoolTotal(team);
    if (total <= cap) return;
    local over = total - cap;

    // Remove from the largest shares first.
    while (over > 0) {
        local best = -1;
        local bestV = 0;
        for (local i = 0; i < arr.len(); i++) {
            if (arr[i] > bestV) { bestV = arr[i]; best = i; }
        }
        if (best < 0 || bestV <= 0) break;
        local take = over;
        if (take > bestV) take = bestV;
        arr[best] -= take;
        over -= take;
    }
}

function _PoolAddDelta(team, delta) {
    local arr = _PoolEnsure(team);
    if (arr == null) return;

    local cap = flagspawn.CFG.POOL_HARDCAP;
    if (cap == null || cap < 0) cap = 999999;

    if (delta > 0) {
        // Water-fill: always increment the LOWEST share (keeps shares even and fills empties first)
        for (local k = 0; k < delta; k++) {
            if (_PoolTotal(team) >= cap) break;

            local best = -1;
            local bestV = 999;
            for (local i = 0; i < arr.len(); i++) {
                if (arr[i] >= 100) continue;
                if (arr[i] < bestV) { bestV = arr[i]; best = i; }
            }
            if (best < 0) break;
            arr[best] += 1;
        }
        return;
    }

    if (delta < 0) {
        local need = -delta;
        // Remove from the HIGHEST shares first.
        for (local k = 0; k < need; k++) {
            if (_PoolTotal(team) <= 0) break;

            local best = -1;
            local bestV = 0;
            for (local i = 0; i < arr.len(); i++) {
                if (arr[i] > bestV) { bestV = arr[i]; best = i; }
            }
            if (best < 0 || bestV <= 0) break;
            arr[best] -= 1;
        }
    }
}

function _PoolPickBestShare(team) {
    local arr = _PoolEnsure(team);
    if (arr == null) return -1;
    local best = -1;
    local bestV = 0;
    for (local i = 0; i < arr.len(); i++) {
        if (arr[i] > bestV) { bestV = arr[i]; best = i; }
    }
    if (bestV <= 0) return -1;
    return best;
}

function _UpdateBudgetMeters(team) {
    local arr = _PoolEnsure(team);
    if (arr == null) return;

    local count = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.SPAWNER_PROP_BLU_COUNT : flagspawn.CFG.SPAWNER_PROP_RED_COUNT;
    local prefix = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.SPAWNER_PROP_BLU_PREFIX : flagspawn.CFG.SPAWNER_PROP_RED_PREFIX;

    if (count == null || count <= 0) return;

    if (count == 1) {
        // Single prop: show TOTAL (clamped 0..100)
        local p = _FindByName(prefix);
        if (_IsValid(p)) _SetPropBodygroupSafe(p, _ClampInt(_PoolTotal(team), 0, 100));
        return;
    }

    // Split display: each prop shows a share value (0..100)
    for (local i = 1; i <= count; i++) {
        local v = 0;
        if (i <= arr.len()) v = arr[i-1];
        local nm = _GetSpawnerPropName(prefix, i, count);
        local p = _FindByName(nm);
        if (_IsValid(p)) _SetPropBodygroupSafe(p, v);
    }
}

function _ModifyBudget(team, delta, why) {
    _PoolAddDelta(team, delta);
    _UpdateBudgetMeters(team);
    // Debug intentionally stripped (constant-table safe release build)
}

// ---------------------------------------------------------------------------
// STOCK (slots remaining) DISPLAY
// ---------------------------------------------------------------------------
function _PkgCountTeam(team) {
    local n = 0;
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!('team' in pkg) || pkg.team != team) continue;
        if ('flag' in pkg && _IsValid(pkg.flag)) n++;
    }
    return n;
}

function _SlotsRemaining(team) {
    local active = _PkgCountTeam(team);
    local pending = 0;
    if (team in flagspawn.State.PendingStock) pending = flagspawn.State.PendingStock[team];

    local rem = flagspawn.CFG.LIMIT_ACTIVE_FLAGS - (active + pending);
    if (rem < 0) rem = 0;
    return rem;
}

function _UpdateStockUI(team) {
    local rem = _SlotsRemaining(team);
    local textName = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.STOCK_TEXT_BLU : flagspawn.CFG.STOCK_TEXT_RED;
    if (textName != null && textName != '') _WorldTextSet(textName, rem);

    local lockName = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.LOCK_SPRITE_BLU : flagspawn.CFG.LOCK_SPRITE_RED;
    if (lockName != null && lockName != '') {
        if (rem <= 0) EntFire(lockName, 'ShowSprite', '', 0.0, null);
        else EntFire(lockName, 'HideSprite', '', 0.0, null);
    }
}

// ---------------------------------------------------------------------------
// PLAYER STATE (spawn reset + class-change reset) + CARRY LEDGER
// ---------------------------------------------------------------------------
function _GetClassSetting(c) {
    if (c in flagspawn.CFG.CLASS_SETTINGS) return flagspawn.CFG.CLASS_SETTINGS[c];
    return flagspawn.CFG.DEFAULT_CLASS_SETTING;
}

function _EnsurePlayer(p) {
    local k = _GetSteamID3(p);
    if (k == null) return null;

    if (!(k in flagspawn.State.Player)) {
        flagspawn.State.Player[k] <- {
            lastClass = 0,
            lastSpawnTime = 0.0,
            used = {
                [flagspawn.CFG.TEAM_BLU] = 0,
                [flagspawn.CFG.TEAM_RED] = 0
            },
            nextDispense = {
                [flagspawn.CFG.TEAM_BLU] = 0.0,
                [flagspawn.CFG.TEAM_RED] = 0.0
            },
            // Carry ledger (authoritative for our chunk logic)
            carry = {
                [flagspawn.CFG.TEAM_BLU] = 0,
                [flagspawn.CFG.TEAM_RED] = 0
            },
            lastDamageChunkAt = 0.0,

            // First-blood bonus per life (per team)
            firstBloodUsed = {
                [flagspawn.CFG.TEAM_BLU] = false,
                [flagspawn.CFG.TEAM_RED] = false
            }
        };
    }

    local st = flagspawn.State.Player[k];
    local c = _GetPlayerClass(p);
    local sp = _GetSpawnTime(p);

    if (st.lastClass != 0 && c != 0 && st.lastClass != c) {
        _ResetPlayer(p, 'class change');
    } else if (st.lastSpawnTime != 0.0 && sp != 0.0 && st.lastSpawnTime != sp) {
        _ResetPlayer(p, 'respawn');
    }

    st.lastClass = c;
    st.lastSpawnTime = sp;
    return st;
}

function _ResetPlayer(p, why) {
    local k = _GetSteamID3(p);
    if (k == null) return;
    if (!(k in flagspawn.State.Player)) return;

    local st = flagspawn.State.Player[k];
    st.used[flagspawn.CFG.TEAM_BLU] = 0;
    st.used[flagspawn.CFG.TEAM_RED] = 0;
    st.nextDispense[flagspawn.CFG.TEAM_BLU] = _Now();
    st.nextDispense[flagspawn.CFG.TEAM_RED] = _Now();
    st.carry[flagspawn.CFG.TEAM_BLU] = 0;
    st.carry[flagspawn.CFG.TEAM_RED] = 0;
    st.lastDamageChunkAt = 0.0;
    st.firstBloodUsed[flagspawn.CFG.TEAM_BLU] = false;
    st.firstBloodUsed[flagspawn.CFG.TEAM_RED] = false;

    // _Dbg('Reset player limits ' + k + ' (' + why + ')');
}

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
    local st = _EnsurePlayer(p);
    if (st == null) return;
    local v = st.carry[team] + delta;
    if (v < 0) v = 0;
    st.carry[team] = v;
    // if (flagspawn.CFG.DBG_CHUNKS) _DbgChunks('Carry ' + _GetSteamID3(p) + ' team=' + team + ' now=' + v + ' (' + why + ')');
}

function _CarryClear(p, why) {
    if (!_IsPlayer(p)) return;
    local st = _EnsurePlayer(p);
    if (st == null) return;
    st.carry[flagspawn.CFG.TEAM_BLU] = 0;
    st.carry[flagspawn.CFG.TEAM_RED] = 0;
    st.lastDamageChunkAt = 0.0;
    // if (flagspawn.CFG.DBG_CHUNKS) _DbgChunks('CarryClear ' + _GetSteamID3(p) + ' (' + why + ')');
}

// ---------------------------------------------------------------------------
// FIRST BLOOD (early-round capture bonus)
// ---------------------------------------------------------------------------
function _FirstBloodTimeRemaining() {
    if (!flagspawn.CFG.FIRSTBLOOD_ENABLED) return 0;
    local win = flagspawn.CFG.FIRSTBLOOD_WINDOW;
    if (win == null || win <= 0) return 0;
    local start = flagspawn.State.RoundStartAt;
    if (start == null || start <= 0) return 0;
    local elapsed = _Now() - start;
    local rem = win - elapsed;
    if (rem <= 0) return 0;
    local r = rem.tointeger();
    if (r < 1) r = 1;
    if (r > win) r = win;
    return r;
}

function _TryFirstBloodAward(p, team) {
    if (!_IsPlayer(p)) return 0;
    if (!flagspawn.CFG.FIRSTBLOOD_ENABLED) return 0;
    if (!(team == flagspawn.CFG.TEAM_BLU || team == flagspawn.CFG.TEAM_RED)) return 0;

    local rem = _FirstBloodTimeRemaining();
    if (rem <= 0) return 0;

    if (!('FirstBloodClaims' in flagspawn.State) || !(team in flagspawn.State.FirstBloodClaims)) return 0;
    local maxc = flagspawn.CFG.FIRSTBLOOD_MAX_CLAIMS;
    if (maxc == null || maxc < 1) maxc = 3;
    if (flagspawn.State.FirstBloodClaims[team] >= maxc) return 0;

    local st = _EnsurePlayer(p);
    if (st == null) return 0;
    if (st.firstBloodUsed[team]) return 0;

    st.firstBloodUsed[team] = true;
    flagspawn.State.FirstBloodClaims[team] = flagspawn.State.FirstBloodClaims[team] + 1;
    // if (flagspawn.CFG.DBG_ECON) _DbgEcon('FIRSTBLOOD team=' + team + ' rem=' + rem + ' by=' + _GetSteamID3(p) + ' claim#=' + flagspawn.State.FirstBloodClaims[team]);
    return rem;
}

// ---------------------------------------------------------------------------
// CONDITIONS GATE (bonk / deadringer / stealth placeholders)
// ---------------------------------------------------------------------------
function _HasCond(p, condId) {
    if (!_IsPlayer(p)) return false;
    try { return p.InCond(condId); } catch(_e) {}
    return false;
}

function _PlayerCannotPickupFlags(p) {
    if (!_IsPlayer(p)) return true;

    // NOTE: These are placeholder IDs (same as your previous versions).
    local BONK = ('TF_COND_BONKED' in _rt) ? _rt.TF_COND_BONKED : 14;
    local FEIGN = ('TF_COND_FEIGN_DEATH' in _rt) ? _rt.TF_COND_FEIGN_DEATH : 4;
    local STEALTH = ('TF_COND_STEALTHED' in _rt) ? _rt.TF_COND_STEALTHED : 1;

    if (_HasCond(p, BONK)) return true;
    if (_HasCond(p, FEIGN)) return true;
    if (_HasCond(p, STEALTH)) return true;

    // TODO: Rocket/Sticky Jumper and other edge cases (weapon checks)
    return false;
}

// ---------------------------------------------------------------------------
// SPAWN CONTEXT QUEUE
// ---------------------------------------------------------------------------
function _CtxQ_Push(team, ctx) {
    if (!(team in flagspawn.State.SpawnCtxQ)) return;
    flagspawn.State.SpawnCtxQ[team].append(ctx);

    // Pending stock: count ONLY normal spawns (chunks do not consume stock)
    local isChunk = (ctx != null && ('isChunk' in ctx) && ctx.isChunk) ? true : false;
    if (!isChunk) {
        if (team in flagspawn.State.PendingStock) {
            flagspawn.State.PendingStock[team] = flagspawn.State.PendingStock[team] + 1;
        }
    }
}

function _CtxQ_Pop(team) {
    if (!(team in flagspawn.State.SpawnCtxQ)) return null;
    local q = flagspawn.State.SpawnCtxQ[team];
    if (q.len() <= 0) return null;
    local ctx = q[0];
    q.remove(0);

    // Pending stock: decrement ONLY for normal spawns
    local isChunk = (ctx != null && ('isChunk' in ctx) && ctx.isChunk) ? true : false;
    if (!isChunk) {
        if (team in flagspawn.State.PendingStock) {
            flagspawn.State.PendingStock[team] = flagspawn.State.PendingStock[team] - 1;
            if (flagspawn.State.PendingStock[team] < 0) flagspawn.State.PendingStock[team] = 0;
        }
    }

    return ctx;
}

// Remove stuck contexts if maker never fires (prevents PendingStock from freezing)
function _CtxQ_Prune(team, maxAge) {
    if (!(team in flagspawn.State.SpawnCtxQ)) return;
    local q = flagspawn.State.SpawnCtxQ[team];
    local now = _Now();

    for (local i = q.len() - 1; i >= 0; i--) {
        local ctx = q[i];
        if (ctx == null) { q.remove(i); continue; }
        if (!('t' in ctx)) continue;
        if ((now - ctx.t) <= maxAge) continue;

        // stale -> drop
        local isChunk = ('isChunk' in ctx && ctx.isChunk) ? true : false;
        if (!isChunk && (team in flagspawn.State.PendingStock)) {
            flagspawn.State.PendingStock[team] = flagspawn.State.PendingStock[team] - 1;
            if (flagspawn.State.PendingStock[team] < 0) flagspawn.State.PendingStock[team] = 0;
        }
        q.remove(i);
    }
}

// ---------------------------------------------------------------------------
// FLAG POINT VALUE + BODYGROUP SYNC
// ---------------------------------------------------------------------------
function _ReadFlagPointsSafe(flag) {
    if (!_IsValid(flag)) return 0;
    local pv = 0;
    try { pv = NetProps.GetPropInt(flag, 'm_nPointValue'); } catch(_e) { pv = 0; }
    if (pv == null || pv < 0) pv = 0;
    return pv;
}

function _ApplyFlagPointValue(flag, pv) {
    if (!_IsValid(flag)) return;
    pv = _ClampInt(pv, 0, 999);
    try { NetProps.SetPropInt(flag, 'm_nPointValue', pv); } catch(_e) {}
    try { EntFireByHandle(flag, 'SetPointValue', '' + pv, 0.0, null, null); } catch(_e2) {}
}

function _ApplyMeterBodygroups(pkg, pv) {
    // Only our 0-100 fill visual; clamp
    local bg = _ClampInt(pv, 0, 100);

    if ('flag' in pkg && _IsValid(pkg.flag)) {
        try { pkg.flag.SetBodygroup(flagspawn.CFG.METER_BODYGROUP_INDEX, bg); } catch(_e) {}
    }
    if ('prop' in pkg && _IsValid(pkg.prop)) {
        try { pkg.prop.SetBodygroup(flagspawn.CFG.METER_BODYGROUP_INDEX, bg); } catch(_e2) {}
    }
}

// ---------------------------------------------------------------------------
// GLOW CONTROL (retarget by netprop handle)
// ---------------------------------------------------------------------------
function _GlowSetTarget(glow, target) {
    if (!_IsValid(glow) || !_IsValid(target)) return;
    try { NetProps.SetPropEntity(glow, 'm_hTarget', target); } catch(_e) {}
}

function _GlowEnable(glow, en) {
    if (!_IsValid(glow)) return;
    try {
        if (en) EntFireByHandle(glow, 'Enable', '', 0.0, null, null);
        else EntFireByHandle(glow, 'Disable', '', 0.0, null, null);
    } catch(_e) {}
}

function _ForceGlow(ent, secs) {
    if (!_IsValid(ent)) return;
    local idx = _EntIndexSafe(ent);
    if (idx < 0) return;
    flagspawn.State.ForceGlowUntil[idx] <- _Now() + secs;
}

function _IsForceGlow(ent) {
    if (!_IsValid(ent)) return false;
    local idx = _EntIndexSafe(ent);
    if (idx < 0) return false;
    if (!(idx in flagspawn.State.ForceGlowUntil)) return false;
    return (_Now() <= flagspawn.State.ForceGlowUntil[idx]);
}

// ---------------------------------------------------------------------------
// PACKAGE VISUAL STATE
// ---------------------------------------------------------------------------
function _SetParentSafe(child, parent) {
    if (!_IsValid(child)) return;
    if (!_IsValid(parent)) {
        try { child.SetParent(null, ''); } catch(_e0) {}
        return;
    }
    try { child.SetParent(parent, ''); } catch(_e) {}
}

function _SetParentAttachmentSafe(child, parent, attachment) {
    if (!_IsValid(child) || !_IsValid(parent)) return;
    try {
        child.SetParent(parent, '');
        child.SetParentAttachmentMaintainOffset(attachment);
        return;
    } catch(_e) {}
    try {
        child.SetParent(parent, '');
        child.SetParentAttachment(attachment);
    } catch(_e2) {}
}

function _FlagDraw(flag, enable) {
    if (!_IsValid(flag)) return;
    try {
        if (enable) EntFireByHandle(flag, 'EnableDraw', '', 0.0, null, null);
        else EntFireByHandle(flag, 'DisableDraw', '', 0.0, null, null);
    } catch(_e) {}
}

function _LockEnable(pkg, enable) {
    if (!('lock' in pkg) || !_IsValid(pkg.lock)) return;
    try {
        if (enable) EntFireByHandle(pkg.lock, 'Enable', '', 0.0, null, null);
        else EntFireByHandle(pkg.lock, 'Disable', '', 0.0, null, null);
    } catch(_e) {}
}

function _ApplyPkgState(pkg, why) {
    // pkg.state: 'dropped' or 'carried'
    if (!('state' in pkg)) return;

    local st = pkg.state;
    local pv = ('pointValue' in pkg) ? pkg.pointValue : _ReadFlagPointsSafe(pkg.flag);

    // Always keep bodygroups in sync
    _ApplyMeterBodygroups(pkg, pv);

    if (st == 'dropped') {
        // Dropped: flag visible, prop follows lmm_target (optional), glow targets flag
        if ('flag' in pkg) _FlagDraw(pkg.flag, true);
        _LockEnable(pkg, true);

        if (flagspawn.CFG.DROP_PARENT_TO_LMM_TARGET && 'prop' in pkg && _IsValid(pkg.prop)) {
            if ('lmm_target' in pkg && _IsValid(pkg.lmm_target)) _SetParentSafe(pkg.prop, pkg.lmm_target);
        }

        if ('glow' in pkg && _IsValid(pkg.glow) && 'flag' in pkg && _IsValid(pkg.flag)) {
            _GlowSetTarget(pkg.glow, pkg.flag);
            _GlowEnable(pkg.glow, true);
        }
    } else {
        // Carried: flag hidden (PD usually does this anyway), lock disabled,
        // prop attaches to player head, glow targets player.
        if ('flag' in pkg) _FlagDraw(pkg.flag, false);
        _LockEnable(pkg, false);

        if ('prop' in pkg && _IsValid(pkg.prop) && 'carrier' in pkg && _IsPlayer(pkg.carrier)) {
            _SetParentAttachmentSafe(pkg.prop, pkg.carrier, flagspawn.CFG.ATTACHMENT_NAME);
        }

        if ('glow' in pkg && _IsValid(pkg.glow)) {
            local tgt = null;
            if ('carrier' in pkg && _IsPlayer(pkg.carrier)) tgt = pkg.carrier;
            else if ('flag' in pkg && _IsValid(pkg.flag)) tgt = pkg.flag;
            if (_IsValid(tgt)) {
                _GlowSetTarget(pkg.glow, tgt);
                _GlowEnable(pkg.glow, true);
            }
        }
    }

    // Optional: force glow briefly on state transitions
    if ('glow' in pkg && _IsValid(pkg.glow)) {
        if ('flag' in pkg && _IsValid(pkg.flag)) _ForceGlow(pkg.flag, flagspawn.CFG.FORCE_GLOW_EVENT_TIME);
        if ('carrier' in pkg && _IsPlayer(pkg.carrier)) _ForceGlow(pkg.carrier, flagspawn.CFG.FORCE_GLOW_EVENT_TIME);
    }

    // if (flagspawn.CFG.DBG_GLOW) _DbgGlow('ApplyState ' + st + ' pv=' + pv + ' (' + why + ')');
}

function _RetryPkgState(suf, why) {
    // Event-driven retries for state changes
    for (local i = 0; i < flagspawn.CFG.RETRY_COUNT; i++) {
        local delay = i * flagspawn.CFG.RETRY_DT;
        flagspawn.State.RetryQ.append({
            t = _Now() + delay,
            f = function() {
                if (!(suf in flagspawn.State.Pkgs)) return;
                local pkg = flagspawn.State.Pkgs[suf];
                if (!('flag' in pkg) || !_IsValid(pkg.flag)) return;
                _ApplyPkgState(pkg, why + ' retry#' + i);
            }
        });
    }
}

// ---------------------------------------------------------------------------
// TOPK GLOW MAINTENANCE
// ---------------------------------------------------------------------------
function _RefreshTopK() {
    local now = _Now();
    if (now < flagspawn.State.NextTopKAt) return;
    flagspawn.State.NextTopKAt = now + 1.0;

    foreach (team in [flagspawn.CFG.TEAM_BLU, flagspawn.CFG.TEAM_RED]) {
        local arr = [];
        foreach (suf, pkg in flagspawn.State.Pkgs) {
            if (!('team' in pkg) || pkg.team != team) continue;
            if (!('flag' in pkg) || !_IsValid(pkg.flag)) continue;
            local pv = ('pointValue' in pkg) ? pkg.pointValue : _ReadFlagPointsSafe(pkg.flag);
            arr.append({ s = suf, v = pv });
        }
        arr.sort(function(a,b){ return (b.v <=> a.v); });

        // Mark topK
        for (local i = 0; i < arr.len(); i++) {
            local suf = arr[i].s;
            if (!(suf in flagspawn.State.Pkgs)) continue;
            flagspawn.State.Pkgs[suf].topk <- (i < flagspawn.CFG.TOPK_GLOWS);
        }
    }
}

function _ApplyGlowPolicy() {
    // Enable glows for: TopK OR forced-glow window. Disable otherwise.
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!('glow' in pkg) || !_IsValid(pkg.glow)) continue;

        local keep = false;
        if ('topk' in pkg && pkg.topk) keep = true;
        if (!keep) {
            if ('flag' in pkg && _IsValid(pkg.flag) && _IsForceGlow(pkg.flag)) keep = true;
            if ('carrier' in pkg && _IsPlayer(pkg.carrier) && _IsForceGlow(pkg.carrier)) keep = true;
        }

        if (!keep) {
            _GlowEnable(pkg.glow, false);
            continue;
        }

        // Ensure target matches current state
        if ('state' in pkg && pkg.state == 'carried' && 'carrier' in pkg && _IsPlayer(pkg.carrier)) {
            _GlowSetTarget(pkg.glow, pkg.carrier);
        } else if ('flag' in pkg && _IsValid(pkg.flag)) {
            _GlowSetTarget(pkg.glow, pkg.flag);
        }
        _GlowEnable(pkg.glow, true);
    }
}

// ---------------------------------------------------------------------------
// SPAWNER TOUCH (STOCK-gated, VALUE from budget)
// ---------------------------------------------------------------------------
function _ComputeSpawnValue(team, capLeft, classBonus) {
    // Spawn value = classBonus + floor(totalPool/POOL_SHARES).
    // Only the POOL portion is consumed from the pool. Class bonus does not.
    // This matches: pool=200 -> pool/5=40 bonus portion.

    if (classBonus == null) classBonus = 0;

    local maxV = flagspawn.CFG.VALUE_CAP;
    if (maxV == null || maxV < 1) maxV = 100;

    if (capLeft != null && capLeft < maxV) maxV = capLeft;
    if (maxV < 1) return 0;

    local total = _PoolTotal(team);
    local n = flagspawn.CFG.POOL_SHARES;
    if (n == null || n < 1) n = 1;

    local poolPortion = (total / n).tointeger();
    if (poolPortion < 0) poolPortion = 0;

    // If pool is empty, you still get classBonus (so meters can stay at 0).
    local desired = classBonus + poolPortion;

    // If both are zero, deny.
    if (desired <= 0) return 0;

    if (desired > maxV) desired = maxV;

    // Enforce minimum spawn value if anything is available.
    if (desired < flagspawn.CFG.SPAWN_MIN_VALUE) desired = flagspawn.CFG.SPAWN_MIN_VALUE;
    if (desired > maxV) desired = maxV;

    // Consume only the pool part we actually used.
    local bonusTake = desired - classBonus;
    if (bonusTake < 0) bonusTake = 0;
    if (bonusTake > 0) {
        _PoolAddDelta(team, -bonusTake);
    }

    _UpdateBudgetMeters(team);
    return desired;
}

function _SpawnerTouch(team) {
    if (!('activator' in this) || !_IsPlayer(activator)) return;
    local p = activator;

    // Gate: alive
    try { if (NetProps.GetPropInt(p, 'm_lifeState') != 0) return; } catch(_e) {}

    // Gate: stock (slots remaining)
    local rem = _SlotsRemaining(team);
    if (rem <= 0) {
        _UpdateStockUI(team);
        // _DbgSpawner('SpawnerTouch DENY (stock=0) team=' + team);
        return;
    }

    // Gate: pickup disallowed (bonk/deadringer/etc)
    if (_PlayerCannotPickupFlags(p)) {
        // _DbgSpawner('SpawnerTouch DENY (cannot pickup) ' + _GetSteamID3(p));
        return;
    }


    // Gate: carry cap (prevents one player from draining the whole pool)
    local st = _EnsurePlayer(p);
    local capLeft = flagspawn.CFG.CARRY_CAP; // default if we failed to track player
    if (st != null) {
        capLeft = flagspawn.CFG.CARRY_CAP - _CarryTotal(st);
        if (capLeft <= 0) {
            // _DbgSpawner('SpawnerTouch DENY (carrycap) carry=' + _CarryTotal(st) + '/' + flagspawn.CFG.CARRY_CAP);
            return;
        }
    }
    // Gate: class budget + rate
    local cs = _GetClassSetting(_GetPlayerClass(p));
    if (st != null) {

        if (st.used[team] >= cs.budget) {
            // _DbgSpawner('SpawnerTouch DENY (budget) used=' + st.used[team] + '/' + cs.budget);
            return;
        }

        local now = _Now();
        if (now < st.nextDispense[team]) return;
        st.nextDispense[team] = now + cs.rate;
        st.used[team] = st.used[team] + 1;
    }

    // Pick maker
    local makerName = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.MAKER_BLU : flagspawn.CFG.MAKER_RED;
    local maker = _FindByName(makerName);
    if (!_IsValid(maker)) {
        // _DbgSpawner('SpawnerTouch missing maker: ' + makerName);
        return;
    }

    // Compute point value from budget (NOT template default)
    local pv = _ComputeSpawnValue(team, capLeft, cs.bonus);

    if (pv <= 0) {
        // _DbgSpawner('SpawnerTouch DENY (pool empty / no debt) team=' + team);
        return;
    }

    // Context for FS_OnMakerSpawned
    _CtxQ_Push(team, {
        t = _Now(),
        playerKey = _GetSteamID3(p),
        pointValue = pv,
        isChunk = false
    });

    // Update stock UI immediately (pending spawn counted)
    _UpdateStockUI(team);

    EntFire(makerName, 'ForceSpawn', '', 0.0, p);
    // _DbgSpawner('SpawnerTouch team=' + team + ' pv=' + pv + ' key=' + _GetSteamID3(p) + ' budgetNow=' + _PoolTotal(team));
}

FS_OnSpawnerTouchBlu <- function() { _SpawnerTouch(flagspawn.CFG.TEAM_BLU); };
FS_OnSpawnerTouchRed <- function() { _SpawnerTouch(flagspawn.CFG.TEAM_RED); };

// ---------------------------------------------------------------------------
// MAKER SPAWN CALLBACK (OnEntitySpawned -> RunScriptCode FS_OnMakerSpawned())
// ---------------------------------------------------------------------------
function _ExtractSuffix(name) {
    if (name == null) return null;
    local idx = name.find('&');
    if (idx == null) return null;
    return name.slice(idx + 1);
}

function _PkgNames(team) {
    return (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.PACKAGE_BLU : flagspawn.CFG.PACKAGE_RED;
}

function _FindSuffixed(base, suf) {
    if (base == null || suf == null) return null;
    return _FindByName(base + '&' + suf);
}

FS_OnMakerSpawned <- function() {
    local maker = ('caller' in this) ? caller : null;
    if (!_IsValid(maker)) return;

    local makerName = _GetName(maker);
    local team = null;
    if (makerName == flagspawn.CFG.MAKER_BLU || makerName == flagspawn.CFG.MAKER_BLU_DYN) team = flagspawn.CFG.TEAM_BLU;
    else if (makerName == flagspawn.CFG.MAKER_RED || makerName == flagspawn.CFG.MAKER_RED_DYN) team = flagspawn.CFG.TEAM_RED;

    if (team == null) team = flagspawn.CFG.TEAM_BLU;

    // activator in OnEntitySpawned is the spawned entity (flag)
    local flag = null;
    if ('activator' in this && _IsValid(activator)) {
        try { if (activator.GetClassname() == 'item_teamflag') flag = activator; } catch(_e) {}
    }
    if (!_IsValid(flag)) {
        // _DbgSpawner('MakerSpawned: missing flag activator');
        return;
    }

    local name = _GetName(flag);
    local suf = _ExtractSuffix(name);
    if (suf == null) {
        // _DbgSpawner('MakerSpawned: no suffix on ' + name);
        return;
    }

    local names = _PkgNames(team);

    local pkg = {
        team = team,
        suffix = suf,
        flag = flag,
        prop = _FindSuffixed(names.prop, suf),
        lock = _FindSuffixed(names.lock, suf),
        glow = _FindSuffixed(names.glow, suf),
        lmm_target = _FindSuffixed(names.lmm_target, suf),
        lmm_ref    = _FindSuffixed(names.lmm_ref, suf),

        // runtime
        pointValue = _ReadFlagPointsSafe(flag),
        state = 'dropped',
        carrier = null,
        topk = false
    };

    // Apply context (spawn value + implied carry)
    local ctx = _CtxQ_Pop(team);
    if (ctx != null && ('t' in ctx) && (_Now() - ctx.t) > 1.0) ctx = null;

    if (ctx != null) {
        if ('pointValue' in ctx && ctx.pointValue != null) {
            pkg.pointValue = ctx.pointValue;
            _ApplyFlagPointValue(flag, pkg.pointValue);
        }

        // IMPORTANT: add to carry ledger here, because OnPickup may not fire
        // when the flag is spawned directly into the player.
        if ('playerKey' in ctx && ctx.playerKey != null) {
            local p = _FindPlayerByKey(ctx.playerKey);
            if (_IsPlayer(p)) {
                pkg.state = 'carried';
                pkg.carrier = p;
                _CarryAdd(p, team, pkg.pointValue, 'spawner dispense');
            }
        }

        if ('isChunk' in ctx && ctx.isChunk) {
            // chunk spawn starts dropped
            pkg.state = 'dropped';
            pkg.carrier = null;
        }
    }

    // Track
    flagspawn.State.Pkgs[suf] <- pkg;

    // Sync visuals immediately + retries
    _ApplyPkgState(pkg, 'maker spawn');
    _RetryPkgState(suf, 'maker spawn');

    // UI refresh
    _UpdateStockUI(team);

    // _DbgSpawner('Registered pkg ' + name + ' team=' + team + ' pv=' + pkg.pointValue + ' state=' + pkg.state);
};

// ---------------------------------------------------------------------------
// DIRECT FLAG OUTPUTS (caller = specific flag, activator = player)
// ---------------------------------------------------------------------------
FS_Direct_Pickup <- function() {
    local flag = ('caller' in this) ? caller : null;
    local p = ('activator' in this) ? activator : null;
    if (!_IsValid(flag) || !_IsPlayer(p)) return;

    local pv = _ReadFlagPointsSafe(flag);
    if (pv < 1) pv = 1;

    local suf = _ExtractSuffix(_GetName(flag));
    if (suf != null && (suf in flagspawn.State.Pkgs)) {
        local pkg = flagspawn.State.Pkgs[suf];
        pkg.state = 'carried';
        pkg.carrier = p;
        pkg.pointValue = pv;

        // Ledger add (this will also correctly handle merges via multiple pickups)
        _CarryAdd(p, pkg.team, pv, 'pickup');

        // Force-glow on event + retry visual state
        _ForceGlow(p, flagspawn.CFG.FORCE_GLOW_EVENT_TIME);
        _ForceGlow(flag, flagspawn.CFG.FORCE_GLOW_EVENT_TIME);
        _ApplyPkgState(pkg, 'direct pickup');
        _RetryPkgState(suf, 'direct pickup');
    } else {
        // Fallback if we missed registration
        local team = (_GetName(flag).find(flagspawn.CFG.PACKAGE_RED.flag) != null) ? flagspawn.CFG.TEAM_RED : flagspawn.CFG.TEAM_BLU;
        _CarryAdd(p, team, pv, 'pickup (untracked)');
    }
};

FS_Direct_Drop <- function() {
    local flag = ('caller' in this) ? caller : null;
    local p = ('activator' in this) ? activator : null;
    if (!_IsValid(flag)) return;

    local suf = _ExtractSuffix(_GetName(flag));
    if (suf != null && (suf in flagspawn.State.Pkgs)) {
        local pkg = flagspawn.State.Pkgs[suf];
        pkg.state = 'dropped';
        pkg.carrier = null;

        if (_IsPlayer(p)) {
            _ForceGlow(p, flagspawn.CFG.FORCE_GLOW_EVENT_TIME);
        }
        _ForceGlow(flag, flagspawn.CFG.FORCE_GLOW_EVENT_TIME);

        _ApplyPkgState(pkg, 'direct drop');
        _RetryPkgState(suf, 'direct drop');
    }
};

FS_Direct_Return <- function() {
    // Called on OnReturn (caller is the flag). Refund goes to the FLAG'S owning team pool.
    local flag = ('caller' in this) ? caller : null;
    local p = ('activator' in this) ? activator : null;
    if (!_IsValid(flag)) return;

    local pv = _ReadFlagPointsSafe(flag);
    if (pv < 1) pv = 1;

    local suf = _ExtractSuffix(_GetName(flag));
    local team = flagspawn.CFG.TEAM_BLU;

    if (suf != null && (suf in flagspawn.State.Pkgs)) {
        team = flagspawn.State.Pkgs[suf].team;
    } else {
        if (_GetName(flag).find(flagspawn.CFG.PACKAGE_RED.flag) != null) team = flagspawn.CFG.TEAM_RED;
    }

    _ModifyBudget(team, pv, 'return refund');

    // If a player was involved, clear their carry ledger (safe catch-all).
    if (_IsPlayer(p)) _CarryClear(p, 'return');

    try { flag.Kill(); } catch(_e) {}

    // _DbgEcon('ReturnRefund team=' + team + ' pv=' + pv + ' suf=' + (suf != null ? suf : 'none'));
};

FS_Direct_Capture <- function() {
    // Called on OnCapture (caller is the flag, activator is capturer).
    // Award goes to the CAPTURER TEAM pool: pv*CAPTURE_MULT + optional FirstBlood time bonus.
    local flag = ('caller' in this) ? caller : null;
    local p = ('activator' in this) ? activator : null;
    if (!_IsValid(flag)) return;

    local pv = _ReadFlagPointsSafe(flag);
    if (pv < 1) pv = 1;

    local capTeam = _IsPlayer(p) ? _GetTeamSafe(p) : 0;
    if (capTeam != flagspawn.CFG.TEAM_BLU && capTeam != flagspawn.CFG.TEAM_RED) {
        // Fallback: opposite of flag's owning team
        local suf = _ExtractSuffix(_GetName(flag));
        local owner = flagspawn.CFG.TEAM_BLU;
        if (suf != null && (suf in flagspawn.State.Pkgs)) owner = flagspawn.State.Pkgs[suf].team;
        else if (_GetName(flag).find(flagspawn.CFG.PACKAGE_RED.flag) != null) owner = flagspawn.CFG.TEAM_RED;
        capTeam = (owner == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.TEAM_RED : flagspawn.CFG.TEAM_BLU;
    }

    local mult = flagspawn.CFG.CAPTURE_MULT;
    if (mult == null || mult < 1) mult = 2;
    local base = pv * mult;

    local timeBonus = 0;
    if (_IsPlayer(p)) timeBonus = _TryFirstBloodAward(p, capTeam);

    local award = base + timeBonus;
    _ModifyBudget(capTeam, award, 'capture award');

    // Capture resets the capturer's spawner usage (one-per-life style loop)
    if (_IsPlayer(p)) {
        local st = _EnsurePlayer(p);
        if (st != null) {
            st.used[capTeam] = 0;
            st.nextDispense[capTeam] = _Now();
        }
        _CarryClear(p, 'capture');
    }

    try { flag.Kill(); } catch(_e) {}

    // _DbgEcon('CaptureAward capTeam=' + capTeam + ' pv=' + pv + ' base=' + base + ' time=' + timeBonus + ' -> award=' + award);
};

// Back-compat: if your VMF still calls FS_Direct_Refund, treat it as a RETURN refund (1x, owning team).
FS_Direct_Refund <- function() { FS_Direct_Return(); };

// ---------------------------------------------------------------------------
// CHUNK / PIÑATA
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// GLOBAL FLAG EVENT (teamplay_flag_event)
// ---------------------------------------------------------------------------
// NOTE: This event does NOT include a flag entindex/name, so do not try to do
// per-flag Return/Capture logic here. Keep this as an optional "pulse" only.
FS_OnFlagEvent <- function() {
    try { FS_Think(); } catch(_e) {}
};

function _CalcChunkValue(total) {
    // Base chunk = 20% of total (config fraction), MIN 1 when total>0.
    if (total <= 0) return 0;
    local v = ((total * flagspawn.CFG.CHUNK_FRACTION_NUM) / flagspawn.CFG.CHUNK_FRACTION_DEN).tointeger();
    if (v < 1) v = 1;
    if (v > total) v = total;
    return v;
}

function _MakeRadialVel(i, n, speedH, speedU) {
    local baseDeg = (360.0 / n) * i;
    local jitter = 18.0 * (RandomFloat(-1.0, 1.0));
    local ang = (baseDeg + jitter) * 0.01745329252;
    local vx = cos(ang) * speedH;
    local vy = sin(ang) * speedH;
    local vz = speedU + RandomFloat(-40.0, 40.0);
    return Vector(vx, vy, vz);
}

function _GetDynMaker(team) {
    local nm = (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.MAKER_BLU_DYN : flagspawn.CFG.MAKER_RED_DYN;
    local m = _FindByName(nm);
    if (_IsValid(m)) return nm;
    return (team == flagspawn.CFG.TEAM_BLU) ? flagspawn.CFG.MAKER_BLU : flagspawn.CFG.MAKER_RED;
}

function _SpawnChunk(team, origin, pv, vel) {
    if (pv <= 0) return;

    local makerName = _GetDynMaker(team);
    local maker = _FindByName(makerName);
    if (!_IsValid(maker)) {
        // _DbgChunks('WARN: no chunk maker: ' + makerName);
        return;
    }

    _SetOrigin(maker, origin + Vector(0,0,8));

    _CtxQ_Push(team, {
        t = _Now(),
        playerKey = null,
        pointValue = pv,
        isChunk = true
    });

    EntFire(makerName, 'ForceSpawn', '', 0.0, null);

    // The spawned flag becomes activator in FS_OnMakerSpawned; set its velocity there via retry? We can't here.
    // Instead, schedule a short retry to set velocity on the newest chunk package for this team.
    // (Good enough for now; your next iteration can add an explicit velocity handoff.)
}

function _DoDeathPinata(pVictim) {
    if (!_IsPlayer(pVictim)) return;

    local st = _EnsurePlayer(pVictim);
    if (st == null) return;

    local carryTotal0 = _CarryTotal(st);
    if (carryTotal0 <= 0) return;

    // Determine which TEAM's points this victim is carrying (best match).
    local teamCarry = _GetTeamSafe(pVictim);
    if (teamCarry != flagspawn.CFG.TEAM_BLU && teamCarry != flagspawn.CFG.TEAM_RED) {
        local tb = _CarryTeamBest(st);
        teamCarry = (tb != null) ? tb : flagspawn.CFG.TEAM_BLU;
    }

    // --------------------------------------------------------------
    // CLARIFIED: On DEATH, destroy 20% of carried value (min 1).
    // This is "to the grave" (removed from play/economy).
    // Then drop up to 4 full chunks of size floor(carryTotal0 * 20%).
    // Any leftover remainder is also destroyed.
    // Example: carry=10 -> destroy=2, remaining=8 -> drop 4x2.
    // --------------------------------------------------------------
    local num = flagspawn.CFG.DEATH_DESTROY_FRAC_NUM; if (num == null) num = 1;
    local den = flagspawn.CFG.DEATH_DESTROY_FRAC_DEN; if (den == null || den <= 0) den = 5;

    local destroy = ((carryTotal0 * num) / den).tointeger();
    if (destroy < 1) destroy = 1;
    if (destroy > carryTotal0) destroy = carryTotal0;

    local remaining = carryTotal0 - destroy;
    if (remaining <= 0) {
        // _DbgChunks("DeathPinata victim=" + _GetSteamID3(pVictim) + " carry0=" + carryTotal0 + " destroyed=" + destroy + " -> ALL DESTROYED");
        _CarryClear(pVictim, "death destroyed");
        return;
    }

    local chunkVal = _CalcChunkValue(carryTotal0); // 20% of ORIGINAL
    if (chunkVal < 1) chunkVal = 1;

    local maxChunks = flagspawn.CFG.DEATH_MAX_CHUNKS;
    if (maxChunks == null || maxChunks <= 0) maxChunks = 4;

    local n = (remaining / chunkVal).tointeger();
    if (n > maxChunks) n = maxChunks;
    if (n < 0) n = 0;

    local o = _GetOrigin(pVictim) + Vector(0,0,48);
    local dropped = 0;

    for (local i = 0; i < n; i++) {
        local vel = _MakeRadialVel(i, maxChunks, flagspawn.CFG.CHUNK_SPEED_H, flagspawn.CFG.CHUNK_SPEED_U);
        _SpawnChunk(teamCarry, o, chunkVal, vel);
        dropped += chunkVal;
    }

    local remainder = remaining - dropped;
    if (remainder < 0) remainder = 0;

    // Destroy remainder as well (more destruction, per your spec).
    local destroyedTotal = destroy + remainder;

    // _DbgChunks("DeathPinata victim=" + _GetSteamID3(pVictim)
    //     + " carry0=" + carryTotal0
    //     + " destroy20%=" + destroy
    //     + " chunk=" + chunkVal
    //     + " dropped=" + dropped
    //     + " remainderDestroyed=" + remainder
    //     + " destroyedTotal=" + destroyedTotal);

    _CarryClear(pVictim, "death pinata");
}

function _DoDamageChunk(pVictim, damageAmount) {
    if (!_IsPlayer(pVictim)) return;
    if (!flagspawn.CFG.DMG_CHUNKS_ENABLED) return;

    local st = _EnsurePlayer(pVictim);
    if (st == null) return;

    local carryTotal0 = _CarryTotal(st);
    if (carryTotal0 <= 0) return;

    local mh = _GetMaxHealthSafe(pVictim);
    if (mh <= 0) return;

    local thresh = mh.tofloat() * flagspawn.CFG.DMG_THRESHOLD_HP_FRAC;
    if (damageAmount.tofloat() < thresh) return;

    local now = _Now();
    if ((now - st.lastDamageChunkAt) < flagspawn.CFG.DMG_CHUNK_COOLDOWN) return;

    // If you only have 1 point, we refuse (we must not delete the whole flag on damage).
    if (carryTotal0 <= 1) return;

    // CLARIFIED: On DAMAGE chunk
    //  - destroy 10% of carried value (min 1)
    //  - spawn a 20% chunk (min 1)
    //  - ensure victim keeps at least 1 point
    // Example: carry=10 -> destroy=1, chunk=2 -> victim=7
    local dnum = flagspawn.CFG.DAMAGE_DESTROY_FRAC_NUM; if (dnum == null) dnum = 1;
    local dden = flagspawn.CFG.DAMAGE_DESTROY_FRAC_DEN; if (dden == null || dden <= 0) dden = 10;

    local destroy = ((carryTotal0 * dnum) / dden).tointeger();
    if (destroy < 1) destroy = 1;
    if (destroy >= carryTotal0) destroy = carryTotal0 - 1; // keep >=1

    local chunkVal = _CalcChunkValue(carryTotal0); // 20% of current/original
    if (chunkVal < 1) chunkVal = 1;

    // Ensure we don't reduce below 1 after (destroy + chunk)
    local maxChunk = carryTotal0 - 1 - destroy;
    if (maxChunk <= 0) return;
    if (chunkVal > maxChunk) chunkVal = maxChunk;
    if (chunkVal < 1) return;

    local teamCarry = _CarryTeamBest(st);
    if (teamCarry == null) {
        local t = _GetTeamSafe(pVictim);
        teamCarry = (t == flagspawn.CFG.TEAM_BLU || t == flagspawn.CFG.TEAM_RED) ? t : flagspawn.CFG.TEAM_BLU;
    }

    local o = _GetOrigin(pVictim) + Vector(0,0,48);
    local vel = _MakeRadialVel(RandomInt(0, 4), 5, flagspawn.CFG.CHUNK_SPEED_H * 0.85, flagspawn.CFG.CHUNK_SPEED_U * 0.75);
    _SpawnChunk(teamCarry, o, chunkVal, vel);

    // Victim loses BOTH the destroyed points and the spawned chunk.
    _CarryAdd(pVictim, teamCarry, -(destroy + chunkVal), "damage chunk");
    st.lastDamageChunkAt = now;

    // _DbgChunks("DamageChunk victim=" + _GetSteamID3(pVictim)
    //     + " dmg=" + damageAmount
    //     + " carry0=" + carryTotal0
    //     + " destroy10%=" + destroy
    //     + " spawnedChunk=" + chunkVal
    //     + " victimAfter=" + (carryTotal0 - destroy - chunkVal));
}

// ---------------------------------------------------------------------------
// EVENT HANDLERS (logic_eventlistener -> CallScriptFunction)
// ---------------------------------------------------------------------------
FS_OnPlayerSpawn_Event <- function() {
    // player_spawn
    local uid = null;
    try { if ('event_data' in this && 'userid' in event_data) uid = event_data.userid; } catch(_e) {}

    local p = (uid != null) ? _GetPlayerFromUserIDSafe(uid) : null;
    if (!_IsPlayer(p)) {
        if ('activator' in this && _IsPlayer(activator)) p = activator;
    }

    if (_IsPlayer(p)) _ResetPlayer(p, 'player_spawn');
    // else _Dbg('SpawnEvent: missing event_data (check FetchEventData=1 + CallScriptFunction)');
};

FS_OnPlayerDeathEvent <- function() {
    // player_death
    local uid = null;
    try { if ('event_data' in this && 'userid' in event_data) uid = event_data.userid; } catch(_e) {}

    local p = (uid != null) ? _GetPlayerFromUserIDSafe(uid) : null;
    if (!_IsPlayer(p)) {
        if ('activator' in this && _IsPlayer(activator)) p = activator;
    }

    if (_IsPlayer(p)) _DoDeathPinata(p);
    // else _Dbg('DeathEvent: missing event_data (check FetchEventData=1 + CallScriptFunction)');
};

FS_OnPlayerHurtEvent <- function() {
    // player_hurt
    local uid = null;
    local dmg = 0;
    try {
        if ('event_data' in this && 'userid' in event_data) uid = event_data.userid;
        if ('event_data' in this && 'damageamount' in event_data) dmg = event_data.damageamount;
    } catch(_e) {}

    local p = (uid != null) ? _GetPlayerFromUserIDSafe(uid) : null;
    if (!_IsPlayer(p)) {
        if ('activator' in this && _IsPlayer(activator)) p = activator;
    }

    if (_IsPlayer(p) && dmg > 0) _DoDamageChunk(p, dmg);
};

// ---------------------------------------------------------------------------
// THINK LOOP (low-frequency pulse; handles merge cleanup + retry queue + TopK)
// ---------------------------------------------------------------------------
function FS_Think() {
    // Process retries
    local now = _Now();
    for (local i = flagspawn.State.RetryQ.len() - 1; i >= 0; i--) {
        local it = flagspawn.State.RetryQ[i];
        if (it == null) { flagspawn.State.RetryQ.remove(i); continue; }
        if ('t' in it && now >= it.t) {
            try { if ('f' in it && it.f != null) it.f(); } catch(_e) {}
            flagspawn.State.RetryQ.remove(i);
        }
    }

    // Prune stuck spawn contexts (maker callback didn't fire)
    _CtxQ_Prune(flagspawn.CFG.TEAM_BLU, 2.5);
    _CtxQ_Prune(flagspawn.CFG.TEAM_RED, 2.5);

    // Clamp carried/dropped flags to VALUE_CAP; overflow returns to budget shares
    foreach (suf2, pkg2 in flagspawn.State.Pkgs) {
        if (!('flag' in pkg2) || !_IsValid(pkg2.flag)) continue;
        local pv2 = _ReadFlagPointsSafe(pkg2.flag);
        local cap2 = flagspawn.CFG.VALUE_CAP; if (cap2 == null || cap2 < 1) cap2 = 100;
        if (pv2 > cap2) {
            local over2 = pv2 - cap2;
            // Apply clamp to entity + package
            pkg2.pointValue <- cap2;
            _ApplyFlagPointValue(pkg2.flag, cap2);
            _ApplyMeterBodygroups(pkg2, cap2);
            // Refund overflow into team budget shares
            if ('team' in pkg2) _ModifyBudget(pkg2.team, over2, 'overflow clamp');
            // Also reduce carry ledger if this flag was being carried
            if ('carrier' in pkg2 && _IsPlayer(pkg2.carrier) && 'team' in pkg2) {
                _CarryAdd(pkg2.carrier, pkg2.team, -over2, 'overflow clamp');
            }
            // if (flagspawn.CFG.DBG_ECON) _DbgEcon('Clamp overflow suf=' + suf2 + ' over=' + over2 + ' -> cap=' + cap2);
        }
    }

// Cleanup dead packages (merge/return/capture kills) + refresh stock UI
    local changedBlu = false;
    local changedRed = false;

    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!('flag' in pkg) || !_IsValid(pkg.flag)) {
            // Merge or refund/capture: absorbed flag disappears -> NO budget refund.
            // Return/Capture budget refund is handled by FS_Direct_Refund.
            if ('team' in pkg && pkg.team == flagspawn.CFG.TEAM_BLU) changedBlu = true;
            if ('team' in pkg && pkg.team == flagspawn.CFG.TEAM_RED) changedRed = true;

            // Best-effort cleanup of extras (they're usually parented and die anyway)
            try { if ('glow' in pkg && _IsValid(pkg.glow)) pkg.glow.Kill(); } catch(_e1) {}
            try { if ('lock' in pkg && _IsValid(pkg.lock)) pkg.lock.Kill(); } catch(_e2) {}
            try { if ('prop' in pkg && _IsValid(pkg.prop)) pkg.prop.Kill(); } catch(_e3) {}

            delete flagspawn.State.Pkgs[suf];
        }
    }

    if (changedBlu) _UpdateStockUI(flagspawn.CFG.TEAM_BLU);
    if (changedRed) _UpdateStockUI(flagspawn.CFG.TEAM_RED);

    // TopK + glow policy
    _RefreshTopK();
    _ApplyGlowPolicy();

    return flagspawn.CFG.THINK_DT;
}

// ---------------------------------------------------------------------------
// INIT
// ---------------------------------------------------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.InitDone) return;
    flagspawn.State.InitDone = true;

    // First-blood timer starts when the script initializes (round-start-ish).
    flagspawn.State.RoundStartAt = _Now();
    if ('FirstBloodClaims' in flagspawn.State) {
        flagspawn.State.FirstBloodClaims[flagspawn.CFG.TEAM_BLU] = 0;
        flagspawn.State.FirstBloodClaims[flagspawn.CFG.TEAM_RED] = 0;
    }

    // Seed bonus pool from POOL_START_* totals (distributed evenly)
    local startBlu = flagspawn.CFG.POOL_START_BLU; if (startBlu == null) startBlu = 0;
    local startRed = flagspawn.CFG.POOL_START_RED; if (startRed == null) startRed = 0;
    // Clear then add (water-fill)
    flagspawn.State.PoolShares[flagspawn.CFG.TEAM_BLU] = [0,0,0,0,0];
    flagspawn.State.PoolShares[flagspawn.CFG.TEAM_RED] = [0,0,0,0,0];
    _PoolAddDelta(flagspawn.CFG.TEAM_BLU, startBlu);
    _PoolAddDelta(flagspawn.CFG.TEAM_RED, startRed);


    // Force starting UI state
    _UpdateBudgetMeters(flagspawn.CFG.TEAM_BLU);
    _UpdateBudgetMeters(flagspawn.CFG.TEAM_RED);
    _UpdateStockUI(flagspawn.CFG.TEAM_BLU);
    _UpdateStockUI(flagspawn.CFG.TEAM_RED);

    // Attach think
    local scripter = _FindByName(flagspawn.CFG.SCRIPTER_NAME);
    if (_IsValid(scripter)) {
        try { AddThinkToEnt(scripter, 'FS_Think'); } catch(_e) {
            // _Dbg('WARN: AddThinkToEnt failed; pulse features (TopK/cleanup) will not run.');
        }
    } else {
        // _Dbg('WARN: missing scripter entity; no Think.');
    }

    // _Dbg('Init done ' + flagspawn.CFG.VERSION + ' (PoolBlu=' + _PoolTotal(flagspawn.CFG.TEAM_BLU) + ' shares=' + flagspawn.State.PoolShares[flagspawn.CFG.TEAM_BLU] + ')');
};

// Auto-init (best-effort). If entities are not ready, it still sets state, and
// the Think will maintain.
try { flagspawn.Init(); } catch(_e) {}
