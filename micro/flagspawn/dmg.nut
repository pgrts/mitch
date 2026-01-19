// flagspawn/dmg.nut (microservices v7)
// Damage chunk + death pinata driven by *flag pointvalue*, not a global score ledger.

local rt = getroottable();
local FS = rt.flagspawn;

FS._PlayRemainderSFX <- function(origin, entForFallback = null) {
    local snd = FS.CFG.SOUND_REMAINDER;
    if (snd == null || snd == "") return;

    local vol = 1.0;
    local pitch = 100;
    try { vol = FS.CFG.SOUND_REMAINDER_VOL; } catch (_e0) { vol = 1.0; }
    try { pitch = FS.CFG.SOUND_REMAINDER_PITCH; } catch (_e1) { pitch = 100; }

    // Prefer world-position sound
    try {
        EmitSoundEx({ sound_name = snd, origin = origin, volume = vol, pitch = pitch });
        return;
    } catch (_e2) {}

    // Fallback: attach to an entity
    if (FS.IsValid(entForFallback)) {
        try { EmitSoundOn(snd, entForFallback); } catch (_e3) {}
    }
};

FS._FindCarriedPkgs <- function(ply) {
    local arr = [];
    if (!FS.IsValid(ply)) return arr;
    foreach (_suf, pkg in FS.State.Flags) {
        if (!pkg || !FS.IsValid(pkg.flag)) continue;
        local owner = FS._GetFlagOwner(pkg.flag);
        if (owner == ply) arr.append(pkg);
    }
    return arr;
};

FS._FindBestCarriedPkg <- function(ply) {
    local best = null;
    local bestV = 0;
    foreach (pkg in FS._FindCarriedPkgs(ply)) {
        local v = FS._GetPointValue(pkg.flag);
        if (v > bestV) { bestV = v; best = pkg; }
    }
    return best;
};

FS._SpawnChunkFlag <- function(team, val, origin) {
    if (!FS._TeamOK(team)) return false;
    if (val < 1) return false;
    return FS._QueueSpawn(team, val, 0, origin, FS.SRC_CHUNK, true);
};

FS._DoDamageChunk <- function(victim) {
    if (!FS.IsValid(victim)) return;

    local pkg = FS._FindBestCarriedPkg(victim);
    if (!pkg || !FS.IsValid(pkg.flag)) return;

    local cur = FS._GetPointValue(pkg.flag);
    // Too small to split cleanly -> just destroy the flag (never set pointvalue to 0).
    if (cur <= FS.CFG.SMALL_FLAG_KILL_MAX) {
        FS._PkgKillAll(pkg);
        FS._UnregisterPkg(pkg);
        FS._UpdateUI();
        return;
    }

    // Damage: destroy 10% (min 1) + spawn 20% chunk (min 1) -> leave 70%
    local destroy = floor(cur.tofloat() / FS.CFG.DMG_DESTROY_DEN.tofloat());
    if (destroy < 1) destroy = 1;

    local chunk = floor(cur.tofloat() / FS.CFG.DMG_CHUNK_DEN.tofloat());
    if (chunk < 1) chunk = 1;

    // If the math would underflow (or collapse into 0), kill the flag instead.
    if ((cur - destroy - chunk) < 1) {
        FS._PkgKillAll(pkg);
        FS._UnregisterPkg(pkg);
        FS._UpdateUI();
        return;
    }

    local newVal = cur - destroy - chunk;
    if (newVal < 1) newVal = 1;

    // Update carried flag value (and both bodygroups via pkg).
    // If we'd end up carrying a 1-pointer, we just destroy the original flag.
    if (newVal <= 1) {
        FS._PkgKillAll(pkg);
        FS._UnregisterPkg(pkg);
    } else {
        FS._SetPointValue(pkg.flag, newVal);
        FS._PkgSetValue(pkg, newVal);
    }

    // Spawn the chunk near the victim (bypasses stock limit)
    local o = FS._Origin(victim) + Vector(RandomInt(-24, 24), RandomInt(-24, 24), 8);
    FS._SpawnChunkFlag(pkg.team, chunk, o);

    FS._UpdateUI();
};

