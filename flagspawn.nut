// ============================================================
// flagspawn_pd_v5.nut
// ------------------------------------------------------------
// Pivot: Use Player Destruction (PD) HUD + scoring style, NOT CTF briefcase overlay.
// Key insight: In PD, item_teamflag supports a PointsValue keyvalue that drives the
// carried-pickup amount shown on PD HUD. citeturn5search1turn5search18
//
// v5 changes vs prior builds:
// - When dispensing a pooled item_teamflag, we set its PointsValue (class bonus).
// - We STOP caring about CTF-style large overlay; we only verify pickup via owner
//   best-effort so "one per life" gates AFTER a successful pickup.
// - Bank logic is left to your map (func_capturezone + tf_logic_player_destruction).
//   This script only dispenses pickups + manages drop worldtext + spawner glows.
// - Dropped integer: point_worldtext (cannot glow through walls; flag already can).
//   tf_glow works on studiomodels, not point_worldtext. citeturn0search3
//
// Requirements in VMF (you mostly already have):
// - A tf_logic_player_destruction (you have fs_pd_logic).
// - func_capturezone set up for PD (optional if you do custom banking).
// - 25 pooled item_teamflag per team named fs_pool_red_01..25 and fs_pool_blu_01..25.
//
// Hammer triggers call:
//   OnSpawnerTouch( !activator, <teamParam> )
//   where teamParam is the trigger's own team (2 or 3). We SWAP inside:
//     teamParam 2 -> dispenses BLU pool flag (3)
//     teamParam 3 -> dispenses RED pool flag (2)
//
// ============================================================


// ---- ROOT TABLE SETUP (MUST BE FIRST) ----
local rt = getroottable();
if (!("flagspawn" in rt)) rt["flagspawn"] <- {};
::flagspawn <- rt["flagspawn"];

// ------------------------------------------------------------
// Config
// ------------------------------------------------------------
::flagspawn.TEAM_RED <- 2;
::flagspawn.TEAM_BLU <- 3;

::flagspawn.DEBUG <- true;

::flagspawn.POOL_PER_TEAM <- 25;
::flagspawn.POOL_NAME_RED_PREFIX <- "fs_pool_red_";
::flagspawn.POOL_NAME_BLU_PREFIX <- "fs_pool_blu_";
::flagspawn.POOL_HIDE_ORIGIN <- Vector(0, 0, -8000);

// Return delay for dropped flags (seconds)
::flagspawn.RETURN_TIME_SECONDS <- 60.0;

// One-per-life gate
::flagspawn.SPAWNER_TOUCH_COOLDOWN <- 0.35;
::flagspawn.ENABLE_ONE_PER_LIFE <- false; // disable for merge testing
::flagspawn.ENABLE_PENDING_GUARD <- false;
::flagspawn.ENABLE_DROPITEM_HOOK <- true; // hook dropitem to enforce a real PD drop when needed
::flagspawn.ENABLE_FORCE_DROPPED_STATE <- true; // ensure dispensed flags are in dropped PD state
::flagspawn.ENABLE_FORCE_PICKUPABLE <- true; // ensure neutral PD pickup state when dispensing
::flagspawn.ENABLE_MANUAL_STACK <- false; // prefer engine PD merge when false
::flagspawn.ENABLE_FRESH_PICKUP_ON_CARRY <- true; // spawn fresh PD pickup when already carrying

// Pickup verification (best-effort; PD uses different HUD, but owner should still become player)
::flagspawn.PICKUP_RETRY_COUNT <- 12;
::flagspawn.PICKUP_RETRY_INTERVAL <- 0.10;

// Dropped worldtext above flags
::flagspawn.ENABLE_DROP_WORLDTEXT <- true;
::flagspawn.WORLDTEXT_Z <- 44;
::flagspawn.WORLDTEXT_SCALE <- 7;
::flagspawn.WORLDTEXT_ORIENTATION <- 1;
::flagspawn.WORLDTEXT_COLOR <- "255 255 255";

// Flag visual stand-in (parented prop_dynamic + tf_glow)
::flagspawn.FLAG_VISUAL_ENABLED <- true;
::flagspawn.FLAG_VISUAL_MODEL <- "models/props_rocks/rock005.mdl";
::flagspawn.FLAG_VISUAL_SCALE <- 0.1;
::flagspawn.FLAG_VISUAL_LOCAL_OFFSET <- Vector(0,0,0);
::flagspawn.FLAG_GLOW_RED <- "255 64 64";
::flagspawn.FLAG_GLOW_BLU <- "64 128 255";
::flagspawn.FLAG_GLOW_NEUTRAL <- "255 255 255";

// Spawner glows via tf_glow on props named fs_spawner_*
::flagspawn.ENABLE_SPAWNER_GLOW <- true;
::flagspawn.SPAWNER_NAME_PREFIX <- "fs_spawner_";

// ------------------------------------------------------------
// Logging + helpers
// ------------------------------------------------------------
::flagspawn.Log <- function(s) { printl("[flagspawn] " + s); };

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
    if (org) return org;
    try { org = NetProps.GetPropVector(ent, "m_vecAbsOrigin"); } catch(e3) { org = null; }
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

