//==============================================================
// Flagspawn (PD Fuel) - MINIMAL CORE REWRITE
// Focus: spawn PD pickups reliably, PD merge works, visual meter on back + ground.
//==============================================================
//
// Map wiring (from README):
//  - logic_script targetname: scripter, script: flagspawn.nut
//  - spawner triggers call:
//      flagspawn.OnSpawnerTouch(activator, 3)   // redtrigger (BLU base) => spawns for RED? (beneficiary=3)
//      flagspawn.OnSpawnerTouch(activator, 2)   // blutrigger (RED base) => spawns for BLU? (beneficiary=2)
//  - pooled flags in map:
//      fs_pool_red_01..25 (item_teamflag)
//      fs_pool_blu_01..25 (item_teamflag)
//
// NOTE: PD stacking/merging is hardcoded when item_teamflag GameType=6.
// We do NOT re-implement merging. We only:
//   - dispense PD pickups from a pool
//   - set their per-flag value (best-effort; see _SetPDValueOnFlag)
//   - track flag entities + attach a meter proxy prop_dynamic to show value
//   - keep the meter on the carrier's back via SetParent + SetParentAttachment "flag"
//   - keep the meter on the dropped pickup on the ground by parenting to the flag
//
// Docs used:
//  - item_teamflag supports SetParent/SetParentAttachment/ClearParent inputs, and player attachment "flag" exists【turn9file2†L1-L5】.
//==============================================================

::flagspawn <- {}

flagspawn.TEAM_RED <- 2
flagspawn.TEAM_BLU <- 3
flagspawn.TEAM_NONE <- 0

flagspawn.CFG <- {
    DEBUG = true,

    // what each dispense is worth (for this "core test" phase you asked for)
    DISPENSE_VALUE = 3,

    // If true: a player can only be dispensed 1 pickup per life.
    // You requested this be disabled so you can spam 3-point pickups.
    ONE_PER_LIFE = false,

    // Cooldown per player to avoid accidental double-dispense in the trigger volume.
    DISPENSE_COOLDOWN = 0.35,

    // When we "drop on your head", place the pickup here:
    DISPENSE_FWD = 24.0,
    DISPENSE_UP  = 52.0,

    // Meter proxy
    METER_MODEL = "models/props_custom/fs_meter/fs_meter_slab_grid.mdl",
    // Bodygroup index for fill (usually 0 in your models)
    METER_BODYGROUP = 0,

    // If your meter needs scale tweaks for readability:
    METER_SCALE_SINGLE = 1.0,
    METER_SCALE_DOUBLE = 0.75,

    // Where to stash pooled flags
    POOL_STASH_ORIGIN = Vector(0, 0, -8000),

    // sanity clamp for visuals
    VALUE_CLAMP_MAX = 99,
}

flagspawn.State <- {
    Inited = false,

    // pools (arrays of handles)
    PoolRed = [],
    PoolBlu = [],

    // next dispense index (simple round-robin)
    PoolIdxRed = 0,
    PoolIdxBlu = 0,

    // per-player cooldown + per-life tracking
    NextDispenseTime = {},   // userid -> time
    GivenThisLife = {},      // userid -> bool

    // tracked flags: entindex -> table{ value, meter, carrier_userid }
    Flags = {},
}

flagspawn._Log <- function(msg) {
    if (!flagspawn.CFG.DEBUG) return
    printl("[FLAGSPAWN] " + msg)
}

flagspawn._ClampInt <- function(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
}

flagspawn._EntIndex <- function(h) {
    if (!h) return -1
    try { return h.entindex() } catch(e) { return -1 }
}

flagspawn._Now <- function() { return Time() }

flagspawn._IsPlayer <- function(ent) {
    return ent && ent.IsValid && ent.IsValid() && ent.GetClassname && ent.GetClassname() == "player"
}

