# Step12D PRE

Status: HISTORICAL SOURCE REVIEW STOP; ENGINEERING PROFILE GATE A/B PASS; GATE C STOP

## 1. Scope and frozen boundary

Step12D-PRE closes the logical, fixed-point, cycle, bandwidth, memory-mapping, and architecture feasibility of a unified inverse-transform fabric. It does not implement RTL and does not run Vivado.

The frozen `v3.5-18` baseline remains immutable. Its scope is only the 64x64 DCT2xDCT2, LFNST-off, single-R4C wrapper and its registered-neighbor OOC implementation baseline. Its timing result must not be inherited by a new unified kernel. Frozen R4C RTL, the existing Step12B wrapper, XDC, and the official 22-bit `it_info` interface are not modified in this PRE.

All Step12D-PRE documents and machine-readable evidence stay inside the repository. No external report is authoritative.

## 2. Source precedence

For every rule, use this precedence:

1. Huawei contest attachment and official interface definition.
2. Designated VVC/reference sources and the frozen canonical data.
3. Explicit engineering contract, labelled as such.

An attachment omission or inconsistency is recorded as unresolved or as an engineering assumption. It is never silently converted into an official rule.

## 3. Official source extraction currently completed

The supplied Huawei attachment lists the following block-size support rows:

- DCT2: 4x4, 4x8, 4x16, 4x32, 4x64, 8x4, 16x4, 32x4, 64x4, 8x8, 8x16, 8x32, 8x64, 16x8, 32x8, 64x8, 16x16, 16x32, 16x64, 32x16, 32x32, 32x64, 64x16, 64x32, 64x64.
- DCT8: 4x4, 4x8, 4x16, 4x32, 8x4, 16x4, 32x4, 8x8, 8x16, 8x32, 16x8, 32x8, 16x16, 16x32, 32x16, 32x32.
- DST7: the same 16 block sizes as DCT8.
- LFNST nTrs=16: 4x4, 4x8, 4x16, 4x32, 4x64, 8x4, 16x4, 32x4, 64x4.
- LFNST nTrs=48: 8x8, 8x16, 8x32, 8x64, 16x8, 32x8, 64x8, 16x16, 16x32, 16x64, 32x16, 32x32, 32x64, 64x16, 64x32, 64x64.

The attachment's `it_info` table has a source inconsistency: its width cell says 20 while the same description uses fields `[19:18]` and `[21:20]`. The repository and frozen RTL contract use 22 bits, which is also the only width consistent with the listed bit ranges. Step12D-PRE records this inconsistency and keeps the 22-bit interface unchanged; it does not reinterpret or narrow the interface.

The rows above are official shape/type support evidence. They are not yet a complete `tr_type_hor` x `tr_type_ver` descriptor tuple matrix. No default Cartesian product is permitted. Axis coupling must be resolved from an authoritative source or explicitly marked unresolved.

## 4. Fixed-point rule

Every legal `transform_type x N x stage` case gets an independent fixed-point contract. The existing DCT2-64 `(+32)>>6 -> signed16 wrap` baseline and final low10 mapping are reference evidence only; they may be promoted to another case only after source and independent-Oracle confirmation. LFNST has its own `(+64)>>7` and Clip3 reference contract, which is likewise checked per legal case.

## 5. Independent Oracle and schedule model

The Oracle and cycle/schedule model may share only immutable canonical coefficient data, source IDs, and its hash. They must not share dot-product, rounding/wrap/clip, schedule execution, or expected-output code.

Each legal one-dimensional case must have an executable P4 schedule with four complete outputs per group and group II=1. A failure in one candidate architecture does not fail PRE; A/B/C candidates and their pre-frozen schedule variants are evaluated. PRE stops only if no allowed candidate covers an official legal case.

## 6. Architecture candidates

- A: fully shared multipliers and reduction fabric.
- B: shared multipliers with family-specific reduction networks.
- C: frozen R4C-64 retained, plus a new <=32/LFNST shared small kernel.

PRE selects one candidate using resource, coefficient-bandwidth, reduction-depth, mux/fanout, pipeline, mode-switching, memory-port, and risk evidence. PRE is not a 500 MHz proof.

LFNST may share the whole fabric, only multipliers, or remain an independent small kernel. This is a decision to be made from evidence.

## 7. General two-dimensional contract

For every legal W x H tuple:

- vertical vector count=W, vector length=H, vertical transform type;
- horizontal vector count=H, vector length=W, horizontal transform type;
- output is TU-raster order, four final points per output fire when accepted.

The model must freeze cache/staging/intermediate/ResultMemory bank and address formulas without hard-coding the 64x64/1024-beat case.

