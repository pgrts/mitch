// ============================================================
// flagspawn_pd_core.nut
// ------------------------------------------------------------
// Event-driven PD pickup tracking with logic_eventlistener +
// item_teamflag outputs. Tracks flag state + player carry totals,
// updates meter bodygroup, and handles 60s returns.
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

::flagspawn.CFG <- {
    DEBUG = true,

    RETURN_DELAY = 60.0,
    CARRY_MAX = 99,

    DISPENSE_COOLDOWN = 0.35,
    DISPENSE_FWD = 24.0,
    DISPENSE_UP = 24.0,

    POOL_PER_TEAM = 25,
    POOL_NAME_RED_PREFIX = "fs_pool_red_",
    POOL_NAME_BLU_PREFIX = "fs_pool_blu_",
    POOL_HIDE_ORIGIN = Vector(0, 0, -8000),

    METER_MODEL = "models/props_custom/fs_meter/fs_meter_slab_grid.mdl",
    METER_BODYGROUP = 0,
    METER_FLAG_ATTACHMENT = "origin",
    ENABLE_METER = true,

    SET_FLAG_BODYGROUP = true,
    BODYGROUP_MAX = 99,

    SEARCH_RADIUS = 96.0,
    EVENT_DEBOUNCE = 0.05,
};

// ------------------------------------------------------------
// State
// ------------------------------------------------------------
::flagspawn.State <- {
    Flags = {},      // entindex -> { value, state, carrier_eidx, return_deadline, vis_eidx, glow_eidx, no_return, pool_team, beneficiary_team }
    Players = {},    // entindex -> { carried_total, last_event_time, last_event_type, last_flag_eidx, last_spawn_flag, last_spawn_time }
    Pool = { [2] = [], [3] = [] },
    NextDispenseAt = {}
};

// ------------------------------------------------------------
// Logging + helpers
// ------------------------------------------------------------
::flagspawn.Log <- function(s) {
    if (::flagspawn.CFG.DEBUG) printl("[flagspawn] " + s);
};

::flagspawn._Now <- function() { return Time(); };

::flagspawn._EntIndex <- function(ent) {
    if (!ent) return -1;
    try { return ent.entindex(); } catch(e) { return -1; }
};

