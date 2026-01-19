// spw.nut (FULL FILE) - Flagspawn spawner service + meter sync (prop01/02/03)
// Uses bodygroup INDEX 1 (SetBodygroup(1,val))

local rt = getroottable();
if (!("flagspawn" in rt)) rt.flagspawn <- {};
local FS = rt.flagspawn;

// ---------------------------- small safe helpers ----------------------------

FS.SpwOkEnt <- function(entHandle)
{
    return (entHandle != null && entHandle.IsValid());
};

FS.SpwTok <- function(teamNum)
{
    local redNum = ("TEAM_RED" in FS.CFG) ? FS.CFG.TEAM_RED : 2;
    local bluNum = ("TEAM_BLU" in FS.CFG) ? FS.CFG.TEAM_BLU : 3;
    return (teamNum == redNum || teamNum == bluNum);
};

FS.SpwPid <- function(plrEnt)
{
    if (!FS.SpwOkEnt(plrEnt)) return 0;
    local pidVal = 0;
    try { pidVal = plrEnt.GetPlayerUserId(); } catch (_e) {}
    if (pidVal > 0) return pidVal;
    try { pidVal = plrEnt.GetEntityIndex(); } catch (_e2) {}
    return pidVal;
};

FS.SpwClamp <- function(v, lo, hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
};

FS.SpwCfgGet <- function(k, defVal)
{
    if (!("CFG" in FS)) FS.CFG <- {};
    return (k in FS.CFG) ? FS.CFG[k] : defVal;
};

// ---------------------------- state init ----------------------------

FS.SpwInit <- function()
{
    if (!("S" in FS)) FS.S <- {};

    if (!("Q" in FS.S))  FS.S.Q  <- [];      // spawn context queue
    if (!("N" in FS.S))  FS.S.N  <- { [2]=0, [3]=0 }; // inflight spawns per team
    if (!("A" in FS.S))  FS.S.A  <- { [2]=0, [3]=0 }; // active spawner flags per team
    if (!("P" in FS.S))  FS.S.P  <- { [2]=0, [3]=0 }; // pool per team (eco.nut normally owns this)

    if (!("BU" in FS.S)) FS.S.BU <- {};  // uses in window per pid
    if (!("BT" in FS.S)) FS.S.BT <- {};  // window start time per pid
    if (!("TL" in FS.S)) FS.S.TL <- {};  // touch lock until time per pid

    if (!("BM" in FS.S)) FS.S.BM <- {};  // mult per pid (1/3)
    if (!("BE" in FS.S)) FS.S.BE <- {};  // mult expiry per pid

    if (!("SF" in FS.S)) FS.S.SF <- {};  // entindex -> { h=handle, t=team }

    if (!("MS" in FS.S)) FS.S.MS <- { [2]=0, [3]=0 }; // meter flash seq per team
};

// ---------------------------- meter (sync 01/02/03) ----------------------------

FS.SpwMeterPrefix <- function(teamNum)
{
    if ("MPF" in FS.CFG && teamNum in FS.CFG.MPF) return FS.CFG.MPF[teamNum];

    // fallback names (your note: blu_flagspawner_prop01 etc.)
    local redNum = FS.SpwCfgGet("TEAM_RED", 2);
    if (teamNum == redNum) return "red_flagspawner_prop";
    return "blu_flagspawner_prop";
};

FS.SpwMeterCount <- function()
{
    return FS.SpwCfgGet("MC", 3);
};

FS.SpwMeterSetAll <- function(teamNum, bgVal)
{
    local prefixStr = FS.SpwMeterPrefix(teamNum);
    local countNum = FS.SpwMeterCount();

    bgVal = FS.SpwClamp(bgVal, 0, 100);

    for (local idx = 1; idx <= countNum; idx++)
    {
        local entName = prefixStr + format("%02d", idx);
        local propEnt = Entities.FindByName(null, entName);
        if (FS.SpwOkEnt(propEnt))
        {
            if ("Bg" in FS) { try { FS.Bg(propEnt, 1, bgVal); } catch (_e0) {} }
            else { try { propEnt.SetBodygroup(1, bgVal); } catch (_e1) {} }
        }
    }
};

