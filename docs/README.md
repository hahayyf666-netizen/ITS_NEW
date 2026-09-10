# 文档索引

本页是整个工程的文档导航。原始报告保留在生成器和 SHA-256 manifest 规定的路径；通过下面的分类快速定位，不需要在根目录逐个翻找。

## 1. 当前使用

- [项目总览](../README.md)
- [Step 12A-R2.1 运行说明](../README_STEP12A_R2.md)
- [Step 12A-R2.1 集成门禁](../03_verification/output/V35_STEP12A_R2_1_INTEGRATION_GATE.md)
- [Step 12A-R2.1 执行证明](../03_verification/output/V35_STEP12A_R2_EXECUTABLE_PROOF.md)

## 2. 设计架构与数学契约

- [P2F 因式分解架构](../V35_P2F_PRE_FACTOR_ARCHITECTURE.md)
- [P2F-A1 调度](../V35_P2F_A1_P4_SCHEDULE.md)
- [P2F-A1 数据流证明](../V35_P2F_A1_DATAFLOW_PROOF.md)
- [P2F-A2 缓存契约](../V35_P2F_A2_BUFFER_CONTRACT.md)
- [V3.4 LFNST 规则](../03_verification/output/V34_LFNST_nonZeroSize_report.md)

## 3. 当前硬件实现证据

- [R4A 操作数局部化](../03_verification/output/V35_P2F_R4A_OPERAND_LOCAL_REPORT.md)
- [R4B 蝶形静态化](../03_verification/output/V35_P2F_B2_R4B_EVENT_STATIC_REPORT.md)
- [R4C DSP 流水线](../03_verification/output/V35_P2F_B2_R4C_DSP_PIPE_REPORT.md)
- [R4C 前置时序审计](../03_verification/output/r4c_pre_dsp_audit/V35_P2F_B2_R4C_PRE_DSP_TIMING_AUDIT.md)

## 4. 历史版本

- `03_verification/output/`：V3～V4、R1～R4C 和各阶段报告
- `_v1_audit/` ～ `_v4_audit/`：版本验收和冻结证据
- `_step102_audit/`、`_step12a_audit/`、`_step12ar_audit/`：早期阶段审计
- `V35_P2A_DCT2_64/`：P2A 原型及其历史实现证据

历史报告只用于追溯，不代表当前实现状态；当前状态以根目录 README 和 Step 12A-R2.1 报告为准。

## 5. 工程目录地图

| 分类 | 路径 | 说明 |
|---|---|---|
| RTL/ROM | `02_rtl/` | 设计源代码、ROM 和约束 |
| 验证 | `03_verification/` | Python、testbench、向量、仿真和 Vivado 证据 |
| 报告 | `01_reports/`、`03_verification/output/` | 方案与自动生成报告 |
| 波形 | `04_waveforms/` | 波形相关文件 |
| 历史审计 | `_v*_audit/`、`_step*_audit/` | 版本和阶段追溯 |
| 外部参考 | `VTM/`、`华为附件.docx` | VTM 与赛题材料 |

## 6. 路径保留原则

自动生成报告的原始路径已经写入冻结 manifest 和复现脚本。为了保证哈希校验和旧命令仍然可运行，不统一移动受控文件；本索引负责分类导航，根目录 README 负责当前状态摘要。
