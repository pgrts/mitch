// ============================================================
// flagspawn.nut — Flagspawn (PD-HUD-ready core)
// - Uses real item_teamflag so dropitem works.
// - Never returns flags (ReturnTime = -1 + ignores returns).
// - No VMF marker dependencies: builds its own glow/rock/hint pools.
// - Spawner props (prop_dynamic) must exist: redflag + bluflag
// - Triggers should call:
//    ::flagspawn.OnSpawnerTouch(activator, 2)   // RED spawner trigger
//    ::flagspawn.OnSpawnerTouch(activator, 3)   // BLU spawner trigger
//    ::flagspawn.OnCaptureTouch(activator, 2)   // RED bank trigger
//    ::flagspawn.OnCaptureTouch(activator, 3)   // BLU bank trigger
// ============================================================

// ---- ROOT TABLE SETUP (MUST BE FIRST) ----
local rt = getroottable();
if (!("flagspawn" in rt)) rt["flagspawn"] <- {};
::flagspawn <- rt["flagspawn"];

printl("[flagspawn] LOADED @ t=" + Time());

// ============================================================
// CONFIG
// ============================================================
::flagspawn.DEBUG <- true;

// teams
::flagspawn.TEAM_RED <- 2;
::flagspawn.TEAM_BLU <- 3;

// pooling / limits
::flagspawn.MAX_FLAGS_PER_TEAM <- 25;          // pooled item_teamflag per team
::flagspawn.MAX_STACK_VALUE <- 10;             // cap for stacking (can overshoot only on class grant if you enable it)
::flagspawn.ALLOW_OVERSHOOT_FROM_CLASS_GRANT <- true;

// per-life rule
::flagspawn.ONE_SPAWN_PER_LIFE <- true;

// class bonus values (TFClass enum in TF2 is 1..9)
::flagspawn.CLASS_BONUS <- {
    // scout=1, sniper=2, soldier=3, demoman=4, medic=5, heavy=6, pyro=7, spy=8, engineer=9
    [1] = 1,
    [2] = 3,  // sniper
    [3] = 2,  // soldier
    [4] = 1,
    [5] = 1,
    [6] = 5,  // heavy
    [7] = 2,  // pyro
    [8] = 1,
    [9] = 1
};

// visuals
::flagspawn.ENABLE_GLOW <- true;               // glow_outline_effect pool
::flagspawn.ENABLE_ROCK_PROP <- true;          // side prop (rock005.mdl)
::flagspawn.ROCK_MODEL <- "models/props_desert/rock005.mdl";
::flagspawn.ROCK_SCALE <- 0.5;
::flagspawn.ROCK_OFFSET <- Vector(18, 0, -8); // relative to flag origin
::flagspawn.SPAWNER_SHOW_VALUE_ZERO <- true;   // show "0" at spawner rocks

// value indicators (through walls): env_instructor_hint
::flagspawn.ENABLE_VALUE_HINTS <- true;
::flagspawn.HINT_RANGE <- 0;                   // 0 = unlimited
::flagspawn.HINT_FORCE_CAPTION <- true;        // show even if player has hints off? (best-effort)

// sounds
::flagspawn.PICKUP_SOUND <- "items/itembk2.wav";

// ============================================================
// INTERNAL STATE
// ============================================================
::flagspawn._inited <- false;
::flagspawn._registered <- false;

// pools
::flagspawn._flagPool <- { [2] = [], [3] = [] };      // arrays of item_teamflag
::flagspawn._flagInUse <- {};                         // entidx -> true
::flagspawn._flagInfo <- {};                          // entidx -> {team, value, classGrant, rockEnt, hintEnt, glowFlag, glowRock}

// rock + hint pools (per team, same size as flag pool)
::flagspawn._rockPool <- { [2] = [], [3] = [] };
::flagspawn._hintPool <- { [2] = [], [3] = [] };
::flagspawn._glowPool <- { [2] = [], [3] = [] };      // glow_outline_effect entities (generic, retargeted)

// spawner props
::flagspawn._spawnerProp <- { [2] = null, [3] = null };
::flagspawn._spawnerRock <- { [2] = null, [3] = null };
::flagspawn._spawnerHint <- { [2] = null, [3] = null };
::flagspawn._spawnerGlow <- { [2] = null, [3] = null };
::flagspawn._spawnerRockGlow <- { [2] = null, [3] = null };

// player state
::flagspawn._ps <- {}; // userid -> { spawnedThisLife, carryingEntIdx, carryingValue, lastTouchTime }

// ============================================================
// UTILS (TF2-safe: DO NOT call ent.IsValid())
// ============================================================
::flagspawn.Log <- function(msg) { printl("[flagspawn] " + msg); }

