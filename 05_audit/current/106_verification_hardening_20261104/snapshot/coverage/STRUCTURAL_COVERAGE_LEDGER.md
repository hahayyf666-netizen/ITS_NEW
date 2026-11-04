# 结构覆盖表（Structural Coverage Ledger）

基线：`42009da`，RTL `903cd9b2…`。本表**从状态机与事件结构导出**，不是抄已有测试名称。

状态定义：`SLOT_FREE=0`、`SLOT_FILL=1`、`SLOT_READY=2`、`SLOT_OUT=3`、`SLOT_SCRUB=4`。

状态：`已命中` = 有定向用例且命中已记录；`待补测` = 结构可达但无定向用例；`未命中` = 有执行路径但语料/配置从未走到；`不可达` = 有代码或约束依据证明不可达；`待解释` = 归属不明。

| ID | 结构项 | 命中条件 | 状态 | 证据 / 缺口说明 |
|---|---|---|---|---|
| A01 | FREE→SCRUB（bind） | `bind_event` 且目标 slot 为 FREE | 已命中 | C01/C04/S01 |
| A02 | SCRUB→FILL（正常路径） | `scrub_index==INPUT_VALID_WORDS-1` 且未提前 end | 已命中 | C01/C02 |
| A03 | SCRUB→READY（提前 end） | `scrub_ended` 为真 | 已命中 | C05/C10 |
| A04 | FILL→READY（末数据同拍 end） | `input_end_fire && input_fire` 后写提交 | 已命中 | C03、S03 |
| A05 | FILL→READY（独立 end） | `input_end_fire && !input_fire`，同拍置 READY | 已命中 | C01 |
| A06 | READY→OUT（计算接纳） | `compute_valid` | 已命中 | 全部数值用例 |
| A07 | OUT→FREE（末拍输出） | `output_last_fire` | 已命中 | C01 等 |
| A08 | 复位：任意态→FREE | `!rst_n` | 已命中 | C11a、protocol reset_inflight |
| A09 | 两 slot 同时 READY | 唯一可达路径为 scrub 末拍旁路 | 已命中 | S03（`blocked=1`） |
| B01 | 队列 0→1 | `desc_push` 且 `desc_count==0` | 已命中 | C01 |
| B02 | 队列 1→2 | 连续两条描述符 | 已命中 | C06/S01 |
| B03 | 队列 2→1（弹出） | `bind_event` 无同拍入队 | 已命中 | C12 |
| B04 | 队列 2→2（同拍 pop+push） | `bind_event && desc_push` | 已命中 | C07a/S01/S02 |
| B05 | 队列满且无 bind → 协议错误 | `it_info_vld && desc_count==2 && !bind_event` | 已命中 | C07b |
| B06 | `desc_rd_ptr` / `desc_wr_ptr` 回绕 | 多次绑定 | 已命中 | C13 |
| C01 | end 在 fill 期原地消费 | `fill_active && !end_seen_slot` | 已命中 | C01 |
| C02 | end 与末数据同拍 | `input_fire && it_data_end` | 已命中 | C03、S03 |
| C03 | end 在 scrub 期被暂存 | `end_to_scrub` | 已命中 | C05 |
| C04 | end 落在 scrub 末拍 | `scrub_ended` 与 `end_to_scrub` 同拍 | 已命中 | C10 |
| C05 | end 属队首未绑定项 | `end_to_queue_store` 于 `desc_rd_ptr` | 已命中 | C06 |
| C06 | end 属队列第二项（队首已结束并被弹出的同拍） | `end_owner_qidx == ~desc_rd_ptr` | 已命中 | C13/S02 |
| C07 | end 随 bind 从队列转移到 slot | `end_seen_slot[bind_slot] <= end_seen_desc[rd] \| end_to_queue_pop` | 已命中 | C12 |
| C08 | 重复 end / 无归属 end | `end_owner_valid==0` → `protocol_error` | 已命中 | C08a/C08b/C08c/C09b |
| D01 | `fill_end_pending_q` 阻止 bind | `!fill_end_pending_q` 进 bind 条件 | 已命中 | S03（`blocked=1`） |
| D02 | 写提交后 bind 恢复 | `fill_wr_cmd_commit` 清 pending | 已命中 | S04（`resumed=1`） |
| D03 | 屏障与满队列同拍入队共存 | pending 期间队列满不误报 | 已命中 | S04 |
| E01 | compute 固定优先 slot0 | 两 slot 同时 READY | 已命中 | S03（负控证明顺序依赖此裁决） |
| E02 | `kernel_run_q` 阻断第二次接纳 | 计算进行中 | 已命中 | 42 仿真隐含 |
| E03 | 输出中途暂停（非末拍） | `it_data_out_req=0` 中途 | 已命中 | P1 S08：1047 个停顿周期，字保持、无丢拍 |
| E04 | 末拍暂停（done 不得提前） | `req=0` 于最后一拍 | **待补测** | 现有 TB 只在首拍前停顿；P1 S08 停在第 1 拍后，未覆盖"末拍" |
| E05 | `it_done` 恰好一次 | 每 TU | 已命中 | 全部用例 done 计数 |
| E06 | LFNST 与主变换同时活动 | `lfnst_run_q` 与 `kernel_run_q` 交叠 | **不可达** | 单一 compute 仲裁（`unified_its_wrapper.sv:1354`）同一时刻只容纳一个属主；P1 四场景 + 既有 42 仿真共 0 周期 |
| E07 | LFNST TU 与普通 TU 交替 | 两方向切换 | 已命中 | P1 S06（LFNST→普通）、S07（普通→LFNST） |
| E08 | 两个 LFNST TU 背靠背排队 | 前 TU 未完成即接收后 TU | 已命中 | P1 S05：`queue_two=1025` 周期，顺序与数据均正确 |
| E09 | LFNST 活动期间接收后 TU 描述符 | 接收事件与 LFNST 阶段重叠 | 已命中 | P1 S06/S08：`desc_while_lfnst=1` |
| F01 | fill 期复位 | `!rst_n` 于 FILL | 已命中 | C11a |
| F02 | scrub 期复位 | `!rst_n` 于 SCRUB | 已命中 | C11a 变体 |
| F03 | 输出期复位 | `!rst_n` 于 OUT | 已命中 | protocol reset_inflight |
| F04 | 队列有描述符时复位 | `desc_count!=0` 且复位 | 已命中 | C11a |
| F05 | 复位后首个 TU | 上电第一条 | 已命中 | C04 |
| G01 | V 阶段 signed16 裁剪生效 | `clip` 命中 | 已命中 | P0-A：1,121/89,348 = 1.25% |
| G02 | H 阶段 signed16 裁剪生效 | `clip` 命中 | **未命中** | P0-A：0/352,896，语料从未触发 H 饱和 |
| G03 | LFNST 阶段 signed16 裁剪生效 | `clip` 命中 | **未命中** | P0-A：0/9,152 |
| G04 | 最终 SAT10 映射生效 | `\|wide\|` 越界 | 已命中 | P0-B：52.35% 点分歧 |
| G05 | 最终 LOW10 映射生效 | `FINAL_SATURATE=0` | 已命中 | P2：双实例锁步，1136 拍全对；两模式在 1118 拍上确实不同，负向对照精确命中这 1118 拍 |

## 不可达项（需依据，不得直接删除）

| ID | 项 | 依据 |
|---|---|---|
| U01 | 单条 `it_data_end` 无法携带 TU 编号，故"迟到的重复 end"与"下一个 TU 的合法 end"不可区分 | 接口定义：1 bit 无编号信号；由发送方契约约束（一 TU 一 end、按序） |
| U02 | 命令队列满导致 `it_data_in_req` 拉低 | `fill_wr_cmd_ready = !valid \| commit ≡ 1`，`req == fill_active`，队列满无法影响 req |

## 已知限制

- 本表是**结构覆盖清单**，不是带分母的覆盖率百分比；语义为"每个应当发生的事件是否确实发生且有记录"。
- G02/G03 的"未命中"说明语料未覆盖该裁剪分支，不能据此断言分支错误，但也不能宣称已验。
- E06–E09 属于同一族（LFNST 与调度重叠），是当前最明确的功能空洞。