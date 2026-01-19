// flagspawn/core.nut (microservices v7)
// Core state + helpers + Think loop (merge cleanup, bodygroups, prop/flag draw swap, glow fix).

local rt = getroottable();
local FS = rt.flagspawn;

// ------------------------------ State ---------------------------------------
FS.State <- {
    Inited = false,

    Pool = { [2] = 0, [3] = 0 }, // team -> points pool

    // Spawn queue entries:
    // [team, value, poolConsume, originOrNull, src]
    Q = [],

    // suffix -> pkg
    Flags = {},
    // entindex -> suffix (fast lookup)
    ByEnt = {},

    // Per-player gates
    UsedSpawn = {}, // entindex -> bool (once per life)
    DmgAcc = {},    // entindex -> float (damage accumulator)

    // Optional capture bonus tracking
    FirstClaim = {},
    FirstCount = { [2] = 0, [3] = 0 },
    RoundT0 = Time(),

    // Pending "kill PD death-drop point" jobs:
    // { due, org }
    DeathClean = []
};

// ------------------------------ Helpers -------------------------------------
FS.IsValid <- function(ent) {
    try { return (ent != null && ent.IsValid()); } catch (_e) { return false; }
};

FS._TeamOK <- function(t) {
    return (t == FS.CFG.TEAM_RED || t == FS.CFG.TEAM_BLU);
};

FS._ClampI <- function(x, lo, hi) {
    if (x < lo) return lo;
    if (x > hi) return hi;
    return x;
};

FS._Find <- function(name) {
    if (name == null || name == "") return null;
    try { return Entities.FindByName(null, name); } catch (_e) { return null; }
};

FS._TryFire <- function(ent, input, param = "", delay = 0.0, activator = null, caller = null) {
    if (!FS.IsValid(ent)) return;
    try { EntFireByHandle(ent, input, param, delay, activator, caller); } catch (_e) {}
};

FS._TryKill <- function(ent) {
    if (!FS.IsValid(ent)) return;
    FS._TryFire(ent, "Kill", "", 0.0, null, null);
};

FS._EntIndex <- function(ent) {
    if (!FS.IsValid(ent)) return 0;
    try { return ent.entindex(); } catch (_e0) {}
    try { return ent.GetEntityIndex(); } catch (_e1) {}
    return 0;
};

FS._EntName <- function(ent) {
    if (!FS.IsValid(ent)) return "";
    local nm = "";
    try { nm = ent.GetName(); } catch (_e) { nm = ""; }
    return (nm == null) ? "" : nm;
};

FS._StartsWith <- function(s, prefix) {
    if (s == null || prefix == null) return false;
    if (s.len() < prefix.len()) return false;
    return (s.slice(0, prefix.len()) == prefix);
};

FS._SuffixFromName <- function(fullName, baseName) {
    if (fullName == null || baseName == null) return "";
    if (!FS._StartsWith(fullName, baseName)) return "";
    if (fullName.len() <= baseName.len()) return "";
    return fullName.slice(baseName.len());
};

// Hard rule: never call GetAbsOrigin() on players.
FS._Origin <- function(ent) {
    if (!FS.IsValid(ent)) return Vector(0, 0, 0);
    local isPlayer = false;
    try { isPlayer = ent.IsPlayer(); } catch (_e0) { isPlayer = false; }
    if (isPlayer) {
        try { return ent.EyePosition() - Vector(0, 0, 20); } catch (_e1) { return Vector(0, 0, 0); }
    }
    try { return ent.GetOrigin(); } catch (_e2) { return Vector(0, 0, 0); }
};

FS._GetMaxHealth <- function(ply) {
    if (!FS.IsValid(ply)) return 100;
    try { return ply.GetMaxHealth(); } catch (_e) { return 100; }
};

FS._GetPointValue <- function(flag) {
    if (!FS.IsValid(flag)) return 0;
    local v = 0;
    try { v = NetProps.GetPropInt(flag, "m_nPointValue"); } catch (_e) { v = 0; }
    if (v < 0) v = 0;
    return v;
};

FS._SetBody <- function(ent, groupIdx, val) {
    if (!FS.IsValid(ent)) return;
    try { ent.SetBodygroup(groupIdx, val); return; } catch (_e0) {}
    FS._TryFire(ent, "SetBodyGroup", groupIdx.tostring() + " " + val.tostring(), 0.0, null, null);
};

FS._SetPointValue <- function(flag, val) {
    if (!FS.IsValid(flag)) return;
    try { NetProps.SetPropInt(flag, "m_nPointValue", val); } catch (_e) {}
    // Project rule: bodygroup index 1 represents the value on both flag + prop.
    FS._SetBody(flag, 1, val);
};

