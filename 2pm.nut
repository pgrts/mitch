// ============================================================
// Flagspawn v17 (Blu-only)
//
// v17 focus:
// - Event-driven cosmetics (v44-style retries), slow fallback pulse.
// - Keep item_teamflag as PD Hard Truth (pickup/merge/HUD).
// - Use a per-package prop_dynamic (bluflag_prop&####) as the *carried* meter.
// - Use the per-package tf_glow (bluflag_glow&####) as a *recycled glow handle*:
//     DROPPED  -> glow targets item_teamflag
//     CARRIED  -> glow targets bluflag_prop (or player if you prefer)
//   (Target set via NetProps m_hTarget because AddOutput doesn't work for tf_glow.)
//
// Map pattern (fs3_test.vmf):
// - logic_script:            scripter (vscripts flagspawn.nut)
// - trigger_multiple:        fs_spawner_blu (OnStartTouch -> CallScriptFunction FS_OnSpawnerTouchBlu)
// - env_entity_maker:        fs_flag_maker_blu (spawnflags 1)
// - item_teamflag template:  bluflag (spawned as bluflag&####)
// - tf_glow template:        bluflag_glow (spawned as bluflag_glow&####)
// - follower anchor:         blu_lmm_target&#### (moved by logic_measure_movement)
// - carry prop:              bluflag_prop&#### (prop_dynamic)
//
// Project safety:
// - NEVER call GetAbsOrigin() on players.
// ============================================================

if (!("flagspawn" in getroottable()) || typeof getroottable().flagspawn != "table") {
    getroottable().flagspawn <- {};
}
::flagspawn <- getroottable().flagspawn;

// ------------------------------
// Config
// ------------------------------
flagspawn.CFG <- {
    VERSION = "v18_event_cosmetics_global_glow_byname",
    DBG = true,

    // Names
    SCRIPTER_NAME = "scripter",
    TEAM_BLU = 3,

    // Spawner
    SPAWNER_TRIG_BLU = "fs_spawner_blu",
    MAKER_BLU = "fs_flag_maker_blu",
    SPAWNER_PROP_BLU = "blu_flagspawner_prop", // optional

    // Package bases (suffix'd)
    FLAG_BASE = "bluflag",
    // --------------------------------------------------------
    // Glow strategy
    //
    // ALL_BY_NAME (default):
    //   - Place TWO global tf_glow entities in the map (NOT templated):
    //       bluflag_glow      (target=bluflag)
    //       bluflag_prop_glow (target=bluflag_prop)
    //   - Leave them enabled all game.
    //   - We never retarget them; glow appears/disappears by hiding/showing props.
    //
    // NETPROP_SINGLE (optional fallback):
    //   - Uses ONE glow handle and sets m_hTarget via NetProps (glows ONE entity).
    //   - Useful for debugging/"teamleader" highlight or Top-1 style effects.
    // --------------------------------------------------------
    GLOW_MODE = "ALL_BY_NAME",
    GLOW_FLAG_GLOBAL = "bluflag_glow",
    GLOW_PROP_GLOBAL = "bluflag_prop_glow",
    GLOW_TEAMLEADER_SECONDS = 0.0, // set >0 to briefly outline the pickup player

    // Legacy per-package glow base (only used if you go back to templated glows)
    GLOW_BASE = "bluflag_glow",
    FOLLOW_BASE = "blu_lmm_target",  // info_target driven by LMM
    PROP_BASE = "bluflag_prop",      // prop_dynamic meter (carried)

    // Cosmetics
    VALUE_MIN = 0,
    VALUE_MAX = 100,

    // If true, show prop while dropped too (normally false; dropped uses the teamflag model)
    PROP_VISIBLE_WHEN_DROPPED = false,

    // Attach preference
    ATTACHMENTS = ["flag", "back_lower", "prop_bone", "partyhat"],

    // Event retries (v44-style)
    EVENT_RETRY_DELAYS = [0.00, 0.12, 0.35, 0.80],

    // Merge refresh retries (carrier value updates after absorbing another flag)
    MERGE_REFRESH_DELAYS = [0.06, 0.16, 0.32, 0.60],

    // Slow fallback pulse (safety only)
    PULSE_INTERVAL = 3.0,

    // --------------------------------------------------------
    // Pinata / damage chunks (optional, but implemented)
    // Requires Hammer logic_eventlistener(s) configured to CallScriptFunction:
    //  - player_death -> FS_OnPlayerDeath
    //  - player_hurt  -> FS_OnPlayerHurt
    // (FetchEventData=1)
    // --------------------------------------------------------
    PINATA_ENABLED = true,
    PINATA_CHUNKS = 5,
    PINATA_FRAC = 0.20,
    PINATA_MIN_CHUNK = 1,
    PINATA_TEXT_SECONDS = 1.5,
    PINATA_SPAWN_RADIUS = 72.0,

    DAMAGE_CHUNKS_ENABLED = false,
    DAMAGE_CHUNK_FRAC = 0.20,
    DAMAGE_CHUNK_MIN = 1,
    DAMAGE_CHUNK_COOLDOWN = 1.0,

    // Optional dedicated maker for dynamic spawns (death/damage). Falls back to MAKER_BLU if missing.
    MAKER_BLU_DYN = "fs_flag_maker_blu_dyn",

    // Registration
    REGISTER_SCAN_RADIUS = 256.0,

    // --------------------------------------------------------
    // Class budget + spawn pacing (Blu)
    // --------------------------------------------------------
    BUDGET_CLASS_MAX = {
        [1] = 2,   // Scout
        [2] = 8,   // Sniper
        [3] = 4,   // Soldier
        [4] = 3,   // Demoman
        [5] = 7,   // Medic
        [6] = 10,  // Heavy
        [7] = 5,   // Pyro
        [8] = 1,   // Spy
        [9] = 6    // Engineer
    },

    // Time to dump a full class budget (heavy 10 -> ~4s)
    SPAWN_FULL_BUDGET_TIME = 4.0,
    SPAWN_DELAY_MIN = 0.08,
    SPAWN_DELAY_MAX = 1.50,
    SPAWN_BURST_MAX_PER_TOUCH = 12,
};

// ------------------------------
// State
// ------------------------------
flagspawn.State <- {
    InitDone = false,
    PoolBlu = 100,

    // entindex(string) -> rec
    // rec = { flag, suffix, value, pkg={prop,follow,glow}, mode="dropped"/"carried", lastOwnerIdx }
    Flags = {},

    // Player budget tracking (per-life)
    PlayerBudget = {}, // entidxStr -> { used, lastLife, lastClass, lastTeam }

    // Dynamic spawn queue (pinata / damage chunks)
    PendingSpawnQueueBlu = [], // array<int>
    PendingSpawnPosQueueBlu = [], // array<Vector>
    PendingSpawnReasonBlu = "",

    // Damage chunk cooldown per player entindex
    LastChunkAt = {},

    NextPulseAt = 0.0,
};

