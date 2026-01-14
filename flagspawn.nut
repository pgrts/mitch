// ==============================================================
// flagspawn.nut (fresh)
//
// Goal: PD-compatible "team-locked" pickups using the fs1_test.vmf pattern:
//   - Spawn neutral PD flags (TeamNum=0, GameType=6) so PD merge logic works
//   - Attach an enemy-only denier trigger to each spawned flag via point_template
//   - Dispense flags onto players via env_entity_maker (ForceSpawnAtEntityOrigin)
//   - Track merges via teamplay_flag_event (ListenToGameEvent + logic_eventlistener fallback)
//
// Hammer wiring (recommended):
//   - logic_script targetname: `scripter`, vscripts: `flagspawn.nut`
//   - logic_eventlistener targetname: `flag_listener`
//       EventName=teamplay_flag_event, FetchEventData=1
//       OnEventFired -> scripter : CallScriptFunction : FS_OnFlagEvent : 0
//   - trigger_multiple spawners (filtered to team):
//       OnStartTouch -> scripter : CallScriptFunction : FS_OnSpawnerTouchRed : 0
//       OnStartTouch -> scripter : CallScriptFunction : FS_OnSpawnerTouchBlu : 0
//   - env_entity_maker:
//       `fs_flag_maker_red` (spawns "RED-owned" flags that deny BLU)
//       `fs_flag_maker_blu` (spawns "BLU-owned" flags that deny RED)
// ==============================================================

::flagspawn <- {}

flagspawn.TEAM_NONE <- 0
flagspawn.TEAM_RED <- 2
flagspawn.TEAM_BLU <- 3

flagspawn.CFG <- {
    DEBUG = true,

    FLAG_LISTENER_NAME = "flag_listener",
    MAKER_RED_NAME = "fs_flag_maker_red",
    MAKER_BLU_NAME = "fs_flag_maker_blu",

    // Per-player, seconds. Prevents "standing in spawner" from vomiting flags.
    DISPENSE_COOLDOWN = 0.35,

    // Optional: spawn a meter prop on players and set bodygroup = carried points.
    ENABLE_PLAYER_METER = false,
    METER_MODEL = "models/props_custom/fs_meter/fs_meter_slab_grid.mdl",
    METER_ATTACH = "flag",
    METER_SCALE_SINGLE = 1.0,
    METER_SCALE_DOUBLE = 0.75,
    METER_VALUE_CLAMP_MAX = 99,

    // Optional: enemy-deny trigger "speed pad" effects (hook via FS_OnLockPadTouch).
    LOCKPAD_ENABLE = true,
    LOCKPAD_COOLDOWN = 0.0,               // Per-player, seconds (0 = no cooldown).
    LOCKPAD_UP_IMPULSE = 140.0,           // Added upward impulse.
    LOCKPAD_FWD_MULT = 0.25,              // Added forward impulse = 2D speed * mult (clamped).
    LOCKPAD_FWD_MIN = 80.0,
    LOCKPAD_FWD_MAX = 320.0,

    // Optional: glow the player who triggers the pad.
    LOCKPAD_PLAYER_GLOW_ENABLE = true,
    LOCKPAD_PLAYER_GLOW_DURATION = 1.0,
    LOCKPAD_PLAYER_GLOW_RED = "255 64 64",
    LOCKPAD_PLAYER_GLOW_BLU = "64 128 255",
    LOCKPAD_PLAYER_GLOW_NEUTRAL = "255 255 255"
}

flagspawn.State <- {
    Inited = false,
    WarnedNoEventData = false,
    WarnedNoMakerRed = false,
    WarnedNoMakerBlu = false,

    LastDispenseAt = {},        // [player_entindex] = time
    LastLockPadAt = {},         // [player_entindex] = time
    PlayerCarriedPoints = {},   // [player_entindex] = int
    PlayerLastFlagName = {},    // [player_entindex] = string
    PlayerMeter = {},           // [player_entindex] = prop handle

    PlayerLockPadGlow = {},     // [player_entindex] = tf_glow handle
    PlayerLockPadGlowUntil = {} // [player_entindex] = time
}

flagspawn._Log <- function(msg) {
    if (!flagspawn.CFG.DEBUG) return
    printl("[flagspawn] " + msg)
}

flagspawn._Now <- function() { return Time() }

flagspawn._IsValid <- function(ent) {
    try { return ent && ent.IsValid && ent.IsValid() } catch (_e) {}
    return false
}

flagspawn._IsPlayer <- function(ent) {
    if (!flagspawn._IsValid(ent)) return false
    try { return ent.GetClassname && ent.GetClassname() == "player" } catch (_e) {}
    return false
}