FS._GetFlagOwner <- function(flag) {
    if (!FS.IsValid(flag)) return null;
    try {
        local o = flag.GetOwner();
        if (FS.IsValid(o)) return o;
    } catch (_e0) {}
    try {
        local o2 = NetProps.GetPropEntity(flag, "m_hOwnerEntity");
        if (FS.IsValid(o2)) return o2;
    } catch (_e1) {}
    return null;
};

// tf_glow target keyvalue is unreliable on templated entities; use netprop m_hTarget.
// We also support duration-based enable/disable (see pkg.glowUntil).
FS._GlowSetTarget <- function(glow, targetEnt, enableWanted) {
    if (!FS.IsValid(glow)) return;

    if (enableWanted) {
        if (FS.IsValid(targetEnt)) {
            try { NetProps.SetPropEntity(glow, "m_hTarget", targetEnt); } catch (_e0) {}
        }
        FS._TryFire(glow, "Enable", "", 0.0, null, null);
    } else {
        FS._TryFire(glow, "Disable", "", 0.0, null, null);
    }
};

FS._PkgFlashGlow <- function(pkg, duration) {
    if (!pkg) return;
    local d = duration;
    if (d <= 0.0) {
        pkg.glowUntil = 0.0;
        FS._PkgApplyVisual(pkg);
        return;
    }
    local until = Time() + d;
    if (until > pkg.glowUntil) pkg.glowUntil = until;

    // Force an immediate visual sync (retarget + enable).
    FS._PkgApplyVisual(pkg);
};

FS._PkgGlowApply <- function(pkg, targetEnt, enableWanted) {
    if (!pkg || !FS.IsValid(pkg.glow)) return;

    local on = (enableWanted && FS.IsValid(targetEnt));
    local tid = on ? FS._EntIndex(targetEnt) : 0;

    local need = false;
    if (on != pkg.glowEnabled) need = true;
    if (on && tid != pkg.glowTargetId) need = true;

    if (!need) return;

    FS._GlowSetTarget(pkg.glow, targetEnt, on);
    pkg.glowEnabled = on;
    pkg.glowTargetId = tid;
};

FS._HideEnt <- function(ent) {
    if (!FS.IsValid(ent)) return;
    FS._TryFire(ent, "DisableDraw", "", 0.0, null, null);
    FS._TryFire(ent, "Disable", "", 0.0, null, null);
};

FS._ShowEnt <- function(ent) {
    if (!FS.IsValid(ent)) return;
    FS._TryFire(ent, "Enable", "", 0.0, null, null);
    FS._TryFire(ent, "EnableDraw", "", 0.0, null, null);
};

// ------------------------------ UI ------------------------------------------
FS._CountSpawnerActive <- function(team) {
    if (!FS._TeamOK(team)) return 0;
    local n = 0;
    foreach (_suf, pkg in FS.State.Flags) {
        if (!pkg) continue;
        if (pkg.team != team) continue;
        if (pkg.src != FS.SRC_SPAWNER) continue;
        if (FS.IsValid(pkg.flag)) n += 1;
    }
    return n;
};

FS._CountSpawnerPending <- function(team) {
    if (!FS._TeamOK(team)) return 0;
    local n = 0;
    foreach (ctx in FS.State.Q) {
        if (ctx.len() < 5) continue;
        if (ctx[0] != team) continue;
        if (ctx[4] != FS.SRC_SPAWNER) continue;
        n += 1;
    }
    return n;
};

FS._StockRemaining <- function(team) {
    local used = FS._CountSpawnerActive(team) + FS._CountSpawnerPending(team);
    local rem = FS.CFG.STOCK_LIMIT - used;
    if (rem < 0) rem = 0;
    return rem;
};

FS._UpdateStockText <- function(team) {
    local nm = FS.CFG.STOCK_TEXT[team];
    if (!nm) return;
    local e = FS._Find(nm);
    if (!FS.IsValid(e)) return;
    FS._TryFire(e, "AddOutput", "message " + FS._StockRemaining(team).tostring(), 0.0, null, null);
};

FS._UpdateLockSprite <- function(team) {
    local nm = FS.CFG.LOCK_SPRITE[team];
    if (!nm) return;
    local spr = FS._Find(nm);
    if (!FS.IsValid(spr)) return;
    if (FS._StockRemaining(team) <= 0) FS._TryFire(spr, "ShowSprite", "", 0.0, null, null);
    else FS._TryFire(spr, "HideSprite", "", 0.0, null, null);
};

