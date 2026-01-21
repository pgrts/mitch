local rt = getroottable();
local FS = rt.flagspawn;

FS.V <- "v71";

FS.S <- {
    // pool points (budget bonus pool)
    P = { [2]=0, [3]=0 },

    // active spawner-origin flags (counted)
    A = { [2]=0, [3]=0 },

    // in-flight spawns (maker fired, OnMakerSpawned not yet applied)
    N = { [2]=0, [3]=0 },

    // spawn queue (contexts)
    Q = [],

    // carried totals tracker (your internal; dmg uses it)
    C = {},

    // misc
    T0 = Time(),

    // glow tick registry (flag name -> handle)
    F = {},

    // spw init guard
    SPW_STARTED = false
};

// ---------- tiny helpers ----------
FS.Ok <- function(ent) { return ent != null && ent.IsValid(); };
FS.Cl <- function(x, lo, hi) { if (x < lo) return lo; if (x > hi) return hi; return x; };
FS.Fn <- function(nm) { return Entities.FindByName(null, nm); };
FS.Tok <- function(t) { return t == 2 || t == 3; };
FS.Pid <- function(plr) { return FS.Ok(plr) ? plr.GetEntityIndex() : 0; };

// NEVER GetAbsOrigin() on players
FS.Op <- function(plr) {
    try { return NetProps.GetPropVector(plr, "m_vecAbsOrigin"); } catch(_e) {}
    try { return plr.GetOrigin(); } catch(_e2) {}
    return Vector(0,0,0);
};

FS.Gv <- function(flagEnt) {
    local val = 0;
    try { val = NetProps.GetPropInt(flagEnt, "m_nPointValue"); } catch(_e) {}
    if (val < 0) val = 0;
    return val;
};

// IMPORTANT: fs_meter bodygroup index is 1
FS.Sv <- function(flagEnt, val) {
    try { NetProps.SetPropInt(flagEnt, "m_nPointValue", val); } catch(_e) {}
    try { flagEnt.SetBodygroup(1, val); } catch(_e2) {}
};

// carry tracker
FS.Cg <- function(plr) {
    local pid = FS.Pid(plr);
    return (pid in FS.S.C) ? FS.S.C[pid] : 0;
};
FS.Cs <- function(plr, val) {
    local pid = FS.Pid(plr);
    if (pid <= 0) return;
    if (val <= 0) { if (pid in FS.S.C) delete FS.S.C[pid]; }
    else FS.S.C[pid] <- val;
};

// maker getter
FS.Mk <- function(teamNum, dyn) {
    local nm = dyn ? FS.CFG.MKD[teamNum] : FS.CFG.MKR[teamNum];
    local mk = nm ? FS.Fn(nm) : null;
    if (!FS.Ok(mk) && dyn) {
        nm = FS.CFG.MKR[teamNum];
        mk = nm ? FS.Fn(nm) : null;
    }
    return mk;
};

// remaining slots
FS.Rem <- function(teamNum) {
    local used = FS.S.A[teamNum] + FS.S.N[teamNum];
    local left = FS.CFG.LIM - used;
    return (left < 0) ? 0 : left;
};

// remaining slots text
FS.Utxt <- function(teamNum) {
    local nm = FS.CFG.STX[teamNum];
    if (!nm) return;
    local e = FS.Fn(nm);
    if (!FS.Ok(e)) return;
    EntFireByHandle(e, "AddOutput", "message " + FS.Rem(teamNum), 0.0, null, null);
};

// 3 props show TOTAL pool segmented
FS.Umet <- function(teamNum) {
    local pfx = FS.CFG.MPF[teamNum];
    if (!pfx) return;

    local tot = FS.S.P[teamNum];
    if (tot < 0) tot = 0;
    if (tot > FS.CFG.PCAP) tot = FS.CFG.PCAP;

    for (local idx = 1; idx <= FS.CFG.MC; idx++) {
        local seg = tot - ((idx - 1) * 100);
        if (seg < 0) seg = 0;
        if (seg > 100) seg = 100;

        local entNm = pfx + format("%02d", idx);
        local propEnt = FS.Fn(entNm);
        if (FS.Ok(propEnt)) {
            try { propEnt.SetBodygroup(1, seg); } catch(_e) {}
        }
    }
};

