# V35 Step 12A-R2.1 Integration Gate Closure

Status: **PASS**

- A single absolute cycle domain carries input, phase-local memory events, persistent R4C events and output request/response trace.
- Final expected is read back from 1024 x 40-bit result beats; no second horizontal transform is used for comparison.
- Oracle uses an independent implementation from the kernel payload path.
- Four-bank input/intermediate memories use one read and one write port per bank and +1 response latency.
- Input responses are tag-checked at the RAM response boundary; finite-epoch scrub prevents stale-data resurrection.
- R4C persists across vertical and horizontal phases; vector IDs are checked through 16-bit wrap.
- Two-TU tagged result beats are held under req=0; TU1 vertical runs while TU0 is full, and TU1 horizontal admission is blocked until TU0 drains.
- Each case writes and drains 1024 result beats with read_latency=1; final10 is compared from the drained memory, not a recomputed horizontal path.
- Horizontal stage16 is read back from final_stage16 memory and compared before low10 conversion.
- Nine negative mutations (same-bank, duplicate, short-II, wrong-ID, capacity, end-without-req, horizontal-stage16, input-full, nonmonotonic-input) are rejected.
- Event trace contains cycle, memory request/response, vector_start, kernel_group, result request and output_fire records.
