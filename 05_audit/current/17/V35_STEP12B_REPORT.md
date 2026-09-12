# V3.5-17 Step12B functional prototype report

日期：2026-09-12

## 本轮范围

本轮建立了 `64×64 + DCT2 vertical + DCT2 horizontal + LFNST OFF` 的独立 wrapper 原型。wrapper 只实例化一份冻结的 `p2f_dct2_64_b1_step102.sv`，V/H 两阶段按时分复用；没有修改 R4C、V3.4 基线、canonical matrix 或 V3.5-16 Oracle。

新增的周期模型 `03_verification/scripts/step12b_cycle_model.py` 使用唯一顶层 `IntegrationModel.tick()`，包含 A/B epoch input cache、单 Intermediate owner、16 周期 vector staging、R4C stateful contract、H 结果同拍写入、1-cycle result read response、hold/skid 和输出反压。模型测试覆盖 zero、sparse、alternating、random、1→0 反压、双 TU、16-bit vector-id wrap、2-bit epoch wrap/scrub；阶段级 stage16、final10 和 negative mutation 全部 PASS。

## RTL 仿真证据

| 检查 | 结果 |
|---|---|
| ModelSim normal compile | PASS |
| ModelSim normal simulation | `STEP12B_WRAPPER_PASS`, 1024 output beats |
| ModelSim `+define+SYNTHESIS` compile | PASS |
| ModelSim `+define+SYNTHESIS` simulation | `STEP12B_WRAPPER_PASS`, 1024 output beats |
| RTL two-TU normal simulation | `STEP12B_TWO_TU_PASS`, 2048 output beats, 2 done pulses |
| RTL two-TU `+define+SYNTHESIS` simulation | `STEP12B_TWO_TU_PASS`, 2048 output beats, 2 done pulses |
| descriptor FIFO overflow normal/SYNTHESIS | `STEP12B_DESCRIPTOR_OVERFLOW_PASS` |
| RTL forced-2-bit epoch wrap normal/SYNTHESIS | `STEP12B_EPOCH_WRAP_PASS`, 10240 beats, 10 done pulses |
| RTL full signed16 random normal/SYNTHESIS | `STEP12B_RANDOM_PASS`, seed 20260904, 1024 Oracle beats |
| RTL alternating +32767/-32768 normal/SYNTHESIS | `STEP12B_RANDOM_PASS`, 1024 Oracle beats |
| RTL causal event trace audit | `STEP12B_RTL_TRACE_PASS`, 128 starts / 2048 groups / 1024 writes / 1024 fires |
| protocol_error | 0 |
| wrapper sparse data check | 地址 65 输入 100；1024 个 final10 beat 与独立 canonical column 计算逐 beat 匹配 |

## 边界

这不是完整 Step12B gate 的最终 PASS。当前 RTL 已增加单 TU 数值 smoke、全范围 signed16 random 与交替极值 Oracle 对拍、同拍 descriptor push/pop + 空 TU 的双 TU 长反压、descriptor overflow、强制 2-bit epoch wrap/stale-poison、因果事件 trace 审计和 normal/SYNTHESIS 双模式；但仍尚未完成 RTL trace 与 Python trace 的逐事件 cycle 对拍、全部 negative mutation 的 RTL 注入，以及 synthesis/post-route。下一轮必须先补齐这些功能验证，再考虑 Vivado。

当前版本因此标记为 **functional prototype / not frozen**，不得宣称完整 ITS Core 或 500 MHz 已通过。
