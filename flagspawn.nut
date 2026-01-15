// flagspawn.nut — Parent extras to flag + StartDisabled + Enable-on-drop
// Drop-in for scripts/vscripts/flagspawn.nut

// ------------------------------------------------------------
// Root-table anchor
// ------------------------------------------------------------
local _rt = getroottable()
if (!("flagspawn" in _rt) || typeof _rt.flagspawn != "table") _rt.flagspawn <- {}
local flagspawn = _rt.flagspawn

flagspawn.CFG <- {
    DEBUG = true,
    THINK_DT = 0.20,

    // 1. MATCH VMF FLAG NAMES (No suffixes)
    // The script will automatically add the &0008 suffix found on the spawned flag
    FLAG_baseName_BLU = "bluflag",
    FLAG_baseName_RED = "redflag",

    // 2. MATCH VMF CHILD NAMES (No suffixes)
    // The script uses these base names + the suffix to find the triggers
    
    // MAPPING LOGIC:
    // If Flag is BLU ("bluflag"):
    //   - Script looks for DENY_baseName_RED -> VMF: "red_lock_bluflag"
    //   - Script looks for PAD_baseName_BLU  -> VMF: "red_pushoff_bluflag"
    
    // If Flag is RED ("redflag"):
    //   - Script looks for DENY_baseName_BLU -> VMF: "blu_lock_redflag"
    //   - Script looks for PAD_baseName_RED  -> VMF: "blu_pushoff_redflag"

    DENY_baseName_RED = "red_lock_bluflag",
    PAD_baseName_BLU  = "red_pushoff_bluflag",

    DENY_baseName_BLU = "blu_lock_redflag",
    PAD_baseName_RED  = "blu_pushoff_redflag",

    // Glow and SFX names
    GLOW_baseName_BLU = "bluflag_glow",
    GLOW_baseName_RED = "redflag_glow",
    SFX_baseName      = "fs_lockpad_sfx_proto",

    // 3. BEHAVIOR
    // This setting ensures triggers are ENABLED when dropped, and DISABLED when carried/home
    ENABLE_EXTRAS_ONLY_WHEN_DROPPED = true, 

    // (These settings are less relevant now that you use VMF I/O, but keep them for safety)
    DENYPAD_ENABLE = true,
    DENYPAD_DISABLE_SEC = 0.70,
    DENYPAD_FLAG_COOLDOWN = 1.00,
    DENYPAD_PRESERVE_RETURNTIMER = true,
    PAD_MOVE_DIR_SPEED = 300.0,
    PAD_MOVE_DIR_LIFT  = 260.0,
    PAD_MIN_2D_SPEED   = 20.0
}

// ------------------------------------------------------------
// STATE
// ------------------------------------------------------------
if (!("State" in flagspawn) || typeof flagspawn.State != "table") flagspawn.State <- {}
flagspawn.State.Pkgs <- {}              // key: suffixDigits ("0011") -> pkg
flagspawn.State.DenyLastAt <- {}        // key: flagName -> time
flagspawn.State.DenyDisableUntil <- {}  // key: flagName -> time

// ------------------------------------------------------------
// Logging helpers
// ------------------------------------------------------------
flagspawn._Dbg <- function(msg) {
    if (flagspawn.CFG.DEBUG) printl("[FLAGSPAWN] " + msg)
}

// ------------------------------------------------------------
// Safe utility
// ------------------------------------------------------------
flagspawn._Now <- function() { try { return Time() } catch (_e) { return 0.0 } }

flagspawn._IsValid <- function(ent) {
    if (!ent) return false
    try { if ("IsValid" in ent && !ent.IsValid()) return false } catch (_e) {}
    return true
}

flagspawn._IsPlayer <- function(ent) {
    if (!flagspawn._IsValid(ent)) return false
    local cn = ""
    try { cn = ent.GetClassname() } catch (_e) { cn = "" }
    return (cn == "player")
}

flagspawn._GetNameSafe <- function(ent) {
    if (!flagspawn._IsValid(ent)) return ""
    local n = ""
    try { n = ent.GetName() } catch (_e) { n = "" }
    return n
}

// canonical suffix digits: "fs_flag_proto_blu&0011" -> "0011"
flagspawn._ExtractSuffixDigits <- function(name) {
    if (name == null) return null
    local amp = null
    try { amp = name.find("&") } catch (_e0) { amp = null }
    if (amp != null) {
        local s = name.slice(amp + 1)
        if (s.len() > 0) return s
    }
    return null
}

flagspawn._WithSuffix <- function(baseName, sufDigits) {
    return baseName + "&" + sufDigits
}

