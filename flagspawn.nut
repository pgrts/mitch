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
// NOTE: PD stacking/merging is hardcoded when item_teamflag GameType=6 (PD).
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

// TF2 VScript uses an older Squirrel; avoid `??` and always anchor the table in the root.
local _rt = getroottable()
if (!("flagspawn" in _rt)) {
    _rt.flagspawn <- {}
} else {
    try {
        if (typeof _rt.flagspawn != "table") _rt.flagspawn <- {}
    } catch (_e) {
        _rt.flagspawn <- {}
    }
}
local flagspawn = _rt.flagspawn
try {
    if (!("flagspawn" in this)) this.flagspawn <- _rt.flagspawn
    else this.flagspawn = _rt.flagspawn
} catch (_e) {}

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

    // Map listener entity (logic_eventlistener) used when ListenToGameEvent isn't available.
    FLAG_LISTENER_NAME = "flag_listener",

    // item_teamflag GameType for Player Destruction (PD).
    // Per VDC item_teamflag docs: 6 = Player Destruction, 5 = Robot Destruction.
    PD_GAMETYPE = 6,

    // If true, flags are assigned to a team and the other team can't pick them up.
    // If false, dispensed flags are neutral (team 0).
    RESTRICT_PICKUP_TO_TEAM = true,

    // Meter glow (tf_glow) on the proxy prop_dynamic.
    ENABLE_METER_GLOW = true,
    GLOW_RED = "255 0 0 255",
    GLOW_BLU = "0 0 255 255",
    GLOW_NEUTRAL = "255 255 255 255",

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

    WarnedNoEventData = false,

    // player entindex -> meter handle (lets us poll carried points when events aren't hookable)
    PlayerMeters = {},
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

flagspawn._GlowColorForTeam <- function(team) {
    if (team == flagspawn.TEAM_RED) return flagspawn.CFG.GLOW_RED
    if (team == flagspawn.TEAM_BLU) return flagspawn.CFG.GLOW_BLU
    return flagspawn.CFG.GLOW_NEUTRAL
}

flagspawn._EntIndex <- function(h) {
    if (!h) return -1
    try { return h.entindex() } catch(e) { return -1 }
}

flagspawn._IsUsableEnt <- function(h) {
    // Some TF2 entity states can make IsValid() unreliable; entindex() is the safest probe.
    if (!h) return false
    try { h.entindex(); return true } catch (e) { return false }
}

flagspawn._Now <- function() { return Time() }

flagspawn._IsPlayer <- function(ent) {
    return ent && ent.IsValid && ent.IsValid() && ent.GetClassname && ent.GetClassname() == "player"
}

// Helper wrappers: keep them on flagspawn, plus global aliases for mixed call sites.
flagspawn._GetOrigin <- function(ent) {
    if (!ent) return Vector(0, 0, 0)
    try { if ("GetOrigin" in ent) return ent.GetOrigin() } catch(e) {}
    try { if ("GetAbsOrigin" in ent) return ent.GetAbsOrigin() } catch(e) {}
    return Vector(0, 0, 0)
}

flagspawn._SetOrigin <- function(ent, pos) {
    if (!ent) return
    try { if ("SetAbsOrigin" in ent) { ent.SetAbsOrigin(pos); return } } catch(e) {}
    try { if ("SetOrigin" in ent) { ent.SetOrigin(pos); return } } catch(e) {}
}

flagspawn._GetForward <- function(ent) {
    if (!ent) return Vector(1, 0, 0)
    try { if ("GetForwardVector" in ent) return ent.GetForwardVector() } catch(e) {}
    try {
        if ("EyeAngles" in ent) return ent.EyeAngles().Forward()
        if ("GetAbsAngles" in ent) return ent.GetAbsAngles().Forward()
    } catch(e) {}
    return Vector(1, 0, 0)
}

if (!("_GetOrigin" in getroottable())) ::_GetOrigin <- function(ent) { return flagspawn._GetOrigin(ent) }
if (!("_SetOrigin" in getroottable())) ::_SetOrigin <- function(ent, pos) { return flagspawn._SetOrigin(ent, pos) }
if (!("_GetForward" in getroottable())) ::_GetForward <- function(ent) { return flagspawn._GetForward(ent) }

