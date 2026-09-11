# V3.5-17 Step12B functional prototype report

日期：2026-09-11

## 本轮范围

本轮建立了 `64×64 + DCT2 vertical + DCT2 horizontal + LFNST OFF` 的独立 wrapper 原型。wrapper 只实例化一份冻结的 `p2f_dct2_64_b1_step102.sv`，V/H 两阶段按时分复用；没有修改 R4C、V3.4 基线、canonical matrix 或 V3.5-16 Oracle。

新增的周期模型 `03_verification/scripts/step12b_cycle_model.py` 使用唯一顶层 `IntegrationModel.tick()`，包含 A/B epoch input cache、单 Intermediate owner、16 周期 vector staging、R4C stateful contract、H 结果同拍写入、1-cycle result read response、hold/skid 和输出反压。模型测试覆盖 zero、sparse、alternating、random、1→0 反压以及双 TU；全部 PASS。

## RTL 仿真证据

| 检查 | 结果 |
|---|---|
| ModelSim normal compile | PASS |
| ModelSim normal simulation | `STEP12B_WRAPPER_PASS`, 1024 output beats |
| ModelSim `+define+SYNTHESIS` compile | PASS |
| ModelSim `+define+SYNTHESIS` simulation | `STEP12B_WRAPPER_PASS`, 1024 output beats |
| protocol_error | 0 |
| wrapper sparse data check | 地址 65 输入 100；1024 个 final10 beat 与独立 canonical column 计算逐 beat 匹配 |

## 边界

这不是完整 Step12B gate 的最终 PASS。当前 testbench 已验证真实 RTL 的一个确定性稀疏 TU、descriptor/end、同拍 data+end、R4C V/H 调度和结果读出，但尚未完成极值/random 的 RTL 逐 beat Oracle 对拍、RTL 事件 trace 与 Python trace 对拍、双 TU RTL 反压以及 synthesis/post-route。下一轮必须先补齐这些功能验证，再考虑 Vivado。

当前版本因此标记为 **functional prototype / not frozen**，不得宣称完整 ITS Core 或 500 MHz 已通过。