// ------------------------------
// Logging / basics
// ------------------------------
flagspawn._Log <- function(msg) { if (flagspawn.CFG.DBG) printl("[FS] " + msg); };
flagspawn._Now <- function() { try { return Time(); } catch(_e) { return 0.0; } };
flagspawn._Clamp <- function(v, lo, hi) { if (v < lo) return lo; if (v > hi) return hi; return v; };

flagspawn._EntInput <- function(ent, input, param = "", delay = 0.0, activator = null, caller = null) {
    if (!ent || !ent.IsValid()) return;
    EntFireByHandle(ent, input, param, delay, activator, caller);
};

flagspawn._CallLater <- function(delay, code) {
    local s = Entities.FindByName(null, flagspawn.CFG.SCRIPTER_NAME);
    if (!s) return;
    EntFireByHandle(s, "RunScriptCode", code, delay, null, null);
};

// SAFETY: NEVER GetAbsOrigin() on players
flagspawn._GetOrigin <- function(ent) {
    if (!ent) return Vector(0,0,0);
    try {
        if (ent.IsPlayer && ent.IsPlayer()) {
            try { return NetProps.GetPropVector(ent, "m_vecOrigin"); } catch(_e0) {}
            try { return NetProps.GetPropVector(ent, "m_vecAbsOrigin"); } catch(_e1) {}
            return Vector(0,0,0);
        }
    } catch(_eP) {}

    try { return NetProps.GetPropVector(ent, "m_vecAbsOrigin"); } catch(_e2) {}
    try { return NetProps.GetPropVector(ent, "m_vecOrigin"); } catch(_e3) {}
    return Vector(0,0,0);
};

flagspawn._Dist <- function(a, b) {
    local dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
};

flagspawn._SuffixFromName <- function(name) {
    if (!name) return "";
    local amp = name.find("&");
    if (amp == null) return "";
    return name.slice(amp);
};

flagspawn._FindSuffixed <- function(base, sfx) {
    if (!sfx || sfx == "") return Entities.FindByName(null, base);
    return Entities.FindByName(null, base + sfx);
};

flagspawn._SafeSetBodygroup <- function(ent, groupIdx, value) {
    if (!ent || !ent.IsValid()) return;
    value = flagspawn._Clamp(value, flagspawn.CFG.VALUE_MIN, flagspawn.CFG.VALUE_MAX);

    // Try method
    try { ent.SetBodygroup(groupIdx, value); return; } catch(_e0) {}

    // Try input "SetBodyGroup" "<idx> <value>"
    flagspawn._EntInput(ent, "SetBodyGroup", groupIdx.tostring() + " " + value.tostring(), 0.0, null, null);
};

flagspawn._ApplyBodygroupsBoth <- function(flagEnt, propEnt, value) {
    // Project rule: meter fill is bodygroup index 1 (but we also try 0 as fallback)
    if (flagEnt && flagEnt.IsValid()) {
        flagspawn._SafeSetBodygroup(flagEnt, 1, value);
        flagspawn._SafeSetBodygroup(flagEnt, 0, value);
    }
    if (propEnt && propEnt.IsValid()) {
        flagspawn._SafeSetBodygroup(propEnt, 1, value);
        flagspawn._SafeSetBodygroup(propEnt, 0, value);
    }
};

flagspawn._ShowProp <- function(prop) {
    if (!prop || !prop.IsValid()) return;
    // hit both: some props ignore one of these
    flagspawn._EntInput(prop, "Enable", "", 0.0, null, null);
    flagspawn._EntInput(prop, "EnableDraw", "", 0.0, null, null);
};

flagspawn._HideProp <- function(prop) {
    if (!prop || !prop.IsValid()) return;
    flagspawn._EntInput(prop, "DisableDraw", "", 0.0, null, null);
    flagspawn._EntInput(prop, "Disable", "", 0.0, null, null);
};

flagspawn._PickAttachment <- function(ply) {
    foreach (a in flagspawn.CFG.ATTACHMENTS) {
        local idx = 0;
        try { idx = ply.LookupAttachment(a); } catch(_e) { idx = 0; }
        if (idx > 0) return a;
    }
    return ""; // fallback to root
};

flagspawn._ParentPropToPlayer <- function(prop, ply) {
    if (!prop || !prop.IsValid() || !ply || !ply.IsValid()) return;

    local att = flagspawn._PickAttachment(ply);

    flagspawn._EntInput(prop, "ClearParent", "", 0.0, null, null);
    flagspawn._EntInput(prop, "SetParent", "!activator", 0.0, ply, prop);

    if (att != "") {
        // give attachment a beat to resolve
        flagspawn._EntInput(prop, "SetParentAttachment", att, 0.01, ply, prop);
        flagspawn._EntInput(prop, "SetParentAttachmentMaintainOffset", att, 0.02, ply, prop);
    }
};

flagspawn._ParentPropToFollow <- function(prop, follow) {
    if (!prop || !prop.IsValid() || !follow || !follow.IsValid()) return;
    flagspawn._EntInput(prop, "ClearParent", "", 0.0, null, null);
    flagspawn._EntInput(prop, "SetParent", "!activator", 0.0, follow, prop);
};

// tf_glow: must use NetProp m_hTarget (AddOutput target is bugged)
flagspawn._BindGlow <- function(glow, targetEnt) {
    if (!glow || !glow.IsValid()) return;

    if (!targetEnt || !targetEnt.IsValid()) {
        // Leave glow enabled; just clear target if possible
        try { NetProps.SetPropEntity(glow, "m_hTarget", null); } catch(_e0) {}
        return;
    }

    try { NetProps.SetPropEntity(glow, "m_hTarget", targetEnt); } catch(_e1) {}

    // If someone left StartDisabled=1, force enable once.
    flagspawn._EntInput(glow, "Enable", "", 0.0, null, null);
};

