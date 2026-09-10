# V3.5 P2A-R1 Explicit DSP Pipeline Report

## Scope

This R1 copy preserves the previous P2A prototype and changes only the
multiplier implementation.  The complete ITS baseline is retained at the
R1 directory root; this report concerns the standalone DCT2-64 1D prototype
under `V35_P2A_DCT2_64/`.

The mathematical contract is unchanged: canonical DCT2-64 inverse operator,
256 multiplication lanes, four complete outputs per cycle, 40-bit reduction,
`+32 >>> 6`, signed 16-bit wrap, 16 groups per invocation, and a 32-group
result FIFO with strategy-B reservation.

## R1 change

`rtl/p2a_dct2_64_p4.sv` now has a synthesis-only generate block containing
256 explicit `DSP48E2` instances.  Each instance uses `AREG=1`, `BREG=1`,
`MREG=1`, and `PREG=1`; A/B operands are sign-extended to the native DSP
widths and `OPMODE=9'b000000101` selects the registered multiplier result.
The simulation branch models the same effective product latency without
requiring a vendor primitive library.  The reduction, FIFO, reservation,
and output interfaces were not changed.

## Functional verification

| Check | Result |
|---|---:|
| Stage-level raw/biased/shifted/stage16/output comparisons | 320/320 PASS |
| Group issue interval | 1 cycle |
| Vector invocation interval | 16 cycles |
| Positive and negative signed16 wrap cases | PASS |
| First/last/group/vector ID alignment | PASS |
| FIFO backpressure and recovery | PASS |
| Capacity `occupied + reserved <= 32` | PASS |
| ModelSim return code | 0 |

Functional log: [`sim/run.log`](sim/run.log).

The added DSP pipeline increases the observed stage latency from 12 to 14
cycles.  This does not change the II=1 group stream or the 16-cycle vector
invocation interval.

## Vivado OOC implementation

Tool: Vivado 2025.2, device `xcku5p-ffvb676-2-e`, post-route OOC, clock
period 2.000 ns (500 MHz).

| Metric | Result | Gate |
|---|---:|---|
| WNS | -2.761 ns | FAIL (must be >= 0) |
| TNS | -2145.587 ns | FAIL (must be 0) |
| Setup failing endpoints | 4763 | FAIL (must be 0) |
| WHS | +0.019 ns | PASS |
| THS | 0.000 ns | PASS |
| Hold failing endpoints | 0 | PASS |
| Unconstrained internal endpoints | 0 | PASS |
| LUT | 9308 | measured |
| FF | 12686 | measured |
| DSP48E2 | 256 | measured |
| BRAM | 0 | measured |
| Total on-chip power | 2.449 W | measured |

The worst setup path is not inside the DSP multiplier after this change; it
is the dynamically selected coefficient address path:
`issue_group_r_reg[1]_rep__3/C` to
`coeff_selected_r_reg[0][51]/ADDRARDADDR[11]`, with 4.458 ns data delay
(98.228% routing) and -2.761 ns slack.  This shows that enabling internal DSP
registers did not remove the dominant group-index-to-coefficient-memory
route.

Reports:

- [`p2a_timing_summary.rpt`](vivado/reports/p2a_timing_summary.rpt)
- [`p2a_setup_paths.rpt`](vivado/reports/p2a_setup_paths.rpt)
- [`p2a_hold_summary.rpt`](vivado/reports/p2a_hold_summary.rpt)
- [`p2a_utilization.rpt`](vivado/reports/p2a_utilization.rpt)
- [`p2a_power.rpt`](vivado/reports/p2a_power.rpt)
- [`vivado_run.log`](vivado/vivado_run.log)

## Conclusion

R1 **functional verification PASS**, but the Step 8.1 implementation gate is
**P2A-R1 FAIL** because setup timing remains substantially negative at 500
MHz.  Per the Step 8.1 instruction, this experiment stops here; no further
register stacking, P2B work, or full-core integration is started.

## Reproduction artifacts

- RTL: [`p2a_dct2_64_p4.sv`](rtl/p2a_dct2_64_p4.sv)
- Testbench: [`p2a_dct2_64_p4_tb.sv`](tb/p2a_dct2_64_p4_tb.sv)
- Simulation driver: [`run_p2a.py`](scripts/run_p2a.py)
- Vivado OOC script: [`run_p2a_ooc.tcl`](vivado/run_p2a_ooc.tcl)
- Machine-readable result: [`p2a_results.json`](p2a_results.json)

R1 RTL SHA-256:
`4f4eff40a061e31cf31022806b1a5202756e46d4df7d2ce022f24f4c02822665`
