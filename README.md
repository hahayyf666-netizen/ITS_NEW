# Unified VVC ITS — frozen SAT10 engineering delivery

DUT functional source: 9b33d9f62de49f022765cd594704353edeaa352c.
Independent 500 MHz replay: db8dbedac12ca337f5ae351841f5574363f91174.

Submission top: 02_rtl/rtl/its_unified_submission_top.sv.
Profile: contest_engineering_vtm10_sat10_v2; signed10 saturation [-512,511].
its_top.v remains the legacy V3.4 entry.

Functional coverage: DCT2/DST7/DCT8, rectangles, LFNST, sparse signed16 input, SAT10, backpressure, ownership, order and completion. P4 group II=1, vector II=N/4. Output packs four signed10 lanes into 40 bits.

Two fresh registered-neighbor runs pass nominal 500 MHz: setup WNS +0.001 ns / TNS 0; hold WHS +0.011 ns / THS 0; Fully Routed. Package-level timing and additional clock margin are not qualified.

[Final submission acceptance and package commands](01_docs/current/FINAL_SUBMISSION_ACCEPTANCE.md).
[Submission entry, source list, coefficient staging and delivery identities](01_docs/current/FINAL_DELIVERY.md).
The package qualification regenerates vectors and runs independent models plus normal/SYNTHESIS HDL regression, with all 369 Gate-C and 388 LFNST cases on the actual submission top.

SAT10 is a PROVISIONAL_ENGINEERING_DECISION; official equivalence remains NOT_PROVEN. Main-transform fixed-point rules and LFNST-off H/V superset are engineering bindings.
Historical LOW10 audits and v3.5-18 remain preserved.

Resource reference: LUT26272, LUTRAM5706, FF21369, DSP320, BRAM/URAM0. Vectorless power estimate1.419W; activity-based power not measured.
