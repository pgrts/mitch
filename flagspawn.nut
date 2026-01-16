// flagspawn_merge_verify_glowfix_v44.nut
// -----------------------------------------------------------------------------
// Goal (v44):
//  - STATE FIX (FINAL): "No Carrier = Dropped".
//    * Logic: If FS_FindCarrier() returns null, we treat the flag as DROPPED
//      immediately, even if the Engine Status (m_nFlagStatus) claims it is 2 (Carried).
//    * This solves the "Sticky Status" issue where the table says CARRIED after a drop.
//  - SIMPLIFIED: Removed complex timestamp overrides. Physical checks are definitive.
// -----------------------------------------------------------------------------

printl("[FS] Script Loading (merge-verify glowfix v45 (budget merge))...");

// -----------------------------------------------------------------------------
// 1) ROOT SETUP
// -----------------------------------------------------------------------------
local _rt = getroottable();
if (!("flagspawn" in _rt) || typeof _rt.flagspawn != "table") {
    _rt.flagspawn <- {};
}
local flagspawn = _rt.flagspawn;
try {
    if (!("flagspawn" in this) || typeof this.flagspawn != "table") this.flagspawn <- flagspawn;
    else this.flagspawn = flagspawn;
} catch (_e) {}

// -----------------------------------------------------------------------------
// 2) CONFIG
// -----------------------------------------------------------------------------
flagspawn.CFG <- {
    DEBUG = true,
    THINK_DT = 0.10,

    // Makers & Names
    MAKER_BLU = "fs_flag_maker_blu",
    MAKER_RED = "fs_flag_maker_red",
    FLAG_BLU  = "bluflag",
    FLAG_RED  = "redflag",
    
    // Helpers to Cleanup
    TRIG_BLU  = "red_lock_bluflag",
    TRIG_RED  = "blu_lock_redflag",
    LMM_BLU   = "blu_lmm",
    LMM_RED   = "red_lmm",
    SFX       = "fs_lockpad_sfx_proto",

    // Glows
    GLOW_BLU  = "bluflag_glow",
    GLOW_RED  = "redflag_glow",
    
    // Glow Pulse Settings
    GLOW_PULSE_RATE     = 1.0, 
    GLOW_PULSE_DURATION = 5.0, 

    // Spawner Props
    PROP_BLU_SPAWNER = "blu_flagspawner_prop",
    PROP_RED_SPAWNER = "red_flagspawner_prop",

    // Visuals
    PROP_BG_INDEX    = 1,
    BG_PULSE_ENABLE  = true,   
    USE_GLOBAL_GLOWS = true,

    // GLOBAL GATES
    SPAWN_COOLDOWN = 0.50,      
    SPAWNER_TOUCH_LOCK = 1.00,  
    ONE_ACTIVE_PER_TEAM = false, 

    // PLAYER GATES
    PLAYER_SPAWN_COOLDOWN = 0.0, 
    ONE_FLAG_PER_LIFE     = false, 

    // Merge Detection
    MERGE_DETECT_ENABLE = true,
    MERGE_DISTANCE_MAX = 256.0,
    MERGE_TIME_WINDOW  = 0.75,
    RECENT_GONE_KEEP   = 2.00,
    
    // Cleanup
    CLEANUP_ENABLE = true,
    CLEANUP_DELAY  = 0.05,

    // -----------------------------------------------------------------
    // Spawn Budget (per-player, class-based)
    // -----------------------------------------------------------------
    BUDGET_ENABLE      = true,
    BUDGET_RESET_SECS  = 90.0,
    BUDGET_COST        = 1,
    BUDGET_TOUCH_CD    = 0.35,   // per-player spam guard
    // TF2 class indexes: 1 Scout, 2 Sniper, 3 Soldier, 4 Demo, 5 Medic, 6 Heavy, 7 Pyro, 8 Spy, 9 Engi
    // Edit these to your economy.
    BUDGET_CLASS_MAX = {
        [1] = 2,   // Scout
        [2] = 8,   // Sniper
        [3] = 4,   // Soldier
        [4] = 3,   // Demoman
        [5] = 7,   // Medic
        [6] = 10,  // Heavy
        [7] = 5,   // Pyro
        [8] = 1,   // Spy
        [9] = 6    // Engineer
    },
    BUDGET_DEFAULT_MAX = 1,
    // If true, spawner prop bodygroup is set to (remaining budget) of last toucher.
    // If false, v44's existing BluPropCounter logic is used.
    BUDGET_PROP_OVERRIDE = false,
    BUDGET_PROP_BG_INDEX = 1

};