flagspawn._EntIndex <- function(ent) {
    try { if (flagspawn._IsValid(ent)) return ent.entindex() } catch (_e) {}
    return -1
}

flagspawn._ClampInt <- function(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
}

flagspawn._GetAbsVelocity <- function(ent) {
    if (!flagspawn._IsValid(ent)) return Vector(0, 0, 0)
    try { return ent.GetAbsVelocity() } catch (_e) {}
    if ("NetProps" in getroottable()) {
        try { return NetProps.GetPropVector(ent, "m_vecAbsVelocity") } catch (_e2) {}
        try { return NetProps.GetPropVector(ent, "m_vecVelocity") } catch (_e3) {}
    }
    return Vector(0, 0, 0)
}

flagspawn._EnsureTargetname <- function(ent, prefix) {
    if (!flagspawn._IsValid(ent)) return ""
    local nm = ""
    try { nm = ent.GetName() } catch (_e) { nm = "" }
    if (nm != null && nm != "") return nm
    nm = prefix + ent.entindex()
    try { ent.__KeyValueFromString("targetname", nm) } catch (_e) {}
    return nm
}

flagspawn._GetMakerForTeam <- function(team) {
    local nm = (team == flagspawn.TEAM_RED) ? flagspawn.CFG.MAKER_RED_NAME : flagspawn.CFG.MAKER_BLU_NAME
    local maker = null
    try { maker = Entities.FindByName(null, nm) } catch (_e) { maker = null }
    return maker
}

flagspawn._CanLockPadNow <- function(ply) {
    if (!flagspawn.CFG.LOCKPAD_ENABLE) return false
    local pe = flagspawn._EntIndex(ply)
    if (pe <= 0) return false
    local now = flagspawn._Now()
    if (!(pe in flagspawn.State.LastLockPadAt)) return true
    return (now - flagspawn.State.LastLockPadAt[pe]) >= flagspawn.CFG.LOCKPAD_COOLDOWN
}

flagspawn._MarkLockPad <- function(ply) {
    local pe = flagspawn._EntIndex(ply)
    if (pe <= 0) return
    flagspawn.State.LastLockPadAt[pe] <- flagspawn._Now()
}

flagspawn._GlowColorForTeam <- function(team) {
    if (team == flagspawn.TEAM_RED) return flagspawn.CFG.LOCKPAD_PLAYER_GLOW_RED
    if (team == flagspawn.TEAM_BLU) return flagspawn.CFG.LOCKPAD_PLAYER_GLOW_BLU
    return flagspawn.CFG.LOCKPAD_PLAYER_GLOW_NEUTRAL
}

flagspawn._EnsureLockPadPlayerGlow <- function(ply) {
    if (!flagspawn.CFG.LOCKPAD_PLAYER_GLOW_ENABLE) return null
    if (!flagspawn._IsPlayer(ply)) return null

    local pe = ply.entindex()
    if (pe in flagspawn.State.PlayerLockPadGlow) {
        local g0 = flagspawn.State.PlayerLockPadGlow[pe]
        if (flagspawn._IsValid(g0)) return g0
        delete flagspawn.State.PlayerLockPadGlow[pe]
    }

    local pname = flagspawn._EnsureTargetname(ply, "fs_p_")
    if (pname == "") return null

    local team = 0
    try { team = ply.GetTeam() } catch (_e) { team = 0 }

    local g = null
    try {
        g = SpawnEntityFromTable("tf_glow", {
            target = pname,
            mode = 0,
            glowcolor = flagspawn._GlowColorForTeam(team),
            StartDisabled = 1
        })
    } catch (_e2) { g = null }
    if (!flagspawn._IsValid(g)) return null

    EntFireByHandle(g, "Disable", "", 0.0, null, null)

    flagspawn.State.PlayerLockPadGlow[pe] <- g
    return g
}

flagspawn._ScheduleLockPadGlowCheck <- function(ply, glow, delay) {
    if (!flagspawn._IsPlayer(ply)) return false
    if (!flagspawn._IsValid(glow)) return false
    if (delay <= 0) return false

    local scripter = null
    try { scripter = Entities.FindByName(null, "scripter") } catch (_e) { scripter = null }
    if (flagspawn._IsValid(scripter)) {
        EntFireByHandle(scripter, "CallScriptFunction", "FS_OnLockPadGlowCheck", delay, ply, glow)
        return true
    }

    // Fallback: best effort; can flicker if the pad is spammed faster than duration.
    EntFireByHandle(glow, "Disable", "", delay, null, null)
    return false
}

