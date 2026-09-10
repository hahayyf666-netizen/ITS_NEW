# ITS V3.5-13 完整工程

本目录是从 `ITS_STUDY_V35_STEP12A_R2_1_DCT2_64_2D_PRE` 完整复制并分类整理得到的新版本。旧目录保持不变；整理前的 GitHub 全量快照已由标签 `v3.5-step12ar2.1-full` 固定。

## 当前状态

- V3.4 功能与数学基线保持冻结。
- 主变换使用 `A = C^T`，RTL 直接计算 `A·x`，禁止再次转置。
- DCT2-64 R4C 一维 P4 核已证明每拍 4 个完整结果、向量启动间隔 16 拍。
- R4C standalone OOC post-route 已在 2.000 ns 约束下闭合。
- 当前二维集成门禁为 Step 12A-R2.1；Step 12B wrapper RTL 尚未开始。

## 目录导航

| 目录 | 内容 |
|---|---|
| `01_docs/` | 当前说明、架构文档、赛题报告和历史记录 |
| `02_rtl/` | RTL、ROM 与约束 |
| `03_verification/` | 脚本、testbench、向量、仿真、Vivado、波形和结果 |
| `04_reference/` | 华为附件与 VTM 参考源码 |
| `05_audit/` | 当前 Step 12A-R2.1 证据与 V3.4 基线审计 |
| `06_archive/` | 旧版本审计、旧原型和本地生成缓存；不作为当前入口 |

详细导航见 [`01_docs/README.md`](01_docs/README.md)。

## 当前验证入口

```powershell
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_current_checks.ps1
python 03_verification/scripts/make_v35_13_manifest.py
```

当前证据目录：`05_audit/current/step12ar2/`。

`run_p2f_a1_dataflow.py` 属于已退休的历史 32-group FIFO 门禁，会按其旧合同报告 FAIL；当前 kernel 门禁使用 `run_p2f_a2_kernel_regate.py`，不要把 A1 的历史结论误判为当前回归失败。

## 结论边界

目前不能宣称完整 ITS Core 已达到 500 MHz，也不能宣称所有尺寸、DST7、DCT8 与 LFNST 已完成新 P4 架构。当前已闭合的是 DCT2-64 standalone 一维核，以及 Step 12A-R2.1 的二维预集成软件门禁。

## 整理规则

- 当前运行链路只使用 `02_rtl/`、`03_verification/`、`04_reference/` 和 `05_audit/`。
- `06_archive/` 只用于历史追溯；其中旧 manifest 的原始相对路径应结合 Git 标签恢复，不作为本版本当前门禁。
- 后续版本继续采用短编号命名，并从完整工程复制生成。
