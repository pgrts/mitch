// ============================================================
// flagspawn_pd_min.nut
// ------------------------------------------------------------
// Minimal PD flag spawner + pool manager.
// Uses item_teamflag outputs for lifecycle, and teamplay_flag_event
// (eventtype=1) + carry deltas for merge detection.
// ============================================================

// ---- ROOT TABLE SETUP ----
local rt = getroottable();
if (!("flagspawn" in rt)) rt["flagspawn"] <- {};
::flagspawn <- rt["flagspawn"];

// ------------------------------------------------------------
// Config
// ------------------------------------------------------------
::flagspawn.TEAM_RED <- 2;
::flagspawn.TEAM_BLU <- 3;

::flagspawn.DEBUG <- true;
::flagspawn.SCRIPTER_NAME <- "scripter";

::flagspawn.POOL_PER_TEAM <- 25;
::flagspawn.POOL_NAME_RED_PREFIX <- "fs_pool_red_";
::flagspawn.POOL_NAME_BLU_PREFIX <- "fs_pool_blu_";
::flagspawn.POOL_HIDE_ORIGIN <- Vector(0, 0, -8000);

::flagspawn.RETURN_TIME_SECONDS <- 60.0;
::flagspawn.GAMETYPE_PD <- 6; // item_teamflag gametype for PD

::flagspawn.FLAG_MODEL <- "models/props_custom/fs_meter/fs_meter_slab_grid.mdl";
::flagspawn.USE_FLAG_MODEL_BODYGROUP <- true;
::flagspawn.FLAG_BODYGROUP_INDEX <- 0;
::flagspawn.FLAG_BODYGROUP_MAX <- 100;

::flagspawn.CARRY_POINTS_PROP_NAME <- "m_nNumCarriedPoints";
::flagspawn.CARRY_COUNT_PROP_NAME <- "m_nStrength";

// ------------------------------------------------------------
// Logging + helpers
// ------------------------------------------------------------
::flagspawn.Log <- function(s) {
    if (::flagspawn.DEBUG) printl("[flagspawn] " + s);
};

::flagspawn._VecStr <- function(v) {
    if (!v) return "0 0 0";
    return "" + v.x + " " + v.y + " " + v.z;
};

::flagspawn._SafeName <- function(ent) {
    if (!ent) return "null";
    local nm = "";
    try { nm = ent.GetName(); } catch(e) { nm = ""; }
    if (nm == null || nm == "") {
        try { nm = ent.GetClassname() + "#" + ent.entindex(); } catch(e2) { nm = "ent"; }
    }
    return nm;
};

::flagspawn._GetEntOrigin <- function(ent) {
    if (!ent) return null;
    local org = null;
    try { org = ent.GetAbsOrigin(); } catch(e) { org = null; }
    if (org) return org;
    try { org = NetProps.GetPropVector(ent, "m_vecOrigin"); } catch(e2) { org = null; }
    return org;
};

::flagspawn._GetTeamNum <- function(ent) {
    if (!ent) return 0;
    local t = 0;
    try { t = ent.GetTeam(); return t; } catch(e) {}
    try { t = NetProps.GetPropInt(ent, "m_iTeamNum"); } catch(e2) { t = 0; }
    return t;
};

::flagspawn._OppTeam <- function(team) {
    if (team == ::flagspawn.TEAM_RED) return ::flagspawn.TEAM_BLU;
    if (team == ::flagspawn.TEAM_BLU) return ::flagspawn.TEAM_RED;
    return 0;
};

// ------------------------------------------------------------
// Class bonus (Heavy=5)
// ------------------------------------------------------------
::flagspawn._GetPlayerClassNum <- function(player) {
    if (!player) return 0;
    try { local c = player.GetPlayerClass(); if (typeof c == "integer") return c; } catch(e) {}
    try { return NetProps.GetPropInt(player, "m_PlayerClass.m_iClass"); } catch(e2) {}
    return 0;
};

::flagspawn.GetClassBonus <- function(player) {
    local cls = ::flagspawn._GetPlayerClassNum(player);
    switch (cls) {
        case 6: return 5; // Heavy
        case 2: return 3; // Sniper
        case 3: return 2; // Soldier
        default: return 1;
    }
};

// ------------------------------------------------------------
// Player state
// ------------------------------------------------------------
::flagspawn._ps <- {};

