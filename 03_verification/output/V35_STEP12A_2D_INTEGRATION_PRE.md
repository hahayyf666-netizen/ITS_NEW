# V35 Step 12A — DCT2-64 2D Integration PRE

**Status: PASS** (cycle-level software proof; no RTL/Vivado in this step)

## Frozen scope
- One frozen R4C DCT2-64 kernel is reused for all 64 vertical and 64 horizontal vectors.
- Scope is 64×64, DCT2×DCT2, LFNST=OFF; vertical completes before horizontal staging.
- Main operator is canonical `inverse_operator A=C^T`, consumed directly; no second transpose.
- Sparse input contract: the contest nominal stream sends nonzero entries and skips zeros. The robust wrapper semantics are: sent addresses take the sent value; unsent addresses read as zero.
- TU admission occurs only after `it_data_end`/TU completion; no vertical read starts before completion.

## Memory and staging contract
- Dense TU cache uses epoch-valid entries in this proof; stale physical words are poisoned before each TU. An unwritten address therefore resolves to zero.
- Candidate mapping (to be implemented only after this proof): `bank=(row[1:0] XOR col[1:0])`, `addr=row*16+(col>>2)`.
- Exhaustive bank result: 2048 aligned vertical/horizontal four-point accesses, conflicts=0; each bank has 1024 unique addresses.
- Synchronous memory read latency is modeled as 1 cycle.
- Vertical results write `stage16` to 4-bank intermediate memory. Horizontal reads `stage16`; only its result is reduced to final low10.

## Cycle contract
- R4C abstract latency: 24 cycles to the first group.
- Staging supplies 4 points/cycle for 16 cycles; vector starts are 16 cycles apart once the phase is ready.
- Vertical: 64 vectors, vector II=16, 16 groups/vector, group II=1; first starts 17 and 33, last output cycle 1064.
- V→H transition latency: 18 cycles in this read-latency-1 schedule.
- Horizontal: 64 vectors, vector II=16, 16 groups/vector, group II=1; first start 1082, last output cycle 2129.
- Output groups are tagged with global vector IDs: TU0 V=0..63/H=64..127; TU1 V=128..191/H=192..255 (16-bit modulo sequence).

## Numeric and stale-data checks
- Fixed seed: 20260904; cases: 4 (zero, sparse, alternating/extreme, full-range random).
- Matrix path: vertical stage16=True, horizontal stage16=True, final10=True.
- TU stale-data poison: TU1 omitted TU0's nonzero address and read 0 (expected 0).

## TU-level result reservation/backpressure
- Final store capacity is 1024 groups = 4096 results. Horizontal admission reserves all groups before the non-stoppable burst.
- Reservation semantics: `reserved += 1024` at admission; each produced group moves one unit reserved→occupied; each accepted output decrements occupied.
- Stress: TU0 produced/drained 1024/1024 groups and TU1 produced/drained 1024/1024; output request low for 64 cycles; TU1 blocked while full and admitted after drain.
- Tagged beat checks: TU0/TU1 store and drain order exact; no_loss_duplicate_reorder=True.
- Invariant: `reserved+occupied <= 1024`, maximum observed=1024; in-flight is not double-counted.

## Gate result
- Bank/address/port model: PASS if conflict count is zero (current result is zero).
- Numeric vertical/horizontal/final comparison: PASS if all fixed cases are equal (current result is PASS).
- Phase II and tag schedule: PASS if both phase IIs are 16 and group II is 1 (current result is PASS).
- Backpressure/admission: PASS if TU1 blocks while the single result store is full and later resumes without loss/reorder (current result is PASS).
- This report proves the Step 12A cycle/dataflow contract only. It does not claim wrapper RTL or 500 MHz closure.

Canonical SHA-256: `d4c497cfbae64096c69d640bad154e4e3bae1f5834f82149623a83028b81e9f6`
