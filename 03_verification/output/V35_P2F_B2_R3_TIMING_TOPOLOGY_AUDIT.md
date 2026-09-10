# V35 P2F-B2-R3 Routed Timing Topology Audit

本报告只读取 R3 post-route DCP 及其报告，不修改 RTL、约束或实现结果。

## 1. 证据
- DCP: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R3\03_verification\vivado\reports_controlled_impl\p2f_b2_controlled_postroute.dcp`
- setup path rows extracted: 1000
- top-path report: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R3\03_verification\output\p2f_b2_r3_timing_topology\top1000_setup_paths.rpt`
- high-fanout report: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R3\03_verification\output\p2f_b2_r3_timing_topology\high_fanout.rpt`
- congestion report: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R3\03_verification\output\p2f_b2_r3_timing_topology\congestion.rpt`

## 2. Top-1000 setup path classification
分类依据是实际 startpoint/endpoint 名称，不使用变量注释、脚本 token 或文件哈希判断结构。

| Category | Count | Fraction | Min slack (ns) | Mean slack (ns) |
|---|---:|---:|---:|---:|
| multiplier_frontend | 605 | 60.5% | -0.846 | -0.6899157024793389 |
| butterfly | 212 | 21.2% | -0.904 | -0.6990235849056604 |
| reduction | 102 | 10.2% | -0.727 | -0.6651470588235294 |
| control_schedule | 69 | 6.9% | -0.731 | -0.6788115942028986 |
| output_reorder | 0 | 0.0% | None | None |
| other | 12 | 1.2% | -0.713 | -0.6881666666666666 |

## 3. Interpretation

1. 最差单条路径属于 butterfly：`bf_cycle_reg[3] → signal_reg_reg[...]`，R3 post-route WNS 为 -0.904 ns；该路径报告显示约70%为 route delay。
2. 但 top-1000 中 multiplier front-end 占多数，说明问题不是单一 butterfly 瓶颈。operand/vector buffer 到 operand/lane-product 的路径仍然形成大范围跨区网络。
3. reduction 占比已经较低，说明 R3 的静态 terminal-dot 改造确实消除了部分 reduction 动态写回网络，但没有使全局设计达到500 MHz。
4. 高扇出证据中，除全局 reset 外，`final10_mem`/`ready_vector_id` 相关网达到约1040、`vector_buf` 相关网约1024，`sched_src_reg_reg_n_0_[10][1]` fanout 800，另有多个 `signal_reg` LUT net 超过250；这说明输出/状态控制、调度和 butterfly 存储网络仍然高度全局化。
5. 因此不能只做 butterfly 局部补丁，也不能只继续修 multiplier 单条路径；下一版本必须同时做 multiplier/operand cluster 与 butterfly/signal cluster 的局部化。

## 4. Gate decision

- R3 functional/bit-exact: 保持已验证通过。
- R3 static reduction connectivity: 保持通过。
- R3 500 MHz post-route: FAIL（WNS -0.904 ns）。
- 下一步：暂停 R3 局部补丁，进入新的架构级 cluster-local static dataflow 设计；不得直接复制当前全局动态 signal bank。

## 5. STOP items

- 当前版本不得宣称500 MHz闭合。
- 在完成新的局部化结构并通过综合门禁前，不得继续集成 DST7/DCT8、LFNST 或完整二维 Core。
