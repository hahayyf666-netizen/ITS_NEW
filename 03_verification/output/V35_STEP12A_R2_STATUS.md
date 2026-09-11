# V35 Step 12A-R2.1 status (historical)

The former Step 12A, Step 12A-R and Step12A-R2 scripts are retained as
historical evidence. Step12A-R2.1 is no longer the current executable
integration gate; it is superseded by Step 12A-R2.2.

It advances one absolute integration cycle at a time. Input writes, banked
read requests, one-cycle responses, staging capture, persistent R4C
admission/output, stage16 writes/readbacks, 1024 x 40-bit result-beat writes
and one-cycle result draining are all represented in the event trace. Expected
values come from an independent operator implementation; both stage16 phases
and the final result are read back from their memories.

The former gate covered four deterministic 64x64 cases, measured vector II/group II,
bank/port/RDW checks, finite epoch wrap and scrub, vector-id wrap, A/B input
ownership/full recovery, two-TU tagged backpressure, one-cycle result output,
complete cycle event traces, and actual negative mutations. It is a model-level
gate: no wrapper RTL or Vivado implementation is included.
