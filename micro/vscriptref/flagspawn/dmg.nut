local rt=getroottable();local FS=rt.flagspawn;

// chunks bypass spawner stock limit
FS.SpawnChunk<-function(t,val,org){
if(!FS.Tok(t)||val<1)return;
local mk=FS.Mk(t,true); if(!FS.Ok(mk))return;
FS.S.Q.append([t,val,0,org]); // isSpawner=0
EntFireByHandle(mk,"ForceSpawn","",0.0,null,null);
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
if(vt==at && FS.CFG.DBG_SELFHURT==0)return;

local V=FS.Cg(victim);
if(V<=1)return;

// Damage: destroy 10% (min1) + spawn 20% chunk (min1), keep >=1
local des=floor(V*0.10); if(des<1)des=1;
local chunk=floor(V*0.20); if(chunk<1)chunk=1;
if((V-des-chunk)<1)return;

FS.Cs(victim,V-des-chunk);

local t=vt;
if(!FS.Tok(t))return;

local o=FS.Op(victim)+Vector(RandomInt(-24,24),RandomInt(-24,24),8);
FS.SpawnChunk(t,chunk,o);
}

FS.OnPlayerDeathEvent<-function(){
if(!("event_data" in rt))return;
local e=rt.event_data;
if(!("userid" in e))return;

local v=GetPlayerFromUserID(e.userid);
if(!FS.Ok(v))return;

local V=FS.Cg(v);
if(V<=0)return;

// Death: destroy 20% to grave, drop up to 4 shards of 20%
local grave=floor(V*0.20); if(grave<1)grave=1;
local R=V-grave; if(R<0)R=0;
local shard=floor(V*0.20); if(shard<1)shard=1;

local cnt=floor(R/shard);
if(cnt>4)cnt=4;
if(cnt<0)cnt=0;

local t=0; try{t=v.GetTeam();}catch(_e2){}
if(!FS.Tok(t))t=3;

local o=FS.Op(v);
for(local i=0;i<cnt;i++){
local off=Vector(RandomInt(-36,36),RandomInt(-36,36),8);
FS.SpawnChunk(t,shard,o+off);
}

try {
    EmitSoundEx({ sound_name = FS.CFG.SOUND_REMAINDER, origin = victimOrigin, volume = 1.0, pitch = 100 });
} catch(_e) {}


// NOTE: we do NOT set any dropped flag pointValue to 0 (merging would break)
FS.Cs(v,0);
}