::flagspawn._IsPlayer <- function(ent) {
    return ent && ent.IsValid && ent.IsValid() && ent.GetClassname && ent.GetClassname() == "player";
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

::flagspawn._ParseInt <- function(v, defval) {
    if (v == null) return defval;
    if (typeof v == "integer") return v;
    if (typeof v == "float") return v.tointeger();
    if (typeof v == "string") {
        if (v.len() == 0) return defval;
        try { return v.tointeger(); } catch(e) { return defval; }
    }
    return defval;
};

::flagspawn._OppTeam <- function(team) {
    if (team == ::flagspawn.TEAM_RED) return ::flagspawn.TEAM_BLU;
    if (team == ::flagspawn.TEAM_BLU) return ::flagspawn.TEAM_RED;
    return 0;
};

::flagspawn._PoolTeamFromName <- function(flag) {
    if (!flag) return 0;
    local nm = "";
    try { nm = flag.GetName(); } catch(e) { nm = ""; }
    if (nm.len() >= ::flagspawn.CFG.POOL_NAME_RED_PREFIX.len() && nm.find(::flagspawn.CFG.POOL_NAME_RED_PREFIX) == 0) return ::flagspawn.TEAM_RED;
    if (nm.len() >= ::flagspawn.CFG.POOL_NAME_BLU_PREFIX.len() && nm.find(::flagspawn.CFG.POOL_NAME_BLU_PREFIX) == 0) return ::flagspawn.TEAM_BLU;
    return 0;
};

// ------------------------------------------------------------
// Player state
// ------------------------------------------------------------
::flagspawn._PS <- function(player) {
    local k = ::flagspawn._EntIndex(player);
    if (k <= 0) return null;
    if (!(k in ::flagspawn.State.Players)) {
        ::flagspawn.State.Players[k] <- {
            carried_total = 0,
            last_event_time = 0.0,
            last_event_type = -1,
            last_flag_eidx = -1,
            last_spawn_flag = -1,
            last_spawn_time = 0.0
        };
    }
    return ::flagspawn.State.Players[k];
};

// ------------------------------------------------------------
// Flag state
// ------------------------------------------------------------
::flagspawn._EnsureFlagData <- function(flag) {
    if (!flag) return null;
    local ei = ::flagspawn._EntIndex(flag);
    if (ei <= 0) return null;

    if (!(ei in ::flagspawn.State.Flags)) {
        local data = {
            value = 1,
            state = "pooled",
            carrier_eidx = -1,
            return_deadline = null,
            vis_eidx = -1,
            glow_eidx = -1,
            no_return = false,
            pool_team = 0,
            beneficiary_team = 0
        };

        // Restore from script scope if present
        try {
            flag.ValidateScriptScope();
            local ss = flag.GetScriptScope();
            if ("fs_value" in ss) data.value = ss.fs_value.tointeger();
            if ("fs_state" in ss) data.state = ss.fs_state;
            if ("fs_poolTeam" in ss) data.pool_team = ss.fs_poolTeam.tointeger();
            if ("fs_beneficiaryTeam" in ss) data.beneficiary_team = ss.fs_beneficiaryTeam.tointeger();
            if ("fs_no_return" in ss) data.no_return = ss.fs_no_return;
            if ("fs_vis_eidx" in ss) data.vis_eidx = ss.fs_vis_eidx.tointeger();
            if ("fs_glow_eidx" in ss) data.glow_eidx = ss.fs_glow_eidx.tointeger();
            if ("fs_dropTime" in ss && typeof ss.fs_dropTime == "float") {
                data.return_deadline = ss.fs_dropTime + ::flagspawn.CFG.RETURN_DELAY;
            }
        } catch(e) {}

        if (data.pool_team == 0) data.pool_team = ::flagspawn._PoolTeamFromName(flag);

        ::flagspawn.State.Flags[ei] <- data;
    }

    // Ensure script scope markers
    try {
        flag.ValidateScriptScope();
        local ss2 = flag.GetScriptScope();
        ss2.fs_isFlagspawn <- true;
        if (!("fs_poolTeam" in ss2)) ss2.fs_poolTeam <- ::flagspawn._PoolTeamFromName(flag);
    } catch(e2) {}

    return ::flagspawn.State.Flags[ei];
};

::flagspawn._WriteFlagScope <- function(flag, data) {
    if (!flag || !data) return;
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.fs_value <- data.value;
        ss.fs_state <- data.state;
        ss.fs_poolTeam <- data.pool_team;
        ss.fs_beneficiaryTeam <- data.beneficiary_team;
        ss.fs_no_return <- data.no_return;
        ss.fs_vis_eidx <- data.vis_eidx;
        ss.fs_glow_eidx <- data.glow_eidx;
        if (data.state == "dropped") ss.fs_dropTime <- ::flagspawn._Now();
        if (data.state != "dropped") ss.fs_dropTime <- null;
    } catch(e) {}
};

::flagspawn._IsFlagHiddenInPool <- function(flag) {
    if (!flag) return true;
    local org = null;
    try { org = flag.GetAbsOrigin(); } catch(e) { org = null; }
    if (!org) return true;
    return (org.z < -7000);
};

// ------------------------------------------------------------
// Meter proxy
// ------------------------------------------------------------
::flagspawn._EnsureMeter <- function(flag, data) {
    if (!::flagspawn.CFG.ENABLE_METER) return null;
    if (!data) return null;

    local meter = null;
    if (data.vis_eidx > 0) {
        try { meter = EntIndexToHScript(data.vis_eidx); } catch(e0) { meter = null; }
        if (meter && meter.IsValid()) return meter;
    }

    local kv = {
        targetname = "fs_meter_" + UniqueString("m"),
        model = ::flagspawn.CFG.METER_MODEL,
        solid = 0,
        rendermode = 0,
        disableshadows = 1
    };
    meter = SpawnEntityFromTable("prop_dynamic", kv);
    if (!meter) return null;

    data.vis_eidx = meter.entindex();
    try { meter.SetAbsOrigin(::flagspawn.CFG.POOL_HIDE_ORIGIN); } catch(e1) {}

    return meter;
};