::flagspawn.Now <- function() { return Time(); }

::flagspawn.GetUserId <- function(player) {
    if (!player) return -1;
    try { return player.GetUserID(); } catch(e) { return -1; }
}

::flagspawn.PlayerState <- function(player) {
    local uid = ::flagspawn.GetUserId(player);
    if (uid < 0) return null;
    if (!(uid in ::flagspawn._ps)) {
        ::flagspawn._ps[uid] <- { spawnedThisLife = false, carryingEntIdx = -1, carryingValue = 0, lastTouchTime = 0.0 };
    }
    return ::flagspawn._ps[uid];
}

::flagspawn.SetTargetName <- function(ent, name) {
    if (!ent) return;
    try { ent.__KeyValueFromString("targetname", name); } catch(e) {}
}

::flagspawn.SetParent <- function(child, parent) {
    if (!child) return;
    if (!parent) { child.AcceptInput("ClearParent", "", null, null); return; }
    child.AcceptInput("SetParent", "!activator", parent, parent);
}

::flagspawn.GetTeamName <- function(t) {
    return (t == ::flagspawn.TEAM_RED) ? "red" : "blu";
}

::flagspawn.OtherTeam <- function(t) {
    return (t == ::flagspawn.TEAM_RED) ? ::flagspawn.TEAM_BLU : ::flagspawn.TEAM_RED;
}

::flagspawn.TeamFromCallerOrInt <- function(teamOrCaller) {
    // If VMF passes an int, great.
    if (typeof teamOrCaller == "integer") return teamOrCaller;
    // If VMF passes caller entity, infer from targetname.
    if (teamOrCaller) {
        local nm = "";
        try { nm = teamOrCaller.GetName(); } catch(e) { nm = ""; }
        nm = nm.tolower();
        if (nm.find("blu") != null) return ::flagspawn.TEAM_BLU;
        if (nm.find("red") != null) return ::flagspawn.TEAM_RED;
    }
    return 0;
}

::flagspawn.GetClassBonus <- function(player) {
    if (!player) return 1;
    local c = 1;
    try { c = player.GetPlayerClass(); } catch(e) { c = 1; }
    if (c in ::flagspawn.CLASS_BONUS) return ::flagspawn.CLASS_BONUS[c];
    return 1;
}

::flagspawn.FindByNameAny <- function(names) {
    foreach (nm in names) {
        local e = Entities.FindByName(null, nm);
        if (e) return e;
    }
    return null;
}

::flagspawn.PlaySoundToAll <- function(sample) {
    if (!sample || sample.len() == 0) return;
    local w = Entities.FindByClassname(null, "worldspawn");
    if (!w) return;
    w.EmitSound(sample);
}

// ============================================================
// ENTITY CREATION HELPERS
// ============================================================
::flagspawn._CreateFlag <- function(team, i) {
    local flag = Entities.CreateByClassname("item_teamflag");
    if (!flag) return null;

    // Place it far away and disable.
    flag.SetAbsOrigin(Vector(0,0,-10000));

    // keyvalues
    flag.__KeyValueFromInt("TeamNum", team);
    flag.__KeyValueFromInt("ReturnTime", -1); // never return
    // NOTE: "flag_model" / "FlagType" etc vary by build; leave default.

    local nm = "fs_flag_" + ::flagspawn.GetTeamName(team) + "_" + format("%02d", i);
    ::flagspawn.SetTargetName(flag, nm);

    // keep disabled until checked out
    flag.AcceptInput("Disable", "", null, null);
    flag.AcceptInput("HideSprite", "", null, null);

    return flag;
}

::flagspawn._CreateRock <- function(team, i) {
    local rock = Entities.CreateByClassname("prop_dynamic_override");
    if (!rock) return null;

    rock.__KeyValueFromString("model", ::flagspawn.ROCK_MODEL);
    rock.__KeyValueFromInt("solid", 0);
    rock.SetAbsOrigin(Vector(0,0,-10000));
    rock.SetAbsAngles(QAngle(0,0,0));
    ::flagspawn.SetTargetName(rock, "fs_rock_" + ::flagspawn.GetTeamName(team) + "_" + format("%02d", i));

    // scale
    try { rock.__KeyValueFromFloat("modelscale", ::flagspawn.ROCK_SCALE); } catch(e) {}

    rock.AcceptInput("Disable", "", null, null);
    rock.AcceptInput("DisableCollision", "", null, null);
    return rock;
}

