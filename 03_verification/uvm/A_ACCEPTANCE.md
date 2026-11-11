# A 阶段验收：检查器可信化

对应计划：修复方案 v2 的 A0–A5。本文件只记录**已执行并可复现**的内容，
以及执行过程中被改写的方案前提。

---

## 0 结论

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 全量回归 | **22/22 PASS** | `run/regress_A_final.txt`、`run/REGRESSION.json` |
| 分类器自检 | **33/33** | `python run_regress.py selftest` |
| 检查器反例自检 | **15/15** | `run/logs/selftest_*.log`、`python a5_selftest.py` |
| 功能覆盖 | 52/54 = 96.30%（与 A 阶段前一致） | 合并覆盖输出 |
| 输入指纹 | `b7d0f145ad57684f` | `run/RUN_MANIFEST.json` |

覆盖数字没有变化是**预期**的：A 阶段只改判定与检查器，不碰覆盖模型。
分母 54 与 `stall_phase` 的 66.67% 仍需带上 RTL 门控解释（wrapper:1354），
这部分留到 B 阶段。

**审核请从第 7 节开始看**：那里列了工具链限制、四个我自己犯的错误、
一处坏检查差点导致的错误结论，以及两处我认为证据偏弱的判断。

---

## 1 改了什么

| 项 | 落点 | 解决的问题 |
| --- | --- | --- |
| A0 运行身份 | `its_uvm_pkg.sv:1885`、`:1959` | 结果文件写入 `run_id` 与 `case`，两个用例不再共用 testname 而无法区分 |
| A0 错误 ID 计数 | `its_uvm_pkg.sv:125`（`its_report_server`） | UVM 1.1d 只有 `get_id_count(id)`，无 severity 维度；改由 `compose_message` 按 (severity, id) 计数 |
| A0 ID 自洽检查 | `run_regress.py:286` | 按 ID 之和必须等于 severity 总数，不等即 DIRTY |
| A0 指纹 | `run_regress.py:158` | RTL、TB、接口、cases、两个判据脚本、**向量文件**、**ROM/系数初始化文件** |
| A0 严格计数 | `run_regress.py:261` | `-1`、`+1`、`1e3` 不再被当成整数 |
| A0 清单 | `run_regress.py:553` | `RUN_MANIFEST.json` 记录每例 run_id、指纹、日志计数、缺失输入 |
| A1 复位状态机 | `its_uvm_pkg.sv:1305` | 复位未建立 / `rst_n===0` / `rst_n===1` / `rst_n` 为 X 四态分开 |
| A1 独立检查 | `its_uvm_pkg.sv:1323`–`1391` | 见下节可达性表 |
| A2 四态 done | `its_out_item.done` 由 `bit` 改 `logic` | X 不再被折叠成 0 后通过 done 检查 |
| A3 日志规范化 | `run_regress.py:201` | 剥离行首 `# `；排除汇总行、命令回显、源码引用 |
| A3 状态/原因表 | `run_regress.py:286` | 无结果文件时按日志判真实原因，不再一律 `NO_RESULT_FILE` |
| A4 因果契约 | `cases.json` 11 个 `neg_*` | 由 `uvm_error_min:1` 改为「精确 ID + 精确/上下界数量 + 因果说明」 |
| A4 符号期望 | `run_regress.py:271` | 期望可写 `@beats`/`@tus`，把契约绑到计数而不是绑到某条向量的观测值 |
| A5 反例环境 | `its_check_selftest_tb.sv`、`a5_selftest.py` | 无 DUT，直接驱动接口，证明检查器会红 |

---

## 2 一个必须先纠正的方案前提

方案 v2 的 R1 写的是「`req=0` 时出现 `vld=1` 或 `done=1` 即违规」。核对 RTL 后这条**不能原样实现**：

```
unified_its_wrapper.sv:1678   it_data_out_vld = output_active && it_data_out_req;
unified_its_wrapper.sv:1680   output_fire      = output_active && it_data_out_req;
unified_its_wrapper.sv:1682   it_done          = output_last_fire;
```

valid 被 request **组合门控**（源码注释写明这是赛题契约），于是：

- `vld===1 && req===0` 在真 DUT 上**不可达**，原样实现就是又一条恒真检查（与此前 L2477 的问题同类）；
- `done===1` 已经蕴含 `vld===1 && req===1`，所以 `done` 检查同样是构造性保证。

因此实现的是：

