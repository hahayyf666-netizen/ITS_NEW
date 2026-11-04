# it_data_end 归属与完成契约（补充说明）

**状态：建议采用的工程契约，尚非官方澄清。**

本文件定义 `it_data_end` 的归属、合法发送时刻与完成条件，用于指导 RTL 修复与定向验证。
它不是组委会确认的规范；赛题正文表3 缺少该信号，附件将其定义为"TU块数据输入完成，脉冲信号…时序上要么与 `it_data_in_vld` 同拍生效，要么单独生效"，但未规定其与 `it_data_in_req` 的时序关系，也未定义稀疏输入下如何判定最后一个非零点已发送完毕。本文件补齐的是**我们这一侧的实现约定**，并明确标注哪些部分仍待官方澄清。

---

## 1. 接口事实与由此产生的缺口

| 事实 | 影响 |
|---|---|
| `it_data_end` 为 1 bit，不携带 TU 编号 | 接收方无法区分"上一 TU 迟到的重复脉冲"与"当前 TU 的合法 end" |
| 附件未要求 end 等待 `it_data_in_req` | 接收方不能假定 end 只在 `req=1` 时到达 |
| 正文表3 无 `it_data_end` | 稀疏输入的完成条件在正文中缺失，必须按附件实现并说明 |
| 修复前 RTL仅按 `input_end_fire = it_data_end && it_data_in_req` 消费且不保存提前end | `req=0` 时到达的 end 丢失，DUT 停在 `fill_active=1` 等待新 end |

## 2. 归属规则

**归属对象**：按描述符接收顺序排列的、**最早的、尚未接受 end 的** TU。

候选集合按以下优先级逐个检查，**已接受 end 的对象一律跳过**：

| 序 | 候选 | 生效条件 |
|---|---|---|
| C1 | 活动 slot（`scrub` 或 `fill`） | `scrub_active \|\| fill_active`，且 `!end_seen_slot[active]` |
| C2 | 队列第 1 项 `desc_rd_ptr` | `desc_count >= 1` 且 `!end_seen_desc[desc_rd_ptr]` |
| C3 | 队列第 2 项 `desc_rd_ptr ^ 1` | `desc_count == 2` 且 `!end_seen_desc[desc_rd_ptr ^ 1]` |
| C4 | 无归属 | 以上均不成立 |

规则要点：

1. **队列深度为 2，必须检查两项**。队首已接受 end 时，下一个 end 可能属于第二项。
2. **活动 slot 已接受 end 不等于队列为空**。A 在 scrub 且已收 end、B 在队列时，B 的 end 必须归 B，不能按"重复 end"丢弃。
3. **本拍 `desc_push` 的新描述符不进入本拍候选集**。候选全部取自沿前已接收状态；这与"info 先接收，后续采样沿才允许发送其 end"一致。
4. **候选判定必须使用沿前寄存器值**，不得混入本拍将被更新的量（`desc_rd_ptr`、`desc_count`、`slot_state` 的次态）。

## 3. 合法发送时刻

| 时刻 | 是否合法 | 说明 |
|---|---|---|
| 描述符被接收的同一采样沿 | **不合法** | 首个 TU 与其 end 同拍不纳入用法 |
| 描述符被接收后的任一后续采样沿 | 合法 | 不要求 `it_data_in_req` 为高 |
| 与最后一个数据同拍 | 合法 | 该拍数据必须成功握手 |
| 最后一个数据成功接收之后单独一拍 | 合法 | 独立结束标记 |
| TU 已接受 end 之后再次出现 | 不合法（发送方违约） | 接收方按归属规则跳过，不再接收 |

## 4. 同拍事件与写优先级

可能同拍：`desc_push`、`bind_event`、`it_data_end`。

