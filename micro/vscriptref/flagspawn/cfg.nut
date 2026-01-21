local rt=getroottable();
local FS=rt.flagspawn;

// CFG: keep this file SHORT + safe. No single-quoted strings (Squirrel char literal bug).
FS.CFG <- {
    // Teams
    TR = 2,
    TB = 3,

    // Glow timings
    GLOW_DURATION_DROP = 10.0,
    GLOW_DURATION_PICKUP = 2.0,

    // Misc
    SOUND_REMAINDER = "Weapon_LooseCannon.Fuse",
    SCRIPTER_NAME = "scripter",

    // Spawner window + touch lock
    WINDOW_RESET_SEC = 90.0,
    SPW_TOUCHLOCK_SEC = 0.15,
    SPW_RECONCILE_SEC = 0.50,

    // Spawner rate limiting between successful pulls (per player)
    // Higher budget classes pull faster per-flag, but take longer to finish their full budget.
    // Interval formula: rate = SPW_RATE_BASE_SEC * sqrt(2) / sqrt(useMax)
    SPW_RATE_BASE_SEC = 0.60,

    // Hard limit of spawner-origin flags alive per team
    LIM = 25,

    // Pool cap (total banked budget bonus)
    PCAP = 300,

    // Number of spawner meter props (blu_flagspawner_prop01..03)
    MC = 3,

    // Meter display mode:
    //  - "pool_segments" : old behavior (300 split across 3 props)
    //  - "portion_sync"  : all props show next payout portion (pool/PORTION_DIV)
    METER_MODE = "portion_sync",

    // 20% payout -> PORTION_DIV=5
    PORTION_DIV = 5,

    // Flash taken value on spawner props (optional)
    METER_FLASH_TAKEN = 1,
    METER_FLASH_SEC = 0.75,

    // If 1, class bonus also drains pool (spend == portion + class bonus)
    SPEND_CLASS_BONUS_FROM_POOL = 0,

    // Per-flag value cap
    VCAP = 100,

    // Per-player carry cap
    CCAP = 100,

    // Capture multiplier (bank -> score)
    CAPM = 3,

    // Merge handling:
    // If a spawner-origin flag entity disappears (PD merge delete), we always free a stock slot.
    // Optionally, you can also refund its last-known value into the pool (treat as "returned").
    MERGE_REFUND = 0,
    MERGE_REFUND_DROPPED_ONLY = 1,

    // Makers
    MKR = { [2] = "fs_flag_maker_red", [3] = "fs_flag_maker_blu" },
    MKD = { [2] = "fs_flag_maker_red_dyn", [3] = "fs_flag_maker_blu_dyn" },

    // Spawner prop prefix (expects 01..MC)
    MPF = { [2] = "red_flagspawner_prop", [3] = "blu_flagspawner_prop" },

    // NEW: non-templated on-deck ghost prop (single prop_dynamic per team)
    // Shows onDeck = floor(pool/PORTION_DIV) (0..60 when PCAP=300, PORTION_DIV=5)
    ONDECK_PROP = { [2] = "red_ondeck_bonus_propflag", [3] = "blu_ondeck_bonus_propflag" },

    // Template sibling prefixes (for merge cleanup by suffix)
    LOCKPFX = { [2] = "blu_lock_redflag", [3] = "red_lock_bluflag" },
    LMMPFX  = { [2] = "red_lmm_target",   [3] = "blu_lmm_target" },

    // Pool text HUD
    STX = { [2] = "red_pool_text", [3] = "blu_pool_text" },

    // Flag prop name (template)
    PPF = { [2] = "redflag_prop", [3] = "bluflag_prop" },

    // Economy (your class budgets)
    BUDGET_CLASS_MAX = { [1]=2,[2]=8,[3]=4,[4]=3,[5]=7,[6]=10,[7]=5,[8]=1,[9]=6 },
    BONUS_CLASS_POINTS = { [1]=2,[2]=8,[3]=4,[4]=3,[5]=7,[6]=10,[7]=5,[8]=1,[9]=6 },

    // Back-compat (if any module still reads CB)
    CB = { [1]=2,[2]=8,[3]=4,[4]=3,[5]=7,[6]=10,[7]=5,[8]=1,[9]=6 }
};