::flagspawn._SetBodygroupValue <- function(ent, value) {
    if (!ent) return;
    local v = value;
    try { v = v.tointeger(); } catch(e) {}
    if (v < 0) v = 0;
    if (v > ::flagspawn.CFG.BODYGROUP_MAX) v = ::flagspawn.CFG.BODYGROUP_MAX;

    local param = "" + ::flagspawn.CFG.METER_BODYGROUP + " " + v;
    try { EntFireByHandle(ent, "SetBodyGroup", param, 0.0, null, null); } catch(e0) {}
    try { EntFireByHandle(ent, "SetBodygroup", param, 0.0, null, null); } catch(e1) {}
    try { EntFireByHandle(ent, "SetBodyGroup", "" + v, 0.0, null, null); } catch(e2) {}
    try { EntFireByHandle(ent, "SetBodygroup", "" + v, 0.0, null, null); } catch(e3) {}
};

::flagspawn._AttachMeterToFlag <- function(flag, data) {
    if (!flag || !data) return;
    local meter = ::flagspawn._EnsureMeter(flag, data);
    if (!meter) return;

    local fname = "";
    try { fname = flag.GetName(); } catch(e0) { fname = ""; }
    if (fname == null || fname == "") {
        fname = "fs_flag_" + flag.entindex();
        try { flag.__KeyValueFromString("targetname", fname); } catch(e1) {}
    }

    EntFireByHandle(meter, "ClearParent", "", 0.0, null, null);
    EntFireByHandle(meter, "SetParent", fname, 0.0, null, null);
    EntFireByHandle(meter, "SetParentAttachment", ::flagspawn.CFG.METER_FLAG_ATTACHMENT, 0.0, null, null);
    ::flagspawn._SetBodygroupValue(meter, data.value);
};

::flagspawn._HideMeter <- function(data) {
    if (!data) return;
    if (data.vis_eidx <= 0) return;
    local meter = null;
    try { meter = EntIndexToHScript(data.vis_eidx); } catch(e) { meter = null; }
    if (!meter || !meter.IsValid()) return;
    EntFireByHandle(meter, "ClearParent", "", 0.0, null, null);
    try { meter.SetAbsOrigin(::flagspawn.CFG.POOL_HIDE_ORIGIN); } catch(e2) {}
};

// ------------------------------------------------------------
// Flag value
// ------------------------------------------------------------
::flagspawn._SetFlagValue <- function(flag, value) {
    if (!flag) return;
    local data = ::flagspawn._EnsureFlagData(flag);
    if (!data) return;

    local v = value;
    try { v = v.tointeger(); } catch(e) {}
    if (v < 0) v = 0;
    if (v > ::flagspawn.CFG.CARRY_MAX) v = ::flagspawn.CFG.CARRY_MAX;

    data.value = v;

    try { flag.__KeyValueFromInt("PointsValue", v); } catch(e0) {}
    try { flag.__KeyValueFromInt("pointsvalue", v); } catch(e1) {}
    try { NetProps.SetPropInt(flag, "m_nPointValue", v); } catch(e2) {}
    try { NetProps.SetPropInt(flag, "m_iPointValue", v); } catch(e3) {}

    if (::flagspawn.CFG.SET_FLAG_BODYGROUP) ::flagspawn._SetBodygroupValue(flag, v);
    if (::flagspawn.CFG.ENABLE_METER) ::flagspawn._SetBodygroupValue(EntIndexToHScript(data.vis_eidx), v);

    ::flagspawn._WriteFlagScope(flag, data);
};