flagspawn._ComputeLockPadImpulse <- function(ply) {
    local vel = flagspawn._GetAbsVelocity(ply)

    local dir = Vector(vel.x, vel.y, 0)
    local h2 = (dir.x * dir.x) + (dir.y * dir.y)
    local hspeed = (h2 > 0) ? sqrt(h2) : 0.0

    if (hspeed < 1.0) {
        local fwd = Vector(1, 0, 0)
        try { fwd = ply.EyeAngles().Forward() } catch (_e) { fwd = Vector(1, 0, 0) }
        fwd.z = 0
        local f2 = (fwd.x * fwd.x) + (fwd.y * fwd.y)
        local flen = (f2 > 0) ? sqrt(f2) : 1.0
        dir = Vector(fwd.x / flen, fwd.y / flen, 0)
        hspeed = 0.0
    } else {
        dir = Vector(dir.x / hspeed, dir.y / hspeed, 0)
    }

    local fwdMag = hspeed * flagspawn.CFG.LOCKPAD_FWD_MULT
    if (fwdMag < flagspawn.CFG.LOCKPAD_FWD_MIN) fwdMag = flagspawn.CFG.LOCKPAD_FWD_MIN
    if (fwdMag > flagspawn.CFG.LOCKPAD_FWD_MAX) fwdMag = flagspawn.CFG.LOCKPAD_FWD_MAX

    return Vector(dir.x * fwdMag, dir.y * fwdMag, flagspawn.CFG.LOCKPAD_UP_IMPULSE)
}

flagspawn._ApplyVelocityImpulse <- function(ent, impulse) {
    if (!flagspawn._IsValid(ent)) return false
    try { ent.ApplyAbsVelocityImpulse(impulse); return true } catch (_e) {}
    try { ent.SetAbsVelocity(flagspawn._GetAbsVelocity(ent) + impulse); return true } catch (_e2) {}
    return false
}

flagspawn._GetPlayerCarriedPoints <- function(ply) {
    if (!flagspawn._IsValid(ply)) return 0
    if (!("NetProps" in getroottable())) return 0

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
        } catch (_e) {}
    }
    return 0
}

// ------------------------------------------------------------
// Optional: player meter
// ------------------------------------------------------------
flagspawn._EnsurePlayerMeter <- function(ply) {
    if (!flagspawn.CFG.ENABLE_PLAYER_METER) return null
    if (!flagspawn._IsPlayer(ply)) return null

    local pe = ply.entindex()
    if (pe in flagspawn.State.PlayerMeter) {
        local m = flagspawn.State.PlayerMeter[pe]
        if (flagspawn._IsValid(m)) return m
        delete flagspawn.State.PlayerMeter[pe]
    }

    local kv = {
        targetname = "fs_meter_" + UniqueString("m"),
        model = flagspawn.CFG.METER_MODEL,
        solid = 0,
        DisableBoneFollowers = 1,
        spawnflags = 0
    }

    local meter = null
    try { meter = SpawnEntityFromTable("prop_dynamic_override", kv) } catch (_e) { meter = null }
    if (!flagspawn._IsValid(meter)) return null

    local pname = flagspawn._EnsureTargetname(ply, "fs_p_")
    EntFireByHandle(meter, "ClearParent", "", 0.0, null, null)
    EntFireByHandle(meter, "SetParent", pname, 0.0, null, null)
    EntFireByHandle(meter, "SetParentAttachment", flagspawn.CFG.METER_ATTACH, 0.01, null, null)

    flagspawn.State.PlayerMeter[pe] <- meter
    return meter
}

flagspawn._SetMeterValue <- function(meter, value) {
    if (!flagspawn._IsValid(meter)) return
    local v = flagspawn._ClampInt(value, 0, flagspawn.CFG.METER_VALUE_CLAMP_MAX)
    local sc = (v >= 10) ? flagspawn.CFG.METER_SCALE_DOUBLE : flagspawn.CFG.METER_SCALE_SINGLE
    try { meter.SetModelScale(sc, 0.0) } catch (_e) {}
    EntFireByHandle(meter, "SetBodyGroup", "" + v, 0.0, null, null)
}

flagspawn._UpdatePlayerCarriedVisuals <- function(ply, carried) {
    if (!flagspawn.CFG.ENABLE_PLAYER_METER) return
    local meter = flagspawn._EnsurePlayerMeter(ply)
    if (meter) flagspawn._SetMeterValue(meter, carried)
}