// -----------------------------------------------------------------------------
// 3) STATE
// -----------------------------------------------------------------------------
if (!("State" in flagspawn) || typeof flagspawn.State != "table") flagspawn.State <- {};
if (!("Pkgs" in flagspawn.State) || typeof flagspawn.State.Pkgs != "table") flagspawn.State.Pkgs <- {}; 
if (!("NextSpawnAt" in flagspawn.State) || typeof flagspawn.State.NextSpawnAt != "table") flagspawn.State.NextSpawnAt <- { blu = 0.0, red = 0.0 };
if (!("SpawnerLockUntil" in flagspawn.State) || typeof flagspawn.State.SpawnerLockUntil != "table") flagspawn.State.SpawnerLockUntil <- { blu = 0.0, red = 0.0 };
if (!("BluPropCounter" in flagspawn.State)) flagspawn.State.BluPropCounter <- 100;
if (!("LastHeartbeat" in flagspawn.State)) flagspawn.State.LastHeartbeat <- 0.0;

// Spawn-budget per-player state
if (!("Budgets" in flagspawn.State) || typeof flagspawn.State.Budgets != "table") flagspawn.State.Budgets <- {};


// -----------------------------------------------------------------------------
// 4) UTILITIES
// -----------------------------------------------------------------------------
function FS_Log(msg) { if (flagspawn.CFG.DEBUG) printl("[FS] " + msg); }
function FS_Now() { try { return Time(); } catch (_e) { return 0.0; } }
function FS_Clamp99(v) { if (v == null || v < 0) return 0; if (v > 99) return 99; return v; }
function FS_IsValid(ent) { try { return ent != null && ent.IsValid(); } catch (_e) { return false; } }

function FS_SetBodyGroup(ent, groupIdx, value) {
    if (!ent) return;
    value = FS_Clamp99(value);
    // Try method forms
    try { ent.SetBodygroup(groupIdx, value); return; } catch (_e) {}
    try { ent.SetBodyGroup(groupIdx, value); return; } catch (_e2) {}
    // Fallback to input (works on prop_dynamic, etc.)
    try { EntFireByHandle(ent, "SetBodyGroup", groupIdx.tostring() + " " + value.tostring(), 0.0, null, null); } catch (_e3) {}
}

function FS_ExtractSuffix(nm) {
    if (nm == null) return null;
    local i = nm.find("&");
    if (i == null || i < 0) return null;
    return nm.slice(i + 1);
}

function FS_WithSuffix(baseName, suf) { return baseName + "&" + suf; }

function FS_GetOrigin(ent) {
    if (!ent) return null;
    // HARD SAFETY: never call GetAbsOrigin() on players (TF2 can hard-crash)
    try { return ent.GetOrigin(); } catch (_e) {}
    try {
        if (!(ent.IsPlayer && ent.IsPlayer())) {
            return ent.GetAbsOrigin();
        }
    } catch (_e2) {}
    return null;
}