::flagspawn._CreateHint <- function(team, i) {
    local hint = Entities.CreateByClassname("env_instructor_hint");
    if (!hint) return null;

    // Basic hint setup. We re-target and update caption on the fly.
    ::flagspawn.SetTargetName(hint, "fs_hint_" + ::flagspawn.GetTeamName(team) + "_" + format("%02d", i));

    hint.__KeyValueFromInt("hint_timeout", 0); // persistent
    hint.__KeyValueFromInt("hint_range", ::flagspawn.HINT_RANGE);
    hint.__KeyValueFromInt("hint_static", 1);
    hint.__KeyValueFromInt("hint_icon_onscreen", 0);
    hint.__KeyValueFromInt("hint_icon_offscreen", 0);
    hint.__KeyValueFromInt("hint_forcecaption", ::flagspawn.HINT_FORCE_CAPTION ? 1 : 0);
    hint.__KeyValueFromInt("hint_nooffscreen", 0);

    // disable until used
    hint.AcceptInput("EndHint", "", null, null);
    return hint;
}

::flagspawn._CreateGlow <- function(team, i) {
    local g = Entities.CreateByClassname("glow_outline_effect");
    if (!g) return null;

    ::flagspawn.SetTargetName(g, "fs_glow_" + ::flagspawn.GetTeamName(team) + "_" + format("%02d", i));
    // team-based color is controlled by engine / effect; we just enable.
    g.AcceptInput("Disable", "", null, null);
    return g;
}

// Retarget glow to an entity by naming the entity and setting glow's targetname kv.
::flagspawn._BindGlow <- function(glow, targetEnt) {
    if (!glow) return;
    if (!targetEnt) { glow.AcceptInput("Disable", "", null, null); return; }

    // Ensure target has a name.
    local tn = "";
    try { tn = targetEnt.GetName(); } catch(e) { tn = ""; }
    if (!tn || tn.len() == 0) {
        tn = "fs_dyn_" + targetEnt.entindex();
        ::flagspawn.SetTargetName(targetEnt, tn);
    }

    // glow_outline_effect uses "target" keyvalue to point at a named entity.
    try { glow.__KeyValueFromString("target", tn); } catch(e) {}

    glow.AcceptInput("Enable", "", null, null);
}

::flagspawn._ShowHint <- function(hint, targetEnt, caption, team) {
    if (!hint || !targetEnt) return;
    local tn = "";
    try { tn = targetEnt.GetName(); } catch(e) { tn = ""; }
    if (!tn || tn.len() == 0) {
        tn = "fs_hint_target_" + targetEnt.entindex();
        ::flagspawn.SetTargetName(targetEnt, tn);
    }

    try { hint.__KeyValueFromString("hint_target", tn); } catch(e) {}
    try { hint.__KeyValueFromString("hint_caption", caption.tostring()); } catch(e) {}

    // Show to everyone by default; if you want team-only, we can extend later.
    hint.AcceptInput("ShowHint", "", null, null);
}

::flagspawn._HideHint <- function(hint) {
    if (!hint) return;
    hint.AcceptInput("EndHint", "", null, null);
}

// ============================================================
// POOL SETUP
// ============================================================
::flagspawn._BuildPools <- function() {
    foreach (t in [::flagspawn.TEAM_RED, ::flagspawn.TEAM_BLU]) {
        ::flagspawn._flagPool[t].clear();
        ::flagspawn._rockPool[t].clear();
        ::flagspawn._hintPool[t].clear();
        ::flagspawn._glowPool[t].clear();

        for (local i = 1; i <= ::flagspawn.MAX_FLAGS_PER_TEAM; i++) {
            local f = ::flagspawn._CreateFlag(t, i);
            if (f) ::flagspawn._flagPool[t].append(f);

            if (::flagspawn.ENABLE_ROCK_PROP) {
                local r = ::flagspawn._CreateRock(t, i);
                if (r) ::flagspawn._rockPool[t].append(r);
            }

            if (::flagspawn.ENABLE_VALUE_HINTS) {
                local h = ::flagspawn._CreateHint(t, i);
                if (h) ::flagspawn._hintPool[t].append(h);
            }

            if (::flagspawn.ENABLE_GLOW) {
                // We use one glow per dropped-flag "bundle" and reuse it for both flag/rock via two glows:
                // For simplicity: create 2 glows per index (flag + rock).
                local g1 = ::flagspawn._CreateGlow(t, i*2-1);
                local g2 = ::flagspawn._CreateGlow(t, i*2);
                if (g1) ::flagspawn._glowPool[t].append(g1);
                if (g2) ::flagspawn._glowPool[t].append(g2);
            }
        }

        ::flagspawn.Log("Pools ready: team=" + ::flagspawn.GetTeamName(t) +
            " flags=" + ::flagspawn._flagPool[t].len() +
            " rocks=" + ::flagspawn._rockPool[t].len() +
            " hints=" + ::flagspawn._hintPool[t].len() +
            " glows=" + ::flagspawn._glowPool[t].len());
    }
}

