# V3.5-17.2 Same-Edge Memory Timing Decision

状态：verification-only closure evidence；不修改 `02_rtl/rtl/`，不运行 Vivado。

## 决策依据

`step12b_memory_timing_probe_tb.sv` 对冻结 Step12B wrapper 的实际 clocked RTL 读取进行独立测量。当前 wrapper 在 staging 时钟块内直接读取 cache/intermediate bank array，并在同一 accepting edge 完成 lane capture：

```text
V/H staging read_request edge == lane_capture edge
first request/capture → stage_full = 15 edges
stage_full → vector_start >= next edge
```

这不是通过 comparator offset 对齐，也不是修改 RTL 后得到的结果；原 STOP 证据和 probe CSV 保留在本目录中。

## Python 合同

周期模型从旧的单一 `READ_LATENCY` 拆成两个明确参数：

```text
STAGING_CAPTURE_EDGE_DELTA = 0
RESULT_READ_LATENCY         = 1
```

因此 input-cache/intermediate 的 `memory_read_request`、`memory_read_response` 和 `stage_lane_capture` 属于同一事务边沿；ResultMemory 仍严格采用 `request C → response C+1`，hold/skid 和 output-fire 语义不变。

每个 staging vector 记录 64 个 lane-level capture，并在最后一个 lane 到达的 edge 记录 `stage_full`。每个请求/响应带 memory、bank、address、request_id；scrub 记录 cache、episode、bank、index，并按每个 episode 验证 1024 个 cycle、4 bank/cycle。

## 禁止项

如果未来重新测量发现 RTL 与上述 same-edge 合同不一致，必须停止并保存差异证据；不得通过 per-event offset、TU-specific offset 或 normal/SYNTHESIS-specific offset 强行对齐，也不得在本 verification-only 版本修改 RTL。

## 当前模型结果

`step12b_cycle_results.json` 报告：zero/sparse/alternating/random、ready-high/backpressure、two-TU、vector-ID wrap、epoch scrub、stage-lane/owner/bank/request-id 及 scrub mutation gates 均 PASS。该结果只证明软件合同与已测 RTL timing decision 一致，不包含 synthesis、RAM inference 或 500 MHz 结论。
