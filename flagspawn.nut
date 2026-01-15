// flagspawn.nut — Pulse PointValue -> SetBodyGroup (LOUD DEBUG)
// Drop-in for scripts/vscripts/flagspawn.nut
//
// What this does:
// - Discovers templated flags spawned by env_entity_maker + point_template name fixup (suffix like &0001)
// - Finds helper entities by suffix (deny trigger, friendly pad, tf_glow, sfx relay)
// - Enables helpers only when the flag is DROPPED (optional)
// - EVERY THINK TICK: reads flag PointValue and slams SetBodyGroup to match it
// - Prints a TON of console logs about bodygroup attempts + observed m_nBody changes

// ------------------------------------------------------------
// Root-table anchor
// ------------------------------------------------------------
local _rt = getroottable()
if (!("flagspawn" in _rt) || typeof _rt.flagspawn != "table") _rt.flagspawn <- {}
local flagspawn = _rt.flagspawn

// ------------------------------------------------------------
// Team constants (TF2)
// ------------------------------------------------------------
flagspawn.TEAM_RED <- 2
flagspawn.TEAM_BLU <- 3

// ------------------------------------------------------------
// CONFIG
// ------------------------------------------------------------
flagspawn.CFG <- {
    DEBUG = true,

    THINK_DT = 0.20,

    // Your templated flag prototype names (NO suffix)
    FLAG_baseName_BLU = "fs_flag_proto_blu",
    FLAG_baseName_RED = "fs_flag_proto_red",

    // Helper prototypes (NO suffix) — names inside the template
    // Deny trigger naming: "deny RED" should live in BLU template, etc.
    DENY_baseName_RED = "fs_lock_proto_deny_red",
    DENY_baseName_BLU = "fs_lock_proto_deny_blu",
    PAD_baseName_BLU  = "fs_proto_blu_friendly_pad",
    PAD_baseName_RED  = "fs_proto_red_friendly_pad",
    GLOW_baseName_BLU = "fs_glow_flag_proto_blu",
    GLOW_baseName_RED = "fs_glow_flag_proto_red",
    SFX_baseName      = "fs_sfx_proto",

    // Enable helpers only when dropped
    ENABLE_EXTRAS_ONLY_WHEN_DROPPED = true,

    // ------------------------------------------------------------
    // Meter / bodygroup debug syncing (for fs_meter models)
    // ------------------------------------------------------------
    BODYGROUP_SYNC_ENABLE = true,
    BODYGROUP_GROUP_INDEX = 0,      // usually 0 for a single "fill" bodygroup
    BODYGROUP_MIN = 0,
    BODYGROUP_MAX = 100,

    // "pulse" behavior
    BODYGROUP_ALWAYS_SLAM = true,   // true = fire SetBodyGroup every think tick
    BODYGROUP_LOG_EVERY_TICK = true // true = print debug every tick per flag
}

// ------------------------------------------------------------
// STATE
// ------------------------------------------------------------
flagspawn.State <- {
    Started = false,
    Pkgs = {} // suffix -> pkg
}

// ------------------------------------------------------------
// Logging helpers
// ------------------------------------------------------------
flagspawn._Dbg <- function(msg) { if (flagspawn.CFG.DEBUG) printl("[FLAGSPAWN] " + msg) }
flagspawn._Now <- function() { try { return Time() } catch (_e0) { return 0.0 } }

// ------------------------------------------------------------
// Safe utilities (NO GetAbsOrigin on players)
// ------------------------------------------------------------
flagspawn._IsValid <- function(e) {
    if (e == null) return false
    try { return e.IsValid() } catch (_e0) { return false }
}
flagspawn._GetNameSafe <- function(e) {
    if (!flagspawn._IsValid(e)) return ""
    try { return e.GetName() } catch (_e0) { return "" }
}
flagspawn._IsPlayer <- function(e) {
    if (!flagspawn._IsValid(e)) return false
    try { return e.IsPlayer() } catch (_e0) { return false }
}
flagspawn._GetOrigin <- function(ent) {
    if (!flagspawn._IsValid(ent)) return Vector(0,0,0)
    // TF2 safe path: prefer GetOrigin; do NOT call GetAbsOrigin on players.
    try { return ent.GetOrigin() } catch (_e0) {}
    // Fallback for some entities (not players typically)
    try { return ent.GetAbsOrigin() } catch (_e1) {}
    return Vector(0,0,0)
}
flagspawn._ClampInt <- function(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
}

