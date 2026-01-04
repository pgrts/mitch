// ============================================================
// fs_spawner_diag.nut — helper to debug flag spawner triggers
// Usage inside TF2:
//   script_execute flagspawn.nut          // load core logic
//   script_execute fs_spawner_diag.nut    // attach debugging hooks
//   fs_spawner_diag.Setup()               // disable capper triggers (optional) and attach logging
// You can re-enable cappers later with fs_spawner_diag.EnableCappers().
// ============================================================

local rt = getroottable();
if (!("fs_spawner_diag" in rt)) rt["fs_spawner_diag"] <- {};
::fs_spawner_diag <- rt["fs_spawner_diag"];

::fs_spawner_diag._watched <- ["blutrigger", "redtrigger", "blucapper", "redcapper"];

::fs_spawner_diag.Log <- function(msg) {
    printl("[fs_spawner_diag] " + msg);
};

::fs_spawner_diag._TryConnect <- function(name) {
    local trig = Entities.FindByName(null, name);
    if (!trig) {
        ::fs_spawner_diag.Log("missing trigger '" + name + "'");
        return;
    }

    trig.ValidateScriptScope();
    local sc = trig.GetScriptScope();
    sc.fsdiag_name <- name;
    sc.OnStartTouch_fsdiag <- function(ent) {
        ::fs_spawner_diag.Log("OnStartTouch " + fsdiag_name + " activator=" + ent);
    };
    sc.OnEndTouch_fsdiag <- function(ent) {
        ::fs_spawner_diag.Log("OnEndTouch " + fsdiag_name + " activator=" + ent);
    };

    trig.ConnectOutput("OnStartTouch", "OnStartTouch_fsdiag");
    trig.ConnectOutput("OnEndTouch", "OnEndTouch_fsdiag");

    ::fs_spawner_diag.Log("watching trigger '" + name + "'");
};

::fs_spawner_diag.DisableCappers <- function() {
    EntFire("redcapper", "Disable");
    EntFire("blucapper", "Disable");
    ::fs_spawner_diag.Log("capture triggers disabled (isolating spawner touches)");
};

::fs_spawner_diag.EnableCappers <- function() {
    EntFire("redcapper", "Enable");
    EntFire("blucapper", "Enable");
    ::fs_spawner_diag.Log("capture triggers re-enabled");
};

::fs_spawner_diag.Setup <- function() {
    // optional: keep captures from intercepting touches while testing spawners
    ::fs_spawner_diag.DisableCappers();

    foreach (nm in ::fs_spawner_diag._watched) {
        ::fs_spawner_diag._TryConnect(nm);
    }

    if ("flagspawn" in rt) {
        ::flagspawn.DEBUG <- true; // make sure base script logs too
    }

    ::fs_spawner_diag.Log("spawner diagnostics ready: move a player through triggers and watch console output");
};
