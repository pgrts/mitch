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
    MFS={ [2]=0,[3]=0 },
    MFV={ [2]=0,[3]=0 },
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

// suffix helper: returns "&0004" from "bluflag&0004"
FS.Suf<-function(ent){
    if(!FS.Ok(ent))return "";
    local nm="";try{nm=ent.GetName();}catch(_e){nm="";}
    local p=nm.find("&");
    if(p==null)return "";
    return nm.slice(p);
}

// owner helper (PD carried flags set owner to player)
FS.Owner<-function(flagEnt){
    if(!FS.Ok(flagEnt))return null;
    try{
        local o=flagEnt.GetOwner();
        if(FS.Ok(o))return o;
    }catch(_e){}
    try{
        local o2=NetProps.GetPropEntity(flagEnt,"m_hOwnerEntity");
        if(FS.Ok(o2))return o2;
    }catch(_e2){}
    return null;
}

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

// spawner meter props: bodygroup index 1
FS._OndeckVal<-function(t){
    if(!FS.Tok(t))return 0;
    local tot=FS.S.P[t];if(tot<0)tot=0;if(tot>FS.CFG.PCAP)tot=FS.CFG.PCAP;
    local divv=("PORTION_DIV" in FS.CFG)?FS.CFG.PORTION_DIV:5;
    if(divv<=0)divv=5;
    local portion=floor(tot.tofloat()/divv.tofloat());
    if(portion<0)portion=0;
    if(portion>100)portion=100;
    return portion;
}

FS.Uondeck<-function(t){
    if(!("ONDECK_PROP" in FS.CFG))return;
    if(!(t in FS.CFG.ONDECK_PROP))return;
    local nm=FS.CFG.ONDECK_PROP[t];
    if(!nm || nm=="")return;
    local ent=FS.Fn(nm);
    if(!FS.Ok(ent))return;
    FS.Bg(ent,1,FS._OndeckVal(t));
}

FS.Umet<-function(t){
    local pfx=FS.CFG.MPF[t];if(!pfx)return;
    local tot=FS.S.P[t];if(tot<0)tot=0;if(tot>FS.CFG.PCAP)tot=FS.CFG.PCAP;

    local mode = ("METER_MODE" in FS.CFG) ? FS.CFG.METER_MODE : "pool_segments";
    local divv = ("PORTION_DIV" in FS.CFG) ? FS.CFG.PORTION_DIV : 5;
    if (divv <= 0) divv = 5;

    // portion_sync: show next payout (floor(pool/div)) on ALL props
    if (mode == "portion_sync")
    {
        local portion = FS._OndeckVal(t);
        for(local i=1;i<=FS.CFG.MC;i++){
            local ent=FS.Fn(pfx+format("%02d",i));
            if(FS.Ok(ent)) FS.Bg(ent,1,portion);
        }
        FS.Uondeck(t);
        return;
    }

    // pool_segments: old behavior (300 split across props by 100s)
    for(local i=1;i<=FS.CFG.MC;i++){
        local seg=tot-((i-1)*100);if(seg<0)seg=0;if(seg>100)seg=100;
        local ent=FS.Fn(pfx+format("%02d",i));
        if(FS.Ok(ent)) FS.Bg(ent,1,seg);
    }
    FS.Uondeck(t);
}

// player origin safe wrapper


// Flash spawner meters to a specific value, then revert after CFG.METER_FLASH_SEC.
FS.UmetFlashTaken <- function(teamNum, shownVal)
{
    if (!FS.Tok(teamNum)) return;

    local pfx = FS.CFG.MPF[teamNum];
    if (!pfx) return;

    local v = shownVal;
    if (v < 0) v = 0;
    if (v > 100) v = 100;

    FS.S.MFS[teamNum] = FS.S.MFS[teamNum] + 1;
    local seq = FS.S.MFS[teamNum];
    FS.S.MFV[teamNum] = v;

    for(local i=1;i<=FS.CFG.MC;i++)
    {
        local ent = FS.Fn(pfx+format("%02d",i));
        if (FS.Ok(ent)) { FS.Bg(ent,1,v); }
    }

    local scripterEnt = Entities.FindByName(null, FS.CFG.SCRIPTER_NAME);
    if (!FS.Ok(scripterEnt)) return;

    local sec = ("METER_FLASH_SEC" in FS.CFG) ? FS.CFG.METER_FLASH_SEC : 0.75;
    if (sec < 0.02) sec = 0.02;

    // schedule revert (seq guard)
    EntFireByHandle(scripterEnt, "RunScriptCode", "getroottable().flagspawn.SpwMeterRevert("+teamNum+","+seq+")", sec, null, null);
};

FS.SpwMeterRevert <- function(teamNum, seq)
{
    if (!FS.Tok(teamNum)) return;
    if (!("MFS" in FS.S)) return;
    if (FS.S.MFS[teamNum] != seq) return; // newer flash happened
    FS.Umet(teamNum);
};
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

FS.GlowTick<-function()
{
    local now = Time();
    if(!("SF" in FS.S)) return;
    foreach (_suf, rec in FS.S.SF)
    {
        local flagEnt = ("h" in rec) ? rec.h : null;
        if (!FS.Ok(flagEnt)) continue;

        try { flagEnt.ValidateScriptScope(); } catch(_e) {}
        local scp = null;
        try { scp = flagEnt.GetScriptScope(); } catch(_e2) {}
        if (scp == null) continue;

        if (("fs_glow" in scp) && FS.Ok(scp.fs_glow) && ("fs_glow_exp" in scp) && scp.fs_glow_exp > 0 && now >= scp.fs_glow_exp)
        {
            scp.fs_glow_exp <- 0.0;
            FS.GlowSetTarget(scp.fs_glow, null, false);
        }
    }
}

	

FS.Init<-function(){
    FS.S.P[2]=0;FS.S.P[3]=0;
    FS.S.A[2]=0;FS.S.A[3]=0;
    FS.S.N[2]=0;FS.S.N[3]=0;
    FS.S.Q.clear();FS.S.C.clear();FS.S.U.clear();FS.S.F.clear();FS.S.FC[2]=0;FS.S.FC[3]=0;
    if("SF" in FS.S) FS.S.SF.clear();
    if("BU" in FS.S) FS.S.BU.clear();
    if("BT" in FS.S) FS.S.BT.clear();
    if("BM" in FS.S) FS.S.BM.clear();
    if("BE" in FS.S) FS.S.BE.clear();
    if("TL" in FS.S) FS.S.TL.clear();
    if("NX" in FS.S) FS.S.NX.clear();
    FS.S.T0=Time();

    FS.Umet(2);FS.Umet(3);FS.Utxt(2);FS.Utxt(3);

    // start reconcile think (merge-kill frees a slot)
    if(!FS.S.SPW_STARTED && ("SpwStartThink" in FS)){
        FS.S.SPW_STARTED=true;
        FS.SpwStartThink();
    }
	// Note: we only attach ONE think to the scripter (spw.nut's FS_SpwThink).
	// Glow expiry is handled from that tick via FS.GlowTick().

}