::flagspawn._PS <- function(player) {
    local k = 0;
    try { k = player.entindex(); } catch(e) { k = 0; }
    if (!(k in ::flagspawn._ps)) {
        ::flagspawn._ps[k] <- {
            last_carry_points = 0,
            last_spawn_value = 0,
            carried_flag_eidx = -1
        };
    }
    return ::flagspawn._ps[k];
};

// ------------------------------------------------------------
// Pool
// ------------------------------------------------------------
::flagspawn._pool <- { red = [], blu = [] };

::flagspawn._FindByName <- function(name) {
    local f = null;
    try { f = Entities.FindByName(null, name); } catch(e) { f = null; }
    return f;
};

::flagspawn._InitFlagScript <- function(flag) {
    if (!flag) return;
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_isFlagspawn <- true;
        if (!("fs_dropTime" in ss)) ss.fs_dropTime <- null;
        if (!("fs_in_pool" in ss)) ss.fs_in_pool <- false;
    } catch(e) {}
};

::flagspawn._IsFlagHiddenInPool <- function(flag) {
    if (!flag) return true;
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        if ("fs_in_pool" in ss && ss.fs_in_pool) return true;
    } catch(e) {}
    local org = null;
    try { org = flag.GetAbsOrigin(); } catch(e2) { org = null; }
    if (!org) return true;
    return org.z < -7000;
};

::flagspawn._HideFlag <- function(flag) {
    if (!flag) return;
    ::flagspawn._ClearFlagOwner(flag);
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_dropTime <- null;
        ss.fs_in_pool <- true;
    } catch(e0) {}
    try { flag.SetAbsOrigin(::flagspawn.POOL_HIDE_ORIGIN); } catch(e) {}
    try { EntFireByHandle(flag, "ForceReset", "", 0, null, null); } catch(e2) {}
};

::flagspawn._DetachFromPool <- function(flag) {
    if (!flag) return;
    try { flag.SetParent(null, ""); } catch(e0) {}
    try { EntFireByHandle(flag, "ClearParent", "", 0.0, null, null); } catch(e1) {}
    try { flag.__KeyValueFromString("parentname", ""); } catch(e2) {}
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_in_pool <- false;
    } catch(e3) {}
};

::flagspawn._ApplyReturnTime <- function(flag) {
    if (!flag) return;
    local rt = ::flagspawn.RETURN_TIME_SECONDS;
    try { flag.__KeyValueFromInt("ReturnTime", rt); } catch(e) {}
    try { flag.__KeyValueFromInt("returntime", rt); } catch(e2) {}
    try { EntFireByHandle(flag, "SetReturnTime", "" + rt, 0, null, null); } catch(e3) {}
};

::flagspawn._ApplyGameTypePD <- function(flag) {
    if (!flag) return;
    local gt = ::flagspawn.GAMETYPE_PD;
    try { flag.__KeyValueFromInt("GameType", gt); } catch(e0) {}
    try { flag.__KeyValueFromInt("gametype", gt); } catch(e1) {}
};

::flagspawn._ApplyFlagModel <- function(flag) {
    if (!flag || !::flagspawn.USE_FLAG_MODEL_BODYGROUP) return;
    if (!::flagspawn.FLAG_MODEL || ::flagspawn.FLAG_MODEL.len() == 0) return;
    try { flag.SetModel(::flagspawn.FLAG_MODEL); } catch(e0) {}
    try { flag.__KeyValueFromString("model", ::flagspawn.FLAG_MODEL); } catch(e1) {}
};

::flagspawn._InitPool <- function() {
    ::flagspawn._pool.red.clear();
    ::flagspawn._pool.blu.clear();

    for (local i = 1; i <= ::flagspawn.POOL_PER_TEAM; i++) {
        local idx = (i < 10) ? ("0" + i) : ("" + i);
        local rn = ::flagspawn.POOL_NAME_RED_PREFIX + idx;
        local bn = ::flagspawn.POOL_NAME_BLU_PREFIX + idx;

        local rf = ::flagspawn._FindByName(rn);
        local bf = ::flagspawn._FindByName(bn);

        if (rf) {
            ::flagspawn._InitFlagScript(rf);
            ::flagspawn._ApplyFlagModel(rf);
            ::flagspawn._ApplyReturnTime(rf);
            ::flagspawn._ApplyGameTypePD(rf);
            ::flagspawn._HideFlag(rf);
            ::flagspawn._pool.red.append(rf);
        } else {
            ::flagspawn.Log("POOL WARN: missing " + rn);
        }

        if (bf) {
            ::flagspawn._InitFlagScript(bf);
            ::flagspawn._ApplyFlagModel(bf);
            ::flagspawn._ApplyReturnTime(bf);
            ::flagspawn._ApplyGameTypePD(bf);
            ::flagspawn._HideFlag(bf);
            ::flagspawn._pool.blu.append(bf);
        } else {
            ::flagspawn.Log("POOL WARN: missing " + bn);
        }
    }

    ::flagspawn.Log("Pool init: red=" + ::flagspawn._pool.red.len() + " blu=" + ::flagspawn._pool.blu.len());
};