::flagspawn._HideFlagModel <- function(flag) {
    if (!flag) return;
    // EF_NODRAW
    try { flag.AddEffects(32); } catch(e) {}
    try { flag.__KeyValueFromInt("rendermode", 10); } catch(e2) {}
    try { flag.__KeyValueFromInt("renderamt", 0); } catch(e3) {}
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
        default: return 1; // everyone else
    }
};

// ------------------------------------------------------------
// PD PointsValue on item_teamflag
// ------------------------------------------------------------
::flagspawn._SetFlagPointsValue <- function(flag, v) {
    if (!flag) return;

    // Store for our own worldtext display
    try { flag.ValidateScriptScope(); flag.GetScriptScope().fs_value <- v; } catch(e) {}

    // PD: try to set the networked point value (what the PD HUD/merge logic usually reads)
    try { NetProps.SetPropInt(flag, "m_nPointValue", v); } catch(eN) {}
    try { NetProps.SetPropInt(flag, "m_iPointValue", v); } catch(eN2) {}

    // Also write common keyvalues (harmless fallback)
    try { flag.__KeyValueFromInt("PointsValue", v); } catch(e2) {}
    try { flag.__KeyValueFromInt("pointsvalue", v); } catch(e3) {}
};

::flagspawn._GetFlagPointsValue <- function(flag) {
    if (!flag) return 0;
    local vNet = null;
    try { vNet = NetProps.GetPropInt(flag, "m_nPointValue"); } catch(e0) { vNet = null; }
    if (vNet == null) {
        try { vNet = NetProps.GetPropInt(flag, "m_iPointValue"); } catch(e1) { vNet = null; }
    }
    if (vNet != null) {
        try {
            flag.ValidateScriptScope();
            local ssn = flag.GetScriptScope();
            ssn.fs_value <- vNet;
        } catch(e2) {}
        return vNet;
    }
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        if ("fs_value" in ss) return ss.fs_value.tointeger();
    } catch(e3) {}
    // fallback to 1
    return 1;
};

// ------------------------------------------------------------
// ------------------------------------------------------------
// Carry detection (owner)
// ------------------------------------------------------------
::flagspawn._FlagOwner <- function(flag) {
    if (!flag) return null;
    local owner = null;
    try { owner = NetProps.GetPropEntity(flag, "m_hOwnerEntity"); } catch(e) { owner = null; }
    return owner;
};

::flagspawn._IsFlagCarriedBy <- function(flag, player) {
    if (!flag || !player) return false;
    local owner = ::flagspawn._FlagOwner(flag);
    if (owner == player) return true;
    local parent = null;
    try { parent = flag.GetMoveParent(); } catch(e2) { parent = null; }
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
// Player state
// ------------------------------------------------------------
::flagspawn._ps <- {};

::flagspawn._PS <- function(player) {
    local k = 0;
    try { k = player.entindex(); } catch(e) { k = 0; }
    if (!(k in ::flagspawn._ps)) {
        ::flagspawn._ps[k] <- {
            used_this_life = false,
            last_spawner_touch = -9999.0,
            pending_flag_eidx = -1
        };
    }
    return ::flagspawn._ps[k];
};

// ------------------------------------------------------------
// Pool
// ------------------------------------------------------------
::flagspawn._Pool <- { red = [], blu = [], red_i = 0, blu_i = 0 };

::flagspawn._FindByName <- function(name) {
    local f = null;
    try { f = Entities.FindByName(null, name); } catch(e) { f = null; }
    return f;
};

::flagspawn._ApplyReturnTime <- function(flag) {
    if (!flag) return;
    local rt = ::flagspawn.RETURN_TIME_SECONDS;
    try { flag.__KeyValueFromInt("ReturnTime", rt); } catch(e) {}
    try { flag.__KeyValueFromInt("returntime", rt); } catch(e2) {}
    try { EntFireByHandle(flag, "SetReturnTime", "" + rt, 0, null, null); } catch(e3) {}
};

::flagspawn._HideFlag <- function(flag) {
    if (!flag) return;
    try { flag.SetAbsOrigin(::flagspawn.POOL_HIDE_ORIGIN); } catch(e) {}
    try { EntFireByHandle(flag, "ForceReset", "", 0, null, null); } catch(e2) {}
};

::flagspawn._ForceEnableFlag <- function(flag) {
    if (!flag) return;

    try { EntFireByHandle(flag, "Enable", "", 0, null, null); } catch(e0) {}
    try { EntFireByHandle(flag, "TurnOn", "", 0, null, null); } catch(e00) {}

    // Clear common "disabled" flags
    local props_bool = ["m_bDisabled", "m_bStartDisabled", "m_bDisabledBecauseNoPlayers"];
    foreach (p in props_bool) {
        try { NetProps.SetPropBool(flag, p, false); } catch(e1) {}
        try { NetProps.SetPropInt(flag, p, 0); } catch(e2) {}
    }

    // NOTE: we intentionally do NOT clear NODRAW here; our visuals use a separate proxy model.
};


// ------------------------------------------------------------
// Script scheduling
// NOTE: RunScriptCode must be fired on the logic_script (scripter), not on players.
// ------------------------------------------------------------
::flagspawn.SCRIPTER_NAME <- "scripter";

::flagspawn._GetScripter <- function() {
    local s = null;
    try { s = Entities.FindByName(null, ::flagspawn.SCRIPTER_NAME); } catch(e) { s = null; }
    return s;
};

::flagspawn._FireScriptCode <- function(delay, code) {
    local s = ::flagspawn._GetScripter();
    if (!s) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("WARN: no logic_script named '" + ::flagspawn.SCRIPTER_NAME + "' to RunScriptCode");
        return;
    }
    try { EntFireByHandle(s, "RunScriptCode", code, delay, null, null); } catch(e) {}
};

