# D3 UVM 协议层 + D4 功能覆盖率 + D5 回归 + 覆盖率/随机/复位补强

对应方案 D3（`agent + driver + monitor + scoreboard` + 2–3 个 sequence）。
范围为**协议层**：UVM 负责激励产生、握手检查、错误捕获；数值金标准不在这里
重算，直接取项目自己的向量文件（由 `generate_gate_c_hdl_vectors.py` 从 VTM10
oracle 生成），因此 UVM 层增加的是协议验证能力，不是第二个数值模型。

## 文件

| 文件 | 作用 |
|---|---|
| `its_if.sv` | DUT 接口，含 `drive_idle()` 复位辅助 |
| `its_uvm_pkg.sv` | 全部 UVM 类：item / 数据库 / sequence / 两个 agent / monitor / scoreboard / env / virtual sequencer / 15 个 test |
| `its_uvm_tb.sv` | 顶层：时钟、接口、DUT、`run_test()` |
| `run_its_uvm.py` | 生成向量、编译、跑 7 个用例（D3 冒烟路径）、独立核对数字 |
| `run_regress.py` | D5/D7/D8 全量回归：19 个用例、结构化判定、覆盖率合并、代码覆盖率 |
| `cases.json` | 回归用例表（19 条），判定期望写在这里而不是日志里 |
| `probe_case.py` | 单个用例的诊断探针，跑完直接打印 `RESULT_FILE`，不在流水线里 |
| `D3_RESULTS.json` | D3 证据：`run_its_uvm.py` 7 个用例的逐条结果与覆盖点 |
| `D4_COVERAGE.json` | D4 证据：`sweep` 单独跑 369 个 case 时的 7 个功能覆盖点 |
| `D5_REGRESSION.json` | D5 证据：19 个用例的结构化判定 + 合并功能覆盖率 + 失败分类表 |
| `D8_CODE_COVERAGE.json` | 代码覆盖率：19 个 UCDB 合并，DUT 口径，机器可读 |
| `D8_GAP_ATTRIBUTION.md` | 代码覆盖率缺口归因：148 条语句缺口逐类给出原因 |
| `D8_GAPS.csv` | 384 行缺口明细（设计单元 / 类型 / 行号 / 是否全局缺口 / RTL 源码） |
| `coverage_uvm_dut.txt` | 同一份代码覆盖率的 vcover 原始报告（给人看） |

DUT 是 `unified_its_wrapper #(.FINAL_SATURATE(1))`，与
`its_unified_submission_top` 内部实例化的是同一个配置。选 wrapper 而不是 top，
是因为 top 把 `protocol_error` 藏起来了，而协议层验证必须能看到它。

## 环境

- ModelSim SE-64 2020.4，`vsim -batch`（`-c` 路径会被代码完整性策略拦下）
- UVM **1.1d**，位于 `D:\software\Modelsim\verilog_src\uvm-1.1d\src`
- `uvm_pkg.sv` 必须与 TB **在同一次 `vlog`** 里编译，并统一带
  `+define+UVM_NO_DPI`；分两次编译会残留 DPI export，`vsim` 加载时转而要求
  C 编译器（`vsim-7019`）

运行：

```powershell
python run_its_uvm.py prep    # 生成向量 + 编译
python run_its_uvm.py run     # 跑 7 个用例（D3 冒烟路径）
python run_its_uvm.py all
```

## 结果（2026-11-10）

| 用例 | 期望 | TU | beat | 重叠接纳 | UVM_ERROR | 结论 |
|---|---|---:|---:|---:|---:|---|
| `single_tu` | 通过 | 1/1 | 4/4 | 0 | 0 | PASS |
| `rect_tu` | 通过 | 1/1 | 8/8 | 0 | 0 | PASS |
| `multi_tu_4` | 通过 | 4/4 | 32/32 | 3 | 0 | PASS |
| `multi_tu_16` | 通过 | 16/16 | 524/524 | 15 | 0 | PASS |
| `neg_wrong_golden` | 必须报错 | — | — | — | 4 | PASS（4 条全为 `ITS_DATA_MISMATCH`） |
| `neg_illegal_desc` | 必须报错 | — | — | — | 1 | PASS（`ITS_PROTOCOL_ERROR`，且仅 1 条） |

