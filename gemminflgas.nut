// -----------------------------------------------------------------------------
// flagspawn.nut
// Spawns and manages PD-style flags/pickups with custom models and values.
// -----------------------------------------------------------------------------

if (!("flagspawn" in getroottable())) ::flagspawn <- {};

// -----------------------------------------------------------------------------
// CONFIGURATION
// -----------------------------------------------------------------------------

// The model to use for the flag
::flagspawn.FLAG_MODEL <- "models/props_custom/fs_meter/fs_meter_slab_grid.mdl";

// If true, we use a bodygroup on the model to represent the point value (0-100)
::flagspawn.USE_FLAG_MODEL_BODYGROUP <- true;

// The bodygroup index to target (usually 0 for the first bodygroup)
::flagspawn.FLAG_BODYGROUP_INDEX <- 0;

// Maximum value for the bodygroup (clamps visual only, not actual points)
::flagspawn.FLAG_BODYGROUP_MAX <- 100;

// If using the model bodygroup, disable the floating "WorldText" visuals?
if (::flagspawn.USE_FLAG_MODEL_BODYGROUP) {
    ::flagspawn.FLAG_VISUAL_ENABLED <- false; 
} else {
    ::flagspawn.FLAG_VISUAL_ENABLED <- true;
}

// -----------------------------------------------------------------------------
// CORE SYSTEMS
// -----------------------------------------------------------------------------

::flagspawn.OnGameEvent_teamplay_round_start <- function(params) {
    // Precache the custom model
    if (::flagspawn.FLAG_MODEL && ::flagspawn.FLAG_MODEL.len() > 0) {
        PrecacheModel(::flagspawn.FLAG_MODEL);
    }
    
    // Reset pool counts or logic if needed
    ::flagspawn.Log("Round Start: Model set to " + ::flagspawn.FLAG_MODEL);
}

// Dispense a new flag at a specific location for a specific team
::flagspawn.DispenseFlag <- function(team, pos, value = 1) {
    local spawnPos = pos;
    // Lift slightly to prevent getting stuck in floor
    spawnPos.z += 16.0;

    local spawnTable = {
        TeamNum = 0, // 0 = Unassigned/Neutral usually for PD pickups
        origin = spawnPos,
        "mins": "-16 -16 0",
        "maxs": "16 16 32",
        "ReturnTime": 0, // PD flags usually don't return automatically
        "points": value  // Native KV for points
    };

    // Apply Custom Model
    if (::flagspawn.FLAG_MODEL && ::flagspawn.FLAG_MODEL.len() > 0) {
        spawnTable.model <- ::flagspawn.FLAG_MODEL;
    }

    local flag = SpawnEntityFromTable("item_teamflag", spawnTable);

    if (flag) {
        // Set script scope values
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        ss.pointsvalue <- value;
        
        // Setup initial bodygroup
        ::flagspawn._UpdateFlagBodygroup(flag, value);
        
        ::flagspawn.Log("DISPENSE: team=" + team + " flag=" + flag + " PointsValue=" + value);
        
        // Force a collision size fix just in case the model is tiny
        // EntFireByHandle(flag, "Enable", "", 0, null, null); 
    }
    
    return flag;
}

// -----------------------------------------------------------------------------
// VISUAL & BODYGROUP MANAGEMENT
// -----------------------------------------------------------------------------

// Updates the flag's bodygroup based on its point value
::flagspawn._UpdateFlagBodygroup <- function(flag, value) {
    if (!::flagspawn.USE_FLAG_MODEL_BODYGROUP || !flag || !flag.IsValid()) return;
    
    local v = value;
    
    // If value not provided, try to fetch it
    if (v == null) v = ::flagspawn._GetFlagPointsValue(flag);
    
    // Ensure integer
    try { v = v.tointeger(); } catch(e) { v = 1; }
    
    // Clamp for visual display
    if (v < 0) v = 0;
    if (v > ::flagspawn.FLAG_BODYGROUP_MAX) v = ::flagspawn.FLAG_BODYGROUP_MAX;
    
    // Optimization: Check if we already set this bodygroup to avoid network spam
    try {
        flag.ValidateScriptScope();
        local ss = flag.GetScriptScope();
        if ("fs_last_bodygroup" in ss && ss.fs_last_bodygroup == v) return;
        ss.fs_last_bodygroup <- v;
    } catch(e2) {}

    // Apply Bodygroup
    // Format: "group_index value"
    local param = "" + ::flagspawn.FLAG_BODYGROUP_INDEX + " " + v;
    
    // Try both spellings of the input just to be safe
    EntFireByHandle(flag, "SetBodyGroup", param, 0.0, null, null);
    EntFireByHandle(flag, "SetBodygroup", param, 0.0, null, null);
    
    // Also ensure skin is correct if needed (optional)
    // EntFireByHandle(flag, "Skin", "0", 0.0, null, null);
};