flagspawn._GetPlayerCarriedPoints <- function(ply) {
    if (!ply) return 0
    if (!("NetProps" in getroottable())) return 0

    // TF2 PD carried-points netprop names vary by build/mod; try a few common candidates.
    foreach (propName in [
        "m_nNumCarriedPoints",
        "m_nNumCarried",
        "m_nCarried",
        "m_nCarriedPoints",
        "m_nCurrentPoints",
        "m_nPoints"
    ]) {
        try {
            local v = NetProps.GetPropInt(ply, propName)
            if (typeof v == "integer" && v >= 0) return v
        } catch (e) {}
    }
    return 0
}

flagspawn._EnsurePDFlag <- function(flag) {
    if (!flag) return
    // Best-effort: force the flag into PD behavior (otherwise it behaves like SD/CTF and won't "merge").
    try { flag.__KeyValueFromInt("GameType", flagspawn.CFG.PD_GAMETYPE) } catch (e) {}
    EntFireByHandle(flag, "AddOutput", "GameType " + flagspawn.CFG.PD_GAMETYPE, 0.0, null, null)
    try { flag.__KeyValueFromInt("NeutralType", 1) } catch (e) {}
    EntFireByHandle(flag, "AddOutput", "NeutralType 1", 0.0, null, null)
}

flagspawn._HideFlagModel <- function(flag) {
    if (!flag) return
    // Hide the briefcase model while keeping the pickup/collision active.
    // (effects 32 = EF_NODRAW, rendermode 10 = kRenderTransAlpha, renderamt 0 = fully transparent)
    try { flag.AddEffects(32) } catch (e) {}
    try { flag.__KeyValueFromInt("effects", 32) } catch (e) {}
    try { flag.__KeyValueFromInt("rendermode", 10) } catch (e) {}
    try { flag.__KeyValueFromInt("renderamt", 0) } catch (e) {}
    EntFireByHandle(flag, "AddOutput", "effects 32", 0.0, null, null)
    EntFireByHandle(flag, "AddOutput", "rendermode 10", 0.0, null, null)
    EntFireByHandle(flag, "AddOutput", "renderamt 0", 0.0, null, null)
}

flagspawn._SetFlagTeam <- function(flag, team) {
    if (!flag) return
    // SetTeam input exists on item_teamflag. TeamNum key is also written for robustness.
    EntFireByHandle(flag, "SetTeam", "" + team, 0.0, null, null)
    try { flag.__KeyValueFromInt("TeamNum", team) } catch (e) {}
    EntFireByHandle(flag, "AddOutput", "TeamNum " + team, 0.0, null, null)
}

//--------------------------------------------------------------
// INIT / POOLS
//--------------------------------------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.Inited) return
    flagspawn.State.Inited = true

    flagspawn._Log("Init()")
    // Optional: use a Hammer logic_eventlistener instead of (or in addition to) ListenToGameEvent.
    // Wire: logic_eventlistener (event_name=teamplay_flag_event, fetch_event_data=Yes) ->
    //       OnEventFired -> logic_script "scripter" : CallScriptFunction : FS_OnFlagEvent : 0
    // FS_OnFlagEvent() below will read activator.event_data and route it to the same handler.

    flagspawn._RebuildPoolsByScan()

    // Hook events (merge-friendly; OnPickup outputs can be buggy in PD when already carrying)
    // We still listen to these for debugging + meter parenting updates.
    if ("ListenToGameEvent" in getroottable()) {
        ListenToGameEvent("teamplay_flag_event", flagspawn._OnTeamplayFlagEvent, flagspawn)
        ListenToGameEvent("player_death", flagspawn._OnPlayerDeath, flagspawn)
        ListenToGameEvent("player_spawn", flagspawn._OnPlayerSpawn, flagspawn)
    } else {
        flagspawn._Log("WARNING: ListenToGameEvent missing; using logic_eventlistener only.")
        local l = null
        try { l = Entities.FindByName(null, flagspawn.CFG.FLAG_LISTENER_NAME) } catch (_e) { l = null }
        if (!l) flagspawn._Log("WARNING: no logic_eventlistener named '" + flagspawn.CFG.FLAG_LISTENER_NAME + "' found (merges won't update meter unless OnPickup outputs work).")
    }

    // Think loop to clean up invalid refs
    AddThinkToEnt(Entities.First(), "flagspawn._Think")
}