function FS_Dist(a, b) {
    if (a == null || b == null) return 1e9;
    local dx = a.x - b.x; local dy = a.y - b.y; local dz = a.z - b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

function FS_ReadFlagPoints(flag) {
    if (!flag) return 0;
    local v = null;
    try { v = NetProps.GetPropInt(flag, "m_nPointValue"); } catch (_e) {}
    if (v == null) try { v = NetProps.GetPropInt(flag, "m_iPointValue"); } catch (_e2) {}
    if (v == null) v = 1;
    return FS_Clamp99(v);
}

function FS_FindGlowForTeam(team, suf) {
    local baseName = (team == 2) ? flagspawn.CFG.GLOW_BLU : flagspawn.CFG.GLOW_RED;
    if (flagspawn.CFG.USE_GLOBAL_GLOWS) {
        local g = Entities.FindByName(null, baseName);
        if (g) return g;
    }
    if (suf != null && suf != "") {
        local g2 = Entities.FindByName(null, FS_WithSuffix(baseName, suf));
        if (g2) return g2;
    }
    return null;
}

function FS_BindGlow(glow, targetEnt, enable) {
    if (!FS_IsValid(glow)) return;
    
    if (!FS_IsValid(targetEnt)) {
        if (enable) EntFireByHandle(glow, "Disable", "", 0, null, null); 
        return;
    }
    try { NetProps.SetPropEntity(glow, "m_hTarget", targetEnt); } catch (_e) {}
    
    if (enable) EntFireByHandle(glow, "Enable", "", 0, null, null);
}

// --- HELPER: Find First Valid Player in Props ---
function FS_FindCarrier(flag) {
    local candidates = ["m_hOwner", "m_hOwnerEntity", "m_hMoveParent"];
    foreach (prop in candidates) {
        try {
            local e = NetProps.GetPropEntity(flag, prop);
            if (e && e.IsValid() && e.IsPlayer()) return e;
        } catch(_e) {}
    }
    return null;
}


// -----------------------------------------------------------------------------
// 4B) SPAWN BUDGET (per-player)
// -----------------------------------------------------------------------------
function FS_EntIndex(ent) {
    if (!ent) return 0;
    try { return ent.entindex(); } catch (_e) {}
    try { return ent.EntIndex(); } catch (_e2) {}
    return 0;
}

function FS_IsPlayer(ent) {
    if (!ent) return false;
    try { return ent.IsPlayer(); } catch (_e) {}
    return false;
}

function FS_GetPropFloat(ent, prop) {
    try { return NetProps.GetPropFloat(ent, prop); } catch (_e) {}
    return 0.0;
}

function FS_GetPropInt(ent, prop) {
    try { return NetProps.GetPropInt(ent, prop); } catch (_e) {}
    return 0;
}

function FS_GetPlayerClassIndex(ply) {
    if (!ply) return 0;
    // method first
    try {
        if ("GetPlayerClass" in ply) {
            local c = ply.GetPlayerClass();
            if (c != null) return c;
        }
    } catch (_e) {}
    // netprops
    local c2 = FS_GetPropInt(ply, "m_PlayerClass.m_iClass");
    if (c2 > 0) return c2;
    local c3 = FS_GetPropInt(ply, "m_iClass");
    if (c3 > 0) return c3;
    return 0;
}

function FS_BudgetKey(ply) { return "p" + FS_EntIndex(ply); }

function FS_BudgetForClass(c) {
    // Coerce class index to an integer key (TF2 can hand us ints/floats/strings depending on source).
    local ci = 0;
    try {
        local tc = typeof c;
        if (tc == "integer") ci = c;
        else if (tc == "float") ci = c.tointeger();
        else ci = c.tointeger();
    } catch (_e) {
        ci = 0;
    }

    if (ci <= 0) return flagspawn.CFG.BUDGET_DEFAULT_MAX;

    // Prefer rawin over 'in' to avoid any older-squirrel edge cases.
    try {
        if (flagspawn.CFG.BUDGET_CLASS_MAX.rawin(ci)) return flagspawn.CFG.BUDGET_CLASS_MAX[ci];
        local ks = "" + ci;
        if (flagspawn.CFG.BUDGET_CLASS_MAX.rawin(ks)) return flagspawn.CFG.BUDGET_CLASS_MAX[ks];
    } catch (_e2) {}

    return flagspawn.CFG.BUDGET_DEFAULT_MAX;
}

function FS_PlayerFromUserID(userid) {
    if (userid == null) return null;
    local p = null;
    try { p = GetPlayerFromUserID(userid); } catch (_e) { p = null; }
    if (p != null) return p;

    // Fallback: iterate players and match by user id (best-effort)
    local it = null;
    while ((it = Entities.FindByClassname(it, "player")) != null) {
        try {
            if ("GetPlayerUserId" in it) {
                if (it.GetPlayerUserId() == userid) return it;
            }
        } catch (_e2) {}
        try {
            if (NetProps.GetPropInt(it, "m_iUserID") == userid) return it;
        } catch (_e3) {}
        try {
            if (NetProps.GetPropInt(it, "m_iUserId") == userid) return it;
        } catch (_e4) {}
    }
    return null;
}


function FS_BudgetEnsure(ply) {
    local key = FS_BudgetKey(ply);
    local B = flagspawn.State.Budgets;
    if (!(key in B)) {
        B[key] <- {
            max = 0,
            used = 0,
            resetAt = 0.0,
            lastSpawnTime = 0.0,
            lastLifeState = -999,
            lastClass = 0,
            lastTouch = 0.0
        };
    }
    return B[key];
}

function FS_BudgetReset(ply, reason, classOverride = null) {
    if (!flagspawn.CFG.BUDGET_ENABLE) return;
    if (!FS_IsPlayer(ply)) return;

    local st = FS_BudgetEnsure(ply);

    // Determine class (optionally from event_data for more reliable immediate post-spawn values)
    local c = 0;
    if (classOverride != null) {
        try {
            local tc = typeof classOverride;
            if (tc == "integer") c = classOverride;
            else if (tc == "float") c = classOverride.tointeger();
            else c = classOverride.tointeger();
        } catch (_e0) {
            c = 0;
        }
    }
    if (c <= 0) c = FS_GetPlayerClassIndex(ply);

    st.lastClass = c;
    st.max = FS_BudgetForClass(c);

    // IMPORTANT: spawning/capture always refreshes to a clean 0/max budget.
    st.used = 0;

    st.resetAt = FS_Now() + flagspawn.CFG.BUDGET_RESET_SECS;
    st.lastSpawnTime = FS_GetPropFloat(ply, "m_flSpawnTime");
    st.lastLifeState = FS_GetPropInt(ply, "m_lifeState");

    if (flagspawn.CFG.DEBUG) {
        FS_Log("RESET " + FS_EntIndex(ply) + " class=" + c + " max=" + st.max + " (" + reason + ")");
    }
}

function FS_BudgetCanTouch(ply) {
    local st = FS_BudgetEnsure(ply);
    local now = FS_Now();
    if ((now - st.lastTouch) < flagspawn.CFG.BUDGET_TOUCH_CD) return false;
    st.lastTouch = now;
    return true;
}

function FS_BudgetUpdateClass(ply, st) {
    local c = FS_GetPlayerClassIndex(ply);
    if (c != 0 && c != st.lastClass) {
        st.lastClass = c;
        st.max = FS_BudgetForClass(c);
        if (st.used > st.max) st.used = st.max;
    }
}

// Export budget helpers to root so they are callable from console/debug context.
// (TF2 console 'script' runs in the root table, not an entity script scope.)
try {
    ::FS_BudgetEnsure <- FS_BudgetEnsure;
    ::FS_BudgetReset <- FS_BudgetReset;
    ::FS_BudgetUpdateClass <- FS_BudgetUpdateClass;
    ::FS_GetPlayerClassIndex <- FS_GetPlayerClassIndex;
    ::FS_PlayerFromUserID <- FS_PlayerFromUserID;
    ::FS_IsPlayer <- FS_IsPlayer;
} catch (_e) {}

function FS_BudgetTrySpend(ply, cost) {
    if (!flagspawn.CFG.BUDGET_ENABLE) return true;
    if (!FS_IsPlayer(ply)) return false;

    local st = FS_BudgetEnsure(ply);

    // timed reset
    if (st.resetAt != 0.0 && FS_Now() >= st.resetAt) {
        FS_BudgetReset(ply, "timeout");
        st = FS_BudgetEnsure(ply);
    }

    // adjust if class changed
    FS_BudgetUpdateClass(ply, st);

    // init if needed
    if (st.max <= 0) {
        FS_BudgetReset(ply, "init");
        st = FS_BudgetEnsure(ply);
    }

    if ((st.used + cost) > st.max) return false;
    st.used += cost;
    return true;
}

function FS_BudgetRemaining(ply) {
    local st = FS_BudgetEnsure(ply);
    local rem = st.max - st.used;
    if (rem < 0) rem = 0;
    return rem;
}

function FS_BudgetTick(now) {
    if (!flagspawn.CFG.BUDGET_ENABLE) return;

    local p = null;
    while ((p = Entities.FindByClassname(p, "player")) != null) {
        local st = FS_BudgetEnsure(p);

        // ---- Spawn detection (robust) ----
        // A) m_lifeState transition into alive (0) catches respawns even if m_flSpawnTime is flaky.
        local ls = FS_GetPropInt(p, "m_lifeState");
        if (st.lastLifeState == -999) {
            st.lastLifeState = ls;
        } else {
            if (ls == 0 && st.lastLifeState != 0) {
                st.lastLifeState = ls;
                FS_BudgetReset(p, "spawn_life");
                st = FS_BudgetEnsure(p);
            } else {
                st.lastLifeState = ls;
            }
        }

        // B) respawn detection by m_flSpawnTime netprop (still useful)
        local sp = FS_GetPropFloat(p, "m_flSpawnTime");
        if (sp != 0.0 && sp != st.lastSpawnTime) {
            st.lastSpawnTime = sp;
            FS_BudgetReset(p, "spawn_poll");
            st = FS_BudgetEnsure(p);
        }

        // ---- Timeout reset ----
        if (st.resetAt != 0.0 && now >= st.resetAt) {
            FS_BudgetReset(p, "timeout");
            st = FS_BudgetEnsure(p);
        }

        // Keep max synced with class even without touching spawner
        FS_BudgetUpdateClass(p, st);
    }
}

// Console debug: script FS_DumpBudgets()
::FS_DumpBudgets <- function() {
    printl("[FS] ---- budgets ----");

    local rt = getroottable();
    if (!("flagspawn" in rt) || typeof rt.flagspawn != "table") {
        printl("[FS] (no flagspawn table in root)");
        return;
    }
    local fs = rt.flagspawn;
    if (!("State" in fs) || typeof fs.State != "table" || !("Budgets" in fs.State) || typeof fs.State.Budgets != "table") {
        printl("[FS] (no budgets state)");
        return;
    }

    local B = fs.State.Budgets;
    local now = 0.0;
    try { now = Time(); } catch (_e) { now = 0.0; }

    local p = null;
    while ((p = Entities.FindByClassname(p, "player")) != null) {
        // entindex() is safe; avoid relying on script-scope helpers when called from console.
        local idx = 0;
        try { idx = p.entindex(); } catch (_e2) { idx = 0; }
        local key = "p" + idx;
        if (!(key in B)) {
            printl("[FS] p" + idx + " (no entry)");
            continue;
        }
        local st = B[key];
        local rin = 0.0;
        try { rin = st.resetAt - now; } catch (_e3) { rin = 0.0; }
        printl("[FS] p" + idx + " used=" + st.used + "/" + st.max + " resetIn=" + rin);
    }
};

// Optional: player_spawn listener can call this (CallScriptFunction recommended)
::FS_OnPlayerSpawn_Event <- function() {
    // If logic_eventlistener has Fetch Event Data enabled, event_data is available.
    local ed = null;
    try { ed = event_data; } catch (_e) { ed = null; }

    if (ed != null && typeof ed == "table") {
        local p = null;
        local uid = null;
        local cls = null;

        try { if (ed.rawin("userid")) uid = ed.userid; } catch (_e1) { uid = null; }
        try {
            if (ed.rawin("class")) cls = ed["class"];
            else if (ed.rawin("playerclass")) cls = ed["playerclass"];
        } catch (_e2) { cls = null; }

        if (uid != null) {
            try { p = FS_PlayerFromUserID(uid); } catch (_e3) { p = null; }
        }

        if (p != null && FS_IsPlayer(p)) {
            if (cls != null) {
                local ci = null;
                try {
                    local tc = typeof cls;
                    if (tc == "integer") ci = cls;
                    else if (tc == "float") ci = cls.tointeger();
                    else ci = cls.tointeger();
                } catch (_e4) { ci = null; }
                if (ci != null) FS_BudgetReset(p, "player_spawn_event", ci);
                else FS_BudgetReset(p, "player_spawn_event");
            } else {
                FS_BudgetReset(p, "player_spawn_event");
            }
            return;
        }
    }

    // Fallback: if activator is the player (depends on your wiring)
    try {
        if (FS_IsPlayer(activator)) {
            FS_BudgetReset(activator, "player_spawn_activator");
        }
    } catch (_e5) {}
};

// -----------------------------------------------------------------------------
// 5) CORE LOGIC: THINK LOOP
// -----------------------------------------------------------------------------
flagspawn.Think <- function() {
    local now = FS_Now();

    // budget housekeeping (spawn polling + timeout resets + class sync)
    FS_BudgetTick(now);

    if (flagspawn.CFG.DEBUG && (now - flagspawn.State.LastHeartbeat > 5.0)) {
        FS_Log("Heartbeat... (Tracking " + flagspawn.State.Pkgs.len() + " flags)");
        flagspawn.State.LastHeartbeat = now;
    }
    
    // A) PRE-CALC BEST GLOW TARGETS
    local bestBlu = null; local bestBluPts = -1;
    local bestRed = null; local bestRedPts = -1;

    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (pkg && FS_IsValid(pkg.flag)) {
            // Logic: Is it Carried?
            local c = FS_FindCarrier(pkg.flag);
            if (!c) {
                // If NOT carried, it's a candidate for "Best Dropped Flag"
                local pts = FS_ReadFlagPoints(pkg.flag);
                if (pkg.team == 2) {
                    if (pts >= bestBluPts) { bestBluPts = pts; bestBlu = pkg; }
                } else {
                    if (pts >= bestRedPts) { bestRedPts = pts; bestRed = pkg; }
                }
            }
        }
    }

    // B) ITERATE PACKAGES
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!pkg) continue;

        local isValid = FS_IsValid(pkg.flag);
        
        if (isValid) {
            // --- ACTIVE LOGIC ---

            // 1. Determine State (STRICT: NO CARRIER = DROPPED)
            local carrier = FS_FindCarrier(pkg.flag);
            
            // Just for debug logging
            local st = -1;
            try { st = NetProps.GetPropInt(pkg.flag, "m_nFlagStatus"); } catch(_e) {}
            pkg.rawStatus <- st;

            local newState = "";

            if (carrier) {
                // Found a player attached -> Definitely CARRIED
                newState = "CARRIED";
                pkg.carrier = carrier;
            } else {
                // Found nobody -> Definitely NOT Carried
                pkg.carrier = null;
                // Treat Status 2 (Carried) as a lie if carrier is null -> DROPPED
                if (st == 1) newState = "HOME";
                else newState = "DROPPED"; 
            }

            // State Change Detection
            if (newState != pkg.state) {
                pkg.state = newState;
                pkg.stateTime = now; 
            }

            // 2. Trigger Follow (LMM handles this)

            // 3. Glow Logic (ANTI-SPAM)
            if (!FS_IsValid(pkg.glow)) pkg.glow = FS_FindGlowForTeam(pkg.team, pkg.suf);
            
            if (pkg.state == "CARRIED") {
                // Do NOTHING
            } 
            else if (pkg.state == "DROPPED") {
                local isBest = (pkg == bestBlu) || (pkg == bestRed);
                if (FS_IsValid(pkg.glow) && isBest) {
                    // Pulse Logic
                    if ((now - pkg.stateTime) < flagspawn.CFG.GLOW_PULSE_DURATION) {
                        if (!("lastGlowPulse" in pkg)) pkg.lastGlowPulse <- 0.0;
                        if ((now - pkg.lastGlowPulse) >= flagspawn.CFG.GLOW_PULSE_RATE) {
                            FS_BindGlow(pkg.glow, pkg.flag, true);
                            pkg.lastGlowPulse = now;
                        }
                    }
                }
            }

            // 4. Bodygroups
            local pts = FS_ReadFlagPoints(pkg.flag);
            if (flagspawn.CFG.BG_PULSE_ENABLE) {
                try { pkg.flag.SetBodygroup(0, pts); } catch (_e) {}
                try { pkg.flag.SetBodygroup(1, pts); } catch (_e) {}
                try { pkg.flag.SetBodygroup(2, pts); } catch (_e) {}
            }
            pkg.curBg <- pts;

            // 5. Merge Detection
            if (!("lastPts" in pkg)) pkg.lastPts <- pts;
            if (pts != pkg.lastPts) {
                local delta = pts - pkg.lastPts;
                if (delta > 0) FS_Log("[MERGE] " + pkg.name + " gained " + delta + " points (Total: " + pts + ")");
                pkg.lastPts = pts;
            }
            pkg.lastPos <- FS_GetOrigin(pkg.flag);

        } else {
            // --- CLEANUP LOGIC ---
            if (pkg.state == "DROPPED") {
                FS_Log("[MERGE/RETURN] Dropped Flag " + pkg.name + " deleted. Cleaning debris.");
            } 
            else if (pkg.state == "CARRIED") {
                FS_Log("[SCORE] Carried Flag " + pkg.name + " deleted. Cleaning debris.");
            }
            else {
                FS_Log("[CLEANUP] Flag " + pkg.name + " deleted from state " + pkg.state);
            }

            if (flagspawn.CFG.CLEANUP_ENABLE) {
                local killList = [ 
                    FS_WithSuffix(flagspawn.CFG.TRIG_BLU, suf), 
                    FS_WithSuffix(flagspawn.CFG.TRIG_RED, suf),
                    FS_WithSuffix(flagspawn.CFG.LMM_BLU, suf), 
                    FS_WithSuffix(flagspawn.CFG.LMM_RED, suf),
                    FS_WithSuffix(flagspawn.CFG.SFX, suf) 
                ];
                foreach (nm in killList) {
                    local ent = Entities.FindByName(null, nm);
                    if (ent) EntFireByHandle(ent, "Kill", "", 0.1, null, null);
                }
            }
            delete flagspawn.State.Pkgs[suf];
        }
    }
    return flagspawn.CFG.THINK_DT;
};