`TU` 与 `beat` 两列不是 scoreboard 自报，而是 `run_its_uvm.py` 用 Python 从向量
文件独立重算后比对的结果，不一致即判 FAIL。

## D4 功能覆盖率

覆盖点取自方案 D4 表，六个维度，全部实现在 `its_desc_coverage` 与
`its_out_coverage` 两个 subscriber 里。采样口径：

- 形状 / 变换类型 / LFNST 三个维度在 **TU 接纳时**采样，来自 `it_info` 字段
- 饱和分级 / 反压深度 / 停拍阶段三个维度在 **每个输出 beat 上**采样

### 结果（`sweep` 用例，369 TU / 45636 beat）

| 覆盖点 | 百分比 | bin | 分布 |
|---|---:|---|---|
| `shape` | 100.00% | 25/25 | 25 种合法 (w,h) 组合全覆盖 |
| `xform` | 100.00% | 9/9 | 双轴各 3 种变换类型的 9 种组合 |
| `lfnst_mode` | 100.00% | 3/3 | off=169 / set1=100 / set2=100 |
| `lfnst_idx` | 100.00% | 4/4 | idx 0–3 各 50 次（仅在开启 LFNST 时采样） |
| `sat` | 100.00% | 3/3 | 无饱和 8010 / 正轨 14620 / 负轨 23006 |
| `backpressure` | 100.00% | 4/4 | 深度 0=33635 / 1=9508 / 2=1436 / ≥3=1057 |
| `stall_phase` | 66.67% | 4/6 | scrub 2827 / fill 32 / output 12001 / 无停拍 33635 |

### 两个未命中 bin 是结构性不可达，不是测试不足

`stall_phase` 的 `lfnst` 与 `compute` 两 bin 恒为 0。原因在 RTL：

```systemverilog
// unified_its_wrapper.sv:1354
if (!output_active && !kernel_run_q && !lfnst_run_q && !scrub_active) begin
    // 只有在此条件下才会拉起新的 compute_valid
```

`output_active` 为真时（即存在待发 beat）DUT 不允许开启新的 kernel 或 LFNST
运行，因此「输出被反压」与「compute/LFNST 正在跑」在物理上不可能同时发生。
这条结论有 RTL 行号支撑，且与 45636 个 beat、含 8 拍深反压的实测结果一致。

按合法空间计算，`stall_phase` 是 4/4。

### 指标可证伪

同一个 covergroup 在 `single_tu`（单个 4×4 DCT-II）上报 14.67%（1/25），在
`sweep` 上报 100%（25/25）。同一套采样逻辑能报出低值，说明它不是恒为 100%
的空转指标——这是 D4 验收标准里「每个覆盖点要有正例和反例」的证据。

## 补强：代码覆盖率、约束随机、运行中复位、负向用例

D5 收口时判定这套 UVM 还不算完结，五个缺口里有四个在这里补上。

### 一、UVM 流程现在有代码覆盖率

之前 D1 的覆盖率数字来自另一套定向 TB，UVM 回归本身不采任何覆盖率。现在：

- 编译加 `+cover=bcestf`
- 每次仿真 `-coverage` 并 `coverage save -onexit <case>.ucdb`
- `run_regress.py coverage` 合并 19 个 UCDB 后按 `-du=unified_its_wrapper` 出报告

DUT 口径（`unified_its_wrapper`，19 个用例合并）：

| 指标 | 命中/总数 | 覆盖率 |
|---|---|---:|
| Assertions | 27/27 | 100.00% |
| Statements | 843/991 | 85.06% |
| Branches | 378/522 | 72.41% |
| Conditions | 92/136 | 67.64% |
| Expressions | 95/161 | 59.00% |
| FSM States | 9/9 | 100.00% |
| FSM Transitions | 11/26 | 42.30% |
| Toggles | 2147/5229 | 41.05% |