//--------------------------------------------------------------
// INIT / POOLS
//--------------------------------------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.Inited) return
    flagspawn.State.Inited = true

    flagspawn._Log("Init()")

    flagspawn._RebuildPoolsByScan()

    // Hook events (merge-friendly; OnPickup outputs can be buggy in PD when already carrying)
    // We still listen to these for debugging + meter parenting updates.
    if ("ListenToGameEvent" in getroottable()) {
        ListenToGameEvent("teamplay_flag_event", flagspawn._OnTeamplayFlagEvent, flagspawn)
        ListenToGameEvent("player_death", flagspawn._OnPlayerDeath, flagspawn)
        ListenToGameEvent("player_spawn", flagspawn._OnPlayerSpawn, flagspawn)
    } else {
        flagspawn._Log("WARNING: ListenToGameEvent missing in this environment.")
    }

    // Think loop to clean up invalid refs
    AddThinkToEnt(Entities.First(), "flagspawn._Think")
}

flagspawn._RebuildPoolsByScan <- function() {
    flagspawn.State.PoolRed.clear()
    flagspawn.State.PoolBlu.clear()
    flagspawn.State.PoolIdxRed = 0
    flagspawn.State.PoolIdxBlu = 0

    local e = null
    while ((e = Entities.FindByClassname(e, "item_teamflag")) != null) {
        local nm = ""
        try { nm = e.GetName() } catch(_e) { nm = "" }

        if (nm.len() >= 12 && nm.slice(0, 12) == "fs_pool_red_") {
            flagspawn.State.PoolRed.append(e)
            flagspawn._PrepPoolFlag(e)
        } else if (nm.len() >= 12 && nm.slice(0, 12) == "fs_pool_blu_") {
            flagspawn.State.PoolBlu.append(e)
            flagspawn._PrepPoolFlag(e)
        }
    }

    flagspawn._Log("Pool init(scan): red=" + flagspawn.State.PoolRed.len() + " blu=" + flagspawn.State.PoolBlu.len())
}

// Put pooled flags into a safe "inactive" state.
flagspawn._PrepPoolFlag <- function(flag) {
    if (!flag) return
    // stash + disable, neutral teamnum 0 so it doesn't act like intel
    EntFireByHandle(flag, "ClearParent", "", 0.0, null, null)
    EntFireByHandle(flag, "Disable", "", 0.0, null, null)
    EntFireByHandle(flag, "SetTeam", "" + flagspawn.TEAM_NONE, 0.0, null, null)
    try { flag.SetAbsOrigin(flagspawn.CFG.POOL_STASH_ORIGIN) } catch(e) {}
}

// Dispense a flag from pool; returns handle or null
flagspawn._DispenseFromPool <- function(beneficiaryTeam) {
    local pool = (beneficiaryTeam == flagspawn.TEAM_RED) ? flagspawn.State.PoolRed : flagspawn.State.PoolBlu
    if (pool.len() <= 0) return null

    local idxRef = (beneficiaryTeam == flagspawn.TEAM_RED) ? "PoolIdxRed" : "PoolIdxBlu"
    local idx = flagspawn.State[idxRef] % pool.len()

    // find a valid flag; advance if invalid
    local tries = pool.len()
    while (tries > 0) {
        local f = pool[idx]
        if (f && f.IsValid()) {
            flagspawn.State[idxRef] = (idx + 1) % pool.len()
            return f
        }
        idx = (idx + 1) % pool.len()
        tries--
    }
    return null
}