// -----------------------------------------------------------------------------
// 6) DIRECT I/O HANDLERS
// -----------------------------------------------------------------------------
::FS_Direct_Pickup <- function() {
    local flag = caller;
    if (!FS_IsValid(flag)) return;
    local nm = flag.GetName();
    local suf = FS_ExtractSuffix(nm);
    
    if (suf && (suf in flagspawn.State.Pkgs)) {
        local pkg = flagspawn.State.Pkgs[suf];
        pkg.state = "CARRIED";
        pkg.stateTime = FS_Now(); // Reset timer
        pkg.carrier = activator; 
        if (flagspawn.CFG.DEBUG) FS_Log("[EVENT] Direct Pickup: " + nm);
    }
};

::FS_Direct_Drop <- function() {
    local flag = caller;
    if (!FS_IsValid(flag)) return;
    local nm = flag.GetName();
    local suf = FS_ExtractSuffix(nm);
    
    if (suf && (suf in flagspawn.State.Pkgs)) {
        local pkg = flagspawn.State.Pkgs[suf];
        pkg.state = "DROPPED";
        pkg.stateTime = FS_Now(); // Reset timer
        pkg.carrier = null;
        if (flagspawn.CFG.DEBUG) FS_Log("[EVENT] Direct Drop: " + nm);
        
        // Immediate Retry Logic for Drop (Once)
        if (pkg.glow) {
             FS_BindGlow(pkg.glow, pkg.flag, true);
             EntFireByHandle(pkg.glow, "Enable", "", 0.1, null, null);
        }
    }
};