::flagspawn._GetFlagValue <- function(flag) {
    if (!flag) return 0;
    local data = ::flagspawn._EnsureFlagData(flag);
    if (data) return data.value;
    return 0;
};

// ------------------------------------------------------------
// Pool helpers
// ------------------------------------------------------------
::flagspawn._HideFlag <- function(flag) {
    if (!flag) return;
    local data = ::flagspawn._EnsureFlagData(flag);
    if (!data) return;

    data.state = "pooled";
    data.carrier_eidx = -1;
    data.return_deadline = null;

    try { flag.__KeyValueFromInt("ReturnTime", ::flagspawn.CFG.RETURN_DELAY); } catch(e0) {}
    try { EntFireByHandle(flag, "ClearParent", "", 0.0, null, null); } catch(e1) {}
    try { EntFireByHandle(flag, "Disable", "", 0.0, null, null); } catch(e2) {}
    try { flag.SetAbsOrigin(::flagspawn.CFG.POOL_HIDE_ORIGIN); } catch(e3) {}

    ::flagspawn._HideMeter(data);
    ::flagspawn._WriteFlagScope(flag, data);
};

::flagspawn._TakeNextFromPool <- function(team) {
    local list = null;
    if (team == ::flagspawn.TEAM_RED) list = ::flagspawn.State.Pool[::flagspawn.TEAM_RED];
    if (team == ::flagspawn.TEAM_BLU) list = ::flagspawn.State.Pool[::flagspawn.TEAM_BLU];
    if (!list || list.len() <= 0) return null;

    foreach (f in list) {
        if (f && f.IsValid() && ::flagspawn._IsFlagHiddenInPool(f)) return f;
    }
    return null;
};

::flagspawn._InitPool <- function() {
    ::flagspawn.State.Pool[::flagspawn.TEAM_RED].clear();
    ::flagspawn.State.Pool[::flagspawn.TEAM_BLU].clear();

    for (local i = 1; i <= ::flagspawn.CFG.POOL_PER_TEAM; i++) {
        local rn = ::flagspawn.CFG.POOL_NAME_RED_PREFIX + ((i < 10) ? "0" + i : "" + i);
        local bn = ::flagspawn.CFG.POOL_NAME_BLU_PREFIX + ((i < 10) ? "0" + i : "" + i);

        local rf = Entities.FindByName(null, rn);
        if (rf) {
            ::flagspawn._EnsureFlagData(rf);
            ::flagspawn._HideFlag(rf);
            ::flagspawn.State.Pool[::flagspawn.TEAM_RED].append(rf);
        } else {
            ::flagspawn.Log("POOL WARN: missing " + rn);
        }

        local bf = Entities.FindByName(null, bn);
        if (bf) {
            ::flagspawn._EnsureFlagData(bf);
            ::flagspawn._HideFlag(bf);
            ::flagspawn.State.Pool[::flagspawn.TEAM_BLU].append(bf);
        } else {
            ::flagspawn.Log("POOL WARN: missing " + bn);
        }
    }

    ::flagspawn.Log("Pool init: red=" + ::flagspawn.State.Pool[::flagspawn.TEAM_RED].len() + " blu=" + ::flagspawn.State.Pool[::flagspawn.TEAM_BLU].len());
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
// Carry resolve
// ------------------------------------------------------------
::flagspawn._ResolveCarriedFlag <- function(player) {
    if (!player) return null;
    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        try {
            local owner = NetProps.GetPropEntity(f, "m_hOwnerEntity");
            if (owner == player) return f;
        } catch(e) {}
    }
    return null;
};