| 情形 | 动作 |
|---|---|
| end 归属 C2 且本拍 `bind_event` 弹出该项 | 不写描述符位，改为并入转移：`end_seen_slot[bind_slot] <= end_seen_desc[desc_rd_ptr] \| 1` |
| end 归属 C2/C3 且该项本拍未被弹出 | `end_seen_desc[idx] <= 1` |
| end 归属 C1 且该 slot 处于 `scrub` | `end_seen_slot[slot] <= 1`（若同拍消费，则清除优先） |
| end 归属 C1 且该 slot 处于 `fill` | 就地消费，**不写** `end_seen_slot` |
| `desc_push` 到索引 `w` | `end_seen_desc[w] <= 0`（新 TU 不继承旧项状态） |

**转移的 OR 项必须限定为"本拍 end 确实归属于正在弹出的队列项"**，不得使用未限定归属的本拍 end 值。

**`desc_wr_ptr == desc_rd_ptr` 同拍复用**：队列满且同拍绑定时两指针可能指向同一物理项。此时旧 TU 的 end 经转移读出（取沿前值），新项初始化为 0，两者不冲突。

## 5. 状态位所有权

每个状态位只由**一个**时序块驱动，禁止跨块写同一寄存器。

| 位 | 唯一所有者 | 负责的转移 |
|---|---|---|
| `end_seen_desc[0:1]` | 专属 `always_ff` | ① `desc_push` 时按 `desc_wr_ptr` 初始化 0 ② 归属 C2/C3 且未弹出时置 1 |
| `end_seen_slot[0:1]` | 专属 `always_ff` | ① `bind_event` 时从 `end_seen_desc[desc_rd_ptr]` 转移（含同拍 end 的 OR）② scrub 期间归属该 slot 时置 1 ③ scrub 末拍消费时清除 ④ `compute_valid` 接纳计算时清除 ⑤ 复位清除 |
| `slot_state` / `fill_active` / `scrub_active` | 现有主 `always_ff` | 仅读取上述两位的沿前值，用于决定次态，不写入它们 |

**置位/清除优先级**：同一拍内，**清除优先于置位**（消费优先）。实际实现由专属块按索引、事件限定和非阻塞赋值优先级完成；例如新描述符初始化先于归属存储，绑定转移和计算接纳清除有明确门控。不得把此实现描述为每位仅有一条赋值。

## 6. scrub 末拍的统一判定

```text
end_to_scrub   = it_data_end && (owner == C1) && (owner_slot == scrub_slot)
scrub_complete = scrub_active && (scrub_index == INPUT_VALID_WORDS - 1)
scrub_ended    = scrub_complete && (end_seen_slot[scrub_slot] || end_to_scrub)
```

- `scrub_ended` 为真：`slot_state <= SLOT_READY`，**不置** `fill_active`，清除 `end_seen_slot`
- 否则：`slot_state <= SLOT_FILL`，`fill_active <= 1`，`fill_slot <= scrub_slot`

约束：

1. 消费条件必须同时覆盖"此前已收到 end"与"本拍收到归属当前 slot 的 end"两种情况。
2. 晚一拍消费只增加一拍，不重新触发清理（`scrub_active` 仅在 `bind_event` 置位）。要求是**有界时间内消费**，不要求同拍。
3. **不以 `!fill_wr_cmd_valid_q` 作为屏障**。该条件不等价于"写入已提交"，且 `fill_wr_cmd_ready = !valid || commit` 恒为 1，加此条件只会多等一拍。改为在 scrub 完成处加断言：`assert(!fill_wr_cmd_valid_q || fill_wr_cmd_commit)`。

## 7. READY 屏障（保持两种语义）

| 情形 | 屏障 |
|---|---|
| end 与末数据同拍 | `fill_end_pending_q <= 1`，等 `fill_wr_cmd_commit` 后置 READY |
| end 单独一拍（无数据） | 该拍旧写命令同时提交，slot 本拍置 READY |
| scrub 末拍消费 pending end | 同"独立 end"，直接置 READY |

## 8. 协议错误边界