// player_hurt listener (logic_eventlistener with FetchEventData=1)
FS.OnPlayerHurtEvent <- function() {
    if (!("event_data" in rt)) return;
    local e = rt.event_data;

    if (!("userid" in e)) return;
    local victim = GetPlayerFromUserID(e.userid);
    if (!FS.IsValid(victim)) return;

    // Require enemy-caused damage (default), so hurtme/world damage doesn't farm chunks.
    if (FS.CFG.DMG_REQUIRE_ENEMY) {
        if (!("attacker" in e)) return;
        if (e.attacker <= 0) return;
        local attacker = GetPlayerFromUserID(e.attacker);
        if (!FS.IsValid(attacker)) return;

        // Ignore self + friendly
        if (attacker == victim) return;
        local vt = 0; local at = 0;
        try { vt = victim.GetTeam(); } catch (_e0) { vt = 0; }
        try { at = attacker.GetTeam(); } catch (_e1) { at = 0; }
        if (vt == at) return;
    }

    local dmg = 0.0;
    try { dmg = e.damageamount.tofloat(); } catch (_e2) { dmg = 0.0; }
    if (dmg <= 0.0) return;

    local pid = FS._EntIndex(victim);
    if (pid <= 0) return;

    local acc = 0.0;
    if (pid in FS.State.DmgAcc) acc = FS.State.DmgAcc[pid];
    acc += dmg;

    local thr = FS._GetMaxHealth(victim).tofloat() * FS.CFG.DMG_THRESHOLD_PCT;
    if (thr < 1.0) thr = 1.0;

    while (acc >= thr) {
        acc -= thr;
        FS._DoDamageChunk(victim);
    }

    FS.State.DmgAcc[pid] <- acc;
};

FS._DoDeathPinataForPkg <- function(pkg, victimOrigin) {
    if (!pkg || !FS.IsValid(pkg.flag)) return;

    local total = FS._GetPointValue(pkg.flag);
    if (total <= 0) {
        FS._PkgKillAll(pkg);
        return;
    }

    // Very small flags: just destroy them on death (no 1-point shards).
    if (total <= FS.CFG.SMALL_FLAG_KILL_MAX) {
        FS._PkgKillAll(pkg);
        return;
    }

    // Death: destroy 20% to the grave (min 1)
    local grave = floor(total.tofloat() / FS.CFG.DEATH_GRAVE_DEN.tofloat());
    if (grave < 1) grave = 1;

    local rem = total - grave;
    if (rem < 0) rem = 0;

    // Shard size = 20% of original (min 1)
    local shard = floor(total.tofloat() / FS.CFG.DEATH_CHUNK_DEN.tofloat());
    if (shard < 1) shard = 1;

    // Spawn up to 4 shards; remainder destroyed
    local cnt = 0;
    if (shard > 0) cnt = floor(rem.tofloat() / shard.tofloat());
    if (cnt > FS.CFG.DEATH_MAX_CHUNKS) cnt = FS.CFG.DEATH_MAX_CHUNKS;
    if (cnt < 0) cnt = 0;

    for (local i = 0; i < cnt; i++) {
        local off = Vector(RandomInt(-36, 36), RandomInt(-36, 36), 8);
        FS._SpawnChunkFlag(pkg.team, shard, victimOrigin + off);
    }

    // Remainder SFX: play when destroyed value exceeds the grave tax (i.e., we lost a remainder piece).
    local dropped = cnt * shard;
    local destroyed = total - dropped;
    if (destroyed > grave) {
        FS._PlayRemainderSFX(victimOrigin, pkg.flag);
    }

    // Kill original (destroys grave + remainder)
    FS._PkgKillAll(pkg);
};

// player_death listener (logic_eventlistener with FetchEventData=1)
FS.OnPlayerDeathEvent <- function() {
    if (!("event_data" in rt)) return;
    local e = rt.event_data;
    if (!("userid" in e)) return;

    local victim = GetPlayerFromUserID(e.userid);
    if (!FS.IsValid(victim)) return;

    local pid = FS._EntIndex(victim);
    if (pid > 0) FS.State.DmgAcc[pid] <- 0.0;

    local vOrg = FS._Origin(victim);

    // Pinata any carried flags (spawner or chunk)
    local carried = FS._FindCarriedPkgs(victim);
    foreach (pkg in carried) {
        if (!pkg) continue;
        local suf = pkg.suffix;
        FS._DoDeathPinataForPkg(pkg, vOrg);
        FS._UnregisterPkg(pkg); // from eco.nut
    }

    // Kill PD "points on death" drop (usually 1 point) after a small delay.
    FS.State.DeathClean.append({ due = Time() + FS.CFG.DEATH_DROP_KILL_DELAY, org = vOrg });

    FS._UpdateUI();
};
