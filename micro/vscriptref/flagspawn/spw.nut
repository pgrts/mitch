local rt = getroottable();
local FS = rt.flagspawn;

// ----------------------------------------------------------------------------
// Spawner microservice
//  - Uses EntFireByHandle(maker,"ForceSpawn") (NEVER mk.ForceSpawn())
//  - Per-player use window (90s) + per-player touch lock
//  - Value = floor(pool/5) + (class bonus points * multiplier)
//  - Sets script-scope marker fs_spawner = 1
//  - Tracks spawner-origin flags so MERGE KILLS free a slot (reconcile think)
// ----------------------------------------------------------------------------

if (!("SpwInit" in FS)) FS.SpwInit <- function() {};

FS.SpwInit <- function()
{
    if (!("BU" in FS.S)) FS.S.BU <- {};   // uses in window
    if (!("BT" in FS.S)) FS.S.BT <- {};   // window start time
    if (!("BM" in FS.S)) FS.S.BM <- {};   // multiplier (1 or 3)
    if (!("BE" in FS.S)) FS.S.BE <- {};   // multiplier expiry time
    if (!("TL" in FS.S)) FS.S.TL <- {};   // touch lock until time
    if (!("NX" in FS.S)) FS.S.NX <- {};   // next allowed time per pid (rate limiting)
    if (!("SF" in FS.S)) FS.S.SF <- {};   // suffix -> { h=handle, t=team, v=val, c=carrierEntIndex }
};

FS.SpwGetUseMax <- function(plr)
{
    local cls = 0;
    try { cls = plr.GetPlayerClass(); } catch (_e) {}
    if ("BUDGET_CLASS_MAX" in FS.CFG && (cls in FS.CFG.BUDGET_CLASS_MAX)) return FS.CFG.BUDGET_CLASS_MAX[cls];
    return 1;
};

FS.SpwGetClassBonus <- function(plr)
{
    local cls = 0;
    try { cls = plr.GetPlayerClass(); } catch (_e) {}
    if ("BONUS_CLASS_POINTS" in FS.CFG && (cls in FS.CFG.BONUS_CLASS_POINTS)) return FS.CFG.BONUS_CLASS_POINTS[cls];
    return 0;
};

FS.SpwGetMult <- function(pid)
{
    if (!(pid in FS.S.BM)) return 1;
    if ((pid in FS.S.BE) && Time() > FS.S.BE[pid]) { delete FS.S.BM[pid]; delete FS.S.BE[pid]; return 1; }
    return FS.S.BM[pid];
};

// Window reset is SLIDING from last successful use:
// - If you stop using for WINDOW_RESET_SEC, your BU counter resets to 0.
// - Every successful use sets BT[pid]=now (so it always resets 90s after last use).
FS.SpwResetWindowIfNeeded <- function(pid)
{
    if (!(pid in FS.S.BT)) { FS.S.BT[pid] <- 0.0; FS.S.BU[pid] <- 0; return; }
    local lastUse = FS.S.BT[pid];
    if (lastUse <= 0.0) return;
    if (Time() - lastUse >= FS.CFG.WINDOW_RESET_SEC) { FS.S.BT[pid] <- 0.0; FS.S.BU[pid] <- 0; }
};

FS.SpwTouchLocked <- function(pid)
{
    if (!(pid in FS.S.TL)) return false;
    return Time() < FS.S.TL[pid];
};

FS.SpwLockTouch <- function(pid, dur)
{
    FS.S.TL[pid] <- Time() + dur;
};

FS.SpwUnlockTouch <- function(pid)
{
    if (pid in FS.S.TL) FS.S.TL[pid] <- 0.0;
};

FS.SpwTrackFlag <- function(flagEnt, teamNum, val)
{
    local suf = ("Suf" in FS) ? FS.Suf(flagEnt) : "";
    if (suf == "") return;
    FS.S.SF[suf] <- { h = flagEnt, t = teamNum, v = val, c = 0 };
};

FS.SpwUntrackFlag <- function(flagEnt)
{
    local suf = ("Suf" in FS) ? FS.Suf(flagEnt) : "";
    if (suf == "") return;
    if (suf in FS.S.SF) delete FS.S.SF[suf];
};

