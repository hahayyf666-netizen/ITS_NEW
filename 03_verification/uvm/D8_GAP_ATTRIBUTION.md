# 代码覆盖率缺口归因（UVM 流程，2026-11-10）

DUT：`unified_its_wrapper`，20 个用例的 UCDB 合并，`vcover report -details -du=unified_its_wrapper`。

这份文档回答一个问题：**85.06% 的语句覆盖率，剩下 148 条为什么不覆盖。**

## 一、总账

| 指标 | 命中/总数 | 覆盖率 | 缺口 |
|---|---|---:|---:|
| Assertions | 27/27 | 100.00% | 0 |
| Statements | 843/991 | 85.06% | 148 |
| Branches | 378/522 | 72.41% | 144 |
| Conditions | 92/136 | 67.64% | 44 |
| Expressions | 95/161 | 59.00% | 66 |
| FSM States | 9/9 | 100.00% | 0 |
| FSM Transitions | 11/26 | 42.30% | 15 |
| Toggles | 2147/5229 | 41.05% | 3082 |

语句缺口 148 条，全部可以归到下面 7 类。

## 二、归因表

| 类别 | 语句 | 分支 | 行号 | 判定依据 |
|---|---:|---:|---|---|
| A. 从未被调用的函数 | 121 | 129 | 841–1085 | `diagonal_count()` 等 6 个函数在本设计中无调用点；扫描全文无引用 |
| B. `case` 的 `default` 臂 | 4 | 4 | 736 / 750 / 764 / 2852 | 合法形状全枚举；非法描述符在更早的 `descriptor_legal` 处就被拦下，到不了这些 `case` |
| C. 防御性 `$fatal` | 4 | 4 | 1464 / 1479 / 1485 / 1489 | 命中即中止仿真；通过回归（PASS 语义）不可能覆盖 |
| D. 内部错误 → protocol_error | 2 | 2 | 2638 / 2640 | 需 `kernel_error` / `lfnst_error` 内部错误位；协议层无法合法构造 |
| E. 零馈送量向量 | 5 | 2 | 2714–2715 / 2782–2784 | 需 `K_V_START`/`K_H_START` 阶段 `kernel_input_vector_done` 已为高，即该向量没有工作要馈送；支持的最小形状 4 点恒有 ≥1 点馈送 |
| F. 内部读流水线 tail 路径 | 11 | 2 | 2279–2283 / 2303–2313 | 只有在 kernel 入口 `in_req` 被**内部 force** 拉低时才可达；D1 就是这么打到的（`force dut.u_unified_p4_kernel.in_req = 1'b0;`）。协议管脚上无法构造，不属于 UVM 协议层应覆盖的范围 |
| G. 队列内 TU 的 end | 1 | 1 | 574 / 573 | 需 TU-B 已入队、且 TU-A 已收到 end，此时 end 才落到队列而非 slot |
| H. 断言前置与包围条件互斥 | 0 | 1 | 1642 | `if (scrub_active)` 位于 fill 写提交的断言块内；scrub 期间不提交 fill 写，两个条件互斥，该断言前置永假 |
| **合计** | **148** | **145** | | |

Conditions 44、Expressions 66、FSM 转移 15 这三类的归因不在上表，单独见第八节。

记账口径说明：`vcover` 摘要报 Branch misses = 144，而明细 CSV 是 145 行（去重键 `(line, item)`，128 个不同行号）。**差 1 行我没有查清原因**，不编造解释；两边都保留原始数字，供后续核对。

A 类是死代码，与验证无关。C 类按定义不可覆盖。B/E/G/H 属"未能证明可达"——不是"证明不可达"，这个区别我保留在表里。F 类已查清：D1 是用内部 `force` 打到的，协议层构造不出来（见第六节）。

## 三、这一轮真正补掉的

归因过程中发现三条**可达但从未被激励**的路径，已补 3 个用例，语句覆盖率 84.46% → 85.06%、分支 71.26% → 72.41%、条件 63.97% → 67.64%、表达式 54.03% → 59.00%。

