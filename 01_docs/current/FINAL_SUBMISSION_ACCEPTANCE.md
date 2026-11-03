# Full spatial reconstruction acceptance

Baseline upstream081efa63356be60233b9f351409a4fd547142ec3. Profile contest_engineering_vtm10_sat10_v2. Official equivalence NOT_PROVEN.

| Requirement | Required evidence |
|---|---|
| Complete V outputs | Analytic +/-DC for every DCT2 shape; full pointwise comparison |
| Reduced frequency support | Native VTM cross-check,369 original configurations and129 extra cases |
| Intermediate memory | Exact Cw*H/4 commits, unique/bounded addresses, one last commit, barrier before H |
| LFNST spatial reconstruction | All sets/indices across six representative shapes |
| Ownership/order/backpressure | Eight mixed queued TUs with distinct signed DC values and middle/final stalls |
| Reset reuse | Lower V outputs, final V commit, pending final output and LFNST lower V outputs; fresh zero TUs |
| Detector sensitivity | Original frozen RTL fails the strict analytic DC checker |
| Existing behavior | All36 normal/SYNTHESIS simulations with regenerated golden |
| Nominal500MHz | Fresh repaired-source synthesis/route and setup/hold reports |

qualify_full_spatial_repair.ps1 produces the functional manifest. Physical status is separate. Tool completion alone does not mean timing passed; diagnostic mismatch counters do not constitute a functional PASS.