// ------------------------------------------------------------
// Pool detach (fixes flags snapping back to pool storage coords)
// ------------------------------------------------------------
::flagspawn._DetachFromPool <- function(flag) {
    if (!flag) return;

    // Break parent hierarchy link
    try { flag.SetParent(null, ""); } catch(e0) {}
    try { EntFireByHandle(flag, "ClearParent", "", 0.0, null, null); } catch(e1) {}

    // Clear keyvalue too (prevents re-parent on think)
    try { flag.__KeyValueFromString("parentname", ""); } catch(e2) {}

    // Kill inherited motion
    try { flag.SetAbsVelocity(Vector(0,0,0)); } catch(e3) {}
};

::flagspawn._ForceDroppedState <- function(flag) {
    if (!flag) return;
    try { NetProps.SetPropEntity(flag, "m_hOwnerEntity", null); } catch(e0) {}
    try { NetProps.SetPropEntity(flag, "m_hPrevOwner", null); } catch(e1) {}
    try { NetProps.SetPropInt(flag, "m_nFlagStatus", 2); } catch(e2) {} // 2 = dropped (best effort)
    try { NetProps.SetPropFloat(flag, "m_flResetTime", 0.0); } catch(e3) {}
};

::flagspawn._MakeFlagPickupable <- function(flag, player) {
    if (!flag) return;
    // PD pickups are neutral; force team 0 so any player can collect.
    try { flag.SetTeam(0); } catch(e0) {}
    try { NetProps.SetPropInt(flag, "m_iTeamNum", 0); } catch(e1) {}
    try { NetProps.SetPropInt(flag, "m_iOriginalTeamNum", 0); } catch(e2) {}
    try { flag.__KeyValueFromInt("TeamNum", 0); } catch(e3) {}
    try { flag.__KeyValueFromInt("teamnum", 0); } catch(e4) {}
    try { EntFireByHandle(flag, "ForceDrop", "", 0.0, player, player); } catch(e5) {}
};

::flagspawn._MakeFlagNeutral <- function(flag) {
    if (!flag) return;
    try { flag.SetTeam(0); } catch(e0) {}
    try { NetProps.SetPropInt(flag, "m_iTeamNum", 0); } catch(e1) {}
    try { NetProps.SetPropInt(flag, "m_iOriginalTeamNum", 0); } catch(e2) {}
    try { flag.__KeyValueFromInt("TeamNum", 0); } catch(e3) {}
    try { flag.__KeyValueFromInt("teamnum", 0); } catch(e4) {}
};

::flagspawn._SpawnFreshPickupAtPlayer <- function(player, value) {
    if (!player) return null;
    local pos = ::flagspawn._GetEntOrigin(player);
    if (!pos) pos = Vector(0,0,0);
    local spawnPos = pos + Vector(0,0,2);

    local f = null;
    try {
        f = SpawnEntityFromTable("item_teamflag", {
            TeamNum = 0,
            GameType = 4,
            NeutralType = 1,
            ReturnBetweenWaves = 1,
            ReturnTime = ::flagspawn.RETURN_TIME_SECONDS,
            origin = spawnPos
        });
    } catch(e0) { f = null; }

    if (!f) return null;

    ::flagspawn._SetFlagPointsValue(f, value);
    ::flagspawn._ForceDroppedState(f);
    ::flagspawn._MakeFlagNeutral(f);
    ::flagspawn._EnsureFlagVisual(f);
    ::flagspawn._ReconcileWorldtexts();
    return f;
};

::flagspawn._CollectCarriedFlags <- function(player) {
    local out = [];
    if (!player) return out;
    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        if (::flagspawn._IsFlagCarriedBy(f, player)) out.append(f);
    }
    return out;
};

::flagspawn._MergeCarriedFlags <- function(player) {
    local flags = ::flagspawn._CollectCarriedFlags(player);
    if (flags.len() <= 1) return;

    local primary = flags[0];
    local total = 0;
    foreach (f in flags) total += ::flagspawn._GetFlagPointsValue(f);

    for (local i = 1; i < flags.len(); i++) {
        local f2 = flags[i];
        ::flagspawn._ForceDroppedState(f2);
        ::flagspawn._MakeFlagNeutral(f2);
        ::flagspawn._HideFlag(f2);
        ::flagspawn._KillWorldtextForFlag(f2);
    }

    ::flagspawn._SetFlagPointsValue(primary, total);
    ::flagspawn._EnsureFlagVisual(primary);
    ::flagspawn._ReconcileWorldtexts();
};