// checkout helpers
::flagspawn._CheckoutFromPool <- function(team) {
    // find first flag not in use
    foreach (flag in ::flagspawn._flagPool[team]) {
        if (!flag) continue;
        local idx = flag.entindex();
        if (!(idx in ::flagspawn._flagInUse)) {
            ::flagspawn._flagInUse[idx] <- true;
            return flag;
        }
    }
    return null;
}

::flagspawn._ReturnToPool <- function(flag) {
    if (!flag) return;
    local idx = flag.entindex();
    if (idx in ::flagspawn._flagInUse) delete ::flagspawn._flagInUse[idx];
    if (idx in ::flagspawn._flagInfo) {
        // cleanup visuals
        local info = ::flagspawn._flagInfo[idx];
        if ("glowFlag" in info && info.glowFlag) ::flagspawn._BindGlow(info.glowFlag, null);
        if ("glowRock" in info && info.glowRock) ::flagspawn._BindGlow(info.glowRock, null);
        if ("hintEnt" in info && info.hintEnt) ::flagspawn._HideHint(info.hintEnt);
        if ("rockEnt" in info && info.rockEnt) {
            info.rockEnt.AcceptInput("Disable", "", null, null);
            info.rockEnt.SetAbsOrigin(Vector(0,0,-10000));
            ::flagspawn.SetParent(info.rockEnt, null);
        }
        delete ::flagspawn._flagInfo[idx];
    }

    // hide flag
    flag.AcceptInput("Disable", "", null, null);
    flag.AcceptInput("HideSprite", "", null, null);
    flag.SetAbsOrigin(Vector(0,0,-10000));
}

// ============================================================
// SPAWNER VISUALS (flagspawner value 0)
// ============================================================
::flagspawn._SetupSpawnerVisuals <- function() {
    // Accept common aliases.
    local red = ::flagspawn.FindByNameAny(["redflag","redcase","fs_spawner_red"]);
    local blu = ::flagspawn.FindByNameAny(["bluflag","blucase","fs_spawner_blu"]);

    ::flagspawn._spawnerProp[::flagspawn.TEAM_RED] <- red;
    ::flagspawn._spawnerProp[::flagspawn.TEAM_BLU] <- blu;

    ::flagspawn.Log("Spawner props: red=" + (red ? "OK" : "missing") + " blu=" + (blu ? "OK" : "missing"));

    if (!::flagspawn.ENABLE_ROCK_PROP) return;

    foreach (t in [::flagspawn.TEAM_RED, ::flagspawn.TEAM_BLU]) {
        local sp = ::flagspawn._spawnerProp[t];
        if (!sp) continue;

        // Create a dedicated rock (not from pool) for spawner area.
        local rock = Entities.CreateByClassname("prop_dynamic_override");
        if (!rock) continue;

        rock.__KeyValueFromString("model", ::flagspawn.ROCK_MODEL);
        rock.__KeyValueFromInt("solid", 0);
        try { rock.__KeyValueFromFloat("modelscale", ::flagspawn.ROCK_SCALE); } catch(e) {}
        ::flagspawn.SetTargetName(rock, "fs_spawner_rock_" + ::flagspawn.GetTeamName(t));
        rock.AcceptInput("DisableCollision", "", null, null);

        // position near spawner
        local org = sp.GetOrigin();
        rock.SetAbsOrigin(org + ::flagspawn.ROCK_OFFSET);
        rock.SetAbsAngles(sp.GetAbsAngles());
        rock.AcceptInput("Enable", "", null, null);

        ::flagspawn._spawnerRock[t] <- rock;

        // Value hint "0"
        if (::flagspawn.ENABLE_VALUE_HINTS && ::flagspawn.SPAWNER_SHOW_VALUE_ZERO) {
            local hint = Entities.CreateByClassname("env_instructor_hint");
            if (hint) {
                ::flagspawn.SetTargetName(hint, "fs_spawner_hint_" + ::flagspawn.GetTeamName(t));
                hint.__KeyValueFromInt("hint_timeout", 0);
                hint.__KeyValueFromInt("hint_range", ::flagspawn.HINT_RANGE);
                hint.__KeyValueFromInt("hint_static", 1);
                hint.__KeyValueFromInt("hint_icon_onscreen", 0);
                hint.__KeyValueFromInt("hint_icon_offscreen", 0);
                hint.__KeyValueFromInt("hint_forcecaption", ::flagspawn.HINT_FORCE_CAPTION ? 1 : 0);
                hint.__KeyValueFromInt("hint_nooffscreen", 0);

                ::flagspawn._spawnerHint[t] <- hint;
                ::flagspawn._ShowHint(hint, rock, "0", t);
            }
        }

        // Glows
        if (::flagspawn.ENABLE_GLOW) {
            local gFlag = Entities.CreateByClassname("glow_outline_effect");
            local gRock = Entities.CreateByClassname("glow_outline_effect");
            if (gFlag) { ::flagspawn.SetTargetName(gFlag, "fs_spawner_glow_flag_" + ::flagspawn.GetTeamName(t)); ::flagspawn._spawnerGlow[t] <- gFlag; }
            if (gRock) { ::flagspawn.SetTargetName(gRock, "fs_spawner_glow_rock_" + ::flagspawn.GetTeamName(t)); ::flagspawn._spawnerRockGlow[t] <- gRock; }
            if (gFlag) ::flagspawn._BindGlow(gFlag, sp);
            if (gRock) ::flagspawn._BindGlow(gRock, rock);
        }
    }
}