FS.SpwSetCarrier <- function(flagEnt, carrierEntOrNull)
{
    local suf = ("Suf" in FS) ? FS.Suf(flagEnt) : "";
    if (suf == "" || !(suf in FS.S.SF)) return;
    local pid = 0;
    if (carrierEntOrNull != null && carrierEntOrNull.IsValid())
    {
        try { pid = carrierEntOrNull.GetEntityIndex(); } catch (_e) { pid = 0; }
    }
    FS.S.SF[suf].c <- pid;
};

FS.SpwSetValue <- function(flagEnt, val)
{
    local suf = ("Suf" in FS) ? FS.Suf(flagEnt) : "";
    if (suf == "" || !(suf in FS.S.SF)) return;
    FS.S.SF[suf].v <- val;
};

FS.SpwCarrySum <- function(pid)
{
    if (pid <= 0) return 0;
    local sum = 0;
    foreach (_suf, rec in FS.S.SF)
    {
        if (!("c" in rec) || rec.c != pid) continue;
        local v = ("v" in rec) ? rec.v : 0;
        if (v > 0) sum += v;
    }
    return sum;
};

FS.SpwCleanupSuffix <- function(teamNum, suf)
{
    if (suf == "") return;

    // common siblings
    local propPfx = ("PPF" in FS.CFG && teamNum in FS.CFG.PPF) ? FS.CFG.PPF[teamNum] : ((teamNum == 2) ? "redflag_prop" : "bluflag_prop");
    local glowPfx = (teamNum == 2) ? "redflag_glow" : "bluflag_glow";
    local lockPfx = ("LOCKPFX" in FS.CFG && teamNum in FS.CFG.LOCKPFX) ? FS.CFG.LOCKPFX[teamNum] : null;
    local lmmPfx  = ("LMMPFX" in FS.CFG && teamNum in FS.CFG.LMMPFX) ? FS.CFG.LMMPFX[teamNum] : null;

    local names = [
        propPfx + suf,
        glowPfx + suf
    ];
    if (lockPfx) names.append(lockPfx + suf);
    if (lmmPfx) names.append(lmmPfx + suf);

    // new relay pattern
    names.append("fs_evt_pickup" + suf);
    names.append("fs_evt_drop" + suf);
    names.append("fs_evt_return" + suf);
    names.append("fs_evt_capture" + suf);

    foreach (_i, nm in names)
    {
        local e = Entities.FindByName(null, nm);
        if (e != null && e.IsValid()) { try { e.Kill(); } catch (_e2) {} }
    }
};

FS.SpwReconcile <- function()
{
    // If a spawner-origin flag vanishes (MERGE KILL), free a slot.
    local dead = [];
    foreach (suf, rec in FS.S.SF)
    {
        local h = ("h" in rec) ? rec.h : null;
        local t = ("t" in rec) ? rec.t : 0;

        if (h == null || !h.IsValid())
        {
            if (FS.Tok(t))
            {
                FS.S.A[t] = FS.S.A[t] - 1;
                if (FS.S.A[t] < 0) FS.S.A[t] = 0;
                FS.Utxt(t);
            }

            // Optional: treat merge-delete as "returned" for economy.
            if (FS.Tok(t) && ("MERGE_REFUND" in FS.CFG) && FS.CFG.MERGE_REFUND == 1)
            {
                local ok = true;
                if (("MERGE_REFUND_DROPPED_ONLY" in FS.CFG) && FS.CFG.MERGE_REFUND_DROPPED_ONLY == 1)
                {
                    if (("c" in rec) && rec.c != 0) ok = false;
                }
                if (ok)
                {
                    local v = ("v" in rec) ? rec.v : 0;
                    if (v > 0) { FS.AddP(t, v); FS.Umet(t); }
                }
            }

            // Cleanup orphaned templated siblings (glow/prop/lock/lmm/relays).
            FS.SpwCleanupSuffix(t, suf);

            dead.append(suf);
            continue;
        }

        // Keep last-known value + carrier for carry cap / merge decisions.
        try { FS.S.SF[suf].v <- FS.Gv(h); } catch (_e3) {}
        local owner = null;
        if ("Owner" in FS) owner = FS.Owner(h);
        local pid = 0;
        if (owner != null && owner.IsValid()) { try { pid = owner.GetEntityIndex(); } catch (_e4) { pid = 0; } }
        FS.S.SF[suf].c <- pid;
    }

    foreach (_j, suf2 in dead)
    {
        if (suf2 in FS.S.SF) delete FS.S.SF[suf2];
    }
};