flagspawn._RebuildPoolsByScan <- function() {
    flagspawn.State.PoolRed.clear()
    flagspawn.State.PoolBlu.clear()
    flagspawn.State.PoolIdxRed = 0
    flagspawn.State.PoolIdxBlu = 0

    local total = 0
    local other = []

    local e = null
    while ((e = Entities.FindByClassname(e, "item_teamflag")) != null) {
        total++
        local nm = ""
        try { nm = e.GetName() } catch(_e) { nm = "" }

        if (nm.len() >= 12 && nm.slice(0, 12) == "fs_pool_red_") {
            flagspawn.State.PoolRed.append(e)
            flagspawn._PrepPoolFlag(e)
        } else if (nm.len() >= 12 && nm.slice(0, 12) == "fs_pool_blu_") {
            flagspawn.State.PoolBlu.append(e)
            flagspawn._PrepPoolFlag(e)
        } else {
            if (other.len() < 8) other.append(nm)
        }
    }

    flagspawn._Log("Pool init(scan): red=" + flagspawn.State.PoolRed.len() + " blu=" + flagspawn.State.PoolBlu.len())
    if (flagspawn.State.PoolRed.len() == 0 && flagspawn.State.PoolBlu.len() == 0) {
        if (total == 0) {
            flagspawn._Log("Pool scan found 0 item_teamflag entities. Wrong BSP loaded, entities missing, or executed before map spawned.")
        } else {
            flagspawn._Log("Pool scan saw item_teamflag but none matched fs_pool_red_*/fs_pool_blu_*; examples: " + other.tostring())
        }
        flagspawn._Log("Run: script flagspawn.DumpTeamFlags() to see what the map actually has.")
    }
}

// Put pooled flags into a safe "inactive" state.
flagspawn._PrepPoolFlag <- function(flag) {
    if (!flag) return
    flagspawn._EnsurePDFlag(flag)
    flagspawn._HideFlagModel(flag)
    // stash + disable, neutral teamnum 0 so it doesn't act like intel
    EntFireByHandle(flag, "ClearParent", "", 0.0, null, null)
    EntFireByHandle(flag, "Disable", "", 0.0, null, null)
    flagspawn._SetFlagTeam(flag, flagspawn.TEAM_NONE)
    try { flag.SetAbsOrigin(flagspawn.CFG.POOL_STASH_ORIGIN) } catch(e) {}
}

// Debug helper: prints teamflags found in the map.
flagspawn.DumpTeamFlags <- function(limit = 64) {
    local e = null
    local n = 0
    while ((e = Entities.FindByClassname(e, "item_teamflag")) != null) {
        local nm = ""
        try { nm = e.GetName() } catch (_e) { nm = "" }
        local org = flagspawn._GetOrigin(e)
        flagspawn._Log("teamflag[" + n + "] name='" + nm + "' org=" + org)
        n++
        if (n >= limit) break
    }
    flagspawn._Log("DumpTeamFlags: total_shown=" + n)
}

flagspawn.DumpPools <- function(limit = 12) {
    local dump = function(label, pool) {
        flagspawn._Log(label + " len=" + pool.len())
        local n = (pool.len() < limit) ? pool.len() : limit
        for (local i = 0; i < n; i++) {
            local f = pool[i]
            local ok = flagspawn._IsUsableEnt(f)
            local nm = ""
            local ei = -1
            try { if (f) { nm = f.GetName(); ei = f.entindex(); } } catch (_e) { nm = ""; ei = -1 }
            flagspawn._Log("  [" + i + "] ok=" + ok + " ei=" + ei + " name='" + nm + "'")
        }
    }
    dump("PoolRed", flagspawn.State.PoolRed)
    dump("PoolBlu", flagspawn.State.PoolBlu)
}

