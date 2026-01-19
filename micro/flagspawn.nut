local rt=getroottable();
if(!("flagspawn" in rt)||typeof rt.flagspawn!="table")rt.flagspawn<-{};
IncludeScript("flagspawn/cfg",rt);
IncludeScript("flagspawn/core",rt);
IncludeScript("flagspawn/spw",rt);
IncludeScript("flagspawn/eco",rt);
IncludeScript("flagspawn/dmg",rt);
rt.flagspawn.Init();
function FS_OnSpawnerTouchBlu(){rt.flagspawn.OnSpawnerTouch(3,activator);}
function FS_OnSpawnerTouchRed(){rt.flagspawn.OnSpawnerTouch(2,activator);}
function FS_OnMakerSpawned(){rt.flagspawn.OnMakerSpawned(caller);}
function FS_Direct_Pickup(){rt.flagspawn.OnFlagPickup(caller,activator);}
function FS_Direct_Drop(){rt.flagspawn.OnFlagDrop(caller,activator);}
function FS_Direct_Return(){rt.flagspawn.OnFlagReturn(caller,activator);}
function FS_Direct_Refund(){rt.flagspawn.OnFlagReturn(caller,activator);}
function FS_Direct_Capture(){rt.flagspawn.OnFlagCapture(caller,activator);}
function FS_OnPlayerHurtEvent(){rt.flagspawn.OnPlayerHurtEvent();}
function FS_OnPlayerDeathEvent(){rt.flagspawn.OnPlayerDeathEvent();}
function FS_OnPlayerSpawnEvent(){rt.flagspawn.OnPlayerSpawnEvent();}
// Optional: some VMFs still wire flag_listener -> FS_OnFlagEvent().
// teamplay_flag_event cannot identify WHICH flag, so this is only a safe pulse.
function FS_OnFlagEvent(){try{rt.flagspawn.Pulse();}catch(_e){}}