// -----------------------------------------------------------------------------
// 7) SPAWN EVENTS
// -----------------------------------------------------------------------------
::FS_OnMakerSpawned <- function() {
    local maker = caller;
    if (!FS_IsValid(maker)) return;
    
    local isBlu = (maker.GetName() == flagspawn.CFG.MAKER_BLU);
    local team = isBlu ? 2 : 3;
    local baseName = isBlu ? flagspawn.CFG.FLAG_BLU : flagspawn.CFG.FLAG_RED;
    local trigBase = isBlu ? flagspawn.CFG.TRIG_BLU : flagspawn.CFG.TRIG_RED;

    local flag = null;
    while ((flag = Entities.FindByName(flag, baseName + "*")) != null) {
        local nm = flag.GetName();
        local suf = FS_ExtractSuffix(nm);
        if (suf != null && !(suf in flagspawn.State.Pkgs)) {
            local pkg = {
                team = team, name = nm, suf = suf, flag = flag,
                trig = Entities.FindByName(null, FS_WithSuffix(trigBase, suf)),
                glow = FS_FindGlowForTeam(team, suf),
                lastPts = FS_ReadFlagPoints(flag),
                lastPos = FS_GetOrigin(flag),
                state = "DROPPED", 
                stateTime = FS_Now(), 
                lastGlowPulse = FS_Now(), 
                carrier = null
            };
            
            try { flag.SetBodygroup(0, pkg.lastPts); } catch(_e){}
            try { flag.SetBodygroup(1, pkg.lastPts); } catch(_e){}
            try { flag.SetBodygroup(2, pkg.lastPts); } catch(_e){}
            
            if (pkg.glow) {
                FS_BindGlow(pkg.glow, flag, true);
                EntFireByHandle(pkg.glow, "Enable", "", 0.2, null, null);
                EntFireByHandle(pkg.glow, "Enable", "", 0.6, null, null);
            }
            
            flagspawn.State.Pkgs[suf] <- pkg;
            FS_Log("Spawned: " + nm);
            break;
        }
    }
};

