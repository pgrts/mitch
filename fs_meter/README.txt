FS Meter Grid (10x10, 2u pixels) — 101-state bodygroup model

- Total: 20.0u wide x 20.0u tall (2u per pixel)
- Fill order: column-major, bottom->top, then left->right
  value=10 => 1 full column
  value=25 => 2 full columns + 5 pixels in next column
  value=99 => 9 full columns + 9 pixels in last column
  value=100 => full block

Runtime:
- One bodygroup (index 0) "fill" with choices 0..100.
- Use EntFire SetBodyGroup "0 <idx>".

QC includes:
- $bbox / $cbox for a constant 20x20x20 box.
