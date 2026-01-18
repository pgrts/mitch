// ============================================================================
// Flagspawn v29 (The Megalith - "Heavy Industry" Edition)
// ----------------------------------------------------------------------------
// MASTER SCRIPT - BLU SIDE AUTHORITATIVE LOGIC
// ----------------------------------------------------------------------------
//
// SUMMARY OF ARCHITECTURE:
//
// 1. THE "HARD TRUTH" (Engine Physics)
//    - We respect 'item_teamflag' as the definitive source of truth for:
//      * Pickup / Drop / Capture events
//      * Merging logic (managed by TF2)
//      * Point values (via NetProp m_nPointValue)
//
// 2. THE "VISUAL TRUTH" (VScript Override)
//    - We override all visuals to stop the "Flag fighting":
//      * CARRIED: item_teamflag is HIDDEN.
//                 'bluflag_prop' is parented to player (!partyhat).
//                 'bluflag_glow' targets the PLAYER (!activator).
//      * DROPPED: item_teamflag is VISIBLE.
//                 'bluflag_prop' is parented to 'blu_lmm_target' (follower).
//                 'bluflag_glow' targets the FLAG entity.
//
// 3. THE ECONOMY (The Bank)
//    - POOL: A global integer ('PoolBlu') starting at 1000.
//    - SPAWN: Decrements Pool. Emits ONE flag worth min(Pool, 500).
//    - REFUND: Captures/Returns increment Pool (Recycling points).
//    - SINK: Merged flags are destroyed WITHOUT refund (Inflation control).
//
// 4. EVENT MATH (Pinata & Bleed)
//    - DEATH: 5 Chunks spawned. Each = 20% of carried value. Remainder sunk.
//    - HURT:  1 Chunk spawned. Value = 20% of carried. Trigger = 12.5% MaxHP dmg.
//
// 5. SAFETY & ROBUSTNESS
//    - "Deep Validation": Every handle checked before use.
//    - "Retry Latch": Visuals re-applied 8 times after events to catch lag.
//    - "Safe Origins": Wrappers to prevent GetAbsOrigin crashes on players.
//    - "Leader Killer": Constant suppression of PD dispenser/beams.
//
// ============================================================================

// --- Root Anchor (TF2 Squirrel Safety) --------------------------------------
// Ensure we are attached to the root table to persist across scopes
local _rt = getroottable();
if (!("flagspawn" in _rt)) {
    _rt.flagspawn <- {};
}
local flagspawn = _rt.flagspawn;

flagspawn.CFG <- {
    VERSION = "v29_megalith_release",
    
    // ... (Keep your Debug flags here) ...
    DBG_GENERAL  = true,
    DBG_VISUALS  = true,
    DBG_ECONOMY  = true,
    DBG_EVENTS   = true,
    DBG_VERBOSE  = false,

    // ... (Keep your Entity Names here) ...
    MAKER_BLU        = "fs_flag_maker_blu",
    SPAWNER_PROP_BLU = "blu_flagspawner_prop",
    ENT_TEXT_BLU     = "blu_pool_text",
    ENT_SPRITE_LOCK  = "blu_spawner_lock",
    PD_LOGIC_NAME    = "fs_pd_logic",
    SCRIPTER_NAME    = "scripter",

    // ... (Keep your Template Suffixes here) ...
    PKG_FLAG = "bluflag",
    PKG_PROP = "bluflag_prop",
    PKG_GLOW = "bluflag_glow",
    PKG_LMM  = "blu_lmm_target",
    PKG_LOCK = "red_lock_bluflag",

    // --- ECONOMY SETTINGS ---
    TEAM_RED = 2,
    TEAM_BLU = 3,
    POOL_START = 1000, // Increased to 1000 so you can spawn multiple flags!
    LIMIT_ACTIVE_FLAGS = 25,
    
    // *** CRITICAL CHANGE ***
    // This allows the flag to physically hold 500 points
    VALUE_MAX_CAP = 500, 
    
    // This clamps the visual model to 100 so it doesn't break
    MODEL_VISUAL_CAP = 100,

    // ... (Keep the rest of your Config: BUDGET_CLASS_MAX, etc.) ...
    BUDGET_CLASS_MAX = {
        [1] = 2, [2] = 8, [3] = 4, [4] = 3, [5] = 7, 
        [6] = 10, [7] = 5, [8] = 1, [9] = 6
    },
    ATTACH_POINT = "partyhat",
    RETRY_COUNT = 8,
    PULSE_INTERVAL = 0.25,
    PINATA_CHUNKS = 5,
    PINATA_PCT = 0.20,
    ENABLE_DAMAGE_CHUNKS = true,
    DAMAGE_THRESHOLD_PCT = 0.125,
    DAMAGE_CHUNK_PCT = 0.20,
};

// ----------------------------------------------------------------------------
// 2. STATE INITIALIZATION
// ----------------------------------------------------------------------------
flagspawn.State <- {
    InitDone = false,
    
    // The "Bank" (points available to spawn)
    PoolBlu = flagspawn.CFG.POOL_START,
    
    // The Registry
    // Key: suffix (string) -> Table { flag, prop, glow, lmm, lock, pointValue, carrier, retry, ... }
    Flags = {},
    
    // Player Tracking
    // Key: userid (string) -> Table { used, damageAccumulator, nextSpawnTime }
    PlayerBudgets = {}, 
    
    // Internal Handoff (Communication between Spawner logic and Maker hook)
    NextSpawnValue = 1
};

