# P9 independent fresh replay — reproduced nominal 500 MHz core timing

Status: PASS under the registered-neighbor integration contract. Two independent fresh synthesis/implementation processes give setup WNS +0.001 ns, TNS 0, zero failing endpoints; hold WHS +0.011 ns, THS 0, zero failing endpoints. No RTL, profile, harness or existing XDC changes.

## Scope and provenance

Replay baseline: 7feaa07fa632edda6b5b5cdf9f979a65a1b170d3.
Functional source: 9b33d9f62de49f022765cd594704353edeaa352c.
First physical evidence: ../99_p9_primary_v_return_20261005/.
Vivado 2025.2 build 6299465; xcku5p-ffvb676-2-e; maxThreads 4; 2.000 ns clock; user uncertainty 0.000 ns. Tool-derived jitter remains enabled. SAT10 is a provisional engineering decision; official equivalence NOT_PROVEN.

Fresh replay (PID 28680, unlike first PID 15128) started 2026-10-06 10:07:18 +08:00 and ended 10:53:46 +08:00. Existing runner exited 0. No old DCP reuse/incremental implementation. All 131 logged tool-stage checksums match the first run.

```tcl
synth_design -top step12f_registered_neighbor_harness -part xcku5p-ffvb676-2-e -flatten_hierarchy none -directive Default
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
```

## Gates

- Fully Routed: 43544 / 43544 routable nets; routing errors 0; DRC errors 0.
- No unconstrained internal endpoints; no valid timing exceptions.
- Boundary FFs: source 54/54 and sink 44/44, both post-synth and post-route.
- Read-only routed boundary worst setup: source→DUT +0.156 ns; DUT internal +0.008 ns; DUT→sink +0.001 ns.
- Input-fire real driver→command address D/CE and bank raw-data D/CE: NO_TIMING_PATHS with nonempty queried objects.
- Command→RAM→raw capture +0.080 ns; raw→return FIFO +0.108 ns; FIFO→P4 ingress +0.598 ns; ingress→input_mem +0.014 ns.
- Separate reset audit: worst recovery +0.053 ns; worst removal +0.152 ns (5137 async endpoint pins queried). No reset timing waiver added.
- Functional PASS inherited from unchanged tested sources: normal/SYNTHESIS, Gate-B 156, Gate-F 13, Gate-C 369 / 45636 beats, LFNST 1088/388, SAT10 exhaustive 65536, overflow/backpressure/two-TU, primary-V depth-4 real-stall/order/II1. No new ModelSim run is claimed.

Global leader remains output_index→result RAM/read mux→sink output bit21, +0.001 ns. Resources: LUT 26272, distributed RAM LUT 5706, SRL LUT 12, FF 21369, DSP 320, BRAM/URAM 0. Vectorless power 1.419 W (Medium confidence, not measured activity).

## Evidence boundary

This is reproduced nominal registered-neighbor core timing PASS, NOT package-level FPGA signoff and NOT margin qualification. Only 1 ps reported setup margin remains. User clock uncertainty is zero; real-system clock budget requires separate qualification.

NSTD-1 / UCIO-1 remain for clk/rst_n because package pins/IOSTANDARD are outside this harness contract. External rst_n has no input-delay model; internal synchronized release recovery/removal is checked, but external reset/package timing is not signed off.

Large DCPs are retained locally and identified by full SHA256 in the manifest; logs, journals and text reports are published. Artifact hashes distinguish working-tree bytes from LF-normalized Git bytes. No main merge and no new tag.

