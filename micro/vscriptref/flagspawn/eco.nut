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

// If we route through logic_relay, caller will be the relay, not the flag.
// Relay names include the same "&####" suffix, so we can resolve the actual flag by name.
FS.EcoResolveFlag <- function(entMaybe)
{
    if (!FS.Ok(entMaybe)) return null;

    local cls = "";
    try { cls = entMaybe.GetClassname(); } catch (_e0) { cls = ""; }
    if (cls == "item_teamflag") return entMaybe;

    local suf = FS.EcoFlagSuffix(entMaybe);
    if (suf == "") return null;

    // Try both teams (maps often have both templates present)
    local f = Entities.FindByName(null, "bluflag" + suf);
    if (f != null && f.IsValid()) return f;
    f = Entities.FindByName(null, "redflag" + suf);
    if (f != null && f.IsValid()) return f;

    return null;
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
    local prefixName = ("PPF" in FS.CFG && teamNum in FS.CFG.PPF) ? FS.CFG.PPF[teamNum] : ((teamNum == 2) ? "redflag_prop" : "bluflag_prop");
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

    // Update spawner tracking (for carry cap / merge decisions)
    if ("SpwSetCarrier" in FS) FS.SpwSetCarrier(flagEnt, plr);
    if ("SpwSetValue" in FS) FS.SpwSetValue(flagEnt, val);

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

    if ("SpwSetCarrier" in FS) FS.SpwSetCarrier(flagEnt, null);
    if ("SpwSetValue" in FS) FS.SpwSetValue(flagEnt, val);

    // Glow -> flag (dropped)
    if (FS.Ok(glowEnt)) FS.EcoRetargetGlow(glowEnt, flagEnt);

// drop: glow on flag for longer
FS.GlowFlashByFlag(flagEnt, flagEnt, FS.CFG.GLOW_DURATION_DROP);

};

FS.EcoIsSpawnerFlag <- function(flagEnt)
{
    local isSpawner = false;
    try {
        flagEnt.ValidateScriptScope();
        local scp = flagEnt.GetScriptScope();
        if (scp != null && ("fs_spawner" in scp) && scp.fs_spawner == 1) isSpawner = true;
    } catch (_e) {}
    return isSpawner;
};

FS.EcoSpawnerTeam <- function(flagEnt, fallbackTeam)
{
    local t = fallbackTeam;
    try {
        flagEnt.ValidateScriptScope();
        local scp = flagEnt.GetScriptScope();
        if (scp != null && ("fs_team" in scp)) t = scp.fs_team;
    } catch (_e) {}
    return t;
};

FS.EcoRefundAndKill <- function(flagEnt, poolTeamNum, mult)
{
    if (!FS.Ok(flagEnt)) return;

    local val = FS.Gv(flagEnt);
    if (mult < 1) mult = 1;

    // Add to pool (budget bonus pool)
    if (FS.Tok(poolTeamNum)) { FS.AddP(poolTeamNum, val * mult); FS.Umet(poolTeamNum); }

    // Return/Capture should free a spawner slot if this was spawner-origin.
    if (FS.EcoIsSpawnerFlag(flagEnt))
    {
        local spwTeam = FS.EcoSpawnerTeam(flagEnt, poolTeamNum);

        // Free one active slot immediately and untrack so reconcile doesn't double-free
        FS.SpwUntrackFlag(flagEnt);
        if (FS.Tok(spwTeam))
        {
            FS.S.A[spwTeam] = FS.S.A[spwTeam] - 1;
            if (FS.S.A[spwTeam] < 0) FS.S.A[spwTeam] = 0;
            FS.Utxt(spwTeam);
        }
    }

    // Kill the flag so it doesn't "return to base" and keep a slot alive
    try { flagEnt.Kill(); } catch (_e2) {}
};

// Hammer entrypoints:

FS.DirectPickup <- function(flagOrRelay, plr)
{
    local f = FS.EcoResolveFlag(flagOrRelay);
    if (f != null && f.IsValid()) FS.EcoOnPickup(f, plr);
};

FS.DirectDrop <- function(flagOrRelay, plr)
{
    local f = FS.EcoResolveFlag(flagOrRelay);
    if (f != null && f.IsValid()) FS.EcoOnDrop(f, plr);
};

FS.DirectReturn <- function(flagEnt)
{
    local f = FS.EcoResolveFlag(flagEnt);
    if (f == null || !f.IsValid()) return;
    local flagTeam = FS.EcoTeamFromFlag(f);
    FS.EcoRefundAndKill(f, flagTeam, 1);
};

FS.DirectCapture <- function(flagEnt)
{
    local f = FS.EcoResolveFlag(flagEnt);
    if (f == null || !f.IsValid()) return;

    // Capture awards pool to the CAPTURER team if possible; fallback to flag team
    local capTeam = 0;
    if (activator != null && activator.IsValid()) { try { capTeam = activator.GetTeam(); } catch (_e0) { capTeam = 0; } }
    if (!FS.Tok(capTeam)) capTeam = FS.EcoTeamFromFlag(f);

    // Capture adds 3x to economy
    FS.EcoRefundAndKill(f, capTeam, 3);

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
            if ("BT" in FS.S) FS.S.BT[pid] <- 0.0;
            if ("BU" in FS.S) FS.S.BU[pid] <- 0;
        }
    }
};