function FS_SpwThink()
{
    local FS2 = getroottable().flagspawn;
    FS2.SpwReconcile();
    if ("GlowTick" in FS2) { try { FS2.GlowTick(); } catch (_e0) {} }
    return FS2.CFG.SPW_RECONCILE_SEC;
}

FS.SpwStartThink <- function()
{
    local scripterName = ("SCRIPTER_NAME" in FS.CFG) ? FS.CFG.SCRIPTER_NAME : "scripter";
    local ctrl = Entities.FindByName(null, scripterName);
    if (ctrl != null && ctrl.IsValid())
    {
        try { ctrl.ValidateScriptScope(); } catch (_e0) {}
        try {
            local sc = ctrl.GetScriptScope();
            sc.FS_SpwThink <- FS_SpwThink;
        } catch (_e1) {}
        try { AddThinkToEnt(ctrl, "FS_SpwThink"); } catch (_e2) {}
    }
};

// ------------------------ MAIN ENTRY ------------------------

FS.OnSpawnerTouch <- function(teamNum, plr)
{
    FS.SpwInit();

    if (!FS.Tok(teamNum) || !FS.Ok(plr)) return;

    local pid = FS.Pid(plr);
    if (pid <= 0) return;

    if (FS.SpwTouchLocked(pid)) return;

    // Per-player rate limiter (scales by class budget)
    if (pid in FS.S.NX)
    {
        if (Time() < FS.S.NX[pid]) return;
    }

    // Hard spawner slot limit (spawner-only; chunks ignore)
    if (FS.Rem(teamNum) <= 0) return;

    // Reset BU counter if they've been idle for >= WINDOW_RESET_SEC
    FS.SpwResetWindowIfNeeded(pid);

    local used = (pid in FS.S.BU) ? FS.S.BU[pid] : 0;
    local useMax = FS.SpwGetUseMax(plr);
    if (used >= useMax) return;

    // Carry cap enforcement
    local carryNow = FS.SpwCarrySum(pid);
    local carryLeft = FS.CFG.CCAP - carryNow;
    if (carryLeft <= 0) return;

    // Pool portion (20%) — clamp pool to PCAP (you said 300 when using 3 props)
    local poolNow = FS.S.P[teamNum];
    if (poolNow < 0) poolNow = 0;
    if (poolNow > FS.CFG.PCAP) poolNow = FS.CFG.PCAP;

    local divv = ("PORTION_DIV" in FS.CFG) ? FS.CFG.PORTION_DIV : 5;
    if (divv <= 0) divv = 5;
    local portion = floor(poolNow.tofloat() / divv.tofloat());

    // Class bonus points (multiplied)
    local clsBonus = FS.SpwGetClassBonus(plr);
    local mult = FS.SpwGetMult(pid);
    clsBonus = clsBonus * mult;

    local val = portion + clsBonus;

    // Clamp to [1..VCAP] and to carryLeft
    val = FS.Cl(val, 1, FS.CFG.VCAP);
    if (val > carryLeft) val = carryLeft;
    if (val < 1) return;

    local maker = FS.Mk(teamNum, false);
    if (!FS.Ok(maker)) return;

    // consume one "use" from the player's window
    FS.S.BU[pid] <- used + 1;

    // SLIDING window: reset timer to 90s from NOW on each successful use.
    FS.S.BT[pid] <- Time();

    // Set next allowed time (higher budgets pull faster per-flag)
    local base = ("SPW_RATE_BASE_SEC" in FS.CFG) ? FS.CFG.SPW_RATE_BASE_SEC : 0.60;
    if (base < 0.05) base = 0.05;
    local denom = useMax.tofloat();
    if (denom < 1.0) denom = 1.0;
    local interval = base * sqrt(2.0) / sqrt(denom);
    if (interval < 0.05) interval = 0.05;
    FS.S.NX[pid] <- Time() + interval;

    // touch lock so multiple fires in same tick don't queue spam
    FS.SpwLockTouch(pid, FS.CFG.SPW_TOUCHLOCK_SEC);

    // Track in-flight spawn count (spawner-only)
    FS.S.N[teamNum] = FS.S.N[teamNum] + 1;

    // Queue context: [team,val,spend,pid,originOrNull,isSpawner]
    local spend = portion;
    if (("SPEND_CLASS_BONUS_FROM_POOL" in FS.CFG) && FS.CFG.SPEND_CLASS_BONUS_FROM_POOL == 1) spend = val;
    FS.S.Q.append([teamNum, val, spend, pid, null, 1]);

    // Spawn the template
    EntFireByHandle(maker, "ForceSpawn", "", 0.0, null, null);

    FS.Utxt(teamNum);
};

