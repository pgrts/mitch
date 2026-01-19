// flagspawn/fs_config.nut
// Keep this file string-heavy (names) so other modules stay light.

local rt = getroottable();
local FS = rt.flagspawn;

FS.CFG <- {
    // Teams
    TEAM_RED = 2,
    TEAM_BLU = 3,

    // Hard caps
    LIMIT_ACTIVE = 25,   // stock cap (flags) per team
    POOL_CAP     = 500,  // economy meter cap (0..500)
    METER_COUNT  = 5,    // 5 props * 0..100

    // Value constraints
    VALUE_CAP = 100,     // per-flag clamp
    SPAWN_MIN = 1,
    CARRY_CAP = 100,     // per-player carry cap (ledger)

    // First-blood window (economy bonus on capture)
    FIRST_WINDOW = 180,  // seconds
    FIRST_MAX    = 3,    // first N unique players per team can claim

    // Entity names (match your VMF)
    SPAWNER_TRIG = { [2] = 'fs_spawner_red', [3] = 'fs_spawner_blu' },

    MAKER        = { [2] = 'fs_flag_maker_red',     [3] = 'fs_flag_maker_blu' },
    MAKER_DYN    = { [2] = 'fs_flag_maker_red_dyn', [3] = 'fs_flag_maker_blu_dyn' },

    // Spawner meter prop prefix (props are prefix + 01..05)
    METER_PREFIX = { [2] = 'red_flagspawner_prop', [3] = 'blu_flagspawner_prop' },

    // Worldtext / HUD helper showing remaining stock
    STOCK_TEXT   = { [2] = 'red_pool_text', [3] = 'blu_pool_text' },

    // Class bonuses (numbers only)
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
    }
};