::flagspawn._InitPool <- function() {
    ::flagspawn._Pool.red.clear();
    ::flagspawn._Pool.blu.clear();
    ::flagspawn._Pool.red_i = 0;
    ::flagspawn._Pool.blu_i = 0;

    for (local i = 1; i <= ::flagspawn.POOL_PER_TEAM; i++) {
        local idx = (i < 10) ? ("0" + i) : ("" + i);
        local rn = ::flagspawn.POOL_NAME_RED_PREFIX + idx;
        local bn = ::flagspawn.POOL_NAME_BLU_PREFIX + idx;

        local rf = ::flagspawn._FindByName(rn);
        local bf = ::flagspawn._FindByName(bn);

        if (rf) { ::flagspawn._ApplyReturnTime(rf); ::flagspawn._HideFlag(rf); ::flagspawn._Pool.red.append(rf); }
        else if (::flagspawn.DEBUG) ::flagspawn.Log("POOL WARN: missing " + rn);

        if (bf) { ::flagspawn._ApplyReturnTime(bf); ::flagspawn._HideFlag(bf); ::flagspawn._Pool.blu.append(bf); }
        else if (::flagspawn.DEBUG) ::flagspawn.Log("POOL WARN: missing " + bn);
    }

    ::flagspawn.Log("Pool init: red=" + ::flagspawn._Pool.red.len() + " blu=" + ::flagspawn._Pool.blu.len());
};

::flagspawn._TakeNextFromPool <- function(team) {
    if (team == ::flagspawn.TEAM_RED) {
        if (::flagspawn._Pool.red.len() <= 0) return null;
        local f = ::flagspawn._Pool.red[::flagspawn._Pool.red_i % ::flagspawn._Pool.red.len()];
        ::flagspawn._Pool.red_i++;
        return f;
    }
    if (team == ::flagspawn.TEAM_BLU) {
        if (::flagspawn._Pool.blu.len() <= 0) return null;
        local f2 = ::flagspawn._Pool.blu[::flagspawn._Pool.blu_i % ::flagspawn._Pool.blu.len()];
        ::flagspawn._Pool.blu_i++;
        return f2;
    }
    return null;
};

// ------------------------------------------------------------
// Dropped worldtext (value) -- does NOT glow through walls; flag glow is separate. citeturn0search3
// ------------------------------------------------------------
::flagspawn._wt_by_flag <- {};

::flagspawn._KillWorldtextForFlag <- function(flag) {
    if (!flag) return;
    local fe = -1;
    try { fe = flag.entindex(); } catch(e) { return; }
    if (!(fe in ::flagspawn._wt_by_flag)) return;

    local wt = null;
    try { wt = EntIndexToHScript(::flagspawn._wt_by_flag[fe]); } catch(e2) { wt = null; }
    if (wt) { try { EntFireByHandle(wt, "Kill", "", 0, null, null); } catch(e3) {} }
    delete ::flagspawn._wt_by_flag[fe];
};

::flagspawn._IsFlagHiddenInPool <- function(flag) {
    if (!flag) return true;
    local org = null;
    try { org = flag.GetAbsOrigin(); } catch(e) { org = null; }
    if (!org) return true;
    return org.z < -7000;
};

::flagspawn._IsFlagDropped <- function(flag) {
    if (!flag) return false;
    if (::flagspawn._IsFlagHiddenInPool(flag)) return false;
    if (::flagspawn._FlagOwner(flag) != null) return false;
    return true;
};

::flagspawn._EnsureWorldtextForFlag <- function(flag) {
    if (!::flagspawn.ENABLE_DROP_WORLDTEXT) return;
    if (!flag) return;

    if (!::flagspawn._IsFlagDropped(flag)) { ::flagspawn._KillWorldtextForFlag(flag); return; }

    local fe = flag.entindex();
    local wt = null;

    if (fe in ::flagspawn._wt_by_flag) {
        try { wt = EntIndexToHScript(::flagspawn._wt_by_flag[fe]); } catch(e2) { wt = null; }
    }

    if (!wt) {
        wt = Entities.CreateByClassname("point_worldtext");
        if (!wt) { ::flagspawn.Log("WARN: could not create point_worldtext"); return; }

        try { wt.__KeyValueFromInt("orientation", ::flagspawn.WORLDTEXT_ORIENTATION); } catch(e3) {}
        try { wt.__KeyValueFromInt("textsize", ::flagspawn.WORLDTEXT_SCALE); } catch(e4) {}
        try { wt.__KeyValueFromString("color", ::flagspawn.WORLDTEXT_COLOR); } catch(e5) {}
        try { wt.__KeyValueFromString("message", ""); } catch(e6) {}

        try { wt.SetParent(flag, ""); } catch(e8) {}
        try { wt.SetLocalOrigin(Vector(0,0,::flagspawn.WORLDTEXT_Z)); } catch(e9) {}

        ::flagspawn._wt_by_flag[fe] <- wt.entindex();
        if (::flagspawn.DEBUG) ::flagspawn.Log("WORLDTEXT CREATE for " + ::flagspawn._SafeName(flag));
    }

    local msg = "" + ::flagspawn._GetFlagPointsValue(flag);
    try { wt.__KeyValueFromString("message", msg); } catch(e10) {}
};

::flagspawn._ReconcileWorldtexts <- function() {
    if (!::flagspawn.ENABLE_DROP_WORLDTEXT) return;
    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        ::flagspawn._EnsureWorldtextForFlag(f);
    }
};

// ------------------------------------------------------------
// Flag visual stand-in (prop_dynamic + tf_glow)
// ------------------------------------------------------------
::flagspawn._GlowColorForTeam <- function(t) {
    if (t == ::flagspawn.TEAM_RED) return ::flagspawn.FLAG_GLOW_RED;
    if (t == ::flagspawn.TEAM_BLU) return ::flagspawn.FLAG_GLOW_BLU;
    return ::flagspawn.FLAG_GLOW_NEUTRAL;
};