这组数字**不是**"全部覆盖"，也不是"和 D1 比谁强"，而是"每一条缺口都有归因"。
148 条语句缺口的分层见 `D8_GAP_ATTRIBUTION.md`：

| 类别 | 语句 | 分支 | 说明 |
|---|---:|---:|---|
| 从未被调用的函数 | 121 | 129 | 死代码，L841–1085 六个函数 |
| `case` 的 `default` 臂 | 4 | 4 | 合法形状全枚举，非法描述符更早被拦 |
| 防御性 `$fatal` | 4 | 4 | 命中即中止仿真 |
| 内部错误 → protocol_error | 2 | 2 | 需 kernel/lfnst 内部错误位 |
| 零馈送量向量 | 5 | 2 | 需向量无工作可馈送；支持的最小形状恒有 ≥1 点，未能证明可达 |
| 内部读流水线 tail 路径 | 11 | 2 | **D1 打到过、UVM 没打到 → UVM 的真实激励缺口** |
| 队列内 TU 的 end | 1 | 1 | 需两 TU 时序配合，收益低于成本 |
| 断言前置与包围条件互斥 | 0 | 1 | scrub 期间不提交 fill 写，前置恒假 |

**与 D1 的对比（含一次自我更正）**：这里先写过"D1 打完剩 143 条、UVM 剩 154 条、
量级相当"，随后又改成"D1 是 954 行、UVM 缺口集被完全包含、UVM 更深"——**第二个
说法是错的**。原因是 D2 的 `GAPS.csv` 有两套口径：`global_gap=True`（143 行，任何
实例都没执行过）和任意实例级（954 行，某些实例漏、某些命中）。我拿 954 那套去比，
包含关系自然成立，结论没有意义。

按 `global_gap=True` 重算，真实对比是：

| | D1 全局缺口行 | UVM 缺口行 | 交集 | 仅 D1 缺 | 仅 UVM 缺 |
|---|---:|---:|---:|---:|---:|
| Statements | 143 | 148 | 137 | 6 | **11** |
| Branches | 132 | 128 | 126 | 6 | **2** |

结论要改成：两者量级相当（143 vs 148）。**UVM 有 11 行是 D1 覆盖到、UVM 没覆盖的**，
全部落在 `kernel_h_rd_raw_tail` 那条路径（L2279–2283、L2303–2313）——这是 UVM 这套
的真实激励缺口，不是不可达路径；UVM 另外多覆盖了 6 行 D1 没覆盖的。所以正确说法是
"各有长短"，不是"谁更强"。

报告只出 `-du` 单块的原因：全设计报告每个实例打印一个小节，用扁平键解析会
把最后一个实例的数字当成全局值——我第一版就踩了这个坑，`Expressions` 被
报成 100%。

### 二、约束随机

`its_random_sequence` 三个 `rand` 字段：

| 字段 | 约束 |
|---|---|
| `n_tu` | `inside {[8:20]}` |
| `shape_pick` | 25 位形状掩码，`$countones` 落在 `[4:10]` |
| `max_gap` | `inside {[0:6]}`，TU 之间插随机空拍 |

抽取逻辑：按掩码筛出合法用例池，Fisher-Yates 不放回抽取，池空后退化为全库随机；
每个 TU 带 `gap_cycles` 随机空拍。

随机化的边界要讲清楚：**金标准仍来自向量文件**，所以随机的对象是"抽哪些合法
用例、什么顺序、间隔多少"，不是"随机造一个描述符再算期望值"。后者需要一个
独立的变换模型，UVM 层没有，也不该在这里造。

可复现：用例表里固定 `-sv_seed 12345`，同 seed 连跑两次结果一致
（两次都是 10 TU / 2472 beat）。

### 三、运行中复位

`its_reset_test`：先发 2 个 TU，然后 driver 等 `dbg_output_active` 拉高
（确保复位落在有待发 beat 的时刻）再拉低 `rst_n`，释放后发第 3 个 TU。

