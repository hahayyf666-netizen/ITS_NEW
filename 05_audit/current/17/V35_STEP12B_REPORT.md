# V3.5-17 Step12B functional candidate report

日期：2026-09-12

## 本轮范围

本轮建立了 `64×64 + DCT2 vertical + DCT2 horizontal + LFNST OFF` 的独立 wrapper。wrapper 只实例化一份冻结的 `p2f_dct2_64_b1_step102.sv`，V/H 两阶段按时分复用；没有修改 R4C、V3.4 基线、canonical matrix 或 V3.5-16 Oracle。descriptor 合同固定为 64×64/DCT2×DCT2/LFNST-off；`lfnst_tr_set_idx` 在 `lfnst_idx=0` 时仅按 Step12B 工程合同作 don’t-care 保存。

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
| RTL↔Python cycle compare | normal + SYNTHESIS PASS；单一 input-fire 全局锚点 `anchor=5`，无事件类型自由 offset |
| descriptor semantics | 非法 descriptor 拒绝；合法 set_idx=0/1/2 无损保存；normal/SYNTHESIS PASS |
| protocol_error | 0 |
| wrapper sparse data check | 地址 65 输入 100；1024 个 final10 beat 与独立 canonical column 计算逐 beat 匹配 |

## Mutation / evidence

`step12b_mutation_manifest.json` 记录 19 项 cycle-model checker fault injection，全部 FAIL-closed；`step12b_cycle_results.json` 在 mutation 完成后写盘并包含完整结果。覆盖 trace rollback、missing/duplicate group、wrong tag、staging/写回覆写、reservation、RDW/早晚响应、hold/drop/duplicate output、done timing、descriptor misbind、bank conflict 和 scrub access。

## 边界

本候选已完成 scoped functional/protocol gate，但正式冻结仍需远端复核。`v3.5-17` 不包含 synthesis、RAM inference 或 post-route；这些属于后续 Step12C / v3.5-18。完整 ITS Core、其他尺寸、DST7/DCT8/LFNST 也不在本范围。

当前版本因此标记为 **functional candidate / not frozen**，不得宣称完整 ITS Core 或 500 MHz 已通过。