::flagspawn._GlowColorForFlag <- function(flag) {
    if (!flag) return ::flagspawn.FLAG_GLOW_NEUTRAL;
    local owner = ::flagspawn._FlagOwner(flag);
    local t = owner ? ::flagspawn._GetTeamNum(owner) : ::flagspawn._GetTeamNum(flag);
    return ::flagspawn._GlowColorForTeam(t);
};

::flagspawn._EnsureFlagVisual <- function(flag) {
    if (!::flagspawn.FLAG_VISUAL_ENABLED || !flag) return;

    ::flagspawn._HideFlagModel(flag);

    try { flag.ValidateScriptScope(); } catch(e0) {}
    local ss = null;
    try { ss = flag.GetScriptScope(); } catch(e1) { ss = null; }
    if (!ss) return;

    if ("fs_vis_eidx" in ss) {
        local vis = null;
        try { vis = EntIndexToHScript(ss.fs_vis_eidx); } catch(e2) { vis = null; }
        if (vis) {
            ::flagspawn._UpdateFlagVisual(flag, vis);
            return;
        }
    }

    local nm = "fs_flagvis_" + flag.entindex();
    local vis2 = null;
    try {
        vis2 = SpawnEntityFromTable("prop_dynamic", {
            targetname = nm,
            model = ::flagspawn.FLAG_VISUAL_MODEL,
            modelscale = ::flagspawn.FLAG_VISUAL_SCALE,
            origin = flag.GetAbsOrigin(),
            angles = flag.GetAbsAngles(),
            solid = 0,
            disableshadows = 1
        });
    } catch(e3) { vis2 = null; }

    if (!vis2) {
        try {
            vis2 = Entities.CreateByClassname("prop_dynamic");
            if (vis2) {
                try { vis2.__KeyValueFromString("targetname", nm); } catch(e) {}
                try { vis2.__KeyValueFromString("model", ::flagspawn.FLAG_VISUAL_MODEL); } catch(e2) {}
                try { vis2.__KeyValueFromFloat("modelscale", ::flagspawn.FLAG_VISUAL_SCALE); } catch(e2b) {}
                try { vis2.__KeyValueFromInt("solid", 0); } catch(e3) {}
                try { vis2.__KeyValueFromInt("disableshadows", 1); } catch(e4) {}
                try { vis2.SetAbsOrigin(flag.GetAbsOrigin()); } catch(e5) {}
                try { vis2.SetAbsAngles(flag.GetAbsAngles()); } catch(e6) {}
                try { DispatchSpawn(vis2); } catch(e7) {}
            }
        } catch(e8) { vis2 = null; }
    }

    if (!vis2) return;

    try { vis2.SetParent(flag, ""); } catch(e4) {}
    try { vis2.SetLocalOrigin(::flagspawn.FLAG_VISUAL_LOCAL_OFFSET); } catch(e5) {}

    local g = null;
    try {
        g = Entities.CreateByClassname("tf_glow");
        if (g) {
            try { g.__KeyValueFromString("target", nm); } catch(e6a) {}
            try { g.__KeyValueFromInt("mode", 0); } catch(e6b) {}
            try { g.__KeyValueFromString("glowcolor", ::flagspawn._GlowColorForFlag(flag)); } catch(e6c) {}
            try { DispatchSpawn(g); } catch(e6d) {}
        }
    } catch(e6) { g = null; }

    if (g) {
        try { g.SetParent(vis2, ""); } catch(e7) {}
        ss.fs_glow_eidx <- g.entindex();
    }

    ss.fs_vis_eidx <- vis2.entindex();

    ::flagspawn._UpdateFlagVisual(flag, vis2);
};

::flagspawn._UpdateFlagVisual <- function(flag, vis) {
    if (!flag || !vis) return;

    ::flagspawn._HideFlagModel(flag);

    local ss = null;
    try { flag.ValidateScriptScope(); ss = flag.GetScriptScope(); } catch(e) { ss = null; }
    if (ss && ("fs_glow_eidx" in ss)) {
        local g2 = null;
        try { g2 = EntIndexToHScript(ss.fs_glow_eidx); } catch(e2) { g2 = null; }
        if (g2) {
            local c = ::flagspawn._GlowColorForFlag(flag);
            try { g2.__KeyValueFromString("glowcolor", c); } catch(e3) {}
        }
    }
};

::flagspawn._ReconcileFlagVisuals <- function() {
    if (!::flagspawn.FLAG_VISUAL_ENABLED) return;
    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        if (::flagspawn._IsFlagHiddenInPool(f)) continue;
        ::flagspawn._EnsureFlagVisual(f);
    }
};

// ------------------------------------------------------------
// Spawner glows via tf_glow (only for studiomodel props) citeturn0search3
// ------------------------------------------------------------
::flagspawn._glow_by_prop <- {};

::flagspawn._CreateGlowForProp <- function(prop) {
    if (!::flagspawn.ENABLE_SPAWNER_GLOW || !prop) return;
    local pe = prop.entindex();
    if (pe in ::flagspawn._glow_by_prop) return;

    local pname = "";
    try { pname = prop.GetName(); } catch(e) { pname = ""; }
    if (pname == null || pname == "") return;

    local g = Entities.CreateByClassname("tf_glow");
    if (!g) return;

    try { g.__KeyValueFromString("target", pname); } catch(e2) {}
    try { g.__KeyValueFromInt("mode", 0); } catch(e3) {}
    try { g.__KeyValueFromString("glowcolor", "255 255 255"); } catch(e4) {}

    ::flagspawn._glow_by_prop[pe] <- g.entindex();
};