// Transient pickup "teamleader" highlight (optional)
flagspawn._TeamLeaderGlowBurst <- function(ply, seconds) {
    if (!ply || !ply.IsValid() || seconds <= 0.0) return;

    // Reuse per-player glow if it exists
    local scope = ply.ValidateScriptScope();
    local g = null;
    if ("fs_leader_glow" in scope) {
        g = scope.fs_leader_glow;
        if (g && g.IsValid()) {
            // refresh
            flagspawn._BindGlow(g, ply);
            flagspawn._EntInput(g, "Enable", "", 0.0, null, null);
            flagspawn._EntInput(g, "Kill", "", seconds, null, null);
            return;
        }
    }

    // Spawn a dedicated tf_glow for this player.
    // Note: tf_glow usually needs to be parented to target to avoid PVS transmit issues.
    try {
        g = SpawnEntityFromTable("tf_glow", {
            targetname = "fs_leader_glow_" + ply.entindex(),
            StartDisabled = 0
        });
    } catch (_e0) { g = null; }
    if (!g || !g.IsValid()) return;

    scope.fs_leader_glow <- g;
    // Parent glow to player (improves networking / PVS)
    flagspawn._EntInput(g, "SetParent", "!activator", 0.0, ply, g);
    flagspawn._BindGlow(g, ply);
    flagspawn._EntInput(g, "Enable", "", 0.0, null, null);
    flagspawn._EntInput(g, "Kill", "", seconds, null, null);
};

// Write point value back into the engine netprops (used for chunking / pinata)
flagspawn._WriteFlagValue <- function(flagEnt, value) {
    if (!flagEnt || !flagEnt.IsValid()) return;
    value = flagspawn._Clamp(value, flagspawn.CFG.VALUE_MIN, flagspawn.CFG.VALUE_MAX);
    try { NetProps.SetPropInt(flagEnt, "m_nPointValue", value); } catch(_e0) {}
    try { NetProps.SetPropInt(flagEnt, "m_iPointValue", value); } catch(_e1) {}
};

flagspawn._SetOriginNonPlayer <- function(ent, vec) {
    if (!ent || !ent.IsValid() || vec == null) return;
    try { ent.SetOrigin(vec); return; } catch(_e0) {}
    try { NetProps.SetPropVector(ent, "m_vecOrigin", vec); return; } catch(_e1) {}
    try { NetProps.SetPropVector(ent, "m_vecAbsOrigin", vec); return; } catch(_e2) {}
};

flagspawn._SpawnWorldText <- function(pos, msg, seconds) {
    if (pos == null) return;
    try {
        local t = SpawnEntityFromTable("point_worldtext", {
            message = msg,
            textsize = 12,
            orientation = 0,
            targetname = "fs_tmp_text"
        });
        if (t && t.IsValid()) {
            flagspawn._SetOriginNonPlayer(t, pos);
            flagspawn._EntInput(t, "Kill", "", seconds, null, null);
        }
    } catch(_e0) {}
};

flagspawn._ReadFlagValue <- function(flagEnt) {
    if (!flagEnt || !flagEnt.IsValid()) return 1;
    local v = 1;
    try { v = NetProps.GetPropInt(flagEnt, "m_nPointValue"); } catch(_e0) {}
    try { v = NetProps.GetPropInt(flagEnt, "m_iPointValue"); } catch(_e1) {}
    return flagspawn._Clamp(v, flagspawn.CFG.VALUE_MIN, flagspawn.CFG.VALUE_MAX);
};

flagspawn._FindCarrier <- function(flagEnt) {
    if (!flagEnt || !flagEnt.IsValid()) return null;
    local props = ["m_hOwner", "m_hOwnerEntity", "m_hMoveParent"];
    foreach (p in props) {
        try {
            local e = NetProps.GetPropEntity(flagEnt, p);
            if (e && e.IsValid() && e.IsPlayer && e.IsPlayer()) return e;
        } catch(_e) {}
    }
    return null;
};

// ------------------------------
// Init / pulse
// ------------------------------
flagspawn.Init <- function() {
    if (flagspawn.State.InitDone) return;
    flagspawn.State.InitDone = true;

    flagspawn._Log("Init " + flagspawn.CFG.VERSION + " PoolBlu=" + flagspawn.State.PoolBlu);

    // schedule slow pulse
    flagspawn._SchedulePulse();
};

flagspawn._SchedulePulse <- function() {
    flagspawn._CallLater(flagspawn.CFG.PULSE_INTERVAL, "flagspawn._Pulse()");
};

flagspawn._Pulse <- function() {
    flagspawn._SchedulePulse();

    // safety only
    flagspawn._PruneDeadFlags();
    flagspawn._RepairAllPlayerBudgets();
    flagspawn._CleanupStuckProps();
    flagspawn._RefreshAllCosmetics();
};

flagspawn._PruneDeadFlags <- function() {
    foreach (k, rec in flagspawn.State.Flags) {
        if (!rec || !rec.flag || !rec.flag.IsValid()) {
            flagspawn.State.Flags.rawdelete(k);
        }
    }
};

flagspawn._CleanupStuckProps <- function() {
    // If a prop is still parented to a player who just respawned/class-changed,
    // budget reset handler will re-home it; this is extra safety.
    foreach (_k, rec in flagspawn.State.Flags) {
        if (!rec || !rec.pkg) continue;
        local prop = rec.pkg.prop;
        if (!prop || !prop.IsValid()) continue;

        local mp = null;
        try { mp = NetProps.GetPropEntity(prop, "m_hMoveParent"); } catch(_e0) { mp = null; }
        if (mp && mp.IsValid() && mp.IsPlayer && mp.IsPlayer()) {
            // If the *flag* is currently dropped (no carrier), the prop should NOT still be on the player.
            if (!flagspawn._FindCarrier(rec.flag)) {
                flagspawn._EntInput(prop, "ClearParent", "", 0.0, null, null);
                if (rec.pkg.follow && rec.pkg.follow.IsValid()) {
                    flagspawn._ParentPropToFollow(prop, rec.pkg.follow);
                }
                if (!flagspawn.CFG.PROP_VISIBLE_WHEN_DROPPED) flagspawn._HideProp(prop);
            }
        }
    }
};