// ------------------------------------------------------------
// Carried vs dropped (authoritative)
// ------------------------------------------------------------
flagspawn._IsCarried <- function(flag) {
    if (!flagspawn._IsValid(flag)) return false

    // 1) MoveParent check (often works)
    local mp = null
    try { mp = flag.GetMoveParent() } catch (_e0) { mp = null }
    if (flagspawn._IsPlayer(mp)) return true

    // 2) NetProps owner check (more reliable when available)
    if (!("NetProps" in _rt)) return false
    local owner = null
    try { owner = NetProps.GetPropEntity(flag, "m_hOwnerEntity") } catch (_e1) { owner = null }
    if (flagspawn._IsPlayer(owner)) return true

    // (optional) other props could be tried, but keep it safe/simple
    return false
}

// ------------------------------------------------------------
// Return timer preservation (Disable/Enable resets it)
// ------------------------------------------------------------
flagspawn._GetResetAbs <- function(flag) {
    if (!flagspawn._IsValid(flag) || !("NetProps" in _rt)) return null
    try { return NetProps.GetPropFloat(flag, "m_flResetTime") } catch (_e0) {}
    try { return NetProps.GetPropFloat(flag, "m_flReturnTime") } catch (_e1) {}
    return null
}

flagspawn._SetResetAbsByName <- function(flagName, tAbs) {
    if (flagName == null || flagName == "" || tAbs == null) return
    if (!("NetProps" in _rt)) return
    local f = null
    try { f = Entities.FindByName(null, flagName) } catch (_e0) { f = null }
    if (!flagspawn._IsValid(f)) return
    try { NetProps.SetPropFloat(f, "m_flResetTime", tAbs) } catch (_e1) {}
    try { NetProps.SetPropFloat(f, "m_flReturnTime", tAbs) } catch (_e2) {}
}

// ------------------------------------------------------------
// Enable/disable helpers
// ------------------------------------------------------------
flagspawn._EntCmd <- function(ent, cmd) {
    if (!flagspawn._IsValid(ent)) return
    try { EntFireByHandle(ent, cmd, "", 0.0, null, null) } catch (_e) {}
}

flagspawn._SetHelperEnabled <- function(ent, enabled) {
    flagspawn._EntCmd(ent, enabled ? "Enable" : "Disable")
}

// ------------------------------------------------------------
// tf_glow binding (real fix)
// ------------------------------------------------------------
flagspawn._BindGlowTarget <- function(glow, flag) {
    if (!flagspawn._IsValid(glow) || !flagspawn._IsValid(flag)) return false
    if (!("NetProps" in _rt)) return false

    try {
        NetProps.SetPropEntity(glow, "m_hTarget", flag)
        return true
    } catch (_e0) {}
    return false
}

// ------------------------------------------------------------
// Package registration (suffix used only for discovery + helper lookup)
// ------------------------------------------------------------
flagspawn._RegisterFlag <- function(flag) {
    if (!flagspawn._IsValid(flag)) return

    local nm = flagspawn._GetNameSafe(flag)
    local suf = flagspawn._ExtractSuffixDigits(nm)
    if (suf == null) return
    if (suf in flagspawn.State.Pkgs) return

    local isBlu = (nm.find(flagspawn.CFG.FLAG_baseName_BLU) == 0)
    local isRed = (nm.find(flagspawn.CFG.FLAG_baseName_RED) == 0)
    if (!isBlu && !isRed) return

    local pkg = {
        suffix = suf,
        flagHandle = flag,
        flagName = nm,

        // handles (may be null if your template differs)
        deny = null,
        pad  = null,
        glow = null,
        sfx  = null
    }

    // IMPORTANT:
    // - BLU flag template should include DENY_RED (red players deny blu flag)
    // - RED flag template should include DENY_BLU
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
        " flag=" + nm +
        " deny=" + flagspawn._GetNameSafe(pkg.deny) +
        " pad="  + flagspawn._GetNameSafe(pkg.pad) +
        " glow=" + flagspawn._GetNameSafe(pkg.glow) +
        " sfx="  + flagspawn._GetNameSafe(pkg.sfx))

    // Bind glow immediately
    if (flagspawn._IsValid(pkg.glow)) {
        local ok = flagspawn._BindGlowTarget(pkg.glow, flag)
        if (!ok) flagspawn._Dbg("GLOW bind FAILED for " + flagspawn._GetNameSafe(pkg.glow))
    }

    // Enforce “start disabled” safety in case Hammer missed one.
    // (We will re-enable on drop via Think.)
    flagspawn._SetHelperEnabled(pkg.deny, false)
    flagspawn._SetHelperEnabled(pkg.pad,  false)
    flagspawn._SetHelperEnabled(pkg.glow, false)
}

