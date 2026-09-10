# V35 P2F-B2 — First Vivado 500 MHz Baseline Gate

日期：2026-09-05  
工程：`D:\Workspace\ITS_STUDY_V35_P2F_B2`  
基线：Step 10.2 / P2F-B1 R2（只读复制，Step 11 未修改 DUT RTL）

## 1. 本轮范围

本轮只对 DCT2-64 P4 functional prototype 做第一次未优化的 Vivado OOC post-route 测量。没有加入 floorplan、Pblock、时序例外、架构优化或 RTL 修复。器件为 `xcku5p-ffvb676-2-e`，唯一时钟约束为 `clk = 2.000 ns`（500 MHz）。

功能依据是 Step 10.2 已保存的 `V35_P2F_B1_FUNCTIONAL_REPORT.md`：49 cases、784 beats、bit-exact PASS；该功能结论不是本轮重新生成的 expected。

## 2. 工具与实现状态

| 项目 | 结果 | 证据 |
|---|---:|---|
| Vivado | 2025.2 | `vivado_p2f_b2.log` |
| Part | `xcku5p-ffvb676-2-e` | OOC Tcl / reports |
| Synthesis | PASS | 0 errors、0 critical warnings |
| opt/place/phys_opt/route | PASS | route completed successfully，0 errors |
| Post-route checkpoint | 已生成 | `p2f_b2_postroute.dcp` |
| RTL 修改 | 否 | R2 与 B2 DUT SHA-256 相同 |

DUT `p2f_dct2_64_b1_step102.sv`：

```text
R2: 53DE8B1B7903D890072EC10715D48F3A1A75FFBF990659FE756237FE2D8466B3
B2: 53DE8B1B7903D890072EC10715D48F3A1A75FFBF990659FE756237FE2D8466B3
```

## 3. 500 MHz post-route timing

| 指标 | 实测值 | 门禁 |
|---|---:|---:|
| Clock period | 2.000 ns | 固定约束 |
| Frequency | 500 MHz | 固定约束 |
| Setup WNS | **-2.052 ns** | FAIL（要求 ≥ 0） |
| Setup TNS | **-19555.092 ns** | FAIL（要求 = 0） |
| Setup failing endpoints | **20730 / 29246** | FAIL |
| Hold WHS | +0.044 ns | PASS |
| Hold THS | 0.000 ns | PASS |
| Hold failing endpoints | 0 | PASS |
| Unconstrained internal endpoints | 0 | PASS |

最差 setup 路径：

```text
Source      : issue_cycle_reg[0]_replica_29/C
Destination : lane_product_reg_reg[55][2]/D
Path group  : clk
Data delay  : 4.031 ns
Logic       : 2.116 ns (52.490%)
Routing     : 1.915 ns (47.510%)
Logic level : 11
Slack       : -2.052 ns
```

该路径属于 issue-cycle/系数选择到 DSP 乘法输入寄存器的控制/数据选择路径，包含 `DSP_A_B_DATA`、`DSP_MULTIPLIER`、`DSP_OUTPUT` 以及 LUT/MUX 级。当前结果说明未优化基线距离 500 MHz 还差约 2.052 ns，不能宣称时序闭合。

## 4. 资源

来自 post-route `report_utilization_postroute.rpt`：

| 资源 | Used | Available | Utilization |
|---|---:|---:|---:|
| CLB LUTs | 20,709 | 216,960 | 9.55% |
| LUT as Logic | 20,709 | 216,960 | 9.55% |
| LUT as Memory | 0 | 99,840 | 0.00% |
| Registers | 18,276 | 433,920 | 4.21% |
| DSP48E2 | 128 | 1,824 | 7.02% |
| Block RAM Tile | 0 | 480 | 0.00% |
| RAMB18 | 0 | 960 | 0.00% |
| RAMB36/FIFO | 0 | 480 | 0.00% |
| URAM | 0 | 64 | 0.00% |

层次报告将全部资源归属于 `p2f_dct2_64_b1_step102` 顶层；本轮没有使用 BRAM/URAM。

## 5. 功耗（仅作实现基线估计）

`report_power_postroute.rpt` 给出：

```text
Total On-Chip Power : 2.464 W
Dynamic              : 1.997 W
Device Static        : 0.466 W
Confidence           : Medium
Simulation Activity  : ---
```

这是 routed design 的 vectorless/default-activity 估计，没有 SAIF/VCD，内部节点活动置信度为 Medium。因此它只能作为 B2 基线记录，不能替代带真实工作负载的功耗结果，也不应直接与带不同实现策略的旧报告作严格比较。

## 6. OOC 约束说明

`check_timing -verbose` 报告：内部无时钟/最大延迟未约束端点；但 OOC 顶层存在 1042 个输入端口未指定 input delay、127 个输出端口未指定 output delay。这是模块级 OOC 边界条件，不能解释为板级 I/O 时序已经签核。报告中的 WNS 仅代表本次 OOC 方法和约束下的模块级 post-route 结果。

## 7. Gate 结论

```text
Step 10.2 functional baseline : PASS（49 cases / 784 beats，见既有报告）
Vivado synthesis              : PASS
Vivado implementation         : PASS
500 MHz setup                 : FAIL（WNS=-2.052 ns，TNS=-19555.092 ns）
500 MHz hold                  : PASS

FINAL: P2F-B2 / Step 11 = FAIL_SETUP
```

本轮到此停止。不得把该结果描述为 500 MHz 已闭合，也不得自动进入 Step 11.1 优化；下一步需由用户明确决定是否开展新的优化阶段。

## 8. 证据文件

- [OOC Tcl](../vivado/run_p2f_b2_ooc.tcl)
- [Vivado final log](../vivado/run/vivado_p2f_b2.log)
- [First-attempt log（仅记录命令兼容性问题）](../vivado/run/vivado_p2f_b2_first_attempt.log)
- [Post-route timing summary](../vivado/reports/report_timing_summary_postroute.rpt)
- [Hold timing summary](../vivado/reports/report_timing_hold_summary_postroute.rpt)
- [Worst setup paths](../vivado/reports/report_timing_worst20_postroute.rpt)
- [Unconstrained/check timing](../vivado/reports/report_timing_unconstrained_postroute.rpt)
- [Utilization](../vivado/reports/report_utilization_postroute.rpt)
- [Hierarchy utilization](../vivado/reports/report_hierarchy_utilization.rpt)
- [Power](../vivado/reports/report_power_postroute.rpt)
- [Post-route checkpoint](../vivado/reports/p2f_b2_postroute.dcp)