flagspawn._RefreshAllCosmetics <- function() {
    foreach (_k, rec in flagspawn.State.Flags) {
        if (!rec || !rec.flag || !rec.flag.IsValid()) continue;

        // recache late spawns
        if (!rec.pkg.prop || !rec.pkg.prop.IsValid()) rec.pkg.prop = flagspawn._FindSuffixed(flagspawn.CFG.PROP_BASE, rec.suffix);
        if (!rec.pkg.follow || !rec.pkg.follow.IsValid()) rec.pkg.follow = flagspawn._FindSuffixed(flagspawn.CFG.FOLLOW_BASE, rec.suffix);
        if (!rec.pkg.glow || !rec.pkg.glow.IsValid()) rec.pkg.glow = flagspawn._FindSuffixed(flagspawn.CFG.GLOW_BASE, rec.suffix);

        local carrier = flagspawn._FindCarrier(rec.flag);
        rec.value = flagspawn._ReadFlagValue(rec.flag);

        if (carrier) {
            rec.mode = "carried";
            rec.lastOwnerIdx = carrier.entindex();

            if (rec.pkg.prop && rec.pkg.prop.IsValid()) {
                flagspawn._ShowProp(rec.pkg.prop);

                // ensure parented to carrier
                local mp = null;
                try { mp = NetProps.GetPropEntity(rec.pkg.prop, "m_hMoveParent"); } catch(_e0) { mp = null; }
                if (mp != carrier) flagspawn._ParentPropToPlayer(rec.pkg.prop, carrier);
            }

            flagspawn._ApplyBodygroupsBoth(rec.flag, rec.pkg.prop, rec.value);
            // Glow:
            // - ALL_BY_NAME: do nothing (map's global tf_glow(s) stay enabled)
            // - NETPROP_SINGLE: optional fallback to bind a single glow target
            if (flagspawn.CFG.GLOW_MODE == "NETPROP_SINGLE") {
                if (rec.pkg.glow && rec.pkg.glow.IsValid()) {
                    if (rec.pkg.prop && rec.pkg.prop.IsValid()) flagspawn._BindGlow(rec.pkg.glow, rec.pkg.prop);
                    else flagspawn._BindGlow(rec.pkg.glow, carrier);
                }
            }
        } else {
            rec.mode = "dropped";

            // hide + re-home prop
            if (rec.pkg.prop && rec.pkg.prop.IsValid()) {
                if (rec.pkg.follow && rec.pkg.follow.IsValid()) {
                    // If still parented to a player, fix it.
                    local mp = null;
                    try { mp = NetProps.GetPropEntity(rec.pkg.prop, "m_hMoveParent"); } catch(_e1) { mp = null; }
                    if (mp && mp.IsValid() && mp.IsPlayer && mp.IsPlayer()) {
                        flagspawn._EntInput(rec.pkg.prop, "ClearParent", "", 0.0, null, null);
                    }
                    flagspawn._ParentPropToFollow(rec.pkg.prop, rec.pkg.follow);
                }

                if (flagspawn.CFG.PROP_VISIBLE_WHEN_DROPPED) flagspawn._ShowProp(rec.pkg.prop);
                else flagspawn._HideProp(rec.pkg.prop);
            }

            flagspawn._ApplyBodygroupsBoth(rec.flag, rec.pkg.prop, rec.value);
            if (flagspawn.CFG.GLOW_MODE == "NETPROP_SINGLE") {
                if (rec.pkg.glow && rec.pkg.glow.IsValid()) flagspawn._BindGlow(rec.pkg.glow, rec.flag);
            }
        }
    }
};

// ------------------------------
// Player budget helpers
// ------------------------------
flagspawn._GetLifeState <- function(ply) {
    try { return NetProps.GetPropInt(ply, "m_lifeState"); } catch(_e) {}
    try { return ply.GetLifeState(); } catch(_e2) {}
    return 0;
};

flagspawn._GetPlayerClassIndex <- function(ply) {
    try { return ply.GetPlayerClass(); } catch(_e) {}
    try { return NetProps.GetPropInt(ply, "m_PlayerClass"); } catch(_e2) {}
    return 0;
};

flagspawn._EnsureBudget <- function(ply) {
    local k = ply.entindex().tostring();
    if (!(k in flagspawn.State.PlayerBudget)) {
        flagspawn.State.PlayerBudget[k] <- { used = 0, lastLife = -1, lastClass = -1, lastTeam = -1 };
    }
    return flagspawn.State.PlayerBudget[k];
};

flagspawn._ResetBudgetIfNeeded <- function(ply) {
    if (!ply || !ply.IsValid()) return;

    local b = flagspawn._EnsureBudget(ply);
    local life = flagspawn._GetLifeState(ply);
    local cls  = flagspawn._GetPlayerClassIndex(ply);
    local team = 0; try { team = ply.GetTeam(); } catch(_e) { team = 0; }

    local respawned = (b.lastLife != -1 && b.lastLife != 0 && life == 0);
    local classChanged = (b.lastClass != -1 && cls != 0 && cls != b.lastClass);
    local teamChanged  = (b.lastTeam != -1 && team != b.lastTeam);

    if (respawned || classChanged || teamChanged) {
        b.used = 0;
        // On respawn/class-change: detach any props that are still on this player
        flagspawn._DetachAllPropsFromPlayer(ply);
        flagspawn._Log("BudgetReset ply=" + ply.entindex() + " respawned=" + respawned + " classChanged=" + classChanged + " teamChanged=" + teamChanged);
    }

    b.lastLife = life;
    b.lastClass = cls;
    b.lastTeam = team;
};

flagspawn._RepairAllPlayerBudgets <- function() {
    local ply = null;
    while ((ply = Entities.FindByClassname(ply, "player")) != null) {
        if (!ply.IsValid()) continue;
        flagspawn._ResetBudgetIfNeeded(ply);
    }
};

flagspawn._DetachAllPropsFromPlayer <- function(ply) {
    // First: detach any registered package props.
    foreach (_k, rec in flagspawn.State.Flags) {
        if (!rec || !rec.pkg || !rec.pkg.prop) continue;
        local prop = rec.pkg.prop;
        if (!prop || !prop.IsValid()) continue;

        local mp = null;
        try { mp = NetProps.GetPropEntity(prop, "m_hMoveParent"); } catch(_e0) { mp = null; }
        if (mp == ply) {
            flagspawn._EntInput(prop, "ClearParent", "", 0.0, null, null);
            if (rec.pkg.follow && rec.pkg.follow.IsValid()) {
                flagspawn._ParentPropToFollow(prop, rec.pkg.follow);
            }
            flagspawn._HideProp(prop);
        }
    }

    // Safety: if a prop was never registered (race, merge, etc.) it can remain stuck on the player.
    // Scan all prop_dynamic named like "bluflag_prop..." and forcibly detach.
    local p = null;
    while ((p = Entities.FindByClassname(p, "prop_dynamic")) != null) {
        if (!p.IsValid()) continue;
        local nm = ""; try { nm = p.GetName(); } catch(_e1) { nm = ""; }
        if (nm.len() < flagspawn.CFG.PROP_BASE.len()) continue;
        if (nm.find(flagspawn.CFG.PROP_BASE) != 0) continue;

        local mp = null;
        try { mp = NetProps.GetPropEntity(p, "m_hMoveParent"); } catch(_e2) { mp = null; }
        if (mp != ply) continue;

        // Detach + re-home to follow if we can infer a suffix.
        flagspawn._EntInput(p, "ClearParent", "", 0.0, null, null);
        local sfx = flagspawn._SuffixFromName(nm);
        local follow = flagspawn._FindSuffixed(flagspawn.CFG.FOLLOW_BASE, sfx);
        if (follow && follow.IsValid()) {
            flagspawn._ParentPropToFollow(p, follow);
        }
        flagspawn._HideProp(p);
    }
};