// ----------------------------------------------------------------------------
// 3. LOGGING SUBSYSTEM
// ----------------------------------------------------------------------------

function FS_Log(msg) { 
    if (flagspawn.CFG.DBG_GENERAL) printl("[FS] " + msg);
}
function FS_LogVis(msg) { 
    if (flagspawn.CFG.DBG_VISUALS) printl("[FS-VIS] " + msg);
}
function FS_LogEco(msg) { 
    if (flagspawn.CFG.DBG_ECONOMY) printl("[FS-ECO] " + msg);
}
function FS_LogEvt(msg) { 
    if (flagspawn.CFG.DBG_EVENTS) printl("[FS-EVT] " + msg);
}
function FS_LogVerb(msg) { 
    if (flagspawn.CFG.DBG_VERBOSE) printl("[FS-VRB] " + msg);
}
function FS_Err(msg) { 
    printl("\n[FS-ERROR] >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>");
    printl("[FS-ERROR] " + msg); 
    printl("[FS-ERROR] <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n");
}

// ----------------------------------------------------------------------------
// 4. ROBUST HELPERS & VALIDATION (Global Scope Fix)
// ----------------------------------------------------------------------------
// We use '::' to force these into the Root Table, ensuring they are visible
// even when the script is executed via console or different scopes.
::FS_IsValid <- function(ent) { 
    try { 
        if (ent && ent.IsValid()) return true;
    } catch(e) {}
    return false; 
}

::FS_IsPlayer <- function(ent) {
    if (!::FS_IsValid(ent)) return false;
    try { return ent.IsPlayer(); } catch(e) { return false; }
}

::FS_GetName <- function(ent) {
    if (!::FS_IsValid(ent)) return "null";
    try { return ent.GetName(); } catch(e) { return "err"; }
}

::FS_GetOrigin <- function(ent) {
    if (!::FS_IsValid(ent)) return Vector(0,0,0);
    try { 
        // Crash Prevention: Player.GetAbsOrigin() is unstable in VScript
        if (ent.IsPlayer()) return ent.EyePosition() - Vector(0,0,20);
        return ent.GetOrigin();
    } catch(e) { return Vector(0,0,0); }
}

// EntFire Wrapper with Exception Handling
flagspawn._EntFire <- function(ent, input, param="", delay=0.0, activator=null) {
    if (!::FS_IsValid(ent)) {
        // FS_LogVerb("EntFire Ignored: Invalid Entity");
        return;
    }
    try { 
        // FS_LogVerb("EntFire: " + ::FS_GetName(ent) + " -> " + input);
        EntFireByHandle(ent, input, param, delay, activator, null); 
    } catch(e) {
        printl("[FS-ERR] EntFire Exception: " + e);
    }
}

// Helper: Find Entity by Name safely
::FS_FindByName <- function(name) {
    if (!name || name == "") return null;
    return Entities.FindByName(null, name);
}

// Helper: Get Player by UserID
::FS_GetPlayerFromUserID <- function(uid) {
    try { return GetPlayerFromUserID(uid);
    } catch(e) { return null; }
}

// Helper: Get Max Health (Safe)
::FS_GetMaxHealth <- function(ply) {
    if (!::FS_IsPlayer(ply)) return 100;
    try { return ply.GetMaxHealth(); } catch(e) { return 100; }
}

// ----------------------------------------------------------------------------
// 4.5 TIMING-HOLE GUARDS (ForceDrop + Rewind)
// ----------------------------------------------------------------------------

flagspawn._SetOriginNonPlayer <- function(ent, vec) {
    if (!::FS_IsValid(ent) || ent.IsPlayer()) return;
    if (vec == null) return;
    try { ent.SetAbsOrigin(vec); return; } catch (_e0) {}
    try { ent.SetOrigin(vec); return; } catch (_e1) {}
    try { NetProps.SetPropVector(ent, "m_vecOrigin", vec); } catch (_e2) {}
};

flagspawn._SetVelocityNonPlayer <- function(ent, vec) {
    if (!::FS_IsValid(ent) || ent.IsPlayer()) return;
    if (vec == null) return;
    try { ent.SetAbsVelocity(vec); return; } catch (_e0) {}
    try { NetProps.SetPropVector(ent, "m_vecAbsVelocity", vec); } catch (_e1) {}
};

flagspawn._RewindFlagByEntIndex <- function(entIdx, x, y, z) {
    local f = null;
    try { f = EntIndexToHScript(entIdx); } catch (_e0) { f = null; }
    if (!::FS_IsValid(f)) return;
    local pos = Vector(x, y, z);
    flagspawn._SetOriginNonPlayer(f, pos);
    flagspawn._SetVelocityNonPlayer(f, Vector(0, 0, 0));
};

flagspawn._ScheduleFlagRewind <- function(flagEnt, pos, delay) {
    if (!::FS_IsValid(flagEnt) || pos == null) return;

    local idx = 0;
    try { idx = flagEnt.entindex(); } catch (_e0) { idx = 0; }
    if (idx <= 0) return;

    local scripter = Entities.FindByName(null, flagspawn.CFG.SCRIPTER_NAME);
    if (!::FS_IsValid(scripter)) return;

    local code = "getroottable().flagspawn._RewindFlagByEntIndex("
        + idx + ","
        + pos.x + "," + pos.y + "," + pos.z
        + ")";

    EntFireByHandle(scripter, "RunScriptCode", code, delay, null, null);
};

