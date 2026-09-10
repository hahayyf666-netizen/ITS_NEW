# V3.5 Step 12A-R

This is a complete copy of `ITS_STUDY_V35_STEP12A_DCT2_64_2D_PRE` with the
executable resource-constrained 64x64 DCT2 integration re-gate added.

The previous Step 12A result is retained as historical evidence and is not
treated as a complete cycle-level proof.  Step 12A-R adds real event-driven
input handshaking, four-bank cache access checks, one-cycle read-response
contract, stateful R4C admission/output tags, stage16 intermediate storage,
result-capacity admission, finite epoch tags with scrub, protocol negative
tests, and a separate two-TU ownership stress.

Current entry point:

```text
python 03_verification/scripts/step12ar_executable_model.py
python 03_verification/scripts/make_step12ar_manifest.py
```

No RTL, canonical matrix, ROM, golden vector, or Vivado result is changed by
Step 12A-R.  Step 12B wrapper RTL is blocked until this model remains PASS
after independent review.