FS.SpwMeterPortion <- function(teamNum)
{
    local divAmt = FS.SpwCfgGet("PORTION_DIV", 5);
    if (divAmt < 1) divAmt = 5;

    local poolNow = 0;
    if ("P" in FS.S && teamNum in FS.S.P) poolNow = FS.S.P[teamNum];

    local poolCap = FS.SpwCfgGet("PCAP", 300);
    if (poolNow < 0) poolNow = 0;
    if (poolNow > poolCap) poolNow = poolCap;

    return floor(poolNow.tofloat() / divAmt.tofloat());
};

FS.SpwMeterUpdate <- function(teamNum)
{
    local showVal = FS.SpwMeterPortion(teamNum);
    FS.SpwMeterSetAll(teamNum, showVal);
};

FS.SpwMeterFlashTaken <- function(teamNum, takenVal)
{
    if (FS.SpwCfgGet("METER_FLASH_TAKEN", 0) == 0) { FS.SpwMeterUpdate(teamNum); return; }

    FS.S.MS[teamNum] = FS.S.MS[teamNum] + 1;
    local seqNum = FS.S.MS[teamNum];

    FS.SpwMeterSetAll(teamNum, takenVal);

    local ctrlName = FS.SpwCfgGet("SCRIPTER_NAME", "scripter");
    local ctrlEnt = Entities.FindByName(null, ctrlName);
    if (!FS.SpwOkEnt(ctrlEnt)) return;

    local delaySec = FS.SpwCfgGet("METER_FLASH_SEC", 0.75);
    if (delaySec < 0.05) delaySec = 0.05;

    local cmdStr = format("getroottable().flagspawn.SpwMeterRevert(%d,%d)", teamNum, seqNum);
    EntFireByHandle(ctrlEnt, "RunScriptCode", cmdStr, delaySec, null, null);
};

FS.SpwMeterRevert <- function(teamNum, seqNum)
{
    if (!FS.SpwTok(teamNum)) return;
    if (!(teamNum in FS.S.MS)) return;
    if (FS.S.MS[teamNum] != seqNum) return;
    FS.SpwMeterUpdate(teamNum);
};

// ---------------------------- class bonus + window ----------------------------

FS.SpwGetUseMax <- function(plrEnt)
{
    local clsNum = 0; try { clsNum = plrEnt.GetPlayerClass(); } catch (_e) {}
    if ("BUDGET_CLASS_MAX" in FS.CFG && (clsNum in FS.CFG.BUDGET_CLASS_MAX)) return FS.CFG.BUDGET_CLASS_MAX[clsNum];
    return 1;
};

FS.SpwGetClassBonus <- function(plrEnt)
{
    local clsNum = 0; try { clsNum = plrEnt.GetPlayerClass(); } catch (_e) {}

    if ("BONUS_CLASS_POINTS" in FS.CFG && (clsNum in FS.CFG.BONUS_CLASS_POINTS)) return FS.CFG.BONUS_CLASS_POINTS[clsNum];
    // fallback: use BUDGET_CLASS_MAX as class bonus if you never defined BONUS_CLASS_POINTS
    if ("BUDGET_CLASS_MAX" in FS.CFG && (clsNum in FS.CFG.BUDGET_CLASS_MAX)) return FS.CFG.BUDGET_CLASS_MAX[clsNum];

    return 0;
};

FS.SpwGetMult <- function(pidVal)
{
    if (!(pidVal in FS.S.BM)) return 1;
    if ((pidVal in FS.S.BE) && Time() > FS.S.BE[pidVal]) { delete FS.S.BM[pidVal]; delete FS.S.BE[pidVal]; return 1; }
    return FS.S.BM[pidVal];
};

FS.SpwResetWindowIfNeeded <- function(pidVal)
{
    local resetSec = FS.SpwCfgGet("WINDOW_RESET_SEC", 90.0);
    if (!(pidVal in FS.S.BT)) { FS.S.BT[pidVal] <- Time(); FS.S.BU[pidVal] <- 0; return; }
    if (Time() - FS.S.BT[pidVal] >= resetSec) { FS.S.BT[pidVal] <- Time(); FS.S.BU[pidVal] <- 0; }
};