flagspawn._ForceDropAndRewindFlag <- function(flagEnt, ply, rewindPos) {
    if (!::FS_IsValid(flagEnt) || !::FS_IsValid(ply) || !ply.IsPlayer()) return;
    if (rewindPos == null) return;

    // ForceDrop should undo PD credit (revert the pickup) without killing/respawning.
    try { EntFireByHandle(flagEnt, "ForceDrop", "", 0.0, ply, ply); } catch (_e0) {}

    // Snap back immediately and also schedule a couple rewinds to win races.
    flagspawn._SetOriginNonPlayer(flagEnt, rewindPos);
    flagspawn._SetVelocityNonPlayer(flagEnt, Vector(0, 0, 0));
    flagspawn._ScheduleFlagRewind(flagEnt, rewindPos, 0.05);
    flagspawn._ScheduleFlagRewind(flagEnt, rewindPos, 0.15);
};

// ----------------------------------------------------------------------------
// 5. LEADER LOGIC (Suppression)
// ----------------------------------------------------------------------------
// Runs every pulse to ensure the PD dispenser and beams don't interfere
flagspawn._KillLeaderDispenser <- function() {
    // 1. Kill Physical Dispenser
    local dispenser = Entities.FindByClassname(null, "pd_dispenser");
    if (FS_IsValid(dispenser)) {
        // Only log once per existence to avoid spam, but kill immediately
        // FS_LogVerb("Killing PD Leader Dispenser entity.");
        dispenser.Kill();
    }

    // 2. Clear Beams on Logic Entity
    local pdLogic = FS_FindByName(flagspawn.CFG.PD_LOGIC_NAME);
    if (!FS_IsValid(pdLogic)) {
        // Fallback search
        pdLogic = Entities.FindByClassname(null, "tf_logic_player_destruction");
    }

    if (FS_IsValid(pdLogic)) {
        // Force leader handles to null to prevent beams
        NetProps.SetPropEntity(pdLogic, "m_hRedTeamLeader", null);
        NetProps.SetPropEntity(pdLogic, "m_hBlueTeamLeader", null);
    }
}

// ----------------------------------------------------------------------------
// 6. ECONOMY & POOL MANAGEMENT
// ----------------------------------------------------------------------------

flagspawn._ModifyPool <- function(amount, reason) {
    local old = flagspawn.State.PoolBlu;
    flagspawn.State.PoolBlu += amount;
    
    // Clamp at 0 (No debt)
    if (flagspawn.State.PoolBlu < 0) flagspawn.State.PoolBlu = 0;
    local diff = flagspawn.State.PoolBlu - old;
    if (diff != 0) {
        FS_LogEco("Pool Update: " + old + " -> " + flagspawn.State.PoolBlu + " (Delta: " + diff + ") Reason: " + reason);
        flagspawn._UpdateWorldUI();
    }
}

flagspawn._UpdateWorldUI <- function() {
    // 1. Calculate Slots
    local activeCount = flagspawn.State.Flags.len();
    local limit = flagspawn.CFG.LIMIT_ACTIVE_FLAGS;
    local slotsLeft = limit - activeCount;
    if (slotsLeft < 0) slotsLeft = 0;

    // 2. Update WorldText
    local txt = FS_FindByName(flagspawn.CFG.ENT_TEXT_BLU);
    if (FS_IsValid(txt)) {
        flagspawn._EntFire(txt, "SetMessage", slotsLeft.tostring());
    }

    // 3. Update Lock Sprite
    local spr = FS_FindByName(flagspawn.CFG.ENT_SPRITE_LOCK);
    if (FS_IsValid(spr)) {
        if (slotsLeft == 0) flagspawn._EntFire(spr, "ShowSprite");
        else flagspawn._EntFire(spr, "HideSprite");
    }
    
    // 4. Update Spawner Meter
    local prop = FS_FindByName(flagspawn.CFG.SPAWNER_PROP_BLU);
    if (FS_IsValid(prop)) {
        local v = flagspawn.State.PoolBlu;
        if (v > 100) v = 100; if (v < 0) v = 0;
        flagspawn._EntFire(prop, "SetBodyGroup", "1 " + v);
    }
}

// ----------------------------------------------------------------------------
// 7. VISUAL STATE MACHINE
// ----------------------------------------------------------------------------

// Helper: Sync bodygroups on both Flag and Prop
// UPDATED: Clamps visuals to 100 even if points are 500
flagspawn._SyncBodygroups <- function(pkg) {
    if (!pkg) return;
    local val = pkg.pointValue;
    
    // LOGICAL CLAMP (Prevent negative points)
    if (val < 1) val = 1;

    // VISUAL CLAMP (Prevent model breaking)
    local visualVal = val;
    if (visualVal > flagspawn.CFG.MODEL_VISUAL_CAP) {
        visualVal = flagspawn.CFG.MODEL_VISUAL_CAP;
    }

    // Apply the VISUAL value to the model
    if (::FS_IsValid(pkg.prop)) flagspawn._EntFire(pkg.prop, "SetBodyGroup", "1 " + visualVal);
    if (::FS_IsValid(pkg.flag)) flagspawn._EntFire(pkg.flag, "SetBodyGroup", "1 " + visualVal);
}

