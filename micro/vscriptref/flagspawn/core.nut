local rt=getroottable();local FS=rt.flagspawn;

FS.V<- "v69";

FS.S<-{
    P={ [2]=0,[3]=0 },
    A={ [2]=0,[3]=0 },
    N={ [2]=0,[3]=0 },
    Q=[],
    C={},
    U={},
    F={},
    FC={ [2]=0,[3]=0 },
    T0=Time(),
    SPW_STARTED=false
};

FS.Ok<-function(e){return e!=null && e.IsValid();}
FS.Cl<-function(x,a,b){if(x<a)return a;if(x>b)return b;return x;}
FS.Fn<-function(n){return Entities.FindByName(null,n);}
FS.Tok<-function(t){return t==2||t==3;}
FS.Pid<-function(p){return FS.Ok(p)?p.GetEntityIndex():0;}
FS.Cg<-function(p){local i=FS.Pid(p);return (i in FS.S.C)?FS.S.C[i]:0;}
FS.Cs<-function(p,v){local i=FS.Pid(p);if(i<=0)return;if(v<=0){if(i in FS.S.C)delete FS.S.C[i];}else FS.S.C[i]<-v;}

// Safe bodygroup setter (index 1 is our value group). Prefer method; fall back to input.
FS.Bg<-function(ent,idx,val){
    if(!FS.Ok(ent))return;
    try{ent.SetBodygroup(idx,val);return;}catch(_e){}
    try{EntFireByHandle(ent,"SetBodyGroup",idx.tostring()+" "+val.tostring(),0.0,null,null);}catch(_e2){}
}

FS.Rem<-function(t){
    local u=FS.S.A[t]+FS.S.N[t];
    local r=FS.CFG.LIM-u;
    return r<0?0:r;
}

FS.Utxt<-function(t){
    local nm=FS.CFG.STX[t];if(!nm)return;
    local e=FS.Fn(nm);if(!FS.Ok(e))return;
    EntFireByHandle(e,"AddOutput","message "+FS.Rem(t),0,null,null);
}

// sets ALL spawner props (..01..MC) to the same bodygroup value
FS.UmetSetAll<-function(t,bgVal){
    local pfx=FS.CFG.MPF[t];if(!pfx)return;
    bgVal=FS.Cl(bgVal,0,100);
    for(local i=1;i<=FS.CFG.MC;i++){
        local ent=FS.Fn(pfx+format("%02d",i));
        if(FS.Ok(ent))FS.Bg(ent,1,bgVal);
    }
}

// default (METER_MODE='portion_sync'): show the *next payout base portion* on ALL spawner props
// legacy (METER_MODE='pool_segments'): show total pool split across props by 100s
FS.Umet<-function(t){
    local pfx=FS.CFG.MPF[t];if(!pfx)return;

    local pool=FS.S.P[t];
    if(pool<0)pool=0;
    if(pool>FS.CFG.PCAP)pool=FS.CFG.PCAP;

    local mode=("METER_MODE" in FS.CFG)?FS.CFG.METER_MODE:"portion_sync";

    if(mode=="pool_segments"){
        local tot=pool;
        for(local i=1;i<=FS.CFG.MC;i++){
            local seg=tot-((i-1)*100);if(seg<0)seg=0;if(seg>100)seg=100;
            local ent=FS.Fn(pfx+format("%02d",i));
            if(FS.Ok(ent))try{ent.SetBodygroup(1,seg);}catch(_e){}
        }
        return;
    }

    local div=("PORTION_DIV" in FS.CFG)?FS.CFG.PORTION_DIV:5;
    if(div<1)div=5;
    local portion=floor(pool.tofloat()/div.tofloat());
    FS.UmetSetAll(t,portion);
}

// --- optional: flash the taken value briefly, then revert safely ---
FS._MetSeqInit<-function(){
    if(!("MS" in FS.S))FS.S.MS<-{[2]=0,[3]=0};
}
FS._MetRevert<-function(t,seq){
    if(!FS.Tok(t))return;
    FS._MetSeqInit();
    if(FS.S.MS[t]!=seq)return;
    FS.Umet(t);
}
FS.UmetFlashTaken<-function(t,takeVal){
    if(!FS.Tok(t))return;
    if(!("METER_FLASH_TAKEN" in FS.CFG) || FS.CFG.METER_FLASH_TAKEN==0)return;

    FS._MetSeqInit();
    FS.S.MS[t]=FS.S.MS[t]+1;
    local seq=FS.S.MS[t];

    FS.UmetSetAll(t,takeVal);

    local ctl=FS.Fn(FS.CFG.SCRIPTER_NAME);
    if(!FS.Ok(ctl))return;

    local delay=("METER_FLASH_SEC" in FS.CFG)?FS.CFG.METER_FLASH_SEC:0.75;
    if(delay<0.05)delay=0.05;

    local cmd=format("getroottable().flagspawn._MetRevert(%d,%d)",t,seq);
    EntFireByHandle(ctl,"RunScriptCode",cmd,delay,null,null);
}
	