FS.OnMakerSpawned <- function(flagEnt)
{
    FS.SpwInit();

    if (!FS.Ok(flagEnt)) return;
    if (FS.S.Q.len() <= 0) return;

    local ctx = FS.S.Q[0];
    FS.S.Q.remove(0);

    local teamNum = ctx[0];
    local val = ctx[1];
    local spend = ctx[2];
    local pid = ctx[3];
    local org = ctx[4];
    local isSpawner = ctx[5];

    if (!FS.Tok(teamNum)) return;

    // Spend from pool only for spawner-origin flags
    if (isSpawner == 1 && spend > 0) FS.ConsP(teamNum, spend);

    // Set point value + bodygroup (make sure core.nut uses bodygroup index 1!)
    FS.Sv(flagEnt, val);

    // Ensure sibling prop has correct value even before first pickup.
    local suf = ("Suf" in FS) ? FS.Suf(flagEnt) : "";
    if (suf != "")
    {
        local pfx = ("PPF" in FS.CFG && teamNum in FS.CFG.PPF) ? FS.CFG.PPF[teamNum] : ((teamNum == 2) ? "redflag_prop" : "bluflag_prop");
        local prop = Entities.FindByName(null, pfx + suf);
        if (prop != null && prop.IsValid())
        {
            if ("Bg" in FS) FS.Bg(prop, 1, val);
            else { try { prop.SetBodygroup(1, val); } catch (_ePropBg) {} }

            // Default dropped state: prop hidden/disabled until pickup.
            try { EntFireByHandle(prop, "DisableDraw", "", 0.0, null, null); } catch (_ePropHide) {}
            try { EntFireByHandle(prop, "Disable", "", 0.0, null, null); } catch (_ePropDis) {}
        }
    }

    // Place chunk/pinata spawns at requested origin
    if (org != null)
    {
        try { flagEnt.SetOrigin(org); } catch (_eOrg) {}
    }

    // Visual feedback on spawner props: flash the POOL PORTION (on-deck), not total value
    if (isSpawner == 1 && ("METER_FLASH_TAKEN" in FS.CFG) && FS.CFG.METER_FLASH_TAKEN == 1 && ("UmetFlashTaken" in FS))
    {
        local divv = ("PORTION_DIV" in FS.CFG) ? FS.CFG.PORTION_DIV : 5;
        if (divv <= 0) divv = 5;
        local poolBefore = FS.S.P[teamNum] + spend; // approx pre-spend
        local portionShown = floor(poolBefore.tofloat() / divv.tofloat());
        if (portionShown < 0) portionShown = 0;
        if (portionShown > 100) portionShown = 100;
        FS.UmetFlashTaken(teamNum, portionShown);
    }


    // Mark this flag origin (spawner vs chunk) so eco/dmg can behave correctly
    try { flagEnt.ValidateScriptScope(); } catch (_e) {}
    local scp = null;
    try { scp = flagEnt.GetScriptScope(); } catch (_e2) {}
    if (scp != null)
    {
        scp.fs_team <- teamNum;
        if (isSpawner == 1) scp.fs_spawner <- 1;
        else scp.fs_chunk <- 1;
    }

    if (isSpawner == 1)
    {
        // Finish in-flight accounting
        FS.S.N[teamNum] = FS.S.N[teamNum] - 1;
        if (FS.S.N[teamNum] < 0) FS.S.N[teamNum] = 0;

        FS.S.A[teamNum] = FS.S.A[teamNum] + 1;

        // Track for merge-kill slot reclaim + carry cap
        FS.SpwTrackFlag(flagEnt, teamNum, val);
    }

    // Unlock player touch
    if (pid > 0) FS.SpwUnlockTouch(pid);

    FS.Umet(teamNum);
    FS.Utxt(teamNum);
};