FS._UpdateMeter <- function(team) {
    local prefix = FS.CFG.METER_PREFIX[team];
    if (!prefix) return;

    // Spawner props show the "on deck" budget bonus, not the full pool.
    // onDeck = floor(pool / POOL_SHARE_DEN), clamped to 0..(POOL_CAP/POOL_SHARE_DEN), and mirrored to all meter props.
    local pool = FS.State.Pool[team];
    if (pool < 0) pool = 0;
    if (pool > FS.CFG.POOL_CAP) pool = FS.CFG.POOL_CAP;

    local onDeckMax = floor(FS.CFG.POOL_CAP.tofloat() / FS.CFG.POOL_SHARE_DEN.tofloat());
    if (onDeckMax < 0) onDeckMax = 0;
    if (onDeckMax > FS.CFG.VALUE_CAP) onDeckMax = FS.CFG.VALUE_CAP;

    local onDeck = floor(pool.tofloat() / FS.CFG.POOL_SHARE_DEN.tofloat());
    if (onDeck < 0) onDeck = 0;
    if (onDeck > onDeckMax) onDeck = onDeckMax;

    for (local i = 1; i <= FS.CFG.METER_COUNT; i++) {
        local ent = FS._Find(prefix + format("%02d", i));
        if (FS.IsValid(ent)) FS._SetBody(ent, 1, onDeck);
    }
};

FS._UpdateUI <- function() {
    FS._UpdateMeter(FS.CFG.TEAM_RED);
    FS._UpdateMeter(FS.CFG.TEAM_BLU);
    FS._UpdateStockText(FS.CFG.TEAM_RED);
    FS._UpdateStockText(FS.CFG.TEAM_BLU);
    FS._UpdateLockSprite(FS.CFG.TEAM_RED);
    FS._UpdateLockSprite(FS.CFG.TEAM_BLU);
};

FS._AddPool <- function(team, amt) {
    if (!FS._TeamOK(team)) return;
    if (amt <= 0) return;
    local cur = FS.State.Pool[team] + amt;
    if (cur > FS.CFG.POOL_CAP) cur = FS.CFG.POOL_CAP;
    FS.State.Pool[team] <- cur;
};

FS._ConsumePool <- function(team, amt) {
    if (!FS._TeamOK(team)) return;
    if (amt <= 0) return;
    local cur = FS.State.Pool[team] - amt;
    if (cur < 0) cur = 0;
    FS.State.Pool[team] <- cur;
};

// ------------------------------ Flag Tracking --------------------------------
FS._PkgCleanup <- function(pkg) {
    if (!pkg) return;
    if (FS.IsValid(pkg.prop)) FS._TryKill(pkg.prop);
    if (FS.IsValid(pkg.glow)) FS._TryKill(pkg.glow);
    if (FS.IsValid(pkg.lock)) FS._TryKill(pkg.lock);
    if (FS.IsValid(pkg.lmm)) FS._TryKill(pkg.lmm);
    if (FS.IsValid(pkg.lmmRef)) FS._TryKill(pkg.lmmRef);
    if (FS.IsValid(pkg.lmmTarget)) FS._TryKill(pkg.lmmTarget);
};

FS._PkgKillAll <- function(pkg) {
    if (!pkg) return;
    if (FS.IsValid(pkg.flag)) FS._TryKill(pkg.flag);
    FS._PkgCleanup(pkg);
};

FS._PkgSetValue <- function(pkg, val) {
    if (!pkg) return;
    local v = val;
    if (v < 1) v = 1;
    if (v > FS.CFG.VALUE_CAP) v = FS.CFG.VALUE_CAP;
    pkg.pv = v;
    if (FS.IsValid(pkg.flag)) FS._SetBody(pkg.flag, 1, v);
    if (FS.IsValid(pkg.prop)) FS._SetBody(pkg.prop, 1, v);
};

