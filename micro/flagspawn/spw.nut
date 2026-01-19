// flagspawn/spw.nut (microservices v7)
// Spawner touch -> queue -> maker spawned (with TF2-correct OnEntitySpawned semantics).

local rt = getroottable();
local FS = rt.flagspawn;

FS._GetPlayerTeam <- function(ply) {
    local t = 0;
    try { t = ply.GetTeam(); } catch (_e) { t = 0; }
    return t;
};

FS._GetPlayerClass <- function(ply) {
    local cls = 0;
    try { cls = ply.GetPlayerClass(); } catch (_e) { cls = 0; }
    return cls;
};

// Sum the value of all tracked flags currently owned by this player.
FS._CarryValue <- function(ply) {
    if (!FS.IsValid(ply)) return 0;
    local total = 0;
    foreach (_suf, pkg in FS.State.Flags) {
        if (!pkg || !FS.IsValid(pkg.flag)) continue;
        local owner = FS._GetFlagOwner(pkg.flag);
        if (owner != ply) continue;
        total += FS._GetPointValue(pkg.flag);
        if (total >= FS.CFG.CARRY_CAP) return FS.CFG.CARRY_CAP;
    }
    return total;
};

FS._FindNewestFlagNearMaker <- function(maker, team) {
    if (!FS.IsValid(maker) || !FS._TeamOK(team)) return null;

    local makerOrg = FS._Origin(maker);
    local prefix = FS.CFG.FLAG_BASE[team];
    if (!prefix) return null;

    local best = null;
    local bestDist = 999999.0;
    local ent = null;

    while ((ent = Entities.FindByClassnameWithin(ent, "item_teamflag", makerOrg, FS.CFG.SPAWN_SCAN_RADIUS)) != null) {
        if (!FS.IsValid(ent)) continue;
        if (FS._FindPkgByFlag(ent) != null) continue;

        local nm = FS._EntName(ent);
        if (!FS._StartsWith(nm, prefix)) continue;

        local d = (FS._Origin(ent) - makerOrg).Length();
        if (d < bestDist) { best = ent; bestDist = d; }
    }
    return best;
};

FS._QueueSpawn <- function(team, val, poolConsume, orgOrNull, src, useDynMaker) {
    if (!FS._TeamOK(team)) return false;
    local mkName = useDynMaker ? FS.CFG.MAKER_DYN[team] : FS.CFG.MAKER[team];
    local maker = FS._Find(mkName);
    if (!FS.IsValid(maker) && useDynMaker) maker = FS._Find(FS.CFG.MAKER[team]);
    if (!FS.IsValid(maker)) return false;

    // [team, value, poolConsume, originOrNull, src]
    FS.State.Q.append([team, val, poolConsume, orgOrNull, src]);
    FS._TryFire(maker, "ForceSpawn", "", 0.0, null, null);
    return true;
};

FS.OnSpawnerTouch <- function(team, ply) {
    if (!FS._TeamOK(team) || !FS.IsValid(ply)) return;
    if (FS._GetPlayerTeam(ply) != team) return;

    local pid = FS._EntIndex(ply);
    if (pid <= 0) return;

    // Once per life (reset on spawn + capture)
    if (pid in FS.State.UsedSpawn && FS.State.UsedSpawn[pid]) return;

    // Spawner stock gate (chunks/pinata bypass this entirely)
    if (FS._StockRemaining(team) <= 0) return;

    // Carry cap gate
    local carry = FS._CarryValue(ply);
    local carryLeft = FS.CFG.CARRY_CAP - carry;
    if (carryLeft <= 0) return;

    // Pool portion (20% of current pool)
    local pool = FS.State.Pool[team];
    if (pool < 0) pool = 0;
    local poolPortion = floor(pool.tofloat() / FS.CFG.POOL_SHARE_DEN.tofloat());
    if (poolPortion > FS.CFG.VALUE_CAP) poolPortion = FS.CFG.VALUE_CAP;

    // Class bonus
    local cls = FS._GetPlayerClass(ply);
    local bonus = (cls in FS.CFG.CLASS_BONUS) ? FS.CFG.CLASS_BONUS[cls] : 0;

    // Dispense = pool/5 + classBonus, then clamps
    local val = poolPortion + bonus;
    val = FS._ClampI(val, FS.CFG.SPAWN_MIN, FS.CFG.VALUE_CAP);
    if (val > carryLeft) val = carryLeft;
    if (val < 1) return;

    local poolConsume = poolPortion;
    if ("POOL_CONSUME_CLASS_BONUS" in FS.CFG && FS.CFG.POOL_CONSUME_CLASS_BONUS) poolConsume = poolPortion + bonus;

    if (!FS._QueueSpawn(team, val, poolConsume, null, FS.SRC_SPAWNER, false)) return;

    FS.State.UsedSpawn[pid] <- true;
    FS._UpdateStockText(team);
    FS._UpdateLockSprite(team);
};

// env_entity_maker OnEntitySpawned:
// In TF2, !activator = !caller = !self (the maker). You do NOT get the spawned handle directly.
FS.OnMakerSpawned <- function(maker) {
    if (!FS.IsValid(maker)) return;
    if (FS.State.Q.len() <= 0) return;

    // Pop next spawn context (FIFO)
    local ctx = FS.State.Q[0];
    FS.State.Q.remove(0);

    local team = ctx[0];
    local val = ctx[1];
    local poolConsume = ctx[2];
    local orgOrNull = ctx[3];
    local src = ctx[4];

    if (!FS._TeamOK(team)) return;

    local flag = FS._FindNewestFlagNearMaker(maker, team);
    if (!FS.IsValid(flag)) return; // spawn failed or scan radius too small

    // Set explicit value (never trust template defaults)
    if (val < 1) val = 1;
    if (val > FS.CFG.VALUE_CAP) val = FS.CFG.VALUE_CAP;
    FS._SetPointValue(flag, val);

    // Optional teleport (chunks / pinata)
    if (orgOrNull != null) {
        try { flag.SetOrigin(orgOrNull); } catch (_e) {}
    }

    // Consume pool only for the spawner pool portion
    FS._ConsumePool(team, poolConsume);

    // Register and apply visuals (prop/flag draw swap, glow fix)
    FS._RegisterFlag(flag, team, src);

    FS._UpdateUI();
};
