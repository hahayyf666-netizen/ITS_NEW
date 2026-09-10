# R3R functional verification

| Configuration | Result |
|---|---|
| ModelSim normal compile | PASS, 0 errors / 0 warnings |
| Normal stage-level simulation | PASS, 49/49 cases, 784/784 beats |
| Positive wrap count | 950 |
| Negative wrap count | 935 |
| ModelSim `+define+SYNTHESIS` compile | PASS, 0 errors / 0 warnings |
| `+define+SYNTHESIS` stage-level run | NOT PASS: 2310 errors, same as unchanged R3 baseline |

The macro run is a pre-existing observability mismatch: the DUT compiles out
raw/biased/shifted debug storage under `SYNTHESIS`, while the legacy TB still
compares those ports. It is recorded as a STOP limitation, not converted into
a pass by relying on the simulator exit code.
