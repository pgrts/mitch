// flagspawn/fs_spawner.nut
// Spawner touch -> queue -> maker spawned.

local rt = getroottable();
local FS = rt.flagspawn;

FS.OnSpawnerTouch <- function(team, ply) {
    if (!FS._TeamOK(team) || !FS.IsValid(ply)) return;

    local pid = FS._Pid(ply);
    if (pid <= 0) return;

    // One-per-life
    if (pid in FS.State.UsedSpawn && FS.State.UsedSpawn[pid]) return;

    // Stock gate (pool is NOT the gate)
    if (FS._StockRemaining(team) <= 0) return;

    // Carry cap gate
    local carry = FS._CarryGet(ply);
    local carryLeft = FS.CFG.CARRY_CAP - carry;
    if (carryLeft <= 0) return;

    // Pool portion: floor(pool / 5)
    local pool = FS.State.Pool[team];
    if (pool < 0) pool = 0;
    local poolPortion = floor(pool / 5.0);

    // Class bonus
    local cls = 0;
    try { cls = ply.GetPlayerClass(); } catch(_e) { cls = 0; }
    local bonus = (cls in FS.CFG.CLASS_BONUS) ? FS.CFG.CLASS_BONUS[cls] : 0;

    // Dispense = pool/5 + classBonus, clamped to 100 and carryLeft
    local val = poolPortion + bonus;
    val = FS._ClampI(val, FS.CFG.SPAWN_MIN, FS.CFG.VALUE_CAP);
    if (val > carryLeft) val = carryLeft;
    if (val < 1) return;

    local mk = FS._TryMaker(team, false);
    if (!FS.IsValid(mk)) return;

    FS.State.UsedSpawn[pid] <- true;
    FS.State.Pending[team] = FS.State.Pending[team] + 1;

    // Queue entry: [team, val, poolPortionToConsume, ownerEntIndex, dropOriginOrNull]
    FS.State.Q.append([team, val, poolPortion, pid, null]);
    mk.ForceSpawn();

    FS._UpdateStockText(team);
}

FS.OnMakerSpawned <- function(spawnedEnt) {
    local f = spawnedEnt;
    if (!FS.IsValid(f)) return;
    if (FS.State.Q.len() <= 0) return;

    local ctx = FS.State.Q[0];
    FS.State.Q.remove(0);

    local team = ctx[0];
    local val  = ctx[1];
    local poolPortion = ctx[2];
    local dropOrigin = ctx[4];

    if (!FS._TeamOK(team)) return;

    // Consume pool portion only on successful spawn
    FS._ConsumePool(team, poolPortion);

    // Set value explicitly (fixes "spawn 100 at start")
    FS._SetFlagValue(f, val);

    // Place if chunk spawn
    if (dropOrigin != null) {
        try { f.SetOrigin(dropOrigin); } catch(_e) {}
    }

    // bookkeeping
    FS.State.Pending[team] = FS.State.Pending[team] - 1;
    if (FS.State.Pending[team] < 0) FS.State.Pending[team] = 0;
    FS.State.Active[team] = FS.State.Active[team] + 1;

    FS._UpdateMeter(team);
    FS._UpdateStockText(team);

    // Carry ledger updates via item_teamflag OnPickup/OnDrop.
}