// Helper: Retarget Glow (The "Sticky Glow" fix)
flagspawn._UpdateGlow <- function(pkg, state) {
    if (!FS_IsValid(pkg.glow)) return;

    // Always enable first
    flagspawn._EntFire(pkg.glow, "Enable");
    
    if (state == "CARRIED" && FS_IsValid(pkg.carrier)) {
        // High-fidelity retargeting to Player model
        // Note: SetTarget uses !activator as the parameter slot for the entity handle in VScript
        EntFireByHandle(pkg.glow, "SetTarget", "!activator", 0.0, pkg.carrier, null);
    } 
    else {
        // Retarget to physical flag entity when dropped
        if (FS_IsValid(pkg.flag)) {
            EntFireByHandle(pkg.glow, "SetTarget", "!activator", 0.0, pkg.flag, null);
        }
    }
}

// CORE: Apply Visuals basend on Logic Truth Table
flagspawn._ApplyVisualState <- function(pkg) {
    if (!pkg || !FS_IsValid(pkg.flag)) return;

    // A. Detect Reality (Carrier)
    local owner = pkg.flag.GetOwner();

    // Retry Latch: If we think we have a carrier but engine says null, trust us for a few frames
    if (!FS_IsValid(owner) && pkg.retry > 0 && FS_IsValid(pkg.carrier)) {
        owner = pkg.carrier;
    }

    // B. Detect Reality (Value)
    try { 
        local rv = NetProps.GetPropInt(pkg.flag, "m_nPointValue");
        if (rv != pkg.pointValue) {
            FS_LogVis("Value Change Detected [" + pkg.suffix + "]: " + pkg.pointValue + " -> " + rv);
            pkg.pointValue = rv;
        }
    } catch(e){}
    
    flagspawn._SyncBodygroups(pkg);

    // C. Apply State
    if (FS_IsValid(owner) && FS_IsPlayer(owner)) {
        // === STATE: CARRIED ===
        if (pkg.state != "CARRIED") FS_LogVis("State Transition [" + pkg.suffix + "] -> CARRIED by " + FS_GetName(owner));
        pkg.state = "CARRIED";
        pkg.carrier = owner;
        
        // 1. Hide Physics Flag
        flagspawn._EntFire(pkg.flag, "DisableDraw");
        if (FS_IsValid(pkg.lock)) flagspawn._EntFire(pkg.lock, "Disable");

        // 2. Attach Prop to Player
        if (FS_IsValid(pkg.prop)) {
            if (pkg.prop.GetMoveParent() != owner) {
                flagspawn._EntFire(pkg.prop, "ClearParent");
                flagspawn._EntFire(pkg.prop, "SetParent", "!activator", 0.02, owner);
                flagspawn._EntFire(pkg.prop, "SetParentAttachment", flagspawn.CFG.ATTACH_POINT, 0.04);
                flagspawn._EntFire(pkg.prop, "Enable");
                // Ensure visible
            }
        }
        
        // 3. Target Glow
        flagspawn._UpdateGlow(pkg, "CARRIED");
    } else {
        // === STATE: DROPPED ===
        if (pkg.state != "DROPPED") FS_LogVis("State Transition [" + pkg.suffix + "] -> DROPPED");
        pkg.state = "DROPPED";
        pkg.carrier = null;

        // Cache last-known dropped origin (prefer LMM follower target if present).
        // Used by the ForceDrop+rewind guard when an enemy "steals" the flag due to timing holes.
        try {
            if (::FS_IsValid(pkg.lmm)) pkg.lastDropOrigin = ::FS_GetOrigin(pkg.lmm);
            else pkg.lastDropOrigin = ::FS_GetOrigin(pkg.flag);
        } catch (_e0) {}
        
        // 1. Show Physics Flag
        flagspawn._EntFire(pkg.flag, "EnableDraw");
        if (FS_IsValid(pkg.lock)) flagspawn._EntFire(pkg.lock, "Enable");

        // 2. Attach Prop to Follower (LMM)
        if (FS_IsValid(pkg.prop) && FS_IsValid(pkg.lmm)) {
            if (pkg.prop.GetMoveParent() != pkg.lmm) {
                flagspawn._EntFire(pkg.prop, "ClearParent");
                flagspawn._EntFire(pkg.prop, "SetParent", pkg.lmm.GetName(), 0.02);
                flagspawn._EntFire(pkg.prop, "SetLocalOrigin", "0 0 0", 0.04);
                flagspawn._EntFire(pkg.prop, "SetLocalAngles", "0 0 0", 0.04);
                flagspawn._EntFire(pkg.prop, "Enable");
            }
        }
        
        // 3. Target Glow
        flagspawn._UpdateGlow(pkg, "DROPPED");
    }
}

// ----------------------------------------------------------------------------
// 8. FLAG EVENTS (Refunds, Destroys)
// ----------------------------------------------------------------------------

