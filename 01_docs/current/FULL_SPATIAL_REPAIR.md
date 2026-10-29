# Full spatial inverse-transform reconstruction

The contest output index is i=0..nTbS-1. nonZeroS limits input-frequency summation, not spatial output extent. LFNST scatter defines intermediate coefficients before DCT2, not a final spatial crop.

For TU widthW/heightH and frequency supportCw/Ch:

| Pass | Inputs | Outputs |
|---|---|---|
| V | Cw vectors,Ch coefficients each | H spatial samples per column |
| V writeback | H*Cw points | Cw*H/4 four-lane commits |
| H | H vectors,Cw coefficients each | W spatial samples per row |
| External | complete TU | W*H/4 accepted beats |

The RTL correction changes V output size/count in ordinary and post-LFNST entry paths. V write masks/last markers use fullH. H reads every spatial row. Input-frequency cuts and the registered final-commit barrier remain in place.

The bank map stays bank=(row+column)&3, local=(row>>2)*W+column. W,H<=64 imply local<=1023, within the existing1024-entry banks. New tests check exact commits, unique addresses, bounds and H admission. The kernel already separates active input size and output group count; coefficient and arithmetic trees are unchanged.

Both Python models now iterate allH spatial outputs. The credit-return TB's hardcoded lower-half zeros are replaced by full-height constants cross-checked against native VTM.

Independent checks combine analytic DC (512 -> V256 -> H16), compiled unmodified VTM functions, and the original frozen RTL as an expected-failure control. The adapter applies the declared input-frequency mask before calling fast primitives. LFNST preprocessing remains the separately checked layout model; native comparison covers the primary V/H transforms.

Tests retain RAM payload between different TU shapes, stall middle/final outputs, and reset within newly reconstructed V regions. Cycle performance and500MHz implementation require fresh evidence. The fixed1024-cycle tag scrub and serial vector scheduler are separate performance limitations.
