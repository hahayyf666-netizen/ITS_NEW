# Step12F-P9 Round 5 — H-read temp-bank address-validity isolation

Date: 2026-09-16  
Base: `aa454c204a74aaeddb006e9c0ea1a74fb78b24c9` (P9-R4 merged baseline)  
Toolchain: Vivado 2025.2, ModelSim SE-64 2020.4, `xcku5p-ffvb676-2-e`, 2.000 ns (500 MHz)

## Result

R5 is a valid functional checkpoint and the targeted RTL boundary is structurally present, but this fresh implementation instance does not meet setup or hold signoff. No tag was created.

| gate | result |
|---|---|
| ModelSim normal + SYNTHESIS | PASS: 369 tuples / 45,636 beats per mode; 156 Gate-B cases; 13-mode II; LFNST 1088/258; N=4 stream |
| Fresh synthesis | completed; setup WNS -0.589 ns, TNS -65.087 ns, 498 failing endpoints |
| Fresh post-route | Fully Routed; setup WNS -0.238 ns, TNS -125.204 ns, 2,068 failing endpoints |
| Hold | WHS -0.080 ns, THS -4.691 ns, 62 failing endpoints |
| Constraints | 0 unconstrained internal endpoints; no valid timing exceptions |
| Tag | not created |

## What changed

The H-read temporary-bank address is now driven unconditionally by the registered `kernel_h_rd_addr_q`. `kernel_h_rd_pending_q`, `kernel_run_q`, and `kernel_stage_q` qualify transaction validity/response capture only; they no longer form a mux in front of the asynchronous RAM address.

The routed representative path confirms the intended topology:

```text
kernel_h_rd_addr_q_reg[0][0]/Q
  → gen_tmp_banks/.../RAMD64E ADDR
  → LUT6/MUXF7/MUXF8 read mux
  → kernel_h_rd_data_q_reg[1]/D
```

It has WNS -0.207 ns, data delay 2.187 ns (logic 0.476 ns, routing 1.711 ns), and five logic levels. The previous address-valid LUT4 is absent from this path. Targeted queries found 20 address-Q→H-response paths and zero pending/run/stage-Q→RAM-through→H-response paths in the sampled routed DCP; `tmp_rd_addr` itself is optimized away as an RTL net name.

## Global timing interpretation

R5 does **not** sign off 500 MHz. The global setup leader is now a kernel slot-state → read-request control CE path (`-0.238 ns`, 2.134 ns data delay), followed by `rd_cmd_addr_q` → LFNST response (`-0.237 ns`). The worst-500 sample contains 27 cache→LFNST paths, 19 P4 input-memory paths, 140 other cache/kernel/write paths, and 118 control/R4C paths. These counts are a sampled census, not full-design TNS.

Relative to the separate P9-R4 fresh implementation, R5 is globally worse (`-0.113 ns / -8.032 ns / 259` to `-0.238 ns / -125.204 ns / 2,068` setup), although hold TNS improves slightly (`-4.911 ns` to `-4.691 ns`). This is diagnostic only because R4 and R5 are not implementations of the same netlist.

## Frozen boundaries

P4 arithmetic/DSP/coefficient organization, input-cache memory type, LFNST arithmetic, H-read response architecture and recurrence, Oracle/profile, XDC, R4C, and `v3.5-18` remain unchanged. Functional and throughput evidence remains PASS; physical timing remains STOP.

Authoritative machine-readable evidence is in `STEP12F_P9_R5_MANIFEST.json`, `p9_r5_hread_address_validity/P9_R5_HREAD_ADDRESS_VALIDITY.json`, and `p9_r5_readonly_qualification/P9_A_ROUTED_READ_QUALIFICATION.json`.
