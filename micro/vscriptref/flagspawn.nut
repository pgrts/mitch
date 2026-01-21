local rt=getroottable();
if(!("flagspawn" in rt) || typeof rt.flagspawn != "table") rt.flagspawn <- {};

IncludeScript("flagspawn/cfg", rt);
IncludeScript("flagspawn/core", rt);
IncludeScript("flagspawn/spw", rt);
IncludeScript("flagspawn/eco", rt);
IncludeScript("flagspawn/dmg", rt);

rt.flagspawn.Init();

// ---------------- Hammer entry points ----------------

function FS_OnSpawnerTouchBlu(){ rt.flagspawn.OnSpawnerTouch(3, activator); }
function FS_OnSpawnerTouchRed(){ rt.flagspawn.OnSpawnerTouch(2, activator); }
function FS_OnMakerSpawned(){ rt.flagspawn.OnMakerSpawned(caller); }

// Direct flag lifecycle (caller MUST be the item_teamflag)
function FS_Direct_Pickup(){ if("DirectPickup" in rt.flagspawn) rt.flagspawn.DirectPickup(caller, activator); }
function FS_Direct_Drop(){ if("DirectDrop" in rt.flagspawn) rt.flagspawn.DirectDrop(caller, activator); }
function FS_Direct_Return(){ if("DirectReturn" in rt.flagspawn) rt.flagspawn.DirectReturn(caller, activator); }
function FS_Direct_Refund(){ if("DirectReturn" in rt.flagspawn) rt.flagspawn.DirectReturn(caller, activator); }
function FS_Direct_Capture(){ if("DirectCapture" in rt.flagspawn) rt.flagspawn.DirectCapture(caller, activator); }

// GameEvent listeners (these are optional; only call if module defines them)
function FS_OnPlayerHurtEvent(){ if("OnPlayerHurtEvent" in rt.flagspawn) rt.flagspawn.OnPlayerHurtEvent(); }
function FS_OnPlayerDeathEvent(){ if("OnPlayerDeathEvent" in rt.flagspawn) rt.flagspawn.OnPlayerDeathEvent(); }

// Your listener name in fs3_test.vmf is FS_OnPlayerSpawn_Event (keep both names just in case)
function FS_OnPlayerSpawn_Event(){ if("OnPlayerSpawnEvent" in rt.flagspawn) rt.flagspawn.OnPlayerSpawnEvent(); }
function FS_OnPlayerSpawnEvent(){ if("OnPlayerSpawnEvent" in rt.flagspawn) rt.flagspawn.OnPlayerSpawnEvent(); }

// ---------------- Relay helpers (fs3_test_relay.vmf) ----------------
// NOTE: logic_relay becomes the caller, so we recover the flag by suffix.

function _FS_FindFlagBySuffix(prefix, relayEnt)
{
    if (relayEnt == null) return null;

    local nm = "";
    try { nm = relayEnt.GetName(); } catch(_e) {}

    local amp = nm.find("&");
    if (amp == null || amp < 0) return null;

    local suf = nm.slice(amp);
    return Entities.FindByName(null, prefix + suf);
}

function FS_Relay_PickupBlu()
{
    local flagEnt = _FS_FindFlagBySuffix("bluflag", caller);
    if (flagEnt == null) return;
    if ("DirectPickup" in rt.flagspawn) rt.flagspawn.DirectPickup(flagEnt, activator);
}

function FS_Relay_DropBlu()
{
    local flagEnt = _FS_FindFlagBySuffix("bluflag", caller);
    if (flagEnt == null) return;
    if ("DirectDrop" in rt.flagspawn) rt.flagspawn.DirectDrop(flagEnt, activator);
}

function FS_Relay_ReturnBlu()
{
    local flagEnt = _FS_FindFlagBySuffix("bluflag", caller);
    if (flagEnt == null) return;
    if ("DirectReturn" in rt.flagspawn) rt.flagspawn.DirectReturn(flagEnt, activator);
}

function FS_Relay_CaptureBlu()
{
    local flagEnt = _FS_FindFlagBySuffix("bluflag", caller);
    if (flagEnt == null) return;
    if ("DirectCapture" in rt.flagspawn) rt.flagspawn.DirectCapture(flagEnt, activator);
}