// Dispense a flag from pool; returns handle or null
flagspawn._DispenseFromPool <- function(beneficiaryTeam) {
    local isRed = (beneficiaryTeam == flagspawn.TEAM_RED)
    local pool = isRed ? flagspawn.State.PoolRed : flagspawn.State.PoolBlu
    if (pool.len() <= 0) {
        // If init ran before the map/entities were ready (or map changed), rescan once.
        flagspawn._RebuildPoolsByScan()
        pool = isRed ? flagspawn.State.PoolRed : flagspawn.State.PoolBlu
        if (pool.len() <= 0) return null
    }

    local idxRef = (beneficiaryTeam == flagspawn.TEAM_RED) ? "PoolIdxRed" : "PoolIdxBlu"
    local idx = flagspawn.State[idxRef] % pool.len()

    // find a valid flag; advance if invalid
    local tries = pool.len()
    local invalid = 0
    while (tries > 0) {
        local f = pool[idx]
        if (flagspawn._IsUsableEnt(f)) {
            flagspawn.State[idxRef] = (idx + 1) % pool.len()
            return f
        }
        invalid++
        idx = (idx + 1) % pool.len()
        tries--
    }

    // If we had entries but none were valid, the map probably changed or entities were removed.
    // Rebuild pools once and retry.
    flagspawn._Log("Dispense: pool had " + pool.len() + " entries but " + invalid + " were invalid; rescanning.")
    flagspawn._RebuildPoolsByScan()
    pool = isRed ? flagspawn.State.PoolRed : flagspawn.State.PoolBlu
    if (pool.len() <= 0) return null
    idx = flagspawn.State[idxRef] % pool.len()
    tries = pool.len()
    while (tries > 0) {
        local f2 = pool[idx]
        if (flagspawn._IsUsableEnt(f2)) {
            flagspawn.State[idxRef] = (idx + 1) % pool.len()
            return f2
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

    // Reduce Hammer-wiring footguns: if pickup is team-restricted, default to the toucher’s team.
    local activatorTeam = 0
    try { activatorTeam = activator.GetTeam() } catch (_e) { activatorTeam = 0 }
    if (beneficiaryTeam != flagspawn.TEAM_RED && beneficiaryTeam != flagspawn.TEAM_BLU) {
        beneficiaryTeam = activatorTeam
    } else if (flagspawn.CFG.RESTRICT_PICKUP_TO_TEAM && activatorTeam != 0 && beneficiaryTeam != activatorTeam) {
        flagspawn._Log("SpawnerTouch: overriding beneficiaryTeam=" + beneficiaryTeam + " -> " + activatorTeam + " (team-restricted pickup).")
        beneficiaryTeam = activatorTeam
    }

    // If pools are empty (common after map swaps without a clean script reload), rescan now.
    if (flagspawn.State.PoolRed.len() == 0 && flagspawn.State.PoolBlu.len() == 0) {
        flagspawn._RebuildPoolsByScan()
    }

    local pid = activator.entindex() // TF2: GetPlayerUserId doesn't exist
    local now = flagspawn._Now()

    // cooldown
    if (pid in flagspawn.State.NextDispenseTime && flagspawn.State.NextDispenseTime[pid] > now) {
        return
    }
    flagspawn.State.NextDispenseTime[pid] <- now + flagspawn.CFG.DISPENSE_COOLDOWN

    // one-per-life (disabled by default per your request)
    if (flagspawn.CFG.ONE_PER_LIFE) {
        if (pid in flagspawn.State.GivenThisLife && flagspawn.State.GivenThisLife[pid]) return
        flagspawn.State.GivenThisLife[pid] <- true
    }

    local flag = flagspawn._DispenseFromPool(beneficiaryTeam)
    if (!flag) {
        flagspawn._Log("DISPENSE FAIL: pool empty for team " + beneficiaryTeam)
        return
    }

    // Detach from pool + enable
    EntFireByHandle(flag, "ClearParent", "", 0.0, null, null)

    // Force PD behavior + hide the briefcase model (meter proxy is the visual).
    flagspawn._EnsurePDFlag(flag)
    flagspawn._HideFlagModel(flag)

    // Team rules: restrict pickup or leave neutral.
    local pickupTeam = flagspawn.CFG.RESTRICT_PICKUP_TO_TEAM ? beneficiaryTeam : flagspawn.TEAM_NONE
    flagspawn._SetFlagTeam(flag, pickupTeam)

    // Make it a PD pickup (GameType=6 should already be set in Hammer on the pooled flags,
    // but we keep the value-setting here in case you change pools.)
    // We DO NOT SetModel in KV to avoid disk lookup lag; set model in Hammer or elsewhere【turn9file18†L1-L4】.

    // Put it in front of player, slightly up (so it falls/touches and gives good feedback).
    // TF2 safety: never call GetAbsOrigin/GetForwardVector directly on players.
    local org = flagspawn._GetOrigin(activator)
    local fwd = flagspawn._GetForward(activator)
    local spawnPos = org + fwd * flagspawn.CFG.DISPENSE_FWD + Vector(0,0, flagspawn.CFG.DISPENSE_UP)

    // Set origin safely. (If you still see rare snap-back, we can add a logic_timer-based re-teleport.)
    flagspawn._SetOrigin(flag, spawnPos)

    // NOTE: SetTeam already applied above (team rules).

    // Assign the value (best effort) BEFORE enabling so PD reads it on activation.
    local v = flagspawn._ClampInt(flagspawn.CFG.DISPENSE_VALUE, 1, flagspawn.CFG.VALUE_CLAMP_MAX)
    flagspawn._SetPDValueOnFlag(flag, v)

    EntFireByHandle(flag, "Enable", "", 0.0, null, null)

    // Track it + spawn/attach its meter (meter will re-parent on pickup event)
    flagspawn._RegisterFlag(flag, v, pickupTeam)

    // Put meter on the dropped pickup immediately (ground view). When PD picks it up, we move it to back.
    flagspawn._AttachMeterToFlag(flag)

    flagspawn._Log("Dispensed value=" + v + " to player pid=" + pid + " team=" + beneficiaryTeam)
}

//--------------------------------------------------------------
// FLAG VALUE + VISUALS
//--------------------------------------------------------------
flagspawn._RegisterFlag <- function(flag, value, team = null) {
    local ei = flagspawn._EntIndex(flag)
    if (ei < 0) return

    if (!(ei in flagspawn.State.Flags)) {
        local t = team
        if (t == null) {
            try { t = flag.GetTeam() } catch (_e) { t = flagspawn.TEAM_NONE }
        }
        flagspawn.State.Flags[ei] <- { value = value, meter = null, glow = null, carrier_userid = 0, team = t }
    } else {
        flagspawn.State.Flags[ei].value = value
        if (team != null) flagspawn.State.Flags[ei].team = team
    }

    // Ensure meter exists
    if (!flagspawn.State.Flags[ei].meter || !flagspawn.State.Flags[ei].meter.IsValid()) {
        flagspawn.State.Flags[ei].meter = flagspawn._SpawnMeterProxy()
    }

    flagspawn._EnsureMeterGlow(flagspawn.State.Flags[ei])

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

flagspawn._EnsureMeterGlow <- function(data) {
    if (!flagspawn.CFG.ENABLE_METER_GLOW) return
    if (!data) return
    if (!("meter" in data) || !data.meter || !data.meter.IsValid()) return

    local team = ("team" in data) ? data.team : flagspawn.TEAM_NONE
    local color = flagspawn._GlowColorForTeam(team)

    // Update existing glow if present.
    if ("glow" in data && data.glow && data.glow.IsValid()) {
        try { data.glow.__KeyValueFromString("GlowColor", color) } catch (e) {}
        EntFireByHandle(data.glow, "AddOutput", "GlowColor " + color, 0.0, null, null)
        return
    }

    local targetName = ""
    try { targetName = data.meter.GetName() } catch (e) { targetName = "" }
    if (targetName == null || targetName == "") return

    local g = null
    try {
        g = SpawnEntityFromTable("tf_glow", {
            target = targetName,
            Mode = 0,
            GlowColor = color,
            StartDisabled = 0
        })
    } catch (e) { g = null }
    if (!g) return
    try { g.SetParent(data.meter, "") } catch (e) {}
    data.glow <- g
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

    flagspawn._EnsureMeterGlow(data)

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
    data.carrier_userid = player.entindex() // TF2: use entindex

    // Remember which meter is on this player so we can poll/refresh value even without teamplay_flag_event.
    flagspawn.State.PlayerMeters[data.carrier_userid] <- data.meter

    flagspawn._SetMeterValue(data.meter, data.value)
}

flagspawn._AttachMeterToFlag <- function(flag) {
    local ei = flagspawn._EntIndex(flag)
    if (!(ei in flagspawn.State.Flags)) return
    local data = flagspawn.State.Flags[ei]
    if (!data.meter || !data.meter.IsValid()) data.meter = flagspawn._SpawnMeterProxy()
    if (!data.meter) return

    flagspawn._EnsureMeterGlow(data)

    local fname = flag.GetName()
    if (fname == null || fname == "") {
        fname = "fs_f_" + ei
        try { flag.__KeyValueFromString("targetname", fname) } catch(e) {}
    }

    EntFireByHandle(data.meter, "ClearParent", "", 0.0, null, null)
    // Parent without attachments: item_teamflag doesn't expose an "origin" attachment.
    // We snap the proxy to the flag's world origin first so it stays visually aligned.
    flagspawn._SetOrigin(data.meter, flagspawn._GetOrigin(flag))
    EntFireByHandle(data.meter, "SetParent", fname, 0.0, null, null)

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
    EntFireByHandle(flag, "AddOutput", "PointValue " + value, 0.0, null, null)

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
        if (!(ei in flagspawn.State.Flags)) {
            local t = flagspawn.TEAM_NONE
            try { t = flag.GetTeam() } catch (_e) { t = flagspawn.TEAM_NONE }
            flagspawn.State.Flags[ei] <- { value = value, meter = null, glow = null, carrier_userid = 0, team = t }
        }
        else flagspawn.State.Flags[ei].value = value
    }
}

//--------------------------------------------------------------
// EVENTS
//--------------------------------------------------------------


// VMF logic_eventlistener entrypoint.
// When logic_eventlistener has FetchEventData enabled, it populates a table named "event_data" in its script scope.
// The listener entity is usually available as `caller` (and sometimes `activator`), so we read from its script scope.
function FS_OnFlagEvent()
{
    // Ensure core is up
    if (!flagspawn.State.Inited) flagspawn.Init()

    local listener = null
    try { if (caller && caller.IsValid()) listener = caller } catch (_e) {}
    try { if (!listener && activator && activator.IsValid()) listener = activator } catch (_e) {}
    if (!listener) {
        try { listener = Entities.FindByName(null, flagspawn.CFG.FLAG_LISTENER_NAME) } catch (_e) { listener = null }
    }
    if (!listener || !listener.IsValid()) return
    if (!listener.ValidateScriptScope()) return
    local scope = listener.GetScriptScope()
    if (!("event_data" in scope)) {
        if (!flagspawn.State.WarnedNoEventData) {
            flagspawn.State.WarnedNoEventData = true
            flagspawn._Log("FS_OnFlagEvent: no event_data on listener (set FetchEventData=1 on logic_eventlistener).")
        }
        return
    }
    local ev = scope.event_data
    if (typeof ev != "table") return

    // Route to the same handler used by ListenToGameEvent.
    flagspawn._OnTeamplayFlagEvent(ev)
}

// Alias in case you prefer a namespaced call in Hammer: flagspawn.FS_OnFlagEvent
flagspawn.FS_OnFlagEvent <- FS_OnFlagEvent

// Compatibility alias for older VMF wiring (RunScriptCode -> ::flagspawn.OnTeamplayFlagEvent()).
flagspawn.OnTeamplayFlagEvent <- function(ev = null) {
    if (typeof ev == "table") return flagspawn._OnTeamplayFlagEvent(ev)
    return FS_OnFlagEvent()
}

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
        local ei = flagspawn._EntIndex(flag)
        if (ei >= 0 && !(ei in flagspawn.State.Flags)) {
            local t = flagspawn.TEAM_NONE
            try { t = flag.GetTeam() } catch (_e) { t = flagspawn.TEAM_NONE }
            flagspawn.State.Flags[ei] <- { value = flagspawn.CFG.DISPENSE_VALUE, meter = null, glow = null, carrier_userid = userid, team = t }
        }

        flagspawn._AttachMeterToPlayer(flag, ply)

        // Best-effort: update the meter to the *current carried total* so merges are reflected.
        local carry = flagspawn._GetPlayerCarriedPoints(ply)
        if (carry > 0 && ei >= 0 && (ei in flagspawn.State.Flags)) {
            flagspawn.State.Flags[ei].value = carry
            if (flagspawn.State.Flags[ei].meter) flagspawn._SetMeterValue(flagspawn.State.Flags[ei].meter, carry)
        }
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
    local ply = GetPlayerFromUserID(userid)
    if (ply) flagspawn.State.GivenThisLife[ply.entindex()] <- false
}

flagspawn._OnPlayerSpawn <- function(ev) {
    local userid = ("userid" in ev) ? ev.userid : 0
    if (userid == 0) return
    local ply = GetPlayerFromUserID(userid)
    if (ply) flagspawn.State.GivenThisLife[ply.entindex()] <- false
}

//--------------------------------------------------------------
// THINK: cleanup + optional resync (low frequency)
//--------------------------------------------------------------
flagspawn._Think <- function() {
    // Poll carried points -> meter (works even when ListenToGameEvent isn't available).
    local deadPids = []
    foreach (pid, meter in flagspawn.State.PlayerMeters) {
        local ply = EntIndexToHScript(pid)
        if (!ply || !ply.IsValid()) { deadPids.append(pid); continue }
        if (!meter || !meter.IsValid()) { deadPids.append(pid); continue }
        local carry = flagspawn._GetPlayerCarriedPoints(ply)
        if (carry >= 0) flagspawn._SetMeterValue(meter, carry)
    }
    foreach (pid in deadPids) delete flagspawn.State.PlayerMeters[pid]

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
            if ("glow" in data && data.glow && data.glow.IsValid()) {
                EntFireByHandle(data.glow, "Kill", "", 0.0, null, null)
            }
            toDelete.append(ei)
            continue
        }

        // meter validity
        if (!data.meter || !data.meter.IsValid()) {
            data.meter = flagspawn._SpawnMeterProxy()
            data.glow = null
        }

        // Keep meter showing our cached value
        if (data.meter) {
            flagspawn._EnsureMeterGlow(data)
            flagspawn._SetMeterValue(data.meter, data.value)
        }
    }

    foreach (ei in toDelete) delete flagspawn.State.Flags[ei]

    return 0.25
}

