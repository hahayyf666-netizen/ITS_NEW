# 文档导航

## 当前状态

- `current/`：Step 12A-R 与 R2 当前说明。
- `reports/`：详细设计、验证与 PPA PDF 报告。

## 架构资料

- `architecture/p2f/`：DCT2-64 因式分解、周期数据流、buffer contract 与早期功能报告。

其中 A1 32-group FIFO 是历史实验，当前采用 A2 guaranteed-accept kernel contract；当前一键检查入口为 `../03_verification/scripts/run_current_checks.ps1`。

## 规范与参考

- 华为原始附件位于 `../04_reference/huawei/`。
- VTM 源码位于 `../04_reference/VTM/`。

## 历史记录

- `history/`：早期修复方案、旧 README 和 Notion 导出。
- 历史审计位于 `../06_archive/audits/`，不属于当前回归入口。
