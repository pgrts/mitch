local rt=getroottable();local FS=rt.flagspawn;

// ----------------------------------------------------------------------------
// Damage + Death microservice
//  - Chunks bypass spawner stock limit (do NOT touch FS.S.N / FS.S.A)
//  - Uses the SAME maker output hook (FS_OnMakerSpawned) with a queue ctx:
//      [team,val,spend,pid,originOrNull,isSpawner]
// ----------------------------------------------------------------------------

FS.DmgSpawnChunk<-function(t,val,org){
    if(!FS.Tok(t) || val<1) return;
    local mk=FS.Mk(t,true);
    if(!FS.Ok(mk)) return;
    // Queue context: spend=0, pid=0, origin=org, isSpawner=0
    FS.S.Q.append([t,val,0,0,org,0]);
    EntFireByHandle(mk,"ForceSpawn","",0.0,null,null);
}

FS.DmgFindCarriedSpawnerFlag<-function(ply){
    if(!FS.Ok(ply)) return null;
    if(!("SF" in FS.S)) return null;
    local pid=0;try{pid=ply.GetEntityIndex();}catch(_e){pid=0;}
    if(pid<=0) return null;
    foreach(_suf, rec in FS.S.SF){
        if(!("c" in rec) || rec.c!=pid) continue;
        local h=("h" in rec)?rec.h:null;
        if(FS.Ok(h)) return h;
    }
    return null;
}

FS.DmgFindDroppedSpawnerFlagNear<-function(org, rad){
    if(rad<=0) rad=128.0;
    local best=null;
    local bestV=-1;
    local ent=null;
    while((ent=Entities.FindByClassnameWithin(ent,"item_teamflag",org,rad))!=null){
        if(!FS.Ok(ent)) continue;
        // only flags we spawned (script scope marker)
        local isSpawner=false;
        try{
            ent.ValidateScriptScope();
            local scp=ent.GetScriptScope();
            if(scp!=null && ("fs_spawner" in scp) && scp.fs_spawner==1) isSpawner=true;
        }catch(_e){}
        if(!isSpawner) continue;
        local v=FS.Gv(ent);
        if(v>bestV){ best=ent; bestV=v; }
    }
    return best;
}

// Kill the built-in PD "1 point on death" drop without ever setting pointValue to 0.
FS.DmgKillPDDeathPointNear<-function(org, rad){
    if(rad<=0) rad=128.0;
    local ent=null;
    while((ent=Entities.FindByClassnameWithin(ent,"item_teamflag",org,rad))!=null){
        if(!FS.Ok(ent)) continue;
        if(FS.Gv(ent)!=1) continue;

        // Don't kill our spawner flags (they have fs_spawner marker)
        local ours=false;
        try{
            ent.ValidateScriptScope();
            local scp=ent.GetScriptScope();
            if(scp!=null && ("fs_spawner" in scp) && scp.fs_spawner==1) ours=true;
        }catch(_e){}
        if(ours) continue;

        try{ ent.Kill(); }catch(_e2){}
    }
}