//--------------------------------------------------------------
// SPAWNER TOUCH
//--------------------------------------------------------------
flagspawn.OnSpawnerTouch <- function(activator, beneficiaryTeam) {
    // beneficiaryTeam is the team that "owns" this pickup for fuel/return rules in later phases.
    if (!flagspawn.State.Inited) flagspawn.Init()
    if (!flagspawn._IsPlayer(activator)) return

    local userid = activator.GetPlayerUserId()
    local now = flagspawn._Now()

    // cooldown
    if (userid in flagspawn.State.NextDispenseTime && flagspawn.State.NextDispenseTime[userid] > now) {
        return
    }
    flagspawn.State.NextDispenseTime[userid] <- now + flagspawn.CFG.DISPENSE_COOLDOWN

    // one-per-life (disabled by default per your request)
    if (flagspawn.CFG.ONE_PER_LIFE) {
        if (userid in flagspawn.State.GivenThisLife && flagspawn.State.GivenThisLife[userid]) return
        flagspawn.State.GivenThisLife[userid] <- true
    }

    local flag = flagspawn._DispenseFromPool(beneficiaryTeam)
    if (!flag) {
        flagspawn._Log("DISPENSE FAIL: pool empty for team " + beneficiaryTeam)
        return
    }

    // Detach from pool + enable
    EntFireByHandle(flag, "ClearParent", "", 0.0, null, null)

    // Make it a PD pickup (GameType=6 should already be set in Hammer on the pooled flags,
    // but we keep the value-setting here in case you change pools.)
    // We DO NOT SetModel in KV to avoid disk lookup lag; set model in Hammer or elsewhere【turn9file18†L1-L4】.

    // Put it in front of player, slightly up (so it falls/touches and gives good feedback).
    local org = activator.GetAbsOrigin()
    local fwd = activator.GetForwardVector()
    local spawnPos = org + fwd * flagspawn.CFG.DISPENSE_FWD + Vector(0,0, flagspawn.CFG.DISPENSE_UP)

    try { flag.SetAbsOrigin(spawnPos) } catch(e) {}

    EntFireByHandle(flag, "SetTeam", "" + flagspawn.TEAM_NONE, 0.0, null, null) // neutral PD pickup
    EntFireByHandle(flag, "Enable", "", 0.0, null, null)

    // Assign the value (best effort). PD will use its own internal logic; we try to match it.
    local v = flagspawn._ClampInt(flagspawn.CFG.DISPENSE_VALUE, 1, flagspawn.CFG.VALUE_CLAMP_MAX)
    flagspawn._SetPDValueOnFlag(flag, v)

    // Track it + spawn/attach its meter (meter will re-parent on pickup event)
    flagspawn._RegisterFlag(flag, v)

    // Put meter on the dropped pickup immediately (ground view). When PD picks it up, we move it to back.
    flagspawn._AttachMeterToFlag(flag)

    flagspawn._Log("Dispensed value=" + v + " to player userid=" + userid + " team=" + beneficiaryTeam)
}

//--------------------------------------------------------------
// FLAG VALUE + VISUALS
//--------------------------------------------------------------
flagspawn._RegisterFlag <- function(flag, value) {
    local ei = flagspawn._EntIndex(flag)
    if (ei < 0) return

    if (!(ei in flagspawn.State.Flags)) {
        flagspawn.State.Flags[ei] <- { value = value, meter = null, carrier_userid = 0 }
    } else {
        flagspawn.State.Flags[ei].value = value
    }

    // Ensure meter exists
    if (!flagspawn.State.Flags[ei].meter || !flagspawn.State.Flags[ei].meter.IsValid()) {
        flagspawn.State.Flags[ei].meter = flagspawn._SpawnMeterProxy()
    }

    // Apply bodygroup to meter
    flagspawn._SetMeterValue(flagspawn.State.Flags[ei].meter, value)
}

flagspawn._SpawnMeterProxy <- function() {
    local kv = {
        targetname = "fs_meter_proxy_" + UniqueString("m"),
        model = flagspawn.CFG.METER_MODEL,
        solid = 0,
        rendermode = 0,
        disableshadows = 1,
    }
    local p = SpawnEntityFromTable("prop_dynamic", kv)
    if (!p) return null

    // Hide until we parent it somewhere
    try { p.SetAbsOrigin(flagspawn.CFG.POOL_STASH_ORIGIN) } catch(e) {}
    try { p.SetModelScale(flagspawn.CFG.METER_SCALE_SINGLE, 0.0) } catch(e) {}

    // Optional: you can attach tf_glow in Hammer or later; this script doesn’t require it for core testing.
    return p
}

