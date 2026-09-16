# Step12F-P9-R5A Fixed-DCP Implementation Stability Qualification

Baseline: `92145aa102f5a41bb7ad0c1ecc644e3c3c2d5b6d`; RTL/XDC frozen; no resynthesis; Vivado 2025.2; xcku5p-ffvb676-2-e; 2.000 ns; maxThreads=4.

| Run | Flow | Setup WNS/TNS/failing | Hold WHS/THS/failing | Route | Final DCP |
|---|---|---:|---:|---|---|
| `R4_REPLAY` | Explore/Explore/Explore/Explore | `-0.099/-6.607/209` | `-0.080/-4.911/76` | Fully routed | `347DA6A0D8526A8B42FCADCC21110CDE5D4E75C3C3382536E88291CDC4DA60C2` |
| `R5_REPLAY` | Explore/Explore/Explore/Explore | `-0.247/-110.011/1951` | `-0.080/-4.691/62` | Fully routed | `1F689CB88DA986D39A520C13C1455166825BD080F21B02EDA7784ED7E9781C3C` |
| `R5_NETDELAY` | Default/ExtraNetDelay_high/AggressiveExplore/NoTimingRelaxation | `-0.063/-1.776/84` | `-0.080/-4.764/65` | Fully routed | `6BE317AFB579115AF7451F872CF2D0C107C296E76432E34D741240248C8E236F` |
| `R5_EXTRATIMING` | Default/ExtraTimingOpt/Explore/NoTimingRelaxation | `-0.121/-2.548/96` | `-0.080/-4.667/62` | Fully routed | `755B12A3F85A5D30D61FE763A0B13F1ED38535856077498F4BA42B197170D43F` |
| `R5_POSTROUTE_PHYSOPT` | Explore/Explore/Explore/Explore + postroute Explore | `-0.247/-110.011/1951` | `-0.080/-4.691/62` | Fully routed | `925C38104559F6741AD222FE0F34B5182B2151D126CD0BBB3E20728E87C2B854` |
| `R5_INCREMENTAL` | Explore + incremental TimingClosure | `-0.195/-68.791/1356` | `-0.080/-4.653/61` | Fully routed | `36D1C2C9949510D4D4C9F58C178AC7F2571F321A0EEBC5807A03CC6D3E719AAF` |

Interpretation: R4_REPLAY vs R5_REPLAY is the controlled topology comparison. The R5 performance flows measure convergence potential only; R5_INCREMENTAL is valid only if its reuse reports and transcript confirm actual incremental implementation rather than fallback.

All routed qualification JSON files contain the worst-500 family census and H-read structural checks. R5_INCREMENTAL reuse percentages are preserved in its three reuse reports and summarized in the run matrix; the transcript and TimingClosure report confirm actual incremental implementation.

## Worst-500 family census (sampled paths)

| Run | A cache→LFNST | B kernel→P4 input | C read | C write/other | D control/R4C | E other |
|---|---:|---:|---:|---:|---:|---:|
| `R4_REPLAY` | 16 | 0 | 0 | 121 | 49 | 23 |
| `R5_REPLAY` | 23 | 32 | 35 | 132 | 159 | 119 |
| `R5_NETDELAY` | 13 | 0 | 0 | 28 | 19 | 24 |
| `R5_EXTRATIMING` | 19 | 0 | 0 | 37 | 13 | 27 |
| `R5_POSTROUTE_PHYSOPT` | 23 | 32 | 35 | 132 | 159 | 119 |
| `R5_INCREMENTAL` | 19 | 43 | 10 | 149 | 194 | 85 |

Family counts are the qualification script's sampled worst-500 classification, not a claim that the sample counts equal the full design endpoint population or full-design TNS.

Decision: retain R5; the best observed R5 setup flow is the NetDelay flow, but hold and setup remain negative. This is an implementation-stability/convergence result, not 500 MHz signoff; P9-R6 RTL changes remain unauthorized.

The qualification does not constitute 500 MHz signoff unless setup and hold are both non-negative on a fully routed run with no unconstrained/exception issue.