| 新用例 | 触发的 RTL 机制 | 覆盖的行 |
|---|---|---|
| `neg_zero_data` | end 落在 bind 后的 scrub 窗口内 → `scrub_ended`，TU 按零数据退休，不打开 fill | 577 / 579 / 2474 |
| `neg_end_only_fill` | fill 窗口打开后只发 end、不发数据 → `input_end_fire && !input_fire` | 2515 / 2516 / 分支 1652 |
| `neg_desc_flood` | scrub 窗口期内连续压 4 个描述符 → `desc_count` 到 2，触发"队列满且无 bind" | 2433 / 分支 2432 |

这三条原来一直是暗的，因为所有激励都是"正常节奏"：描述符 → 等 req → 发数据 → 带 end 的最后一拍。没有任何一个用例把 end 放到别的时刻，也没有一个用例在 fill 期间继续压描述符。

## 四、和 D1 定向套件的对比

用 D2 的 `GAPS.csv` 比，必须先分清它的两套口径：

- `global_gap=True`：任何实例都没执行过（真缺口）
- 任意实例级：某些实例漏、某些命中（含实例级差异）

拿"任意实例级"的 954 行去比会得出"UVM 缺口被 D1 完全包含"的假结论——我第一次就是这么错的。

按 `global_gap=True` 重算：

| | D1 全局缺口行 | UVM 缺口行 | 交集 | 仅 D1 缺 | 仅 UVM 缺 |
|---|---:|---:|---:|---:|---:|
| Statements | 143 | 148 | 137 | 6 | **11** |
| Branches | 132 | 128 | 126 | 6 | **2** |

所以：量级相当；**UVM 有 11 行 D1 打到而它没打到，全部在 `kernel_h_rd_raw_tail` 路径**；UVM 也多覆盖了 6 行。各有长短。

这 11 行是这套验证真实剩下的激励缺口——要补就得复现 D1 那套 raw-capture 的触发条件（两个 raw 响应背靠背到达），不是继续堆随机用例。

## 五、为什么零数据 / 裸 end / 描述符洪泛之前没被发现

所有激励都假设了一个"规矩的"主机：描述符 → 等 req → 发数据 → 最后一拍带 end。没有任何用例把 end 放到别的时刻，也没有任何用例在 fill 期间继续压描述符。D1 的定向 TB 也没覆盖这三条，所以这是整个项目的激励盲区，不是 UVM 层的退步。

## 六、还差什么

G 类（574/573）可以继续构造，但需要两个 TU 的时序配合，收益是 1 条语句 + 1 个分支，成本高于收益，先记录不补。

E 类要真正判定为不可达，需要从 RTL 的 `for`/`if` 上给出形式化论证，或者用强制注入（force）打一次——force 属于对 RTL 的攻击性验证，会污染"协议层验证"的边界，需要单独一轮讨论后再做。

### F 类：结论是「协议层构造不出来」，不是「UVM 缺激励」

我先按 RTL 读法做了推理：tail 缓冲（L2302 的 else 分支）只在 `raw_to_queue` 为真、head 仍有未消费字、且本拍不消费时写入；而 `kernel_h_rd_consume` 需要 `kernel_input_group_fire` 且不在 `kernel_h_input_commit_wait_q` 期间。于是推论是"让 kernel 消费端停拍、读请求流水线继续产出，tail 就会填"。

据此写了 `tail_stress`：取数据库里最大用例（32×32、1024 拍输出），在描述符之前就把输出许可拉低 600 拍（`deep_period=1, deep_len=600`），让 kernel 侧面持续被反压。

结果：**L2279–2283、L2303–2313 仍然 0 命中**（单用例 UCDB 核对）。用例本身有效（1024 拍逐位正确、`data_errors=0`），但它碰不到 tail。

然后去查 D1 到底怎么打到的。仓库里有专门的 `03_verification/tb/unified_its_hread_raw_capture_tb.sv`，第 186 行：

```systemverilog
force dut.u_unified_p4_kernel.in_req = 1'b0;
```

它自己的注释写着"forcing the kernel-local ready low isolates a real consumer stall without changing any public ready/valid behavior"。

所以：**这 11 行只有靠内部 force 才能到达**。输出反压不行（已实测），公共管脚上也不行——`in_req` 是 kernel 子模块的输出信号，协议层无法在保持自身 valid/ready 合法的前提下把它单独按低。而 L2246 那条守卫在 `kernel_h_input_commit_wait_q` 期间冻结整个读状态，正好挡住了自然停拍产生的窗口。