// Scan all flags by classname; register any new templated ones
flagspawn._ScanAndRegisterAllFlags <- function() {
    local e = null
    while ((e = Entities.FindByClassname(e, "item_teamflag")) != null) {
        flagspawn._RegisterFlag(e)
    }
}

// Cull pkgs whose flag got deleted (merge/return/cap)
flagspawn._CullDeadPkgs <- function() {
    foreach (suf, pkg in flagspawn.State.Pkgs) {
        if (!flagspawn._IsValid(pkg.flagHandle)) {
            flagspawn._Dbg("CULL suf=" + suf + " (flag invalid; engine deleted it)")
            delete flagspawn.State.Pkgs[suf]
        }
    }
}

// Apply state each tick (anti-spam)
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

        // Toggle once
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

// AddThinkToEnt requires a function name that exists in the host’s script scope.
// We expose a global thunk so it works regardless of where you call it from.
::flagspawn_think <- function() {
    return flagspawn._Think()
}

flagspawn._StartThink <- function() {
    local host = null
    try { host = self } catch (_e0) { host = null }
    if (!flagspawn._IsValid(host)) {
        try { host = Entities.FindByName(null, "scripter") } catch (_e1) { host = null }
    }
    if (!flagspawn._IsValid(host)) {
        printl("[FLAGSPAWN] ERROR: no valid host (self invalid, 'scripter' not found)")
        return
    }
    try {
        AddThinkToEnt(host, "flagspawn_think")
        flagspawn._Dbg("Think started on " + flagspawn._GetNameSafe(host))
    } catch (_e2) {
        printl("[FLAGSPAWN] ERROR: AddThinkToEnt failed (host scope issue?)")
    }
}

// ------------------------------------------------------------
// DENY PAD TOUCH (Pure Disabler)
// ------------------------------------------------------------
::FS_OnDenyPadTouch <- function() {
    if (!flagspawn.CFG.DENYPAD_ENABLE) return
    local trig = caller
    // 1. FILTER CHECK: Double-check team in script just in case
    // (Optional safety if Hammer filters fail)
    local ply = activator
    if (flagspawn._IsPlayer(ply)) {
        local plyTeam = ply.GetTeam()
        local trigName = flagspawn._GetNameSafe(trig)
        // If Red Trigger is touched by Blue Player, ABORT.
        if (trigName.find("deny_red") != null && plyTeam == flagspawn.TEAM_BLU) return
        if (trigName.find("deny_blu") != null && plyTeam == flagspawn.TEAM_RED) return
    }

    // 2. Find Flag (Parenting is preferred!)
    local flag = null
    try { flag = trig.GetMoveParent() } catch (_e0) { flag = null }

    // Fallback: Suffix lookup
    if (!flagspawn._IsValid(flag)) {
        local tn = flagspawn._GetNameSafe(trig)
        local suf = flagspawn._ExtractSuffixDigits(tn)
        if (suf != null && (suf in flagspawn.State.Pkgs)) {
            flag = flagspawn.State.Pkgs[suf].flagHandle
        }
    }

    if (!flagspawn._IsValid(flag)) return

    // 3. DISABLE FLAG (DENY)
    // We disable it immediately so it cannot be picked up.
    EntFireByHandle(flag, "Disable", "", 0.0, null, null)
    
    // 4. Play Sound
    local pkg = flagspawn.State.Pkgs[flagspawn._ExtractSuffixDigits(flagspawn._GetNameSafe(flag))]
    if (pkg && pkg.sfx) EntFireByHandle(pkg.sfx, "PlaySound", "", 0.0, null, null)

    // 5. Cooldown / Re-Enable Logic
    // (Set the flag to re-enable after X seconds)
    EntFireByHandle(flag, "Enable", "", flagspawn.CFG.DENYPAD_DISABLE_SEC, null, null)

    // NOTE: We do NOT call FS_OnLockPadTouch() here anymore.
}

