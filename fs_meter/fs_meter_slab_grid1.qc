$modelname "props_custom/fs_meter/fs_meter_slab_grid1.mdl"

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
    studio "out_slab1/grid_000_thick.smd"
    studio "out_slab1/grid_001_thick.smd"
    studio "out_slab1/grid_002_thick.smd"
    studio "out_slab1/grid_003_thick.smd"
    studio "out_slab1/grid_004_thick.smd"
    studio "out_slab1/grid_005_thick.smd"
    studio "out_slab1/grid_006_thick.smd"
    studio "out_slab1/grid_007_thick.smd"
    studio "out_slab1/grid_008_thick.smd"
    studio "out_slab1/grid_009_thick.smd"
    studio "out_slab1/grid_010_thick.smd"
    studio "out_slab1/grid_011_thick.smd"
    studio "out_slab1/grid_012_thick.smd"
    studio "out_slab1/grid_013_thick.smd"
    studio "out_slab1/grid_014_thick.smd"
    studio "out_slab1/grid_015_thick.smd"
    studio "out_slab1/grid_016_thick.smd"
    studio "out_slab1/grid_017_thick.smd"
    studio "out_slab1/grid_018_thick.smd"
    studio "out_slab1/grid_019_thick.smd"
    studio "out_slab1/grid_020_thick.smd"
    studio "out_slab1/grid_021_thick.smd"
    studio "out_slab1/grid_022_thick.smd"
    studio "out_slab1/grid_023_thick.smd"
    studio "out_slab1/grid_024_thick.smd"
    studio "out_slab1/grid_025_thick.smd"
    studio "out_slab1/grid_026_thick.smd"
    studio "out_slab1/grid_027_thick.smd"
    studio "out_slab1/grid_028_thick.smd"
    studio "out_slab1/grid_029_thick.smd"
    studio "out_slab1/grid_030_thick.smd"
    studio "out_slab1/grid_031_thick.smd"
    studio "out_slab1/grid_032_thick.smd"
    studio "out_slab1/grid_033_thick.smd"
    studio "out_slab1/grid_034_thick.smd"
    studio "out_slab1/grid_035_thick.smd"
    studio "out_slab1/grid_036_thick.smd"
    studio "out_slab1/grid_037_thick.smd"
    studio "out_slab1/grid_038_thick.smd"
    studio "out_slab1/grid_039_thick.smd"
    studio "out_slab1/grid_040_thick.smd"
    studio "out_slab1/grid_041_thick.smd"
    studio "out_slab1/grid_042_thick.smd"
    studio "out_slab1/grid_043_thick.smd"
    studio "out_slab1/grid_044_thick.smd"
    studio "out_slab1/grid_045_thick.smd"
    studio "out_slab1/grid_046_thick.smd"
    studio "out_slab1/grid_047_thick.smd"
    studio "out_slab1/grid_048_thick.smd"
    studio "out_slab1/grid_049_thick.smd"
    studio "out_slab1/grid_050_thick.smd"
    studio "out_slab1/grid_051_thick.smd"
    studio "out_slab1/grid_052_thick.smd"
    studio "out_slab1/grid_053_thick.smd"
    studio "out_slab1/grid_054_thick.smd"
    studio "out_slab1/grid_055_thick.smd"
    studio "out_slab1/grid_056_thick.smd"
    studio "out_slab1/grid_057_thick.smd"
    studio "out_slab1/grid_058_thick.smd"
    studio "out_slab1/grid_059_thick.smd"
    studio "out_slab1/grid_060_thick.smd"
    studio "out_slab1/grid_061_thick.smd"
    studio "out_slab1/grid_062_thick.smd"
    studio "out_slab1/grid_063_thick.smd"
    studio "out_slab1/grid_064_thick.smd"
    studio "out_slab1/grid_065_thick.smd"
    studio "out_slab1/grid_066_thick.smd"
    studio "out_slab1/grid_067_thick.smd"
    studio "out_slab1/grid_068_thick.smd"
    studio "out_slab1/grid_069_thick.smd"
    studio "out_slab1/grid_070_thick.smd"
    studio "out_slab1/grid_071_thick.smd"
    studio "out_slab1/grid_072_thick.smd"
    studio "out_slab1/grid_073_thick.smd"
    studio "out_slab1/grid_074_thick.smd"
    studio "out_slab1/grid_075_thick.smd"
    studio "out_slab1/grid_076_thick.smd"
    studio "out_slab1/grid_077_thick.smd"
    studio "out_slab1/grid_078_thick.smd"
    studio "out_slab1/grid_079_thick.smd"
    studio "out_slab1/grid_080_thick.smd"
    studio "out_slab1/grid_081_thick.smd"
    studio "out_slab1/grid_082_thick.smd"
    studio "out_slab1/grid_083_thick.smd"
    studio "out_slab1/grid_084_thick.smd"
    studio "out_slab1/grid_085_thick.smd"
    studio "out_slab1/grid_086_thick.smd"
    studio "out_slab1/grid_087_thick.smd"
    studio "out_slab1/grid_088_thick.smd"
    studio "out_slab1/grid_089_thick.smd"
    studio "out_slab1/grid_090_thick.smd"
    studio "out_slab1/grid_091_thick.smd"
    studio "out_slab1/grid_092_thick.smd"
    studio "out_slab1/grid_093_thick.smd"
    studio "out_slab1/grid_094_thick.smd"
    studio "out_slab1/grid_095_thick.smd"
    studio "out_slab1/grid_096_thick.smd"
    studio "out_slab1/grid_097_thick.smd"
    studio "out_slab1/grid_098_thick.smd"
    studio "out_slab1/grid_099_thick.smd"
    studio "out_slab1/grid_100_thick.smd"
	
}

// ------------------------------------------------------------
// 3. PROPERTIES
// ------------------------------------------------------------
$staticprop
$surfaceprop "metal"
$contents "solid"

// Force a valid bounding box just in case (optional, but good safety)
$bbox -30 -2 -20 30 0 20

$collisionmodel "smd/collision_box.smd"
{
    $mass 10
    $inertia 1
    $damping 0
    $rotdamping 0
    $rootbone "root"
}


$sequence "idle" {
"smd/fs_meter_bounds.smd" // Use bounds as ref for idle
fps 30
}