::FS_OnFlagEvent <- function() {
    // Handles teamplay_flag_event when called from a logic_eventlistener
    // (Fetch Event Data must be enabled). We use it to reset budget on capture.
    if (!flagspawn.CFG.BUDGET_ENABLE) return;

    local ed = null;
    try { ed = event_data; } catch (_e) { ed = null; }
    if (ed == null || typeof ed != "table") return;

    local et = 0;
    try { if (ed.rawin("eventtype")) et = ed.eventtype; } catch (_e2) {}
    // 2 = Captured
    if (et != 2) return;

    local idx = 0;
    try { if (ed.rawin("player")) idx = ed.player; } catch (_e3) {}
    if (idx <= 0) return;

    local p = null;
    try { p = PlayerInstanceFromIndex(idx); } catch (_e4) { p = null; }
    if (p == null) { try { p = EntIndexToHScript(idx); } catch (_e5) { p = null; } }
    if (p != null && FS_IsPlayer(p)) {
        FS_BudgetReset(p, "capture");
    }
};

// -----------------------------------------------------------------------------
// 8) TOUCH HANDLERS
// -----------------------------------------------------------------------------
function FS_CheckPlayerGate(player) {
    if (!player) return false;
    local now = FS_Now();
    local sc = player.GetScriptScope();
    if (!sc) { player.ValidateScriptScope(); sc = player.GetScriptScope(); }

    if (flagspawn.CFG.ONE_FLAG_PER_LIFE) {
        local spawnTime = NetProps.GetPropFloat(player, "m_flSpawnTime");
        if (!("fs_lastSpawnTime" in sc)) sc.fs_lastSpawnTime <- -1.0;
        if (!("fs_flagsTaken" in sc)) sc.fs_flagsTaken <- 0;
        if (spawnTime != sc.fs_lastSpawnTime) { sc.fs_lastSpawnTime = spawnTime; sc.fs_flagsTaken = 0; }
        if (sc.fs_flagsTaken > 0) {
            if (flagspawn.CFG.DEBUG) FS_Log("Player denied: One Flag Per Life limit reached.");
            return false;
        }
    }
    return true;
}

