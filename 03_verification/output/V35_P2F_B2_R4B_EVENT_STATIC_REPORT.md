# V3.5 P2F-B2-R4B Event-Static Butterfly Report

Date: 2026-09-09

Baseline: `D:/Workspace/ITS_STUDY_V35_P2F_B2_R4B_PRE`

Scope: replace only the dynamic butterfly event lookup/indexing in the
R4B_PRE DCT2-64 prototype. Operand scheduling, 128-lane multiplier farm,
reduction fabric, event timing, arithmetic and output protocol were not
otherwise changed.

## Implementation

- The complete R4B_PRE project was copied to
  `D:/Workspace/ITS_STUDY_V35_P2F_B2_R4B_EVENT_STATIC`.
- `generate_r4b_static_butterfly.py` mechanically reads the frozen
  `r4b_pre_butterfly_events.csv` and emits `p2f_r4b_static_butterfly.svh`.
- The active RTL includes that generated statement block in place of the
  previous `p2f102_bf_*` dynamic butterfly loops.
- The generated block contains 124 fixed phase/destination/source events,
  with `bf_bank` and `bf_vector_id` retained only as dynamic context.

## Structural audit

`run_r4b_event_static_audit.py` result:

| Check | Result |
|---|---:|
| Expected events | 124 |
| Observed fixed events | 124 |
| Expected unique destinations | 124 |
| Observed unique destinations | 124 |
| Duplicate destinations | 0 |
| Event sequence exact vs frozen CSV | PASS |
| Dynamic butterfly lookup in active RTL | absent |
| Dynamic `signal_reg[sid_tmp]` destination | absent |
| Overall | **PASS** |

The machine-readable result is
`03_verification/output/r4b_event_static_connectivity.json`.

## Functional simulation

ModelSim 2020.4, normal mode:

- compile: 0 errors, 0 warnings
- 49/49 cases, 784/784 beats
- stage/final data and tags: PASS
- group 0..15 contiguous for every vector
- vector launch interval: 16 cycles
- positive/negative wrap cases exercised: 950 / 935 outputs

SYNTHESIS mode (`+define+SYNTHESIS`):

- compile: 0 errors, 0 warnings
- 49/49 cases, 784/784 beats
- final stage16/final10 and tags: PASS

Logs:

- `03_verification/sim/logs/r4b_event_static_functional.log`
- `03_verification/sim/logs/r4b_event_static_synthesis.log`
- `03_verification/sim/logs/r4b_event_static_repro.log` (retained `.do` replay)

The functional compile/run command is also retained as
`03_verification/sim/run_r4b_event_static.do`.

## Synthesis-only comparison (same Tcl/XDC/part)

Part: `xcku5p-ffvb676-2-e`; OOC period: 2.000 ns.

| Metric | R4A baseline | R4B event-static | Change |
|---|---:|---:|---:|
| CLB LUTs | 15,677 | 15,226 | -451 (-2.9%) |
| Post-synth WNS | -0.235 ns | -0.235 ns | no change |
| Post-synth setup failing endpoints | 3,222 | 3,072 | -150 |
| Post-synth TNS | -481.310 ns | -479.434 ns | +1.876 ns |
| CLB registers | 21,324 | 21,260 | -64 |
| DSP48E2 | 128 | 128 | unchanged |
| Block RAM Tile | 0 | 0 | unchanged |
| F7/F8 muxes | 0 / 0 | 0 / 0 | unchanged |

The R4B synthesis reports are in
`03_verification/vivado/reports_r4b_event_static_synth/`.

## Post-route result

The same controlled OOC flow was run once after the synthesis improvement.

| Metric | R4A baseline | R4B event-static |
|---|---:|---:|
| WNS | -0.626 ns | **-0.462 ns** |
| TNS | -1,740.066 ns | **-928.781 ns** |
| Setup failing endpoints | 6,320 | **3,486** |
| WHS | +0.043 ns | +0.043 ns |
| Hold failing endpoints | 0 | 0 |
| CLB LUTs | 15,179 | 14,778 |
| CLB registers | 21,361 | 21,260 |
| DSP48E2 | 128 | 128 |
| Block RAM Tile | 0 | 0 |
| Total on-chip power | 1.708 W | 1.813 W |

The R4B post-route reports are in
`03_verification/vivado/reports_r4b_event_static_postroute/`.
The worst path remains in the operand-coefficient front end:
`operand_coeff_reg_reg[31][2]/C -> lane_product_reg_reg[86][7]/D`,
slack -0.462 ns. This change therefore does **not** close 500 MHz.

## File hashes

| File | SHA-256 |
|---|---|
| `02_rtl/rtl/p2f_dct2_64_b1_step102.sv` | `0BE2371B8D5371E3F9FCDE19DD874AB53CAA7571E18B4752FB554A9378FA7647` |
| `02_rtl/rtl/p2f_r4b_static_butterfly.svh` | `84A2FCFFB9D2D8B2EFAED1089B1B17123C428008AAC76146122EF997FA2A0F1A` |
| `03_verification/scripts/generate_r4b_static_butterfly.py` | `CDEE6F614E731E8DA64BD160D7FF522E566656CD8574A78AA053BF65A5FC88A8` |
| `03_verification/scripts/apply_r4b_static_butterfly.py` | `CF15C5EA7EB95779DC93A071E34D10FEF2C9F39F612FDEED991945B1DC74740C` |
| `03_verification/scripts/run_r4b_event_static_audit.py` | `6C2E65B0C0E38947AEAF2206B7A7B129D44FB61BB45AD161FCAEE675EEBDF2E0` |

## Gate conclusion

- Functional gate: **PASS**
- Static connectivity gate: **PASS**
- Synthesis structural improvement: **PASS** (modest LUT/failing-endpoint reduction)
- 2 ns / 500 MHz post-route timing gate: **FAIL** (WNS -0.462 ns)

R4B event-static is a valid frozen experiment and is not a 500 MHz solution.
The next optimization must target the remaining operand/DSP front-end path;
no further butterfly rewrite is justified by this experiment alone.