::flagspawn._FindNearestDroppedFlag <- function(player, radius) {
    if (!player) return null;
    local org = null;
    try { org = player.GetAbsOrigin(); } catch(e) { org = null; }
    if (!org) return null;

    local best = null;
    local bestDist = radius * radius;

    foreach (ei, data in ::flagspawn.State.Flags) {
        if (data.state != "dropped") continue;
        local f = null;
        try { f = EntIndexToHScript(ei); } catch(e2) { f = null; }
        if (!f || !f.IsValid()) continue;
        local pos = null;
        try { pos = f.GetAbsOrigin(); } catch(e3) { pos = null; }
        if (!pos) continue;
        local dx = pos.x - org.x;
        local dy = pos.y - org.y;
        local dz = pos.z - org.z;
        local d2 = dx*dx + dy*dy + dz*dz;
        if (d2 < bestDist) {
            best = f;
            bestDist = d2;
        }
    }
    return best;
};

::flagspawn._GetPlayerCarryPoints <- function(player) {
    if (!player) return -1;
    local names = [ "m_nNumCarriedPoints", "m_nStrength", "m_nNumCarried", "m_nNumCarriedFlags" ];
    foreach (n in names) {
        try {
            local v = NetProps.GetPropInt(player, n);
            if (v >= 0) return v;
        } catch(e) {}
    }
    return -1;
};

// ------------------------------------------------------------
// Flag state transitions
// ------------------------------------------------------------
::flagspawn._SetFlagState <- function(flag, state, player) {
    if (!flag) return;
    local data = ::flagspawn._EnsureFlagData(flag);
    if (!data) return;

    data.state = state;

    if (state == "carried" && player) {
        data.carrier_eidx = ::flagspawn._EntIndex(player);
        data.return_deadline = null;
    } else if (state == "dropped") {
        data.carrier_eidx = -1;
        data.return_deadline = ::flagspawn._Now() + ::flagspawn.CFG.RETURN_DELAY;
    } else if (state == "returned" || state == "captured" || state == "pooled") {
        data.carrier_eidx = -1;
        data.return_deadline = null;
    }

    ::flagspawn._WriteFlagScope(flag, data);
};

::flagspawn._ReturnFlag <- function(flag, reason) {
    if (!flag) return;
    ::flagspawn._SetFlagState(flag, reason);
    ::flagspawn._HideFlag(flag);
};

// ------------------------------------------------------------
// Event handling
// ------------------------------------------------------------
::flagspawn._IsDuplicateEvent <- function(ps, eventType) {
    if (!ps) return false;
    local now = ::flagspawn._Now();
    if (ps.last_event_type == eventType && (now - ps.last_event_time) < ::flagspawn.CFG.EVENT_DEBOUNCE) return true;
    ps.last_event_type = eventType;
    ps.last_event_time = now;
    return false;
};

::flagspawn._HandlePickupEvent <- function(player, flag) {
    if (!player) return;
    local ps = ::flagspawn._PS(player);
    if (!ps) return;
    if (::flagspawn._IsDuplicateEvent(ps, 1)) return;

    local prev = ps.carried_total;

    // Resolve picked flag
    local picked = flag;
    if (!picked) picked = ::flagspawn._FindNearestDroppedFlag(player, ::flagspawn.CFG.SEARCH_RADIUS);
    if (!picked && ps.last_spawn_flag > 0 && (::flagspawn._Now() - ps.last_spawn_time) < 0.5) {
        try { picked = EntIndexToHScript(ps.last_spawn_flag); } catch(e0) { picked = null; }
    }

    local pickedValue = (picked ? ::flagspawn._GetFlagValue(picked) : 0);
    local carryNow = ::flagspawn._GetPlayerCarryPoints(player);
    if (carryNow < 0 && pickedValue > 0) carryNow = prev + pickedValue;
    if (carryNow < 0) return;

    if (carryNow <= prev && prev > 0) return;

    local carriedFlag = ::flagspawn._ResolveCarriedFlag(player);
    if (!carriedFlag && picked) carriedFlag = picked;

    if (carriedFlag) {
        ::flagspawn._SetFlagValue(carriedFlag, carryNow);
        ::flagspawn._SetFlagState(carriedFlag, "carried", player);
        ::flagspawn._AttachMeterToFlag(carriedFlag, ::flagspawn._EnsureFlagData(carriedFlag));
    }

    ps.carried_total = carryNow;
    ps.last_flag_eidx = carriedFlag ? carriedFlag.entindex() : -1;

    if (prev > 0 && picked && carriedFlag && picked.entindex() != carriedFlag.entindex()) {
        ::flagspawn._ReturnFlag(picked, "pooled");
    }

    ::flagspawn.Log("PICKUP: player=" + ::flagspawn._SafeName(player) + " total=" + carryNow);
};

