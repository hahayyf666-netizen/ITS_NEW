# 文档索引

本目录用于说明仓库中的文档层次。历史报告和自动生成报告暂时保留在原路径，不能随意移动或删除：冻结 manifest、审计脚本和复现实验会按原路径校验它们。

## 当前入口

- [项目总览](../README.md)
- [Step 12A-R2.1 运行说明](../README_STEP12A_R2.md)
- [Step 12A-R2.1 集成门禁](../03_verification/output/V35_STEP12A_R2_1_INTEGRATION_GATE.md)
- [Step 12A-R2.1 执行证明](../03_verification/output/V35_STEP12A_R2_EXECUTABLE_PROOF.md)

## 当前设计与验证证据

- [R4C DSP 流水线报告](../03_verification/output/V35_P2F_B2_R4C_DSP_PIPE_REPORT.md)
- [R4B 蝶形静态化报告](../03_verification/output/V35_P2F_B2_R4B_EVENT_STATIC_REPORT.md)
- [R4A 操作数局部化报告](../03_verification/output/V35_P2F_R4A_OPERAND_LOCAL_REPORT.md)
- [V3.4 LFNST 报告](../03_verification/output/V34_LFNST_nonZeroSize_report.md)

## 历史阶段

V1/V2/V3/V4、P2F-A1/A2/B1、R3/R3R 和早期 Step 12A 报告均属于历史证据，集中在 `03_verification/output/`、各 `_v*_audit/` 和 `_step*_audit/` 目录中。它们用于追溯，不代表当前实现状态。

## 为什么没有统一移动文件

自动生成报告的原始路径已经写入 SHA-256 manifest 和生成器。统一搬迁会导致历史 manifest 失效，也会使旧的复现命令找不到报告。因此当前采用“保留原路径 + 索引导航”的方式整理。

