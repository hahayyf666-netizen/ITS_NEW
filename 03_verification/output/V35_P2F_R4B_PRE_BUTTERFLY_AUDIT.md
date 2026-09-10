# V35 P2F R4B_PRE Butterfly Topology Audit

结论：**FAIL_AUDIT**

本轮只读取 R4A RTL、调度表、现有 DCP 和既有时序报告；没有修改 RTL、约束或实现结果。

## 1. 连接级结果

- Butterfly events: 124（预期124）
- Destination count: 124
- Duplicate destinations: 0
- Source-choice distribution: {1: 28, 2: 16, 8: 8}
- Eight-choice slots: N64_slot0, N64_slot1, N64_slot2, N64_slot3, N64_slot4, N64_slot5, N64_slot6, N64_slot7
- 每个 event 的完整映射见 `r4b_pre_butterfly_events.csv`。

## 2. 当前 RTL 结构证据

- dynamic key expressions: 5
- dynamic signal destinations: 10
- dynamic signal sources: 4
- dynamic table lookups: 25
- 当前确实使用 `bf_cycle` 计算 key，并通过 `sid_tmp/esig_tmp` 动态访问 signal_reg；这只是 RTL 证据，不等同于综合网表证明。

## 3. 时序与高扇出证据

- R4A post-route DCP: `D:\Workspace\ITS_STUDY_V35_P2F_B2_R4B_PRE\03_verification\vivado\reports_r4a_postroute\p2f_b2_controlled_postroute.dcp`
- worst-20 中 bf_cycle→signal_reg 路径数：18
- vector-buffer fanout entries: 2
- post-synthesis vector-buffer driver: LUT2; post-route driver: BUFGCE (1024 loads each)
- DCP 只读 census failing paths: 6320
- 全部 failing path 分类：
  - butterfly: 2315 (36.6%), min slack -0.626 ns
  - control_schedule: 85 (1.3%), min slack -0.427 ns
  - multiplier_frontend: 3126 (49.5%), min slack -0.587 ns
  - other: 166 (2.6%), min slack -0.185 ns
  - output_reorder: 132 (2.1%), min slack -0.25 ns
  - reduction: 496 (7.8%), min slack -0.448 ns

## 4. 决策

完整 DCP census 已完成，但连接级统计显示 butterfly 存在 8 个八选一 slot，不能直接套用 reduction 的固定/二选一改法。
当前决策：STOP_NO_PROVEN_REPAIR。需要针对八选一 source-set 和 bf_cycle/control fanout 进一步评估局部化或流水方案，不能直接生成 R4B RTL。

## 5. STOP

- 不得把 source-set 统计直接等同于物理 locality。
- 不得把 worst-20 等同于全部 failing endpoints。
- 不得在本阶段修改 1024 fanout、DSP、reduction 或 butterfly RTL。
