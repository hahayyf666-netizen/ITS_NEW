# V3.5 Step12C-M5-Setup Synthesis Report

## 判定

**M5-Setup 的 synthesis-only setup/structure gate PASS；Boundary-PRE 尚未完成。**

本轮只修改 input-tag 的 bank-local 写命令表达，以及 response 侧 raw-tag
寄存/延后 epoch compare。R4C、数学、官方接口、XDC、V-write pipeline 和
ResultMemory reader 均未修改。未运行 place/route，因此不创建 `v3.5-18`。

## 固定输入

- M5 基线：`d773b919e3cff6735872b436278b5477400df1de`
- Vivado：`2025.2` build `6299465`
- Device：`xcku5p-ffvb676-2-e`
- Clock：`clk`，周期 `2.000 ns` / `500 MHz`
- XDC：保持 M4 原文件不变
- R4C SHA-256：`15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1`
- Wrapper SHA-256（M5）：`32C4519F806C311981F8AFBEC2C0AC14B6B82942217AB47914171E15630D4E41`
- XDC SHA-256：`5FC2465A7E852A99BE1B7C6B484C9EDF85FB96DDAF256F277D4A2E3DB467F2F3`

## 功能回归

既有 Step12B 回归通过：

- normal / `SYNTHESIS` ModelSim 编译与仿真
- zero / sparse / alternating / random / extreme
- two-TU、descriptor、epoch-wrap、backpressure
- RTL trace、internal trace、trace mutation
- R4C transaction latency `23`
- vector II `16`、group II `1`、ready-high output II `1`
- R4C SHA 保持不变

## Synthesis-only 结果

| 指标 | 结果 | M5-Setup 判定 |
|---|---:|---|
| Setup WNS | `+0.075 ns` | PASS |
| Setup TNS | `0 ns` | PASS |
| Setup failing endpoints | `0` | PASS |
| Hold WHS | `-0.076 ns` | Boundary-PRE 待处理 |
| Hold THS | `-17.135 ns` | Boundary-PRE 待处理 |
| Hold failing endpoints | `251` | Boundary-PRE 待处理 |
| Unconstrained internal endpoints | `0` | PASS |
| Valid timing exceptions | `none` | PASS |

M5 后最差 setup 已不再是 M4 的 input-tag RAMD 更新路径；postsynth
worst path 为 `cache_epoch`/cache-control 到 `last_input_addr` 控制路径，
slack `+0.075 ns`。这证明本轮 tag 写端口与 raw-tag compare 改动消除了原
setup blocker，但不代表最终 post-route 已闭合。

## 结构资源

- LUT：`21,313`（logic `15,425`，distributed-RAM `5,888`）
- FF：`21,336`
- DSP48E2：`128`
- BRAM18/36：`0`
- URAM：`0`
- synthesis：`0` errors、`0` critical warnings、`77` warnings
- RAM 映射仍为 distributed RAM（RAM64M/RAM64M8），不是 BRAM；本轮不以
  RAM 类型单独判 FAIL，后续由 implementation/PPA 继续判断。

## 约束与边界说明

`check_timing` 报告内部逻辑约束完整：无 unconstrained endpoint、无缺失
I/O delay、无组合环；`report_exceptions` 没有有效 timing exception。
但当前 OOC XDC 仍缺少完整的 clock/interface physical context（例如
`HD.CLK_SRC` 或等价的 registered-neighbor/top-level harness），因此
`-0.076 ns` 的 port→first-command-FF hold 不能直接解释为 DUT 必须加入
80 ps 硬件延迟。下一步应单独执行 Boundary-PRE，不用人为 delay cell、
false path、multicycle 或随意修改 input-delay。

## 证据文件

本目录保存 synthesis-only 原始证据：

- `step12c_wrapper_postsynth.dcp`
- `report_timing_summary_postsynth.rpt`
- `report_timing_hold_summary_postsynth.rpt`
- `report_timing_worst100_postsynth.rpt`
- `report_utilization_postsynth.rpt`
- `report_hierarchy_utilization_postsynth.rpt`
- `report_high_fanout_postsynth.rpt`
- `report_check_timing_postsynth.rpt`
- `report_exceptions_postsynth.rpt`
- `report_methodology_postsynth.rpt`
- `report_drc_postsynth.rpt`

DCP SHA-256：`AECD46CD4F4122A5A654BE496DEDC106449DEBEE58E8C48C4C3F114B230A5E48`

## 决策

M5-Setup synthesis setup/structure 通过，M4 的 setup blocker 已被窄范围
修复；保留 hold 为独立的 Boundary-PRE 方法学问题。当前不运行 route、不打
`v3.5-18`，下一步只冻结并评审真实 OOC/interface physical boundary，再决定
实现阶段的最终 timing gate。
