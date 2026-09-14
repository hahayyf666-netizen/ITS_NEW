# Step12D-PRE official clarification request

The following two questions are the only remaining source-contract blockers. Existing VTM/H.266 behaviour is retained as reference evidence and is not assumed to define the contest interface.

## 1. Horizontal and vertical transform coupling

When `lfnst_idx == 0`, which complete `(tu_width, tu_height, tr_type_hor, tr_type_ver)` tuples are legal?

In particular, should the two type fields be interpreted as:

- only the same transform family on both axes;
- any Cartesian product for which the selected horizontal type supports `tu_width` and the selected vertical type supports `tu_height`;
- only the five VVC explicit-MTS pairs (`DCT2/DCT2`, `DST7/DST7`, `DCT8/DST7`, `DST7/DCT8`, `DCT8/DCT8`);
- or another explicitly defined subset?

Please provide the authoritative tuple rule for the contest descriptor. We will not infer it from VTM coding-context predicates.

## 2. Main-transform fixed-point output contract

For every supported DCT2/DCT8/DST7 case, what exact fixed-point rules define the expected RTL result?

Please specify, for the vertical intermediate stage and the horizontal/final stage:

- accumulator width;
- rounding constant and right shift;
- clipping versus two's-complement wrapping;
- intermediate width;
- final mapping to each signed 10-bit output lane.

The contest text gives the coefficient matrices and dot-product formula and explicitly defines LFNST as `Clip3(-32768,32767,(sum+64)>>7)`, but it does not state an equivalent complete main-transform rule. The current 64x64 prototype uses an engineering baseline of `(+32)>>6`, signed-16 wrap and final low-10 selection; this will not be generalized without confirmation.

## Already closed

For active LFNST, the contest requirement that LFNST is followed by DCT2 is treated as `DCT2 x DCT2` for the two-dimensional main transform. The updated attachment supplies set indices `0..3`, active kernel indices `1..2`, nTrs `16/48`, coefficient matrices and the LFNST rounding/clipping rule.