// ------------------------------------------------------------
// Flag carried detection
// ------------------------------------------------------------
flagspawn._IsCarried <- function(flag) {
    if (!flagspawn._IsValid(flag)) return false

    // 1) MoveParent check (often works)
    local mp = null
    try { mp = flag.GetMoveParent() } catch (_e0) { mp = null }
    if (flagspawn._IsPlayer(mp)) return true

    // 2) Owner entity check (when available)
    if (!("NetProps" in _rt)) return false
    local owner = null
    try { owner = NetProps.GetPropEntity(flag, "m_hOwnerEntity") } catch (_e1) { owner = null }
    if (flagspawn._IsPlayer(owner)) return true

    return false
}

// ------------------------------------------------------------
// Enable/disable helpers safely
// ------------------------------------------------------------
flagspawn._SetHelperEnabled <- function(ent, enabled) {
    if (!flagspawn._IsValid(ent)) return

    // Triggers generally use Enable/Disable
    try {
        EntFireByHandle(ent, enabled ? "Enable" : "Disable", "", 0.0, null, null)
        return
    } catch (_e0) {}

    // Some props use TurnOn/TurnOff
    try {
        EntFireByHandle(ent, enabled ? "TurnOn" : "TurnOff", "", 0.0, null, null)
    } catch (_e1) {}
}

// ------------------------------------------------------------
// tf_glow binding (keeps glow on the flag)
// ------------------------------------------------------------
flagspawn._BindGlowTarget <- function(glow, targetEnt) {
    if (!flagspawn._IsValid(glow) || !flagspawn._IsValid(targetEnt)) return
    // tf_glow has "SetTarget" input that takes targetname, but we can also just keep it parented.
    // Parenting is typically robust if the template already parents it.
    // Still, in case it's not parented, attempt to SetParent.
    try { glow.SetParent(targetEnt, "") } catch (_e0) {}
}

// ------------------------------------------------------------
// Name suffix helpers
// ------------------------------------------------------------
flagspawn._ExtractSuffix <- function(nameStr) {
    // expects "...&####"
    if (nameStr == null) return null
    local i = nameStr.find("&")
    if (i == null) return null
    if (i < 0) return null
    return nameStr.slice(i + 1)
}
flagspawn._WithSuffix <- function(baseName, sufDigits) {
    return baseName + "&" + sufDigits
}

// ------------------------------------------------------------
// Bodygroup / meter sync (PointValue -> SetBodyGroup)
// ------------------------------------------------------------
flagspawn._GetPointValueSafe <- function(flag) {
    if (!flagspawn._IsValid(flag)) return 0
    if (!("NetProps" in getroottable())) return 0

    local v = 0
    // TF2 sometimes uses m_nPointValue; try a couple
    try { v = NetProps.GetPropInt(flag, "m_nPointValue"); return v } catch (_e0) {}
    try { v = NetProps.GetPropInt(flag, "m_iPointValue"); return v } catch (_e1) {}
    return 0
}
flagspawn._GetBodySafe <- function(ent) {
    if (!flagspawn._IsValid(ent)) return null
    if (!("NetProps" in getroottable())) return null
    try { return NetProps.GetPropInt(ent, "m_nBody") } catch (_e0) {}
    return null
}

// Fire SetBodyGroup and try to OBSERVE m_nBody changing immediately
flagspawn._TrySetBodyGroup <- function(flag, desired, paramStr) {
    local before = flagspawn._GetBodySafe(flag)

    // Fire the input (no return value)
    try { EntFireByHandle(flag, "SetBodyGroup", paramStr, 0.0, null, null) } catch (_e0) {}

    local after = flagspawn._GetBodySafe(flag)

    if (flagspawn.CFG.DEBUG) {
        printl("[FLAGSPAWN][BG] try param='" + paramStr + "' body " +
               (before == null ? "null" : before) + " -> " +
               (after == null ? "null" : after) + " (want " + desired + ")")
    }

    return (after != null && after == desired)
}