::flagspawn._TakeNextFromPool <- function(team) {
    local list = null;
    if (team == ::flagspawn.TEAM_RED) list = ::flagspawn._pool.red;
    if (team == ::flagspawn.TEAM_BLU) list = ::flagspawn._pool.blu;
    if (!list || list.len() <= 0) return null;

    foreach (f in list) {
        if (f && f.IsValid() && ::flagspawn._IsFlagHiddenInPool(f)) return f;
    }
    return null;
};

// ------------------------------------------------------------
// Flag values + bodygroup
// ------------------------------------------------------------
::flagspawn._UpdateFlagBodygroup <- function(flag, value) {
    if (!::flagspawn.USE_FLAG_MODEL_BODYGROUP || !flag) return;
    local v = value;
    if (v == null) v = ::flagspawn._GetFlagPointsValue(flag);
    try { v = v.tointeger(); } catch(e) {}
    if (v < 0) v = 0;
    if (v > ::flagspawn.FLAG_BODYGROUP_MAX) v = ::flagspawn.FLAG_BODYGROUP_MAX;

    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_bodygroup <- v;
    } catch(e2) {}

    local param = "" + ::flagspawn.FLAG_BODYGROUP_INDEX + " " + v;
    try { flag.__KeyValueFromInt("body", v); } catch(e0) {}
    try { EntFireByHandle(flag, "SetBodyGroup", param, 0.0, null, null); } catch(e3) {}
    try { EntFireByHandle(flag, "SetBodygroup", param, 0.0, null, null); } catch(e4) {}
    try { EntFireByHandle(flag, "SetBodyGroup", "" + v, 0.0, null, null); } catch(e5) {}
    try { EntFireByHandle(flag, "SetBodygroup", "" + v, 0.0, null, null); } catch(e6) {}
};

::flagspawn._SetFlagPointsValue <- function(flag, v) {
    if (!flag) return;
    try { flag.ValidateScriptScope(); flag.GetScriptScope().fs_value <- v; } catch(e) {}
    try { NetProps.SetPropInt(flag, "m_nPointValue", v); } catch(eN) {}
    try { NetProps.SetPropInt(flag, "m_iPointValue", v); } catch(eN2) {}
    try { flag.__KeyValueFromInt("PointsValue", v); } catch(e2) {}
    try { flag.__KeyValueFromInt("pointsvalue", v); } catch(e3) {}
    ::flagspawn._UpdateFlagBodygroup(flag, v);
};

::flagspawn._GetFlagPointsValue <- function(flag) {
    if (!flag) return 0;
    local vNet = null;
    try { vNet = NetProps.GetPropInt(flag, "m_nPointValue"); } catch(e0) { vNet = null; }
    if (vNet == null) {
        try { vNet = NetProps.GetPropInt(flag, "m_iPointValue"); } catch(e1) { vNet = null; }
    }
    if (vNet != null) {
        try { flag.ValidateScriptScope(); flag.GetScriptScope().fs_value <- vNet; } catch(e2) {}
        return vNet;
    }
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        if ("fs_value" in ss) return ss.fs_value.tointeger();
    } catch(e3) {}
    return 1;
};

::flagspawn._ClearFlagOwner <- function(flag) {
    if (!flag) return;
    try { NetProps.SetPropEntity(flag, "m_hOwnerEntity", null); } catch(e0) {}
    try { NetProps.SetPropEntity(flag, "m_hPrevOwner", null); } catch(e1) {}
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_owner_eidx <- -1;
    } catch(e2) {}
};

::flagspawn._SetFlagScriptOwner <- function(flag, player) {
    if (!flag) return;
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_owner_eidx <- (player ? player.entindex() : -1);
        ss.fs_dropTime <- null;
        ss.fs_isFlagspawn <- true;
    } catch(e) {}
};

