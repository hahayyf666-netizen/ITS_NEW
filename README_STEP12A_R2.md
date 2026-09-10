# V3.5 Step 12A-R2.1

This complete project copy closes the remaining Step 12A-R2 gate gaps. The
old Step 12A, Step 12A-R and Step 12A-R2 outputs remain as historical evidence
and are not used as the current gate.

Run:

```text
python 03_verification/scripts/step12ar2_executable_model.py
python 03_verification/scripts/make_step12ar2_manifest.py
```

The model uses one absolute integration clock, one persistent R4C contract
instance, four-bank synchronous memories, independent Oracle arithmetic,
horizontal and vertical stage16 readback, real 1024-beat result readback with
one-cycle result latency, finite epoch scrub, A/B input ownership, 16-bit
vector-id wrap, two-TU tagged drain, cycle event traces, and mutation checks.
No RTL, ROM, canonical matrix, golden vector or Vivado result is modified by
this step.

Step12B wrapper RTL remains blocked until the R2 evidence is independently
reviewed.