// ghost prop shows ON-DECK payout = floor(pool/5)
FS.Udeck <- function(teamNum) {
    local nm = FS.CFG.ODP[teamNum];
    if (!nm) return;

    local ghostEnt = FS.Fn(nm);
    if (!FS.Ok(ghostEnt)) return;

    local tot = FS.S.P[teamNum];
    if (tot < 0) tot = 0;
    if (tot > FS.CFG.PCAP) tot = FS.CFG.PCAP;

    local divv = FS.CFG.PORTION_DIV;
    if (divv <= 0) divv = 5;

    local deckVal = floor(tot.tofloat() / divv.tofloat());
    deckVal = FS.Cl(deckVal, 0, 100);

    try { ghostEnt.SetBodygroup(1, deckVal); } catch(_e) {}
};

FS.Upool <- function(teamNum) {
    FS.Umet(teamNum);
    FS.Udeck(teamNum);
};

// pool math
FS.AddP <- function(teamNum, amt) {
    if (amt <= 0) return;
    local cur = FS.S.P[teamNum] + amt;
    if (cur > FS.CFG.PCAP) cur = FS.CFG.PCAP;
    FS.S.P[teamNum] <- cur;
    FS.Upool(teamNum);
};
FS.ConsP <- function(teamNum, amt) {
    if (amt <= 0) return;
    local cur = FS.S.P[teamNum] - amt;
    if (cur < 0) cur = 0;
    FS.S.P[teamNum] <- cur;
    FS.Upool(teamNum);
};

// ---------- glow helpers ----------
FS.GlowSetTarget <- function(glowEnt, targetEnt, enableIt) {
    if (!FS.Ok(glowEnt)) return;

    if (FS.Ok(targetEnt)) {
        try { NetProps.SetPropEntity(glowEnt, "m_hTarget", targetEnt); } catch(_e) {}
    }

    EntFireByHandle(glowEnt, enableIt ? "Enable" : "Disable", "", 0.0, null, null);
};

FS.GlowFlashByFlag <- function(flagEnt, targetEnt, dur) {
    if (!FS.Ok(flagEnt)) return;

    local nm = "";
    try { nm = flagEnt.GetName(); } catch(_e0) {}
    if (nm == "") return;

    try { flagEnt.ValidateScriptScope(); } catch(_e1) {}
    local scp = null;
    try { scp = flagEnt.GetScriptScope(); } catch(_e2) {}
    if (scp == null) return;

    // cache glow handle once
    if (!("fs_glow" in scp) || scp.fs_glow == null || !scp.fs_glow.IsValid()) {
        local amp = nm.find("&");
        if (amp == null) return;
        local suf = nm.slice(amp);
        local pref = (nm.len() >= 3 && nm.slice(0,3) == "red") ? "redflag_glow" : "bluflag_glow";
        scp.fs_glow <- Entities.FindByName(null, pref + suf);
    }

    if (!FS.Ok(scp.fs_glow)) return;

    scp.fs_glow_exp <- Time() + dur;
    FS.GlowSetTarget(scp.fs_glow, targetEnt, true);

    // register for expiry ticking
    FS.S.F[nm] <- flagEnt;
};

FS.GlowTick <- function(nowT) {
    local killKeys = [];

    foreach (nm, flagEnt in FS.S.F) {
        if (!FS.Ok(flagEnt)) { killKeys.append(nm); continue; }

        try { flagEnt.ValidateScriptScope(); } catch(_e0) {}
        local scp = null;
        try { scp = flagEnt.GetScriptScope(); } catch(_e1) {}
        if (scp == null) continue;

        if (("fs_glow" in scp) && FS.Ok(scp.fs_glow) && ("fs_glow_exp" in scp) && scp.fs_glow_exp > 0.0) {
            if (nowT >= scp.fs_glow_exp) {
                scp.fs_glow_exp <- 0.0;
                FS.GlowSetTarget(scp.fs_glow, null, false);
            }
        }
    }

    foreach (nm in killKeys) {
        if (nm in FS.S.F) delete FS.S.F[nm];
    }
};

// ---------- init ----------
FS.Init <- function() {
    FS.S.P[2] = 0; FS.S.P[3] = 0;
    FS.S.A[2] = 0; FS.S.A[3] = 0;
    FS.S.N[2] = 0; FS.S.N[3] = 0;
    FS.S.Q.clear();
    FS.S.C.clear();
    FS.S.F.clear();
    FS.S.T0 = Time();

    FS.Upool(2); FS.Upool(3);
    FS.Utxt(2); FS.Utxt(3);

    if (!FS.S.SPW_STARTED && ("SpwStartThink" in FS)) {
        FS.S.SPW_STARTED = true;
        FS.SpwStartThink();
    }
};