Latency is reported in separate forms:

- input-acceptance time for a specified descriptor and beat sequence;
- ready-high intrinsic compute/drain latency, anchored explicitly at `end_fire` and `last_output_fire`;
- backpressure-dependent completion behaviour, calculated by the state model without claiming a fixed upper bound.

The current logical mapping proof covers every extracted shape/type row (57
rows, 25 unique shapes) with the following candidate four-bank formula:
`bank = (row[1:0] XOR col[1:0])` and
`address = row * (width / 4) + floor(col / 4)`.  It checks vertical input
reads, horizontal intermediate reads, vertical intermediate writes, address
range, four-lane bank distinctness, and raster beat order.  This is a logical
conflict proof only; it is not a physical RAM-inference, placement, timing,
ownership, or complete official descriptor-tuple proof.  The machine-readable
result is `MEMORY_MAPPING_PROOF.json`.

## 8. PRE evidence and exit gate

Evidence is written under `05_audit/current/26/step12d_pre/` after confirming that the directory is unused. Expected outputs include the descriptor field map, official shape matrix, source traceability, fixed-point contracts, independent P4 schedules, A/B/C comparison, LFNST decision, general memory mapping, and cycle/resource results.

Step12D-PRE passes only when every official legal case has traceable source, an independent fixed-point Oracle, and coverage by at least one allowed executable P4 schedule; A/B/C and LFNST decisions are explicit; all rectangular mappings are conflict-free; and the machine-readable manifest is complete. Otherwise the state remains STOP in PRE and no unified RTL is authorized.

P0 stops immediately for a source/specification contradiction affecting correctness, an impossible legal case, or a mathematical/fixed-point contradiction. P1 must close before PRE ends. P2/P3 observations are recorded without expanding the gate.

## 9. Source-contract resolution status

The 2026-09-14 source-resolution batch rechecked the current official contest page, its updated attachment, and ITU-T H.266 clause 8.7.4. It closed the active-LFNST source contract: set indices 0..3 and active kernel indices 1..2 select the supplied matrices, the official nTrs/nonZeroSize and `(+64)>>7 + Clip3` rules apply, and the following two-dimensional main transform is DCT2 x DCT2.

Step12D-PRE remains STOP on exactly two root P1 source contracts:

- for `lfnst_idx == 0`, the official material does not enumerate the complete legal horizontal/vertical transform-type pairs;
- the official contest material does not define the complete main-transform intermediate scaling and final signed-10 output mapping for every case.

H.266/VTM remain reference evidence. In particular, H.266's normative two-dimensional process uses an intermediate `(+64)>>7 + Clip3` and a final shift dependent on BitDepth and Log2TransformRange, so it cannot silently replace the contest contract or prove the frozen Step12B `(+32)>>6`, wrap16, low10 engineering baseline. Architecture selection is a downstream dependency, not a third independent source blocker. See `SOURCE_CONTRACT_RESOLUTION.json` and `SOURCE_CONTRACT_CLARIFICATION_REQUEST.md`.

## 10. Engineering-profile continuation (2026-09-14)

The historical source-review result in Section 9 is preserved. Because the
contest has ended and no further normative clarification is available, the
engineering continuation uses the explicitly labelled
`contest_engineering_vtm10_v1` profile: bit depth 10, extended precision off,
dynamic range 15, VTM inverse shifts 7/10, and a LOW10 two's-complement final
adapter (SAT10 remains an alternate differential adapter). This binding is
reproducible but does not claim official or hidden-golden equivalence.

Gate A is closed for this engineering profile and Gate B has a new unified
P4 one-dimensional RTL reference covering DCT2/DST7/DCT8 at 4/8/16/32 and
DCT2 at 64. Gate C's independent software model covers the 169 LFNST-off
per-axis tuples and 200 active-LFNST tuples, including rectangles, mixed
H/V, sparse raster input, two-slot ownership, backpressure, and exactly-once
completion. The new `unified_its_wrapper.sv` and its testbench are present,
but this environment has no `vsim`, `vlog`, `iverilog`, `verilator`, or
`xvlog`; therefore normal and `SYNTHESIS`-mode HDL simulation are not claimed
and the final engineering batch is `STOP_GATE_C_HDL_SIMULATOR_UNAVAILABLE`.

The machine-readable final status is recorded in
`05_audit/current/27/step12d_engineering/STEP12D_STEP12E_FINAL_MANIFEST.json`.
No frozen R4C, historical wrapper, or XDC file was modified, and no physical
timing or Vivado result is implied by the Gate A/B/model results.
