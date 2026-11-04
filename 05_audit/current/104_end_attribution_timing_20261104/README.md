# End-attribution repair and 500 MHz timing evidence

The report set in `physical/` records the fully routed `step12f_registered_neighbor_harness` implementation for `xcku5p-ffvb676-2-e` at 2.000 ns. The implementation uses the RTL whose SHA-256 is recorded in `physical/SOURCE_ARTIFACT_HASHES.json`.

The physical strategy was `opt_design -directive Default`, `place_design -directive ExtraNetDelay_high`, `phys_opt_design -directive AggressiveFanoutOpt`, and `route_design -directive NoTimingRelaxation`. The repository flow at `03_verification/vivado/run_step12f_registered_neighbor.tcl` now selects that strategy. `END_ATTRIBUTION_VALIDATION.json` combines the functional qualification summary with the selected physical result.

The end-attribution and supplemental SystemVerilog tests are under `03_verification/tb/`; the proposed interface contract is under `01_docs/current/`. The official contest-equivalence status remains `NOT_PROVEN`. The timing result is registered-neighbor core-level evidence; it is not package-level board signoff. Setup slack is 0.006 ns (6 ps), so the measured margin is small.

Current functional replay, supplemental tests and portable logs: ../105_functional_closure_20261104/. The original 104 functional summary is historical; use 105 for current replay.
