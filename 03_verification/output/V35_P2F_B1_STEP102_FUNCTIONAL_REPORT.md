# V35 P2F-B1 Step 10.2 Functional Report

## Scope

This report covers only the Step 10.2 DCT2-64 resource-faithful shared-reduction RTL prototype in the independent R2 copy. R1 and the V3.4 baseline remain unchanged. No full-core integration, other transform types, LFNST, synthesis, Vivado implementation, timing, or PPA claim is made here.

## RTL and testbench

- DUT: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\02_rtl\\rtl\\p2f_dct2_64_b1_step102.sv`
- Generated operation/event tables: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\02_rtl\\rtl\\p2f_step102_tables.svh`
- Testbench: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\tb\\p2f_dct2_64_b1_tb.sv`
- Expected data are fixed testbench arrays generated before this Step 10.2 run; no RTL output is used to create expected values.

## ModelSim evidence

Tool: ModelSim SE-64 2020.4 (`D:\\software\\Modelsim\\win64`).

- Standard compile log: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\sim\\logs\\p2f_b1_step102_compile.log`
- Standard functional log: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\sim\\logs\\p2f_b1_step102_functional.log`
- Synthesis-macro syntax compile log: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\sim\\logs\\p2f_b1_step102_synthesis_define_compile.log`

Observed results:

```text
standard compile: Errors=0, Warnings=0
SYNTHESIS macro compile: Errors=0, Warnings=0
B1_PASS cases=49 fires=784 positive_wrap_outputs=950 negative_wrap_outputs=935
functional run: Errors=0, Warnings=0
```

The testbench compares every valid beat's `raw`, `biased`, `shifted`, `stage16`, `final10`, `vector_id`, `group`, `first`, and `last`. It checks 49 cases and 784 valid four-wide beats. The log shows group 0..15 for each vector with interval 1; vector boundaries are also adjacent in the no-stall guaranteed-accept test. Positive and negative wrap cases both occur.

## Functional gate

| Check | Result |
|---|---|
| 128-lane farm / frozen 1368-op schedule | PASS (also covered by structural audit) |
| 4 complete results per valid beat | PASS |
| Stage-level bit-exact comparison | PASS, 784/784 beats |
| Group 0..15 and tag alignment | PASS |
| Group interval = 1 / no valid-output bubbles | PASS |
| Vector launch interval = 16 cycles | PASS |
| Positive and negative signed16 wrap | PASS |
| `result_accept` does not stall an admitted burst | PASS (simulation assertion) |
| Standard ModelSim compile/run | PASS |
| Vivado/synthesis/place/route/power | NOT RUN by Step 10.2 restriction |

## Boundary

This is a functional and source-structure result only. It does not prove 500 MHz timing or implementation PPA. Those require a separately authorized Vivado step.