function FS_OnFlagEvent() {
    // 1. VMF SAFETY CHECK (Critical Fix)
    if (!("event_data" in getroottable())) {
        FS_Err("EVENT DATA MISSING! Fix 'FetchEventDate' -> 'FetchEventData' in VMF!");
        // We cannot proceed without data
        return;
    }
    
    local evt = event_data;

    // NOTE: `teamplay_flag_event` does NOT include a flag entity index on TF2.
    // It provides: player, carrier, eventtype, home, team.
    // Because we can't identify which specific flag returned/captured, refunds
    // must be driven by `item_teamflag` outputs (OnReturn/OnCapture) calling
    // `FS_Direct_Refund()` where `caller` is the flag entity.
    local type = 0;
    try { type = evt.eventtype; } catch (_e0) { type = 0; }
    if (flagspawn.CFG.DBG_EVENTS) {
        local p = 0; local c = 0; local t = 0; local home = 0;
        try { p = evt.player; } catch (_e1) { p = 0; }
        try { c = evt.carrier; } catch (_e2) { c = 0; }
        try { t = evt.team; } catch (_e3) { t = 0; }
        try { home = evt.home; } catch (_e4) { home = 0; }
        FS_LogEvt("teamplay_flag_event type=" + type + " team=" + t + " home=" + home + " player=" + p + " carrier=" + c);
    }
}

flagspawn._DestroyPackage <- function(suffix) {
    if (suffix in flagspawn.State.Flags) {
        local pkg = flagspawn.State.Flags[suffix];
        // Cleanup all entities in the package
        if (FS_IsValid(pkg.flag)) pkg.flag.Kill();
        if (FS_IsValid(pkg.prop)) pkg.prop.Kill();
        if (FS_IsValid(pkg.glow)) pkg.glow.Kill();
        if (FS_IsValid(pkg.lock)) pkg.lock.Kill();
        if (FS_IsValid(pkg.lmm))  pkg.lmm.Kill();
        
        delete flagspawn.State.Flags[suffix];
        flagspawn._UpdateWorldUI();
        FS_Log("Package Destroyed: " + suffix);
    }
}

// ----------------------------------------------------------------------------
// 9. SPAWNER LOGIC (One Big Flag - Megalith)
// ----------------------------------------------------------------------------

function FS_OnSpawnerTouchBlu() {
    flagspawn.Init();
    local ply = activator;
    
    // 1. Validation
    if (!::FS_IsValid(ply) || !ply.IsPlayer()) return;
    if (ply.GetTeam() != flagspawn.CFG.TEAM_BLU) return;

    // 2. Active Limit Check
    if (flagspawn.State.Flags.len() >= flagspawn.CFG.LIMIT_ACTIVE_FLAGS) {
        FS_LogVerb("Spawn Denied: Limit Reached");
        flagspawn._UpdateWorldUI();
        return;
    }

    // 3. Pool Check
    if (flagspawn.State.PoolBlu <= 0) {
        FS_LogVerb("Spawn Denied: Empty Pool");
        return;
    }

    // 4. Budget Check (Count based)
    local uid = ply.entindex().tostring();
    if (!(uid in flagspawn.State.PlayerBudgets)) 
        flagspawn.State.PlayerBudgets[uid] <- { used=0, damageAccumulator=0, nextSpawnTime=0.0 };

    local bud = flagspawn.State.PlayerBudgets[uid];
    if (Time() < bud.nextSpawnTime) return;

    local pClass = ply.GetPlayerClass();
    local limit = (pClass in flagspawn.CFG.BUDGET_CLASS_MAX) ?
        flagspawn.CFG.BUDGET_CLASS_MAX[pClass] : 1;
    
    // This limits the NUMBER of flags, not the value.
    // A Heavy can pull 1 flag worth 500 points, consuming 1 budget slot.
    if (bud.used >= limit) {
        FS_LogVerb("Spawn Denied: Class Budget Limit");
        return;
    }

    // 5. Spawn Value Calculation (One Big Flag)
    // Take all points from pool up to VALUE_MAX_CAP (Now 500)
    local val = flagspawn.State.PoolBlu;
    if (val > flagspawn.CFG.VALUE_MAX_CAP) val = flagspawn.CFG.VALUE_MAX_CAP;
    
    // 6. Execute Spawn
    local maker = ::FS_FindByName(flagspawn.CFG.MAKER_BLU);
    if (maker) {
        // Handoff Value to Maker callback
        flagspawn.State.NextSpawnValue = val;
        // Deduct FIRST to be safe
        flagspawn._ModifyPool(-val, "PlayerSpawn");
        // Cooldown & Budget
        bud.used += 1;
        bud.nextSpawnTime = Time() + 1.0; 
        
        maker.SpawnEntity();
        FS_LogEco("Spawned Flag Value: " + val + " for " + ply.GetName());
    } else {
        FS_Err("Spawner Maker Entity Not Found: " + flagspawn.CFG.MAKER_BLU);
    }
}

// ----------------------------------------------------------------------------
// 9.5 MAKER CALLBACK (The Missing Link Fix)
// ----------------------------------------------------------------------------