// ------------------------------
// Registration (maker)
// ------------------------------
flagspawn._RegisterNewestFlagNearMaker <- function(maker) {
    local mo = flagspawn._GetOrigin(maker);

    local best = null;
    local bestIdx = -1;

    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        if (!f.IsValid()) continue;

        local nm = ""; try { nm = f.GetName(); } catch(_e0) { nm = ""; }
        if (nm.len() < flagspawn.CFG.FLAG_BASE.len()) continue;
        if (nm.find(flagspawn.CFG.FLAG_BASE) != 0) continue; // prefix match

        // near maker
        local fo = flagspawn._GetOrigin(f);
        if (flagspawn._Dist(fo, mo) > flagspawn.CFG.REGISTER_SCAN_RADIUS) continue;

        local k = f.entindex().tostring();
        if (k in flagspawn.State.Flags) continue;

        if (f.entindex() > bestIdx) {
            best = f;
            bestIdx = f.entindex();
        }
    }

    if (!best) {
        flagspawn._Log("RegisterNewest: none found");
        return;
    }

    flagspawn._RegisterFlag(best);
};

flagspawn._RegisterFlag <- function(flagEnt) {
    local nm = ""; try { nm = flagEnt.GetName(); } catch(_e) { nm = ""; }
    local sfx = flagspawn._SuffixFromName(nm);

    local rec = {
        flag = flagEnt,
        suffix = sfx,
        value = flagspawn._ReadFlagValue(flagEnt),
        mode = "dropped",
        lastOwnerIdx = 0,
        pkg = { prop = null, follow = null, glow = null }
    };

    // cache package handles
    rec.pkg.prop = flagspawn._FindSuffixed(flagspawn.CFG.PROP_BASE, sfx);
    rec.pkg.follow = flagspawn._FindSuffixed(flagspawn.CFG.FOLLOW_BASE, sfx);
    rec.pkg.glow = flagspawn._FindSuffixed(flagspawn.CFG.GLOW_BASE, sfx);

    // make sure prop is homed to follow and hidden
    if (rec.pkg.prop && rec.pkg.prop.IsValid() && rec.pkg.follow && rec.pkg.follow.IsValid()) {
        flagspawn._ParentPropToFollow(rec.pkg.prop, rec.pkg.follow);
    }
    if (rec.pkg.prop && rec.pkg.prop.IsValid() && !flagspawn.CFG.PROP_VISIBLE_WHEN_DROPPED) {
        flagspawn._HideProp(rec.pkg.prop);
    }

    // Glow is handled by the map in ALL_BY_NAME mode.
    // Optional NETPROP_SINGLE mode may bind a single glow target.
    if (flagspawn.CFG.GLOW_MODE == "NETPROP_SINGLE") {
        if (rec.pkg.glow && rec.pkg.glow.IsValid()) {
            flagspawn._BindGlow(rec.pkg.glow, rec.flag);
        }
    }

    // apply initial cosmetics
    // If a dynamic spawn queue is active (pinata/damage), overwrite the spawned value now.
    if (flagspawn.State.PendingSpawnQueueBlu.len() > 0) {
        local v = flagspawn.State.PendingSpawnQueueBlu[0];
        flagspawn.State.PendingSpawnQueueBlu.remove(0);
        v = flagspawn._Clamp(v, flagspawn.CFG.VALUE_MIN, flagspawn.CFG.VALUE_MAX);
        rec.value = v;
        flagspawn._WriteFlagValue(rec.flag, v);
    }

    // Optional: teleport newly-spawned flag to queued position (for pinata/damage spawns)
    if (flagspawn.State.PendingSpawnPosQueueBlu.len() > 0) {
        local pos = flagspawn.State.PendingSpawnPosQueueBlu[0];
        flagspawn.State.PendingSpawnPosQueueBlu.remove(0);
        if (pos != null) {
            flagspawn._SetOriginNonPlayer(rec.flag, pos);
        }
    }

    flagspawn._ApplyBodygroupsBoth(rec.flag, rec.pkg.prop, rec.value);

    flagspawn.State.Flags[flagEnt.entindex().tostring()] <- rec;

    flagspawn._Log("Registered " + nm + " value=" + rec.value + " sfx=" + sfx);
};

// ------------------------------
// Spawner touch (Blu)
// ------------------------------
function FS_OnSpawnerTouchBlu() {
    flagspawn.Init();

    local ply = null; try { ply = activator; } catch(_e) { ply = null; }
    if (!ply || !ply.IsValid()) return;
    try { if (!ply.IsPlayer()) return; } catch(_e2) {}

    local team = 0; try { team = ply.GetTeam(); } catch(_e3) { team = 0; }
    if (team != flagspawn.CFG.TEAM_BLU) return;

    flagspawn._ResetBudgetIfNeeded(ply);
    local b = flagspawn._EnsureBudget(ply);

    local cls = flagspawn._GetPlayerClassIndex(ply);
    local maxBudget = (cls in flagspawn.CFG.BUDGET_CLASS_MAX) ? flagspawn.CFG.BUDGET_CLASS_MAX[cls] : 1;

    local remaining = maxBudget - b.used;
    if (remaining <= 0) return;

    if (flagspawn.State.PoolBlu <= 0) return;

    local spawnCount = remaining;
    if (spawnCount > flagspawn.State.PoolBlu) spawnCount = flagspawn.State.PoolBlu;
    if (spawnCount > flagspawn.CFG.SPAWN_BURST_MAX_PER_TOUCH) spawnCount = flagspawn.CFG.SPAWN_BURST_MAX_PER_TOUCH;

    local maker = Entities.FindByName(null, flagspawn.CFG.MAKER_BLU);
    if (!maker) {
        flagspawn._Log("SpawnerTouch: maker missing");
        return;
    }

    local perDelay = flagspawn.CFG.SPAWN_FULL_BUDGET_TIME / maxBudget.tofloat();
    if (perDelay < flagspawn.CFG.SPAWN_DELAY_MIN) perDelay = flagspawn.CFG.SPAWN_DELAY_MIN;
    if (perDelay > flagspawn.CFG.SPAWN_DELAY_MAX) perDelay = flagspawn.CFG.SPAWN_DELAY_MAX;

    for (local i = 0; i < spawnCount; i++) {
        EntFireByHandle(maker, "ForceSpawn", "", i * perDelay, null, null);
    }

    b.used += spawnCount;
    flagspawn.State.PoolBlu -= spawnCount;

    flagspawn._UpdateSpawnerPropBlu();
};