::flagspawn._HandleDropEvent <- function(player, flag) {
    if (!player) return;
    local ps = ::flagspawn._PS(player);
    if (!ps) return;
    if (::flagspawn._IsDuplicateEvent(ps, 4)) return;

    local dropped = flag;
    if (!dropped) dropped = ::flagspawn._ResolveCarriedFlag(player);
    if (!dropped) dropped = ::flagspawn._FindNearestDroppedFlag(player, ::flagspawn.CFG.SEARCH_RADIUS);

    if (dropped) {
        if (ps.carried_total > 0) ::flagspawn._SetFlagValue(dropped, ps.carried_total);
        ::flagspawn._SetFlagState(dropped, "dropped", null);
        ::flagspawn._AttachMeterToFlag(dropped, ::flagspawn._EnsureFlagData(dropped));
    }

    ps.carried_total = 0;
    ps.last_flag_eidx = -1;

    ::flagspawn.Log("DROP: player=" + ::flagspawn._SafeName(player) + " flag=" + ::flagspawn._SafeName(dropped));
};

::flagspawn._HandleReturnEvent <- function(player, flag) {
    local ret = flag;
    if (!ret && player) ret = ::flagspawn._FindNearestDroppedFlag(player, ::flagspawn.CFG.SEARCH_RADIUS);
    if (!ret) return;

    ::flagspawn._ReturnFlag(ret, "returned");
    ::flagspawn.Log("RETURN: flag=" + ::flagspawn._SafeName(ret));
};

::flagspawn._HandleCaptureEvent <- function(player, flag) {
    local cap = flag;
    if (!cap && player) cap = ::flagspawn._ResolveCarriedFlag(player);
    if (!cap) return;

    ::flagspawn._ReturnFlag(cap, "captured");

    if (player) {
        local ps = ::flagspawn._PS(player);
        if (ps) {
            ps.carried_total = 0;
            ps.last_flag_eidx = -1;
        }
    }

    ::flagspawn.Log("CAPTURE: player=" + ::flagspawn._SafeName(player) + " flag=" + ::flagspawn._SafeName(cap));
};

::flagspawn._HandleTeamplayFlagEvent <- function(eventType, player, flag) {
    if (eventType == 1) { ::flagspawn._HandlePickupEvent(player, flag); return; }
    if (eventType == 4) { ::flagspawn._HandleDropEvent(player, flag); return; }
    if (eventType == 5) { ::flagspawn._HandleReturnEvent(player, flag); return; }
    if (eventType == 2) { ::flagspawn._HandleCaptureEvent(player, flag); return; }
};

// ------------------------------------------------------------
// VMF event listener entrypoint
// ------------------------------------------------------------
::flagspawn.OnFlagEventFromVMF <- function(eventtype = null, playerParam = null, flagParam = null) {
    local et = ::flagspawn._ParseInt(eventtype, -1);
    if (et < 0) {
        ::flagspawn.Log("VMF event missing eventtype; update logic_eventlistener output to pass %eventtype%.");
        return;
    }

    local player = null;
    if (playerParam != null) {
        local num = ::flagspawn._ParseInt(playerParam, -1);
        if (num > 0) {
            try { player = GetPlayerFromUserID(num); } catch(e0) { player = null; }
            if (!player) { try { player = EntIndexToHScript(num); } catch(e1) { player = null; } }
        } else if (typeof playerParam == "instance") {
            player = playerParam;
        }
    }

    if (!player && ("activator" in getroottable())) {
        if (::flagspawn._IsPlayer(activator)) player = activator;
    }

    local flag = null;
    if (flagParam != null) {
        if (typeof flagParam == "string") flag = Entities.FindByName(null, flagParam);
        else if (typeof flagParam == "instance") flag = flagParam;
        else {
            local fn = ::flagspawn._ParseInt(flagParam, -1);
            if (fn > 0) { try { flag = EntIndexToHScript(fn); } catch(e2) { flag = null; } }
        }
    }

    ::flagspawn._HandleTeamplayFlagEvent(et, player, flag);
};

