# V3.5 Step12C-M4 Implementation Report

## 判定

**Step12C-2 implementation completed, final timing gate STOP.**

`route_design` completed successfully and produced a routed checkpoint, but the
post-route 2.000 ns timing requirements are not met. Therefore this evidence
does not create `v3.5-18` and does not authorize further scope expansion.

## 固定输入

- Git commit: `bb65abf60b3036e5535bf7056402e971e0e1a855`
- Vivado: `2025.2` build `6299465`
- Device: `xcku5p-ffvb676-2-e`
- Clock: `clk`, period `2.000 ns` / `500 MHz`
- R4C RTL: unchanged; SHA-256
  `15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1`
- Step12B wrapper: unchanged; SHA-256
  `D1459B652666E2DBBB0D3464002E88DD30867C4BA6E4715E6865B5164E664943`
- RTL/XDC scope: no changes for this implementation run

## Post-route timing

| Metric | Result | Gate |
|---|---:|---|
| WNS | `-0.052 ns` | FAIL (`>= 0`) |
| TNS | `-4.030 ns` | FAIL (`0`) |
| setup failing endpoints | `291` | FAIL (`0`) |
| WHS | `-0.080 ns` | FAIL (`>= 0`) |
| THS | `-17.614 ns` | FAIL (`0`) |
| hold failing endpoints | `281` | FAIL (`0`) |
| unconstrained internal endpoints | `0` | PASS |

The worst setup path is an input-cache tag RAM path from
`input_wr_addr_b3_q_reg[0]` to `input_tag_b3_reg_r2_896_959_0_6/RAMD/I`,
with `1.971 ns` data delay and approximately `80%` routed delay. The worst
hold path is an OOC input-port to first input-command register path, for
example `it_data_in[13] -> input_wr_data_a2_q_reg[13]/D`, with `-0.080 ns`
slack. Vivado also reported that it could not fix some hold pins because of
fixed or dedicated routing.

## Implementation/structure evidence

- Route status: `0` unrouted nets, `0` partially routed nets, `0` node overlaps.
- DRC: no errors; the report contains OOC-related warnings and 256 `DPIP-2`
  input-pipelining warnings plus one no-routable-load warning.
- Timing exceptions: `No valid timing exceptions found.`
- Post-route resources: `21,841` LUTs total (`14,673` logic LUTs,
  `7,168` distributed-RAM LUTs), `21,352` FFs, `128` DSP48E2, `0` BRAM,
  `0` URAM.
- High fanout remains visible, led by `rst_n` at `21,267` loads and several
  frozen-R4C/result/stage nets above `1,000` loads.
- Vectorless power estimate: `1.227 W`, dynamic `0.771 W`, static `0.456 W`,
  confidence `Medium`; no SAIF/VCD activity was supplied.

## Evidence files

- `step12c_wrapper_postroute.dcp`
- `report_timing_summary_postroute.rpt`
- `report_timing_hold_summary_postroute.rpt`
- `report_timing_worst100_postroute.rpt`
- `report_hold_worst100_postroute.rpt`
- `report_utilization_postroute.rpt`
- `report_hierarchy_utilization_postroute.rpt`
- `report_high_fanout_postroute.rpt`
- `report_check_timing_postroute.rpt`
- `report_exceptions_postroute.rpt`
- `report_drc_postroute.rpt`
- `report_methodology_postroute.rpt`
- `report_power_postroute.rpt`

Post-route DCP SHA-256:
`386D3DF0C6A829FF1408052B12D49D61A741D2C01EAC4A1A490108CBE494F529`

## Decision

The M4 RTL/XDC remains frozen for this run. Do not create `v3.5-18` and do
not enter a new optimization blindly. The next engineering action is a
narrow post-route root-cause review of the measured input-tag setup cone and
the input-port/first-command-register hold cone. Any RTL change must be a
separately scoped repair version with fresh functional and synthesis evidence.
