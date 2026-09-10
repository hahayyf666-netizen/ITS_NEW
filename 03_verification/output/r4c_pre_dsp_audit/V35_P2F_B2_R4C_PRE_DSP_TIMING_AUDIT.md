# V35 P2F B2 R4C_PRE DSP Front-End Timing Audit

基线：R4B Event-Static routed DCP（只读）

## 结论

R4C_PRE 的瓶颈定位通过：当前 500 MHz 违例主要集中在 `operand_x/operand_coeff → DSP48E2 → lane_product_reg`。128 个 DSP 的 `AREG/BREG/MREG/PREG` 全部为 0，DSP 内部没有吸收 A/B、乘法输出或 P 输出流水。候选增加 1 个乘法结果流水阶段在周期级模型中保持 II=16、group II=1 和 A/B/result bank 生命周期，因此可以进入 R4C 独立副本实施；本报告不表示 R4C 已实现或已经达到 500 MHz。

## 1. 实际路径分类

R4B DCP 中共导出 3486 条 setup failing paths，最差 slack 为 -0.462 ns。

| 类别 | 全部 failing | 占比 | worst slack |
|---|---:|---:|---:|
| coeff → lane_product | 1973 | 56.6% | -0.460 ns |
| x → lane_product | 1099 | 31.5% | -0.450 ns |
| control/other | 414 | 11.9% | -0.240 ns |

worst1000 全部属于 operand/coeff → lane_product：coeff 646 条，x 354 条。

最差具体路径为：

`operand_coeff_reg_reg[31][2]/C → lane_product_reg_reg[86][7]/D`

数据路径 2.445 ns，其中逻辑 1.728 ns、布线 0.717 ns；经过 DSP A/B 输入、PREADD、MULTIPLIER、M_DATA、ALU、DSP_OUTPUT 和末端 LUT2。

## 2. DSP 实际属性

查询 DCP 中 128 个 `DSP48E2`：

| 属性 | 128 个实例的值 |
|---|---|
| AREG | 0/128 |
| BREG | 0/128 |
| MREG | 0/128 |
| PREG | 0/128 |
| ADREG | 1/128 |
| DREG | 1/128 |

所有 DSP 的 `CLK/RSTA/RSTB/RSTM/RSTP/CEA1/CEA2/CEAD/CEB1/CEB2/CEM/CEP/CECTRL/CED/CEINMODE` 在 routed primitive 上均为 `<const0>`，这是因为当前 DSP 内部可选流水没有启用。不能通过简单保留现有异步复位编码来期待 Vivado 自动启用 MREG/PREG；R4C 需要明确同步复位/使能和 valid/tag 对齐方案。

## 3. 周期级重定时证明

使用 `r4c_pre_cycle_proof.py` 对四个连续 vector（start=0/16/32/48）建模，检查 ΔL=0、1、2。候选 ΔL=1 的结果：

- 128 lanes、1368 ops、64 terminal dots 不变；
- vector invocation interval 仍为 16 cycles；
- 每个 vector 仍有 16 个 group，group interval 为 1；
- reduction、butterfly、capture、result-ready 整体平移 ΔL；
- A/B 输入 buffer 的 issue/read 窗口在下一次 vector 写入前结束；
- result bank 按 vector_id[1:0] 四次 invocation 后才复用；
- valid、vector_id、bank、first/last 必须和 product 一起延迟 ΔL。

这证明“增加一拍可以保持吞吐”的控制条件成立，但不替代 RTL 仿真；实现时若 DSP 内部流水使用同步复位，必须重新检查 reset release、CE、invalid bubble 和跨 vector pending context。

## 4. R4C 实施门禁

进入 R4C 前必须保持：`A=C^T`、1368 operations、128 lanes、现有 reduction/butterfly event sequence、vector II=16、group II=1、4 个完整结果/拍和固定点规则不变。

R4C 只允许改乘法边界及其必要的控制重定时。完成后必须依次通过：

1. ModelSim 阶段级 bit-exact（raw/biased/shifted/stage16/final10/tag）；
2. synthesis-only，确认至少 MREG/PREG 或等效内部流水真实进入 DSP；
3. post-route 2.000 ns，再判断 WNS/TNS 和剩余瓶颈。

如果启用内部流水后 A/B bank、reduction event、butterfly pending 或 result bank 生命周期无法保持，R4C 立即判失败，回到 PRE 重新设计。

## 5. 限制与审计产物

本轮只读 R4B DCP；没有修改 R4B RTL，也没有声称 500 MHz 已达成。原始数据与证明：

- `r4c_pre_dsp_audit/dsp_properties.csv`
- `r4c_pre_dsp_audit/dsp_control_pins.csv`
- `r4c_pre_dsp_audit/failing_paths.csv`
- `r4c_pre_dsp_audit/cycle_proof.json`
- `r4c_pre_dsp_audit/r4c_pre_results.json`

## FINAL

**R4C_PRE PASS（允许进入独立 R4C 实施；不代表时序 PASS）**
