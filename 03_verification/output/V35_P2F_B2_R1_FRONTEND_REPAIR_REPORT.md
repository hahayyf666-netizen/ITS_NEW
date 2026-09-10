# V35 P2F-B2 R1 — Multiplier Front-End Pipeline Repair

## Scope

This R1 copy was created from `D:/Workspace/ITS_STUDY_V35_P2F_B2`. Only the
DCT2-64 P2F-B1 DUT was changed. The mathematical schedule, 128-lane limit,
1368 operations/vector, reduction/butterfly resources, A/B buffers, output
contract, and FIFO policy were not changed.

Modified DUT:

`D:/Workspace/ITS_STUDY_V35_P2F_B2_R1/02_rtl/rtl/p2f_dct2_64_b1_step102.sv`

The front end now has registered schedule decode, registered operand
selection, and registered signed multiplication output. Context is delayed by
the same two cycles before reduction/butterfly launch.

## Functional gate

ModelSim compile and simulation completed with no compile errors and no
testbench errors:

```text
B1_PASS cases=49 fires=784 positive_wrap_outputs=950 negative_wrap_outputs=935
```

Thus the existing 49-case / 784-beat stage-level bit-exact regression passed,
including positive and negative signed-16 wrap cases, group ordering, and
continuous vector boundaries. The existing 128-lane structural audit also
passed; no additional multiplier lanes were introduced.

Log:

`D:/Workspace/ITS_STUDY_V35_P2F_B2_R1/03_verification/logs/p2f_b2_r1_step111_functional.log`

Structural audit:

`D:/Workspace/ITS_STUDY_V35_P2F_B2_R1/03_verification/output/V35_P2F_B1_STEP102_STRUCTURE_AUDIT.md`

## Vivado OOC post-route gate

Tool: Vivado 2025.2, part `xcku5p-ffvb676-2-e`, OOC clock period 2.000 ns.

Reports:

`D:/Workspace/ITS_STUDY_V35_P2F_B2_R1/03_verification/vivado/reports/`

| Metric | R1 result | Gate |
|---|---:|---:|
| Setup WNS | **-0.969 ns** | FAIL (must be >= 0) |
| Setup TNS | **-7891.720 ns** | FAIL (must be 0) |
| Setup failing endpoints | **20632** | FAIL (must be 0) |
| Hold WHS | +0.042 ns | PASS |
| Hold THS | 0.000 ns | PASS |
| Hold failing endpoints | 0 | PASS |
| Unconstrained internal endpoints | 0 | PASS |
| CLB LUTs | 46,897 | — |
| CLB registers | 22,812 | — |
| DSPs | 128 | within limit |
| Block RAM Tile | 0 | — |
| Total on-chip power | 4.082 W | — |

Worst setup path:

```text
Source      : red_cycle_reg[4]_rep/C
Destination : dot_value_bank_reg[1][31][23]/D
Slack       : -0.969 ns
Data delay  : 2.949 ns (logic 1.027 ns, route 1.922 ns)
```

The intended front-end path was not the final worst path after implementation;
the dominant failure is now control/reduction-cycle fanout and routing into
the dot-value bank. The R1 change therefore does not close 500 MHz.

For comparison, the B2 baseline was setup WNS -2.052 ns, TNS -19555.091 ns,
20,730 failing endpoints, hold WHS +0.044 ns, 20,709 LUTs, 18,276 registers,
128 DSPs, and 2.464 W reported power.

## Gate decision

```text
FUNCTIONAL: PASS
500-MHz OOC timing: FAIL
STEP 11.1: FAIL / STOP
```

Per the Step 11.1 instruction, no further RTL optimization, floorplanning,
factorization, P2B, or full-core integration was performed in this step.
