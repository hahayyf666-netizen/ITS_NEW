# V35 Step 10.1 — P2F-B1 Pipeline Structural Hardening

## Scope and isolation

- Working copy: `D:\Workspace\ITS_STUDY_V35_P2F_B1_R1`.
- The original `D:\Workspace\ITS_STUDY_V35_P2F_B1` was not modified.
- This step targets only the DCT2-64 P4 functional prototype. It does not
  integrate the full ITS core, add other transform types, or run Vivado.
- The frozen 1368-operation schedule and 128 multiplier-lane limit are
  unchanged.

## Structural changes

- `p2f_dct2_64_b1_step101.sv` is the active Step 10.1 module used by the
  self-checking testbench. The pre-hardening module is retained in the copy
  for rollback/reference.
- `lane_product_reg[0:127]` provides an explicit registered multiplier-output
  boundary. Products are written to generated `(dot, term)` slots in
  `term_mem`; there is no `dot_acc_next += lane_product` reduction chain.
  A source scan of the active Step 10.1 module found no `dot_acc_next` symbol.
- The registered balanced fabric is:

  `mul_reg/term_mem -> red_l0 (32) -> red_l1 (16) -> red_l2 (8) -> red_l3 (4) -> red_l4 (2) -> red_l5 (1)`.

  Every level has a clocked register boundary and all short dots use zero-filled
  terms.
- The exact 124-node butterfly graph is committed by generated signal level
  (`p2f_sig_level`) over five registered phases. No full graph is evaluated as
  one combinational chain.
- `result_accept` is used only by a simulation assertion. It does not control
  progress of an already-started result burst.
- The output remains a guaranteed-accept four-wide port carrying completed
  `raw`, `biased`, `shifted`, `stage16`, and `final10` values for verification.
  The raw/biased/shifted memories and output assignments are guarded by
  `` `ifndef SYNTHESIS ``; a synthesis-defined compile was also checked with
  zero errors/warnings, so those debug copies do not enter an implementation
  build.

## ModelSim verification

Tool: ModelSim SE-64 2020.4 (`D:\software\Modelsim\win64`).

Compilation:

```text
vlog: Errors=0, Warnings=0
```

Synthesis-defined syntax check:

```text
vlog +define+SYNTHESIS: Errors=0, Warnings=0
```

Functional run:

```text
B1_PASS cases=49 fires=784 positive_wrap_outputs=950 negative_wrap_outputs=935
vsim: Errors=0, Warnings=0
```

Each beat is compared against the generated independent expected arrays for
`raw`, `biased`, `shifted`, `stage16`, `final10`, `vector_id`, `group`,
`first`, and `last`.

Observed output boundaries remain continuous:

```text
vector 0: group 0 tick 27, group 15 tick 42
vector 1: group 0 tick 43, group 15 tick 58
vector 2: group 0 tick 59, group 15 tick 74
vector 3: group 0 tick 75, group 15 tick 90
```

Thus the registered latency increased, but each vector still produces 16
groups with group interval 1 and no valid-output bubble across vector
boundaries. The testbench launches vectors at 16-cycle intervals.

## Gate status

```text
registered multiplier outputs                 PASS
balanced registered reduction levels           PASS (structural)
registered butterfly phases                   PASS (structural)
1368-op schedule unchanged                    PASS
128 lanes unchanged                           PASS
stage-level bit-exact                         PASS
49 cases / 784 beats                          PASS
positive and negative wrap coverage            PASS
16 groups/vector                              PASS
group interval = 1                            PASS
4 complete results per valid beat              PASS
vector launch interval = 16                   PASS
result_accept does not advance state            PASS (assertion-only)
Vivado synthesis/implementation               NOT RUN (Step 10.1 restriction)
500 MHz timing                                 NOT PROVEN
full-Core integration/backpressure             NOT STARTED
```

## Evidence files

- RTL: `02_rtl/rtl/p2f_dct2_64_b1_step101.sv`
- Generated schedule metadata: `02_rtl/rtl/p2f_b1_tables.svh`
- Testbench: `03_verification/tb/p2f_dct2_64_b1_tb.sv`
- Compile log: `03_verification/sim/logs/p2f_b1_step101_compile.log`
- Functional log: `03_verification/sim/logs/p2f_b1_step101_functional.log`

## Boundary

Step 10.1 proves functional correctness and structural pipeline separation in
simulation. It does not establish 500 MHz post-route timing or PPA; those are
reserved for the next explicitly authorized implementation step.
