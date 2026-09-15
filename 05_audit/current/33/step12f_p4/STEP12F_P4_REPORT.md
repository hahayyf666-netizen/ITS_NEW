# Step12F-P4 report

## Result

P4 functional and Stage-0 descriptor separation are verified, but the fresh
2.000 ns synthesis gate remains STOP. The scheduler-to-descriptor path is
`-0.300 ns`; the descriptor-to-coefficient path is `+0.899 ns`. The old
live `slot_state/ready -> s0_coeff` direct paths have no timing paths with
non-empty endpoint matches. No place/route run was started.

## Functional evidence

ModelSim SE-64 2020.4 normal and `SYNTHESIS` runs pass 156 Gate-B numeric
cases, 13 vector-II modes, 369 Gate-C tuples / 45,636 beats per mode, 1,088
LFNST engine cases, 258 LFNST wrapper cases, and the P3 write contract. The
new directed N=4 stream passes 16 descriptors, 16 Stage-0 captures, and 16
post-capture slot releases with unique payloads and no descriptor/capture
bubbles.

## Targeted timing evidence

The synthesized checkpoint has 120 descriptor Q pins and 120 descriptor D
pins. The scheduler-to-descriptor report has a worst slack of `-0.300 ns`
(`2.281 ns` data path, 8 logic levels, about 71.2% routing). The registered
descriptor-to-coefficient report has worst slack `+0.899 ns` (`1.082 ns`,
3 logic levels). Slot-state-to-coefficient and ready/control-to-coefficient
direct reports both match non-empty source/destination sets and report no
timing paths. The operand capture register endpoint was optimized away by
Vivado (`s0_input_d=0`), so no non-vacuous operand timing proof is claimed.

## Fresh synthesis

Vivado 2025.2 on `xcku5p-ffvb676-2-e` completes synthesis in 452 seconds with
peak memory about 3.47 GB. Resources are 38,321 LUT (5,632 LUTRAM), 33,642
FF, 316 DSP, and 0 BRAM/URAM. At 2.000 ns, setup is `WNS=-1.008 ns`,
`TNS=-9235.052 ns`, 38,503 failing endpoints; hold is `WHS=-0.076 ns`,
`THS=-3.358 ns`, 45 failing endpoints. `check_timing` reports zero
unconstrained internal endpoints and `report_exceptions` reports no valid
timing exceptions.

## Decision

P4 is a functional/structural partial pass and a physical timing STOP. The
checkpoint and evidence are retained; `v3.5-18`, frozen R4C, wrapper, and
XDC remain unchanged. No tag is created. The next change must be based on the
new scheduler-to-descriptor/control timing evidence; no route is authorized
from this failed synthesis gate.
