// flagspawn/cfg.nut (microservices v7)
// Keep string-heavy config here so other modules stay lighter.

local rt = getroottable();
local FS = rt.flagspawn;

FS.SRC_SPAWNER <- 1; // counts toward stock (25)
FS.SRC_CHUNK   <- 2; // pinata/damage (bypasses stock)

FS.CFG <- {
    VERSION = "v7_micro",

    // Teams
    TEAM_RED = 2,
    TEAM_BLU = 3,

    // ---------------- Spawner Stock (flags) ----------------
    // This is NOT points. This is a cap on how many spawner-dispensed flags can exist at once.
    STOCK_LIMIT = 25,

    // ---------------- Economy Pool (points) ----------------
    // We only render 3 spawner meter props, so pool is clamped to 0..300.
    // Anything above this is discarded ("killed from the economy").
    // With POOL_SHARE_DEN=5, the displayed on-deck meter is 0..60.
    POOL_CAP = 300,
    METER_COUNT = 3,

    // Spawner dispenses 20% of the pool (floor(pool/5)) + class bonus.
    POOL_SHARE_DEN = 5,

    // If true, the class bonus also drains the pool when dispensing from the spawner.
    // If false, only the 20% pool portion drains the pool (class bonus is "free" and does not reduce meters).
    POOL_CONSUME_CLASS_BONUS = false,

    // Value constraints
    VALUE_CAP = 100,
    SPAWN_MIN = 1,
    CARRY_CAP = 100,

    // If a carried flag becomes "too small to split cleanly", we just kill it (never set to 0).
    // This especially matters for 1/2-point flags (2 tends to collapse into 1 with 10%/20% math).
    SMALL_FLAG_KILL_MAX = 2,

    // Capture economy multiplier (new: 3x)
    CAP_MULT = 3,

    // Think / maintenance
    THINK_DT = 0.25,
    SPAWN_SCAN_RADIUS = 256.0,

    // Damage / death rules (v7)
    DMG_REQUIRE_ENEMY = true,
    DMG_THRESHOLD_PCT = 0.125, // 12.5% max health
    DMG_DESTROY_DEN = 10,      // 10%
    DMG_CHUNK_DEN = 5,         // 20%
    DEATH_GRAVE_DEN = 5,       // 20%
    DEATH_CHUNK_DEN = 5,       // 20%
    DEATH_MAX_CHUNKS = 4,

    // Kill the PD "points on death" drop (usually 1 point) without ever creating 0-point flags.
    // We do this by killing nearby 1-point flags shortly after death.
    DEATH_DROP_KILL_VALUE = 1,
    DEATH_DROP_KILL_RADIUS = 96.0,
    DEATH_DROP_KILL_DELAY = 0.15,

    // ---------------- VMF Names ----------------
    SCRIPTER_NAME = "scripter",

    // Makers
    MAKER = { [2] = "fs_flag_maker_red", [3] = "fs_flag_maker_blu" },
    MAKER_DYN = { [2] = "fs_flag_maker_red_dyn", [3] = "fs_flag_maker_blu_dyn" },

    // Spawner meter props: <prefix>01..03
    METER_PREFIX = { [2] = "red_flagspawner_prop", [3] = "blu_flagspawner_prop" },

    // Stock remaining display (point_worldtext)
    STOCK_TEXT = { [2] = "red_pool_text", [3] = "blu_pool_text" },

    // Optional lock icon sprite near the worldtext (shown when stock == 0)
    LOCK_SPRITE = { [2] = "red_spawner_lock", [3] = "blu_spawner_lock" },

    // Template bases (suffix appended by point_template NameFixup)
    FLAG_BASE = { [2] = "redflag", [3] = "bluflag" },
    PROP_BASE = { [2] = "redflag_prop", [3] = "bluflag_prop" },
    GLOW_BASE = { [2] = "redflag_glow", [3] = "bluflag_glow" },
    LOCK_BASE = { [2] = "blu_lock_redflag", [3] = "red_lock_bluflag" },
    LMM_BASE = { [2] = "red_lmm", [3] = "blu_lmm" },
    LMM_REF_BASE = { [2] = "red_lmm_ref", [3] = "blu_lmm_ref" },
    LMM_TARGET_BASE = { [2] = "red_lmm_target", [3] = "blu_lmm_target" },

    // Prop cosmetic attach point on player
    ATTACH_POINT = "partyhat",

    // ---------------- Visuals / SFX ----------------
    // Duration-based glow behavior (retarget via NetProp m_hTarget).
    GLOW_DURATION_DROP = 10.0,   // after spawn/drop
    GLOW_DURATION_PICKUP = 2.0,  // brief flash on pickup (optional)

    // Sound played when value is destroyed as "remainder" beyond the grave tax in death pinata.
    SOUND_REMAINDER = "Weapon_LooseCannon.Fuse",
    SOUND_REMAINDER_VOL = 1.0,
    SOUND_REMAINDER_PITCH = 100,

    // Class bonuses (numbers only; string-free table)
    CLASS_BONUS = {
        [1] = 2,   // Scout
        [2] = 8,   // Sniper
        [3] = 4,   // Soldier
        [4] = 3,   // Demoman
        [5] = 7,   // Medic
        [6] = 10,  // Heavy
        [7] = 5,   // Pyro
        [8] = 1,   // Spy
        [9] = 6    // Engineer
    },

    // First-blood capture window (optional; still supported)
    FIRST_WINDOW = 180,
    FIRST_MAX = 3
};