FS._PkgApplyVisual <- function(pkg) {
    if (!pkg || !FS.IsValid(pkg.flag)) return;

    local owner = FS._GetFlagOwner(pkg.flag);
    local isPlayer = false;
    try { isPlayer = (FS.IsValid(owner) && owner.IsPlayer()); } catch (_e0) { isPlayer = false; }

    local now = Time();
    local glowActive = (pkg.glowUntil > 0.0 && now < pkg.glowUntil);

    if (isPlayer) {
        pkg.carrier = owner;
        local oid = FS._EntIndex(owner);

        // Carried: hide flag, show prop on player
        if (!pkg.carried || pkg.carrierId != oid) {
            FS._HideEnt(pkg.flag);

            if (FS.IsValid(pkg.prop)) {
                FS._TryFire(pkg.prop, "ClearParent", "", 0.0, null, null);
                FS._TryFire(pkg.prop, "SetParent", "!activator", 0.0, owner, null);
                FS._TryFire(pkg.prop, "SetParentAttachment", FS.CFG.ATTACH_POINT, 0.02, owner, null);
                FS._ShowEnt(pkg.prop);
            }
        }

        pkg.carried = true;
        pkg.carrierId = oid;

        FS._PkgGlowApply(pkg, owner, glowActive);
    } else {
        pkg.carrier = null;
        pkg.carried = false;
        pkg.carrierId = 0;

        // Dropped: show flag, hide prop (but keep it parented to LMM target if present)
        FS._ShowEnt(pkg.flag);

        if (FS.IsValid(pkg.prop)) {
            if (FS.IsValid(pkg.lmmTarget)) {
                local tnm = FS._EntName(pkg.lmmTarget);
                if (tnm != "") {
                    local mp = null;
                    try { mp = pkg.prop.GetMoveParent(); } catch (_e1) { mp = null; }
                    if (mp != pkg.lmmTarget) {
                        FS._TryFire(pkg.prop, "ClearParent", "", 0.0, null, null);
                        FS._TryFire(pkg.prop, "SetParent", tnm, 0.0, null, null);
                        FS._TryFire(pkg.prop, "SetLocalOrigin", "0 0 0", 0.01, null, null);
                        FS._TryFire(pkg.prop, "SetLocalAngles", "0 0 0", 0.01, null, null);
                    }
                }
            }
            FS._HideEnt(pkg.prop);
        }

        FS._PkgGlowApply(pkg, pkg.flag, glowActive);
    }
};

FS._RegisterFlag <- function(flag, team, src) {
    if (!FS.IsValid(flag)) return null;
    if (!FS._TeamOK(team)) return null;

    local nm = FS._EntName(flag);
    local prefix = FS.CFG.FLAG_BASE[team];
    if (prefix == null || prefix == "") return null;
    if (!FS._StartsWith(nm, prefix)) return null;

    local suf = FS._SuffixFromName(nm, prefix);
    if (suf == "") return null;

    // Avoid double-register
    if (suf in FS.State.Flags) return FS.State.Flags[suf];

    local pkg = {
        suffix = suf,
        team = team,
        src = src,
        flag = flag,
        prop = null,
        glow = null,
        lock = null,
        lmm = null,
        lmmRef = null,
        lmmTarget = null,
        pv = FS._GetPointValue(flag),
        carrier = null,

        // Glow timer + caching (duration-based enable/disable)
        glowUntil = Time() + FS.CFG.GLOW_DURATION_DROP,
        glowEnabled = false,
        glowTargetId = 0,

        // Visual state cache (avoid reparent spam)
        carried = false,
        carrierId = 0
    };

    // Associated entities (best-effort)
    local pb = FS.CFG.PROP_BASE[team];
    if (pb) pkg.prop = FS._Find(pb + suf);

    local gb = FS.CFG.GLOW_BASE[team];
    if (gb) pkg.glow = FS._Find(gb + suf);

    local lb = FS.CFG.LOCK_BASE[team];
    if (lb) pkg.lock = FS._Find(lb + suf);

    local lmmn = FS.CFG.LMM_BASE[team];
    if (lmmn) pkg.lmm = FS._Find(lmmn + suf);

    local lmmr = FS.CFG.LMM_REF_BASE[team];
    if (lmmr) pkg.lmmRef = FS._Find(lmmr + suf);

    local lmmt = FS.CFG.LMM_TARGET_BASE[team];
    if (lmmt) pkg.lmmTarget = FS._Find(lmmt + suf);

    // Store lookups
    FS.State.Flags[suf] <- pkg;
    local idx = FS._EntIndex(flag);
    if (idx > 0) FS.State.ByEnt[idx.tostring()] <- suf;

    // Apply value visuals (bodygroup index 1 on both)
    FS._PkgSetValue(pkg, pkg.pv);

    // Initial drop state (spawn glows for a duration)
    if (FS.IsValid(pkg.prop)) FS._HideEnt(pkg.prop);
    FS._PkgApplyVisual(pkg);
    return pkg;
};