function FS_OnMakerSpawned() {
    // Scan for the newly created flag
    // The Maker appends a unique suffix (e.g. "bluflag&0001")
    // We look for any flag we haven't registered yet.
    local flagPrefix = flagspawn.CFG.PKG_FLAG; // FIXED: Renamed 'base' to 'flagPrefix'
    local foundEnt = null;
    local foundSuffix = null;

    local ent = Entities.FindByClassname(null, "item_teamflag");
    while (ent) {
        local name = FS_GetName(ent);
        if (name.find(flagPrefix) == 0) {
            local suf = name.slice(flagPrefix.len());
            if (!(suf in flagspawn.State.Flags)) {
                foundEnt = ent;
                foundSuffix = suf;
                break;
            }
        }
        ent = Entities.FindByClassname(ent, "item_teamflag");
    }

    if (foundEnt && foundSuffix != null) {
        // Register the package
        local pkg = {
            suffix     = foundSuffix,
            flag       = foundEnt,
            prop       = FS_FindByName(flagspawn.CFG.PKG_PROP + foundSuffix),
            glow       = FS_FindByName(flagspawn.CFG.PKG_GLOW + foundSuffix),
            lmm        = FS_FindByName(flagspawn.CFG.PKG_LMM + foundSuffix),
            lock       = FS_FindByName(flagspawn.CFG.PKG_LOCK + foundSuffix),
            pointValue = flagspawn.State.NextSpawnValue,
            state      = "SPAWNING",
            carrier    = null,
            retry      = flagspawn.CFG.RETRY_COUNT,
            lastDropOrigin = null
        };

        flagspawn.State.Flags[foundSuffix] <- pkg;

        // Apply Points Authority
        NetProps.SetPropInt(pkg.flag, "m_nPointValue", pkg.pointValue);

        // Apply Visuals
        flagspawn._ApplyVisualState(pkg);

        FS_Log("Registered flag suffix: " + foundSuffix + " | Value: " + pkg.pointValue);
        flagspawn._UpdateWorldUI();
    } else {
        FS_Err("Maker spawned entity, but could not find unregistered 'item_teamflag' with prefix: " + flagPrefix);
    }
}

// ----------------------------------------------------------------------------
// 10. EVENT LOGIC (Pinata / Hurt)
// ----------------------------------------------------------------------------

function FS_OnPlayerSpawn_Event() {
    if (!("event_data" in getroottable())) return;
    local uid = event_data.userid.tostring();
    // Reset Budget on spawn
    if (uid in flagspawn.State.PlayerBudgets) {
        flagspawn.State.PlayerBudgets[uid].used = 0;
        flagspawn.State.PlayerBudgets[uid].damageAccumulator = 0;
        flagspawn.State.PlayerBudgets[uid].nextSpawnTime = 0.0;
        FS_LogEvt("Budget Reset for UserID: " + uid);
    }
}

// THE PINATA: 5 chunks @ 20%
function FS_OnPlayerDeathEvent() {
    if (!("event_data" in getroottable())) {
        FS_Err("NO EVENT DATA (Death) - Check VMF!");
        return; 
    }
    local uid = event_data.userid;
    local victim = FS_GetPlayerFromUserID(uid);
    if (!FS_IsValid(victim)) return;

    // Scan for carried flags
    foreach (suf, pkg in flagspawn.State.Flags) {
        if (pkg.carrier == victim) {
            local totalVal = pkg.pointValue;
            FS_LogEvt("Pinata Death: " + victim.GetName() + " carrying " + totalVal);

            // 1. Destroy Source Flag (It explodes)
            flagspawn._DestroyPackage(suf);

            // 2. Calc Chunk Value (20%)
            local chunkVal = floor(totalVal * flagspawn.CFG.PINATA_PCT);

            // 3. Spawn Chunks
            if (chunkVal > 0) {
                local maker = FS_FindByName(flagspawn.CFG.MAKER_BLU);
                if (maker) {
                    for (local i=0; i < flagspawn.CFG.PINATA_CHUNKS; i++) {
                        // Check Active Limit
                        if (flagspawn.State.Flags.len() >= flagspawn.CFG.LIMIT_ACTIVE_FLAGS) {
                            FS_Log("Pinata Limit Reached, stopping spawns.");
                            break;
                        }
                        
                        flagspawn.State.NextSpawnValue = chunkVal;
                        local scatter = Vector(RandomInt(-30,30), RandomInt(-30,30), 40);
                        maker.SpawnEntityAtLocation(victim.GetOrigin() + scatter, Vector(0,0,0));
                    }
                }
            } else {
                FS_Log("Pinata value too low to chunk.");
            }
        }
    }
}

// DAMAGE CHUNKS: 1 chunk @ 20% per 12.5% MaxHP damage
function FS_OnPlayerHurtEvent() {
    if (!flagspawn.CFG.ENABLE_DAMAGE_CHUNKS) return;

    if (!("event_data" in getroottable())) {
        FS_Err("NO EVENT DATA (Hurt) - Check VMF!"); 
        return;
    }
    
    local dmg = event_data.damageamount;
    local uid = event_data.userid.tostring();
    local victim = FS_GetPlayerFromUserID(event_data.userid);

    // Dynamic Threshold Calc
    local maxHp = FS_GetMaxHealth(victim);
    local threshold = maxHp * flagspawn.CFG.DAMAGE_THRESHOLD_PCT;

    if (!(uid in flagspawn.State.PlayerBudgets)) 
        flagspawn.State.PlayerBudgets[uid] <- { used=0, damageAccumulator=0, nextSpawnTime=0.0 };

    local rec = flagspawn.State.PlayerBudgets[uid];
    rec.damageAccumulator += dmg;
    
    // Check Acc
    while (rec.damageAccumulator >= threshold) {
        rec.damageAccumulator -= threshold;
        flagspawn._DropDamageChunk(victim);
    }
}

