# V3.5-17.2 Step12B verification closure

## 结论

**V3.5-17.2 = PASS / FROZEN（verification-only timing/trace closure）**。

本轮只修正 Python phase-admission 语义和一个 memory-timing checker 兼容问题；`02_rtl/rtl/`、canonical matrix、R4C、Step12B wrapper 和数学数据通路均未修改。旧的 `V35_17_2_*STOP*` 文件保留为历史证据，不代表当前结论。

## 本轮修正

- phase admission edge 只改变阶段状态；首个 V/H staging read 最早在下一 accepting edge 发出。
- staging memory 仍采用真实测得的 same-edge `read_request → lane_capture`（delta=0）；首个 request/capture 到 `stage_full` 为 15 edges。
- ResultMemory 保持 `request @ C → response @ C+1` 和 hold/skid backpressure 合同。
- memory timing checker 为 lane-level capture 使用独立 key，不再把 capture 误当成带 token 的 request。
- `run_step12b_checks.ps1` 当前入口改用 `05_audit/current/17_2/` 的模型与审计输出。

## 既有门禁复跑结果

| 门禁 | 结果 | 证据 |
|---|---|---|
| Python cycle model | PASS | `step12b_cycle_results.json`：zero/sparse/alternating/random、ready-high、backpressure、two-TU、vector-ID wrap、epoch scrub |
| Model mutation | 26/26 PASS | `step12b_cycle_results.json` / `step12b_mutation_manifest.json` |
| Epoch scrub mutation | 5/5 PASS | `step12b_cycle_results.json` |
| ModelSim normal + SYNTHESIS | PASS | `03_verification/logs/step12b_wrapper_*`、`r4c_latency_*` |
| Memory timing normal | PASS | `memory_timing_compare_normal_results.json` |
| Memory timing SYNTHESIS | PASS | `memory_timing_compare_synthesis_results.json` |
| Memory probe | 8192 requests / 8192 responses / 8192 captures / 128 `stage_full` / 4096 V writes | `memory_timing_probe_{normal,synthesis}.csv` |
| Public RTL trace normal | PASS | 128 starts / 2048 groups / 1024 writes / 1024 fires，single anchor=5 |
| Public RTL trace SYNTHESIS | PASS | 同上，single anchor=5 |
| Internal RTL trace normal | PASS | stage_capture=128、intermediate_write=1024、reserve=1、result read req/rsp=1024、latency=1 |
| Internal RTL trace SYNTHESIS | PASS | 同上 |
| RTL trace comparator mutation | 7/7 PASS | `step12b_trace_mutation_results.json` |

所有 comparator 使用一个 input-fire global anchor；没有 event-specific、TU-specific 或 normal/SYNTHESIS-specific offset。memory probe 的 `single_anchor=4` 与 wrapper event trace 的 `single_anchor=5` 是各自采样文件的输入边沿编号差异，不是人为对齐偏移。

## 冻结不变量

- R4C standalone transaction latency：`group0_result_fire_edge - vector_start_accept_edge = 23`，16 groups 连续、group II=1。
- V/H vector II=16；每 vector 16 groups；1D kernel 4 complete points/cycle；ready-high output fire II=1。
- H kernel group 与 ResultMemory write 同一事务周期；最终输出由 ResultMemory readback 产生。
- `it_data_out_req=0` 时外部 `it_data_out_vld=0`，内部 hold/skid 保持稳定；只有 output fire 消费。
- `02_rtl/rtl/` 变更数为 0；R4C SHA-256：`15aa962c197c4ce0b9daf2e5478b64c51f3c6712e582f8950df6bf1c339c31b1`；wrapper SHA-256：`1cf3d2554a6a54a4a0b0db820ffb290a80544d6c1e6c13faf1d5334b2483c584`。

## 版本边界

本版本只表示 64×64 DCT2×DCT2、LFNST-off Step12B 的 verification-only 周期/协议证据闭合。它不包含 Vivado synthesis、RAM inference、2.000 ns post-route、完整 Core、其他尺寸、DCT8/DST7 或 LFNST；这些仍属于后续 Step12C 及以后阶段。