::flagspawn._InitSpawnerGlows <- function() {
    if (!::flagspawn.ENABLE_SPAWNER_GLOW) return;

    local p = null;
    while ((p = Entities.FindByClassname(p, "prop_dynamic")) != null) {
        local nm = ""; try { nm = p.GetName(); } catch(e) { nm = ""; }
        if (nm && nm.len() > 0 && nm.tolower().find(::flagspawn.SPAWNER_NAME_PREFIX) == 0) ::flagspawn._CreateGlowForProp(p);
    }

    p = null;
    while ((p = Entities.FindByClassname(p, "prop_dynamic_override")) != null) {
        local nm2 = ""; try { nm2 = p.GetName(); } catch(e2) { nm2 = ""; }
        if (nm2 && nm2.len() > 0 && nm2.tolower().find(::flagspawn.SPAWNER_NAME_PREFIX) == 0) ::flagspawn._CreateGlowForProp(p);
    }
};

// ------------------------------------------------------------
// Dispense + pickup verify
// ------------------------------------------------------------
::flagspawn._NudgeForPickup <- function(flag, player) {
    if (!flag || !player) return;

    if (::flagspawn.DEBUG) {
        ::flagspawn.Log("NUDGE CALL: flag=" + ::flagspawn._SafeName(flag) + " player=" + ::flagspawn._SafeName(player));
    }

    ::flagspawn._ForceEnableFlag(flag);
    ::flagspawn._DetachFromPool(flag);
    if (::flagspawn.ENABLE_FORCE_DROPPED_STATE) ::flagspawn._ForceDroppedState(flag);
    if (::flagspawn.ENABLE_FORCE_PICKUPABLE) ::flagspawn._MakeFlagNeutral(flag);

    local pos = Vector(0,0,0);
    local fwd = Vector(1,0,0);
    local porg = ::flagspawn._GetEntOrigin(player);
    if (porg) pos = porg;
    try { local ang = player.EyeAngles(); fwd = ang.Forward(); } catch(e2) {}

    if (::flagspawn.DEBUG) {
        ::flagspawn.Log("NUDGE BASE: pos=" + ::flagspawn._VecStr(pos) + " fwd=" + ::flagspawn._VecStr(fwd));
    }

    // Put it at the player's feet to force a real touch pickup
    local spawnPos = pos + Vector(0,0,2);
    try { flag.SetAbsOrigin(spawnPos); } catch(e3) {}
    try { EntFireByHandle(flag, "Teleport", ::flagspawn._VecStr(spawnPos), 0.0, null, null); } catch(e4) {}
    try { flag.SetAbsVelocity(Vector(0,0,0)); } catch(e5) {}
    try { NetProps.SetPropVector(flag, "m_vecResetPos", spawnPos); } catch(e6) {}

    if (::flagspawn.DEBUG) {
        local fp = ::flagspawn._GetEntOrigin(flag);
        local pp = ::flagspawn._GetEntOrigin(player);
        if (fp && pp) {
            local dx = fp.x - pp.x;
            local dy = fp.y - pp.y;
            local dz = fp.z - pp.z;
            local dist = sqrt((dx*dx) + (dy*dy) + (dz*dz));
            ::flagspawn.Log("NUDGE: flag@" + ::flagspawn._VecStr(fp) + " player@" + ::flagspawn._VecStr(pp) + " dist=" + dist);
        } else {
            ::flagspawn.Log("NUDGE: missing origin flag=" + (fp ? "ok" : "null") + " player=" + (pp ? "ok" : "null"));
        }
    }

    // If already carrying, let physics touch drive merge instead of forcing TouchTest.
    local carrying = ::flagspawn._ResolveCarriedFlag(player);
    if (!carrying || carrying == flag) {
        try { EntFireByHandle(flag, "TouchTest", "", 0.0, player, player); } catch(e8) {}
    }
};

::flagspawn._StartVerifyPickup <- function(player, flag, attempt) {
    if (!player || !flag) return;

    if (::flagspawn._IsFlagCarriedBy(flag, player)) {
        local ps = ::flagspawn._PS(player);
        if (::flagspawn.ENABLE_ONE_PER_LIFE) ps.used_this_life = true;
        if (::flagspawn.ENABLE_PENDING_GUARD) ps.pending_flag_eidx = -1;
        ::flagspawn._KillWorldtextForFlag(flag);
        ::flagspawn._MergeCarriedFlags(player);
        if (::flagspawn.DEBUG) ::flagspawn.Log("PICKUP VERIFIED: " + ::flagspawn._SafeName(player) + " owns " + ::flagspawn._SafeName(flag));
        return;
    }

    if (attempt >= ::flagspawn.PICKUP_RETRY_COUNT) {
        local ps2 = ::flagspawn._PS(player);
        if (::flagspawn.ENABLE_PENDING_GUARD) ps2.pending_flag_eidx = -1; // allow retry
        if (::flagspawn.DEBUG) ::flagspawn.Log("PICKUP FAILED: owner still null after retries; pending cleared; flag left dropped.");
        ::flagspawn._ReconcileWorldtexts();
        return;
    }

    if (::flagspawn.DEBUG) {
        ::flagspawn.Log("NUDGE RETRY " + attempt + ": flag=" + ::flagspawn._SafeName(flag) + " player=" + ::flagspawn._SafeName(player));
    }

    ::flagspawn._NudgeForPickup(flag, player);

    local code = "if (::flagspawn != null) ::flagspawn._VerifyPickup(" + player.entindex() + "," + flag.entindex() + "," + (attempt+1) + ");";
    ::flagspawn._FireScriptCode(::flagspawn.PICKUP_RETRY_INTERVAL, code);
};