flagspawn._PulseBodygroup <- function(pkg) {
    if (!flagspawn.CFG.BODYGROUP_SYNC_ENABLE) return

    local flag = pkg.flagHandle
    if (!flagspawn._IsValid(flag)) return

    local pv = flagspawn._GetPointValueSafe(flag)
    local desired = flagspawn._ClampInt(pv, flagspawn.CFG.BODYGROUP_MIN, flagspawn.CFG.BODYGROUP_MAX)
    local bodyNow = flagspawn._GetBodySafe(flag)

    if (flagspawn.CFG.DEBUG && flagspawn.CFG.BODYGROUP_LOG_EVERY_TICK) {
        printl("[FLAGSPAWN][BG] pulse name=" + pkg.flagName +
               " pv=" + pv +
               " desired=" + desired +
               " bodyNow=" + (bodyNow == null ? "null" : bodyNow))
    }

    // Confirm delayed success if we were waiting
    if (("bgExpect" in pkg)) {
        if (bodyNow != null && bodyNow == pkg.bgExpect) {
            printl("[FLAGSPAWN][BG] CONFIRMED LATE name=" + pkg.flagName + " body=" + bodyNow)
            delete pkg.bgExpect
            delete pkg.bgExpectAt
        } else {
            local dt = flagspawn._Now() - pkg.bgExpectAt
            if (dt > 1.0) {
                printl("[FLAGSPAWN][BG] STILL NOT SET after " + dt + "s name=" + pkg.flagName +
                       " bodyNow=" + (bodyNow == null ? "null" : bodyNow) +
                       " expect=" + pkg.bgExpect)
                // refresh timer so it doesn’t scream every tick forever
                pkg.bgExpectAt <- flagspawn._Now()
            }
        }
    }

    // Decide whether to slam
    local shouldSlam = flagspawn.CFG.BODYGROUP_ALWAYS_SLAM
    if (!shouldSlam) {
        if (!("lastPV" in pkg) || pkg.lastPV != pv) shouldSlam = true
        else if (bodyNow == null || bodyNow != desired) shouldSlam = true
    }
    pkg.lastPV <- pv
    if (!shouldSlam) return

    // Try multiple parameter formats (TF2 is inconsistent across classes/builds)
    local ok = false
    ok = flagspawn._TrySetBodyGroup(flag, desired, "" + flagspawn.CFG.BODYGROUP_GROUP_INDEX + " " + desired)
    if (!ok) ok = flagspawn._TrySetBodyGroup(flag, desired, "" + desired)
    if (!ok) ok = flagspawn._TrySetBodyGroup(flag, desired, "" + flagspawn.CFG.BODYGROUP_GROUP_INDEX + "," + desired)

    if (!ok) {
        // It might apply next frame; mark expectation for later confirmation
        pkg.bgExpect <- desired
        pkg.bgExpectAt <- flagspawn._Now()
        printl("[FLAGSPAWN][BG] fired but not observed yet name=" + pkg.flagName +
               " desired=" + desired +
               " bodyNow=" + (bodyNow == null ? "null" : bodyNow))
    }
}

// ------------------------------------------------------------
// Package registration (discover flags + suffix)
// ------------------------------------------------------------
flagspawn._RegisterFlagByName <- function(flagName) {
    if (flagName == null || flagName == "") return
    local flag = null
    try { flag = Entities.FindByName(null, flagName) } catch (_e0) { flag = null }
    if (!flagspawn._IsValid(flag)) return

    local suf = flagspawn._ExtractSuffix(flagName)
    if (suf == null || suf == "") return
    if (suf in flagspawn.State.Pkgs) return

    // Determine team by base name prefix (cheap)
    local isBlu = (flagName.find(flagspawn.CFG.FLAG_baseName_BLU) == 0)

    local pkg = {
        suffix = suf,
        flagHandle = flag,
        flagName = flagName,
        deny = null,
        pad = null,
        glow = null,
        sfx = null,
        lastState = null
    }

    local denyName = isBlu ? flagspawn._WithSuffix(flagspawn.CFG.DENY_baseName_RED, suf)
                           : flagspawn._WithSuffix(flagspawn.CFG.DENY_baseName_BLU, suf)
    local padName  = isBlu ? flagspawn._WithSuffix(flagspawn.CFG.PAD_baseName_BLU,  suf)
                           : flagspawn._WithSuffix(flagspawn.CFG.PAD_baseName_RED,  suf)
    local glowName = isBlu ? flagspawn._WithSuffix(flagspawn.CFG.GLOW_baseName_BLU, suf)
                           : flagspawn._WithSuffix(flagspawn.CFG.GLOW_baseName_RED, suf)
    local sfxName  = flagspawn._WithSuffix(flagspawn.CFG.SFX_baseName, suf)

    try { pkg.deny = Entities.FindByName(null, denyName) } catch (_e1) { pkg.deny = null }
    try { pkg.pad  = Entities.FindByName(null, padName)  } catch (_e2) { pkg.pad  = null }
    try { pkg.glow = Entities.FindByName(null, glowName) } catch (_e3) { pkg.glow = null }
    try { pkg.sfx  = Entities.FindByName(null, sfxName)  } catch (_e4) { pkg.sfx  = null }

    flagspawn.State.Pkgs[suf] <- pkg

    flagspawn._Dbg("REGISTER suf=" + suf +
                   " flag=" + flagName +
                   " deny=" + (pkg.deny ? flagspawn._GetNameSafe(pkg.deny) : "null") +
                   " pad="  + (pkg.pad  ? flagspawn._GetNameSafe(pkg.pad)  : "null") +
                   " glow=" + (pkg.glow ? flagspawn._GetNameSafe(pkg.glow) : "null"))
}