复位后 driver 向 scoreboard 写一个 marker，scoreboard 在 marker 处清空待比对
队列——被复位打断的 TU 剩下的 beat 永远不会来了。

结果：`tus=2 resets=1 data_errors=0 done_errors=0 unexpected=0 pending=0`。
含义是：复位打断了一个在飞 TU，此后**没有吐出任何脏 beat**，复位后的 TU 逐位
正确。`unexpected=0` 就是"没吐脏数据"的直接证据。

### 四、负向用例从 2 个扩到 8 个

新增 6 个，每个对应 RTL 里一条具体检查：

| 用例 | 违反的规则 | RTL 位置 | 实测反应 |
|---|---|---|---|
| `neg_lfnst_xform` | LFNST 开启但变换类型非 0 | `:775-778` | 1 次 protocol_error |
| `neg_lfnst_mode3` | LFNST mode=3 非法编码 | `:780-781` | 1 次 protocol_error |
| `neg_addr_overrun` | 数据地址越过 TU 最后一点 | `:2434-2436` | protocol_error + 4 条数据错 |
| `neg_stray_end` | 没有 TU 在填充时发 end | `:2438-2439` | 1 次 protocol_error |
| `neg_no_end` | 填充永不关闭 | — | 0 beat，1 个 TU 悬挂 |
| `neg_short_beats` | 只发一半输入就 end | — | TU 完成但 4 拍全错 |

后两个是 TB 级检测：DUT 不报协议错，但"不关闭填充就不该出 beat"和"截断输入
不该复现金标准"这两条由 scoreboard 兜住。

### 五、多 agent 与 virtual sequencer

先查了 DUT 到底有没有两路通道，结论是**没有**：

```
its_if.sv 端口：it_info/it_data_in/it_data_addr/it_data_in_vld/it_data_end
                + it_data_out_req（单个）/it_data_out/it_data_out_vld
```

一路输入、一路输出、单个 req。所以「两个激励 agent 并发」只能重复驱动同一批
管脚，那是假并发。因此按**管脚组**拆，拆出来的是真独立的 agent：

| 组件 | 拥有管脚 | 类型 |
|---|---|---|
| `its_driver` | `it_info*` / `it_data_in*` / `it_data_addr` / `it_data_end` | 激励 agent |
| `its_grant_driver` | `it_data_out_req` | 反压 agent |
| `its_monitor` | 只读观察 | 被动 |

反压驱动原本埋在输入 driver 里（`drive_output_grant()`），现在：

- 独立 item `its_grant_item`：`always_grant` / `light_mod` / `light_off` /
  `deep_period` / `deep_len` / `duration_cycles`
- 独立 sequencer `grant_seqr`
- **默认 profile 与旧行为逐字相同**（`light 7/11`、`deep 64/8`），所以原有
  15 个用例的 tus/beats/overlap 数字一个没变

  但有一个必须写明的差别：反压计数器 `cyc` 现在在独立组件里自由计数，起点不再
  与激励 driver 的 `run_phase` fork 点对齐，所以**单看某个短用例，反压 bin 的
  命中会变**（`rect_tu`、`multi_tu_4` 从 backpressure 3/4 变成 2/4）。DUT 侧
  行为不受影响，16 个用例合并后仍是 4/4、总覆盖率仍是 52/54。这种"bin 相位变了
  但结论不变"的差别如果不说，事后对不上数就说不清。
- `duration_cycles` 到期自动回落默认 profile，sequence 不需要知道时钟周期

`its_virtual_sequencer` 持有 `in_seqr` 与 `grant_seqr` 两个句柄，
`its_vseq_stress` 用 `fork...join` 同时启动激励序列与 profile 序列：

```systemverilog
fork
    stim.start(p_sequencer.in_seqr);     // 12 个 TU
    prof.start(p_sequencer.grant_seqr);  // 三档反压
join
```

实测日志证明两路真的在协作：

