# ITS V3.5 当前工作目录：Step12C / v3.5-18 performance baseline

本目录是 ITS 工程的唯一持续工作目录。版本历史通过 GitHub commit/tag 保存，不再为每个版本复制整套本地工程。`v3.5-17` 保留为不可移动的 Step12B 功能冻结点；当前工作版本为 Step12C / v3.5-18 performance baseline，冻结 tag 按发布顺序指向本次状态提交。

## 当前状态（v3.5-18 冻结，Step12D/Step12E 功能基线通过，Step12F 物理实现 STOP）

- V3.4 功能与数学基线保持冻结。
- 主变换使用 `A = C^T`，RTL 直接计算 `A·x`，禁止再次转置。
- DCT2-64 R4C 一维 P4 核已证明每拍 4 个完整结果、向量启动间隔 16 拍。
- R4C standalone OOC post-route 已在 2.000 ns 约束下闭合。
- Step 12A-R2.1 与 R2.2 为历史证据；V3.5-15 即 Step 12A-R2.3（Output & Reproducibility Closure）。V3.5-16 在不改数学与调度的前提下，统一文档命名并将 validator 内部身份改为永久 `invocation_serial`。
- R4C standalone 一维核保持冻结；Step12B 已新增 64×64 DCT2×DCT2 单 R4C wrapper。`v3.5-17` 已冻结功能结果；`v3.5-17.1` 补充事务边沿周期合同、永久 R4C latency=23 gate、`it_done` post-NBA 断言、内部事务事件审计和 comparator fail-closed mutation；`v3.5-17.2` 修正 Python phase-admission 一拍语义并完成 normal/SYNTHESIS memory、公共/内部事件及 RTL trace mutation closure。Step12C-M3 增加 bank-response/staging 两级流水并将 R4C vector-ID sanity check 移为 verification-only；Step12C-M4 仅增加 input-cache bank-local write-command pipeline；Step12C-M5-Setup 仅统一 input-tag bank 写命令并将 raw-tag compare 后移，R4C、数学、官方接口和 XDC 不变。
- Step12C-M6 implementation-only sweep 已闭合：四组固定 Vivado 2025.2 flow 均从同一 M6 postsynth DCP 独立起跑；`Performance_NetDelay_high` 首次通过并独立复跑通过，最终 setup/hold 均为 WNS/WHS `+0.011 ns`、TNS/THS `0`，route fully routed，约束检查无 unconstrained endpoint、无 timing exception。该结果仅代表本 64×64 DCT2×DCT2 wrapper 的 registered-neighbor OOC 性能基线，不代表完整 ITS Core 或其他变换已闭合。
- Step12D 的 `contest_engineering_vtm10_v1` 工程 profile Gate A 已闭合（官方/历史 hidden-golden 等价性仍未证明）。新的四槽重叠 unified P4 kernel 已通过 ModelSim SE-64 2020.4 的 Gate B normal 与 `SYNTHESIS`-define 数值/吞吐回归；Step12F 又完成了 369 tuple / 45,636 beat 的 normal 与 `SYNTHESIS` HDL 覆盖及 13 模式 vector-II 压测。unified wrapper 的 fresh Vivado 物理线在 RTL elaboration 阶段因资源/展开规模 STOP，尚无 synthesis、route 或 500 MHz 结论；`v3.5-18`、frozen R4C、旧 wrapper/XDC 均未改变。详见 `05_audit/current/28/STEP12F_REPORT.md`。

## 目录导航

| 目录 | 内容 |
|---|---|
| `01_docs/` | 当前说明、架构文档、赛题报告和历史记录 |
| `02_rtl/` | RTL、ROM 与约束 |
| `03_verification/` | 脚本、testbench、向量、仿真、Vivado、波形和结果 |
| `04_reference/` | 华为附件与 VTM 参考源码 |
| `05_audit/` | 当前 V3.5-16 证据与 V3.4 基线审计 |
| `06_archive/` | 旧版本审计、旧原型和本地生成缓存；不作为当前入口 |

详细导航见 [`01_docs/README.md`](01_docs/README.md)。Step12D-PRE 合同见 [`01_docs/current/Step12D.md`](01_docs/current/Step12D.md)，当前机器可读证据位于 `05_audit/current/26/step12d_pre/`。

## 当前验证入口

```powershell
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_current_checks.ps1
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_step12b_checks.ps1
```

当前证据目录：`05_audit/current/25/`；`05_audit/current/21/`、`05_audit/current/20/`、`05_audit/current/19/`、`05_audit/current/17_2/`、`05_audit/current/17_1/` 与 `05_audit/current/17/` 保留为历史证据。M6 sweep 摘要、命令记录和文本报告位于 `05_audit/current/25/`；各策略最终 DCP 保留为本地 checkpoint，并由 manifest 记录 SHA-256。

`run_p2f_a1_dataflow.py` 属于已退休的历史 32-group FIFO 门禁，会按其旧合同报告 FAIL；当前 kernel 门禁使用 `run_p2f_a2_kernel_regate.py`，不要把 A1 的历史结论误判为当前回归失败。

Step12B/Step12C 合同见 [`01_docs/current/Step12B.md`](01_docs/current/Step12B.md)；M6 implementation sweep 摘要见 `05_audit/current/25/M6_IMPLEMENTATION_SWEEP.json`，策略命令和 timing/constraint/resource 报告位于同目录下的各 flow 文件夹；M5 synthesis-only 与 M4 post-route 报告保留为历史证据。

## 结论边界

目前不能宣称完整 ITS Core 已达到 500 MHz，也不能宣称所有尺寸、DST7、DCT8 与 LFNST 已完成新 P4 架构。当前已闭合的是 DCT2-64 standalone 一维核、Step12A-R2.3 / V3.5-15 二维预 RTL 集成门禁、Step12B v3.5-17/17.1/17.2 的功能与审计证据，以及 Step12C 对 64×64 DCT2×DCT2 wrapper 的 implementation-only 500 MHz 性能基线。选定的 `Performance_NetDelay_high` flow 首次运行和独立复跑均通过 WNS/WHS `+0.011 ns`、TNS/THS `0`，route fully routed；v3.5-18 的范围仅限该 wrapper/OOC harness，不外推到完整 Core。

## 整理规则

- 当前运行链路只使用 `02_rtl/`、`03_verification/`、`04_reference/` 和 `05_audit/`。
- `06_archive/` 只用于历史追溯；其中旧 manifest 的原始相对路径应结合 Git 标签恢复，不作为本版本当前门禁。
- 后续版本继续在本总目录内迭代，GitHub commit/tag保存版本历史；不再新建本地整套版本目录。

## 发布包

- V3.5-15/V3.5-16 发布证据和 manifest 保留在 Git 标签对应的历史提交中；`v3.5-17` 功能冻结证据位于 `05_audit/current/17/`，`v3.5-17.1` 历史审计证据位于 `05_audit/current/17_1/`，`v3.5-17.2` 历史 closure 证据位于 `05_audit/current/17_2/`，M3/M4/M5 历史证据位于 `05_audit/current/19/`、`05_audit/current/20/` 与 `05_audit/current/21/`；v3.5-18 Step12C implementation sweep 证据位于 `05_audit/current/25/`。
- 发布包不含本地缓存、嵌套 `.git` 和 VTM 示例私钥；完整历史保留在本目录和 Git 标签中。