// ============================================================
// FLAG RESOLUTION + VALUE
// ============================================================
::flagspawn._ResolveCarriedOrNearbyFlag <- function(player) {
    if (!player) return null;

    // 1) Prefer a flag we know is owned by this player
    foreach (idx, info in ::flagspawn._flagInfo) {
        local f = EntIndexToHScript(idx);
        if (!f) continue;
        local owner = null;
        try { owner = NetProps.GetPropEntity(f, "m_hOwnerEntity"); } catch(e) { owner = null; }
        if (owner == player) return f;
    }

    // 2) Search nearby our known flags
    local p = player.GetOrigin();
    local best = null;
    local bestD2 = 99999999.0;

    foreach (idx, info in ::flagspawn._flagInfo) {
        local f = EntIndexToHScript(idx);
        if (!f) continue;
        local o = f.GetOrigin();
        local d2 = (o - p).LengthSqr();
        if (d2 < bestD2 && d2 <= (160*160)) { best = f; bestD2 = d2; }
    }
    return best;
}

::flagspawn._GetFlagValue <- function(flag) {
    if (!flag) return 0;
    local idx = flag.entindex();
    if (idx in ::flagspawn._flagInfo) return ::flagspawn._flagInfo[idx].value;
    return 0;
}

::flagspawn._SetFlagValue <- function(flag, v) {
    if (!flag) return;
    local idx = flag.entindex();
    if (!(idx in ::flagspawn._flagInfo)) return;
    ::flagspawn._flagInfo[idx].value = v;
    // update hint if any
    local info = ::flagspawn._flagInfo[idx];
    if ("hintEnt" in info && info.hintEnt && "rockEnt" in info && info.rockEnt) {
        ::flagspawn._ShowHint(info.hintEnt, info.rockEnt, v.tostring(), info.team);
    }
}

::flagspawn._ApplyDroppedVisuals <- function(flag) {
    if (!flag) return;
    local idx = flag.entindex();
    if (!(idx in ::flagspawn._flagInfo)) return;

    local info = ::flagspawn._flagInfo[idx];
    local team = info.team;

    // rock
    if (::flagspawn.ENABLE_ROCK_PROP && ("rockEnt" in info) && info.rockEnt) {
        local rock = info.rockEnt;
        // position + parent to flag while dropped
        rock.SetAbsOrigin(flag.GetOrigin() + ::flagspawn.ROCK_OFFSET);
        rock.SetAbsAngles(flag.GetAbsAngles());
        ::flagspawn.SetParent(rock, flag);
        rock.AcceptInput("Enable", "", null, null);
    }

    // hint
    if (::flagspawn.ENABLE_VALUE_HINTS && ("hintEnt" in info) && info.hintEnt && ("rockEnt" in info) && info.rockEnt) {
        ::flagspawn._ShowHint(info.hintEnt, info.rockEnt, info.value.tostring(), team);
    }

    // glow bindings
    if (::flagspawn.ENABLE_GLOW) {
        if ("glowFlag" in info && info.glowFlag) ::flagspawn._BindGlow(info.glowFlag, flag);
        if ("glowRock" in info && info.glowRock && ("rockEnt" in info) && info.rockEnt) ::flagspawn._BindGlow(info.glowRock, info.rockEnt);
    }
}

