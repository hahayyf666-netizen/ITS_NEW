# ITS V3.5 / Step12F 当前项目总览 — Unified ITS 500 MHz 收敛中

本仓库是 VVC 反变换模块 ITS 的唯一持续工作目录。数学、RTL、验证、物理实现和审计证据均在本仓库内持续演进；历史版本通过 Git commit/tag 与 `05_audit/` 证据保留，不再为每个版本复制整套工程。

> **当前主线结论（2026-09-19）**
>
> - 当前真正 retained 的最佳 RTL 基线：**P9-R6 / R6A**。
> - 当前最佳 registered-neighbor 500 MHz 物理结果：**WNS = -0.045 ns，TNS = -4.882 ns，312 failing endpoints；hold WHS = +0.006 ns，0 failing；Fully Routed**。
> - 因此 **500 MHz core setup 尚未 sign off**，但已从 R5E 的 `-0.139 ns / -74.139 ns / 1808 endpoints` 大幅收敛到最后的 distributed routing tail。
> - R6B 的 `ExtraTimingOpt` placement treatment 已拒绝。
> - R7 的功能回归全部 PASS，但 fresh implementation 退化为 `-0.134 ns / -42.408 ns / 1006 endpoints`，因此 **R7 已拒绝**。
> - **当前 `main` 的 RTL 内容仍包含 R7 的失败实验改动**（该实验由 commit `8b873a30...` 引入）；本次 README 更新不修改 RTL。继续新 RTL 实验前必须先恢复 retained R6 RTL。
> - 下一项计划中的 bounded 实验是 **R8：wrapper compute-side `slot_state` exact shadow replication**；截至本 README 更新时尚未执行。
> - package-level FPGA timing 仍 **NOT_EVALUATED**。

---

## 1. 项目目标

项目对应第九届中国研究生创芯大赛华为赛题一：**VVC 反变换模块 ITS 设计**。

核心目标：

1. 支持 DCT2 / DST7 / DCT8 主反变换；
2. 支持 LFNST；
3. LFNST 路径遵守“先 LFNST，再主反变换”的调用顺序；
4. 支持题目接口规定的稀疏/非零输入；
5. 计算侧实现 P4：稳定运行时一拍处理/产生 4 个结果级别的数据；
6. 输出接口一拍输出 4 个最终结果；
7. 目标时钟 **500 MHz（2.000 ns）**；
8. 兼顾面积与功耗；
9. 覆盖题目规定的尺寸、变换类型及二维组合；
10. 官方接口、握手、反压、ordering、ownership、completion 行为必须可验证。

当前项目已经不处在“功能是否能跑”的阶段，而是处在：

> **完整 unified ITS 已完成大规模功能/吞吐验证，当前主要 blocker 是 500 MHz setup closure。**

---

## 2. 一眼看懂当前完成度

| 项目 | 当前状态 |
|---|---|
| 主变换数学方向 / 矩阵来源 | **PASS / 冻结** |
| 独立 Oracle | **PASS / 冻结** |
| LFNST 当前工程合同 | **PASS / 冻结** |
| 官方接口 / descriptor / sparse input | **PASS** |
| P4 kernel 功能 | **PASS** |
| group II / vector II | **PASS：group II=1，vector II=N/4** |
| 多类型 / 多尺寸 / rectangles | **PASS：Gate-C 369 tuples** |
| Backpressure / ordering / ownership / completion | **PASS** |
| ModelSim normal | **PASS** |
| ModelSim `SYNTHESIS` | **PASS** |
| Fresh Vivado synth/place/route | **已真实完成** |
| Route | **Fully Routed** |
| Hold @ 500 MHz | **PASS（R6）** |
| Setup @ 500 MHz | **FAIL：WNS -0.045 ns（R6A 最佳）** |
| Package-level signoff | **NOT_EVALUATED** |
| 当前 retained baseline | **R6 / R6A** |
| R7 | **REJECTED** |
| R8 | **PLANNED / NOT_EXECUTED** |

---

## 3. 当前 Git / baseline 状态

### 3.1 retained baseline

真正应该作为后续比较参考的是：