function FS_DropDamageChunk(ply) {
    if (!FS_IsValid(ply)) return;
    // Limit Check
    if (flagspawn.State.Flags.len() >= flagspawn.CFG.LIMIT_ACTIVE_FLAGS) return;
    
    // Find Source Flag
    local source = null;
    foreach (suf, pkg in flagspawn.State.Flags) {
        if (pkg.carrier == ply) { source = pkg; break; }
    }
    
    if (!source) return; // No flag to bleed points from
    
    // Calc 20% Value of carried flag
    local chunkVal = floor(source.pointValue * flagspawn.CFG.DAMAGE_CHUNK_PCT);
    if (chunkVal < 1) chunkVal = 1;
    
    // Spawn Chunk (Does NOT deduct from source, inflation bleed logic)
    local maker = FS_FindByName(flagspawn.CFG.MAKER_BLU);
    if (maker) {
        flagspawn.State.NextSpawnValue = chunkVal;
        maker.SpawnEntityAtLocation(ply.GetOrigin() + Vector(0,0,50), Vector(0,0,0));
        FS_LogEvt("Hurt Chunk: " + chunkVal + "pts from " + ply.GetName());
    }
}

// ----------------------------------------------------------------------------
// 11. DIRECT HOOKS & PULSE
// ----------------------------------------------------------------------------

function FS_Direct_Pickup() {
    flagspawn.Init();

    local flag = null;
    local ply = null;
    try { flag = caller; } catch (_e0) { flag = null; }
    try { ply = activator; } catch (_e1) { ply = null; }
    if (!::FS_IsValid(flag)) return;

    // We need activator to enforce the timing-hole guard.
    if (!::FS_IsValid(ply) || !ply.IsPlayer()) {
        flagspawn._TriggerRetry(flag);
        return;
    }

    // Enemy pickup timing-hole guard:
    // If a RED player picks up a BLU flag (bluflag&####), ForceDrop and rewind it back to the last known dropped pos.
    local pTeam = 0;
    try { pTeam = ply.GetTeam(); } catch (_e2) { pTeam = 0; }

    if (pTeam == flagspawn.CFG.TEAM_RED) {
        local nm = "";
        try { nm = flag.GetName(); } catch (_e3) { nm = ""; }

        local prefix = flagspawn.CFG.PKG_FLAG;
        if (nm != null && nm.find(prefix) == 0) {
            local suf = nm.slice(prefix.len());
            local rewindPos = null;
            local pkg = null;

            if (suf != null && suf != "" && (suf in flagspawn.State.Flags)) {
                pkg = flagspawn.State.Flags[suf];
                try {
                    if (("lastDropOrigin" in pkg) && pkg.lastDropOrigin != null) rewindPos = pkg.lastDropOrigin;
                    else if (::FS_IsValid(pkg.lmm)) rewindPos = ::FS_GetOrigin(pkg.lmm);
                } catch (_e4) {}
            }

            if (rewindPos == null) rewindPos = ::FS_GetOrigin(flag);

            FS_LogVis("Enemy pickup guard: RED picked up " + nm + " -> ForceDrop+rewind");
            flagspawn._ForceDropAndRewindFlag(flag, ply, rewindPos);

            // Re-apply visuals after the forced drop.
            if (pkg != null) pkg.retry = flagspawn.CFG.RETRY_COUNT;
            flagspawn._Pulse();
            return;
        }
    }

    // Normal pickup: v44-style retry latch for visuals.
    flagspawn._TriggerRetry(flag);
}

function FS_Direct_Drop() {
    flagspawn.Init();
    local flag = null;
    try { flag = caller; } catch (_e0) { flag = null; }
    flagspawn._TriggerRetry(flag);
}

// ----------------------------------------------------------------------------
// 11.5 DIRECT REFUND (OnReturn / OnCapture outputs)
// ----------------------------------------------------------------------------

function FS_Direct_Refund() {
    flagspawn.Init();

    local flag = null;
    try { flag = caller; } catch (_e0) { flag = null; }
    if (!::FS_IsValid(flag)) return;

    local nm = "";
    try { nm = flag.GetName(); } catch (_e1) { nm = ""; }
    if (nm == null || nm == "") return;

    local prefix = flagspawn.CFG.PKG_FLAG;
    if (nm.find(prefix) != 0) return;

    local suf = nm.slice(prefix.len());
    if (suf == null || suf == "" || suf.slice(0, 1) != "&") return;

    // Find package
    if (!(suf in flagspawn.State.Flags)) return;
    local pkg = flagspawn.State.Flags[suf];

    // Refund (cap to prevent runaway economy)
    local refund = pkg.pointValue;
    if (refund > flagspawn.CFG.VALUE_MAX_CAP) refund = flagspawn.CFG.VALUE_MAX_CAP;
    if (refund < 0) refund = 0;

    FS_LogEco("Direct Refund: " + nm + " +" + refund);
    flagspawn._ModifyPool(refund, "DirectRefund");

    // Kill entities to free slot (engine would otherwise return to base).
    flagspawn._DestroyPackage(suf);
}

flagspawn._TriggerRetry <- function(flag) {
    if (!FS_IsValid(flag)) return;
    local n = flag.GetName(); local b = flagspawn.CFG.PKG_FLAG;
    
    // Check if valid templated flag
    if (n.find(b) == 0) {
        local s = n.slice(b.len());
        if (s in flagspawn.State.Flags) {
            FS_LogVis("Triggering Visual Retry for " + s);
            flagspawn.State.Flags[s].retry = flagspawn.CFG.RETRY_COUNT;
            flagspawn._Pulse();
        }
    }
}