flagspawn._UpdateSpawnerPropBlu <- function() {
    local prop = Entities.FindByName(null, flagspawn.CFG.SPAWNER_PROP_BLU);
    if (!prop) return;
    // Project rule: bodygroup index 1
    flagspawn._SafeSetBodygroup(prop, 1, flagspawn.State.PoolBlu);
};

// ------------------------------
// Dynamic spawns (pinata / damage chunks)
// Spawns through an env_entity_maker so we still get the full template package.
// Values / positions are queued and applied inside _RegisterFlag.
// ------------------------------
flagspawn._GetBluDynMaker <- function() {
    local m = Entities.FindByName(null, flagspawn.CFG.MAKER_BLU_DYN);
    if (m) return m;
    return Entities.FindByName(null, flagspawn.CFG.MAKER_BLU);
};

flagspawn._ScatterPos <- function(origin, radius) {
    local a = 0.0;
    try { a = RandomFloat(0.0, 6.2831853); } catch(_e0) { a = 0.0; }
    local r = 0.0;
    try { r = RandomFloat(0.0, radius); } catch(_e1) { r = radius; }
    local x = cos(a) * r;
    local y = sin(a) * r;
    return Vector(origin.x + x, origin.y + y, origin.z + 8.0);
};

flagspawn._DynSpawnBlu <- function(values, origin, radius, reason) {
    local maker = flagspawn._GetBluDynMaker();
    if (!maker) {
        flagspawn._Log("DynSpawn: maker missing");
        return;
    }
    if (origin == null) origin = flagspawn._GetOrigin(maker);

    flagspawn.State.PendingSpawnReasonBlu = reason;

    local t = 0.0;
    foreach (v in values) {
        flagspawn.State.PendingSpawnQueueBlu.append(v);
        flagspawn.State.PendingSpawnPosQueueBlu.append(flagspawn._ScatterPos(origin, radius));
        EntFireByHandle(maker, "ForceSpawn", "", t, null, null);
        t += 0.03; // small stagger to keep RegisterNewest sane
    }
};

// maker output
function FS_OnMakerSpawned() {
    flagspawn.Init();
    local maker = null; try { maker = caller; } catch(_e) { maker = null; }
    if (!maker || !maker.IsValid()) maker = Entities.FindByName(null, flagspawn.CFG.MAKER_BLU);
    if (!maker) return;

    flagspawn._RegisterNewestFlagNearMaker(maker);
}

// ------------------------------
// Flag direct events (from item_teamflag outputs in fs3_test)
// These are the ones you WANT for cosmetics.
// ------------------------------
function FS_Direct_Pickup() {
    flagspawn.Init();

    local flagEnt = null; try { flagEnt = caller; } catch(_e0) { flagEnt = null; }
    local ply = null;     try { ply = activator; } catch(_e1) { ply = null; }
    if (!flagEnt || !flagEnt.IsValid() || !ply || !ply.IsValid()) return;

    flagspawn._OnPickup(flagEnt, ply);
}

function FS_Direct_Drop() {
    flagspawn.Init();

    local flagEnt = null; try { flagEnt = caller; } catch(_e0) { flagEnt = null; }
    if (!flagEnt || !flagEnt.IsValid()) return;

    flagspawn._OnDrop(flagEnt);
}

// Optional: can be wired on return/capture to clean cosmetics
function FS_Direct_Return() {
    flagspawn.Init();
    local flagEnt = null; try { flagEnt = caller; } catch(_e0) { flagEnt = null; }
    if (!flagEnt || !flagEnt.IsValid()) return;
    flagspawn._OnDrop(flagEnt);
}

function FS_Direct_Capture() {
    flagspawn.Init();
    local flagEnt = null; try { flagEnt = caller; } catch(_e0) { flagEnt = null; }
    if (!flagEnt || !flagEnt.IsValid()) return;
    flagspawn._OnDrop(flagEnt);
}

// ------------------------------
// Alias entrypoints (Hammer outputs vary between versions)
// ------------------------------
function FS_MakerSpawned() { FS_OnMakerSpawned(); }
function FS_SpawnEvent() { FS_OnMakerSpawned(); }
function FS_DirectPickup() { FS_Direct_Pickup(); }
function FS_DirectDrop() { FS_Direct_Drop(); }
function FS_PickupEvent() { FS_Direct_Pickup(); }
function FS_DropEvent() { FS_Direct_Drop(); }

// Lowercase fallbacks (if you typed them that way in Hammer)
function fs_makerspawned() { FS_OnMakerSpawned(); }
function fs_directpickup() { FS_Direct_Pickup(); }
function fs_drop() { FS_Direct_Drop(); }

// ------------------------------
// Event handlers (with retries)
// ------------------------------
flagspawn._OnPickup <- function(flagEnt, ply) {
    local k = flagEnt.entindex().tostring();
    if (!(k in flagspawn.State.Flags)) {
        flagspawn._RegisterFlag(flagEnt);
    }

    foreach (d in flagspawn.CFG.EVENT_RETRY_DELAYS) {
        flagspawn._CallLater(d, "flagspawn._EnforcePickup(" + flagEnt.entindex() + "," + ply.entindex() + ")");
    }
    // Merge refresh: the absorbed flag is `caller`, but the carrier
    //'s *other* flag value updates shortly after.
    foreach (d2 in flagspawn.CFG.MERGE_REFRESH_DELAYS) {
        flagspawn._CallLater(d2, "flagspawn._RefreshCarrierForPlayerIdx(" + ply.entindex() + ")");
    }
};

flagspawn._OnDrop <- function(flagEnt) {
    local k = flagEnt.entindex().tostring();
    if (!(k in flagspawn.State.Flags)) {
        flagspawn._RegisterFlag(flagEnt);
    }

    foreach (d in flagspawn.CFG.EVENT_RETRY_DELAYS) {
        flagspawn._CallLater(d, "flagspawn._EnforceDrop(" + flagEnt.entindex() + ")");
    }
};

flagspawn._HFromIdx <- function(idx) {
    // EntIndexToHScript exists in TF2 VScript; keep defensive
    try { return EntIndexToHScript(idx); } catch(_e0) {}
    return null;
};



// Refresh carrier cosmetics (merge updates): find the flag currently carried by this player
flagspawn._FindRecByCarrier <- function(ply) {
    foreach (_k, rec in flagspawn.State.Flags) {
        if (!rec || !rec.flag || !rec.flag.IsValid()) continue;
        local c = flagspawn._FindCarrier(rec.flag);
        if (c == ply) return rec;
    }
    return null;
};

