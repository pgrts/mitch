local rt=getroottable();
if(!("flagspawn" in rt)||typeof rt.flagspawn!="table")rt.flagspawn<-{};

IncludeScript("flagspawn/cfg",rt);
IncludeScript("flagspawn/core",rt);
IncludeScript("flagspawn/spw",rt);
IncludeScript("flagspawn/eco",rt);
IncludeScript("flagspawn/dmg",rt);

rt.flagspawn.Init();

// spawner trigger touch
function FS_OnSpawnerTouchBlu(){ rt.flagspawn.OnSpawnerTouch(3,activator); }
function FS_OnSpawnerTouchRed(){ rt.flagspawn.OnSpawnerTouch(2,activator); }

// maker OnEntitySpawned: spawned ent is usually activator, sometimes caller
function FS_OnMakerSpawned(){
    local spawnedEnt=null;
    try{spawnedEnt=activator;}catch(_e){}
    if(spawnedEnt==null){try{spawnedEnt=caller;}catch(_e2){}}
    if(spawnedEnt!=null && spawnedEnt.IsValid()) rt.flagspawn.OnMakerSpawned(spawnedEnt);
}

// item_teamflag direct outputs -> THESE NAMES EXIST in eco.nut
function FS_Direct_Pickup(){  rt.flagspawn.DirectPickup(caller,activator); }
function FS_Direct_Drop(){    rt.flagspawn.DirectDrop(caller,activator); }
function FS_Direct_Return(){  rt.flagspawn.DirectReturn(caller); }
function FS_Direct_Refund(){  rt.flagspawn.DirectReturn(caller); }
function FS_Direct_Capture(){ rt.flagspawn.DirectCapture(caller); }

// logic_eventlistener events (these exist in dmg.nut)
function FS_OnPlayerHurtEvent(){  rt.flagspawn.OnPlayerHurtEvent(); }
function FS_OnPlayerDeathEvent(){ rt.flagspawn.OnPlayerDeathEvent(); }

// no spawn handler in your modules right now, so make it safe/no-op
function FS_OnPlayerSpawnEvent(){ if("OnPlayerSpawnEvent" in rt.flagspawn) rt.flagspawn.OnPlayerSpawnEvent(); }