// ------------------------------------------------------------
// Dispense (spawner touch)
// ------------------------------------------------------------
flagspawn._CanDispenseNow <- function(ply) {
    local pe = flagspawn._EntIndex(ply)
    if (pe <= 0) return false
    local now = flagspawn._Now()
    if (!(pe in flagspawn.State.LastDispenseAt)) return true
    return (now - flagspawn.State.LastDispenseAt[pe]) >= flagspawn.CFG.DISPENSE_COOLDOWN
}

flagspawn._MarkDispensed <- function(ply) {
    local pe = flagspawn._EntIndex(ply)
    if (pe <= 0) return
    flagspawn.State.LastDispenseAt[pe] <- flagspawn._Now()
}

flagspawn.DispenseToPlayer <- function(team, ply, spawner = null) {
    if (!flagspawn.State.Inited) flagspawn.Init()
    if (!flagspawn._IsPlayer(ply)) return false
    if (!flagspawn._CanDispenseNow(ply)) return false

    flagspawn._MarkDispensed(ply)

    local maker = flagspawn._GetMakerForTeam(team)
    if (!flagspawn._IsValid(maker)) {
        if (team == flagspawn.TEAM_RED) {
            if (!flagspawn.State.WarnedNoMakerRed) {
                flagspawn.State.WarnedNoMakerRed = true
                flagspawn._Log("Missing env_entity_maker '" + flagspawn.CFG.MAKER_RED_NAME + "'")
            }
        } else {
            if (!flagspawn.State.WarnedNoMakerBlu) {
                flagspawn.State.WarnedNoMakerBlu = true
                flagspawn._Log("Missing env_entity_maker '" + flagspawn.CFG.MAKER_BLU_NAME + "'")
            }
        }
        return false
    }

    // ForceSpawnAtEntityOrigin expects a targetname. Ensure the player has one.
    local pname = flagspawn._EnsureTargetname(ply, "fs_p_")

    // Spawn the template at the player's origin; PD consumes it on touch and merge events fire.
    EntFireByHandle(maker, "ForceSpawnAtEntityOrigin", pname, 0.0, ply, spawner)
    return true
}

// ------------------------------------------------------------
// teamplay_flag_event handling
// ------------------------------------------------------------
flagspawn._OnTeamplayFlagEvent <- function(ev) {
    local userid = ("player" in ev) ? ev.player : (("userid" in ev) ? ev.userid : 0)
    if (userid == 0) return

    local ply = null
    try { ply = GetPlayerFromUserID(userid) } catch (_e) { ply = null }
    if (!flagspawn._IsPlayer(ply)) return

    local pe = ply.entindex()
    local flagname = ("flagname" in ev) ? ev.flagname : ""
    local carried = flagspawn._GetPlayerCarriedPoints(ply)

    flagspawn.State.PlayerCarriedPoints[pe] <- carried
    if (flagname != null && flagname != "") flagspawn.State.PlayerLastFlagName[pe] <- flagname

    flagspawn._UpdatePlayerCarriedVisuals(ply, carried)

    if (flagspawn.CFG.DEBUG) {
        local et = ("eventtype" in ev) ? ev.eventtype : -1
        flagspawn._Log("teamplay_flag_event type=" + et + " player=" + pe + " carried=" + carried + " flag='" + flagname + "'")
    }
}

// VMF logic_eventlistener entrypoint (FetchEventData must be enabled).
function FS_OnFlagEvent() {
    if (!flagspawn.State.Inited) flagspawn.Init()

    local listener = null
    try { if (caller && caller.IsValid()) listener = caller } catch (_e) {}
    try { if (!listener && activator && activator.IsValid()) listener = activator } catch (_e) {}
    if (!listener) {
        try { listener = Entities.FindByName(null, flagspawn.CFG.FLAG_LISTENER_NAME) } catch (_e) { listener = null }
    }
    if (!flagspawn._IsValid(listener)) return
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
    flagspawn._OnTeamplayFlagEvent(ev)
}
flagspawn.FS_OnFlagEvent <- FS_OnFlagEvent

flagspawn.OnGameEvent_teamplay_flag_event <- function(ev) { flagspawn._OnTeamplayFlagEvent(ev) }

// ------------------------------------------------------------
// Hammer entrypoints: spawner touches
// ------------------------------------------------------------
function FS_OnSpawnerTouchRed() {
    local ply = null
    local src = null
    try { ply = activator } catch (_e) { ply = null }
    try { src = caller } catch (_e) { src = null }
    if (!flagspawn._IsPlayer(ply)) return
    flagspawn.DispenseToPlayer(flagspawn.TEAM_RED, ply, src)
}
flagspawn.FS_OnSpawnerTouchRed <- FS_OnSpawnerTouchRed