flagspawn._RefreshCarrierForPlayerIdx <- function(plyIdx) {
    local ply = flagspawn._HFromIdx(plyIdx);
    if (!ply || !ply.IsValid()) return;

    local rec = flagspawn._FindRecByCarrier(ply);
    if (!rec) return;

    // recache late spawns
    if (!rec.pkg.prop || !rec.pkg.prop.IsValid()) rec.pkg.prop = flagspawn._FindSuffixed(flagspawn.CFG.PROP_BASE, rec.suffix);
    if (!rec.pkg.follow || !rec.pkg.follow.IsValid()) rec.pkg.follow = flagspawn._FindSuffixed(flagspawn.CFG.FOLLOW_BASE, rec.suffix);
    if (!rec.pkg.glow || !rec.pkg.glow.IsValid()) rec.pkg.glow = flagspawn._FindSuffixed(flagspawn.CFG.GLOW_BASE, rec.suffix);

    // ensure prop is visible + on the carrier
    if (rec.pkg.prop && rec.pkg.prop.IsValid()) {
        flagspawn._ShowProp(rec.pkg.prop);
        flagspawn._ParentPropToPlayer(rec.pkg.prop, ply);
    }

    // re-read current carried value (after merge)
    rec.value = flagspawn._ReadFlagValue(rec.flag);
    rec.mode = "carried";
    rec.lastOwnerIdx = plyIdx;

    flagspawn._ApplyBodygroupsBoth(rec.flag, rec.pkg.prop, rec.value);

    if (flagspawn.CFG.GLOW_MODE == "NETPROP_SINGLE") {
        if (rec.pkg.glow && rec.pkg.glow.IsValid()) {
            if (rec.pkg.prop && rec.pkg.prop.IsValid()) flagspawn._BindGlow(rec.pkg.glow, rec.pkg.prop);
            else flagspawn._BindGlow(rec.pkg.glow, ply);
        }
    }
};
flagspawn._EnforcePickup <- function(flagIdx, plyIdx) {
    local flagEnt = flagspawn._HFromIdx(flagIdx);
    local ply = flagspawn._HFromIdx(plyIdx);
    if (!flagEnt || !flagEnt.IsValid() || !ply || !ply.IsValid()) return;

    local k = flagIdx.tostring();
    if (!(k in flagspawn.State.Flags)) return;
    local rec = flagspawn.State.Flags[k];

    // recache late spawns
    if (!rec.pkg.prop || !rec.pkg.prop.IsValid()) rec.pkg.prop = flagspawn._FindSuffixed(flagspawn.CFG.PROP_BASE, rec.suffix);
    if (!rec.pkg.follow || !rec.pkg.follow.IsValid()) rec.pkg.follow = flagspawn._FindSuffixed(flagspawn.CFG.FOLLOW_BASE, rec.suffix);
    if (!rec.pkg.glow || !rec.pkg.glow.IsValid()) rec.pkg.glow = flagspawn._FindSuffixed(flagspawn.CFG.GLOW_BASE, rec.suffix);

    rec.value = flagspawn._ReadFlagValue(flagEnt);
    rec.mode = "carried";
    rec.lastOwnerIdx = plyIdx;

    // show + attach prop
    if (rec.pkg.prop && rec.pkg.prop.IsValid()) {
        flagspawn._ShowProp(rec.pkg.prop);
        flagspawn._ParentPropToPlayer(rec.pkg.prop, ply);
    }

    // cosmetics: bodygroups on both
    flagspawn._ApplyBodygroupsBoth(flagEnt, rec.pkg.prop, rec.value);

    // Glow:
    // - ALL_BY_NAME: do nothing (global glows key off the prop/flag target strings)
    // - NETPROP_SINGLE: optional fallback to retarget one glow entity
    if (flagspawn.CFG.GLOW_MODE == "NETPROP_SINGLE") {
        if (rec.pkg.glow && rec.pkg.glow.IsValid()) {
            if (rec.pkg.prop && rec.pkg.prop.IsValid()) flagspawn._BindGlow(rec.pkg.glow, rec.pkg.prop);
            else flagspawn._BindGlow(rec.pkg.glow, ply); // last-resort
        }
    }

    // Optional: brief leader outline on pickup (separate, transient tf_glow)
    if (flagspawn.CFG.GLOW_TEAMLEADER_SECONDS > 0.0) {
        flagspawn._TeamLeaderGlowBurst(ply, flagspawn.CFG.GLOW_TEAMLEADER_SECONDS);
    }
};

flagspawn._EnforceDrop <- function(flagIdx) {
    local flagEnt = flagspawn._HFromIdx(flagIdx);
    if (!flagEnt || !flagEnt.IsValid()) return;

    local k = flagIdx.tostring();
    if (!(k in flagspawn.State.Flags)) return;
    local rec = flagspawn.State.Flags[k];

    // recache late spawns
    if (!rec.pkg.prop || !rec.pkg.prop.IsValid()) rec.pkg.prop = flagspawn._FindSuffixed(flagspawn.CFG.PROP_BASE, rec.suffix);
    if (!rec.pkg.follow || !rec.pkg.follow.IsValid()) rec.pkg.follow = flagspawn._FindSuffixed(flagspawn.CFG.FOLLOW_BASE, rec.suffix);
    if (!rec.pkg.glow || !rec.pkg.glow.IsValid()) rec.pkg.glow = flagspawn._FindSuffixed(flagspawn.CFG.GLOW_BASE, rec.suffix);

    rec.value = flagspawn._ReadFlagValue(flagEnt);
    rec.mode = "dropped";

    // re-home prop to follow and hide (dropped uses the flag)
    if (rec.pkg.prop && rec.pkg.prop.IsValid()) {
        if (rec.pkg.follow && rec.pkg.follow.IsValid()) {
            flagspawn._ParentPropToFollow(rec.pkg.prop, rec.pkg.follow);
        } else {
            flagspawn._EntInput(rec.pkg.prop, "ClearParent", "", 0.0, null, null);
        }

        if (flagspawn.CFG.PROP_VISIBLE_WHEN_DROPPED) flagspawn._ShowProp(rec.pkg.prop);
        else flagspawn._HideProp(rec.pkg.prop);
    }

    // cosmetics: bodygroups on both
    flagspawn._ApplyBodygroupsBoth(flagEnt, rec.pkg.prop, rec.value);

    if (flagspawn.CFG.GLOW_MODE == "NETPROP_SINGLE") {
        // glow retarget: glow -> flag while dropped (single-target fallback)
        if (rec.pkg.glow && rec.pkg.glow.IsValid()) {
            flagspawn._BindGlow(rec.pkg.glow, flagEnt);
        }
    }
};