```
ITS_VSEQ] vseq tu_count=12 tu_start=0
ITS_GRANT] profile: grant always=0 light=5/9 deep=32/4 dur=6000
ITS_GRANT] profile: grant always=1 light=7/11 deep=64/8 dur=3000
ITS_GRANT] profile: grant always=0 light=3/5 deep=24/10 dur=6000
ITS_GRANT] profile expired, default restored
ITS_VSEQ] vseq complete tus=12 beats=200 overlap=11
```

`tus=12 beats=200 overlap=11 data_errors=0` —— 反压被程序化改变的同时，输出
仍然逐位正确。

**边界**：这是「两个真独立 agent + virtual sequencer」，不是「两路 DUT 通道
并发」。后者 DUT 不提供，硬做只能是假验证。

### 六、过程中被抓出来的三个 bug

**`do_copy` 没实现**：`uvm_object::copy()` 不报错也不复制，派生 item 变成全 0
描述符，于是非法描述符 → driver 死等 `it_data_in_req` → 仿真挂死十几分钟。
补 `do_copy` 后正常。

**`send_end_only` 无条件等 req**：裸 end 测试里没有 TU 在填充，`it_data_in_req`
永远不拉高，同样挂死。加了 `ignore_req` 参数。

**`-code bces` / `-du xxx` 不合法**：这个版本的 vcover 只认 `-du=xxx`，且不接受
`-code`。抄 D1 脚本的最简写法后正常。

三处挂死/失效都不是读代码看出来的，是靠加超时守卫和实跑暴露的。现在
`send_data` / `send_end_only` 里都有 20 万拍守卫，DUT 不再要数据会直接
`uvm_fatal` 而不是挂住。

## D5 回归（原始三个动作）

三个动作按方案 84–87 条实现：

| 动作 | 实现 |
|---|---|
| 用例列表外置 | `cases.json`，runner 不内嵌任何用例名 |
| 覆盖率合并 | 跨运行取 bin 并集，输出每组合与总体 |
| 失败分类自动输出 | `REGRESSION.json` 的 `failure_classes` |

### 判定与日志文本解耦

这是 D5 的关键约束。做法是让 TB 自己写结构化结果：

`its_base_test::write_result_file()` 在 `report_phase` 把 54 个覆盖 bin 计数和
`tus/beats/data_errors/done_errors/protocol_errors/unexpected/pending/overlap/
uvm_error/uvm_fatal` 逐行写成 `key=value`，路径由 `+RESULT_FILE=` 指定。

runner 只读这个文件做判定，**从不 grep 仿真日志**。所以 UVM 消息文案改动
不会翻转判定结果。

### 状态词表

按方案要求「SKIP 视为 INCOMPLETE，DIRTY/失败/缺阶段一律不算 PASS」：

| 状态 | 含义 |
|---|---|
| `PASS` | 所有期望字段全中，且 `uvm_fatal == 0` |
| `FAIL/<类>` | 字段不符，带具体类别 |
| `INCOMPLETE` | 结果文件缺失/为空/超时/被跳过 |
| `DIRTY` | 结果文件存在但坏（重复键、缺必填字段、退出码非零却结果干净） |

失败类别：`UVM_FATAL`、`UVM_ERROR_COUNT`、`EXPECTED_ERROR_MISSING`、
`TUS_MISMATCH`、`BEATS_MISMATCH`、`DATA_ERRORS_MISMATCH`、`PENDING_MISMATCH`、
`OVERLAP_NOT_OBSERVED`、`NO_RESULT_FILE`、`EMPTY_RESULT_FILE`、
`MISSING_FIELD:<名>`、`RESULT_DUPLICATE_KEY:<名>`、`SKIPPED`。

### 判定逻辑本身有测试

七个真实用例全过，失败分支本来一行都不会执行，所以另加
`run_regress.py selftest`：喂 13 个构造出来的结果（含 fatal、错误数不符、
缺结果文件、空文件、重复键、缺字段、tus_min 不足、复位计数不符）和 1 个
覆盖率合并检查，核对分类结果。

```
selftest: PASS (14/14)
```