::flagspawn._VerifyPickup <- function(playerEidx, flagEidx, attempt) {
    local player = null;
    local flag = null;
    try { player = EntIndexToHScript(playerEidx); } catch(e) { player = null; }
    try { flag = EntIndexToHScript(flagEidx); } catch(e2) { flag = null; }
    if (!player || !flag) return;

    if (::flagspawn.DEBUG) {
        local owner = ::flagspawn._FlagOwner(flag);
        ::flagspawn.Log("PICKUP RETRY " + attempt + ": owner=" + ::flagspawn._SafeName(owner) + " flag=" + ::flagspawn._SafeName(flag));
    }
    ::flagspawn._StartVerifyPickup(player, flag, attempt);
};

// ------------------------------------------------------------
// Manual drop helper (PD disables dropitem; use this instead)
// ------------------------------------------------------------
::flagspawn.DropCarriedFlag <- function(player) {
    if (!player) return;
    local flag = ::flagspawn._ResolveCarriedFlag(player);
    if (!flag) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("DROP: no carried flag for " + ::flagspawn._SafeName(player));
        return;
    }

    local v = ::flagspawn._GetFlagPointsValue(flag);

    ::flagspawn._ForceEnableFlag(flag);
    ::flagspawn._DetachFromPool(flag);
    ::flagspawn._ForceDroppedState(flag);
    ::flagspawn._MakeFlagPickupable(flag, player);

    local pos = ::flagspawn._GetEntOrigin(player);
    if (!pos) pos = Vector(0,0,0);
    local dropPos = pos + Vector(0,0,2);

    try { flag.SetAbsOrigin(dropPos); } catch(e2) {}
    try { EntFireByHandle(flag, "Teleport", ::flagspawn._VecStr(dropPos), 0.0, null, null); } catch(e3) {}
    try { flag.SetAbsVelocity(Vector(0,0,0)); } catch(e4) {}

    ::flagspawn._SetFlagPointsValue(flag, v);

    ::flagspawn._ReconcileWorldtexts();

    if (::flagspawn.DEBUG) ::flagspawn.Log("DROP: player=" + ::flagspawn._SafeName(player) + " flag=" + ::flagspawn._SafeName(flag));
};

::flagspawn.OnDropTouch <- function(activator) {
    ::flagspawn.DropCarriedFlag(activator);
};

::flagspawn.DebugDropByEidx <- function(playerEidx) {
    local player = null;
    try { player = EntIndexToHScript(playerEidx); } catch(e) { player = null; }
    if (!player) return;
    ::flagspawn.DropCarriedFlag(player);
};

// ------------------------------------------------------------
// Hammer entrypoint: spawner touch
// ------------------------------------------------------------
::flagspawn.OnSpawnerTouch <- function(activator, teamParam) {
    local player = activator;
    if (!player) return;

    local ps = ::flagspawn._PS(player);

    local now = Time();
    if (now - ps.last_spawner_touch < ::flagspawn.SPAWNER_TOUCH_COOLDOWN) return;
    ps.last_spawner_touch = now;

    local requested = 0;
    if (typeof teamParam == "integer") requested = teamParam;
    if (requested != ::flagspawn.TEAM_RED && requested != ::flagspawn.TEAM_BLU) { ::flagspawn.Log("OnSpawnerTouch DENY: bad teamParam"); return; }

    local spawnTeam = ::flagspawn._OppTeam(requested);

    if (::flagspawn.DEBUG) {
        local c = null; try { c = caller; } catch(e) { c = null; }
        ::flagspawn.Log("OnSpawnerTouch activator=" + ::flagspawn._SafeName(player) +
            "(team=" + ::flagspawn._GetTeamNum(player) + ") teamParam=" + requested +
            " -> spawnTeam=" + spawnTeam + " caller=" + ::flagspawn._SafeName(c));
    }

    // If you are already carrying a PD flag, optionally stack manually or spawn a fresh pickup.
    local carried = ::flagspawn._ResolveCarriedFlag(player);
    if (carried && ::flagspawn.ENABLE_MANUAL_STACK) {
        local add = ::flagspawn.GetClassBonus(player);
        local cur = ::flagspawn._GetFlagPointsValue(carried);
        local nxt = cur + add;
        ::flagspawn._SetFlagPointsValue(carried, nxt);
        ::flagspawn.Log("STACK: carried=" + ::flagspawn._SafeName(carried) + " PointsValue " + cur + " -> " + nxt);
        return;
    }
    if (carried && ::flagspawn.ENABLE_FRESH_PICKUP_ON_CARRY) {
        local add2 = ::flagspawn.GetClassBonus(player);
        local fresh = ::flagspawn._SpawnFreshPickupAtPlayer(player, add2);
        ::flagspawn.Log("FRESH PICKUP: val=" + add2 + " ent=" + ::flagspawn._SafeName(fresh));
        return;
    }

    // One-per-life (after a successful pickup)
    if (::flagspawn.ENABLE_ONE_PER_LIFE && ps.used_this_life) { ::flagspawn.Log("OnSpawnerTouch DENY: used_this_life=true (no new flag until next spawn)"); return; }
    if (::flagspawn.ENABLE_PENDING_GUARD && ps.pending_flag_eidx != -1) { ::flagspawn.Log("OnSpawnerTouch DENY: pending flag already dispensed (try picking it up first)"); return; }

    local flag = ::flagspawn._TakeNextFromPool(spawnTeam);
    if (!flag) { ::flagspawn.Log("OnSpawnerTouch DENY: pool empty for spawnTeam=" + spawnTeam); return; }

    ::flagspawn._DetachFromPool(flag);

    local val = ::flagspawn.GetClassBonus(player);
    ::flagspawn._SetFlagPointsValue(flag, val);
    ::flagspawn._ApplyReturnTime(flag);

    ps.pending_flag_eidx = flag.entindex();

    ::flagspawn._NudgeForPickup(flag, player);
    ::flagspawn._StartVerifyPickup(player, flag, 0);

    ::flagspawn.Log("DISPENSE: team=" + spawnTeam + " flag=" + ::flagspawn._SafeName(flag) + " PointsValue=" + val);

    ::flagspawn._ReconcileWorldtexts();
};