::flagspawn._IsFlagCarriedBy <- function(flag, player) {
    if (!flag || !player) return false;
    local owner = null;
    try { owner = NetProps.GetPropEntity(flag, "m_hOwnerEntity"); } catch(e0) { owner = null; }
    if (owner == player) return true;
    local parent = null;
    try { parent = flag.GetMoveParent(); } catch(e1) { parent = null; }
    return parent == player;
};

::flagspawn._ResolveCarriedFlag <- function(player) {
    if (!player) return null;
    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        if (::flagspawn._IsFlagCarriedBy(f, player)) return f;
    }
    return null;
};

// ------------------------------------------------------------
// Carry values (merge detection)
// ------------------------------------------------------------
::flagspawn._GetPlayerCarryPoints <- function(player) {
    if (!player) return -1;
    local names = [
        ::flagspawn.CARRY_POINTS_PROP_NAME,
        "m_nNumCarriedPoints",
        "m_nNumCarriedPointsTotal"
    ];
    foreach (n in names) {
        if (!n || n.len() == 0) continue;
        try {
            local v = NetProps.GetPropInt(player, n);
            if (v >= 0) return v;
        } catch(e) {}
    }
    return -1;
};

::flagspawn._GetPlayerCarryCount <- function(player) {
    if (!player) return -1;
    local names = [
        ::flagspawn.CARRY_COUNT_PROP_NAME,
        "m_nStrength",
        "m_nNumCarryables",
        "m_nNumCarried"
    ];
    foreach (n in names) {
        if (!n || n.len() == 0) continue;
        try {
            local v = NetProps.GetPropInt(player, n);
            if (v >= 0) return v;
        } catch(e) {}
    }
    try { return player.GetNumCarryables(); } catch(e2) {}
    return -1;
};

::flagspawn._GetPlayerCarryValue <- function(player) {
    local points = ::flagspawn._GetPlayerCarryPoints(player);
    if (points >= 0) return points;
    local carried = ::flagspawn._ResolveCarriedFlag(player);
    if (carried) return ::flagspawn._GetFlagPointsValue(carried);
    local count = ::flagspawn._GetPlayerCarryCount(player);
    if (count >= 0) return count;
    return 0;
};

// ------------------------------------------------------------
// VMF outputs: pooled flag lifecycle
// ------------------------------------------------------------
::flagspawn.OnPoolFlagPickup <- function(flag, player) {
    if (!flag) return;
    ::flagspawn._DetachFromPool(flag);
    ::flagspawn._SetFlagScriptOwner(flag, player);
    ::flagspawn._UpdateFlagBodygroup(flag, ::flagspawn._GetFlagPointsValue(flag));

    if (player) {
        local ps = ::flagspawn._PS(player);
        ps.carried_flag_eidx = flag.entindex();
        ps.last_carry_points = ::flagspawn._GetPlayerCarryValue(player);
        ps.last_spawn_value = 0;
    }

    ::flagspawn.Log("POOL PICKUP: flag=" + ::flagspawn._SafeName(flag) +
        " player=" + ::flagspawn._SafeName(player));
};

::flagspawn.OnPoolFlagDrop <- function(flag, player) {
    if (!flag) return;
    ::flagspawn._DetachFromPool(flag);
    ::flagspawn._ClearFlagOwner(flag);
    try { flag.ValidateScriptScope(); flag.GetScriptScope().fs_dropTime <- Time(); } catch(e) {}
    ::flagspawn._UpdateFlagBodygroup(flag, ::flagspawn._GetFlagPointsValue(flag));

    if (player) {
        local ps = ::flagspawn._PS(player);
        ps.last_carry_points = 0;
        ps.carried_flag_eidx = -1;
    }

    ::flagspawn.Log("POOL DROP: flag=" + ::flagspawn._SafeName(flag) +
        " player=" + ::flagspawn._SafeName(player));
};

::flagspawn.OnPoolFlagReturn <- function(flag) {
    if (!flag) return;
    ::flagspawn._HideFlag(flag);
    ::flagspawn.Log("POOL RETURN: flag=" + ::flagspawn._SafeName(flag));
};

::flagspawn.OnPoolFlagCapture <- function(flag, player) {
    if (!flag) return;
    ::flagspawn._HideFlag(flag);
    if (player) {
        local ps = ::flagspawn._PS(player);
        ps.last_carry_points = 0;
        ps.carried_flag_eidx = -1;
    }
    ::flagspawn.Log("POOL CAPTURE: flag=" + ::flagspawn._SafeName(flag) +
        " player=" + ::flagspawn._SafeName(player));
};