::flagspawn._ClearDroppedVisuals <- function(flag) {
    if (!flag) return;
    local idx = flag.entindex();
    if (!(idx in ::flagspawn._flagInfo)) return;

    local info = ::flagspawn._flagInfo[idx];

    if ("rockEnt" in info && info.rockEnt) {
        ::flagspawn.SetParent(info.rockEnt, null);
        info.rockEnt.AcceptInput("Disable", "", null, null);
        info.rockEnt.SetAbsOrigin(Vector(0,0,-10000));
    }

    if ("hintEnt" in info && info.hintEnt) {
        ::flagspawn._HideHint(info.hintEnt);
    }

    if (::flagspawn.ENABLE_GLOW) {
        if ("glowFlag" in info && info.glowFlag) ::flagspawn._BindGlow(info.glowFlag, null);
        if ("glowRock" in info && info.glowRock) ::flagspawn._BindGlow(info.glowRock, null);
    }
}

// ============================================================
// GAME LOGIC
// ============================================================
::flagspawn.ResetAll <- function() {
    ::flagspawn.Log("ResetAll: clearing players + returning pooled flags");

    // reset player state
    foreach (uid, ps in ::flagspawn._ps) {
        ps.spawnedThisLife = false;
        ps.carryingEntIdx = -1;
        ps.carryingValue = 0;
        ps.lastTouchTime = 0.0;
    }

    // return all flags
    foreach (idx, _ in clone ::flagspawn._flagInUse) {
        local f = EntIndexToHScript(idx);
        if (f) ::flagspawn._ReturnToPool(f);
        else delete ::flagspawn._flagInUse[idx];
    }

    ::flagspawn.Log("ResetAll complete.");
}

::flagspawn._GrantFlagToPlayer <- function(player, team) {
    if (!player) return;

    // per-life gate
    local ps = ::flagspawn.PlayerState(player);
    if (!ps) return;

    if (::flagspawn.ONE_SPAWN_PER_LIFE && ps.spawnedThisLife) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("DENY: one spawn per life already used");
        return;
    }

    // compute class bonus
    local val = ::flagspawn.GetClassBonus(player);

    // if already carrying one of our flags, do stacking instead of creating new
    local carriedFlag = ::flagspawn._ResolveCarriedOrNearbyFlag(player);
    if (carriedFlag) {
        // stack onto current carried
        local cur = ::flagspawn._GetFlagValue(carriedFlag);
        local allowOvershoot = ::flagspawn.ALLOW_OVERSHOOT_FROM_CLASS_GRANT;
        local next = cur + val;

        if (!allowOvershoot) next = (next < ::flagspawn.MAX_STACK_VALUE) ? next : ::flagspawn.MAX_STACK_VALUE;
        else {
            // overshoot only if we're granting from spawner/class
            if (cur < ::flagspawn.MAX_STACK_VALUE) {
                next = (next < ::flagspawn.MAX_STACK_VALUE) ? next : ::flagspawn.MAX_STACK_VALUE;
                // if val itself is big and pushes over cap, allow it
                if (cur + val > ::flagspawn.MAX_STACK_VALUE) next = cur + val;
            }
        }

        ::flagspawn._SetFlagValue(carriedFlag, next);
        ps.spawnedThisLife = true;
        ps.carryingEntIdx = carriedFlag.entindex();
        ps.carryingValue = next;

        ::flagspawn.PlaySoundToAll(::flagspawn.PICKUP_SOUND);
        if (::flagspawn.DEBUG) ::flagspawn.Log("STACK: player already had flag, +" + val + " => " + next);
        return;
    }

    // checkout pooled flag for this team
    local flag = ::flagspawn._CheckoutFromPool(team);
    if (!flag) {
        ::flagspawn.Log("DENY: no pooled flags available for team=" + team);
        return;
    }

    // attach metadata
    local idx = flag.entindex();
    local info = { team = team, value = val, classGrant = true, rockEnt = null, hintEnt = null, glowFlag = null, glowRock = null };
    ::flagspawn._flagInfo[idx] <- info;

    // checkout rock/hint/glows by index position (best-effort)
    if (::flagspawn.ENABLE_ROCK_PROP && ::flagspawn._rockPool[team].len() > 0) {
        // pick first disabled rock not in use by searching for one that's not parented and at z=-10000
        foreach (r in ::flagspawn._rockPool[team]) { if (r) { info.rockEnt = r; break; } }
    }
    if (::flagspawn.ENABLE_VALUE_HINTS && ::flagspawn._hintPool[team].len() > 0) {
        foreach (h in ::flagspawn._hintPool[team]) { if (h) { info.hintEnt = h; break; } }
    }
    if (::flagspawn.ENABLE_GLOW && ::flagspawn._glowPool[team].len() >= 2) {
        // pick two glows; no perfect tracking, but good enough for singleplayer testing
        info.glowFlag = ::flagspawn._glowPool[team][0];
        info.glowRock = ::flagspawn._glowPool[team][1];
    }

    // spawn at player's feet and force pickup behavior by teleporting close then enabling
    local org = player.GetOrigin();
    flag.SetAbsOrigin(org + Vector(0,0,16));
    flag.__KeyValueFromInt("ReturnTime", -1);

    flag.AcceptInput("Enable", "", null, null);
    flag.AcceptInput("ShowSprite", "", null, null);

    // Force the engine to treat it like a real enemy intel if needed:
    // TeamNum already set; pickup overlay is still shown.

    ps.spawnedThisLife = true;
    ps.carryingEntIdx = idx;
    ps.carryingValue = val;

    ::flagspawn.PlaySoundToAll(::flagspawn.PICKUP_SOUND);
    if (::flagspawn.DEBUG) ::flagspawn.Log("SUCCESS: granted pooled flag ent#" + idx + " team=" + team + " value=" + val);
}