FS.SpwTouchLocked <- function(pidVal)
{
    if (!(pidVal in FS.S.TL)) return false;
    return Time() < FS.S.TL[pidVal];
};

FS.SpwLockTouch <- function(pidVal, durSec)
{
    FS.S.TL[pidVal] <- Time() + durSec;
};

FS.SpwUnlockTouch <- function(pidVal)
{
    if (pidVal in FS.S.TL) FS.S.TL[pidVal] <- 0.0;
};

// ---------------------------- slots (spawner-only) ----------------------------

FS.SpwSlotMax <- function(teamNum)
{
    if ("SPAWN_SLOT_MAX" in FS.CFG && teamNum in FS.CFG.SPAWN_SLOT_MAX) return FS.CFG.SPAWN_SLOT_MAX[teamNum];
    if ("SLOT_MAX" in FS.CFG && teamNum in FS.CFG.SLOT_MAX) return FS.CFG.SLOT_MAX[teamNum];
    return 99;
};

FS.SpwSlotsLeft <- function(teamNum)
{
    local slotMax = FS.SpwSlotMax(teamNum);
    local active = (teamNum in FS.S.A) ? FS.S.A[teamNum] : 0;
    local inflight = (teamNum in FS.S.N) ? FS.S.N[teamNum] : 0;
    local left = slotMax - (active + inflight);
    if (left < 0) left = 0;
    return left;
};

// ---------------------------- maker find ----------------------------

FS.SpwFindMaker <- function(teamNum)
{
    if ("Mk" in FS) {
        local mkEnt = null;
        try { mkEnt = FS.Mk(teamNum, false); } catch (_e) { mkEnt = null; }
        if (FS.SpwOkEnt(mkEnt)) return mkEnt;
    }

    local bluNum = FS.SpwCfgGet("TEAM_BLU", 3);
    local nm = (teamNum == bluNum) ? FS.SpwCfgGet("MAKER_BLU", "fs_flag_maker_blu") : FS.SpwCfgGet("MAKER_RED", "fs_flag_maker_red");
    return Entities.FindByName(null, nm);
};

// ---------------------------- flag track (merge-kill reclaim) ----------------------------

FS.SpwTrackFlag <- function(flagEnt, teamNum)
{
    local entIdx = 0; try { entIdx = flagEnt.GetEntityIndex(); } catch (_e) { return; }
    FS.S.SF[entIdx] <- { h = flagEnt, t = teamNum };
};

FS.SpwUntrackFlag <- function(flagEnt)
{
    local entIdx = 0;
    try { entIdx = flagEnt.GetEntityIndex(); } catch (_e) { return; }
    if ("SF" in FS.S && (entIdx in FS.S.SF)) delete FS.S.SF[entIdx];
};

FS.SpwReconcile <- function()
{
    foreach (entIdx, rec in FS.S.SF)
    {
        local hEnt = ("h" in rec) ? rec.h : null;
        local tNum = ("t" in rec) ? rec.t : 0;

        if (hEnt == null || !hEnt.IsValid())
        {
            if (FS.SpwTok(tNum))
            {
                if (!(tNum in FS.S.A)) FS.S.A[tNum] <- 0;
                FS.S.A[tNum] = FS.S.A[tNum] - 1;
                if (FS.S.A[tNum] < 0) FS.S.A[tNum] = 0;
            }
            delete FS.S.SF[entIdx];
        }
    }
};

function FS_SpwThink()
{
    local FS2 = getroottable().flagspawn;
    if ("SpwReconcile" in FS2) FS2.SpwReconcile();
    return FS2.SpwCfgGet("SPW_RECONCILE_SEC", 1.5);
}

FS.SpwStartThink <- function()
{
    local ctrlName = FS.SpwCfgGet("SCRIPTER_NAME", "scripter");
    local ctrlEnt = Entities.FindByName(null, ctrlName);
    if (FS.SpwOkEnt(ctrlEnt))
    {
        try { AddThinkToEnt(ctrlEnt, "FS_SpwThink"); } catch (_e) {}
    }
};