// ------------------------------------------------------------
// Item outputs (safe with or without args)
// ------------------------------------------------------------
::flagspawn.OnPoolFlagPickup <- function(flag = null, player = null) {
    if (!flag && ("caller" in getroottable())) flag = caller;
    if (!player && ("activator" in getroottable())) player = activator;
    ::flagspawn._HandlePickupEvent(player, flag);
};

::flagspawn.OnPoolFlagDrop <- function(flag = null, player = null) {
    if (!flag && ("caller" in getroottable())) flag = caller;
    if (!player && ("activator" in getroottable())) player = activator;
    ::flagspawn._HandleDropEvent(player, flag);
};

::flagspawn.OnPoolFlagReturn <- function(flag = null) {
    if (!flag && ("caller" in getroottable())) flag = caller;
    ::flagspawn._HandleReturnEvent(null, flag);
};

::flagspawn.OnPoolFlagCapture <- function(flag = null, player = null) {
    if (!flag && ("caller" in getroottable())) flag = caller;
    if (!player && ("activator" in getroottable())) player = activator;
    ::flagspawn._HandleCaptureEvent(player, flag);
};

// ------------------------------------------------------------
// Spawner touch
// ------------------------------------------------------------
::flagspawn.OnSpawnerTouch <- function(activator, teamParam) {
    local player = activator;
    if (!::flagspawn._IsPlayer(player)) return;

    local requested = ::flagspawn._ParseInt(teamParam, 0);
    if (requested != ::flagspawn.TEAM_RED && requested != ::flagspawn.TEAM_BLU) {
        ::flagspawn.Log("OnSpawnerTouch DENY: bad teamParam");
        return;
    }

    local now = ::flagspawn._Now();
    local peidx = ::flagspawn._EntIndex(player);
    if (peidx in ::flagspawn.State.NextDispenseAt && ::flagspawn.State.NextDispenseAt[peidx] > now) return;
    ::flagspawn.State.NextDispenseAt[peidx] <- now + ::flagspawn.CFG.DISPENSE_COOLDOWN;

    local spawnTeam = ::flagspawn._OppTeam(requested);
    local flag = ::flagspawn._TakeNextFromPool(spawnTeam);
    if (!flag) {
        ::flagspawn.Log("OnSpawnerTouch DENY: pool empty for spawnTeam=" + spawnTeam);
        return;
    }

    local data = ::flagspawn._EnsureFlagData(flag);
    if (!data) return;

    data.pool_team = spawnTeam;
    data.beneficiary_team = player.GetTeam();
    data.no_return = false;

    // Reset and enable
    EntFireByHandle(flag, "ClearParent", "", 0.0, null, null);
    EntFireByHandle(flag, "Enable", "", 0.0, null, null);

    // PD setup
    try { flag.__KeyValueFromInt("GameType", 6); } catch(e0) {}
    try { flag.__KeyValueFromInt("gametype", 6); } catch(e1) {}
    try { flag.__KeyValueFromInt("ReturnTime", ::flagspawn.CFG.RETURN_DELAY); } catch(e2) {}

    local val = ::flagspawn.GetClassBonus(player);
    ::flagspawn._SetFlagValue(flag, val);

    // Place near player for touch pickup
    local org = null;
    try { org = player.GetAbsOrigin(); } catch(e3) { org = Vector(0,0,0); }
    local fwd = null;
    try { fwd = player.GetForwardVector(); } catch(e4) { fwd = Vector(1,0,0); }
    local spawnPos = org + fwd * ::flagspawn.CFG.DISPENSE_FWD + Vector(0,0, ::flagspawn.CFG.DISPENSE_UP);

    try { flag.SetAbsOrigin(spawnPos); } catch(e5) {}
    try { EntFireByHandle(flag, "Teleport", "" + spawnPos.x + " " + spawnPos.y + " " + spawnPos.z, 0.0, null, null); } catch(e6) {}
    try { EntFireByHandle(flag, "TouchTest", "", 0.0, player, player); } catch(e7) {}

    data.state = "dropped";
    data.return_deadline = ::flagspawn._Now() + ::flagspawn.CFG.RETURN_DELAY;
    ::flagspawn._AttachMeterToFlag(flag, data);
    ::flagspawn._WriteFlagScope(flag, data);

    local ps = ::flagspawn._PS(player);
    if (ps) {
        ps.last_spawn_flag = flag.entindex();
        ps.last_spawn_time = ::flagspawn._Now();
    }

    ::flagspawn.Log("DISPENSE: team=" + spawnTeam + " flag=" + ::flagspawn._SafeName(flag) + " PointsValue=" + val);
};

