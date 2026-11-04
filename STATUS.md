# 仓库状态（STATUS）

> 本文件是仓库"当前状态"的唯一入口。`README.md` 讲 RTL 怎么用、怎么跑验证；版本沿革、证据索引、验证边界看这里。

## 当前有效交付

| 项 | 值 |
|---|---|
| 功能基线 | 本次 end-attribution 修复 + TU 顺序屏障（tag `v3.7-end-attribution-timing-closed`） |
| 生产顶层 | `02_rtl/rtl/its_unified_submission_top.sv` |
| 算术 profile | `contest_engineering_vtm10_sat10_v2`（shift 7/10，signed16 饱和裁剪，SAT10 → [-512, 511]） |
| 官方等价性 | **`official_equivalence = NOT_PROVEN`** |

## 版本沿革

| 版本 / 提交 | 日期 | 状态 |
|---|---|---|
| `v3.5-14` → `v3.5-18`、`v3.5-step12ar2.1-full` | 2026-09-10 ~ 09-14 | 历史内部迭代，已全部并入 `main` |
| `081efa6` | 2026-10-06 | SAT10 冻结交付，**已被取代**（标签 `v3.5-19-freeze-superseded`） |
| `1780eb9` | 2026-10-29 | 完整空间重建修复（标签 `v3.6-full-spatial-repair`） |
| 本次提交 | 2026-11-04 | `it_data_end` 提前到达归属修复、TU 顺序屏障及 500 MHz 名义时序闭合（标签 `v3.7-end-attribution-timing-closed`） |

### 为什么 `081efa6` 被取代

冻结版误将 **V 阶段的输入频率支撑高度**（`kernel_cut_h_q`）当作空间输出高度，在该支撑高度小于 TU 高度时丢失后续空间行。赛题输出索引是 `i = 0..nTbS-1`（完整空间范围），频率支撑只限制输入累加范围。

LFNST 关闭时：V 轴 DCT2-64 仅写回前 32 行，DCT8/DST7-32 仅写回前 16 行；V 轴 DCT2 ≤ 32 不会因这一裁剪规则丢行。LFNST 开启路径需按实际支撑高度判断。

64×64 DCT2、DC=512 时，旧版后 32 行错误为 0，修复后全部 4096 点为 16。

修复把 V 写回行数与输出组数改为完整空间高度（`kernel_h_q` / `kernel_h_q>>2`），RTL 差异仅 **13 行增 / 15 行删**，全部在 `unified_its_wrapper.sv`。

当时 369 配置能全绿，是因为 Python 参考模型与 RTL 共享同一个缺陷。修复提交同时修正了两边模型，并补上原生 VTM 逐点交叉核验（498 配置 / 293,360 值）与"冻结 RTL 应当失败"的负向对照（`EXPECTED_FAIL_DETECTED`）。

## 证据索引

| 内容 | 位置 |
|---|---|
| End attribution 功能与当前 500 MHz 名义时序证据 | `05_audit/current/104_end_attribution_timing_20261104/` |
| 完整空间修复证据 | `05_audit/current/103_full_spatial_repair_20261029/` |
| 修复设计说明 | `01_docs/current/FULL_SPATIAL_REPAIR.md` |
| 历史：1780eb9 的 core 级物理结果 | `05_audit/current/103_full_spatial_repair_20261029/physical/` |
| 历史：上一版 RTL 的物理闭合 | `05_audit/current/100_p9_primary_v_replay_20261006/`（对应 `081efa6` 版，已被取代） |
| 早期冻结交付 | `05_audit/current/101_final_submission_20261006/`、`102_final_release_20261006/` |
| 接口与形状规格提取 | `05_audit/current/58/…/HUAWEI_ATTACHMENT_INTERFACE_EXTRACT.txt` |

## 验证边界（引用任何结论时必须一并说明）

- 本次 500 MHz 时序闭合是 **registered-neighbor core 级**：WNS +0.006 ns、WHS +0.011 ns；setup 余量仅 6 ps，结果依赖记录的物理优化策略
- `081efa6` 版 setup 余量 +0.001 ns；`1780eb9` 版在报告精度下为 **0.000 ns**，hold +0.004 ns（均为历史结果）
- `NSTD-1` / `UCIO-1` 未消：`clk` / `rst_n` 的封装引脚与 IOSTANDARD 不在 harness 契约内
- 外部 `rst_n` 没有 input delay 模型
- 官方等价性 `NOT_PROVEN`：算术 profile、逆变换移位规则、LFNST-off 的 H/V 子集都是工程绑定，不是官方金标准

## 已知陷阱

`02_rtl/synth/top_500_singleclk_*.rpt`（8 个文件）生成于 **2026-07-04**，设计 `its_top_500_singleclk` 只有 1886 LUT / 2214 FF / 5 DSP，WNS +0.087 ns，**与当前实现无关**。

真实时序证据：本次实现位于 `05_audit/current/104_end_attribution_timing_20261104/physical/`（LUT 26160 / FF 19886 / DSP 320）；历史结果分别位于 `05_audit/current/100_p9_primary_v_replay_20261006/` 与 `05_audit/current/103_full_spatial_repair_20261029/physical/`。

## 未完成事项

- 板级 / 封装级 signoff（引脚、IOSTANDARD、外部复位时序）
- 官方等价性证明
- 仓库体积治理：`06_archive` 约占 76% 文件数，全仓库 86% 文件为字节级重复