// Called by triggers
::flagspawn.OnSpawnerTouch <- function(activator, teamOrCaller, caller=null, value=null) {
    local player = activator;
    if (!player) return;

    local t = ::flagspawn.TeamFromCallerOrInt(teamOrCaller);
    if (t != ::flagspawn.TEAM_RED && t != ::flagspawn.TEAM_BLU) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("OnSpawnerTouch DENY: could not resolve team");
        return;
    }

    // ENEMY-SPAWNER rule:
    // - Touching your OWN team's spawner should do nothing.
    // - Touching the ENEMY team's spawner grants you a flag.
    local pteam = 0;
    try { pteam = player.GetTeam(); } catch(e) { pteam = 0; }
    if (pteam == t) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("OnSpawnerTouch DENY: same team");
        return;
    }

    // touch cooldown (prevents multiple fires per tick)
    local ps = ::flagspawn.PlayerState(player);
    if (ps) {
        local now = ::flagspawn.Now();
        if (now - ps.lastTouchTime < 0.25) return;
        ps.lastTouchTime = now;
    }

    ::flagspawn._GrantFlagToPlayer(player, t);
}

// Capture/bank trigger. For now: consuming carried value into scoreboard is stubbed.
::flagspawn.OnCaptureTouch <- function(activator, teamOrCaller, caller=null, value=null) {
    local player = activator;
    if (!player) return;

    local capTeam = ::flagspawn.TeamFromCallerOrInt(teamOrCaller);
    if (capTeam != ::flagspawn.TEAM_RED && capTeam != ::flagspawn.TEAM_BLU) return;

    local pteam = 0;
    try { pteam = player.GetTeam(); } catch(e) { pteam = 0; }
    if (pteam != capTeam) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("OnCaptureTouch DENY: wrong team");
        return;
    }

    // find carried flag
    local flag = ::flagspawn._ResolveCarriedOrNearbyFlag(player);
    if (!flag) {
        if (::flagspawn.DEBUG) ::flagspawn.Log("OnCaptureTouch: no flag found for player");
        return;
    }

    local val = ::flagspawn._GetFlagValue(flag);
    if (val <= 0) return;

    // consume / return to pool (no return behavior)
    ::flagspawn._ClearDroppedVisuals(flag);
    ::flagspawn._ReturnToPool(flag);

    // reset per-life gate (your rule: reset on capturing any amount)
    local ps = ::flagspawn.PlayerState(player);
    if (ps) { ps.spawnedThisLife = false; ps.carryingEntIdx = -1; ps.carryingValue = 0; }

    ::flagspawn.Log("CAPTURE: team=" + capTeam + " player=" + ::flagspawn.GetUserId(player) + " turned in value=" + val + " (PD scoring hookup next)");
}

