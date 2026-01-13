$modelname "props_custom/fs_meter/fs_meter_slab_grid.mdl"

// VMTs live here:
$cdmaterials "models/props_custom/fs_meter/"

// ------------------------------------------------------------
// 1) ALWAYS-ON BOUNDS HELPER (gives a reliable 3D silhouette / bbox)
// ------------------------------------------------------------
$body "bounds" "smd/fs_meter_bounds.smd"

// ------------------------------------------------------------
// 2) FILL BODYGROUP (0–100)
// ------------------------------------------------------------
$bodygroup "fill"
{
    studio "out_slab/grid_000_thick.smd"
    studio "out_slab/grid_001_thick.smd"
    studio "out_slab/grid_002_thick.smd"
    studio "out_slab/grid_003_thick.smd"
    studio "out_slab/grid_004_thick.smd"
    studio "out_slab/grid_005_thick.smd"
    studio "out_slab/grid_006_thick.smd"
    studio "out_slab/grid_007_thick.smd"
    studio "out_slab/grid_008_thick.smd"
    studio "out_slab/grid_009_thick.smd"
    studio "out_slab/grid_010_thick.smd"
    studio "out_slab/grid_011_thick.smd"
    studio "out_slab/grid_012_thick.smd"
    studio "out_slab/grid_013_thick.smd"
    studio "out_slab/grid_014_thick.smd"
    studio "out_slab/grid_015_thick.smd"
    studio "out_slab/grid_016_thick.smd"
    studio "out_slab/grid_017_thick.smd"
    studio "out_slab/grid_018_thick.smd"
    studio "out_slab/grid_019_thick.smd"
    studio "out_slab/grid_020_thick.smd"
    studio "out_slab/grid_021_thick.smd"
    studio "out_slab/grid_022_thick.smd"
    studio "out_slab/grid_023_thick.smd"
    studio "out_slab/grid_024_thick.smd"
    studio "out_slab/grid_025_thick.smd"
    studio "out_slab/grid_026_thick.smd"
    studio "out_slab/grid_027_thick.smd"
    studio "out_slab/grid_028_thick.smd"
    studio "out_slab/grid_029_thick.smd"
    studio "out_slab/grid_030_thick.smd"
    studio "out_slab/grid_031_thick.smd"
    studio "out_slab/grid_032_thick.smd"
    studio "out_slab/grid_033_thick.smd"
    studio "out_slab/grid_034_thick.smd"
    studio "out_slab/grid_035_thick.smd"
    studio "out_slab/grid_036_thick.smd"
    studio "out_slab/grid_037_thick.smd"
    studio "out_slab/grid_038_thick.smd"
    studio "out_slab/grid_039_thick.smd"
    studio "out_slab/grid_040_thick.smd"
    studio "out_slab/grid_041_thick.smd"
    studio "out_slab/grid_042_thick.smd"
    studio "out_slab/grid_043_thick.smd"
    studio "out_slab/grid_044_thick.smd"
    studio "out_slab/grid_045_thick.smd"
    studio "out_slab/grid_046_thick.smd"
    studio "out_slab/grid_047_thick.smd"
    studio "out_slab/grid_048_thick.smd"
    studio "out_slab/grid_049_thick.smd"
    studio "out_slab/grid_050_thick.smd"
    studio "out_slab/grid_051_thick.smd"
    studio "out_slab/grid_052_thick.smd"
    studio "out_slab/grid_053_thick.smd"
    studio "out_slab/grid_054_thick.smd"
    studio "out_slab/grid_055_thick.smd"
    studio "out_slab/grid_056_thick.smd"
    studio "out_slab/grid_057_thick.smd"
    studio "out_slab/grid_058_thick.smd"
    studio "out_slab/grid_059_thick.smd"
    studio "out_slab/grid_060_thick.smd"
    studio "out_slab/grid_061_thick.smd"
    studio "out_slab/grid_062_thick.smd"
    studio "out_slab/grid_063_thick.smd"
    studio "out_slab/grid_064_thick.smd"
    studio "out_slab/grid_065_thick.smd"
    studio "out_slab/grid_066_thick.smd"
    studio "out_slab/grid_067_thick.smd"
    studio "out_slab/grid_068_thick.smd"
    studio "out_slab/grid_069_thick.smd"
    studio "out_slab/grid_070_thick.smd"
    studio "out_slab/grid_071_thick.smd"
    studio "out_slab/grid_072_thick.smd"
    studio "out_slab/grid_073_thick.smd"
    studio "out_slab/grid_074_thick.smd"
    studio "out_slab/grid_075_thick.smd"
    studio "out_slab/grid_076_thick.smd"
    studio "out_slab/grid_077_thick.smd"
    studio "out_slab/grid_078_thick.smd"
    studio "out_slab/grid_079_thick.smd"
    studio "out_slab/grid_080_thick.smd"
    studio "out_slab/grid_081_thick.smd"
    studio "out_slab/grid_082_thick.smd"
    studio "out_slab/grid_083_thick.smd"
    studio "out_slab/grid_084_thick.smd"
    studio "out_slab/grid_085_thick.smd"
    studio "out_slab/grid_086_thick.smd"
    studio "out_slab/grid_087_thick.smd"
    studio "out_slab/grid_088_thick.smd"
    studio "out_slab/grid_089_thick.smd"
    studio "out_slab/grid_090_thick.smd"
    studio "out_slab/grid_091_thick.smd"
    studio "out_slab/grid_092_thick.smd"
    studio "out_slab/grid_093_thick.smd"
    studio "out_slab/grid_094_thick.smd"
    studio "out_slab/grid_095_thick.smd"
    studio "out_slab/grid_096_thick.smd"
    studio "out_slab/grid_097_thick.smd"
    studio "out_slab/grid_098_thick.smd"
    studio "out_slab/grid_099_thick.smd"
    studio "out_slab/grid_100_thick.smd"
}

// ------------------------------------------------------------
// 3. PROPERTIES
// ------------------------------------------------------------
$staticprop
$surfaceprop "metal"
$contents "solid"

// Force a valid bounding box just in case (optional, but good safety)
$bbox -16 -16 -16 16 16 16

$collisionmodel "smd/collision_box.smd"
{
    $mass 10
    $inertia 1
    $damping 0
    $rotdamping 0
    $rootbone "root"
}


$sequence "idle" {
"out_slab/fs_meter_bounds.smd" // Use bounds as ref for idle
fps 30
}