flagspawn._SetMeterValue <- function(meter, value) {
    if (!meter || !meter.IsValid()) return
    local v = flagspawn._ClampInt(value, 0, flagspawn.CFG.VALUE_CLAMP_MAX)

    // scale tweak: 2-digit (>=10) uses 0.75 per your cosmetic rule
    local sc = (v >= 10) ? flagspawn.CFG.METER_SCALE_DOUBLE : flagspawn.CFG.METER_SCALE_SINGLE
    try { meter.SetModelScale(sc, 0.0) } catch(e) {}

    // Bodygroup set by input (works even without sequences)
    EntFireByHandle(meter, "SetBodyGroup", "" + v, 0.0, null, null)
}

flagspawn._AttachMeterToPlayer <- function(flag, player) {
    local ei = flagspawn._EntIndex(flag)
    if (!(ei in flagspawn.State.Flags)) return
    local data = flagspawn.State.Flags[ei]
    if (!data.meter || !data.meter.IsValid()) data.meter = flagspawn._SpawnMeterProxy()
    if (!data.meter) return

    // Parent meter to player and use the "flag" attachment on players【turn9file2†L1-L5】.
    // Note: inputs require targetname, so ensure player has a name.
    local pname = player.GetName()
    if (pname == null || pname == "") {
        pname = "fs_p_" + player.entindex()
        try { player.__KeyValueFromString("targetname", pname) } catch(e) {}
    }

    EntFireByHandle(data.meter, "ClearParent", "", 0.0, null, null)
    EntFireByHandle(data.meter, "SetParent", pname, 0.0, null, null)
    EntFireByHandle(data.meter, "SetParentAttachment", "flag", 0.01, null, null)

    // keep the actual item_teamflag un-parented (PD handles its carry visual/logic)
    data.carrier_userid = player.GetPlayerUserId()

    flagspawn._SetMeterValue(data.meter, data.value)
}

flagspawn._AttachMeterToFlag <- function(flag) {
    local ei = flagspawn._EntIndex(flag)
    if (!(ei in flagspawn.State.Flags)) return
    local data = flagspawn.State.Flags[ei]
    if (!data.meter || !data.meter.IsValid()) data.meter = flagspawn._SpawnMeterProxy()
    if (!data.meter) return

    local fname = flag.GetName()
    if (fname == null || fname == "") {
        fname = "fs_f_" + ei
        try { flag.__KeyValueFromString("targetname", fname) } catch(e) {}
    }

    EntFireByHandle(data.meter, "ClearParent", "", 0.0, null, null)
    EntFireByHandle(data.meter, "SetParent", fname, 0.0, null, null)
    EntFireByHandle(data.meter, "SetParentAttachment", "origin", 0.01, null, null)

    data.carrier_userid = 0
    flagspawn._SetMeterValue(data.meter, data.value)
}

// Try to set the value in a way PD will respect.
// This is necessarily "best effort" because TF2’s PD internals aren’t fully exposed in VScript.
// For your test goal (bottom-left PD points increasing), this is the key hook to iterate on.
flagspawn._SetPDValueOnFlag <- function(flag, value) {
    // 1) Try keyvalues (common patterns: point_value / PointValue / n_strength).
    // These calls are safe: if the KV doesn’t exist, it usually no-ops.
    try { flag.__KeyValueFromInt("point_value", value) } catch(e) {}
    try { flag.__KeyValueFromInt("PointValue", value) } catch(e) {}
    try { flag.__KeyValueFromInt("n_strength", value) } catch(e) {}
    try { flag.__KeyValueFromInt("strength", value) } catch(e) {}

    // 2) Try netprops (if present). Wrapped so it never crashes if prop name is wrong.
    // You’ll confirm the correct prop name by printing with netprops tools or trial.
    if ("NetProps" in getroottable()) {
        try { NetProps.SetPropInt(flag, "m_nPointValue", value) } catch(e) {}
        try { NetProps.SetPropInt(flag, "m_nFlagValue", value) } catch(e) {}
        try { NetProps.SetPropInt(flag, "m_nPoints", value) } catch(e) {}
    }

    // 3) Cache our value for visuals even if PD ignores it.
    local ei = flagspawn._EntIndex(flag)
    if (ei >= 0) {
        if (!(ei in flagspawn.State.Flags)) flagspawn.State.Flags[ei] <- { value = value, meter = null, carrier_userid = 0 }
        else flagspawn.State.Flags[ei].value = value
    }
}