端到端也验过一次：把 `single_tu` 的期望改成 `beats=999`，runner 报
`FAIL/BEATS_MISMATCH`、退出码 1——说明失败确实能被分类出来，不是只会报 PASS。

### 结果

```
[regress] 16 case(s) from cases.json
  [single_tu]        PASS  tus=1   beats=4
  [rect_tu]          PASS  tus=1   beats=8
  [multi_tu_4]       PASS  tus=4   beats=32   overlap=3
  [multi_tu_16]      PASS  tus=16  beats=524  overlap=15
  [neg_wrong_golden] PASS  uvm_error=4        （负向对照，期望报错）
  [neg_illegal_desc] PASS  uvm_error=1  protocol_errors=1
  [sweep]            PASS  tus=369 beats=45636 overlap=368
  [rand]             PASS  tus=10  beats=2472  （seed 12345）
  [neg_lfnst_xform]  PASS  protocol_errors=1
  [neg_lfnst_mode3]  PASS  protocol_errors=1
  [neg_addr_overrun] PASS  protocol_errors=1  data_errors=4
  [neg_stray_end]    PASS  protocol_errors=1
  [neg_no_end]       PASS  beats=0  pending=1
  [neg_short_beats]  PASS  data_errors=4
  [reset_mid_tu]     PASS  tus=2  resets=1  data_errors=0
  [vseq_multi_agent] PASS  tus=12 beats=200  overlap=11
  [neg_zero_data]    PASS  tus=1  beats=4  data_errors=4   （scrub 窗口内 end）
  [neg_desc_flood]   PASS  tus=0  beats=0  protocol_errors=1  pending=1
  [neg_end_only_fill] PASS tus=1  beats=4  data_errors=4   （fill 窗口内裸 end）

status: PASS 19
merged functional coverage: 52/54 = 96.30%
summary: 19/19 PASS，退出码 0
```

合并后只有 `stall_phase` 的 2 个不可达 bin 未命中（见 D4 章节）。

### 覆盖率合并的口径

合并用**扁平 bin 命中率**（命中 bin 数 / 定义 bin 总数，共 54 个），因为跨运行
唯一有定义的操作是 bin 并集。这与覆盖组自报的 `get_coverage()` 在部分命中时
权重不同（`single_tu` 下 `shape` 自报 14.67%，扁平口径是 1/25 = 4.00%），
但两者在 100% 时一致。两个数字不能混用，文档里分别标明。

## D3 验收标准对照（方案第 66–69 块）

| 标准 | 状态 | 依据 |
|---|---|---|
| `uvm_info` 层级不乱、逐位顺序正确 | 满足 | 19 个用例逐 beat 比对，40 位全等；`sweep` 共 45636 拍零差异 |
| 多个 TU 并行测试稳定 | 满足 | `sweep` 368 次重叠接纳，`multi_tu_16` 15 次；driver 不在 TU 之间等 done |
| 故意注错时 scoreboard 能报错 | 满足 | 金标准人为翻转 1 bit → 恰好 4 条 `ITS_DATA_MISMATCH`；非法描述符 → `ITS_PROTOCOL_ERROR` |

## 定向细节

- **背压**：`it_data_out_req` 平时按 `%7/%11` 双周期模式拉低，另每 64 拍注入一次
  连续 8 拍深停拍。没有深停拍时 `backpressure` 的 ≥3 bin 和重叠接纳都上不去
- **Sparse TU**：`input_count == 0` 的用例只发独立的 `it_data_end`，不发数据拍。
  `sparse_mode` 决定 end 落在哪个窗口：`2` = bind 后的 scrub 窗口内（DUT 按零数据
  退休该 TU），`0` = fill 窗口打开后（end-only marker，不产生数据命令）
- **done 配对**：scoreboard 要求 `done` 恰好落在最后一个 beat，且全 TU 只出现一次
- **负向对照的必要性**：`neg_wrong_golden` 翻转金标准后仍能"跑完"，若 scoreboard
  是空壳就查不出来；这条用例证明检查器可被证伪
