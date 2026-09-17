# Step12F-P9-R5C — Setup/Hold Root-Cause Qualification

## Scope

Read-only audit of the best reproducible R5 implementation (`B0_NETDELAY_REPLAY`).
The routed DCP was opened without synthesis, optimization, placement, routing,
RTL, XDC, or constraint changes.

Baseline commit: `1ffea5276fc4c95cac34ffc42cd0a66b98c2e8b3`  
DCP SHA-256: `39DE741B81CBB7525B4D877BEB0A6E272969D4FA56665833B90FF720A250002A`  
Vivado: 2025.2, `xcku5p-ffvb676-2-e`, 2.000 ns, maxThreads=4.

## Timing snapshot

| Axis | WNS/WHS | TNS/THS | Failing endpoints | Negative paths | Unique endpoints |
|---|---:|---:|---:|---:|---:|
| Setup | -0.063 ns | -1.776 ns | 84 | 84 | 84 |
| Hold | -0.080 ns | -4.764 ns | 65 | 65 | 65 |
| Async reset removal | +0.010 ns worst | 0 | 0 | — | — |

All paths were taken from the full negative-path query, not from the 100-path
display window. The textual reports are retained alongside the CSV census.

## Hold conclusion

All 65 negative min-delay paths start at input ports, have zero logic levels,
and terminate at first-register data pins. The families are:

| Source family | Count | Sample TNS |
|---|---:|---:|
| `it_info` → `desc_mem_reg` | 44 | -3.401 ns |
| `it_data_in` → `fill_wr_cmd_data_q_reg` | 16 | -1.228 ns |
| `it_data_addr` → `fill_wr_cmd_addr_q_reg` | 5 | -0.135 ns |

The routed path has approximately 11–12 ps data delay and uses the frozen
`set_input_delay -clock clk -min 0.000` contract. The DCP has no placed package
I/O location, IBUF/IODELAY, or IOB-FF evidence for these paths. Therefore the
classification is:

> `INTERFACE_OR_OOC_HARNESS_STRONGLY_INDICATED_NOT_PROVEN`

This is not a license to relax the XDC. The next responsibility check must use
the final contest/top-level interface methodology, including the intended
earliest-arrival assumption, clock edge/latency, and any real I/O placement.

Reset removal is not a hidden negative hold problem: the negative census contains
no `rst_n` paths, and the async-default group reports zero failing endpoints.

## Setup conclusion

The 84 negative setup endpoints are distributed across multiple families:

| Family | Count | Sample TNS | Worst slack |
|---|---:|---:|---:|
| P4 slot state | 20 | -0.581 ns | -0.060 ns |
| Cache read command | 16 | -0.337 ns | -0.063 ns |
| P4 FIFO control | 20 | -0.290 ns | -0.045 ns |
| Wrapper kernel vector | 11 | -0.244 ns | -0.036 ns |
| LFNST control | 10 | -0.252 ns | -0.041 ns |
| H-read/kernel control | 6 | -0.074 ns | -0.028 ns |
| Other P4 control | 1 | -0.003 ns | -0.003 ns |

This is a distributed multi-family timing tail. No single path family is
authorized as an R6 RTL target by this read-only census. The counts are one
representative negative path per endpoint; they are not a claim that each
family's sample TNS equals the complete design TNS beyond the 84 failing
endpoints.

## Frozen decision

```yaml
P9-R5C: COMPLETE_READ_ONLY
R5: RETAINED
RTL: UNCHANGED
XDC: UNCHANGED
resynthesis: NOT_RUN
implementation_rerun: NOT_RUN
hold_signoff: false
setup_signoff: false
500MHz_signoff: false
P9-R6_RTL: NOT_AUTHORIZED
```

The remaining hold issue belongs first to interface/OOC signoff responsibility;
the setup issue remains a distributed timing tail. No automatic RTL or XDC
change follows from this batch.