| 检查 ID | 条件 | 在现 RTL 上是否可达 | 计入"协议通过" |
| --- | --- | --- | --- |
| `ITS_DONE_NO_FIRE` | `done=1` 且未完成握手 | 否，需 force 或 RTL 回归 | 是（失败即红） |
| `ITS_VLD_STALL` | `vld=1 && req=0` | 否 | **否**，只记 guard 计数并发 info |
| `ITS_SIG_X` | `vld`/`done` 为 X | 是，X 传播是真实风险 | 是 |
| `ITS_DATA_X` | 被接收 beat 的 data 含 X | 是 | 是 |
| `ITS_RST_X` | 有效期内 `rst_n` 为 X | 是 | 是 |
| `ITS_IN_VLD_NO_REQ` | 激励侧在 `req=0` 时拉高 `in_vld` | 是，属激励自检 | 是 |

结论要照实说：**输出侧握手性质在本 RTL 上是被单条 always_comb 构造保证的**，
检查器的真实价值在 X 传播与激励自检，以及在被 force 注入时能立即变红。
A5 证明的正是后者。

---

## 3 三个实测事实（带复现证据）

1. **`uvm_fatal` 会跳过结果文件。**
   `uvm_report_handler.svh:431`：`set_severity_action(UVM_FATAL, UVM_DISPLAY | UVM_EXIT);`
   → `report_phase` 不执行 → `.result` 永不存在。若只按"文件缺失"判定，
   会把一个真正的失败降级成 `NO_RESULT_FILE`。已改为 `UVM_FATAL_EARLY_EXIT`。

2. **原生 `$fatal` 的日志里也有 `$finish`。**
   实测日志：
   ```
   # ** Fatal: AUDIT_NATIVE_FATAL: synthetic
   # ** Note: $finish    : t_native.sv(3)
   ```
   所以 `$finish` 不能作为完成证据；它只被记录，不参与判定。

3. **日志行首有 `# `，且汇总行含 `UVM_FATAL` 字样。**
   第一版扫描器把
   ```
   # UVM_FATAL :    0
   ```
   当成了诊断，导致 `native_error` 场景被判成 `UVM_FATAL_EARLY_EXIT`。
   A5 直接抓出这个缺陷（`selftest_native_error`），现已用
   `UVM_SUMMARY_RE`（`run_regress.py:192`）显式排除。

---

## 4 逐例因果契约

每个负向用例都写明：注入什么 → 应触发哪个检查 → 不许出现什么。
数量口径优先绑计数，无法证明精确时才给上下界。

| 用例 | 注入 | 必须触发 | 口径 | 禁止 |
| --- | --- | --- | --- | --- |
| `neg_wrong_golden` | 期望值整体 XOR 1 | `ITS_DATA_MISMATCH` | 精确 = `@beats` | 任何其它 ID；`done_errors` 非零 |
| `neg_illegal_desc` | width=2 描述符 | `ITS_PROTOCOL_ERROR` | 精确 1（粘滞位只跳变一次） | 任何 beat、任何其它 ID |
| `neg_lfnst_xform` | 非零变换类型的 LFNST | `ITS_PROTOCOL_ERROR` | 精确 1 | 任何 beat、任何其它 ID |
| `neg_lfnst_mode3` | 非法 mode 3 | `ITS_PROTOCOL_ERROR` | 精确 1 | 任何 beat、任何其它 ID |
| `neg_addr_overrun` | 越界地址 beat | `ITS_PROTOCOL_ERROR` + `ITS_DATA_MISMATCH` | 1 + 〔1, `@beats`〕 | 任何其它 ID；`done_errors` 非零 |
| `neg_stray_end` | 无归属 end | `ITS_PROTOCOL_ERROR` | 精确 1 | 任何 beat、任何其它 ID |
| `neg_no_end` | 不发 end | `ITS_INCOMPLETE_TU` | 精确 1，`pending`=1 | 任何 beat、任何其它 ID |
| `neg_short_beats` | 输入截断 | `ITS_DATA_MISMATCH` | 〔1, `@beats`〕 | 任何协议错误、任何其它 ID |
| `neg_zero_data` | 全零输入 | `ITS_DATA_MISMATCH` | 〔1, `@beats`〕 | 任何协议错误、任何其它 ID |
| `neg_desc_flood` | 队列溢出 | `ITS_PROTOCOL_ERROR` + `ITS_INCOMPLETE_TU` | 1 + 1，`pending`≥1 | 任何 beat、任何其它 ID |
| `neg_end_only_fill` | 只有 end 没有数据 | `ITS_DATA_MISMATCH` | 〔1, `@beats`〕 | 任何协议错误、任何其它 ID |

