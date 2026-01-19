local rt=getroottable();local FS=rt.flagspawn;

FS.CFG<-{
    TR=2,TB=3,

GLOW_DURATION_DROP = 10.0,
GLOW_DURATION_PICKUP = 2.0,
SOUND_REMAINDER = "Weapon_LooseCannon.Fuse",

    WINDOW_RESET_SEC = 90.0,
    SPW_TOUCHLOCK_SEC = 0.15,
    SPW_RECONCILE_SEC = 0.50,
    SCRIPTER_NAME = "scripter",

    LIM=25,

    PCAP=300,
    MC=3,
    // Meter display (spawner props blu_flagspawner_prop01..03 etc.)
    //  - pool_segments: old behavior (shows pool total split across props by 100s)
    //  - portion_sync: new behavior (all props show the *next payout* base portion)
	METER_MODE = "portion_sync",


    // Flash the taken value on the spawner props for feedback when a pull succeeds
    METER_FLASH_TAKEN = 1,
    METER_FLASH_SEC = 0.75,

    // Portion divisor: 5 == 20%
    PORTION_DIV = 5,

    // If 1, the class bonus also drains the pool (so heavy pulls reduce the pool more).
    // If 0, only the base portion drains the pool (class bonus is free).
    SPEND_CLASS_BONUS_FROM_POOL = 0,

    VCAP=100,
    SMIN=1,

    CCAP=100,

    BCOOL=90,
    BBOOST=3,
    CAPM=3,
    DBG_SELFHURT=1,

    MKR={ [2]="fs_flag_maker_red", [3]="fs_flag_maker_blu" },
    MKD={ [2]="fs_flag_maker_red_dyn", [3]="fs_flag_maker_blu_dyn" },

    MPF={ [2]="red_flagspawner_prop", [3]="blu_flagspawner_prop" },
    STX={ [2]="red_pool_text", [3]="blu_pool_text" },
    PPF={ [2]="redflag_prop", [3]="bluflag_prop" },

    // spw.nut expects THESE names:
    BUDGET_CLASS_MAX={ [1]=2,[2]=8,[3]=4,[4]=3,[5]=7,[6]=10,[7]=5,[8]=1,[9]=6 },
    BONUS_CLASS_POINTS={ [1]=2,[2]=8,[3]=4,[4]=3,[5]=7,[6]=10,[7]=5,[8]=1,[9]=6 },

    // keep if other modules still read CB
    CB={ [1]=2,[2]=8,[3]=4,[4]=3,[5]=7,[6]=10,[7]=5,[8]=1,[9]=6 }
};
