// ============================================================
// flagspawn_spawner_replacement.nut
// Drop-in replacement for flagspawn.nut when debugging spawner
// triggers inside fs_gamemode.vmf / flagspawngamemode.vmf.
//
// Goals:
// - Print every spawner/capper touch so you can confirm Hammer
//   trigger volumes fire as expected.
// - Keep capture triggers disabled by default so they do not
//   intercept touches while you iterate on spawner geometry.
// - Avoid manipulating intel entities; this is a touch logger
//   only, intended for diagnosis.
//
// Usage in console:
//   script_execute flagspawn_spawner_replacement.nut
//   flagspawn.Setup();
//
// When done iterating, re-enable capture triggers:
//   flagspawn.EnableCappers();
// ============================================================

// ---- ROOT TABLE ----
local rt = getroottable();
if (!("flagspawn" in rt)) rt["flagspawn"] <- {};
::flagspawn <- rt["flagspawn"];

::flagspawn.DEBUG <- true;
::flagspawn.TEAM_RED <- 2;
::flagspawn.TEAM_BLU <- 3;
::flagspawn._cappersDisabled <- false;

::flagspawn.Log <- function(msg) { printl("[flagspawn-diag] " + msg); };

::flagspawn.TeamName <- function(t) {
    if (t == ::flagspawn.TEAM_RED) return "RED";
    if (t == ::flagspawn.TEAM_BLU) return "BLU";
    return "UNKNOWN";
};

::flagspawn.PlayerTeam <- function(player) {
    if (!player) return 0;
    try { return player.GetTeam(); } catch (e) { return 0; }
};

::flagspawn.CapperNames <- function() {
    return { [::flagspawn.TEAM_RED] = "redcapper", [::flagspawn.TEAM_BLU] = "blucapper" };
};

::flagspawn.SpawnerNames <- function() {
    return { [::flagspawn.TEAM_RED] = "redtrigger", [::flagspawn.TEAM_BLU] = "blutrigger" };
};

::flagspawn.TeamFromParam <- function(teamOrCaller) {
    if (typeof teamOrCaller == "integer") return teamOrCaller;
    if (!teamOrCaller) return 0;
    local nm = "";
    try { nm = teamOrCaller.GetName(); } catch (e) { nm = ""; }
    nm = nm.tolower();
    if (nm.find("blu") != null) return ::flagspawn.TEAM_BLU;
    if (nm.find("red") != null) return ::flagspawn.TEAM_RED;
    return 0;
};

::flagspawn._EachByName <- function(name, fn) {
    local ent = null;
    while (true) {
        ent = Entities.FindByName(ent, name);
        if (!ent) break;
        fn(ent);
    }
};

::flagspawn.DisableCappers <- function() {
    foreach (team, nm in ::flagspawn.CapperNames()) {
        ::flagspawn._EachByName(nm, function(ent) {
            ent.AcceptInput("Disable", "", null, null);
        });
    }
    ::flagspawn._cappersDisabled = true;
    ::flagspawn.Log("Cappers disabled (redcapper/blucapper)");
};

::flagspawn.EnableCappers <- function() {
    foreach (team, nm in ::flagspawn.CapperNames()) {
        ::flagspawn._EachByName(nm, function(ent) {
            ent.AcceptInput("Enable", "", null, null);
        });
    }
    ::flagspawn._cappersDisabled = false;
    ::flagspawn.Log("Cappers enabled");
};

::flagspawn.ReportMissingTriggers <- function() {
    local missing = [];
    foreach (team, nm in ::flagspawn.SpawnerNames()) {
        local found = Entities.FindByName(null, nm);
        if (!found) missing.append(nm);
    }
    foreach (team, nm in ::flagspawn.CapperNames()) {
        local found = Entities.FindByName(null, nm);
        if (!found) missing.append(nm);
    }
    if (missing.len() == 0) {
        ::flagspawn.Log("All spawner/capper triggers found (redtrigger, blutrigger, redcapper, blucapper)");
    } else {
        ::flagspawn.Log("Missing triggers: " + missing.join(", "));
    }
};

::flagspawn.Setup <- function() {
    ::flagspawn.Log("Diag replacement loaded @ t=" + Time());
    ::flagspawn.DisableCappers();
    ::flagspawn.ReportMissingTriggers();
};

::flagspawn.OnSpawnerTouch <- function(activator, teamOrCaller, caller = null, value = null) {
    local team = ::flagspawn.TeamFromParam(teamOrCaller);
    local playerTeam = ::flagspawn.PlayerTeam(activator);
    local actor = "";
    try { actor = activator.GetPlayerName(); } catch (e) { actor = "<non-player>"; }
    ::flagspawn.Log("OnSpawnerTouch teamParam=" + team + " (" + ::flagspawn.TeamName(team) + ") activatorTeam=" + ::flagspawn.TeamName(playerTeam) + " name=" + actor);
};

::flagspawn.OnCaptureTouch <- function(activator, teamOrCaller, caller = null) {
    local team = ::flagspawn.TeamFromParam(teamOrCaller);
    local playerTeam = ::flagspawn.PlayerTeam(activator);
    local actor = "";
    try { actor = activator.GetPlayerName(); } catch (e) { actor = "<non-player>"; }
    ::flagspawn.Log("OnCaptureTouch teamParam=" + team + " (" + ::flagspawn.TeamName(team) + ") activatorTeam=" + ::flagspawn.TeamName(playerTeam) + " name=" + actor + (" cappersDisabled=" + ::flagspawn._cappersDisabled));
};

::flagspawn.OnPlayerSpawn <- function(player) {
    local team = ::flagspawn.PlayerTeam(player);
    local nm = "";
    try { nm = player.GetPlayerName(); } catch (e) { nm = "<player>"; }
    ::flagspawn.Log("OnPlayerSpawn team=" + ::flagspawn.TeamName(team) + " name=" + nm);
};

::flagspawn.OnGameEvent_player_spawn <- function(params) {
    ::flagspawn.OnPlayerSpawn(GetPlayerFromUserID(params.userid));
};

::flagspawn.OnScriptHook_OnTakeDamage <- function(params) {
    // Keep hooks inert; we only log spawner/capper touches.
    return 0;
};