// Retrieve the points value from a flag entity
::flagspawn._GetFlagPointsValue <- function(flag) {
    if (!flag || !flag.IsValid()) return 1;
    
    // 1. Try Script Scope
    try {
        if (flag.GetScriptScope() && "pointsvalue" in flag.GetScriptScope()) {
            return flag.GetScriptScope().pointsvalue;
        }
    } catch(e) {}
    
    // 2. Try Native NetProp (m_nType is often used for points in some PD implementations, or just KeyValues)
    // This is unreliable depending on exact entity config, defaulting to 1 if missing.
    return 1;
};

// -----------------------------------------------------------------------------
// RECONCILIATION LOOP
// -----------------------------------------------------------------------------

// Call this from a logic_timer or MainThink
::flagspawn.Think <- function() {
    ::flagspawn._ReconcileFlagBodygroups();
    return 0.25; // Run 4 times a second
}

::flagspawn._ReconcileFlagBodygroups <- function() {
    if (!::flagspawn.USE_FLAG_MODEL_BODYGROUP) return;

    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        if (f.IsValid()) {
            local val = ::flagspawn._GetFlagPointsValue(f);
            
            // 1. Update Visuals
            ::flagspawn._UpdateFlagBodygroup(f, val);
            
            // 2. Attempt Manual Merge Fix (Collision Check)
            // If the custom model has bad physics, players might step on it without picking it up.
            // We check for nearby players and force a touch/pickup if very close.
            ::flagspawn._CheckProximityPickup(f);
        }
    }
};

::flagspawn._CheckProximityPickup <- function(flag) {
    // Look for players within 32 units
    local p = null;
    local flagOrigin = flag.GetOrigin();
    
    while ((p = Entities.FindByClassname(p, "player")) != null) {
        if (p.IsValid() && p.GetHealth() > 0) {
            local dist = (p.GetOrigin() - flagOrigin).Length();
            if (dist < 40.0) {
                // If the player is this close and hasn't picked it up, 
                // the collision model might be failing. 
                // We can nudge the flag or force a touch.
                
                // Only do this if the flag is "Idle" (not captured/returned)
                // native m_nFlagStatus: 0=home, 1=dropped, 2=carried
                // For PD flags, they are usually dropped (1).
                
                // Simple nudge towards player to wake physics
                /*
                local vel = (p.GetOrigin() - flagOrigin);
                vel.Norm();
                flag.SetVelocity(Vector(vel.x * 10, vel.y * 10, 200));
                */
            }
        }
    }
}

::flagspawn.Log <- function(msg) {
    printl("[flagspawn] " + msg);
}

// -----------------------------------------------------------------------------
// EVENT HOOKS
// -----------------------------------------------------------------------------

// Hook into game events to track points
// Note: You must register these in your logic_script or OnPostSpawn
function OnGameEvent_teamplay_flag_event(params) {
    // params: player, carrier, eventtype, priority
    // eventtype 4 = picked up
    
    local p = GetPlayerFromUserID(params.player);
    if (params.eventtype == 4 && p) {
        // Player picked up a flag
        // In PD, this usually destroys the entity and adds to player count.
        // If we need to track points, we rely on the logic that spawned it.
        ::flagspawn.Log("Flag Pickup by " + p);
    }
}

// Helper to get player from ID
function GetPlayerFromUserID(userid) {
    local pl = null;
    while ((pl = Entities.FindByClassname(pl, "player")) != null) {
        if (pl.GetScriptScope() && pl.GetScriptScope().userid == userid) return pl; // fallback
        if (NetProps.GetPropInt(pl, "m_iUserID") == userid) return pl;
    }
    return null;
}

// -----------------------------------------------------------------------------
// BOOTSTRAP
// -----------------------------------------------------------------------------

::flagspawn.Log("LOADED PD v5 - Slab Model: " + ::flagspawn.FLAG_MODEL);