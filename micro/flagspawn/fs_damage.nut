// flagspawn/fs_damage.nut
// Damage chunking + death pinata.
// Requires logic_eventlistener with FetchEventData=1 and CallScriptFunction.

local rt = getroottable();
local FS = rt.flagspawn;

FS._SpawnChunk <- function(team, val, origin) {
    if (!FS._TeamOK(team) || val < 1) return;
    local mk = FS._TryMaker(team, true);
    if (!FS.IsValid(mk)) return;

    FS.State.Pending[team] = FS.State.Pending[team] + 1;
    FS.State.Q.append([team, val, 0, 0, origin]);
    mk.ForceSpawn();

    FS._UpdateStockText(team);
}

// player_hurt
FS.OnPlayerHurtEvent <- function() {
    if (!('event_data' in rt)) return;
    local e = rt.event_data;
    if (!('userid' in e)) return;

    local victim = GetPlayerFromUserID(e.userid);
    if (!FS.IsValid(victim)) return;

    local V = FS._CarryGet(victim);
    if (V <= 1) return;

    // Damage: destroy 10% (min 1), spawn 20% chunk (min 1), keep >= 1
    local destroy = floor(V * 0.10);
    if (destroy < 1) destroy = 1;

    local chunk = floor(V * 0.20);
    if (chunk < 1) chunk = 1;

    if ((V - destroy - chunk) < 1) return;

    FS._CarrySet(victim, V - destroy - chunk);

    local team = 0;
    try { team = victim.GetTeam(); } catch(_e2) { team = 0; }
    if (!FS._TeamOK(team)) return;

    local o = FS._OriginPlayerSafe(victim);
    o = o + Vector(RandomInt(-24, 24), RandomInt(-24, 24), 8);

    FS._SpawnChunk(team, chunk, o);
}

// player_death
FS.OnPlayerDeathEvent <- function() {
    if (!('event_data' in rt)) return;
    local e = rt.event_data;
    if (!('userid' in e)) return;

    local victim = GetPlayerFromUserID(e.userid);
    if (!FS.IsValid(victim)) return;

    local V = FS._CarryGet(victim);
    if (V <= 0) return;

    // Death: destroy 20% to the grave (min 1)
    local grave = floor(V * 0.20);
    if (grave < 1) grave = 1;

    local R = V - grave;
    if (R < 0) R = 0;

    // Shard size = 20% of original (min 1)
    local shard = floor(V * 0.20);
    if (shard < 1) shard = 1;

    // Drop up to 4 shards; remainder destroyed
    local dropCount = floor(R / shard);
    if (dropCount > 4) dropCount = 4;
    if (dropCount < 0) dropCount = 0;

    local team = 0;
    try { team = victim.GetTeam(); } catch(_e2) { team = 0; }
    if (!FS._TeamOK(team)) team = FS.CFG.TEAM_BLU;

    local o = FS._OriginPlayerSafe(victim);

    for (local i = 0; i < dropCount; i++) {
        local off = Vector(RandomInt(-36, 36), RandomInt(-36, 36), 8);
        FS._SpawnChunk(team, shard, o + off);
    }

    // Victim loses everything (grave + dropped + remainder are removed)
    FS._CarrySet(victim, 0);
}
