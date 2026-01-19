// flagspawn/fs_economy.nut
// Pickup/Drop ledger + Return/Capture economy.

local rt = getroottable();
local FS = rt.flagspawn;

// item_teamflag: OnPickup -> CallScriptFunction(FS_Direct_Pickup)
FS.OnFlagPickup <- function(flag, ply) {
    if (!FS.IsValid(flag) || !FS.IsValid(ply)) return;

    local v = FS._GetFlagValue(flag);
    if (v <= 0) return;

    // Add to carrier ledger (this is what damage/death uses)
    local cur = FS._CarryGet(ply);
    local nv = cur + v;
    if (nv > FS.CFG.CARRY_CAP) nv = FS.CFG.CARRY_CAP;
    FS._CarrySet(ply, nv);
}

// item_teamflag: OnDrop -> CallScriptFunction(FS_Direct_Drop)
FS.OnFlagDrop <- function(flag, ply) {
    if (!FS.IsValid(flag) || !FS.IsValid(ply)) return;

    local v = FS._GetFlagValue(flag);
    if (v <= 0) return;

    // Subtract from carrier ledger
    local cur = FS._CarryGet(ply);
    cur -= v;
    if (cur < 0) cur = 0;
    FS._CarrySet(ply, cur);
}

// item_teamflag: OnReturn -> CallScriptFunction(FS_Direct_Return)
FS.OnFlagReturn <- function(flag, ply) {
    if (!FS.IsValid(flag)) return;

    local team = 0;
    try { team = flag.GetTeam(); } catch(_e) { team = 0; }
    if (!FS._TeamOK(team)) return;

    local v = FS._GetFlagValue(flag);
    if (v < 0) v = 0;

    // Return refunds to OWNING TEAM pool (1x)
    FS._AddPool(team, v);
    FS._UpdateMeter(team);

    if (FS.State.Active[team] > 0) FS.State.Active[team] = FS.State.Active[team] - 1;
    FS._UpdateStockText(team);
}

// item_teamflag: OnCapture -> CallScriptFunction(FS_Direct_Capture)
FS.OnFlagCapture <- function(flag, ply) {
    if (!FS.IsValid(flag)) return;

    // Capturer team (prefer activator)
    local t = 0;
    if (FS.IsValid(ply)) { try { t = ply.GetTeam(); } catch(_e) { t = 0; } }
    if (!FS._TeamOK(t)) { try { t = flag.GetTeam(); } catch(_e2) { t = 0; } }
    if (!FS._TeamOK(t)) return;

    local v = FS._GetFlagValue(flag);
    if (v < 0) v = 0;

    // Award = 2x value
    local award = v * 2;

    // First-blood window bonus
    local left = FS.CFG.FIRST_WINDOW - (Time() - FS.State.RoundT0);
    if (left < 0) left = 0;

    local pid = FS._Pid(ply);
    if (left > 0 && pid > 0) {
        local can = true;
        if (pid in FS.State.FirstClaim) can = false;
        if (FS.State.FirstCount[t] >= FS.CFG.FIRST_MAX) can = false;
        if (can) {
            FS.State.FirstClaim[pid] <- true;
            FS.State.FirstCount[t] = FS.State.FirstCount[t] + 1;
            award += floor(left);
        }
    }

    FS._AddPool(t, award);
    FS._UpdateMeter(t);

    // Capture refresh: allow spawner again this life
    if (pid > 0) FS.State.UsedSpawn[pid] <- false;

    // Subtract from capturer ledger
    if (FS.IsValid(ply) && v > 0) {
        local cur = FS._CarryGet(ply);
        cur -= v;
        if (cur < 0) cur = 0;
        FS._CarrySet(ply, cur);
    }

    // Active stock bookkeeping (decrement the flag's team)
    local ft = 0;
    try { ft = flag.GetTeam(); } catch(_e3) { ft = 0; }
    if (FS._TeamOK(ft) && FS.State.Active[ft] > 0) FS.State.Active[ft] = FS.State.Active[ft] - 1;
    FS._UpdateStockText(ft);
}

// player_spawn (optional reset)
FS.OnPlayerSpawnEvent <- function() {
    if (!('event_data' in rt)) return;
    local e = rt.event_data;
    if (!('userid' in e)) return;
    local p = GetPlayerFromUserID(e.userid);
    if (!FS.IsValid(p)) return;
    FS.State.UsedSpawn[p.GetEntityIndex()] <- false;
}
