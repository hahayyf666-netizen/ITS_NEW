# V35 P2F-B2 R4_PRE Architecture Census

本报告只做 R3R 的只读架构/时序预检查，未修改 RTL、ROM、golden 或约束。

## Frozen graph
- operations: 1368
- dots: 64
- butterfly signals: 124
- lanes: 128
- issue-cycle counts: `{0: 88, 1: 128, 2: 128, 3: 128, 4: 128, 5: 128, 6: 128, 7: 128, 8: 128, 9: 128, 10: 128}`

## Lane candidate evidence
- max unique x sources per physical lane: 3
- max unique coefficients per physical lane: 11
- source-count histogram: `{2: 40, 3: 88}`
- coefficient-count histogram: `{9: 5, 10: 50, 11: 73}`

## R3R routed timing census
- path rows: 1000

| category | count | fraction | min slack (ns) | mean slack (ns) |
|---|---:|---:|---:|---:|
| butterfly | 192 | 19.2% | -0.862 | -0.6853125000000001 |
| control_schedule | 141 | 14.1% | -0.789 | -0.7000992907801419 |
| operand_frontend | 635 | 63.5% | -0.818 | -0.7002094488188976 |
| reduction | 32 | 3.2% | -0.688 | -0.663875 |

## Interpretation

The current post-route bottleneck must be treated as two coupled locality problems:
the operand/coefficient front-end and the butterfly/signal store. A single butterfly-only patch is not accepted by this precheck.
The lane/source map and full butterfly connectivity JSON are the authoritative inputs for the next cluster partition step.

## Gate

PASS_MODEL_CENSUS: exact 1368-op / 64-dot / 124-signal graph extracted from the frozen P4Dataflow model.
No R4 RTL was written and no new synthesis/implementation was launched in this step.
