# ITS V3.5-17 Step12B 功能原型（未冻结）

本目录是 ITS 工程的唯一持续工作目录。版本历史通过 GitHub commit/tag 保存，不再为每个版本复制整套本地工程。`v3.5-16` 保留为上一冻结点；当前工作版本为 Step12B 功能原型，尚未打正式冻结 tag。

## 当前状态（Step12B 功能原型）

- V3.4 功能与数学基线保持冻结。
- 主变换使用 `A = C^T`，RTL 直接计算 `A·x`，禁止再次转置。
- DCT2-64 R4C 一维 P4 核已证明每拍 4 个完整结果、向量启动间隔 16 拍。
- R4C standalone OOC post-route 已在 2.000 ns 约束下闭合。
- Step 12A-R2.1 与 R2.2 为历史证据；V3.5-15 即 Step 12A-R2.3（Output & Reproducibility Closure）。V3.5-16 在不改数学与调度的前提下，统一文档命名并将 validator 内部身份改为永久 `invocation_serial`。
- R4C standalone 一维核保持冻结；Step12B 已新增 64×64 DCT2×DCT2 单 R4C wrapper 原型。ModelSim normal/SYNTHESIS 稀疏 TU smoke 均通过，完整 RTL Oracle/事件对拍仍未闭合。

## 目录导航

| 目录 | 内容 |
|---|---|
| `01_docs/` | 当前说明、架构文档、赛题报告和历史记录 |
| `02_rtl/` | RTL、ROM 与约束 |
| `03_verification/` | 脚本、testbench、向量、仿真、Vivado、波形和结果 |
| `04_reference/` | 华为附件与 VTM 参考源码 |
| `05_audit/` | 当前 V3.5-16 证据与 V3.4 基线审计 |
| `06_archive/` | 旧版本审计、旧原型和本地生成缓存；不作为当前入口 |

详细导航见 [`01_docs/README.md`](01_docs/README.md)。

## 当前验证入口

```powershell
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_current_checks.ps1
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_step12b_checks.ps1
```

当前证据目录：`05_audit/current/17/`。

`run_p2f_a1_dataflow.py` 属于已退休的历史 32-group FIFO 门禁，会按其旧合同报告 FAIL；当前 kernel 门禁使用 `run_p2f_a2_kernel_regate.py`，不要把 A1 的历史结论误判为当前回归失败。

Step12B 功能合同见 [`01_docs/current/Step12B.md`](01_docs/current/Step12B.md)；当前原型报告见 `05_audit/current/17/V35_STEP12B_REPORT.md`。

## 结论边界

目前不能宣称完整 ITS Core 已达到 500 MHz，也不能宣称所有尺寸、DST7、DCT8 与 LFNST 已完成新 P4 架构。当前已闭合的是 DCT2-64 standalone 一维核，以及 Step 12A-R2.3 / V3.5-15 二维预 RTL 集成门禁；Step12B 目前仅有功能原型 smoke PASS，尚未达到正式冻结条件。

## 整理规则

- 当前运行链路只使用 `02_rtl/`、`03_verification/`、`04_reference/` 和 `05_audit/`。
- `06_archive/` 只用于历史追溯；其中旧 manifest 的原始相对路径应结合 Git 标签恢复，不作为本版本当前门禁。
- 后续版本继续在本总目录内迭代，GitHub commit/tag保存版本历史；不再新建本地整套版本目录。

## 发布包

- V3.5-15/V3.5-16 发布证据和 manifest 保留在 Git 标签对应的历史提交中；Step12B 原型证据位于 `05_audit/current/17/`，通过完整功能 gate 后再生成正式冻结 manifest/tag。
- 发布包不含本地缓存、嵌套 `.git` 和 VTM 示例私钥；完整历史保留在本目录和 Git 标签中。