// player origin safe wrapper
FS.Op<-function(p){
    try{return NetProps.GetPropVector(p,"m_vecAbsOrigin");}catch(_e){}
    try{return p.GetOrigin();}catch(_e2){}
    return Vector(0,0,0);
}

FS.Gv<-function(f){local v=0;try{v=NetProps.GetPropInt(f,"m_nPointValue");}catch(_e){}return v<0?0:v;}

// IMPORTANT: flag/prop value bodygroup index 1 (NOT 0)
FS.Sv<-function(f,v){
    try{NetProps.SetPropInt(f,"m_nPointValue",v);}catch(_e){}
    FS.Bg(f,1,v);
}

FS.AddP<-function(t,a){if(a<=0)return;local c=FS.S.P[t]+a;if(c>FS.CFG.PCAP)c=FS.CFG.PCAP;FS.S.P[t]<-c;}
FS.ConsP<-function(t,a){if(a<=0)return;local c=FS.S.P[t]-a;if(c<0)c=0;FS.S.P[t]<-c;}

FS.Mk<-function(t,d){
    local nm=d?FS.CFG.MKD[t]:FS.CFG.MKR[t];
    local m=nm?FS.Fn(nm):null;
    if(!FS.Ok(m)&&d){nm=FS.CFG.MKR[t];m=nm?FS.Fn(nm):null;}
    return m;
}

FS.GlowSetTarget <- function(glowEnt, targetEnt, enableIt)
{
    if (!FS.Ok(glowEnt)) return;

    if (FS.Ok(targetEnt))
    {
        try { NetProps.SetPropEntity(glowEnt, "m_hTarget", targetEnt); } catch(_e) {}
    }

    EntFireByHandle(glowEnt, enableIt ? "Enable" : "Disable", "", 0.0, null, null);
};

FS.GlowFlashByFlag <- function(flagEnt, targetEnt, dur)
{
    if (!FS.Ok(flagEnt)) return;

    try { flagEnt.ValidateScriptScope(); } catch(_e) {}
    local scp = null;
    try { scp = flagEnt.GetScriptScope(); } catch(_e2) {}
    if (scp == null) return;

    // cache glow handle once (sibling name fixup still works for FINDING it)
    if (!("fs_glow" in scp) || scp.fs_glow == null || !scp.fs_glow.IsValid())
    {
        local nm = "";
        try { nm = flagEnt.GetName(); } catch(_e3) {}
        local amp = nm.find("&");
        if (amp == null) return;
        local suf = nm.slice(amp);

        // pick prefix from name (bluflag/redflag)
        local pref = (nm.len() >= 3 && nm.slice(0,3)=="red") ? "redflag_glow" : "bluflag_glow";
        scp.fs_glow <- Entities.FindByName(null, pref + suf);
    }

    if (!FS.Ok(scp.fs_glow)) return;

    scp.fs_glow_exp <- Time() + dur;
    FS.GlowSetTarget(scp.fs_glow, targetEnt, true);
};

function FS_GlowThink()
{
    local FS2 = getroottable().flagspawn;
    local now = Time();

    // Scan only known flags you already track in FS2.S.F (or whichever table you use)
    foreach (_k, flagEnt in FS2.S.F)
    {
        if (!FS2.Ok(flagEnt)) continue;

        try { flagEnt.ValidateScriptScope(); } catch(_e) {}
        local scp = null;
        try { scp = flagEnt.GetScriptScope(); } catch(_e2) {}
        if (scp == null) continue;

        if (("fs_glow" in scp) && FS2.Ok(scp.fs_glow) && ("fs_glow_exp" in scp) && scp.fs_glow_exp > 0 && now >= scp.fs_glow_exp)
        {
            scp.fs_glow_exp <- 0.0;
            FS2.GlowSetTarget(scp.fs_glow, null, false);
        }
    }
    return FS2.CFG.SPW_RECONCILE_SEC; // reuse your slow tick (0.5)
}

	

FS.Init<-function(){
    FS.S.P[2]=0;FS.S.P[3]=0;
    FS.S.A[2]=0;FS.S.A[3]=0;
    FS.S.N[2]=0;FS.S.N[3]=0;
    FS.S.Q.clear();FS.S.C.clear();FS.S.U.clear();FS.S.F.clear();FS.S.FC[2]=0;FS.S.FC[3]=0;
    FS.S.T0=Time();

    FS.Umet(2);FS.Umet(3);FS.Utxt(2);FS.Utxt(3);

    // start reconcile think (merge-kill frees a slot)
    if(!FS.S.SPW_STARTED && ("SpwStartThink" in FS)){
        FS.S.SPW_STARTED=true;
        FS.SpwStartThink();
    }
	local scripterEnt = Entities.FindByName(null, FS.CFG.SCRIPTER_NAME);
	if (FS.Ok(scripterEnt)) { try { AddThinkToEnt(scripterEnt, "FS_GlowThink"); } catch(_e) {} }

}
