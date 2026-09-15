# Step12F-P8.1 report

## Result

P8.1 functional verification passes in both ModelSim normal and `SYNTHESIS`
modes. Fresh synthesis completes. The subsequent full implementation also
completes and reports a fully routed design, but setup and hold timing both
fail; therefore P8.1 is a physical-timing STOP and no 500 MHz signoff or tag
is authorized.

The published P8 parent is `29dd5df64bb4c6980325db31f2d8a1e7f177c6cc`.
The full local evidence run was originally based on P8 commit
`c6ec4f2ee5ab17b41a7fb26faa9f0ea83cd3e21a`; both share P7 parent
`48e55acb2e5b53772ee9be1633815ba94c60edf7`. Their RTL is semantically
identical when terminal blank-line normalization is ignored, while the
published P8 commit intentionally contains a smaller evidence subset.

## Functional evidence

The ModelSim SE-64 2020.4 campaign passes 156 Gate-B numeric cases, all 13
one-dimensional vector-II modes, 369 Gate-C tuples / 45,636 beats per mode,
1,088 LFNST engine cases, 258 LFNST wrapper cases, the P3 V-write contract,
and the directed N=4 slot-release stream in both normal and `SYNTHESIS`
modes. The machine-readable run record is
`step12f_p8_1_coverage_20260915/STEP12F_COVERAGE_MODELSIM_RUN.json`.

P8.1 keeps `input_group_fire` as a same-edge transaction event for local
response consumption and feed bookkeeping. The feed and drain counters are
separate; the registered `input_vector_done` token owns FEED-to-DRAIN
completion; and the wrapper-local start-issued state owns START-to-FEED. The
external protocol, arithmetic, ordering, group II 1, and vector II `N/4`
contracts are unchanged.

## Fresh synthesis

Vivado 2025.2 on `xcku5p-ffvb676-2-e` at a 2.000 ns target completes fresh
synthesis. Post-synthesis setup is `WNS=-0.223 ns`, `TNS=-568.870 ns`, with
3,861 failing endpoints. Hold is `WHS=-0.076 ns`, `THS=-3.372 ns`, with 46
failing endpoints. The post-synthesis design uses 30,387 CLB LUTs (5,639
LUT-memory LUTs), 25,231 registers, 320 DSP48E2, and no BRAM/URAM.

The synthesis leader is a local bounded-LFNST product path, not the old
P8 same-edge control family. This demonstrates that P8.1 changed the control
topology, but it does not constitute a timing pass.

## Full implementation

The fixed flow was:

```text
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
```

Routing completed with zero unrouted nets, zero partially routed nets, and a
Vivado DRC design state of `Fully Routed`. The final post-route results are:

```text
Setup: WNS=-1.034 ns, TNS=-19931.496 ns, 49,916 failing endpoints
Hold:  WHS=-0.080 ns, THS=-3.438 ns, 46 failing endpoints
```

Post-route utilization is 30,641 CLB LUTs, 25,954 registers, 320 DSP48E2,
and zero BRAM/URAM. Estimated total on-chip power is 2.035 W.

The first routed setup path is:

```text
kernel_rd_req_pending_q_reg_replica/C
  -> generated input-cache bank address/read network
  -> distributed RAMD64E read
  -> LUT6/MUXF7/MUXF8 response selection
  -> lfnst_mem_resp_data_q_reg[4]/D
```

It has 3.016 ns data delay, including 0.792 ns logic and 2.224 ns routing,
for `WNS=-1.034 ns`. A second leading path from `kernel_stage_q` to another
LFNST response register is in the same input-cache distributed-RAM read
family. Thus the route result exposes a new/retained LFNST gather/read
physical bottleneck; it does not prove a functional regression in the P8.1
feed/drain semantics.

## Constraints and signoff boundary

Post-route `check_timing` reports zero no-clock, unconstrained internal,
missing-I/O-delay, loop, and latch-loop findings. `report_exceptions` says
`No valid timing exceptions found`. DRC reports `Fully Routed` with no DRC
errors. Known DSP pipelining, OOC clock/interface-context, and fixed-routing
hold warnings are retained as audit notes. The OOC context warnings are not
claimed to be the unique cause of the -0.080 ns hold result.

P8.1 therefore has the following status:

```yaml
functional: PASS
fresh_synthesis: PASS_COMPLETED_BUT_TIMING_FAIL
implementation: FULLY_ROUTED
physical_timing: P1_STOP
500MHz_signoff: NOT_REACHED
tag: NOT_CREATED
```

The next action is routed root-cause analysis of the LFNST gather/read family
and comparison with the P8/P8.1 baseline. R4C, XDC, Oracle/profile, arithmetic
contracts, and `v3.5-18` remain frozen until a new narrow repair is justified.