// ============================================================
// EVENT HOOKS
// ============================================================
::flagspawn._OnFlagEvent <- function(ev) {
    // teamplay_flag_event keys: player, team, eventtype, priority, home
    // eventtype: 1=pickup, 2=capture, 3=defend?, 4=drop, 5=return (varies)
    local et = ("eventtype" in ev) ? ev.eventtype.tointeger() : -1;
    local uid = ("player" in ev) ? ev.player.tointeger() : 0;
    local ply = (uid > 0) ? GetPlayerFromUserID(uid) : null;

    if (::flagspawn.DEBUG) {
        ::flagspawn.Log("[flag_event] uid=" + uid + " et=" + et + " team=" + (("team" in ev) ? ev.team : "?"));
    }

    // resolve flag from player proximity/ownership
    local flag = ::flagspawn._ResolveCarriedOrNearbyFlag(ply);

    if (et == 4) { // drop
        if (flag) {
            // ensure metadata exists even if engine created the flag (rare)
            local idx = flag.entindex();
            if (!(idx in ::flagspawn._flagInfo)) {
                ::flagspawn._flagInfo[idx] <- { team = (("team" in ev) ? ev.team.tointeger() : 0), value = 1, classGrant = false, rockEnt = null, hintEnt = null, glowFlag = null, glowRock = null };
            }
            // apply dropped visuals
            ::flagspawn._ApplyDroppedVisuals(flag);
        }
        return;
    }

    if (et == 1) { // pickup
        if (flag) {
            // hide dropped visuals when picked up
            ::flagspawn._ClearDroppedVisuals(flag);

            // update player state
            if (ply) {
                local ps = ::flagspawn.PlayerState(ply);
                if (ps) { ps.carryingEntIdx = flag.entindex(); ps.carryingValue = ::flagspawn._GetFlagValue(flag); }
            }
        }
        return;
    }

    if (et == 2) { // capture (engine capture event; we also have our trigger capture)
        // we ignore engine capture; our trigger handles scoring
        return;
    }

    if (et == 5) { // return
        // never return: ignore, and re-apply ReturnTime
        if (flag) {
            try { flag.__KeyValueFromInt("ReturnTime", -1); } catch(e) {}
        }
        return;
    }
}

::flagspawn._OnPlayerDeath <- function(ev) {
    local uid = ("userid" in ev) ? ev.userid.tointeger() : 0;
    local ply = (uid > 0) ? GetPlayerFromUserID(uid) : null;
    if (!ply) return;

    // reset per-life gate on death
    local ps = ::flagspawn.PlayerState(ply);
    if (ps) { ps.spawnedThisLife = false; ps.carryingEntIdx = -1; ps.carryingValue = 0; }
}

::flagspawn._OnRoundStart <- function(ev) {
    ::flagspawn.Log("teamplay_round_start");
    ::flagspawn.ResetAll();
}

::flagspawn._OnRestart <- function(ev) {
    ::flagspawn.Log("teamplay_restart_round");
    ::flagspawn.ResetAll();
}

::flagspawn.RegisterEvents <- function() {
    if (::flagspawn._registered) return;
    ::flagspawn._registered = true;

    // TF2 VScript does NOT always expose ListenToGameEvent().
    // Prefer it when present; otherwise fall back to TF2's __CollectGameEventCallbacks().
    local rt = getroottable();

    if ("ListenToGameEvent" in rt) {
        ListenToGameEvent("teamplay_round_start",   ::flagspawn._OnRoundStart,  null);
        ListenToGameEvent("teamplay_restart_round", ::flagspawn._OnRestart,    null);
        ListenToGameEvent("player_death",           ::flagspawn._OnPlayerDeath,null);
        ListenToGameEvent("teamplay_flag_event",    ::flagspawn._OnFlagEvent,  null);

        ::flagspawn.Log("RegisterEvents (ListenToGameEvent)");
        return;
    }

    if ("__CollectGameEventCallbacks" in rt) {
        // Build a dedicated callback table and collect once.
        if (!("_ge" in ::flagspawn)) ::flagspawn._ge <- {};
        local ge = ::flagspawn._ge;

        // Wrap to preserve your existing handlers.
        ge["OnGameEvent_teamplay_round_start"]   <- function(params) { ::flagspawn._OnRoundStart(params); };
        ge["OnGameEvent_teamplay_restart_round"] <- function(params) { ::flagspawn._OnRestart(params); };
        ge["OnGameEvent_player_death"]           <- function(params) { ::flagspawn._OnPlayerDeath(params); };
        ge["OnGameEvent_teamplay_flag_event"]    <- function(params) { ::flagspawn._OnFlagEvent(params); };

        __CollectGameEventCallbacks(ge);

        ::flagspawn.Log("RegisterEvents (__CollectGameEventCallbacks)");
        return;
    }

    ::flagspawn.Log("ERROR: No game-event registration API available (ListenToGameEvent / __CollectGameEventCallbacks missing).");
}


// ============================================================
// INIT
// ============================================================
::flagspawn.Init <- function() {
    if (::flagspawn._inited) return;
    ::flagspawn._inited = true;

    ::flagspawn.Log("Init");

    ::flagspawn.RegisterEvents();
    ::flagspawn._BuildPools();
    ::flagspawn._SetupSpawnerVisuals();

    // Friendly reminder for glow
    if (::flagspawn.ENABLE_GLOW) {
        ::flagspawn.Log("NOTE: players must have glow_outline_effect_enable 1 to see glows.");
    }
}

::flagspawn.Init();
