local rt = getroottable();
local FS = rt.flagspawn;

// ----------------------------------------------------------------------------
// Economy + Direct outputs microservice
//  - OnPickup: hide flag (renderamt 0), show prop, glow -> player
//  - OnDrop: show flag, hide prop, glow -> flag
//  - OnReturn: add 1x value to pool, free spawner slot, kill flag
//  - OnCapture: add 3x value to pool, free slot, kill flag
//
// IMPORTANT: Wire Hammer:
//   OnReturn  -> CallScriptFunction FS_Direct_Return
//   OnCapture -> CallScriptFunction FS_Direct_Capture
// ----------------------------------------------------------------------------

FS.EcoFlagSuffix <- function(flagEnt)
{
    local nm = "";
    try { nm = flagEnt.GetName(); } catch (_e) {}
    local pos = nm.find("&");
    if (pos == null) return "";
    return nm.slice(pos);
};

FS.EcoTeamFromFlag <- function(flagEnt)
{
    // Prefer netprop team if it exists, otherwise infer from name prefix
    local t = 0;
    try { t = NetProps.GetPropInt(flagEnt, "m_iTeamNum"); } catch (_e) {}
    if (t == 2 || t == 3) return t;

    local nm = "";
    try { nm = flagEnt.GetName(); } catch (_e2) {}
    if (nm.len() >= 3 && nm.slice(0,3) == "red") return 2;
    return 3;
};

FS.EcoFindPropSibling <- function(teamNum, suffix)
{
    local prefixName = (teamNum == 2) ? "redflag_prop" : "bluflag_prop";
    return Entities.FindByName(null, prefixName + suffix);
};

FS.EcoFindGlowSibling <- function(teamNum, suffix)
{
    local prefixName = (teamNum == 2) ? "redflag_glow" : "bluflag_glow";
    return Entities.FindByName(null, prefixName + suffix);
};

FS.EcoSetHiddenFlag <- function(flagEnt, hideIt)
{
    if (!FS.Ok(flagEnt)) return;

    if (hideIt)
    {
        EntFireByHandle(flagEnt, "AddOutput", "rendermode 10", 0.0, null, null);
        EntFireByHandle(flagEnt, "AddOutput", "renderamt 0", 0.0, null, null);
    }
    else
    {
        EntFireByHandle(flagEnt, "AddOutput", "rendermode 0", 0.0, null, null);
        EntFireByHandle(flagEnt, "AddOutput", "renderamt 255", 0.0, null, null);
    }
};

FS.EcoSetPropEnabled <- function(propEnt, enableIt)
{
    if (!FS.Ok(propEnt)) return;
    EntFireByHandle(propEnt, enableIt ? "Enable" : "Disable", "", 0.0, null, null);
    // prop_dynamic is picky; keep draw state in sync too
    EntFireByHandle(propEnt, enableIt ? "EnableDraw" : "DisableDraw", "", 0.0, null, null);
};

FS.EcoTryAttachPropToPlayer <- function(propEnt, plr)
{
    if (!FS.Ok(propEnt) || !FS.Ok(plr)) return;

    // Parent to player; attachment string can be tuned
    try { propEnt.SetParent(plr, ""); } catch (_e) {}
    try { propEnt.SetParentAttachment("partyhat", true); } catch (_e2) {}
};

FS.EcoTryAttachPropToFollower <- function(propEnt, teamNum, suffix)
{
    if (!FS.Ok(propEnt)) return;

    local followerName = (teamNum == 2) ? "red_lmm_target" : "blu_lmm_target";
    local foll = Entities.FindByName(null, followerName + suffix);
    if (!FS.Ok(foll)) return;

    try { propEnt.SetParent(foll, ""); } catch (_e) {}
};

FS.EcoRetargetGlow <- function(glowEnt, targetEnt)
{
    if (!FS.Ok(glowEnt) || !FS.Ok(targetEnt)) return;
    try { NetProps.SetPropEntity(glowEnt, "m_hTarget", targetEnt); } catch (_e) {}
};

FS.EcoApplyValueToSiblings <- function(flagEnt, teamNum, suffix, val)
{
    // Flag bodygroup/value already done in FS.Sv, but we retry here for stickiness.
    if ("Bg" in FS) FS.Bg(flagEnt, 1, val);
    else { try { flagEnt.SetBodygroup(1, val); } catch (_e) {} }

    local propEnt = FS.EcoFindPropSibling(teamNum, suffix);
    if (FS.Ok(propEnt))
    {
        if ("Bg" in FS) FS.Bg(propEnt, 1, val);
        else { try { propEnt.SetBodygroup(1, val); } catch (_e2) {} }
    }
};