结论修正：这不是"UVM 的激励缺口"，是**白盒 force 类用例才能覆盖的点**。要不要补取决于是否允许在 UVM 里放 force 类白盒测试；那是另一个验证层级的问题，不该混进协议层回归。`tail_stress` 保留，因为它在"宽变换 + 长时间输出关断"这个组合上是有效的新激励，只是它的作用不是补这一簇。

## 七、条件、表达式、FSM 转移的缺口归因（新增）

前面的表只覆盖语句和分支。剩下三类一直没归因，这次补齐：

| 指标 | 命中/总数 | 缺口 |
|---|---|---:|
| Conditions | 92/136 | 44 |
| Expressions | 95/161 | 66 |
| FSM Transitions | 11/26 | 15 |

按块能定位到的是 31 个 condition 块和 31 个 expression 块；块内缺项相加（30 / 63）与汇总的 44 / 66 有小差异，原因是同一行的多个 item 在报表里合并计数。**这个差我没有完全对齐**，和分支 144/145 的差属于同一类报表粒度问题，两个口径都保留。

### A. 死代码（12 个 condition 块）

L875–981，全部落在第一节 A 类那六个从未被调用的函数体内。与语句缺口同源，不需要单独解释。

### B. 由不变量证明不可达（13 个 FSM 转移）

不变量：`kernel_run_q == 0 ⟹ kernel_phase_q == K_IDLE`。建立与保持的依据是全部 5 处赋值点：

- 复位 L1848/L1849 同时清两者；
- 另外两处清 `kernel_run_q` 都同时把 phase 置 IDLE（L2589/L2590、L2843/L2844）；
- 唯一把 phase 置成非 IDLE 的两处（L2555/L2556、L2675/L2676）同时在置 `kernel_run_q = 1`。

于是 L2590（LFNST 启动）和 L2676（LFNST 完成）执行时 `kernel_run_q` 必为 0，phase 必为 IDLE：

- L2590 只能产生 IDLE→IDLE（不计转移），**7 条 X→K_IDLE 不可达**：V_START、V_FEED、V_DRAIN、V_WAIT_COMMIT、H_START、H_FEED、H_DRAIN → K_IDLE；
- L2676 只能产生 IDLE→K_V_START（已覆盖），**6 条 X→K_V_START 不可达**：V_FEED、V_WAIT_COMMIT、H_START、H_FEED、H_DRAIN、H_WAIT_COMMIT → K_V_START。

这 13 条与之前"未能证明可达"的那几类不同：这里有证明，不是猜测。

### C. 零馈送臂（2 个 FSM 转移）

L2715 `K_V_START → K_V_DRAIN`、L2784 `K_H_START → K_H_DRAIN`，与语句 E 类（2714–2715 / 2782–2784）同一个根因。

### D. 外部反压传不到内部握手（8 个块，根因 L1354）

`compute_valid` 被 `!output_active && !kernel_run_q && !lfnst_run_q && !scrub_active` 门控，也就是同一时刻只有一个 TU 在计算或输出。后果是内部写/读握手永远不会出现"有效但目标忙"：

- E L811 `fill_wr_cmd_commit=_0`、L812 `fill_wr_cmd_ready=_0`
- E L1180 `rd_cmd_ready=_0`、`primary_issue_ready=_0`、`rd_cmd_candidate_owner=_0`
- E L1513 / L1788 `kernel_out_req=_0`
- C L2365 `lfnst_mem_req_accept=_0`、C L2387、C L2500 `fill_wr_cmd_commit=_0`

20 个用例里有 4 档外部反压，仍然没有让这些内部信号出现反压。外部反压被 `output_active` 这个闸门吸收在计算准入处，传不下去。

其中 L811/L812 比"传不下去"更强，是**恒等式**：

```systemverilog
assign fill_wr_cmd_commit = fill_wr_cmd_valid_q;
assign fill_wr_cmd_ready  = !fill_wr_cmd_valid_q || fill_wr_cmd_commit;   // ≡ 1
```