//==============================================================
// VMF / entity output entrypoints
//==============================================================
// Hammer outputs sometimes use RunScriptCode (which runs in the logic_script's
// script-scope table) and sometimes CallScriptFunction. To avoid
// "the index 'X' does not exist" errors, we provide plain (non-namespaced)
// functions here.

// If your VMF calls Init() directly.
function Init() {
    if (!flagspawn.State.Inited) flagspawn.Init();
}

// item_teamflag outputs: OnPickup1 -> (scripter) CallScriptFunction/RunScriptCode -> OnPoolFlagPickup
// Expected: caller == flag, activator == player.
function OnPoolFlagPickup() {
    if (!flagspawn.State.Inited) flagspawn.Init();
    local flag = caller;
    local ply  = activator;
    if (!flag || !flag.IsValid()) return;
    if (!ply  || !ply.IsValid())  return;

    // Make sure we have a tracked value + meter
    local ei = flagspawn._EntIndex(flag);
    if (!(ei in flagspawn.State.Flags)) {
        local t = flagspawn.TEAM_NONE;
        try { t = flag.GetTeam(); } catch (_e) { t = flagspawn.TEAM_NONE; }
        flagspawn.State.Flags[ei] <- { value = flagspawn.CFG.DISPENSE_VALUE, meter = null, glow = null, carrier_userid = 0, team = t };
    }

    flagspawn._AttachMeterToPlayer(flag, ply);
}

// item_teamflag outputs: OnDrop1 -> (scripter) CallScriptFunction/RunScriptCode -> OnPoolFlagDrop
// Expected: caller == flag, activator == player.
function OnPoolFlagDrop() {
    if (!flagspawn.State.Inited) flagspawn.Init();
    local flag = caller;
    if (!flag || !flag.IsValid()) return;
    flagspawn._AttachMeterToFlag(flag);
}

// Convenience aliases if you prefer namespaced calls from Hammer.
flagspawn.OnPoolFlagPickup <- OnPoolFlagPickup;
flagspawn.OnPoolFlagDrop   <- OnPoolFlagDrop;
flagspawn.InitEntry        <- Init;

//--------------------------------------------------------------
// Autostart when script is executed (works for script_execute as well)
//--------------------------------------------------------------
flagspawn.Init()