FS._FindPkgByFlag <- function(flag) {
    if (!FS.IsValid(flag)) return null;
    local idx = FS._EntIndex(flag);
    if (idx > 0) {
        local k = idx.tostring();
        if (k in FS.State.ByEnt) {
            local suf = FS.State.ByEnt[k];
            if (suf in FS.State.Flags) return FS.State.Flags[suf];
        }
    }

    // Fallback: parse name and search
    local nm = FS._EntName(flag);
    foreach (team, prefix in FS.CFG.FLAG_BASE) {
        if (!prefix) continue;
        if (!FS._StartsWith(nm, prefix)) continue;
        local suf2 = FS._SuffixFromName(nm, prefix);
        if (suf2 in FS.State.Flags) return FS.State.Flags[suf2];
    }
    return null;
};

// ------------------------------ Maintenance ---------------------------------
FS._PruneDead <- function() {
    local dirty = false;
    foreach (suf, pkg in FS.State.Flags) {
        if (!pkg) { dirty = true; delete FS.State.Flags[suf]; continue; }
        if (!FS.IsValid(pkg.flag)) {
            FS._PkgCleanup(pkg); // merge sink: no refunds
            dirty = true;
            delete FS.State.Flags[suf];
        }
    }
    if (dirty) {
        // Rebuild ByEnt (small table)
        FS.State.ByEnt.clear();
        foreach (suf2, pkg2 in FS.State.Flags) {
            if (!pkg2 || !FS.IsValid(pkg2.flag)) continue;
            local idx = FS._EntIndex(pkg2.flag);
            if (idx > 0) FS.State.ByEnt[idx.tostring()] <- suf2;
        }
    }
    return dirty;
};

FS._ProcessDeathClean <- function() {
    if (FS.State.DeathClean.len() <= 0) return;

    local now = Time();
    for (local i = FS.State.DeathClean.len() - 1; i >= 0; i--) {
        local job = FS.State.DeathClean[i];
        if (!job) { FS.State.DeathClean.remove(i); continue; }
        if (job.due > now) continue;

        // Find 1-point death-drop flags near the origin and kill them, excluding our tracked flags.
        local org = job.org;
        local ent = null;
        while ((ent = Entities.FindByClassnameWithin(ent, "item_teamflag", org, FS.CFG.DEATH_DROP_KILL_RADIUS)) != null) {
            if (!FS.IsValid(ent)) continue;
            if (FS._FindPkgByFlag(ent) != null) continue;

            local owner = FS._GetFlagOwner(ent);
            if (FS.IsValid(owner)) continue; // ignore carried

            local pv = FS._GetPointValue(ent);
            if (pv == FS.CFG.DEATH_DROP_KILL_VALUE) {
                FS._TryKill(ent);
            }
        }

        FS.State.DeathClean.remove(i);
    }
};

FS.Pulse <- function() {
    local pruned = FS._PruneDead();

    // Keep all tracked flags visually correct (value + draw swap + glow target).
    foreach (_suf, pkg in FS.State.Flags) {
        if (!pkg || !FS.IsValid(pkg.flag)) continue;

        local pv = FS._GetPointValue(pkg.flag);
        if (pv != pkg.pv) {
            pkg.pv = pv;
            FS._PkgSetValue(pkg, pv);
        }

        FS._PkgApplyVisual(pkg);
    }

    FS._ProcessDeathClean();

    // UI is cheap; keep it always correct.
    FS._UpdateUI();
    return pruned;
};

FS.Think <- function() {
    FS.Pulse();
    return FS.CFG.THINK_DT;
};

FS._GetThinkEnt <- function() {
    if ("self" in rt) {
        local s = rt.self;
        if (FS.IsValid(s)) return s;
    }
    local sc = FS._Find(FS.CFG.SCRIPTER_NAME);
    if (FS.IsValid(sc)) return sc;
    return null;
};

FS.Init <- function() {
    if (FS.State.Inited) return;
    FS.State.Inited = true;

    // Reset round-time bookkeeping + UI
    FS.State.Pool[FS.CFG.TEAM_RED] = 0;
    FS.State.Pool[FS.CFG.TEAM_BLU] = 0;
    FS.State.Q.clear();
    FS.State.Flags.clear();
    FS.State.ByEnt.clear();
    FS.State.UsedSpawn.clear();
    FS.State.DmgAcc.clear();
    FS.State.FirstClaim.clear();
    FS.State.FirstCount[FS.CFG.TEAM_RED] = 0;
    FS.State.FirstCount[FS.CFG.TEAM_BLU] = 0;
    FS.State.RoundT0 = Time();
    FS.State.DeathClean.clear();

    // Think loop anchor
    local te = FS._GetThinkEnt();
    if (FS.IsValid(te)) {
        local sc = te.GetScriptScope();
        sc.Think <- FS.Think;
        AddThinkToEnt(te, "Think");
    }

    FS._UpdateUI();
};