// ------------------------------
// Pinata / Damage chunks
// (disabled by default via CFG)
// ------------------------------
flagspawn._FindRecentDroppedFromOwner <- function(ownerIdx, pos, maxDist) {
    local best = null;
    local bestD = 999999.0;
    foreach (_k, rec in flagspawn.State.Flags) {
        if (!rec || !rec.flag || !rec.flag.IsValid()) continue;
        if (rec.lastOwnerIdx != ownerIdx) continue;
        // Only consider dropped flags (owner is null)
        local c = flagspawn._FindCarrier(rec.flag);
        if (c) continue;
        local o = flagspawn._GetOrigin(rec.flag);
        local dx = o.x - pos.x;
        local dy = o.y - pos.y;
        local dz = o.z - pos.z;
        local d = dx*dx + dy*dy + dz*dz;
        if (d < bestD) { bestD = d; best = rec; }
    }
    if (best && bestD <= (maxDist*maxDist)) return best;
    return null;
};

flagspawn._DoPinata <- function(ply) {
    if (!ply || !ply.IsValid()) return;
    if (!flagspawn.CFG.PINATA_ENABLED) return;

    local pos = flagspawn._GetOrigin(ply);
    local idx = ply.entindex();

    // Find the dropped "main" flag that just came out of this player.
    local rec = flagspawn._FindRecentDroppedFromOwner(idx, pos, 128.0);
    if (!rec) return;

    local V = flagspawn._ReadFlagValue(rec.flag);
    if (V <= 1) return;

    local chunks = flagspawn.CFG.PINATA_CHUNKS;
    local chunk = floor(V.tofloat() * flagspawn.CFG.PINATA_FRAC).tointeger();
    if (chunk < flagspawn.CFG.PINATA_MIN_CHUNK) chunk = flagspawn.CFG.PINATA_MIN_CHUNK;
    if (chunk > (V - 1)) chunk = V - 1;
    // ensure we can spawn N chunks while leaving at least 1 on the main flag
    if (chunk * chunks > (V - 1)) {
        chunk = floor((V - 1).tofloat() / chunks.tofloat()).tointeger();
        if (chunk < 1) return;
    }

    local total = chunk * chunks;
    local remainder = V - total;
    if (remainder < 1) remainder = 1;

    // Set main dropped flag to remainder
    rec.value = remainder;
    flagspawn._WriteFlagValue(rec.flag, remainder);
    flagspawn._ApplyBodygroupsBoth(rec.flag, rec.pkg.prop, remainder);

    // Spawn chunk flags
    local vals = [];
    for (local i = 0; i < chunks; i++) vals.append(chunk);
    flagspawn._DynSpawnBlu(vals, pos, flagspawn.CFG.PINATA_SPAWN_RADIUS, "pinata");

    // Optional remainder text (short)
    flagspawn._SpawnWorldText(Vector(pos.x, pos.y, pos.z + 64.0), "REMAINDER: " + remainder, flagspawn.CFG.PINATA_TEXT_SECONDS);
};

flagspawn._DoDamageChunk <- function(ply) {
    if (!ply || !ply.IsValid()) return;
    if (!flagspawn.CFG.DAMAGE_CHUNKS_ENABLED) return;

    local idxStr = ply.entindex().tostring();
    local now = flagspawn._Now();
    if (idxStr in flagspawn.State.LastChunkAt) {
        if (now - flagspawn.State.LastChunkAt[idxStr] < flagspawn.CFG.DAMAGE_CHUNK_COOLDOWN) return;
    }
    flagspawn.State.LastChunkAt[idxStr] <- now;

    local rec = flagspawn._FindRecByCarrier(ply);
    if (!rec) return;

    local V = flagspawn._ReadFlagValue(rec.flag);
    if (V <= 1) return;

    local chunk = floor(V.tofloat() * flagspawn.CFG.DAMAGE_CHUNK_FRAC).tointeger();
    if (chunk < flagspawn.CFG.DAMAGE_CHUNK_MIN) chunk = flagspawn.CFG.DAMAGE_CHUNK_MIN;
    if (chunk > (V - 1)) chunk = V - 1;
    if (chunk <= 0) return;

    local newV = V - chunk;
    if (newV < 1) newV = 1;

    rec.value = newV;
    flagspawn._WriteFlagValue(rec.flag, newV);
    flagspawn._ApplyBodygroupsBoth(rec.flag, rec.pkg.prop, newV);

    local pos = flagspawn._GetOrigin(ply);
    flagspawn._DynSpawnBlu([chunk], pos, 32.0, "damage");
};

// logic_eventlistener: player_death (FetchEventData=1) -> CallScriptFunction FS_OnPlayerDeath
function FS_OnPlayerDeath() {
    flagspawn.Init();
    local ed = null; try { ed = event_data; } catch(_e0) { ed = null; }
    if (ed == null) return;

    local uid = 0; try { uid = ed.userid; } catch(_e1) { uid = 0; }
    local ply = null;
    try { ply = GetPlayerFromUserID(uid); } catch(_e2) { ply = null; }
    if (!ply) {
        local ei = 0; try { ei = ed.entindex; } catch(_e3) { ei = 0; }
        if (ei > 0) ply = flagspawn._HFromIdx(ei);
    }
    if (!ply || !ply.IsValid()) return;

    // Delay a tick so the PD drop exists and is registered
    flagspawn._CallLater(0.05, "flagspawn._DoPinata(EntIndexToHScript(" + ply.entindex() + "))");
}

// logic_eventlistener: player_hurt (FetchEventData=1) -> CallScriptFunction FS_OnPlayerHurt
function FS_OnPlayerHurt() {
    flagspawn.Init();
    local ed = null; try { ed = event_data; } catch(_e0) { ed = null; }
    if (ed == null) return;

    local uid = 0; try { uid = ed.userid; } catch(_e1) { uid = 0; }
    local ply = null;
    try { ply = GetPlayerFromUserID(uid); } catch(_e2) { ply = null; }
    if (!ply) {
        local ei = 0; try { ei = ed.entindex; } catch(_e3) { ei = 0; }
        if (ei > 0) ply = flagspawn._HFromIdx(ei);
    }
    if (!ply || !ply.IsValid()) return;

    flagspawn._DoDamageChunk(ply);
}

// ------------------------------
// Debug
// ------------------------------
function FS_DbgPrintPkgs() {
    printl("[FS] --- Pkgs " + flagspawn.State.Flags.len() + " ---");
    foreach (k, rec in flagspawn.State.Flags) {
        local nm = ""; try { nm = rec.flag.GetName(); } catch(_e) { nm = ""; }
        printl("  " + k + " " + nm + " mode=" + rec.mode + " val=" + rec.value +
            " prop=" + (rec.pkg.prop && rec.pkg.prop.IsValid()) +
            " follow=" + (rec.pkg.follow && rec.pkg.follow.IsValid()) +
            " glow=" + (rec.pkg.glow && rec.pkg.glow.IsValid()));
    }
}

flagspawn.Init();