// enemy-only (unless DBG_SELFHURT=1 so you can test with hurtme)
FS.OnPlayerHurtEvent<-function(){
if(!("event_data" in rt))return;
local e=rt.event_data;
if(!("userid" in e))return;

local victim=GetPlayerFromUserID(e.userid);
if(!FS.Ok(victim))return;

if(!("attacker" in e))return;
if(e.attacker<=0)return;
local attacker=GetPlayerFromUserID(e.attacker);
if(!FS.Ok(attacker))return;

local vt=0,at=0;
try{vt=victim.GetTeam();}catch(_e0){}
try{at=attacker.GetTeam();}catch(_e1){}
if(vt==at){
    if(!("DBG_SELFHURT" in FS.CFG) || FS.CFG.DBG_SELFHURT==0) return;
}

local flag=FS.DmgFindCarriedSpawnerFlag(victim);
if(!FS.Ok(flag))return;
local V=FS.Gv(flag);
if(V<=2){
    // too small to split cleanly; destroy the flag instead of producing 0-value artifacts
    try{ flag.Kill(); }catch(_eKill){}
    return;
}

// Damage: destroy 10% (min1) + spawn 20% chunk (min1), keep >=1
local des=floor(V*0.10); if(des<1)des=1;
local chunk=floor(V*0.20); if(chunk<1)chunk=1;
local newV=V-des-chunk;
if(newV<1){
    try{ flag.Kill(); }catch(_eKill2){}
    return;
}

// reduce the carried flag directly (never set to 0)
FS.Sv(flag,newV);
if("SpwSetValue" in FS) FS.SpwSetValue(flag,newV);

local t=vt;
if(!FS.Tok(t))return;

local o=FS.Op(victim)+Vector(RandomInt(-24,24),RandomInt(-24,24),8);
FS.DmgSpawnChunk(t,chunk,o);
}

FS.OnPlayerDeathEvent<-function(){
if(!("event_data" in rt))return;
local e=rt.event_data;
if(!("userid" in e))return;

local v=GetPlayerFromUserID(e.userid);
if(!FS.Ok(v))return;

local org=FS.Op(v);

// On death PD drops the flag first, so we find the dropped spawner flag near the corpse.
local flag=FS.DmgFindDroppedSpawnerFlagNear(org,160.0);
if(!FS.Ok(flag)){
    // still kill PD 1-point drop
    local s=Entities.FindByName(null,FS.CFG.SCRIPTER_NAME);
    if(FS.Ok(s)){
        local cmd=format("getroottable().flagspawn.DmgKillPDDeathPointNear(Vector(%f,%f,%f),160.0)",org.x,org.y,org.z);
        EntFireByHandle(s,"RunScriptCode",cmd,0.05,null,null);
    }
    return;
}

local V=FS.Gv(flag);
if(V<=2){
    try{ flag.Kill(); }catch(_eKill3){}
    local s2=Entities.FindByName(null,FS.CFG.SCRIPTER_NAME);
    if(FS.Ok(s2)){
        local cmd2=format("getroottable().flagspawn.DmgKillPDDeathPointNear(Vector(%f,%f,%f),160.0)",org.x,org.y,org.z);
        EntFireByHandle(s2,"RunScriptCode",cmd2,0.05,null,null);
    }
    return;
}

// Death: destroy 20% to grave, drop up to 4 shards of 20%
local grave=floor(V*0.20); if(grave<1)grave=1;
local shard=floor(V*0.20); if(shard<1)shard=1;

local rem=V-grave;
if(rem<0)rem=0;
local cnt=0;
while(cnt<4 && rem>=shard){ rem-=shard; cnt+=1; }

local t=0; try{t=v.GetTeam();}catch(_e2){}
if(!FS.Tok(t))t=3;

for(local i=0;i<cnt;i++){
local off=Vector(RandomInt(-36,36),RandomInt(-36,36),8);
FS.DmgSpawnChunk(t,shard,org+off);
}

// Remainder SFX if we destroyed extra beyond the grave tax
// destroyed = grave + rem
if(rem>0){
    try { EmitSoundEx({ sound_name = FS.CFG.SOUND_REMAINDER, origin = org, volume = 1.0, pitch = 100 }); } catch(_e3) {}
}

// Kill the original dropped spawner flag (prevents merge weirdness and removes value cleanly)
try{ flag.Kill(); }catch(_e4){}

// Kill the built-in PD 1-point death drop (scheduled slightly later)
local scr=Entities.FindByName(null,FS.CFG.SCRIPTER_NAME);
if(FS.Ok(scr)){
    local cmd3=format("getroottable().flagspawn.DmgKillPDDeathPointNear(Vector(%f,%f,%f),160.0)",org.x,org.y,org.z);
    EntFireByHandle(scr,"RunScriptCode",cmd3,0.05,null,null);
}
}
