// flagspawn/fs_core.nut
// Utilities + meter/stock UI + safe player origin helper.

local rt = getroottable();
local FS = rt.flagspawn;

FS.IsValid <- function(e) { return e != null && e.IsValid(); }

FS._ClampI <- function(x, a, b) {
    if (x < a) return a;
    if (x > b) return b;
    return x;
}

FS._Find <- function(name) { return Entities.FindByName(null, name); }

FS._TeamOK <- function(t) { return (t == FS.CFG.TEAM_RED || t == FS.CFG.TEAM_BLU); }

FS._Pid <- function(p) { return (FS.IsValid(p) ? p.GetEntityIndex() : 0); }

FS._CarryGet <- function(p) {
    local id = FS._Pid(p);
    if (id <= 0) return 0;
    return (id in FS.State.Carry) ? FS.State.Carry[id] : 0;
}

FS._CarrySet <- function(p, v) {
    local id = FS._Pid(p);
    if (id <= 0) return;
    if (v <= 0) { if (id in FS.State.Carry) delete FS.State.Carry[id]; return; }
    FS.State.Carry[id] <- v;
}

FS._StockRemaining <- function(team) {
    local used = FS.State.Active[team] + FS.State.Pending[team];
    local rem = FS.CFG.LIMIT_ACTIVE - used;
    if (rem < 0) rem = 0;
    return rem;
}

FS._UpdateStockText <- function(team) {
    local nm = FS.CFG.STOCK_TEXT[team];
    if (!nm) return;
    local t = FS._Find(nm);
    if (!FS.IsValid(t)) return;

    // In TF2 VScript, inputs are fired via EntFire/EntFireByHandle, not methods.
    EntFireByHandle(t, 'AddOutput', 'message ' + FS._StockRemaining(team), 0.0, null, null);
}

FS._UpdateMeter <- function(team) {
    local prefix = FS.CFG.METER_PREFIX[team];
    if (!prefix) return;

    local total = FS.State.Pool[team];
    if (total < 0) total = 0;
    if (total > FS.CFG.POOL_CAP) total = FS.CFG.POOL_CAP;

    for (local i = 1; i <= FS.CFG.METER_COUNT; i++) {
        local seg = total - ((i - 1) * 100);
        if (seg < 0) seg = 0;
        if (seg > 100) seg = 100;

        local ent = FS._Find(prefix + format('%02d', i));
        if (FS.IsValid(ent)) {
            // critical project rule: bodygroup index 1
            try { ent.SetBodygroup(1, seg); } catch(_e) {}
        }
    }
}

// Hard rule: do NOT call GetAbsOrigin() on players
FS._OriginPlayerSafe <- function(p) {
    try { return NetProps.GetPropVector(p, 'm_vecAbsOrigin'); } catch(_e) {}
    try { return p.GetOrigin(); } catch(_e2) {}
    return Vector(0,0,0);
}

FS._GetFlagValue <- function(f) {
    local v = 0;
    try { v = NetProps.GetPropInt(f, 'm_nPointValue'); } catch(_e) { v = 0; }
    if (v < 0) v = 0;
    return v;
}

FS._SetFlagValue <- function(f, val) {
    // Never trust template default
    try { NetProps.SetPropInt(f, 'm_nPointValue', val); } catch(_e) {}
    // If your flag model uses bodygroup 0 for value, keep this:
    try { f.SetBodygroup(0, val); } catch(_e2) {}
}

FS._AddPool <- function(team, amt) {
    if (amt <= 0) return;
    local cur = FS.State.Pool[team] + amt;
    if (cur > FS.CFG.POOL_CAP) cur = FS.CFG.POOL_CAP;
    FS.State.Pool[team] <- cur;
}

FS._ConsumePool <- function(team, amt) {
    if (amt <= 0) return;
    local cur = FS.State.Pool[team] - amt;
    if (cur < 0) cur = 0;
    FS.State.Pool[team] <- cur;
}

FS._TryMaker <- function(team, dyn) {
    local nm = dyn ? FS.CFG.MAKER_DYN[team] : FS.CFG.MAKER[team];
    local mk = nm ? FS._Find(nm) : null;
    if (!FS.IsValid(mk) && dyn) {
        nm = FS.CFG.MAKER[team];
        mk = nm ? FS._Find(nm) : null;
    }
    return mk;
}

// ---------------- State + Init ----------------
FS.State <- {
    Pool    = { [2] = 0, [3] = 0 },
    Active  = { [2] = 0, [3] = 0 },
    Pending = { [2] = 0, [3] = 0 },

    // Spawn queue entries are arrays to reduce constant-table pressure:
    // [team, value, poolPortionToConsume, ownerEntIndexOr0, dropOriginOrNull]
    Q = [],

    Carry = {},
    UsedSpawn = {},
    FirstClaim = {},
    FirstCount = { [2] = 0, [3] = 0 },

    RoundT0 = Time()
};

FS.Init <- function() {
    FS.State.Pool[FS.CFG.TEAM_RED] = 0;
    FS.State.Pool[FS.CFG.TEAM_BLU] = 0;
    FS.State.Active[FS.CFG.TEAM_RED] = 0;
    FS.State.Active[FS.CFG.TEAM_BLU] = 0;
    FS.State.Pending[FS.CFG.TEAM_RED] = 0;
    FS.State.Pending[FS.CFG.TEAM_BLU] = 0;

    FS.State.Q.clear();
    FS.State.Carry.clear();
    FS.State.UsedSpawn.clear();
    FS.State.FirstClaim.clear();
    FS.State.FirstCount[FS.CFG.TEAM_RED] = 0;
    FS.State.FirstCount[FS.CFG.TEAM_BLU] = 0;
    FS.State.RoundT0 = Time();

    // Meter props start empty (0) by design.
    FS._UpdateMeter(FS.CFG.TEAM_RED);
    FS._UpdateMeter(FS.CFG.TEAM_BLU);
    FS._UpdateStockText(FS.CFG.TEAM_RED);
    FS._UpdateStockText(FS.CFG.TEAM_BLU);
}