// ------------------------------------------------------------
// Events: reset used_this_life on spawn
// ------------------------------------------------------------
::flagspawn.OnGameEvent_player_spawn <- function(params) {
    local player = null;
    if ("userid" in params) { try { player = GetPlayerFromUserID(params.userid); } catch(e) { player = null; } }
    if (!player) return;

    local ps = ::flagspawn._PS(player);
    ps.used_this_life = false;
    ps.pending_flag_eidx = -1;
    ps.last_spawner_touch = -9999.0;

    if (::flagspawn.DEBUG) ::flagspawn.Log("player_spawn: reset used_this_life for " + ::flagspawn._SafeName(player));
};

::flagspawn.OnGameEvent_teamplay_flag_event <- function(params) {
    // Any flag event -> update worldtexts
    ::flagspawn._ReconcileWorldtexts();
};

::flagspawn.OnGameEvent_player_dropitem <- function(params) {
    if (!::flagspawn.ENABLE_DROPITEM_HOOK) return;
    local player = null;
    if ("userid" in params) { try { player = GetPlayerFromUserID(params.userid); } catch(e) { player = null; } }
    if (!player) return;
    local code = "if (::flagspawn != null) ::flagspawn._AfterDropItem(" + player.entindex() + ");";
    ::flagspawn._FireScriptCode(0.05, code);
};

::flagspawn._AfterDropItem <- function(playerEidx) {
    local player = null;
    try { player = EntIndexToHScript(playerEidx); } catch(e) { player = null; }
    if (!player) return;

    // If the engine didn't drop it, force a real PD drop at the player's feet.
    local carried = ::flagspawn._ResolveCarriedFlag(player);
    if (carried) {
        ::flagspawn.DropCarriedFlag(player);
        return;
    }

    // Engine drop succeeded; just refresh visuals/text.
    ::flagspawn._ReconcileWorldtexts();
    ::flagspawn._ReconcileFlagVisuals();
};

// ------------------------------------------------------------
// Think loop
// ------------------------------------------------------------
::flagspawn._Think <- function() {
    ::flagspawn._ReconcileWorldtexts();
    ::flagspawn._ReconcileFlagVisuals();
    return 0.25;
};

// ------------------------------------------------------------
// Init
// ------------------------------------------------------------
::flagspawn.RegisterEvents <- function() {
    try { __CollectGameEventCallbacks(::flagspawn); ::flagspawn.Log("Registered game event callbacks."); }
    catch(e) { ::flagspawn.Log("WARN: Could not register game event callbacks (" + e + ")."); }
};

::flagspawn.Init <- function() {
    ::flagspawn.Log("LOADED PD v5 @ t=" + Time());
    ::flagspawn._InitPool();
    ::flagspawn.RegisterEvents();
    if (::flagspawn.ENABLE_SPAWNER_GLOW) ::flagspawn._InitSpawnerGlows();
    try { AddThinkToEnt(::flagspawn, "_Think"); } catch(e2) { ::flagspawn.Log("WARN: AddThinkToEnt failed (" + e2 + ")"); }

    ::flagspawn.Log("READY. PointsValue is written to dispensed item_teamflag for PD HUD. Heavy=5, Sniper=3, Soldier=2, others=1.");
    ::flagspawn.Log("Note: point_worldtext itself cannot be tf_glow'd; only studiomodel props can. Flag glow is separate. citeturn0search3");
};
::flagspawn.Init();

// ------------------------------------------------------------
// Hammer entrypoint: capture touch (stub)
// ------------------------------------------------------------
::flagspawn.OnCaptureTouch <- function(activator, teamParam) {
    // TODO: wire into your bank/capture logic.
    ::flagspawn._ReconcileWorldtexts();
};

// Hammer may call plain Init() in script scope
Init <- function() { ::flagspawn.Init(); };
