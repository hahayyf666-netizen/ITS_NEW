# D3 UVM 协议层 + D4 功能覆盖率 + D5 回归

对应方案 D3（`agent + driver + monitor + scoreboard` + 2–3 个 sequence）。
范围为**协议层**：UVM 负责激励产生、握手检查、错误捕获；数值金标准不在这里
重算，直接取项目自己的向量文件（由 `generate_gate_c_hdl_vectors.py` 从 VTM10
oracle 生成），因此 UVM 层增加的是协议验证能力，不是第二个数值模型。

## 文件

| 文件 | 作用 |
|---|---|
| `its_if.sv` | DUT 接口，含 `drive_idle()` 复位辅助 |
| `its_uvm_pkg.sv` | 全部 UVM 类：item / 数据库 / 3 个 sequence / driver / monitor / scoreboard / env / 5 个 test |
| `its_uvm_tb.sv` | 顶层：时钟、接口、DUT、`run_test()` |
| `run_its_uvm.py` | 生成向量、编译、跑 6 个用例、独立核对数字 |

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
python run_its_uvm.py run     # 跑 6 个用例
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

## D5 回归

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
`run_regress.py selftest`：喂 9 个构造出来的结果（含 fatal、错误数不符、
缺结果文件、空文件、重复键、缺字段）和 1 个覆盖率合并检查，核对分类结果。

```
selftest: PASS (10/10)
```

端到端也验过一次：把 `single_tu` 的期望改成 `beats=999`，runner 报
`FAIL/BEATS_MISMATCH`、退出码 1——说明失败确实能被分类出来，不是只会报 PASS。

### 结果

```
[regress] 7 case(s) from cases.json
  [single_tu]        PASS  tus=1   beats=4
  [rect_tu]          PASS  tus=1   beats=8
  [multi_tu_4]       PASS  tus=4   beats=32   overlap=3
  [multi_tu_16]      PASS  tus=16  beats=524  overlap=15
  [neg_wrong_golden] PASS  uvm_error=4  （负向对照，期望报错）
  [neg_illegal_desc] PASS  uvm_error=1  protocol_errors=1
  [sweep]            PASS  tus=369 beats=45636 overlap=368

status: PASS 7
merged functional coverage: 52/54 = 96.30%
summary: 7/7 PASS，退出码 0
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
| `uvm_info` 层级不乱、逐位顺序正确 | 满足 | 7 个用例逐 beat 比对，40 位全等；`sweep` 共 45636 拍零差异 |
| 多个 TU 并行测试稳定 | 满足 | `sweep` 368 次重叠接纳，`multi_tu_16` 15 次；driver 不在 TU 之间等 done |
| 故意注错时 scoreboard 能报错 | 满足 | 金标准人为翻转 1 bit → 恰好 4 条 `ITS_DATA_MISMATCH`；非法描述符 → `ITS_PROTOCOL_ERROR` |

## 定向细节

- **背压**：`it_data_out_req` 平时按 `%7/%11` 双周期模式拉低，另每 64 拍注入一次
  连续 8 拍深停拍。没有深停拍时 `backpressure` 的 ≥3 bin 和重叠接纳都上不去
- **Sparse TU**：`input_count == 0` 的用例只发独立的 `it_data_end`，不发数据拍
- **done 配对**：scoreboard 要求 `done` 恰好落在最后一个 beat，且全 TU 只出现一次
- **负向对照的必要性**：`neg_wrong_golden` 翻转金标准后仍能"跑完"，若 scoreboard
  是空壳就查不出来；这条用例证明检查器可被证伪
- **覆盖率探针**：`scrub_active` / `fill_active` / `lfnst_busy` / `kernel_busy` /
  `output_active` 由 TB 顶层 `assign` 到接口，不改 RTL；`vsim` 需
  `-voptargs=+acc`，否则这些内部信号被优化掉，vopt 直接报错

## 已知限制

- 数值正确性依赖项目向量集（369 case），UVM 层未独立实现变换模型
- `stall_phase` 的 lfnst / compute 两 bin 受 RTL 结构约束不可达（见上）
- UVM 随机化未启用，sequence 按固定顺序或 stride 取用例
- 单 driver 串行发激励；TU 重叠来自 DUT 流水，不是多 driver 并发
- D5 只回归 UVM 层 7 个用例；D1 的代码覆盖率回归不在此 pipeline 内
- 覆盖率合并是 bin 并集，不做跨运行的代码覆盖率 UCDB 合并