**为什么有三个用例用区间而不是精确值。**
`neg_addr_overrun` / `neg_short_beats` / `neg_zero_data` / `neg_end_only_fill`
的因果结论是「注入后的输入不可能重现 golden，所以至少一拍必须错」。
但哪几拍错取决于填充顺序与 golden 的取值分布，无法从契约推出精确数字，
观测到的 4/4 只是这一条向量的结果。写成精确 4 就是把观测当契约，
换个向量就会假失败。区间上界 `@beats` 绑定的是"错拍数不可能超过产出拍数"。

`neg_wrong_golden` 可以精确：每个期望值都与真实值相差 bit0，必然全部不等。

---

## 5 证据文件

| 文件 | 内容 |
| --- | --- |
| `run/regress_A_final.txt` | 22 例逐例状态 |
| `run/REGRESSION.json` | 状态计数、失败分类、合并覆盖 |
| `run/RUN_MANIFEST.json` | 每例 `run_id`、指纹、日志计数、缺失输入、退出码 |
| `run/logs/regress_<case>.log` | 每例原始日志 |
| `run/logs/selftest_*.log` | A5 六个场景日志 |
| `run/results/<case>.result` | 结构化结果（含 `run_id`、`case`、按 ID 计数） |

复现：

```
python run_its_uvm.py prep
python run_regress.py selftest
python run_regress.py run
python a5_selftest.py
```

---

## 6 A 阶段没做的事（边界）

- **没有放宽也没收紧覆盖分母。** `CG_TOTALS` 仍是 7 组 54 bin；
  `out_rail` / `clip_signed10` 是 B 阶段的事。
- **输出侧握手检查是契约守卫，不是可达检查。** 理由见第 2 节，已写进源码注释，
  避免以后被当成"协议已充分验证"。
- **同一注入事件可能产生两条诊断。** 例如 `done` 在 `req=0` 时拉高会同时产生
  `ITS_VLD_STALL`（info）与 `ITS_DONE_NO_FIRE`（error）；消息里带
  `src=done_no_fire` 标记同源，统计时算一个故障。
- **指纹只覆盖列出的输入。** 仿真器版本、UVM 版本、Vivado 版本没有纳入；
  换工具后的结果不在这份指纹的保证范围内。
- **原生通道与结构化通道各自独立判定。** 结构化计数干净但日志有
  `** Error` 时判 `NATIVE_ERROR`，这是刻意的：RTL 断言失败不会改退出码，
  也不会进 UVM 报告服务器。

---

## 7 遗留清单与自评（供审核）

第 6 节只列了"没做的事"，没有列"做得不好的地方"。实际存在三类问题、
一处坏检查差点导致的错误结论，以及两处弱证据。审核建议从本节开始看。

### 7.1 工具链与 API 限制

| 限制 | 现象 | 处理 | 对结论的影响 |
| --- | --- | --- | --- |
| UVM 1.1d 的 `get_id_count(id)` 没有 severity 维度 | "ID 与 severity 配对统计"无法直接实现 | 继承 `uvm_report_server`，覆写 `compose_message` 自行计数 | 无；但属绕行实现，不是标准接口 |
| `uvm_fatal` 默认 action 是 `UVM_DISPLAY \| UVM_EXIT`（`uvm_report_handler.svh:431`） | `report_phase` 不执行，`.result` 永不产生 | 新增 `UVM_FATAL_EARLY_EXIT` 判定 | 重大：不修则真失败被降级成"结果文件缺失" |
| 新增源文件单独 vlog 时 `uvm_component_utils` 未定义 | 宏不在包内，`import` 不会带入 | 显式 `include "uvm_macros.svh"` 并加 `+incdir` | 无 |
| `uvm_fatal` 宏不能作为 case 分支 | 展开成 begin/end：加分号报 `unexpected ';'`，不加报 `unexpected STRING_LITERAL` | 改用 `uvm_report_fatal(...)` 函数调用 | 无 |
| Notion API 拒绝 callout 图标 U+2691 | 400，且错误体被 GBK 控制台吞掉 | 逐块类型探测定位后去掉自定义图标 | 无（仅影响写文档） |

### 7.2 我自己的错误：四个，不是两个

| 错误 | 现象 | 谁发现 | 性质 |
| --- | --- | --- | --- |
| 日志扫描器把汇总行 `# UVM_FATAL :    0` 当成诊断 | `native_error` 场景被判成 `UVM_FATAL_EARLY_EXIT` | A5 反例自检 | 真 bug：会让每次干净运行都带一条伪错误 |
| 反例 TB 没有 raise objection | UVM 在所有 phase 结束后立即结束，仿真在 time 0 就 `$finish`，场景根本没执行 | A5 反例自检 | 真 bug：最隐蔽的一条，日志看起来是"正常结束" |
| 分类器自检有两个用例的数据写错（`clean()` 未覆盖 `uvm_error`；`no_log()` 的默认值使该行合法变成 `FINISHED_WITHOUT_RESULT`） | 自检 27/29 | 自查 | 测试数据错，不是判定逻辑错；改的是用例不是判定 |
| 新增的 `data_errors==0` 隐含规则与精确 ID 契约冲突 | 4 个负向用例假失败 `DATA_ERRORS_NONZERO` | 全量回归 | 规则冲突：声明了精确 ID 集时不再套用隐含零规则 |

