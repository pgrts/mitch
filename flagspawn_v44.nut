// flagspawn_merge_verify_glowfix_v44.nut
// -----------------------------------------------------------------------------
// Goal (v44):
//  - STATE FIX (FINAL): "No Carrier = Dropped".
//    * Logic: If FS_FindCarrier() returns null, we treat the flag as DROPPED
//      immediately, even if the Engine Status (m_nFlagStatus) claims it is 2 (Carried).
//    * This solves the "Sticky Status" issue where the table says CARRIED after a drop.
//  - SIMPLIFIED: Removed complex timestamp overrides. Physical checks are definitive.
// -----------------------------------------------------------------------------

printl("[FS] Script Loading (merge-verify glowfix v44)...");

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
    CLEANUP_DELAY  = 0.05
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

// -----------------------------------------------------------------------------
// 4) UTILITIES
// -----------------------------------------------------------------------------
function FS_Log(msg) { if (flagspawn.CFG.DEBUG) printl("[FS] " + msg); }
function FS_Now() { try { return Time(); } catch (_e) { return 0.0; } }
function FS_Clamp99(v) { if (v == null || v < 0) return 0; if (v > 99) return 99; return v; }
function FS_IsValid(ent) { try { return ent != null && ent.IsValid(); } catch (_e) { return false; } }

function FS_ExtractSuffix(nm) {
    if (nm == null) return null;
    local i = nm.find("&");
    if (i == null || i < 0) return null;
    return nm.slice(i + 1);
}

function FS_WithSuffix(baseName, suf) { return baseName + "&" + suf; }

function FS_GetOrigin(ent) {
    if (!ent) return null;
    try { return ent.GetOrigin(); } catch (_e) {}
    try { return ent.GetAbsOrigin(); } catch (_e2) {}
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
// 5) CORE LOGIC: THINK LOOP
// -----------------------------------------------------------------------------
flagspawn.Think <- function() {
    local now = FS_Now();

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

::FS_OnFlagEvent <- function() {};

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

    flagspawn.State.NextSpawnAt.blu = now + flagspawn.CFG.SPAWN_COOLDOWN;
    flagspawn.State.SpawnerLockUntil.blu = now + flagspawn.CFG.SPAWNER_TOUCH_LOCK;
    FS_ConsumePlayerGate(activator); 
    
    EntFire(flagspawn.CFG.MAKER_BLU, "ForceSpawn", "", 0, activator);
    
    EntFire(flagspawn.CFG.GLOW_BLU, "Enable", "", 0.1, activator);
    EntFire(flagspawn.CFG.GLOW_BLU, "Enable", "", 0.5, activator);
    
    local prop = Entities.FindByName(null, flagspawn.CFG.PROP_BLU_SPAWNER);
    if (prop) {
        flagspawn.State.BluPropCounter--;
        if (flagspawn.State.BluPropCounter < 0) flagspawn.State.BluPropCounter = 0;
        try { prop.SetBodygroup(flagspawn.CFG.PROP_BG_INDEX, flagspawn.State.BluPropCounter); } catch(_e){}
    }
};

::FS_OnSpawnerTouchRed <- function() {
    if (!(activator && activator.IsPlayer && activator.IsPlayer())) return;
    local now = FS_Now();
    if (now < flagspawn.State.SpawnerLockUntil.red) return;
    if (now < flagspawn.State.NextSpawnAt.red) return;
    if (flagspawn.CFG.ONE_ACTIVE_PER_TEAM && FS_TeamHasActiveFlag(3)) return;
    if (!FS_CheckPlayerGate(activator)) return;

    flagspawn.State.NextSpawnAt.red = now + flagspawn.CFG.SPAWN_COOLDOWN;
    flagspawn.State.SpawnerLockUntil.red = now + flagspawn.CFG.SPAWNER_TOUCH_LOCK;
    FS_ConsumePlayerGate(activator);

    EntFire(flagspawn.CFG.MAKER_RED, "ForceSpawn", "", 0, activator);
    
    EntFire(flagspawn.CFG.GLOW_RED, "Enable", "", 0.1, activator);
    EntFire(flagspawn.CFG.GLOW_RED, "Enable", "", 0.5, activator);
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