// ------------------------------------------------------------
// Think: return timer + meter sanity
// ------------------------------------------------------------
::flagspawn._Think <- function() {
    local now = ::flagspawn._Now();

    foreach (ei, data in ::flagspawn.State.Flags) {
        local flag = null;
        try { flag = EntIndexToHScript(ei); } catch(e0) { flag = null; }
        if (!flag || !flag.IsValid()) continue;

        if (data.state == "dropped" && !data.no_return && data.return_deadline != null && now >= data.return_deadline) {
            ::flagspawn._ReturnFlag(flag, "returned");
        }

        if (::flagspawn.CFG.ENABLE_METER) {
            local meter = ::flagspawn._EnsureMeter(flag, data);
            if (meter) ::flagspawn._SetBodygroupValue(meter, data.value);
        }
    }

    return 0.25;
};

// ------------------------------------------------------------
// Game event fallback (optional)
// ------------------------------------------------------------
::flagspawn.OnGameEvent_teamplay_flag_event <- function(params) {
    local et = -1;
    if ("eventtype" in params) et = ::flagspawn._ParseInt(params.eventtype, -1);
    if (et < 0) return;

    local player = null;
    if ("player" in params) {
        local id = ::flagspawn._ParseInt(params.player, -1);
        if (id > 0) {
            try { player = GetPlayerFromUserID(id); } catch(e0) { player = null; }
            if (!player) { try { player = EntIndexToHScript(id); } catch(e1) { player = null; } }
        }
    }

    local flag = null;
    if ("flagname" in params) flag = Entities.FindByName(null, params.flagname);

    ::flagspawn._HandleTeamplayFlagEvent(et, player, flag);
};

// ------------------------------------------------------------
// Debug
// ------------------------------------------------------------
::flagspawn.DebugListFlags <- function() {
    foreach (ei, data in ::flagspawn.State.Flags) {
        local flag = null;
        try { flag = EntIndexToHScript(ei); } catch(e0) { flag = null; }
        ::flagspawn.Log("FLAG: " + ei + " state=" + data.state + " value=" + data.value + " flag=" + ::flagspawn._SafeName(flag));
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
    ::flagspawn.Log("LOADED PD core @ t=" + Time());
    try { PrecacheModel(::flagspawn.CFG.METER_MODEL); } catch(e0) {}
    ::flagspawn._InitPool();
    ::flagspawn.RegisterEvents();
    AddThinkToEnt(Entities.First(), "flagspawn._Think");
    ::flagspawn.Log("READY. ReturnTime=" + ::flagspawn.CFG.RETURN_DELAY + "s");
};

::flagspawn.Init();

// Hammer may call plain Init() in script scope
Init <- function() { ::flagspawn.Init(); };