`ready = !v || v` 恒为 1，所以 `it_data_in_req = fill_active`。任何要求 `fill_wr_cmd_ready=0` 的覆盖项在这份 RTL 上**按构造不可能出现**。同一条恒等式也让 L2477 那条断言（`!fill_wr_cmd_valid_q || fill_wr_cmd_commit`）恒真、永不触发。

### E. 守卫与防御检查恒真（多块，语句有命中但条件项恒定）

这些行的语句命中数很高，说明代码在跑，只是守卫在合法路径上恒成立：

- C L2653 边界检查（语句命中 7488 次）、C L2756 / L2841（V/H `WAIT_COMMIT` 各 421 次）
- C L1409、L1452、L1462、L1478、L1484（LFNST 取数与检查器守卫）
- E L771 / L776（合法描述符路径上 `axis_supported` / `lfnst_shape_supported` 恒真）
- E L1323 `(active_size != 0)=_0`、L1372 `commit_wait=_1`、L1379 `phase==V_START=_1`、L1384 `vector_done=_1`
- E L2404（LFNST 写回坐标恒在界内）

性质与语句里那 4 条防御性 `$fatal` 相同：防御代码在合法激励下不触发。

### F. if/else 与循环上界蕴含（3 个块）

- C L1424 `kernel_stage_q=_0`：该表达式位于 `else if (kernel_in_valid && kernel_stage_q)`，前一个分支已经把 stage=0 的情况拿走了，所以这一项在结构上取不到 0
- C L1260 `(kernel_rd_row_i < kernel_cut_h_q)=_0`：循环上界保证恒成立
- C L1263 `bank_mask=_0`：只遍历掩码置位的 bank

### G. tail 簇（force-only）

C L2257、L2290；E L1312、L1314、L1316。与语句 F 类同源，见上一节。

### H. end 归属与队列满组合（这一类是真缺激励，本轮未构造）

E L535、L539、L549、L554、L556、L559、L583、L802。

证据很直接：`(desc_count == 2)=_1` 从未出现——**整个回归里描述符队列从未同时持有 2 项**。于是所有依赖"队列满 + end 与 bind 同拍"的子项都没走到。

构造方法（已从 RTL 推出，未执行）：先让 slot0 与 slot1 都被占住，再压入第 3、4 个描述符把队列填到 2；然后在"slot 已收到 end 但仍在填充"的窗口里多发一个 `it_data_end`。此时 `end_owner_is_slot` 为 0（该 slot 的 `end_seen_slot` 已是 1），这个 end 会被归给队列里的描述符，走 `end_to_queue_store`，同时打中语句 573/574、分支 573/574 以及上面那批表达式项。

这是目前唯一一类我认为还能靠激励真实提升的缺口，量级是 1 条语句 + 1 个分支 + 8 个表达式块。

但有个我说不清的地方：`neg_desc_flood` 已经连压 4 个描述符且不发 end，按理第 3、4 个会滞留在队列里把 `desc_count` 推到 2，可这个项从未命中。要么推入被更早的合法性检查挡掉了，要么第二个描述符直接绑到了空着的 slot1。**这一点我没有查清**，所以在按上面的方法构造之前，得先弄明白 flood 为什么没把队列填满。

### I. 口径异常（2 个 expression 块）

L616 `axis_supported`、L651 `lfnst_shape_supported`：同一行的语句命中分别 850 次和 207 次，但表达式报表给 0/7 和 0/10，且每一项都标 `'_0' not hit`。函数既然被调用了，`(n == 4)` 这种项不可能只有一侧取值。两者矛盾，我在现有工具链下判不清是内联导致还是报表本身的问题，**因此不计入任何可达/不可达结论**。

## 八、复现

```powershell
python run_regress.py run                       # 20 个用例，产出 20 个 UCDB
python run_regress.py coverage                  # 合并 + -du 报告 + COVERAGE_CODE.json
vcover report -details -du=unified_its_wrapper -output cov_details_dut.txt run/uvm_merged.ucdb
python <gap_analysis.py> cov_details_dut.txt GAPS.json GAPS.csv
```

机器可读的 384 行缺口明细见 `D8_GAPS.csv`（只含语句/分支/条件/表达式四类，FSM 转移不在其中）。