```yaml
R6_RTL: RETAINED / FROZEN
R6A_PHYSICAL_RESULT: CURRENT_BEST
R7: REJECTED_PHYSICAL_SETUP_REGRESSION
500MHz_CORE_SIGNOFF: NOT_ACHIEVED
PACKAGE_LEVEL_TIMING: NOT_EVALUATED
```

关键提交：

- R6 RTL：[`1f7c119`](https://github.com/hahayyf666-netizen/ITS_NEW/commit/1f7c11919d13e3df0f9dda23c00bba312a3c0546)
- R6A setup-tail qualification：[`2a04edb`](https://github.com/hahayyf666-netizen/ITS_NEW/commit/2a04edb93836c5771f7fda26fd559372d7d2f6a8)
- R6B physical-convergence A/B：[`89e4c4e`](https://github.com/hahayyf666-netizen/ITS_NEW/commit/89e4c4e10c0a7ff380ec2570c5b596cc582bfa15)
- R7 rejected experiment：[`8b873a30`](https://github.com/hahayyf666-netizen/ITS_NEW/commit/8b873a30a8e24eb2068f4945e5ae2edab61936c8)

### 3.2 当前 main 的一致性注意事项

R7 已被工程结论明确拒绝，但目前 `main` 的 RTL 内容仍保留了 R7 的一行实验性删除：

```systemverilog
// rejected R7 experiment removed this transaction-time clear:
lfnst_grid[lfnst_grid_i] <= '0;
```

继续新的 RTL 实验前，应先恢复 retained R6 行为，使：

`02_rtl/rtl/unified_its_wrapper.sv`

与 R7 parent `89e4c4e...` 中的 retained R6 RTL 一致。

建议单独提交：

```text
Restore retained R6 RTL after rejected R7
```

以后失败的 RTL experiment 应优先在独立 branch/worktree 中执行；失败时只保留 audit evidence，不让 rejected RTL 留在 `main`。

---

## 4. 数学与定点契约

### 4.1 主变换方向

主变换方向已经冻结：

```text
inverse operator A = C^T
RTL computes A · x
```

禁止再次做额外 transpose。

`trType`：

```text
0 = DCT2
1 = DST7
2 = DCT8
```

### 4.2 LFNST

LFNST 保持：

```text
M · x
```

不因为主变换改为 `A=C^T` 而转置。

LFNST 的扫描顺序、有效输入数量、`nTrs=16/48`、写回规则已经在 V3.4/V3.5 的 Oracle 与 RTL 交叉核对中冻结。

### 4.3 当前工程 profile

当前统一验证 profile：

```text
contest_engineering_vtm10_v1
```

定位：

- 用于当前 Oracle / RTL / HDL 回归的一致工程合同；
- 不冒充未获得的官方 hidden-golden 等价性证明；
- bit depth = 10；
- extended precision off；
- max dynamic range = 15；
- inverse shift 按当前冻结的 type × N × stage 合同执行；
- 当前接口 LOW10 two's-complement adapter 为主；
- SAT10 保留为对照/差分 adapter。

---

## 5. 当前 RTL 架构

### 5.1 Unified P4 kernel

当前主线不再是早期串行 4-MAC 核，而是 unified P4 架构。

主要特点：

- 每个 input/output group 为 4 个样本；
- group II = 1；
- vector II = N/4；
- arithmetic path 显式流水；
- 支持 overlapping invocation；
- result FIFO 吸收 output backpressure；
- slot / issue / descriptor / result ownership 有 assertion 与 trace 证据。

当前主变换支持范围：

- DCT2：4 / 8 / 16 / 32 / 64；
- DST7：4 / 8 / 16 / 32；
- DCT8：4 / 8 / 16 / 32。

### 5.2 Unified ITS wrapper

`unified_its_wrapper.sv` 负责：

- `it_info` descriptor 解码；
- sparse input 接受；
- input cache；
- tag / epoch ownership；
- vertical / horizontal phase；
- LFNST orchestration；
- kernel read command；
- intermediate / result storage；
- output backpressure；
- done / completion；
- slot lifecycle；
- 多 TU ownership。

### 5.3 Registered-neighbor harness

当前用于真实 core timing 的顶层：

```text
step12f_registered_neighbor_harness
```

该 harness 使用 live internal source FF 驱动 DUT 输入，并用 live sink FF 捕获 DUT 输出，使 timing 结论落在“相邻寄存器 → DUT → 相邻寄存器”的 integration context，而不是旧式裸 OOC port timing。

---

## 6. 当前功能与吞吐验证

Simulator：

```text
ModelSim SE-64 2020.4
```

normal 和 `SYNTHESIS` 两种模式均执行完整回归。

当前冻结的主要结果：

```text
Gate-B numeric:
  156 cases PASS

Gate-B legacy vector-II:
  7 modes PASS

Gate-F full vector-II:
  13 modes PASS

Gate-C unified wrapper:
  369 legal tuples PASS
  45,636 beats PASS

LFNST engine specialty:
  1,088 cases PASS

LFNST wrapper specialty:
  258 cases PASS

P3 V-write:
  PASS

P4 Stage-0 N=4 stream:
  16/16/16/16 PASS
```

同时验证：

- sparse / zero / extreme / random；
- rectangles；
- mixed H/V transform type；
- long backpressure；
- ordering；
- owner / slot / epoch；
- duplicate / drop；
- completion / done；
- normal / `SYNTHESIS` 一致性。

因此当前主要工程风险已经不是 numerical correctness，而是 physical convergence。

---

## 7. 关键演进路线

### 7.1 V1 → V3.4：数学、协议、方向、LFNST

关键里程碑：

- V1：矩阵来源与 `trType` 映射审计；
- V2：将规范矩阵应用到 RTL；
- V3：输出协议审计；
- V3.1：输出零气泡；
- V3.2：历史 OOC timing strategy；
- V3.3：主变换正式修正为 `A=C^T`；
- V3.4：LFNST 有效输入数量与写回规则冻结。

### 7.2 V3.5：独立 Oracle

建立并冻结：

- pure operator math；
- RTL bit-exact model；
- bounded VTM reference；
- one-hot；
- signed16 边界；
- wrap / clip；
- full-range random；
- 2D vertical→horizontal；
- LFNST；
- RTL ↔ independent Oracle cross-check；
- fail-closed mutation。

后续 expected 不依赖 RTL 自己生成。

### 7.3 P2A / P2F：P4 架构探索

P2A direct-matrix 256-lane 路线被保留为历史 PPA/时序基线，但由于资源、系数网络、不可停 pipeline 等实现风险，没有成为最终主线。

P2F / R4C 路线完成：

- DCT2-64 精确 factorization；
- raw 数学等价；
- 128-lane 原型；
- 4 complete results/beat；
- vector interval = 16；
- 最终形成冻结的一维 R4C P4 kernel。

### 7.4 Step12B / Step12C：二维 wrapper 与 memory topology

完成：

- 64×64 DCT2×DCT2 单 R4C wrapper；
- transaction-edge 语义；
- memory request/response 周期合同；
- R4C latency = 23；
- two-TU / descriptor / epoch / backpressure；
- internal/public trace；
- banked input/intermediate/result storage；
- staging response pipeline；
- bank-local input write command；
- tag/epoch compare 的物理结构修复。

Step12C 历史上曾在特定 64×64 DCT2×DCT2 wrapper scope 下得到 500 MHz 通过结果；该结果不能外推为当前 unified full ITS 已 sign off。

### 7.5 Step12D / Step12F：统一 profile 与完整功能扩展

Step12D：

- 冻结 `contest_engineering_vtm10_v1`；
- 建立 unified P4；
- 扩展多类型、多尺寸、rectangles 与 LFNST。

Step12F：

- Gate-C：369 tuples / 45,636 beats；
- 13-mode vector-II；
- unified wrapper；
- 进入 R5/R6/R7 registered-neighbor physical convergence 主线。

---

## 8. 当前 physical convergence 主线

### 8.1 R5E — 首个可信 registered-neighbor qualification

环境：

```text
Vivado 2025.2
part: xcku5p-ffvb676-2-e
clock: 2.000 ns
threads: 4
```

retained flow：

```text
synth_design -flatten_hierarchy none -directive Default
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
```

结果：

| Metric | R5E |
|---|---:|
| Setup WNS | -0.139 ns |
| Setup TNS | -74.139 ns |
| Setup failing endpoints | 1808 |
| Hold WHS | +0.010 ns |
| Hold THS | 0 |
| Hold failing endpoints | 0 |
| Route | Fully Routed |

结论：hold PASS，setup STOP。

证据：

`05_audit/current/59/p9_r5e_registered_neighbor_20260917_defaulttop/`

### 8.2 R5F — 1808 endpoint setup census

R5E exact routed DCP 全量 read-only census：

```text
negative endpoints = 1808
DUT internal = 1777
DUT internal TNS ≈ -72.297 ns
DUT internal TNS share ≈ 97.6%
normalized family groups = 234
```

分类：

```text
DISTRIBUTED_MULTI_FAMILY_TIMING_TAIL
```

主要历史 family：

- P4 ingress_group/data → input_mem；
- fill_wr_cmd → input_cache；
- kernel_run → lfnst_grid；
- result command → result bank；
- rd_cmd → kernel raw data；
- H-read；
- FIFO / control。

证据：

`05_audit/current/59/p9_r5f_setup_census_20260917_final/`

### 8.3 R5G — producer-only locality branch 已关闭

做过：

- physical locality inventory；
- failing/passing distance comparison；
- whole-64 producer relocation geometry；
- corrected upstream/downstream geometry；
- expanded inventory；
- 32-row bounded screening。

最终：

```text
32 candidates evaluated
rows with D_NEAR mention = 4
rejected only by D_NEAR = 0
producer-only locality = CLOSED
```

因此：

- 不再继续 G0.7/G0.8；
- 不做无限 producer-only placement 搜索；
- geometry proxy 不冒充 timing proof。

证据：

`05_audit/current/60/` ～ `64/`

### 8.4 R6 — 当前最成功的结构性优化

R6 针对 R5F 的：

```text
fill_wr_cmd_addr_q -> input_cache_bank
```

实施 bank-local accepted write-command replication/localization。

功能与 throughput 不变。

结果：

| Metric | R5E | R6 |
|---|---:|---:|
| Setup WNS | -0.139 ns | **-0.045 ns** |
| Setup TNS | -74.139 ns | **-4.882 ns** |
| Setup failing endpoints | 1808 | **312** |
| Hold WHS | +0.010 ns | **+0.006 ns** |
| Hold failing endpoints | 0 | **0** |

改善：

- WNS：+94 ps；
- |TNS|：减少 69.257 ns；
- failing endpoints：减少 1496。

R6 post-route resource：

```text
DSP48E2          320
CLB LUTs         28,043
distributed RAM   5,632 LUTs
CLB registers    25,831
CARRY8            1,487
F7 MUX             1,743
F8 MUX               592
BRAM                  0
URAM                  0
```

状态：

```yaml
R6: EFFECTIVE_PARTIAL
R6: RETAINED / FROZEN
500MHz: NOT_SIGNED_OFF
```

证据：

`05_audit/current/65/p9_r6_input_cache_local_20260918/`

### 8.5 R6A — 当前最佳物理解的 residual tail

exact R6 routed DCP：

```text
raw negative paths = 312
unique endpoints = 312
duplicates = 0
unclassified = 0

authoritative WNS = -0.045 ns
authoritative TNS = -4.882 ns

DUT internal:
  303 endpoints
  reconstructed TNS = -4.835 ns
```

分类：

```text
DISTRIBUTED_MULTI_FAMILY_ROUTING_TAIL
```

集中度：

```text
top-1 |TNS| share = 18.7%
top-5 |TNS| share = 41.7%
```

重点：

```text
slot_state -> lfnst_grid:
  45 endpoints
  TNS = -0.914 ns
  worst = -0.045 ns

rd_cmd_addr related:
  28 endpoints
  TNS ≈ -0.505 ns

historical fill command -> input cache:
  0
```

即：R6 已经消掉原 fill-write 大热点，但剩余 violation 是分散的 routing tail。

证据：

`05_audit/current/66/p9_r6a_setup_tail_20260918/`

### 8.6 R6B — physical placement treatment 已拒绝

受控 A/B：

| Run | Placement | WNS | TNS | Endpoints |
|---|---|---:|---:|---:|
| R6A retained | retained R6 implementation | -0.045 | -4.882 | 312 |
| CONTROL | ExtraNetDelay_high | -0.055 | -5.960 | 320 |
| TREATMENT | ExtraTimingOpt | -0.188 | -416.302 | 6047 |

两支：

- Fully Routed；
- hold PASS；
- routing errors = 0。

结论：

```text
ExtraTimingOpt = REJECTED
blind placement strategy sweep = CLOSED
```

证据：

`05_audit/current/67/p9_r6b_physical_convergence_20260918/`

### 8.7 R7 — 功能正确，但 physical regression，正式拒绝

R7 只做一个单点 RTL 实验：

```systemverilog
// transaction admission 中删除：
lfnst_grid[lfnst_grid_i] <= '0;
```

`lfnst_grid_valid <= 0` 保留。

功能回归：

- normal PASS；
- `SYNTHESIS` PASS；
- 369 tuples / 45,636 beats PASS；
- LFNST PASS；
- 13-mode II PASS；
- N=4 stream PASS。

Fresh implementation：

| Metric | R6A | R7 |
|---|---:|---:|
| Setup WNS | -0.045 ns | **-0.134 ns** |
| Setup TNS | -4.882 ns | **-42.408 ns** |
| Setup failing endpoints | 312 | **1006** |
| Hold WHS | +0.006 ns | **+0.007 ns** |
| Hold failing endpoints | 0 | **0** |

R7 census：

```text
DUT internal = 972 / 1006
DUT internal reconstructed TNS ≈ -40.971 ns
TNS share ≈ 96.57%
family pairs = 192
```

结论：

```yaml
R7: REJECTED_PHYSICAL_SETUP_REGRESSION
R6: RETAINED / FROZEN
FOLLOW_ON_BLIND_RTL: NOT_AUTHORIZED
```

R7 的意义：

> 当前设计已经对 placer/router 的全局物理解非常敏感。局部减少逻辑不等于整体时序改善；后续干预必须针对覆盖较大 population 的共同结构源，并用 fresh implementation 验证。

证据：

`05_audit/current/68/p9_r7_lfnst_grid_clear_20260918/`

---

## 9. 当前真正还要突破什么

当前最大的剩余技术问题只有一个：

> **在不破坏现有数学、功能、协议和 P4 吞吐的前提下，把 R6A 的 distributed routing setup tail 从 WNS -45 ps 推过 0，同时保持 hold PASS。**

当前已经不是以下问题：

- 不是矩阵/方向错误；
- 不是 LFNST 主规则未闭合；
- 不是基本握手错误；
- 不是 group II 不够；
- 不是 route 不通；
- 不是 hold failure；
- 不是 R5 的 fill-write 大热点仍存在。

当前真正的问题：

- setup violation 分布在多个 control/read family；
- routing fraction 较高；
- 单一 family 不占绝对主导；
- small RTL perturbation 可能触发大范围 placement/routing 重排；
- 只剩最后约 45 ps WNS，但不能通过盲目微调保证获得。

---

## 10. 下一项计划：R8 bounded experiment

R6A 进一步聚合显示：

```text
wrapper slot_state_reg:
  53 failing endpoints
  TNS ≈ -1.019 ns
  worst = -0.045 ns

其中：
slot_state -> lfnst_grid
  45 endpoints
  TNS = -0.914 ns

P4 internal slot_state_q_reg:
  64 failing endpoints
  TNS ≈ -1.125 ns
```

因此下一项计划中的候选：

```text
P9-R8 — Wrapper compute-side slot-state exact shadow replication
```

设计原则：

- 先只动 wrapper `slot_state`；
- 新增同周期 exact shadow register；
- 所有 state assignment 同周期镜像；
- 禁止 `shadow <= primary` 形成额外一拍；
- 只将 compute admission 的 `SLOT_READY` consumer 切到 shadow；
- bind / free-slot / ownership 继续使用 primary；
- 不同时改 P4 `slot_state_q`；
- 不改 arithmetic；
- 不增 pipeline；
- 不改 handshake；
- 不改 XDC；
- 不做新的 placement strategy sweep。

执行边界：

1. 先恢复 R6 baseline；
2. R8 从独立 branch/worktree 开始；
3. normal + `SYNTHESIS` 全回归；
4. post-synth structural gate 先确认 shadow 未被合并；
5. 再 fresh R6-equivalent place/route；
6. 只与 R6A `-0.045 / -4.882 / 312` 比较；
7. R8 若失败，不继续 R8.1/R8.2 盲试。

---

## 11. 当前可以宣称与不能宣称的边界

### 已有证据支持

可以说：

- 主变换方向与矩阵来源已审计；
- LFNST 当前工程合同已审计；
- independent Oracle 已建立；
- unified P4 HDL 功能与吞吐回归成熟；
- 369 legal tuples / 45,636 beats 已完成 HDL coverage；
- registered-neighbor fresh Vivado implementation 已真实完成；
- R6 Fully Routed；
- R6 hold PASS；
- R6 是当前有效 partial physical improvement；
- R6A 是当前最佳 physical result。

### 仍不能扩大表述

不能说：

- 完整 ITS 已 500 MHz signoff；
- package-level FPGA 已 signoff；
- 历史 64×64 wrapper 的 +11 ps 可以代表当前 unified full core；
- R7 是 current retained RTL；
- bounded locality close 等于数学上证明所有 locality 方法无效；
- 单一 worst path 的逻辑简化必然改善全局 timing；
- 当前 engineering profile 已证明官方 hidden-golden 完全等价。

---

## 12. 当前 Vivado / timing contract

```text
Vivado:
  2025.2 Build 6299465

Part:
  xcku5p-ffvb676-2-e

Clock:
  2.000 ns
  500 MHz

Threads:
  4

Retained implementation flow:
  synth_design ... -flatten_hierarchy none -directive Default
  opt_design -directive Default
  place_design -directive ExtraNetDelay_high
  phys_opt_design -directive AggressiveExplore
  route_design -directive NoTimingRelaxation
```

registered-neighbor scope：

- DUT inputs 由 live internal source FF 驱动；
- DUT outputs 由 live internal sink FF 捕获；
- old OOC data-port delay XDC 不加载；
- `rst_n` 为预期的 no-input-delay control；
- unconstrained internal endpoints = 0；
- no timing exception 用于掩盖 setup；
- package pin / IOSTANDARD / board-level timing 不在当前 signoff 范围。

---

## 13. 仓库目录导航

| 目录 | 内容 |
|---|---|
| `01_docs/` | 当前架构、合同、说明和历史文档 |
| `02_rtl/` | RTL、ROM、XDC |
| `03_verification/` | Python、ModelSim、testbench、vectors、Vivado Tcl |
| `04_reference/` | 华为附件、VTM 与参考源 |
| `05_audit/` | 当前/历史 reports、JSON、CSV、manifest、timing evidence |
| `06_archive/` | 退休原型、旧审计、生成缓存；不作为当前执行入口 |

详细文档入口：

- [`01_docs/README.md`](01_docs/README.md)
- [`01_docs/current/Step12B.md`](01_docs/current/Step12B.md)
- [`01_docs/current/Step12D.md`](01_docs/current/Step12D.md)

---

## 14. 当前最重要的 evidence

```text
R5E registered-neighbor:
05_audit/current/59/p9_r5e_registered_neighbor_20260917_defaulttop/

R5F full setup census:
05_audit/current/59/p9_r5f_setup_census_20260917_final/

R5G locality / geometry / bounded screening:
05_audit/current/60/
05_audit/current/61/
05_audit/current/62/
05_audit/current/63/
05_audit/current/64/

R6 input-cache command localization:
05_audit/current/65/p9_r6_input_cache_local_20260918/

R6A setup-tail qualification:
05_audit/current/66/p9_r6a_setup_tail_20260918/

R6B physical-convergence A/B:
05_audit/current/67/p9_r6b_physical_convergence_20260918/

R7 rejected LFNST-grid-clear experiment:
05_audit/current/68/p9_r7_lfnst_grid_clear_20260918/
```

---

## 15. 已退休 / 已关闭的方向

以下不应继续作为默认主线：

- 早期 4-MAC 串行核心；
- P2A 直接 256-lane 作为最终架构；
- 历史 32-group FIFO gate；
- producer-only locality 无限搜索；
- G0.7/G0.8 类继续扩张；
- ExtraTimingOpt placement treatment；
- R7 redundant LFNST-grid data-clear removal；
- 看到一条 worst path 就直接做 blind RTL cut；
- 把旧 OOC data input/output delay 直接套到 registered-neighbor core。

这些历史仍作为 evidence 保存，不删除。

---

## 16. 当前验证入口

常用基础检查仍从：

```powershell
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_current_checks.ps1
powershell -ExecutionPolicy Bypass -File 03_verification/scripts/run_step12b_checks.ps1
```

开始。

Step12F 的 authoritative gate 应以对应 audit package 中记录的 normal / `SYNTHESIS` coverage、Gate-C、LFNST、vector-II 和 Vivado Tcl 为准；不要仅依据旧 Step12B runner 判断当前 full unified wrapper 状态。

历史脚本 `run_p2f_a1_dataflow.py` 属于已退休的 32-group FIFO 合同，按旧规则报告 FAIL 不代表当前 unified kernel regression。

---

## 17. 接手者现在应该怎么继续

如果今天第一次接手这个项目，推荐顺序：

1. 阅读本 README，理解 retained / rejected / historical 三类状态；
2. 查看 R6、R6A、R6B、R7 audit；
3. 确认当前 `main` RTL 是否已恢复到 R6；
4. 若仍包含 R7 一行删除，先做 baseline restoration；
5. 不动其它逻辑，建立独立 R8 branch/worktree；
6. 执行 wrapper `slot_state` exact-shadow 单变量实验；
7. full ModelSim normal + `SYNTHESIS`；
8. post-synth structural gate；
9. fresh R6-equivalent implementation；
10. 与 R6A：
    `WNS=-0.045 / TNS=-4.882 / 312 endpoints / hold PASS`
    做严格比较；
11. R8 若失败，停止该方向；
12. R8 若真正 setup+hold closure，再做一次 independent fresh replay；
13. replay 仍 PASS 后，才进入 registered-neighbor 500 MHz core signoff 与 package/PPA 收尾。

---

## 18. 当前北极星

当前项目不再以“增加更多审计脚本”为目标。

真正的工程判断标准是：

> **每一步是否能在保持功能、接口、ordering、backpressure 与 P4 throughput 的前提下，把完整 unified ITS 推向真实 500 MHz closure。**

当前最大剩余突破点：

```yaml
best_setup_WNS: -0.045 ns
best_setup_TNS: -4.882 ns
best_setup_failing_endpoints: 312
hold: PASS
route: FULLY_ROUTED

R6: RETAINED_FROZEN
R6A: CURRENT_BEST_PHYSICAL_RESULT
R6B: PHYSICAL_TREATMENT_REJECTED
R7: REJECTED_PHYSICAL_SETUP_REGRESSION
R8: PLANNED_NOT_EXECUTED

500MHz_core_signoff: NOT_ACHIEVED
package_level_timing: NOT_EVALUATED
```

**当前唯一大的技术关卡：把 R6A 剩余的 -45 ps distributed routing setup tail 推过 0，并保持 hold PASS。**

---

## 19. README 维护规则

本文件是仓库根目录的项目总入口。

更新规则：

- retained baseline 改变时，必须更新顶部当前状态；
- 每次新的真实 Vivado qualification 后更新 physical 结果；
- rejected experiment 可以保留历史，但不得写成 active baseline；
- GitHub commit、raw report、machine-readable JSON/CSV/manifest 是 evidence authority；
- README 负责回答“项目是什么、做到哪里、证据在哪里、下一步是什么”；
- README 与证据冲突时，以最新已审核 evidence 为准，并立即修正 README。