flagspawn.Think <- function() { flagspawn._Pulse(); return flagspawn.CFG.PULSE_INTERVAL; }

flagspawn._Pulse <- function() {
    flagspawn._KillLeaderDispenser(); // Suppress beams

    foreach (suf, pkg in flagspawn.State.Flags) {
        // A. TERMINAL CLEANUP (Detect entities killed by engine PD merges or returns)
        if (!FS_IsValid(pkg.flag)) {
            FS_Log("Pulse Prune: " + suf + " (Flag Entity Missing)");
            flagspawn._DestroyPackage(suf);
            continue;
        }
        
        // B. LATCHED RETRIES
        if (pkg.retry > 0) { 
            pkg.retry--;
            flagspawn._ApplyVisualState(pkg); 
        }
        
        // C. CONTINUOUS POLL (Value & Carrier)
        // Detect silent PD merges or value changes
        try {
            local rv = NetProps.GetPropInt(pkg.flag, "m_nPointValue");
            if (rv != pkg.pointValue) {
                pkg.pointValue = rv;
                flagspawn._ApplyVisualState(pkg);
            }
        } catch(e){}
    }
}
// ----------------------------------------------------------------------------
// 12. DEBUG COMMANDS
// ----------------------------------------------------------------------------

function FS_DbgDump() {
    printl("\n===============================================");
    printl(" FLAGSPAWN v28 DEBUG DUMP");
    printl("===============================================");
    printl(" Pool: " + flagspawn.State.PoolBlu);
    printl(" Active Flags: " + flagspawn.State.Flags.len() + " / " + flagspawn.CFG.LIMIT_ACTIVE_FLAGS);
    printl("-----------------------------------------------");
    printl(" FLAGS REGISTRY:");
    foreach (s, p in flagspawn.State.Flags) {
        local cStr = ::FS_IsValid(p.carrier) ? p.carrier.GetName() : "null";
        printl(format(" [%s] Val:%d | State:%s | Carr:%s | Rtry:%d", s, p.pointValue, p.state, cStr, p.retry));
        printl(format("    > Handle Check: Flag=%s Prop=%s Glow=%s", 
            ::FS_IsValid(p.flag).tostring(), ::FS_IsValid(p.prop).tostring(), ::FS_IsValid(p.glow).tostring()));
    }
    printl("-----------------------------------------------");
    printl(" PLAYER BUDGETS:");
    foreach (u, b in flagspawn.State.PlayerBudgets) {
        if (b.used > 0 || b.damageAccumulator > 0) {
            printl(format(" [UserID %s] Used:%d | DmgAcc:%.1f", u, b.used, b.damageAccumulator));
        }
    }
    printl("===============================================\n");
}

// Usage in console: script FS_Track(123) <-- Use the Entity Index
::FS_Track <- function(index) {
    printl("--- TRACKING FLAG INDEX " + index + " ---");
    foreach (s, p in flagspawn.State.Flags) {
        if (::FS_IsValid(p.flag) && p.flag.entindex() == index) {
            printl("Found Suffix: " + s);
            printl("Origin: " + p.flag.GetOrigin());
            printl("State: " + p.state);
            
            // Visual Debug: Draw a box around the flag for 10 seconds
            DebugDrawBox(p.flag.GetOrigin(), Vector(-16,-16,0), Vector(16,16,72), 0, 255, 0, 100, 10.0);
            if (::FS_IsValid(p.carrier)) {
                printl("Carrier: " + p.carrier.GetName());
                // Draw box around carrier too
                DebugDrawBox(p.carrier.GetOrigin(), Vector(-24,-24,0), Vector(24,24,82), 255, 0, 0, 100, 10.0);
            }
            return;
        }
    }
    printl("Flag index " + index + " not found in registry.");
}

// ----------------------------------------------------------------------------
// 13. BOOTSTRAP (ROBUST VERSION)
// ----------------------------------------------------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.InitDone) return;
    flagspawn.State.InitDone = true;

    // SAFETY: Determine the host entity. 
    // If 'self' exists (Map Spawn), use it.
    // If 'self' is missing (Console script_execute), find the entity by name.
    local host = null;
    if ("self" in getroottable() && self != null && self.IsValid()) {
        host = self;
    } else {
        // Fallback for manual console execution
        host = Entities.FindByName(null, flagspawn.CFG.SCRIPTER_NAME);
    }

    if (host) {
        // Ensure the host scope has the Think function attached
        local sc = host.GetScriptScope();
        if (!("Think" in sc)) {
            sc.Think <- flagspawn.Think;
        }
        
        // Restart the Think loop
        AddThinkToEnt(host, "Think");
        printl("[FS28] Hooked to host entity: " + host.GetName());
    } else {
        // Critical Failure: Could not find the scripter entity
        printl("[FS-ERR] CRITICAL: Host entity '" + flagspawn.CFG.SCRIPTER_NAME + "' not found! Logic disabled.");
        return;
    }
    
    flagspawn._UpdateWorldUI();
    
    printl("\n[FS28] Flagspawn Megalith Loaded.");
    printl("[FS28] Active Limit: " + flagspawn.CFG.LIMIT_ACTIVE_FLAGS);
    printl("[FS28] REMINDER: ENSURE VMF FETCHEVENTDATA IS CORRECT!");
    printl("[FS28] Run 'script FS_DbgDump()' for status.\n");
}

// Auto-start on script load
flagspawn.Init();
