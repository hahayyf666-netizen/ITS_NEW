# Step12F synthesis recovery — coefficient access topology

Baseline: `b7c0a3f`. This investigation addresses synthesis completion.
The new unified kernel has no inherited R4C-64 timing proof.

## What the source and isolated synthesis show

The old top-level run stopped after 2700 seconds in Cross Boundary and Area
Optimization. Its last logged peak was 5164.590 MB. It did not establish an
out-of-memory failure or prove that the design could never synthesize.

The next investigation synthesized actual modules independently, without
black-box substitutes. Input-cache bank completed in 66 seconds and bounded
LFNST in 73 seconds. The original unified kernel alone remained in Cross
Boundary and Area Optimization until a controlled stop after approximately
605 seconds. Runs overlapped; elapsed times are diagnostic, not controlled
performance benchmarks. `ram_probe` initially used the wrong top-specific
I/O names; `ram_probe_corrected` supersedes it.

In the original kernel, four output lanes each loop over 64 input terms.
Each term dynamically indexes the same 8176-entry coefficient array using
`base + output_row * matrix_size + input_term`. This describes up to 256
logical coefficient reads per output group, not a 128-lane factorized R4C.
The RTL also evaluates multiplication, reduction, rounding and clipping
without arithmetic pipeline registers. These are separate physical issues.

## Implemented narrow repair

Canonical coefficients are transposed at elaboration into 61 output-group
bundles. Each bundle contains four rows, with 64 coefficient positions per
row. Terms outside a matrix dimension are zero padded. At runtime there is
one 6-bit bundle address and constant slices into the selected bundle.

The same canonical file is read. No coefficient, orientation, product/sum
precision, rounding, clipping, slot scheduler or handshake is changed.
There are 8176 non-padding coefficients and 7440 zero-padding positions.
This is a memory-layout transformation, not a new transform algorithm or
an added cycle of latency.

`unified_p4_kernel.sv` is the only production RTL file changed by this
investigation. The experimental copy and production copy have identical
SHA-256 `d0462619915806b77013272d4519bb522b4850dbc62157fe1d5f21e408af2af8`.

The coefficient-layout test exhaustively compares all 8176 coefficients and
7440 zero positions independently of the DUT's address functions. Both
normal and SYNTHESIS modes pass. The existing complete regression also
passes in both modes: 369 tuples / 45636 beats, 13 throughput modes, 156
kernel numeric cases, 1088 LFNST engine cases and 258 LFNST wrapper cases.
The Oracle and vector generators are unchanged.

## Completed kernel synthesis

With Default synthesis, the packed kernel completed in 503 seconds and
generated a DCP: 16059 LUT, 4218 FF, 256 DSP. The added RuntimeOptimized
diagnostic also completed (212 seconds). Both used the same 2 ns module
constraint and no timing exception. RuntimeOptimized is not the final
wrapper flow and is not used to claim performance closure.

The Default kernel timing estimate is WNS -7.549 ns; its worst path is
`output_slot_q -> coefficient/input selection -> arithmetic -> out_data`,
9.484 ns and 39 logic levels. LFNST's isolated setup estimate is also
negative. Successful synthesis therefore does not establish 500 MHz.

## Completed full-wrapper synthesis

The fresh `unified_its_wrapper` Default run completed `synth_design` in 486
seconds, with a peak logged memory use of 4545.117 MB. It produced a
14,268,039-byte post-synthesis DCP and all requested reports. Vivado reported
232 infos, 112 warnings, zero critical warnings and zero errors. No old DCP
was reused.

The synthesized wrapper uses 38,269 LUT, including 5,632 LUTRAM, 7,125 FF,
316 DSP, zero BRAM and zero URAM. Hierarchical utilization attributes 252 DSP
to `unified_p4_kernel` and 64 DSP to `bounded_lfnst_engine`.

This closes the synthesis-completion blocker, but not the 500 MHz gate. The
post-synthesis estimate is WNS -9.061 ns / TNS -87,983.219 ns with 44,270
failing setup endpoints. Hold is positive at WHS +0.468 ns / THS 0. These are
synthesized-design estimates, not post-route signoff numbers.

All first 100 setup paths start at `lfnst_ntrs48_q_reg/C`; 91 terminate at
`lfnst_input_terms_q_reg` and nine at `lfnst_grid_reg`. The worst path is
11.042 ns and 41 logic levels. The runtime 4/8-side diagonal `scan_row` /
`scan_col`, cache address, bank, validity and gather selection remain in one
deep wrapper combinational cone. Separately, isolated kernel synthesis shows
a 9.484 ns, 39-level multiplier/reduction/postprocess path. These are two
measured pipeline problems, not another coefficient-ROM elaboration problem.

The actual reports and hashes are recorded in `SYNTHESIS_RECOVERY.json` and
`wrapper_packed_default/`. Full synthesis uses the existing wrapper XDC. The
script now saves the post-synthesis DCP immediately after `synth_design`,
before the longer report phase.

## Next physical repair, after synthesis evidence

The measured wrapper gather and arithmetic paths require actual register
boundaries:

1. Replace runtime diagonal-scan arithmetic with a bounded, table-driven LFNST
   scan mapping. Register the cache read request and response metadata rather
   than recomputing row, column and bank in both request and capture cones.
2. Capture the selected P4 input vector and coefficient bundle with mode,
   stage, group, owner and last-group metadata.
3. Register multiplication using suitable DSP input/product stages.
4. Express balanced reduction with explicit register cuts. Determine the
   number of cuts from small-block 2 ns synthesis evidence; do not declare
   a fixed new latency without measuring its event sequence.
5. Register rounding/clipping and buffer outgoing groups. Track issued,
   in-flight and consumed groups so backpressure cannot overwrite a slot,
   lose a result or emit `done` before the last actual output transaction.

That repair must retain numerical behavior and ready-high group II=1 /
vector II=N/4. It will require an explicit latency/model update; merely
waiting an extra cycle around the current combinational logic is ineffective.
This report does not implement that pipeline or declare timing closed.

Banked async RAMs were independently synthesizable. A later synchronous
BRAM decision must be driven by resource/timing reports and its transaction
latency, rather than being assumed to fix this coefficient bottleneck.
AMD documents that block RAM requires synchronous read, whereas distributed
RAM does not: [UG906 memory mapping guidance](https://docs.amd.com/r/2025.1-English/ug906-vivado-design-analysis/RQS_UTIL-203-Large-ROM-Inferred-using-Distributed-RAM).

## Reproduce

Run `03_verification/vivado/run_step12f_fresh_synth.ps1` from PowerShell.
It selects Vivado 2025.2, a writable user-data directory, fresh evidence
paths, Default synthesis, the same target part and 2 ns wrapper XDC.
It requires a DCP and reports before reporting synthesis completion.
It does not route or create a tag, and does not silently overwrite evidence.

Full regression can be rerun with
`03_verification/step12d_engineering/run_step12f_coverage_modelsim.ps1`.
The recorded experimental run used `-KernelSource` to select the exact
candidate whose hash is now the production hash.