| 情况 | 处理 |
|---|---|
| 候选集为空（无"已接收且尚未结束输入"的 TU）时的 end | 置 `protocol_error`（确定可判） |
| 归属 TU 已接受 end 后再出现 end | 归属规则已跳过该对象；若因此无归属则报错，否则归下一对象。不单独判"重复" |
| 上一 TU 迟到的重复脉冲被下一 TU 接收 | **无法识别**（end 无编号）→ 由发送方契约约束，不做断言 |
| TU 已进入计算/输出阶段的 end | 不据此判非法；此时 owner 可能是 scrub/fill 中的后一 TU 或队列项 |

## 9. 复位

复位清除描述符、归属标志与所有 pending end 状态，复位前的 end 不得影响复位后的 TU。

## 10. 发送方责任（本契约不保证）

- 一 TU 一个 end，按 TU 顺序发送
- 不在"没有已接收 TU"时发送 end
- 不在描述符接收的同一沿发送该 TU 的 end
- 不发送无法归属的迟到重复 end

## 11. 待官方澄清项

1. 稀疏输入下"最后一个非零点已发送"的判定方式（正文缺失，附件以 end 补充）
2. end 是否允许早于 `it_data_in_req`（附件未禁止，本契约按允许处理）
3. `it_data_end` 是否属于强制端口（正文表3 缺失，附件有）

## 12. 验收映射（19 项）

| ID | 场景 | 关键归属点 |
|---|---|---|
| C01 | 等 req 后独立 end（全零 TU） | C1 slot |
| C02 | 末数据后、待写命令提交时独立 end | C1 slot |
| C03 | end 与末数据同拍 | C1 slot |
| C04 | 复位后首个 TU 正常流程 | C1 slot |
| C05 | info 后立即独立 end（scrub 中） | C1 slot（scrub） |
| C06 | 已接收、未绑定的 end | C2 队列首项 |
| C07a | 队列满 + 同拍绑定，新项入队 | 转移 + 初始化 |
| C07b | 队列满 + 无绑定 | C2/C3 |
| C08a | 无后续 TU 时再现 end | C4 无归属 → 报错 |
| C08b | 下一 TU 在 fill 时再现 end | C1 slot |
| C08c | 下一 TU 在 scrub 时再现 end | C1 slot（scrub） |
| C09a | 前 TU 计算中、后 TU 合法结束 | C1 slot |
| C09b | 无待结束 TU 时出现 end | C4 → 报错 |
| C10 | end 恰在 scrub 末拍 | C1 + scrub_ended 同拍 |
| C11a | pending 置位后复位 | 复位清除 |
| C11b | 连续全零 TU，等 req 后发 | C1 slot |
| C11c | 连续全零 TU，提前发 | C1 slot（scrub） |
| C12 | A 在 scrub 且已 end、B 在队列 | **跳过 C1，归 C2** |
| C13 | 队首已 end、第二项未 end | **跳过 C2，归 C3** |

C12/C13 直接验证"跳过已结束对象"，不可由"下一 TU 已进入 scrub/fill"的场景替代。
## 13. TU输出顺序与绑定屏障

输出TU必须保持描述符接受顺序。前TU末数据与end同拍时，在其写命令提交前，年轻TU不得绑定并开启scrub。
绑定条件包含 `!fill_end_pending_q`：pending沿阻止绑定，提交后恢复。该屏障让较老READY TU及时被计算接纳，避免年轻slot0抢先。
S03以B=511和C=0区分TU，S04验证pending时阻止绑定以及满队列复用时恢复绑定；S01/S02覆盖同拍pop/push/end归属。
完整新增验证入口见 [FUNCTIONAL_REPLAY.md](FUNCTIONAL_REPLAY.md)。原19项加S01/S02/S03/S04为每种模式23项。
scrub仍完整执行1024拍；提前end只使scrub完成后直接READY，不跳过清理。