flagspawn._ScanAndRegisterAllFlags <- function() {
    // Find all flags that match our base names. This is a brute scan (safe, simple).
    local ent = null

    // BLU flags
    ent = null
    while (true) {
        try { ent = Entities.FindByName(ent, flagspawn.CFG.FLAG_baseName_BLU + "*") } catch (_e0) { ent = null }
        if (!flagspawn._IsValid(ent)) break
        local name = flagspawn._GetNameSafe(ent)
        if (name != "") flagspawn._RegisterFlagByName(name)
    }

    // RED flags
    ent = null
    while (true) {
        try { ent = Entities.FindByName(ent, flagspawn.CFG.FLAG_baseName_RED + "*") } catch (_e1) { ent = null }
        if (!flagspawn._IsValid(ent)) break
        local name2 = flagspawn._GetNameSafe(ent)
        if (name2 != "") flagspawn._RegisterFlagByName(name2)
    }
}

flagspawn._CullDeadPkgs <- function() {
    // remove pkgs whose flag no longer exists
    local dead = []
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!flagspawn._IsValid(pkg.flagHandle)) dead.append(suf)
    }
    foreach (suf2 in dead) {
        flagspawn._Dbg("CULL suf=" + suf2)
        delete flagspawn.State.Pkgs[suf2]
    }
}

// ------------------------------------------------------------
// Apply state each tick (anti-spam for helper toggles)
// ------------------------------------------------------------
flagspawn._ApplyPkgState <- function(pkg) {
    local flag = pkg.flagHandle
    if (!flagspawn._IsValid(flag)) return

    // keep name fresh
    pkg.flagName = flagspawn._GetNameSafe(flag)

    local carried = flagspawn._IsCarried(flag)
    local dropped = !carried

    // keep glow bound (cheap and silent)
    if (flagspawn._IsValid(pkg.glow)) flagspawn._BindGlowTarget(pkg.glow, flag)

    // Desired helper state
    local desired = true
    if (flagspawn.CFG.ENABLE_EXTRAS_ONLY_WHEN_DROPPED) {
        desired = dropped
    }

    // Only fire inputs when state changes
    if (!("lastState" in pkg) || pkg.lastState != desired) {
        flagspawn._SetHelperEnabled(pkg.deny, desired)
        flagspawn._SetHelperEnabled(pkg.pad,  desired)
        flagspawn._SetHelperEnabled(pkg.glow, desired)

        if (flagspawn.CFG.DEBUG) {
            printl("[FLAGSPAWN] helpers " + (desired ? "EN" : "DIS") +
                   " suf=" + pkg.suffix +
                   " carried=" + (carried ? "YES" : "NO"))
        }

        pkg.lastState <- desired
    }

    // --- THE THING YOU CARE ABOUT ---
    // Pulse-set bodygroup from PointValue and log like crazy
    flagspawn._PulseBodygroup(pkg)
}

// ------------------------------------------------------------
// THINK (authoritative)
// ------------------------------------------------------------
flagspawn._Think <- function() {
    flagspawn._ScanAndRegisterAllFlags()
    flagspawn._CullDeadPkgs()

    foreach (_suf, pkg in flagspawn.State.Pkgs) {
        flagspawn._ApplyPkgState(pkg)
    }

    return flagspawn.CFG.THINK_DT
}

// ------------------------------------------------------------
// Public entrypoint
// ------------------------------------------------------------
flagspawn.Start <- function() {
    if (flagspawn.State.Started) return
    flagspawn.State.Started = true
    flagspawn._Dbg("Start()")
    // schedule think
    try { AddThinkToEnt(self, "Think") } catch (_e0) {
        // If we are not running inside an entity context, just do nothing.
        // You can call flagspawn.Think() manually via logic_script if needed.
    }
}

flagspawn.Think <- function() {
    return flagspawn._Think()
}