// ---------------------------- MAIN ENTRY ----------------------------

FS.OnSpawnerTouch <- function(teamNum, plrEnt)
{
    FS.SpwInit();
    if (!FS.SpwTok(teamNum) || !FS.SpwOkEnt(plrEnt)) return;

    local pidVal = FS.SpwPid(plrEnt);
    if (pidVal <= 0) return;

    if (FS.SpwTouchLocked(pidVal)) return;
    if (FS.SpwSlotsLeft(teamNum) <= 0) return;

    FS.SpwResetWindowIfNeeded(pidVal);

    local usedAmt = (pidVal in FS.S.BU) ? FS.S.BU[pidVal] : 0;
    local useMax = FS.SpwGetUseMax(plrEnt);
    if (usedAmt >= useMax) return;

    // carry cap (if core provides FS.Cg, use it; else assume 0)
    local carryNow = 0;
    if ("Cg" in FS) { try { carryNow = FS.Cg(plrEnt); } catch (_e) { carryNow = 0; } }
    local carryCap = FS.SpwCfgGet("CCAP", 99);
    local carryLeft = carryCap - carryNow;
    if (carryLeft <= 0) return;

    // pool portion + class bonus
    local portionAmt = FS.SpwMeterPortion(teamNum);

    local clsBonus = FS.SpwGetClassBonus(plrEnt);
    local multNow = FS.SpwGetMult(pidVal);
    clsBonus = clsBonus * multNow;

    local valAmt = portionAmt + clsBonus;

    local valCap = FS.SpwCfgGet("VCAP", 99);
    valAmt = FS.SpwClamp(valAmt, 1, valCap);
    if (valAmt > carryLeft) valAmt = carryLeft;
    if (valAmt < 1) return;

    local makerEnt = FS.SpwFindMaker(teamNum);
    if (!FS.SpwOkEnt(makerEnt)) return;

    FS.S.BU[pidVal] <- usedAmt + 1;

    local lockSec = FS.SpwCfgGet("SPW_TOUCHLOCK_SEC", 0.15);
    FS.SpwLockTouch(pidVal, lockSec);

    if (!(teamNum in FS.S.N)) FS.S.N[teamNum] <- 0;
    FS.S.N[teamNum] = FS.S.N[teamNum] + 1;

    // ctx: [team,val,portion,pid]
    FS.S.Q.append([teamNum, valAmt, portionAmt, pidVal]);

    EntFireByHandle(makerEnt, "ForceSpawn", "", 0.0, null, null);

    // optional: text update if you have it
    if ("Utxt" in FS) { try { FS.Utxt(teamNum); } catch (_e2) {} }
};