// ------------------------------------------------------------
// Spawner touch
// ------------------------------------------------------------
::flagspawn.OnSpawnerTouch <- function(activator, teamParam) {
    local player = activator;
    if (!player) return;

    local requested = 0;
    if (typeof teamParam == "integer") requested = teamParam;
    if (requested != ::flagspawn.TEAM_RED && requested != ::flagspawn.TEAM_BLU) {
        ::flagspawn.Log("OnSpawnerTouch DENY: bad teamParam");
        return;
    }

    local spawnTeam = ::flagspawn._OppTeam(requested);
    local flag = ::flagspawn._TakeNextFromPool(spawnTeam);
    if (!flag) {
        ::flagspawn.Log("OnSpawnerTouch DENY: pool empty for spawnTeam=" + spawnTeam);
        return;
    }

    ::flagspawn._DetachFromPool(flag);
    ::flagspawn._ApplyFlagModel(flag);
    ::flagspawn._ApplyReturnTime(flag);
    ::flagspawn._ApplyGameTypePD(flag);
    ::flagspawn._ClearFlagOwner(flag);
    ::flagspawn._MakeFlagNeutral(flag);

    local val = ::flagspawn.GetClassBonus(player);
    ::flagspawn._SetFlagPointsValue(flag, val);

    local pos = ::flagspawn._GetEntOrigin(player);
    if (!pos) pos = Vector(0,0,0);
    local spawnPos = pos + Vector(0,0,2);
    try { flag.SetAbsOrigin(spawnPos); } catch(e1) {}
    try { EntFireByHandle(flag, "Teleport", ::flagspawn._VecStr(spawnPos), 0.0, null, null); } catch(e2) {}
    try { EntFireByHandle(flag, "TouchTest", "", 0.0, player, player); } catch(e3) {}

    local ps = ::flagspawn._PS(player);
    ps.last_spawn_value = val;

    ::flagspawn.Log("DISPENSE: team=" + spawnTeam + " flag=" + ::flagspawn._SafeName(flag) +
        " PointsValue=" + val);
};

// ------------------------------------------------------------
// Neutralize flag (PD pickups are neutral)
// ------------------------------------------------------------
::flagspawn._MakeFlagNeutral <- function(flag) {
    if (!flag) return;
    try { flag.SetTeam(0); } catch(e0) {}
    try { NetProps.SetPropInt(flag, "m_iTeamNum", 0); } catch(e1) {}
    try { NetProps.SetPropInt(flag, "m_iOriginalTeamNum", 0); } catch(e2) {}
    try { flag.__KeyValueFromInt("TeamNum", 0); } catch(e3) {}
    try { flag.__KeyValueFromInt("teamnum", 0); } catch(e4) {}
};

// ------------------------------------------------------------
// Merge detection (teamplay_flag_event eventtype=1)
// ------------------------------------------------------------
::flagspawn._GetEventPlayer <- function(params) {
    local player = null;
    if ("userid" in params) {
        try { player = GetPlayerFromUserID(params.userid); } catch(e) { player = null; }
    }
    if (!player && "player" in params) {
        try { player = GetPlayerFromUserID(params.player); } catch(e2) { player = null; }
        if (!player) { try { player = EntIndexToHScript(params.player); } catch(e3) { player = null; } }
    }
    if (!player && "carrier" in params) {
        try { player = GetPlayerFromUserID(params.carrier); } catch(e4) { player = null; }
        if (!player) { try { player = EntIndexToHScript(params.carrier); } catch(e5) { player = null; } }
    }
    return player;
};

::flagspawn._HandleCarryDelta <- function(player, carryNow) {
    if (!player) return;
    local ps = ::flagspawn._PS(player);
    local prev = ps.last_carry_points;

    if (carryNow <= 0) {
        if (ps.last_spawn_value > 0) {
            // Fallback when netprops are unavailable.
            if (prev > 0) carryNow = prev + ps.last_spawn_value;
            else carryNow = ps.last_spawn_value;
        } else {
            return;
        }
    }

    if (prev > 0 && carryNow > prev) {
        local delta = carryNow - prev;
        local carried = ::flagspawn._ResolveCarriedFlag(player);
        if (carried) ::flagspawn._SetFlagPointsValue(carried, carryNow);
        ps.last_carry_points = carryNow;
        ps.last_spawn_value = 0;
        ::flagspawn.Log("MERGE: player=" + ::flagspawn._SafeName(player) +
            " delta=" + delta + " total=" + carryNow);
        return;
    }

    if (prev <= 0 && carryNow > 0) {
        local carried2 = ::flagspawn._ResolveCarriedFlag(player);
        if (carried2) ::flagspawn._SetFlagPointsValue(carried2, carryNow);
        ps.last_carry_points = carryNow;
        ps.last_spawn_value = 0;
        ::flagspawn.Log("PICKUP START: player=" + ::flagspawn._SafeName(player) +
            " carry=" + carryNow);
    }
};