// ------------------------------------------------------------
// FRIENDLY PAD TOUCH
// OnStartTouch -> scripter CallScriptFunction FS_OnLockPadTouch
// ------------------------------------------------------------
::FS_OnLockPadTouch <- function() {
    local ply = activator
    if (!flagspawn._IsPlayer(ply)) return

    // Prefer AbsVelocity (suppresses your spam warnings)
    local vel = Vector(0,0,0)
    local ok = false
    try { vel = ply.GetAbsVelocity(); ok = true } catch (_e0) { ok = false }
    if (!ok) { try { vel = ply.GetVelocity() } catch (_e1) { vel = Vector(0,0,0) } }

    local dir = Vector(vel.x, vel.y, 0)
    local d2 = dir.x*dir.x + dir.y*dir.y

    if (d2 < (flagspawn.CFG.PAD_MIN_2D_SPEED * flagspawn.CFG.PAD_MIN_2D_SPEED)) {
        // fallback to view forward
        local ang = null
        try { ang = ply.EyeAngles() } catch (_e2) { ang = null }
        if (ang != null) {
            local f = Vector(1,0,0)
            try { f = ang.Forward() } catch (_e3) { f = Vector(1,0,0) }
            dir = Vector(f.x, f.y, 0)
            d2 = dir.x*dir.x + dir.y*dir.y
        }
    }

    if (d2 <= 0.0001) return
    local inv = 1.0 / sqrt(d2)
    dir = Vector(dir.x*inv, dir.y*inv, 0)

    local add = Vector(
        dir.x * flagspawn.CFG.PAD_MOVE_DIR_SPEED,
        dir.y * flagspawn.CFG.PAD_MOVE_DIR_SPEED,
        flagspawn.CFG.PAD_MOVE_DIR_LIFT
    )

    local outv = Vector(vel.x + add.x, vel.y + add.y, vel.z + add.z)

    // Prefer SetAbsVelocity
    local setOk = false
    try { ply.SetAbsVelocity(outv); setOk = true } catch (_e4) { setOk = false }
    if (!setOk) { try { ply.SetVelocity(outv) } catch (_e5) {} }
}

// ------------------------------------------------------------
// OPTIONAL: teamplay_flag_event hook
// You can keep this wired for extra logging / faster toggles,
// but Think loop is authoritative.
// ------------------------------------------------------------
::FS_OnFlagEvent <- function() {
    local scope = null
    try { if (caller && caller.GetScriptScope()) scope = caller.GetScriptScope() } catch (_e0) { scope = null }
    if (scope == null) { try { if (self && self.GetScriptScope()) scope = self.GetScriptScope() } catch (_e1) { scope = null } }
    if (scope == null || !("event_data" in scope)) return

    local ev = scope.event_data
    local type = ("eventtype" in ev) ? ev.eventtype : -1
    local flagName = ("flagname" in ev) ? ev.flagname : ""

    if (flagspawn.CFG.DEBUG) flagspawn._Dbg("EVENT type=" + type + " flag=" + flagName)

    // No hard logic needed here. Think loop will enforce state.
}

// ------------------------------------------------------------
// Spawner touches (unchanged)
// ------------------------------------------------------------
flagspawn.State.SpawnerCooldown <- {}
flagspawn._SpawnerCooldownOK <- function(ply, tag, cd) {
    local now = flagspawn._Now()
    local uid = 0
    try { if ("GetPlayerUserId" in _rt) uid = GetPlayerUserId(ply) } catch (_e) { uid = 0 }
    local k = "" + tag + ":" + uid
    if (k in flagspawn.State.SpawnerCooldown && (now - flagspawn.State.SpawnerCooldown[k]) < cd) return false
    flagspawn.State.SpawnerCooldown[k] <- now
    return true
}
flagspawn._ForceSpawnMaker <- function(makerName) {
    local maker = null
    try { maker = Entities.FindByName(null, makerName) } catch (_e0) { maker = null }
    if (!flagspawn._IsValid(maker)) { printl("[SPAWNER] missing maker: " + makerName); return false }
    try { EntFireByHandle(maker, "ForceSpawn", "", 0.0, null, null) } catch (_e1) {}
    return true
}
::FS_OnSpawnerTouchBlu <- function() {
    local ply = activator
    if (!flagspawn._IsPlayer(ply)) return
    if (!flagspawn._SpawnerCooldownOK(ply, "BLU", 0.25)) return
    printl("[SPAWNER] BLU touch")
    flagspawn._ForceSpawnMaker("fs_flag_maker_blu")
}
::FS_OnSpawnerTouchRed <- function() {
    local ply = activator
    if (!flagspawn._IsPlayer(ply)) return
    if (!flagspawn._SpawnerCooldownOK(ply, "RED", 0.25)) return
    printl("[SPAWNER] RED touch")
    flagspawn._ForceSpawnMaker("fs_flag_maker_red")
}

// ------------------------------------------------------------
// INIT
// ------------------------------------------------------------
flagspawn._StartThink()
