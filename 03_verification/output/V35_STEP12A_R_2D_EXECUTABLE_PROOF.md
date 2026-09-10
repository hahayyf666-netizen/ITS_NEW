# V35 Step 12A-R Executable Cycle Re-Gate

Status: **PASS**

- Single frozen R4C black-box contract; vector admission II=16; first output latency=24.
- Input cache and intermediate memory use four single-port banks; reads have one-cycle response.
- Stage16 is written before horizontal processing; final interface keeps low10 only.
- Sparse input is accepted in strict raster-monotonic address order; missing entries read as zero.
- Mapping: bank=(row[1:0] XOR col[1:0]), addr=row*16+(col>>2); conflicts=0.
- Cases: 4; each phase has 64 vectors/1024 groups and measured II=16.
- Epoch: 2-bit tags with full 4096-entry scrub on wrap.
- Negative mutation checks: end-under-req, same-cycle data/end, capacity, dropped group, bank conflict.
