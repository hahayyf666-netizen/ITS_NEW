# V35 P2F-B1 DCT2-64 RTL Functional Prototype

## Scope

This version is a complete copy of the P2F engineering tree with an
independent DCT2-64 factorized RTL prototype added.  Only the DCT2-64 1D
kernel is implemented in B1.  DCT8, DST7, LFNST, full-Core integration,
Vivado synthesis, and Vivado implementation are intentionally out of scope.

The V3.4 baseline remains untouched.  The B1 RTL does not use the retired A1
32-group FIFO as a kernel gate; its result port is guaranteed-accept.

The copy was checked by relative-path SHA-256 comparison against
`D:\Workspace\ITS_STUDY_V35_P2F_PRE`: 27,662 source files, 0 missing in B1,
0 different-content common files.  B1 contains 40 additional generated B1
artifacts (RTL/table/testbench/log files and simulator outputs).

## Generated implementation

| Artifact | Purpose |
|---|---|
| `02_rtl/rtl/p2f_b1_tables.svh` | mechanically generated lane/source/coefficient/dot/signal map |
| `02_rtl/rtl/p2f_dct2_64_b1.sv` | 128-lane exact factorized DCT2-64 RTL prototype |
| `03_verification/scripts/generate_p2f_b1_rtl.py` | regenerates the RTL operation table from the frozen Python schedule |
| `03_verification/tb/p2f_dct2_64_b1_tb.sv` | self-checking ModelSim testbench |
| `03_verification/scripts/generate_p2f_b1_testbench.py` | regenerates test vectors and expected values from the independent Oracle |
| `03_verification/sim/run_p2f_b1.do` | ModelSim run script |

The generated operation table contains exactly 1368 operations and 124 signal
nodes.  The RTL exposes 128 lane products, A/B 64-sample input buffers, exact
E/O butterfly signal reconstruction, four result banks, and a four-wide
guaranteed-accept output port.

## Functional test coverage

The testbench runs 49 vectors:

- zero, all-positive maximum, all-negative minimum;
- both alternating extreme patterns;
- single positive/negative extremes and sparse mixed extremes;
- eight DCT2-64 one-hot positions;
- 32 full-range random vectors using seeds 20260904 and 20260905.

Expected values are generated from the independent canonical `A=C^T` Oracle,
not from RTL output or legacy golden files.  Each valid beat compares:

```text
raw[4]
biased[4]
shifted[4]
stage16[4]
final10[4]
vector_id
group
first/last
```

The testbench also checks launch intervals and valid-output intervals.  The
four required initial vectors are launched at intervals of 16 cycles, and all
groups are checked for a one-cycle interval, including vector boundaries.

## ModelSim evidence

Tool: ModelSim SE-64 2020.4 (`D:\software\Modelsim\win64`).

```text
vlog: Errors=0, Warnings=0
vsim: Errors=0, Warnings=0
B1_PASS cases=49 fires=784 positive_wrap_outputs=950 negative_wrap_outputs=935
```

Representative continuous output boundaries:

```text
vector 0: group 0 tick 15, group 15 tick 30
vector 1: group 0 tick 31, group 15 tick 46
vector 2: group 0 tick 47, group 15 tick 62
vector 3: group 0 tick 63, group 15 tick 78
```

Thus each vector has 16 groups, each group contains four complete fixed-point
results, and there is no valid-output bubble between consecutive vectors in
the tested stream.

Logs:

- `03_verification/sim/logs/p2f_b1_compile.log`
- `03_verification/sim/logs/p2f_b1_functional.log`

## Gate result

```text
exact factorized DCT2-64 functional result       PASS
128 lane operation mapping                       PASS
vector interval = 16                            PASS
16 groups/vector                                 PASS
4 complete results/cycle                         PASS
continuous group interval = 1                    PASS
tag alignment                                    PASS
positive/negative wrap coverage                  PASS
V3.4 modified                                    NO
Vivado run                                       NOT RUN (Step 10 restriction)
full-Core integration                            NOT STARTED
```

## Boundary

This is a functional RTL prototype result only.  It does not prove 500 MHz
timing, FPGA resource usage, or full-TU/Core-level admission and backpressure.
Those checks require a later implementation step and must not be inferred from
this report.