function FS_ConsumePlayerGate(player) {
    if (!player) return;
    local now = FS_Now();
    local sc = player.GetScriptScope();
    if (!("fs_flagsTaken" in sc)) sc.fs_flagsTaken <- 0;
    sc.fs_flagsTaken++;
}

::FS_OnSpawnerTouchBlu <- function() {
    if (!(activator && activator.IsPlayer && activator.IsPlayer())) return;
    local now = FS_Now();
    
    if (now < flagspawn.State.SpawnerLockUntil.blu) return;
    if (now < flagspawn.State.NextSpawnAt.blu) return;
    if (flagspawn.CFG.ONE_ACTIVE_PER_TEAM && FS_TeamHasActiveFlag(2)) return; 
    if (!FS_CheckPlayerGate(activator)) return;


    // Budget gate (per-player)
    if (flagspawn.CFG.BUDGET_ENABLE) {
        if (!FS_BudgetCanTouch(activator)) return;
        if (!FS_BudgetTrySpend(activator, flagspawn.CFG.BUDGET_COST)) {
            local st = FS_BudgetEnsure(activator);
            FS_Log("DENY BLU spawn: " + st.used + "/" + st.max + " for player " + FS_EntIndex(activator));
            return;
        }
    }

    flagspawn.State.NextSpawnAt.blu = now + flagspawn.CFG.SPAWN_COOLDOWN;
    flagspawn.State.SpawnerLockUntil.blu = now + flagspawn.CFG.SPAWNER_TOUCH_LOCK;
    FS_ConsumePlayerGate(activator); 
    
    EntFire(flagspawn.CFG.MAKER_BLU, "ForceSpawn", "", 0, activator);
    
    EntFire(flagspawn.CFG.GLOW_BLU, "Enable", "", 0.1, activator);
    EntFire(flagspawn.CFG.GLOW_BLU, "Enable", "", 0.5, activator);
    
    local prop = Entities.FindByName(null, flagspawn.CFG.PROP_BLU_SPAWNER);
    if (prop) {
        if (flagspawn.CFG.BUDGET_ENABLE && flagspawn.CFG.BUDGET_PROP_OVERRIDE) {
            local rem = FS_BudgetRemaining(activator);
            if (rem > 99) rem = 99;
            try { FS_SetBodyGroup(prop, flagspawn.CFG.BUDGET_PROP_BG_INDEX, rem); } catch(_e){}
        } else {
            flagspawn.State.BluPropCounter--;
            if (flagspawn.State.BluPropCounter < 0) flagspawn.State.BluPropCounter = 0;
            if (flagspawn.State.BluPropCounter > 99) flagspawn.State.BluPropCounter = 99;
            try { FS_SetBodyGroup(prop, flagspawn.CFG.PROP_BG_INDEX, flagspawn.State.BluPropCounter); } catch(_e){}
        }
    }
};

