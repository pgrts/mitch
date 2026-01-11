// ------------------------------------------------------------
// Flag visual proxy (prop_dynamic parented to item_teamflag)
// ------------------------------------------------------------
::flagspawn.FLAG_VISUAL_ENABLED <- true;

// Your thin “2D” meter model (the one that renders fine as prop_dynamic)
::flagspawn.FLAG_VISUAL_MODEL <- "models/props_custom/fs_meter/fs_meter.mdl";

// Local offset from the flag origin (tweak if you want it higher/lower)
::flagspawn.FLAG_VISUAL_LOCAL_OFFSET <- Vector(0, 0, 0);

// If you want team-colored glow:
::flagspawn.FLAG_GLOWCOLOR_RED <- "255 64 64";
::flagspawn.FLAG_GLOWCOLOR_BLU <- "64 128 255";
::flagspawn.FLAG_GLOWCOLOR_NEUTRAL <- "255 255 255";

::flagspawn._ClampInt <- function(v, lo, hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
};

::flagspawn._HideFlagModel <- function(flag) {
    if (!flag) return;
    // Prefer EF_NODRAW (0x20). Some entities don’t expose AddEffects safely, so wrap in try.
    try { flag.AddEffects(32); } catch(e) {}
    // Extra belt+suspenders: renderamt 0 sometimes helps if effects fails.
    try { flag.__KeyValueFromInt("rendermode", 10); } catch(e2) {}   // kRenderTransAlpha
    try { flag.__KeyValueFromInt("renderamt", 0); } catch(e3) {}
};

::flagspawn._GlowColorForFlag <- function(flag) {
    local t = 0;
    try { t = flag.GetTeam(); } catch(e) { t = 0; }
    if (t == ::flagspawn.TEAM_RED) return ::flagspawn.FLAG_GLOWCOLOR_RED;
    if (t == ::flagspawn.TEAM_BLU) return ::flagspawn.FLAG_GLOWCOLOR_BLU;
    return ::flagspawn.FLAG_GLOWCOLOR_NEUTRAL;
};

// Store per-flag handles in the flag’s script scope so it survives arrays/maps.
::flagspawn._GetFlagScope <- function(flag) {
    try { flag.ValidateScriptScope(); } catch(e) {}
    local ss = null;
    try { ss = flag.GetScriptScope(); } catch(e2) { ss = null; }
    return ss;
};

::flagspawn._EnsureFlagVisual <- function(flag) {
    if (!::flagspawn.FLAG_VISUAL_ENABLED || !flag) return;

    local ss = ::flagspawn._GetFlagScope(flag);
    if (!ss) return;

    // If we already have a visual and it still exists, just update it.
    if ("fs_vis_eidx" in ss) {
        local vis = null;
        try { vis = EntIndexToHScript(ss.fs_vis_eidx); } catch(e0) { vis = null; }
        if (vis) {
            ::flagspawn._UpdateFlagVisual(flag, vis);
            return;
        }
    }

    // Create the prop_dynamic proxy.
    local vis2 = Entities.CreateByClassname("prop_dynamic");
    if (!vis2) return;

    local name = "fs_flagvis_" + flag.entindex();
    try { vis2.__KeyValueFromString("targetname", name); } catch(e1) {}
    try { vis2.__KeyValueFromString("model", ::flagspawn.FLAG_VISUAL_MODEL); } catch(e2) {}
    try { vis2.__KeyValueFromInt("solid", 0); } catch(e3) {}
    try { vis2.__KeyValueFromInt("disableshadows", 1); } catch(e4) {}

    // Parent to the flag so it follows PD carry/merge behavior.
    try { vis2.SetParent(flag, ""); } catch(e5) {}
    try { vis2.SetLocalOrigin(::flagspawn.FLAG_VISUAL_LOCAL_OFFSET); } catch(e6) {}

    // Hide the real flag model (we only want the proxy visible).
    ::flagspawn._HideFlagModel(flag);

    // Make it glow (tf_glow targets by name).
    local g = Entities.CreateByClassname("tf_glow");
    if (g) {
        try { g.__KeyValueFromString("target", name); } catch(e7) {}
        try { g.__KeyValueFromInt("mode", 0); } catch(e8) {}
        try { g.__KeyValueFromString("glowcolor", ::flagspawn._GlowColorForFlag(flag)); } catch(e9) {}
        ss.fs_glow_eidx <- g.entindex();
    }

    ss.fs_vis_eidx <- vis2.entindex();

    ::flagspawn._UpdateFlagVisual(flag, vis2);
};

::flagspawn._UpdateFlagVisual <- function(flag, vis) {
    if (!flag || !vis) return;

    local v = ::flagspawn._GetFlagPointsValue(flag);
    v = ::flagspawn._ClampInt(v, 0, 100);

    // cache last value so we don’t spam EntFire every think
    local ss = ::flagspawn._GetFlagScope(flag);
    if (ss) {
        if ("fs_vis_lastv" in ss && ss.fs_vis_lastv == v) return;
        ss.fs_vis_lastv <- v;
    }

    // Your model uses bodygroup 0 for 0..100 fill states.【turn7file0†L10-L13】
    // EntFire is the safest universal way to drive bodygroups in TF2 VScript.
    try { EntFireByHandle(vis, "SetBodyGroup", "0 " + v, 0.0, null, null); } catch(e) {}

    // Keep the flag itself hidden in case PD re-enables drawing.
    ::flagspawn._HideFlagModel(flag);
};

::flagspawn._ReconcileFlagVisuals <- function() {
    if (!::flagspawn.FLAG_VISUAL_ENABLED) return;

    local f = null;
    while ((f = Entities.FindByClassname(f, "item_teamflag")) != null) {
        // Only create visuals for “active” flags that have a PointsValue we care about.
        // (If you want *all* flags in the world to get a proxy, remove this guard.)
        local v = ::flagspawn._GetFlagPointsValue(f);
        if (v > 0) ::flagspawn._EnsureFlagVisual(f);
    }
};
