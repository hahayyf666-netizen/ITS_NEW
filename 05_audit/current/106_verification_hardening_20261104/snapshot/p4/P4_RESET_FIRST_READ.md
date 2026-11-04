> 复核修正：本文为原始静态/动态分析记录。控制复位完整性与所有valid配对尚未被证明；原“已关闭”措辞以 P4_EVIDENCE.json 的 review_corrections 为准。===1比较不能单独关闭X风险。

# P4 复位与首次读取安全性审计

基线 `42009da`，RTL `903cd9b2…`。工具：ModelSim SE-64 2020.4、Vivado 2025.2（静态分类脚本 + 动态 TB）。

## 一、静态结果

按 `always_ff` 块统计复位覆盖（`closure_audit/p4/reset_static_audit.py`，含括号深度过滤，排除 `(x <= y)` 形式的比较误报）：

| 文件 | always_ff 块 | 无任何复位的块 | 复位寄存器 | **无复位寄存器** |
|---|---|---|---|---|
| `unified_its_wrapper.sv` | 3 | 1 | 136 | 3 |
| `unified_p4_kernel.sv` | 5 | 2 | 81 | 16 |
| `bounded_lfnst_engine.sv` | 2 | 1 | 42 | 3 |
| `its_input_cache_bank.sv` | 1 | 1 | 0 | 2 |
| `its_simple_ram.sv` | 1 | 1 | 0 | 1 |

259 个控制寄存器在复位分支内，25 个不在。**25 个全部是数据或存储器，没有一个是控制状态**——逐名核对如下。

## 二、四分类

### ① 必须复位的控制状态 —— 已全部复位，无缺口

`slot_state`、`desc_count`、`desc_rd_ptr`/`desc_wr_ptr`、`fill_active`、`fill_slot`、`fill_end_pending_q`、`scrub_active`、`scrub_index`、`end_seen_desc`/`end_seen_slot`、`end_owner_*`、`output_active`、`kernel_run_q`、`lfnst_run_q`、`done`/`protocol_error` 以及 kernel、LFNST 引擎的全部阶段 valid/计数，均在 `if (!rst_n)` 分支内赋值。静态清单中无控制寄存器落入无复位集合。

### ② 读取前必写的数据 —— 有明确写入者，且写入先于读取

| 寄存器 | 位置 | 写入者 | 为何读取一定在后 |
|---|---|---|---|
| `valid_mem` | `its_input_cache_bank.sv:21` | scrub | `scrub_index` 从 0 计到 `INPUT_VALID_WORDS-1`（= `MAX_POINTS/4-1`），每拍对**全部 4 个 bank** 写 `valid=0`（`unified_its_wrapper.sv:1718-1722`）。scrub 期间读被 `scrub_active` 禁止；提前结束路径 `scrub_ended` 也要求 `scrub_index == INPUT_VALID_WORDS-1`（`:559-561`），即**整幅清完才可能提前转 READY** |
| `data_mem` | `its_input_cache_bank.sv:20` | fill | 内容从不清除，但读取与另一路 `valid_mem` 同步输出，由消费侧配对使用 |
| `input_mem` | `unified_p4_kernel.sv:81` | ingress commit | 读取由 `issue_desc_valid_q` 且 `pipe_term_i < issue_desc_active_size_q` 限定（`:629-637`），越界项强制填 0 |
| `desc_mem` | wrapper | 描述符入队 | 读取按 `desc_count` 与队列指针，空队列不读 |
| `mem` | `its_simple_ram.sv:20` | 使用者 | 通用 RAM，写读时序由使用者保证 |

**scrub 覆盖整幅**这一条是 P4 的关键支点：它使 `valid_mem` 的上电任意值不可能在首次读取时被当作有效。

### ③ 由 valid/tag 屏蔽的数据 —— 20 个流水线数据寄存器

