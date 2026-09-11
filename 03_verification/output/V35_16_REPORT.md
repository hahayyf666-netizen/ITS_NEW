# V3.5-16 Pre-Step12B Validator Closure

Status: **PASS**

- One IntegrationModel.tick() owns the absolute cycle.
- H kernel groups write ResultMemory in the same cycle; historical replay is forbidden.
- Result output uses one-cycle synchronous response and a two-entry elastic holding path; ready steady-state output_fire II=1.
- Input data/end are accepted only on vld&&req / end&&req.
- A persistent R4C contract is reused across both phases.
- Four-bank memories model one read and one write port per bank.
- Epoch wrap scrubs four tag banks in parallel for 1024 cycles.
- Negative mutations are fail-closed and part of the overall gate.
- Validator identity uses permanent invocation serial; vector_id is checked only as the visible 16-bit tag.
- The frozen independent P1-A oracle is vendored under 04_reference/oracle.
