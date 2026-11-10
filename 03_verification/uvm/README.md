# D3 最小 UVM 协议层

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

## 验收标准对照（方案第 66–69 块）

| 标准 | 状态 | 依据 |
|---|---|---|
| `uvm_info` 层级不乱、逐位顺序正确 | 满足 | 6 个用例逐 beat 比对，40 位全等；`multi_tu_16` 共 524 拍零差异 |
| 多个 TU 并行测试稳定 | 满足 | `multi_tu_16` 有 15 次「上一个 TU 未排空即接纳新 TU」的重叠接纳；driver 不在 TU 之间等 done |
| 故意注错时 scoreboard 能报错 | 满足 | 金标准人为翻转 1 bit → 恰好 4 条 `ITS_DATA_MISMATCH`；非法描述符 → `ITS_PROTOCOL_ERROR` |

## 定向细节

- **背压**：`it_data_out_req` 按 `%7/%11` 双周期模式周期性拉低，DUT 必须在
  停拍期间保持输出稳定，monitor 持续采样
- **Sparse TU**：`input_count == 0` 的用例只发独立的 `it_data_end`，不发数据拍
- **done 配对**：scoreboard 要求 `done` 恰好落在最后一个 beat，且全 TU 只出现一次
- **负向对照的必要性**：`neg_wrong_golden` 翻转金标准后仍能"跑完"，若 scoreboard
  是空壳就查不出来；这条用例证明检查器可被证伪

## 已知限制

- 数值正确性依赖项目向量集（369 case），UVM 层未独立实现变换模型
- 功能覆盖率（covergroup）未做，属 D4
- UVM 随机化未启用，sequence 按固定 stride 取用例
- 单 driver 串行发激励；TU 重叠来自 DUT 流水，不是多 driver 并发