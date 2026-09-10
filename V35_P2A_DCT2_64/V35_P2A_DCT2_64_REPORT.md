# V35 P2A DCT2-64 P4 Prototype Report

## Scope

This is an independent DCT2-64 1D prototype.  It does not modify or integrate
the V3.4 core, and it does not implement DST7, DCT8, other sizes, LFNST, P2B,
or a complete contest top.

## Frozen architecture

- 256 multiplication lanes (64 input indices × 4 output lanes).
- Four registered 64-term reduction trees, 252 pairwise add nodes total, with
  a uniform 40-bit signed reduction width.
- Coefficients are the canonical DCT2-64 `inverse_operator` (already `C^T`),
  selected dynamically for all 16 groups; no second transpose is performed.
- Two 64×16-bit vector buffers (A/B), non-stalling compute pipeline, and a
  32-group result FIFO.
- Strategy B capacity contract: group 0 is admitted only when 16 slots are
  free; reserved in-flight groups plus occupied FIFO groups never exceed 32.
- One group is issued per cycle; one 64-point invocation consists of groups
  0..15 and therefore has a 16-cycle invocation interval when admitted.
- Each accepted output beat contains four complete signed16 values after
  `raw -> +32 -> arithmetic >>>6 -> wrap16`.

## Independent functional verification

Expected values were generated before simulation from
`D:\Workspace\ITS_STUDY_V35_ORACLE\v34_rtl_bitexact.py`; no RTL value or
existing golden file was used to make expected data.  The testbench compares
raw dot products, biased values, shifted values, stage16 values, and FIFO
output data, including vector/group/first/last tags.

ModelSim result: **PASS**.

The directed set contains all-max, all-min, alternating, deterministic random,
and sparse mixed signed16 inputs.  The first two cases intentionally trigger
positive and negative wrap16 terms:

| vector | positive-wrap terms | negative-wrap terms | shifted min | shifted max |
|---:|---:|---:|---:|---:|
| 0 | 17 | 10 | -620013 | 1896902 |
| 1 | 10 | 17 | -1896960 | 620032 |
| 2 | 17 | 10 | -620023 | 1896931 |
| 10 | 18 | 25 | -853610 | 252420 |
| 11 | 15 | 31 | -230908 | 108031 |


The testbench also checks group ordering and no issue/output bubbles in the
ready=1 phase, then holds ready=0 for 350 cycles.  During that stall it expects
exactly two admitted invocations (32 reserved/occupied result groups total),
and after recovery it checks all 32 groups for loss, duplication, or reorder.

Observed launch events were phase 1 at cycles 22, 38, and 54 (16-cycle
intervals), and phase 2 at cycles 101 and 117.  Across the two phases the
testbench performed 320 comparisons at each of the raw, biased, shifted,
stage16, and output-data levels.

The measured issue-to-stage-write latency is 10 cycles in the current RTL
(`P2A_LATENCY` markers).  The reported output-fire latency in the stalled
phase includes the intentional ready=0 interval and is not a pipeline-latency
measurement.

## Vivado OOC gate

Required command is the supplied `vivado/run_p2a_ooc.tcl` with an OOC
post-route 2.000 ns clock.  Vivado executable discovered: **D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat**.

Vivado result: **FAIL**.
No timing/utilization/power result is invented when Vivado is unavailable.

## Gate decision

Because the P2A gate requires both functional proof and a post-route OOC
500 MHz result, the current status is **P2A FAIL**.  The functional prototype
passed, but the implementation gate is not closed unless the Vivado reports
show WNS/TNS/WHS/THS all meeting the requested limits and no unconstrained
paths.  STOP here; do not start P2B or core integration.
