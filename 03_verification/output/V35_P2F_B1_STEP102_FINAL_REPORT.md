# V35 P2F-B1 Step 10.2 Final Report

## Final status

```text
FUNCTIONAL RTL SIMULATION: PASS
SOURCE STRUCTURE AUDIT:     PASS
VIVADO / TIMING:            NOT RUN (forbidden in this step)
```

Step 10.2 replaces the Step 10.1 replicated reduction implementation in the independent R2 copy with a resource-faithful shared structure. The frozen DCT2-64 schedule and mathematics are unchanged: 128 multiplier lanes, 1368 operations per vector, canonical signed8 coefficients, and the existing exact fixed-point post-process.

## Implemented structure

- One registered 128-lane multiplier farm (`lane_product_reg[0:127]`).
- One shared registered reduction fabric with physical slots 64 -> 32 -> 16 -> 8 -> 4.
- Registered event-driven butterfly signal store with capacities N4/N8/N16/N32/N64 = 4/8/16/16/8.
- Two 64 x 16-bit A/B vector buffers and two dot-value contexts; no `term_mem`, per-bank reduction trees, or serial `dot_acc_next` chain.
- Simulation-only raw/biased/shifted memories are guarded by `` `ifndef SYNTHESIS ``; the macro compile passed.
- Guaranteed-accept four-wide result port. `result_accept` is assertion-only and cannot advance or stall an admitted burst.

The generated table and source-level audit are mechanical checks, not copied claims:

- Audit script: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\scripts\\run_p2f_b1_step102_structural_audit.py`
- Audit JSON: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\output\\p2f_b1_step102_structure.json`
- Audit report: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\output\\V35_P2F_B1_STEP102_STRUCTURE_AUDIT.md`

The latest audit reports `status=PASS`, 1368 generated operations, the exact shared slot bounds, zero forbidden tokens, and no missing R1 files. Only the R2 testbench binding is a changed common file; R1 itself was not modified.

## Functional evidence

Official log: `D:\\Workspace\\ITS_STUDY_V35_P2F_B1_R2\\03_verification\\sim\\logs\\p2f_b1_step102_functional.log`

```text
compile: 0 errors, 0 warnings
B1_PASS cases=49 fires=784 positive_wrap_outputs=950 negative_wrap_outputs=935
functional run: 0 errors, 0 warnings
```

The 784 beats compare all four data layers (`raw`, `biased`, `shifted`, `stage16`, `final10`) plus vector/group/first/last tags. Group 0..15 is continuous at interval 1, and vectors are launched at interval 16 in the testbench. Both wrap polarities are observed.

## Explicit non-claims and stop boundary

- No DCT8, DST7, LFNST, complete ITS core, or full contest-top integration was attempted.
- No Vivado synthesis, placement, routing, timing, utilization, power, or 500 MHz result was generated in Step 10.2.
- Therefore this step proves the shared-resource RTL's functional/structural gate only; it does not yet prove the 500 MHz gate.

## Gate decision

```text
P2F-B1 Step 10.2 = PASS for functional simulation and source structure.
Next authorized step, if desired: a separately scoped timing/implementation audit.
```
