# Step12F P9-R5G execution summary

Status: `CLOSED_READ_ONLY`

Baseline: `167b11c96c5658cdfa3f0182213ce89f5b40d5c7`
Fixed routed R5E DCP SHA-256: `D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C`

## Read-only inventory

Vivado 2025.2 was run through the installed executable
`D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`, with `general.maxThreads=4` and a run-local `XILINX_LOCAL_USER_DATA` directory. The fixed routed DCP was opened read-only. No `opt_design`, `place_design`, `phys_opt_design`, `route_design`, pblock, checkpoint, RTL, or XDC operation was executed.

The expanded inventory completed with:

- 64/64 exact `ingress_data_q_reg` producer cells;
- 9,198 SLICEL/SLICEM site rows;
- complete `SLICE_X40..X112 / Y55..Y180` envelope;
- DCP hash match;
- `implementation_commands=FORBIDDEN`.

The 1.73 MB candidate-site CSV remains in the local evidence workspace. The
public GitHub mirror intentionally publishes only this bounded summary and the
small status artifacts; detailed cell/site inventory files are not uploaded
without an explicit decision to expose that layout metadata. No truncated
replacement is used.

## Bounded producer-only screen

The historical exhaustive virtual frontier was not rerun. A finite screen evaluated four fixed X2Y2/X2Y1-boundary corridors × eight deterministic subsets = 32 pairs. The screen used the existing fixed-DCP upstream/downstream path census plus the fresh site inventory only for capacity and anchor validation.

Fixed gates were:

- bounded upstream-negative and upstream-passing distance risk;
- clear aggregate improvement for negative downstream paths;
- no distance increase in negative/near-zero downstream populations;
- two-FF-per-moved-bit headroom and <=50% projected FF utilization.

Result:

```yaml
decision: NO_PRODUCER_ONLY_CANDIDATE_IN_BOUNDED_SCREEN
evaluated_pairs: 32
passing_pairs: 0
```

This is an engineering stop for the finite producer-only experiment. It is not a proof that every producer relocation is impossible and does not authorize a pblock, G1 CONTROL/TREATMENT, R6 RTL, or a timing claim.

## Next action

Stop expanding producer-only locality. Return to the R5F distributed multi-family setup-tail census and choose the next intervention only if it has a direct 500 MHz or PPA rationale. RTL, XDC, Oracle/profile, R4C, and `v3.5-18` remain frozen.