// Called when maker actually spawned the flag entity
FS.OnMakerSpawned <- function(flagEnt)
{
    FS.SpwInit();
    if (!FS.SpwOkEnt(flagEnt)) return;
    if (FS.S.Q.len() <= 0) return;

    local ctx = FS.S.Q[0];
    FS.S.Q.remove(0);

    local teamNum = ctx[0];
    local valAmt = ctx[1];
    local portionAmt = ctx[2];
    local pidVal = ctx[3];

    if (!FS.SpwTok(teamNum)) return;

    // mark script scope (spawner-origin)
    try {
        flagEnt.ValidateScriptScope();
        flagEnt.GetScriptScope().fs_spawner <- 1;
        flagEnt.GetScriptScope().fs_team <- teamNum;
        flagEnt.GetScriptScope().fs_val <- valAmt;
    } catch (_e3) {}

    // spend from pool (portion only by default)
    local spendAmt = portionAmt;
    if (FS.SpwCfgGet("SPEND_CLASS_BONUS_FROM_POOL", 0) == 1) spendAmt = valAmt;

    if (spendAmt > 0)
    {
        if ("ConsP" in FS) { try { FS.ConsP(teamNum, spendAmt); } catch (_e4) {} }
        else {
            if (!(teamNum in FS.S.P)) FS.S.P[teamNum] <- 0;
            FS.S.P[teamNum] = FS.S.P[teamNum] - spendAmt;
            if (FS.S.P[teamNum] < 0) FS.S.P[teamNum] = 0;
        }
    }

    // set PD value + model bodygroup
    if ("Sv" in FS) { try { FS.Sv(flagEnt, valAmt); } catch (_e5) {} }
    else {
        try { NetProps.SetPropInt(flagEnt, "m_nPointValue", valAmt); } catch (_e6) {}
        try { flagEnt.SetBodygroup(1, FS.SpwClamp(valAmt, 0, 100)); } catch (_e7) {}
    }

    // Ensure sibling prop has the same value bodygroup even while disabled/hidden.
    // (When the flag is picked up, the prop replaces the carried flag model on the player.)
    local suf = "";
    try {
        local nm = flagEnt.GetName();
        local pos = nm.find("&");
        if (pos != null) suf = nm.slice(pos);
    } catch (_e7b) {}
    if (suf != "")
    {
        local pfx = ("PPF" in FS.CFG && teamNum in FS.CFG.PPF) ? FS.CFG.PPF[teamNum] : ((teamNum == 2) ? "redflag_prop" : "bluflag_prop");
        local propEnt = Entities.FindByName(null, pfx + suf);
        if (FS.SpwOkEnt(propEnt))
        {
            local bgv = FS.SpwClamp(valAmt, 0, 100);
            if ("Bg" in FS) { try { FS.Bg(propEnt, 1, bgv); } catch (_e7c) {} }
            else { try { propEnt.SetBodygroup(1, bgv); } catch (_e7d) {} }

            // Default state is dropped: prop stays hidden until pickup.
            try { EntFireByHandle(propEnt, "DisableDraw", "", 0.0, null, null); } catch (_e7e) {}
            try { EntFireByHandle(propEnt, "Disable", "", 0.0, null, null); } catch (_e7f) {}
        }
    }

    // meter feedback: flash the *pool portion* (budget bonus), not the class bonus
    FS.SpwMeterFlashTaken(teamNum, FS.SpwClamp(portionAmt, 0, 100));

    // finish inflight + active counts
    FS.S.N[teamNum] = FS.S.N[teamNum] - 1;
    if (FS.S.N[teamNum] < 0) FS.S.N[teamNum] = 0;

    FS.S.A[teamNum] = FS.S.A[teamNum] + 1;

    // track for merge-kill slot reclaim
    FS.SpwTrackFlag(flagEnt, teamNum);

    // unlock touch
    if (pidVal > 0) FS.SpwUnlockTouch(pidVal);

    if ("Utxt" in FS) { try { FS.Utxt(teamNum); } catch (_e8) {} }
};

// ---------------------------- Hammer wrappers ----------------------------

function FS_OnMakerSpawned()
{
    local FS2 = getroottable().flagspawn;
    local entSpawn = null;
    try { entSpawn = activator; } catch (_e) {}
    if (entSpawn == null) { try { entSpawn = caller; } catch (_e2) {} }
    if (entSpawn != null && entSpawn.IsValid()) FS2.OnMakerSpawned(entSpawn);
}

function FS_OnSpawnerTouch_Blu()
{
    local FS2 = getroottable().flagspawn;
    local plrEnt = null; try { plrEnt = activator; } catch (_e) {}
    if (plrEnt == null || !plrEnt.IsValid()) return;
    local bluNum = ("TEAM_BLU" in FS2.CFG) ? FS2.CFG.TEAM_BLU : 3;
    FS2.OnSpawnerTouch(bluNum, plrEnt);
}

function FS_OnSpawnerTouch_Red()
{
    local FS2 = getroottable().flagspawn;
    local plrEnt = null; try { plrEnt = activator; } catch (_e) {}
    if (plrEnt == null || !plrEnt.IsValid()) return;
    local redNum = ("TEAM_RED" in FS2.CFG) ? FS2.CFG.TEAM_RED : 2;
    FS2.OnSpawnerTouch(redNum, plrEnt);
}