FS.EcoOnPickup <- function(flagEnt, plr)
{
    if (!FS.Ok(flagEnt) || !FS.Ok(plr)) return;

    local teamNum = FS.EcoTeamFromFlag(flagEnt);
    local suffix = FS.EcoFlagSuffix(flagEnt);
    local val = FS.Gv(flagEnt);

    local propEnt = FS.EcoFindPropSibling(teamNum, suffix);
    local glowEnt = FS.EcoFindGlowSibling(teamNum, suffix);

    // Hide flag, show prop
    FS.EcoSetHiddenFlag(flagEnt, true);

    if (FS.Ok(propEnt))
    {
        FS.EcoTryAttachPropToPlayer(propEnt, plr);
        FS.EcoSetPropEnabled(propEnt, true);
    }

    // Ensure visuals match value
    FS.EcoApplyValueToSiblings(flagEnt, teamNum, suffix, val);

    // Glow -> player
    if (FS.Ok(glowEnt)) FS.EcoRetargetGlow(glowEnt, plr);
	// pickup: glow briefly on player
FS.GlowFlashByFlag(flagEnt, plr, FS.CFG.GLOW_DURATION_PICKUP);


};

FS.EcoOnDrop <- function(flagEnt, plr)
{
    if (!FS.Ok(flagEnt)) return;

    local teamNum = FS.EcoTeamFromFlag(flagEnt);
    local suffix = FS.EcoFlagSuffix(flagEnt);
    local val = FS.Gv(flagEnt);

    local propEnt = FS.EcoFindPropSibling(teamNum, suffix);
    local glowEnt = FS.EcoFindGlowSibling(teamNum, suffix);

    // Show flag, hide prop
    FS.EcoSetHiddenFlag(flagEnt, false);

    if (FS.Ok(propEnt))
    {
        // Put prop back onto follower (optional)
        FS.EcoTryAttachPropToFollower(propEnt, teamNum, suffix);
        FS.EcoSetPropEnabled(propEnt, false);
    }

    FS.EcoApplyValueToSiblings(flagEnt, teamNum, suffix, val);

    // Glow -> flag (dropped)
    if (FS.Ok(glowEnt)) FS.EcoRetargetGlow(glowEnt, flagEnt);

// drop: glow on flag for longer
FS.GlowFlashByFlag(flagEnt, flagEnt, FS.CFG.GLOW_DURATION_DROP);

};

FS.EcoRefundAndKill <- function(flagEnt, mult)
{
    if (!FS.Ok(flagEnt)) return;

    local teamNum = FS.EcoTeamFromFlag(flagEnt);
    local val = FS.Gv(flagEnt);

    // Return/Capture should free a spawner slot if this was spawner-origin.
    local isSpawner = false;
    try {
        flagEnt.ValidateScriptScope();
        local scp = flagEnt.GetScriptScope();
        if (scp != null && ("fs_spawner" in scp) && scp.fs_spawner == 1) isSpawner = true;
    } catch (_e) {}

    if (mult < 1) mult = 1;

    // Add to pool (budget bonus pool)
    FS.AddP(teamNum, val * mult);
    FS.Umet(teamNum);

    if (isSpawner)
    {
        // Free one active slot immediately and untrack so reconcile doesn't double-free
        FS.SpwUntrackFlag(flagEnt);
        FS.S.A[teamNum] = FS.S.A[teamNum] - 1;
        if (FS.S.A[teamNum] < 0) FS.S.A[teamNum] = 0;
        FS.Utxt(teamNum);
    }

    // Kill the flag so it doesn't "return to base" and keep a slot alive
    try { flagEnt.Kill(); } catch (_e2) {}
};

// Hammer entrypoints:

FS.DirectPickup <- function(flagEnt, plr) { FS.EcoOnPickup(flagEnt, plr); };
FS.DirectDrop <- function(flagEnt, plr) { FS.EcoOnDrop(flagEnt, plr); };

FS.DirectReturn <- function(flagEnt)
{
    FS.EcoRefundAndKill(flagEnt, 1);
};

FS.DirectCapture <- function(flagEnt)
{
    // NEW CHANGE: capture adds 3x to economy
    FS.EcoRefundAndKill(flagEnt, 3);

    // Optional: give the capturing player a 3x class bonus window for 90s
    // (only if activator exists)
    if (activator != null && activator.IsValid())
    {
        local pid = 0;
        try { pid = activator.GetEntityIndex(); } catch (_e) {}
        if (pid > 0)
        {
            if (!("BM" in FS.S)) FS.S.BM <- {};
            if (!("BE" in FS.S)) FS.S.BE <- {};
            FS.S.BM[pid] <- 3;
            FS.S.BE[pid] <- Time() + FS.CFG.WINDOW_RESET_SEC;

            // Reset use window on capture (so they can pull again)
            if ("BT" in FS.S) FS.S.BT[pid] <- Time();
            if ("BU" in FS.S) FS.S.BU[pid] <- 0;
        }
    }
};