`unified_p4_kernel`：`s0_coeff_q`、`s0_input_q`、`mul_a_q`、`mul_b_q`、`mul_m_q`、`product_q`、`reduce_l1_q`~`reduce_l5_q`、`shifted_wide_q`、`pipe_out_data_q`、`ingress_data_q`、`fifo_data_q`
`bounded_lfnst_engine`：`mul_coeff_q`、`mul_term_q`、`products_q`
`unified_its_wrapper`：`kernel_h_rd_raw_data_q`、`primary_return_data_q`

数据与有效位成对搬运：例如 `kernel_rd_raw_data_q` 与 `kernel_rd_bank_valid_q` 同拍捕获（`unified_its_wrapper.sv:2185-2190`），`lfnst_gather_rd_data` 与 `lfnst_gather_rd_valid` 同拍取用（`:1340-1343`）。因此陈旧数据本身不构成输出错误，只会被有效位屏蔽。

### ④ 尚不能证明安全的路径 —— 3 项，未结案

| # | 路径 | 现状 | 结案方式 |
|---|---|---|---|
| ④-1 | `data_mem` 在**硬件**上电时为任意值，且从不被清除 | 仿真中为 X，由 `valid` 屏蔽；硬件中若某地址从未被任何 TU 写入且 `valid` 为 0，则读到的是任意值但被判定无效 | 需满足三选一：证明所有可达读地址的 `valid` 在读取前必为 0（scrub 已提供该证明，需把「scrub 覆盖整幅」写成断言）→ 或加一条定向断言 |
| ④-2 | `fifo_data_q` / `ingress_data_q` 的有效位配对仅在少数路径被动态覆盖 | 动态 X 检查仅覆盖 24 个输出拍 | 补「使能前读」定向检查，或证明该路径在所有可达状态下的有效条件 |
| ④-3 | 仿真的 4 态语义会**代替**设计做屏蔽：`if (valid_mem[..])` 遇 X 取假，恰好等于"视为无效" | 这是 X-乐观/悲观巧合，不能当作设计正确性的证据 | 需用显式比较（`=== 1'b1`）或断言把该假设写死，否则硬件行为与仿真无因果关系 |

**④-1 的注**：`valid_mem` 依据的是 scrub 结构，不是复位；这属于必须写明的设计选择——它使「无复位」成为合法实现，但把正确性绑定在 scrub 的完整性上。一旦将来改动 scrub 范围，这条证明立即失效。

## 三、动态验证

TB：`reset_first_read_tb.sv`（生产顶层 `its_unified_submission_top`，未改 RTL）。

| 用例 | 注入点 | 目标状态实测 | 结果 |
|---|---|---|---|
| R1 | scrub 期复位 | `scrub_active=1` 后复位；两 slot 与队列全清 | PASS |
| R2 | fill 期（已收部分数据）复位 | `fill_active=1` 且部分数据已入 | PASS |
| R3 | LFNST 期复位 | `lfnst_run_q=1` | PASS |
| R4 | 输出被 req 拉低阻塞时复位 | `output_active=1 && !req` | PASS |
| R5 | 队列含描述符时复位 | `desc_count!=0` → 复位后为 0 | PASS |

每个用例复位后立即跑一个已知向量的 TU，逐拍比对 LFNST 输出，全部精确匹配。

**X 检查**：`vld_cycles=24`，`it_data_out` 的 X 违例 **0**，`it_done` 的 X 违例 **0**。

**负向对照**：删除 `desc_count` 的复位赋值（`unified_its_wrapper.sv:1837`），R1–R5 **全部 5 例失败**，`pass=0 fail=5`。证明该 TB 对「控制状态未复位」是敏感的。

## 四、结论

- 控制状态复位覆盖完整，无缺口；动态 5 个相位复位后首个 TU 均正确。
- 存储器无复位是**有意设计**，其正确性依赖 scrub 整幅清零，该依赖已定位到具体行号。
- 仍有 3 条 ④ 类未结案，其中 ④-3（4 态仿真代替设计做屏蔽）是最容易被忽略的一条：它意味着「仿真无 X」不能直接推广为「硬件可信」。
- 本审计未修改任何 RTL。