**方法论要点**：两个真 bug 都只有 A5 能抓出来。如果反例自检只断言
"不该出现什么"，这两条永远不会暴露——两种情况下日志看起来都是正常结束。
反例自检必须包含正向断言"必须出现 X"。

### 7.3 过程代价

- 先用带 bug 的扫描器跑完 22 例全过，改完扫描器后又重跑一轮全量，
  多花约一轮回归时间。
- 这轮不算白费：A4 因果契约需要真实错误 ID 才能写，必须先观测。
  但顺序可以更好——先跑单例、看清日志实际格式，再写扫描器，可以省掉这一轮。

### 7.4 一处坏检查差点导致的错误结论

- 查 D0 目录时用 `Get-ChildItem -Include` 配目录路径，得到假阴性，
  据此差点判定"D0 的分析脚本未落盘、删页会丢分析"。重查后发现
  `run_d0c`–`run_d0g` 正是那套乘法器位宽测量。
- 这与 A 阶段"不能用名字相近的间接信号下结论"是同一条纪律：检查本身失效时，
  会给出一个看起来确定的否定结论，比不确定更危险。

### 7.5 两处弱证据（请重点审）

1. **区间口径是我的判断，不是契约推出的唯一答案。** A4 中有四个用例用
   `〔1, @beats〕` 而不是精确值。可质疑点：是否应改为精确值并显式登记
   "依赖哪条向量"；是否应改用更强契约（例如要求每个 beat 的期望值都错）。
   当前写法选择了"换向量不会假失败"，代价是漏检变弱。
2. **反例自检只证明"会红"，不证明"对真 DUT 有效"。**
   `its_check_selftest_tb.sv` 是无 DUT 的接口驱动测试；真 DUT 路径上
   `ITS_SIG_X` / `ITS_DATA_X` 在 22 例全过程中从未触发（计数恒为 0），
   因此 X 类检查的有效性目前仅由合成激励支持。
3. 附带说明：`neg_wrong_golden` 用精确值（每 beat 都错）依据是
   "每个期望值与真实值差 bit0"；该推理成立，但审核方可复核 XOR 是否
   作用于全部 beat，而非仅首拍。

### 7.6 仍未解决 / 未验证

- 覆盖分母 54 与 `stall_phase` 66.67% 的解释（wrapper:1354 门控）留到 B 阶段。
- "601 拍"这一描述已作废（属旧实现观测），B 阶段重基线前不应再被引用。
- X 类检查在真 DUT 上从未触发，有效性仅由合成激励证明（见 7.5 第 2 条）。
- 指纹不含工具版本（ModelSim、UVM 1.1d、Vivado 2025.2），换工具后的结果
  不在这份保证范围内。
- 本文件列出的行号基于提交 `9e5c2b6`；后续提交若改动代码，行号需重核。

### 7.7 建议的复核顺序

1. 先看 `cases.json` 中 11 个 `causality` 与 `uvm_error_ids`：
   契约本身是否成立，是最容易出问题的地方。
2. 再看 `run_regress.py` 中 `classify` 的分支顺序，
   特别是 `RESULT_MISSING` 内部的判定优先级。
3. 复跑 `python run_regress.py selftest` 与 `python a5_selftest.py`，
   确认 33/33 与 15/15。
4. 最后看 `its_uvm_pkg.sv` 中 monitor 的 `run_phase` 复位状态机，
   确认 `warmup` 与 `checks_on` 既不漏检也不多检。

---

## 8 下一步

B 阶段（`v3.10.2-b-grant-cov`）：

1. B1 背压 profile 的段间衔接——当前 `revert_to_default()` 不清 `hold`，
   且"到期即回默认"会在段间插一拍默认配置；改为到期保持 + 序列末尾显式 restore。
2. B4 覆盖点：`out_rail`（每 beat）+ `clip_signed10`（每 `horizontal_result_fire`，
   wrapper:1788），组数 7→8，bin 54→55，X 单独作完整性计数器。
3. 重基线：`tail_stress` 的 601 拍描述作废，所有用例需在新语义下重跑。