function FS_OnSpawnerTouchBlu() {
    local ply = null
    local src = null
    try { ply = activator } catch (_e) { ply = null }
    try { src = caller } catch (_e) { src = null }
    if (!flagspawn._IsPlayer(ply)) return
    flagspawn.DispenseToPlayer(flagspawn.TEAM_BLU, ply, src)
}
flagspawn.FS_OnSpawnerTouchBlu <- FS_OnSpawnerTouchBlu

function FS_OnLockPadGlowCheck() {
    if (!flagspawn.State.Inited) flagspawn.Init()

    local ply = null
    try { ply = activator } catch (_e) { ply = null }
    if (!flagspawn._IsPlayer(ply)) return

    local pe = ply.entindex()
    if (!(pe in flagspawn.State.PlayerLockPadGlowUntil)) return

    local now = flagspawn._Now()
    if (now < flagspawn.State.PlayerLockPadGlowUntil[pe]) return

    delete flagspawn.State.PlayerLockPadGlowUntil[pe]

    local g = null
    if (pe in flagspawn.State.PlayerLockPadGlow) g = flagspawn.State.PlayerLockPadGlow[pe]
    if (!flagspawn._IsValid(g)) return

    EntFireByHandle(g, "Disable", "", 0.0, null, null)
}
flagspawn.FS_OnLockPadGlowCheck <- FS_OnLockPadGlowCheck

function FS_OnLockPadTouch() {
    if (!flagspawn.State.Inited) flagspawn.Init()

    local ply = null
    try { ply = activator } catch (_e) { ply = null }
    if (!flagspawn._IsPlayer(ply)) return
    if (!flagspawn._CanLockPadNow(ply)) return

    flagspawn._MarkLockPad(ply)

    local impulse = flagspawn._ComputeLockPadImpulse(ply)
    flagspawn._ApplyVelocityImpulse(ply, impulse)

    if (flagspawn.CFG.LOCKPAD_PLAYER_GLOW_ENABLE && flagspawn.CFG.LOCKPAD_PLAYER_GLOW_DURATION > 0) {
        local g = flagspawn._EnsureLockPadPlayerGlow(ply)
        if (flagspawn._IsValid(g)) {
            local pe = ply.entindex()
            flagspawn.State.PlayerLockPadGlowUntil[pe] <- flagspawn._Now() + flagspawn.CFG.LOCKPAD_PLAYER_GLOW_DURATION

            EntFireByHandle(g, "Enable", "", 0.0, null, null)
            flagspawn._ScheduleLockPadGlowCheck(ply, g, flagspawn.CFG.LOCKPAD_PLAYER_GLOW_DURATION)
        }
    }
}
flagspawn.FS_OnLockPadTouch <- FS_OnLockPadTouch

// ------------------------------------------------------------
// Debug helpers
// ------------------------------------------------------------
flagspawn.DumpCarriers <- function() {
    flagspawn._Log("DumpCarriers:")
    foreach (pe, v in flagspawn.State.PlayerCarriedPoints) {
        local fn = (pe in flagspawn.State.PlayerLastFlagName) ? flagspawn.State.PlayerLastFlagName[pe] : ""
        flagspawn._Log("  player_entindex=" + pe + " carried=" + v + " last_flag='" + fn + "'")
    }
}

// ------------------------------------------------------------
// Init
// ------------------------------------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.Inited) return
    flagspawn.State.Inited = true

    if ("__CollectGameEventCallbacks" in getroottable()) {
        try { __CollectGameEventCallbacks(flagspawn) } catch (_e) {}
    } else if ("ListenToGameEvent" in getroottable()) {
        try { ListenToGameEvent("teamplay_flag_event", flagspawn._OnTeamplayFlagEvent, flagspawn) } catch (_e) {}
    }

    local mr = flagspawn._GetMakerForTeam(flagspawn.TEAM_RED)
    local mb = flagspawn._GetMakerForTeam(flagspawn.TEAM_BLU)
    if (!flagspawn._IsValid(mr)) flagspawn._Log("NOTE: maker '" + flagspawn.CFG.MAKER_RED_NAME + "' not found yet (map may still be spawning).")
    if (!flagspawn._IsValid(mb)) flagspawn._Log("NOTE: maker '" + flagspawn.CFG.MAKER_BLU_NAME + "' not found yet (map may still be spawning).")

    flagspawn._Log("Init complete. ENABLE_PLAYER_METER=" + flagspawn.CFG.ENABLE_PLAYER_METER)
}

try { flagspawn.Init() } catch (_e) {}