//--------------------------------------------------------------
// EVENTS
//--------------------------------------------------------------

// teamplay_flag_event tip for tracking PD merges【turn9file8†L1-L2】
// We use it to move the meter between "ground" and "back".
flagspawn._OnTeamplayFlagEvent <- function(ev) {
    // Fields vary by build; we only use what exists.
    // Typical: ev.eventtype, ev.player (userid), ev.team, ev.flagname, ev.carrier, etc.
    local et = ("eventtype" in ev) ? ev.eventtype : -1
    local userid = ("player" in ev) ? ev.player : (("userid" in ev) ? ev.userid : 0)
    local flagname = ("flagname" in ev) ? ev.flagname : ""

    // best-effort resolve flag handle by name (when present)
    local flag = null
    if (flagname != "") flag = Entities.FindByName(null, flagname)

    // Resolve player handle
    local ply = (userid != 0) ? GetPlayerFromUserID(userid) : null

    // We don't rely on exact constants here; we use validity + whether player exists.
    // If the flag exists and a player exists, we treat as "picked up" and parent meter to player.
    if (flag && ply) {
        // On PD merge, a player already carrying may not fire OnPickup outputs,
        // but this event is the recommended multi-flag tracking path【turn9file8†L1-L2】.
        flagspawn._AttachMeterToPlayer(flag, ply)
        flagspawn._Log("flag_event type=" + et + " pickup-ish flag=" + flagname + " userid=" + userid)
        return
    }

    // If we have a flag but no player, treat as drop/return/cap and put meter back on flag.
    if (flag) {
        flagspawn._AttachMeterToFlag(flag)
        flagspawn._Log("flag_event type=" + et + " drop-ish flag=" + flagname)
    }
}

flagspawn._OnPlayerDeath <- function(ev) {
    local userid = ("userid" in ev) ? ev.userid : 0
    if (userid == 0) return
    flagspawn.State.GivenThisLife[userid] <- false
}

flagspawn._OnPlayerSpawn <- function(ev) {
    local userid = ("userid" in ev) ? ev.userid : 0
    if (userid == 0) return
    flagspawn.State.GivenThisLife[userid] <- false
}

//--------------------------------------------------------------
// THINK: cleanup + optional resync (low frequency)
//--------------------------------------------------------------
flagspawn._Think <- function() {
    // Clean invalid flags/meters from table
    local toDelete = []
    foreach (ei, data in flagspawn.State.Flags) {
        // flag validity
        local flag = EntIndexToHScript(ei)
        if (!flag || !flag.IsValid()) {
            if (data.meter && data.meter.IsValid()) {
                EntFireByHandle(data.meter, "ClearParent", "", 0.0, null, null)
                try { data.meter.SetAbsOrigin(flagspawn.CFG.POOL_STASH_ORIGIN) } catch(e) {}
            }
            toDelete.append(ei)
            continue
        }

        // meter validity
        if (!data.meter || !data.meter.IsValid()) {
            data.meter = flagspawn._SpawnMeterProxy()
        }

        // Keep meter showing our cached value
        if (data.meter) flagspawn._SetMeterValue(data.meter, data.value)
    }

    foreach (ei in toDelete) delete flagspawn.State.Flags[ei]

    return 0.25
}

//--------------------------------------------------------------
// Autostart when script is executed (works for script_execute as well)
//--------------------------------------------------------------
flagspawn.Init()