::flagspawn.OnGameEvent_teamplay_flag_event <- function(params) {
    local eventType = -1;
    if ("eventtype" in params) eventType = params.eventtype;
    else if ("eventType" in params) eventType = params.eventType;
    try { eventType = eventType.tointeger(); } catch(e) { eventType = -1; }
    if (eventType != 1) return;

    local player = ::flagspawn._GetEventPlayer(params);
    if (!player) return;

    local carryNow = ::flagspawn._GetPlayerCarryValue(player);
    ::flagspawn._HandleCarryDelta(player, carryNow);
};

::flagspawn.OnGameEvent_player_spawn <- function(params) {
    local player = null;
    if ("userid" in params) { try { player = GetPlayerFromUserID(params.userid); } catch(e) { player = null; } }
    if (!player) return;
    local ps = ::flagspawn._PS(player);
    ps.last_carry_points = 0;
    ps.last_spawn_value = 0;
    ps.carried_flag_eidx = -1;
};

// ------------------------------------------------------------
// Debug helpers
// ------------------------------------------------------------
::flagspawn.DebugCarryProps <- function(playerEidx) {
    local player = null;
    try { player = EntIndexToHScript(playerEidx); } catch(e) { player = null; }
    if (!player) return;
    try { ::flagspawn.Log("carryfunc GetNumCarryables=" + player.GetNumCarryables()); } catch(e0) {}
    local names = [
        ::flagspawn.CARRY_COUNT_PROP_NAME,
        ::flagspawn.CARRY_POINTS_PROP_NAME,
        "m_nStrength",
        "m_nNumCarryables",
        "m_nNumCarried",
        "m_nNumCarriedPoints",
        "m_nNumCarriedPointsTotal"
    ];
    foreach (n in names) {
        try { ::flagspawn.Log("carryprop " + n + "=" + NetProps.GetPropInt(player, n)); } catch(e) {}
    }
};

::flagspawn.DebugListFlags <- function() {
    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        local owner = null; try { owner = NetProps.GetPropEntity(f, "m_hOwnerEntity"); } catch(e0) { owner = null; }
        local parent = null; try { parent = f.GetMoveParent(); } catch(e1) { parent = null; }
        local status = null; try { status = NetProps.GetPropInt(f, "m_nFlagStatus"); } catch(e2) { status = null; }
        local org = ::flagspawn._GetEntOrigin(f);
        local pos = org ? ::flagspawn._VecStr(org) : "null";
        ::flagspawn.Log("FLAG: " + ::flagspawn._SafeName(f) +
            " owner=" + ::flagspawn._SafeName(owner) +
            " parent=" + ::flagspawn._SafeName(parent) +
            " status=" + status +
            " pos=" + pos +
            " hidden=" + ::flagspawn._IsFlagHiddenInPool(f));
    }
};

// ------------------------------------------------------------
// Init
// ------------------------------------------------------------
::flagspawn.RegisterEvents <- function() {
    try { __CollectGameEventCallbacks(::flagspawn); ::flagspawn.Log("Registered game event callbacks."); }
    catch(e) { ::flagspawn.Log("WARN: Could not register game event callbacks (" + e + ")."); }
};

::flagspawn.Init <- function() {
    ::flagspawn.Log("LOADED PD minimal @ t=" + Time());
    if (::flagspawn.USE_FLAG_MODEL_BODYGROUP && ::flagspawn.FLAG_MODEL && ::flagspawn.FLAG_MODEL.len() > 0) {
        try { PrecacheModel(::flagspawn.FLAG_MODEL); } catch(e0) {}
    }
    ::flagspawn._InitPool();
    ::flagspawn.RegisterEvents();
    ::flagspawn.Log("READY. ReturnTime=" + ::flagspawn.RETURN_TIME_SECONDS + "s");
};

::flagspawn.Init();

// Hammer may call plain Init() in script scope
Init <- function() { ::flagspawn.Init(); };