- **覆盖率探针**：`scrub_active` / `fill_active` / `lfnst_busy` / `kernel_busy` /
  `output_active` 由 TB 顶层 `assign` 到接口，不改 RTL；`vsim` 需
  `-voptargs=+acc`，否则这些内部信号被优化掉，vopt 直接报错

## 自查发现并修正的不一致（2026-11-10）

做完之后逐条核对「文档写的 vs 实际跑的」，找出 7 处，全部已修：

| # | 问题 | 具体 | 处理 |
|---|---|---|---|
| 1 | 文档用例数滞后 | README 三处写「15 个用例」「7 个用例」，实际已是 16 个 | 改为 16 |
| 2 | 冒烟流程用例数写错 | README 写「跑 6 个用例」，`run_its_uvm.py` 实跑 7 个，自己输出的也是 `7/7 passed` | 改为 7 |
| 3 | 文件表缺项 | `probe_case.py`、`cases.json`、`run_regress.py` 没进文件表 | 补齐，并标明探针不在流水线里 |
| 4 | 自检用例数滞后 | README 写 `selftest 10/10`、9 个构造用例，实际 14/14、13 个 | 改为 14/14 |
| 5 | 覆盖率无机器可读产物 | 只有 `coverage_uvm_dut.txt` 这种给人看的文本，回归门禁无法比对 | `coverage` 阶段增写 `run/COVERAGE_CODE.json`，落库为 `D8_CODE_COVERAGE.json` |
| 6 | 用例表与测试类未对账 | 15 个测试类是否都被 `cases.json` 覆盖，之前没人查过 | 逐一比对：15 个非基类测试全部有用例（`its_multi_tu_test` 用两次），无孤儿测试 |
| 7 | 证据 JSON 无说明 | 4 个 `D*.json` 名字没人解释 | 进文件表，各写一行用途 |

另外确认了两件容易被误判的事：

- **仓库是 `blob:none` 部分克隆**（`remote.origin.promisor=true`、28448 个已跟踪
  文件、2327 个未取回 blob）。所以 `git ls-tree -l` 会尝试联网取对象，离网就失败；
  用它算出来的"仓库体积"只是已取回对象的子集，不能当真实体积报。
- **D3_RESULTS.json 已按当前代码重新生成**。重跑发现 3 个短用例的反压 bin 命中
  变了（原因见上文 agent 拆分那段），tus/beats/errors/overlap 全部不变。

## 已知限制

- 数值正确性依赖项目向量集（369 case），UVM 层未独立实现变换模型
- 随机化的对象是用例抽取/顺序/间隔，不是描述符本身的随机生成
- `stall_phase` 的 lfnst / compute 两 bin 受 RTL 结构约束不可达（见上）
- 两个 agent 按管脚组拆分（激励 / 反压），**不是两路 DUT 通道并发**；DUT 只有
  一路输入和一路输出，这是接口决定的
- 复位只测了"处理途中拉低 rst_n"一种时序，没有覆盖复位抖动或多拍复位
- DUT 覆盖率是 19 个用例合并的 DUT 单模块口径，不是全设计口径，也不是与 D1
  定向套件合并后的数；跨套件合并（UCDB 联并）尚未做
- 覆盖率合并（功能）是 bin 并集，不做加权
- 代码覆盖率有归因（`D8_GAP_ATTRIBUTION.md`）：其中"零馈送量向量"一类只是**未能
  证明可达**，不是**已证明不可达**；要证明需要形式化论证或用 `force` 注入，后者会
  越过协议层验证的边界，尚未做
- **明确的激励缺口**：`kernel_h_rd_raw_tail` 那 11 行 + 2 个分支，D1 的定向 TB 打到
  过、UVM 这套打不到。要补必须复现"两个 raw 响应背靠背到达"的条件，属于下一轮工作
- 分支缺口账目有一次对不齐：`vcover` 摘要报 144 miss，明细 CSV 是 145 行，
  **差 1 行原因未查明**，两边原始数字都保留