# V3.5-17.1 Step12B audit / timing-semantics closure

## 结论

`v3.5-17` 的 64×64 DCT2×DCT2 single-R4C functional RTL freeze 保持不变。本轮只补验证语义和审计证据，不修改 R4C、主数据通路数学、scheduler 或接口结构；不运行 Vivado。

结果：**PASS（audit closure）**。

## 已闭合项目

- 统一事务周期语义：事件属于其被第 C 个上升沿接受的 transaction edge；`#1step` 只延迟日志写入，不重新采样事件。
- post-NBA 独立断言：最后一个 `output_fire` 的事务边沿记录 `it_done`，该边沿后 `it_done=1`，下一边沿后清零；删除混合 `trace_done_s || dut.it_done` 逻辑。
- 冻结 R4C standalone latency：`result_accept=1` 时 `group0_result_fire_edge - vector_start_accept_edge = 23`，16 groups 连续、group II=1；normal/SYNTHESIS 均通过。
- 内部事务事件对拍：`stage_capture=128`、`intermediate_write=1024`、`result_reserve=1`、`result_read_request=1024`、`result_read_response=1024`，result RAM request→response latency=1；与 Python trace 共用单一 input-fire anchor=5，无事件类型自由 offset。
- RTL trace comparator fail-closed mutation：vector-start cycle、missing group、wrong vector ID、duplicate write、output index swap、done cycle、trace rollback 共 7 项，全部被拒绝。
- 既有 Step12B 19 项 cycle-model/checker mutation、normal/SYNTHESIS、random/extreme、two-TU、descriptor、epoch、req/vld 和公共事件对拍保持 PASS。

## 版本边界

- `v3.5-17` annotated tag 永不移动，历史功能证据保留在 `05_audit/current/17/`。
- `v3.5-17.1` 只代表审计/周期语义/可复现性收尾，不代表 synthesis、RAM inference、500 MHz 或完整 ITS Core。
- Step12C / `v3.5-18` 才负责真实 RAM 结构、综合和 2.000 ns post-route。

## 关键引用

- v3.5-17 frozen commit: `00850c12bf574b92bb8ab85c3bd8515851f067b4`
- frozen R4C SHA-256: `15aa962c197c4ce0b9daf2e5478b64c51f3c6712e582f8950df6bf1c339c31b1`
- internal normal evidence: `step12b_internal_trace_results.json`
- internal SYNTHESIS evidence: `step12b_internal_trace_synthesis_results.json`
- trace mutation evidence: `step12b_trace_mutation_results.json`
