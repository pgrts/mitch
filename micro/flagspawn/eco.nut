// flagspawn/eco.nut (microservices v7)
// Flag pickup/drop visuals + return/capture economy (no teamplay_flag_event dependency).

local rt = getroottable();
local FS = rt.flagspawn;

FS._UnregisterPkg <- function(pkg) {
    if (!pkg) return;
    if (pkg.suffix in FS.State.Flags) delete FS.State.Flags[pkg.suffix];
    if (pkg.flag && FS.IsValid(pkg.flag)) {
        local idx = FS._EntIndex(pkg.flag);
        if (idx > 0) {
            local k = idx.tostring();
            if (k in FS.State.ByEnt) delete FS.State.ByEnt[k];
        }
    }
};

FS._InferTeamFromFlagName <- function(flag) {
    local nm = FS._EntName(flag);
    foreach (team, prefix in FS.CFG.FLAG_BASE) {
        if (prefix && FS._StartsWith(nm, prefix)) return team;
    }
    return 0;
};

// item_teamflag OnPickup -> CallScriptFunction(FS_Direct_Pickup)
FS.OnFlagPickup <- function(flag, ply) {
    if (!FS.IsValid(flag) || !FS.IsValid(ply)) return;
    local pkg = FS._FindPkgByFlag(flag);
    if (pkg) FS._PkgFlashGlow(pkg, FS.CFG.GLOW_DURATION_PICKUP);
};

// item_teamflag OnDrop -> CallScriptFunction(FS_Direct_Drop)
FS.OnFlagDrop <- function(flag, ply) {
    if (!FS.IsValid(flag)) return;
    local pkg = FS._FindPkgByFlag(flag);
    if (pkg) FS._PkgFlashGlow(pkg, FS.CFG.GLOW_DURATION_DROP);
};

// item_teamflag OnReturn -> CallScriptFunction(FS_Direct_Return)
FS.OnFlagReturn <- function(flag, ply) {
    if (!FS.IsValid(flag)) return;

    local pkg = FS._FindPkgByFlag(flag);
    local spawnTeam = pkg ? pkg.team : FS._InferTeamFromFlagName(flag);
    if (!FS._TeamOK(spawnTeam)) return;

    local v = FS._GetPointValue(flag);
    if (v < 0) v = 0;

    // Return: 1x value -> owning spawner pool
    FS._AddPool(spawnTeam, v);

    // Kill and unregister (frees stock if this was a spawner flag; merge sinks already handled elsewhere)
    if (pkg) {
        FS._PkgKillAll(pkg);
        FS._UnregisterPkg(pkg);
    } else {
        FS._TryKill(flag);
    }

    FS._UpdateUI();
};

// item_teamflag OnCapture -> CallScriptFunction(FS_Direct_Capture)
FS.OnFlagCapture <- function(flag, ply) {
    if (!FS.IsValid(flag)) return;

    local pkg = FS._FindPkgByFlag(flag);
    local spawnTeam = pkg ? pkg.team : FS._InferTeamFromFlagName(flag);
    if (!FS._TeamOK(spawnTeam)) return;

    // Capturer team (prefer activator)
    local capTeam = 0;
    if (FS.IsValid(ply)) {
        try { capTeam = ply.GetTeam(); } catch (_e0) { capTeam = 0; }
    }
    if (!FS._TeamOK(capTeam)) capTeam = spawnTeam;

    local v = FS._GetPointValue(flag);
    if (v < 0) v = 0;

    // Capture: 3x value (new change)
    local award = v * FS.CFG.CAP_MULT;

    // Optional first-blood bonus window
    local left = FS.CFG.FIRST_WINDOW - (Time() - FS.State.RoundT0);
    if (left < 0) left = 0;

    local pid = FS._EntIndex(ply);
    if (left > 0 && pid > 0) {
        local can = true;
        if (pid in FS.State.FirstClaim) can = false;
        if (FS.State.FirstCount[capTeam] >= FS.CFG.FIRST_MAX) can = false;
        if (can) {
            FS.State.FirstClaim[pid] <- true;
            FS.State.FirstCount[capTeam] = FS.State.FirstCount[capTeam] + 1;
            award += floor(left);
        }
    }

    FS._AddPool(capTeam, award);

    // Capture refresh: allow spawner again this life
    if (pid > 0) FS.State.UsedSpawn[pid] <- false;

    // Kill + unregister the captured flag package (frees stock for spawnTeam spawner)
    if (pkg) {
        FS._PkgKillAll(pkg);
        FS._UnregisterPkg(pkg);
    } else {
        FS._TryKill(flag);
    }

    FS._UpdateUI();
};

// player_spawn listener (optional): reset spawner use this life
FS.OnPlayerSpawnEvent <- function() {
    if (!("event_data" in rt)) return;
    local e = rt.event_data;
    if (!("userid" in e)) return;
    local p = GetPlayerFromUserID(e.userid);
    if (!FS.IsValid(p)) return;
    local pid = FS._EntIndex(p);
    if (pid > 0) FS.State.UsedSpawn[pid] <- false;
    if (pid > 0) FS.State.DmgAcc[pid] <- 0.0;
};