::FS_OnSpawnerTouchRed <- function() {
    if (!(activator && activator.IsPlayer && activator.IsPlayer())) return;
    local now = FS_Now();
    if (now < flagspawn.State.SpawnerLockUntil.red) return;
    if (now < flagspawn.State.NextSpawnAt.red) return;
    if (flagspawn.CFG.ONE_ACTIVE_PER_TEAM && FS_TeamHasActiveFlag(3)) return;
    if (!FS_CheckPlayerGate(activator)) return;

    // Budget gate (per-player)
    if (flagspawn.CFG.BUDGET_ENABLE) {
        if (!FS_BudgetCanTouch(activator)) return;
        if (!FS_BudgetTrySpend(activator, flagspawn.CFG.BUDGET_COST)) {
            local st = FS_BudgetEnsure(activator);
            FS_Log("DENY RED spawn: " + st.used + "/" + st.max + " for player " + FS_EntIndex(activator));
            return;
        }
    }

    flagspawn.State.NextSpawnAt.red = now + flagspawn.CFG.SPAWN_COOLDOWN;
    flagspawn.State.SpawnerLockUntil.red = now + flagspawn.CFG.SPAWNER_TOUCH_LOCK;
    FS_ConsumePlayerGate(activator);

    EntFire(flagspawn.CFG.MAKER_RED, "ForceSpawn", "", 0, activator);

    EntFire(flagspawn.CFG.GLOW_RED, "Enable", "", 0.1, activator);
    EntFire(flagspawn.CFG.GLOW_RED, "Enable", "", 0.5, activator);

    // Optional: show remaining budget on red spawner prop
    if (flagspawn.CFG.BUDGET_ENABLE && flagspawn.CFG.BUDGET_PROP_OVERRIDE) {
        local prop = Entities.FindByName(null, flagspawn.CFG.PROP_RED_SPAWNER);
        if (prop) {
            local rem = FS_BudgetRemaining(activator);
            if (rem > 99) rem = 99;
            try { FS_SetBodyGroup(prop, flagspawn.CFG.BUDGET_PROP_BG_INDEX, rem); } catch(_e){}
        }
    }
};

// -----------------------------------------------------------------------------
// 9) DEBUG COMMANDS (DEEP PROBE EDITION)
// -----------------------------------------------------------------------------
::FS_DumpPkgs <- function() {
    printl("\n================ FS FLAG TABLE ================");
    local count = 0;
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (pkg) {
            local tName = (pkg.team == 2) ? "BLU" : "RED";
            local pts = ("lastPts" in pkg) ? pkg.lastPts : "?";
            local state = ("state" in pkg ? pkg.state : "UNKNOWN");
            local bg = ("curBg" in pkg ? pkg.curBg : "?");
            local raw = ("rawStatus" in pkg ? pkg.rawStatus : -1);
            
            local cStr = "None";
            if (pkg.carrier && pkg.carrier.IsValid()) {
                if (pkg.carrier.IsPlayer()) cStr = "PLY:" + pkg.carrier.GetName();
                else cStr = "ENT:" + pkg.carrier.GetClassname();
            }

            // PROBE STRING
            local probe = "";
            local props = ["m_hOwner", "m_hOwnerEntity", "m_hMoveParent"];
            foreach (p in props) {
                try {
                    local e = NetProps.GetPropEntity(pkg.flag, p);
                    if (e) {
                        if (e.IsPlayer()) probe += "[" + p + "=PLY(" + e.EntIndex() + ")] ";
                        else probe += "[" + p + "=" + e.GetClassname() + "] ";
                    } else {
                        probe += "[" + p + "=null] ";
                    }
                } catch(_e) { probe += "[" + p + "=err] "; }
            }

            printl(format("PKG [%s] %s | Pts: %s | State: %s (Raw: %d) | Carrier: %s | BG: %s", 
                suf, tName, pts.tostring(), state, raw, cStr, bg.tostring()));
            printl("   > PROBE: " + probe);
            count++;
        }
    }
    printl("Total Tracked: " + count);
    printl("===============================================\n");
};

// -----------------------------------------------------------------------------
// 10) STARTUP & CLEANUP
// -----------------------------------------------------------------------------
function FS_FullCleanup() {
    FS_Log("Performing Soft Tracker Cleanup...");
    flagspawn.State.Pkgs.clear();
    flagspawn.State.NextSpawnAt = { blu = 0.0, red = 0.0 };
    flagspawn.State.SpawnerLockUntil = { blu = 0.0, red = 0.0 };
}

::FS_Start <- function() {
    local sc = self.GetScriptScope();
    if (sc) {
        sc.Think <- flagspawn.Think;
        AddThinkToEnt(self, "Think");
    }
    printl("[FS] System Started (v44).");
};

::FS_Clamp99 <- FS_Clamp99;

// AUTO-EXECUTE CLEANUP
FS_FullCleanup();

// AUTO-EXECUTE STARTUP (SAFE for Console)
try {
    if (self && self.IsValid()) {
        FS_Start();
    }
} catch(e) {
    printl("[FS] Loaded in console. Run FS_Start() on an entity to begin.");
}