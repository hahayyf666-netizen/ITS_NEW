# V3.2 时序裕量优化报告

> 日期：2026-08-08
> 基线：V3.1 冻结 RTL（its_core_500=04241edc, async_fifo=08254a2a）
> 顶层：its_top_500_singleclk，器件：xcku5p-ffvb676-2-e，clk=2.000ns
> 目标：仅通过 Vivado 实现策略提升 WNS 裕量，不修改 RTL

---

## 一、策略矩阵结果（同一份冻结 RTL）

| 策略 | place | phys_opt | route | **WNS** | WHS | LUT | FF | DSP | BRAM | 功耗(W) |
|------|-------|----------|-------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| STR01 | Explore | AggressiveExplore | Explore | **0.001** | 0.044 | 1940 | 2166 | 5 | 14.5 | 0.686 |
| STR02 | ExtraNetDelay_high | AggressiveExplore | Explore | 0.026 | 0.038 | 1936 | 2168 | 5 | 14.5 | 0.683 |
| **STR03** | **ExtraNetDelay_low** | **AggressiveExplore** | **Explore** | **+0.067** | 0.030 | 1937 | 2182 | 5 | 14.5 | 0.684 |
| STR04 | ExtraPostPlacementOpt | AggressiveExplore | Explore | 0.011 | 0.044 | 1957 | 2202 | 5 | 14.5 | 0.705 |
| STR05 | ExtraTimingOpt | AggressiveExplore | Explore | 0.020 | 0.039 | 1934 | 2183 | 5 | 14.5 | 0.688 |
| STR06 | SSI_SpreadLogic_high | AggressiveExplore | Explore | 0.000 | 0.044 | 1956 | 2196 | 5 | 14.5 | 0.703 |
| STR07 | Explore | AggressiveExplore | AggressiveExplore | 0.001 | 0.044 | 1940 | 2166 | 5 | 14.5 | 0.686 |
| STR08 | Explore | AggressiveExplore | NoTimingRelaxation | 0.003 | 0.044 | 1940 | 2166 | 5 | 14.5 | 0.688 |
| STR10 | Explore | AlternateReplication | Explore | 0.001 | 0.044 | 1940 | 2166 | 5 | 14.5 | 0.686 |
| STR11 | Explore | AlternateFlowWithRetiming | Explore | 0.001 | 0.044 | 1940 | 2166 | 5 | 14.5 | 0.686 |
| STR12 | ExtraTimingOpt | AlternateReplication | AggressiveExplore | 0.017 | 0.040 | 1927 | 2170 | 5 | 14.5 | 0.683 |

（STR09 使用无效 route 指令 ExtraTimingOpt，运行失败，已剔除）

### 最优策略：STR03（ExtraNetDelay_low）

```
place_design    -directive ExtraNetDelay_low
phys_opt_design -directive AggressiveExplore
route_design    -directive Explore
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AlternateFlowWithRetiming

WNS = +0.067 ns   （两次独立运行完全一致，确定性）
TNS = 0.000
WHS = +0.030 ns
THS = 0.000
```

### 最优策略最差路径

```
Slack (MET): +0.067 ns
Source:      u_wrapper/u_core/u_shared_engine/pf_dly_col_reg[0]/C
Dest:        u_wrapper/u_core/u_shared_engine/coeff_buf_reg_r2_192_255_0_6/RAMB/I
Data Path:   1.855 ns（logic 0.498 + route 1.357，路由占 73%）
```

路径为变换引擎 PREFETCH 延迟寄存器 → 系数缓冲 RAM 写入。路由主导，非组合逻辑深度问题。

---

## 二、裕量目标达成

| 目标 | 达成 |
|------|:--:|
| WNS ≥ +0.050ns | ✅ +0.067ns |
| 最好 WNS ≥ +0.100ns | ❌ 未达（需 RTL 流水化） |
| TNS = 0 | ✅ |
| THS = 0 | ✅ |
| WHS ≥ 0 | ✅ +0.030ns |
| 功能 RTL 不变 | ✅ |
| 无 false/multicycle/放宽时钟 | ✅ |

V3.1 基线 WNS=+0.001 → V3.2 最优 +0.067ns，提升 67ps（纯实现策略，零 RTL 改动）。

---

## 三、OOC 约束可信度分析

### 3.1 方法学报告（report_methodology）

| 告警 | 等级 | 数量 | 说明 |
|------|:--:|:--:|------|
| DPIR-2 | Warning | 240 | 异步复位驱动检查（rst_n 异步断言） |
| SYNTH-6 | Warning | 15 | RAM 块时序可能非最优 |
| SYNTH-9 | Warning | 6 | 小乘法器 |
| XDCH-2 | Warning | 97 | IO 端口 min/max 延迟相同（0.200/0.200） |

**无 Critical Warning，无 HD.CLK_SRC、无 PARTPIN_LOCS。**

### 3.2 OOC 边界影响（report_clock_utilization + check_timing）

| 检查项 | 结果 | 含义 |
|--------|------|------|
| BUFGCTRL / BUFGCE / MMCM | **0 使用** | OOC 不插入时钟树，`clk` 为虚拟时钟 |
| 引脚放置 | 无 | OOC 无物理 I/O 引脚，PARTPIN_LOCS 不适用 |
| no_clock | 0 | 无时钟缺失 |
| unconstrained_internal_endpoints | 0 | 无未约束内部端点 |
| I/O 延迟 | 0.200ns 假设值 | OOC 边界假设，非真实板级延迟 |

### 3.3 正确表述

> **模块级 OOC post-route 在 2.000ns 约束下时序闭合（WNS=+0.067ns）。完整板级时序仍取决于上层时钟树和引脚布局。** OOC 不包含 BUFG/MMCM 时钟树、真实引脚和板级 IO 延迟，板级闭合需在完整工程中另行验证。

---

## 四、结论

1. **纯实现策略提升裕量**：ExtraNetDelay_low 使 WNS 从 +0.001ns 提升到 **+0.067ns**，达到 ≥0.050ns 目标，无需修改 RTL。
2. **确定性可复现**：最优策略两次运行结果一致（WNS=0.067）。
3. **OOC 可信度**：模块级闭合成立；板级时序需完整工程验证。
4. **如需 +0.100ns 以上**：需 RTL 流水化（如 MAC 输入 P0 增加寄存器）。**未经确认不实施。**

---

## 五、产物

| 文件 | 内容 |
|------|------|
| `run_v32_best.tcl` | 最优策略完整脚本（可重复生成） |
| `v32_best.dcp` | 最优策略实现 checkpoint |
| `v32_best_timing_summary.rpt` | WNS=+0.067, TNS=0, WHS=+0.030 |
| `v32_best_setup.rpt` | 最差 setup 路径 |
| `v32_best_hold.rpt` | hold 路径 |
| `v32_best_utilization.rpt` | 1937 LUT / 2182 FF / 5 DSP / 14.5 BRAM |
| `v32_best_power.rpt` | 0.684W |
| 各策略日志 | `logs/STR*.log` |
