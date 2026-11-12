# A 阶段验收：检查器可信化

对应计划：修复方案 v2 的 A0–A5。本文件只记录**已执行并可复现**的内容，
以及执行过程中被改写的方案前提。

---

## 0 结论

**状态：修复方自验通过，待独立复核。**

第二轮独立审核发现 6 类缺陷，其中 D1/D2 属于把**已约定的验收条件降级**，
不是新需求。本文件所在提交已把 6 类缺陷全部在 A 阶段内关闭：未进入 B 阶段、
未改 DUT。逐项修前/修后证据见 §9。

第三轮独立复核确认上述修复可复现，但指出 D5 的**异常组合**判定仍有遗留
（空结果文件掩盖 UVM_FATAL 与原生错误、超时可返回 PASS、`reasons` 不是
判定原因的集合）。三处已在 §10 关闭，判定顺序据此重写。

第四轮独立复核确认 §10 可复现，又指出两处：非零退出码会改写已确认的主因，
以及"超时 + 截断产物"仍判 DIRTY（与 §10 的文字相矛盾）。两处已在 §11 关闭，
其中一处是我在 §10 里自己引入的回归。

第五轮独立复核用 224 项组合矩阵验证了 §11 的修复，只剩一处：FIRM 发现（身份
错误）会被排在前面的 TORN 发现（缺字段）遮住，因而没进入判定。该处在 §12
关闭；同时更正 §11.1 里关于"fatal 必带非零退出码"的错误说法——实测真实
`final_phase` fatal 的 `rc=0`。

第六轮复核确认 §12 的四个反例通过，352 项组合矩阵全绿，又指出 FIRM 收集范围
仍不完整：重复键会让全部 FIRM 检查被跳过，动态 `err.error.*` 数值不进严格检查。
两处在 §13 关闭。这一轮把"可读矛盾不会被遮住"的适用条件写清楚了，不再作为
无条件结论。

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 全量回归 | **22/22 PASS** | `run/regress_A2_summary.txt`、`run/REGRESSION.json` |
| 分类器自检 | **71/71**（63 条用例 + 8 条附加检查） | `python run_regress.py selftest` |
| 检查器反例自检 | **9 场景 / 46 断言 / 46 通过** | `run/logs/selftest_*.log`、`python a5_selftest.py` |
| final_phase 真实反例 | **10 断言 / 10 通过**（并记录两次运行的 `returncode`） | `run/A5_FINAL_FATAL.json`、`python a5_final_fatal.py` |
| 分类器修前/修后对照 | 23 个 fixture：**19 个被修正**，4 个原本已正确（含 1 个证明"曾被改坏又改回"），新判定器 0 个错 | §9.1、§10.4、§11.4、§12.3、`run/probe/classifier_before_after.txt` |
| 功能覆盖 | 52/54 = 96.30%（与 A 阶段前一致） | `run/REGRESSION.json` 的 `merged_coverage` |
| 代码覆盖 | 语句 85.16% / 分支 72.60% / 条件 67.64% / 表达式 65.21% / 断言 100% / FSM 状态 100% / FSM 转移 42.30% / 翻转 41.13% | `run/COVERAGE_CODE.json`（在最终回归**之后**生成，与同一轮 ucdb 对应） |
| 输入指纹 | `2fbc8065da68a933`，18 个文件，无缺失，与提交态一致 | `run/RUN_MANIFEST.json` |
| 产物一致性 | 回归收尾复核 22 个结果文件 sha256，`artifact_drift` 为空 | `run/REGRESSION.json` |
| 运行身份 | 22 例 `run_id` 互不相同，且每例结果文件内的 `run_id` 与本次运行一致 | 同上 |

自检计数的账目按真实清单写：第一轮结束时是 32 条用例 + 1 条合并检查 = 33；
第二轮加入 9 条反例与 1 条 `reasons` 检查 = 43；第三轮加入 8 条异常组合用例
与 2 条附加检查 = 53；第四轮加入 7 条退出码/截断用例与 2 条附加检查 = 62；
第五轮加入 4 条 FIRM 遮蔽用例与 1 条附加检查 = 67；第六轮加入 3 条 FIRM 范围用例与 1 条附加检查 = 71。
（此前正文写过"33 + 9 条反例 + 2 条附加"，把原有的合并检查重复计入，
已按实际清单更正。）

本次回归的时间窗与身份以文件为准，不在正文重抄：`run/regress_A2_summary.txt`
第 4 行是 start/end，第 7 行起是逐例 `run_id`。

场景数（9）、断言数（46）、通过数（46）分列记录，不要求断言数与场景数
互不相等：反例自检的价值在于**每条断言都能独立成立**，而不在数字关系。

覆盖数字没有变化是**预期**的：A 阶段只改判定与检查器，不碰覆盖模型。
分母 54 与 `stall_phase` 的 66.67% 仍需带上 RTL 门控解释（wrapper:1354），
这部分留到 B 阶段。

**审核请从第 7 节和第 9 节开始看**：第 7 节列了工具链限制、我自己犯的错误、
一处坏检查差点导致的错误结论；第 9 节是第二轮审核 6 类缺陷的修前/修后证据。

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

第二轮审核后的修复（D1–D6）落点表见 §9.1；本节的 A0–A5 落点行号未变，
`run_regress.py` 因新增分支整体下移，引用时以符号名（`REQUIRED_FIELDS`、
`_classify`、`write_manifest`）为准。

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
| `ITS_VLD_STALL` | `vld=1 && req=0` | 否 | **是**（见下方更正） |
| `ITS_SIG_X` | 控制信号既非 0 也非 1 | 是，X/Z 传播是真实风险 | 是 |
| `ITS_DATA_X` | 被接收 beat 的 data 含 X | 是 | 是 |
| `ITS_RST_X` | 有效期内 `rst_n` 为 X | 是 | 是 |
| `ITS_IN_VLD_NO_REQ` | 激励侧在 `req=0` 时拉高 `in_vld` | 是，属激励自检 | 是 |

结论要照实说：**输出侧握手性质在本 RTL 上是被单条 always_comb 构造保证的**，
检查器的真实价值在 X 传播与激励自检，以及在被 force 注入时能立即变红。
A5 证明的正是后者。

### 2.1 第二轮更正：可达性不是降级依据

上一版把 `ITS_VLD_STALL` 降级成 `uvm_info`，理由是"真 DUT 不可达"。这是**拿
可达性去改验收条件**：方案 R1 明确要求该状态判 FAIL 并计入 PROTOCOL_SIG 计数，
可达性只说明它不会被合法激励触发，不说明它可以不报错。而且这条已约定的验收
条件被我单方面改掉、改完才写进文档——即使标注了，也应该先问。

现改为 `uvm_error("ITS_VLD_STALL")`，`vld_stall_guard` 计数保留，用于交叉
检查"计数路径"与"诊断路径"是否一致（两者不一致本身就是 DIRTY 级的证据）。
可达性说明只留在代码注释里，不再作为免检理由。

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
| `run/regress_A2_summary.txt` | 22 例逐例状态、`run_id`、产物 sha256 前 8 位、覆盖 |
| `run/REGRESSION.json` | 状态计数、失败分类、`artifact_drift`、合并覆盖 |
| `run/RUN_MANIFEST.json` | 启动/结束记录、每例 `run_id`、完整命令行、日志计数、缺失输入、退出码 |
| `run/COVERAGE_CODE.json` | DUT 代码覆盖率 |
| `run/A5_FINAL_FATAL.json` | final_phase 反例两次运行的判定与产物 sha256 |
| `run/probe/classifier_before_after.txt` | 23 个反例的修前/修后判定 |
| `run/probe/a5_final_fatal_*.result` | 反例的产物（不占用 `run/results/`） |
| `run/logs/regress_<case>.log` | 每例原始日志 |
| `run/logs/selftest_*.log` | A5 九个场景日志 |
| `run/results/<case>.result` | 结构化结果（含 `run_id`、`case`、按 ID 计数、四个检查计数、两个汇总总数） |

复现（顺序有意义：回归要在自检之后跑，`run/results/` 的最终状态才由回归本身产生）：

```
python run_its_uvm.py prep
python run_regress.py selftest      # 71/71
python a5_selftest.py               # 9 场景 / 46 断言
python a5_final_fatal.py            # 10 断言
python probe_classifier_history.py  # 修前/修后对照
python run_regress.py all           # 22/22 + 产物 sha256 复核
python run_regress.py coverage
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
   `ITS_SIG_X` / `ITS_DATA_X` 在 22 例全过程中从未触发（第二轮修复后
   `sig/x/in/guard` 四个计数仍全为 0），因此 X 类检查的有效性目前仅由合成
   激励支持。这一条在第二轮修复后**仍然成立**，是 A 阶段剩下的主要弱点。
3. 附带说明：`neg_wrong_golden` 用精确值（每 beat 都错）依据是
   "每个期望值与真实值差 bit0"；该推理成立，但审核方可复核 XOR 是否
   作用于全部 beat，而非仅首拍。

### 7.6 仍未解决 / 未验证

- 覆盖分母 54 与 `stall_phase` 66.67% 的解释（wrapper:1354 门控）留到 B 阶段。
- "601 拍"这一描述已作废（属旧实现观测），B 阶段重基线前不应再被引用。
- X 类检查在真 DUT 上从未触发，有效性仅由合成激励证明（见 7.5 第 2 条）。
- 指纹不含工具版本（ModelSim、UVM 1.1d、Vivado 2025.2），换工具后的结果
  不在这份保证范围内。
- 本文件列出的行号基于本文件所在提交；后续提交若改动代码，行号需重核。
  第二轮修复后 `run_regress.py` 整体下移，引用请优先用符号名。
- **A 阶段尚未被独立复核关闭。** 在复核方确认前，不进入 B 阶段。
- 零计数的适用范围已收窄（见 §9.5）：只覆盖检查已开启且实际采样到的窗口。

### 7.7 建议的复核顺序

1. 先看 `cases.json` 中 11 个 `causality` 与 `uvm_error_ids`：
   契约本身是否成立，是最容易出问题的地方。
2. 再看 `run_regress.py` 中 `_classify` 的分支顺序（§10.2 是当前生效的版本），
   特别是"诊断事实先于产物形态、身份先于计数、超时先于形态"这三条。
3. 复跑三个自检：`python run_regress.py selftest`（71/71）、
   `python a5_selftest.py`（9 场景 46/46）、`python a5_final_fatal.py`（10/10）。
4. 看 `its_uvm_pkg.sv` 中 monitor 的 `run_phase` 复位状态机与
   `not_two_state()`，确认 `warmup` 与 `checks_on` 既不漏检也不多检。
5. 最后看 `run_regress.py` 的 `FINGERPRINT_FILES`：它从编译清单派生，
   新增 RTL 时不需要再手工登记。

---

## 8 下一步

**出口条件**：本阶段的收尾顺序是——反例按预期失败、正常对照通过、全量回归
完成、身份与指纹检查通过，才标记"修复方自验通过，待独立复核"；独立复核完成
后才关闭验收项。以上四项均已完成（见 §0），因此当前状态停在"待独立复核"，
**不进入 B 阶段**。

B 阶段（`v3.10.2-b-grant-cov`）：

1. B1 背压 profile 的段间衔接——当前 `revert_to_default()` 不清 `hold`，
   且"到期即回默认"会在段间插一拍默认配置；改为到期保持 + 序列末尾显式 restore。
2. B4 覆盖点：`out_rail`（每 beat）+ `clip_signed10`（每 `horizontal_result_fire`，
   wrapper:1788），组数 7→8，bin 54→55，X 单独作完整性计数器。
3. 重基线：`tail_stress` 的 601 拍描述作废，所有用例需在新语义下重跑。

---

## 9 第二轮独立审核：6 类缺陷的修复与证据

审核方独立复跑后指出 6 类缺陷。全部在本阶段内关闭，未改 DUT，未进入 B。
D1/D2 属于**把已约定的验收条件降级**，不是新需求；其余为判定路径与记录缺口。
先写反例、确认它在修前不被拦，再修、确认它被具体原因拒绝——每一步的顺序都是
"先红后绿"，因为上一轮的两个真 bug 都是反例抓出来的，不是回归暴露的。

### 9.1 逐项修前 / 修后

下表由 `probe_classifier_history.py` 生成：它把提交 `9e5c2b6` 的判定器从 git
取出、与当前判定器加载进同一进程，喂同一批 fixture，结果写在
`run/probe/classifier_before_after.txt`。复核方可用同一条命令复跑。

| 缺陷 | 反例 fixture | 修前判定 | 修后判定 |
| --- | --- | --- | --- |
| D1 vld-only 从 FAIL 降级为 INFO | `vld_stall_guard=1` 但无 error 记录 | PASS | FAIL / `VLD_STALL_GUARD_NONZERO` |
| D2 四态只查 X、漏 Z，且不看 req | 真实仿真 `done=Z` / `req=X` | 无任何诊断（审计日志 `ITS_SIG_X` 0 次） | FAIL / `ITS_SIG_X` |
| D3 run_id 写入但从不校验 | 结果文件 `run_id=stale-run` | PASS | DIRTY / `RUN_ID_MISMATCH` |
| D4 错误 ID 值解析失败被静默丢弃 | `err.error.BOGUS=garbage` | PASS | DIRTY / `FIELD_FORMAT` |
| D4 汇总字段可选 | 缺 `err_server_total_error` | PASS | DIRTY / `MISSING_FIELD` |
| D4 fatal 侧 ID 从不做自洽校验 | `err.fatal.X=1`、总数 1、fatal 0 | PASS | DIRTY / `FATAL_ID_COUNT_MISMATCH` |
| D5 有结果文件时不看日志 fatal | 文件完整 + 日志 1 条 UVM_FATAL | PASS | FAIL / `UVM_FATAL_IN_LOG` |
| D5 空文件先返回，吞掉已发生的 fatal | `RESULT_EMPTY` + native fatal | INCOMPLETE | FAIL / `NATIVE_FATAL` |
| D5 超时优先，吞掉已发生的原生错误 | `RESULT_MISSING` + native error + 超时 | INCOMPLETE / TIMEOUT | FAIL / `NATIVE_ERROR`（`reasons` 保留 TIMEOUT） |
| D6 指纹漏 3 个实际编译的 RTL | 改这 3 个文件，指纹不变 | 指纹 15 个文件 | 18 个文件，源自编译清单 |

分类器自检从 33/33 变为 **43/43**（第三轮后为 53/53，第四轮后为 62/62，第五轮后为 67/67，第六轮后为 71/71，见 §10.5、§11.5、§12.5、§13.5）；新增 9 条反例行中，8 条在修前被判 PASS。

### 9.2 判定顺序（D5）

> 本节记的是第二轮修完后的顺序，**已被 §10.2、§11.3 取代**：第三轮复核指出它把
> 产物形态排在诊断之前，导致空文件仍会掩盖 UVM_FATAL 与原生错误，且超时
> 排在形态判定之前会把"超时 + 缺文件"判成 DIRTY；第四轮又指出超时不区分
> "截断类"与"独立类"发现。当前生效的判定顺序见 §11.3。

修前：`RESULT_MISSING` 内部先看超时；有结果文件时完全不看日志里的 fatal。
修后：fatal 与原生错误**无条件先判**，超时不再具有豁免力。

1. native fatal → FAIL / `NATIVE_FATAL`
2. 超时 + 原生错误 → FAIL / `NATIVE_ERROR`（`reasons` 同时保留 `TIMEOUT`）
3. 有结果文件 + 日志 UVM_FATAL → FAIL / `UVM_FATAL_IN_LOG`
4. 无结果文件时：`UVM_FATAL_EARLY_EXIT` → `NATIVE_ERROR` → 超时 → DIRTY → INCOMPLETE

`reason` 是单值主因，既有调用方（自检、汇总表、`REGRESSION.json`）不受影响。
原生错误"可能来自半途状态"不构成忽略它的理由：若某类错误在中断流程中允许
发生，需要在契约里写明限定条件，而不是由判定器代为豁免。

### 9.3 final_phase fatal：真实仿真反例（D5）

唯一"结果文件干净但运行失败"的路径：`report_phase` 先写并 `$fclose` 结果文件
（`its_uvm_pkg.sv:1953`、`:2026`），`final_phase` 之后才跑。
`a5_final_fatal.py` 用**真实 TB** 跑同一用例两次：

| 运行 | 结果文件 | 日志 fatal | 判定 |
| --- | --- | --- | --- |
| 控制（无注入） | 完整，全部必填字段齐 | 0 | PASS |
| 探针（`+FATAL_IN_FINAL=1`） | 完整，且 `uvm_error=0 uvm_fatal=0` | 1 | FAIL / `UVM_FATAL_IN_LOG` |

字段完整性用 `run_regress.REQUIRED_FIELDS` 判定，不硬编码条数——新增字段后
探针自动跟着变。两次运行的结果文件分别写在 `run/probe/a5_final_fatal_control.result`
与 `run/probe/a5_final_fatal_fatal.result`，**不占用该用例在 `run/results/` 下的
正式产物**；证据汇总在 `run/A5_FINAL_FATAL.json`（含两次结果文件的 sha256）。

### 9.4 四态与控制信号的逐信号覆盖（D2 的准确表述）

修前 `run_phase` 只查 `it_data_out_vld === 1'bx` 与 `it_done === 1'bx`。

| 信号 | 方向 | 修前 | 修后 |
| --- | --- | --- | --- |
| `it_data_out_vld` | DUT 出 | 只查 X，漏 Z | 既非 0 也非 1 → `ITS_SIG_X` |
| `it_done` | DUT 出 | 只查 X，漏 Z | 同上 |
| `it_data_out_req` | 握手入 | 完全不查 | 同上 |
| `protocol_error` | DUT 出 | 完全不查 | 同上 |
| `it_data_in_vld` | 激励 | 只查 `vld&&!req` 组合 | 同上（新增两态） |
| `it_data_in_req` | 激励 | 只查组合 | 同上（新增两态） |
| `it_data_out[39:0]` | DUT 出 | 只在被接受的那一拍查 X | 不变（`ITS_DATA_X`） |
| `rst_n` | 激励 | 三态分开 | 不变（`ITS_RST_X`） |

A5 新增 `done_z`、`req_x` 两个场景，各 2 拍，均报 2 次 `ITS_SIG_X`；
`vld_only` 场景只报 `ITS_VLD_STALL`、不报 `ITS_DONE_NO_FIRE`，
证明三条检查互不搭靠，不是靠别的诊断顺带触发。

### 9.5 零计数的适用范围（收窄后的表述）

零计数只能说明**检查已开启、且实际采样到**的窗口里没发生该事件，不包括：

- 初始化期与复位屏蔽期（`checks_on=0`，含复位后的 3 拍 warmup）；
- 未采样的信号（例如 `it_data_out` 只在被接受的那一拍检查，空闲拍不查）；
- 本阶段没有规则的属性（数值正确性只由 scoreboard 覆盖）。

因此正确表述是：**这些数字可复现，说明当前用例在现有检查规则下全部通过；
新增反例证明规则仍有漏检面，所以不能据此排除未被检查到的异常。**
既没有"因为检查器有洞，所以之前的通过都是假的"这样的证据；也不能从
"检查器没报错"反推"漏检条件没有发生"。

### 9.6 输入指纹与运行记录（D6）

- 指纹改为**从编译清单派生**（`run_its_uvm.RTL` + `SRC`），不再手抄。手抄版
  漏了 `its_simple_ram.sv`、`its_input_cache_bank.sv`、`bounded_lfnst_engine.sv`
  三个实际参与编译的 RTL，改它们不会改变指纹。现为 18 个文件，无缺失。
- `RUN_MANIFEST.json` 改为**启动即写、结束重写**：`record` / `start` / `end` /
  `planned_cases` / `runs_completed`。原实现只在结束时写一次，进程中途崩掉就
  什么都不留，与它自己"start/end record"的说明不符。
- 每例额外记录完整 `command`、结果文件 `bytes` 与 `sha256`、`run_id`、`reasons`。
- 回归收尾时逐个复核结果文件的 sha256（`REGRESSION.json` 的 `artifact_drift`），
  本次 22/22 与记录一致；探针产物写到 `run/probe/` 且自带名字，不替换正式证据。

### 9.7 我在这一轮犯的错

- **把可达性当成了降级依据。** D1 的检查我判断"真 DUT 不可达"，就把它的
  严重度从 FAIL 降成 INFO 并写进文档。方案 R1 明确要求该状态判 FAIL 并计入
  PROTOCOL_SIG。即使标注了，改已约定的验收条件也应该先问，而不是改完再记录。
- **只 grep 了计数名就下全局结论。** 我曾判断"改成 error 也没人拦"，实际
  `cases.json` 的 `defaults.expect` 已让全部干净用例继承 `uvm_error: 0`，
  11 个 `neg_*` 又走精确 ID 集，两条路都会拦住。这与 §7.4 记的是同一个毛病：
  用一个局部检查的结果去下全局结论。
- **自检 fixture 本身不自洽。** 加上严格 ID 自洽校验后，3 条旧 fixture
  （物理上不可能出现的记录：severity 总数与 ID 之和不符）必须先修正数据，
  否则会把新校验误判成 bug。改的是 fixture，不是判定逻辑。
- **把"断言数等于场景数"当成问题。** 真正的缺口是没有分列统计场景数、
  断言数、通过数，不是两个数字恰好相等；刻意让它们不等是形式主义。
- **探针覆写了回归的证据。** `a5_final_fatal.py` 第一版复用 `single_tu` 的
  产物名，跑完探针后 `run/results/single_tu.result` 与对应日志已被替换，
  manifest 里记的 sha256 指向的内容在磁盘上不存在了——证据集自相矛盾。
  现改为探针自带名字、写进 `run/probe/`，且全量回归在自检之后跑，
  保证 `run/results/` 的最终状态由回归本身产生。
  这类问题正是这一轮反复强调的：**记录对不对，要看它描述的文件还在不在。**

---

## 10 第三轮复核：D5 异常组合的修正

第三轮独立复核确认 §9 的修复可复现，同时指出三处判定口径问题。三处都不是
"再加一个分支"能解决的，根因是**判定顺序把产物形态放在了诊断事实之前**。

### 10.1 三处问题与根因

| 问题 | 现象（复核方实测） | 根因 | 现在 |
| --- | --- | --- | --- |
| 空结果文件掩盖两类错误 | `RESULT_EMPTY`＋日志 UVM_FATAL → `INCOMPLETE/EMPTY_RESULT_FILE`；`RESULT_EMPTY`＋原生 error → 同上 | UVM_FATAL 检查被 `parse_error not in (MISSING, EMPTY)` 挡住（本意是让 MISSING 走自己的分支，却没给 EMPTY 等价分支）；原生 error 只在超时时提前处理，通用预算检查在 EMPTY 返回之后 | 两条都先于形态判定，见 §10.2 |
| 超时仍可返回 PASS | 干净完整文件＋`timed_out=True` → `PASS`，`reasons=['TIMEOUT']` | 超时只在外层补一条原因，规则本身没有"超时不得判 PASS"；且外层覆盖式改写 `reasons` 会丢掉 TIMEOUT | 超时在形态判定之前，单独出现即 `INCOMPLETE/TIMEOUT` |
| `reasons` 不是完整列表 | 四类诊断同时存在 → `[NATIVE_FATAL, TIMEOUT]` | 实现是"主因 + 可选 TIMEOUT"，docstring 写的却是"complete list, nothing dropped" | 改为**判定原因集合**，四条都在；`log`/`fields` 才是诊断计数全集 |

超时来源同时改掉：原用 `elapsed >= timeout_s - 1` 推断，会把刚好在限内跑完的
运行判成超时，也会漏掉别处发来的终止。执行器 `run_its_uvm.run()` 在
`TimeoutExpired` 分支里写 `*** TIMEOUT after Ns` 并返回 `rc=-9`，判定器只认
这条**专用标记**；`rc=-9` 本身不作为超时证据，因为其他异常终止也报同样的码。

### 10.2 事实集合与判定顺序（第三轮）

> **已被 §11.3 取代。** 本节第 2 步把"字段缺失/格式错"一类与"身份不符"混在
> 一起，第 4 步又把超时排在全部产物检查之后——第四轮复核据此构造出"超时 +
> 截断文件"，仍被判 DIRTY，与本节自己的说明相矛盾。当前生效的版本见 §11.3。

判定器先收事实，再由事实定档位，不按文件状态分叉。

| 事实 | 来源 | 性质 |
| --- | --- | --- |
| F1 native fatal | 日志 `** Fatal` | 诊断，独立否决 PASS |
| F2 native error/assert 超出用例允许值 | 日志 | 同上 |
| F3 UVM_FATAL 行 | 日志 | 同上 |
| F4 非超时的非零退出 | 执行器 `rc` | 同上（档位为 DIRTY） |
| F5 超时 | 日志 `*** TIMEOUT` 标记 | 同上 |
| F6 无结果文件 / F7 空结果文件 | 解析 | 形态 |
| F8 结构错误 / F9 身份或格式不符 | 解析 | 可信度 |
| F10 计数与期望不符 | 字段 | 判定（**仅当 F8/F9 全部通过时成立**） |

顺序：

1. **F1 → FAIL/`NATIVE_FATAL`**；F3 → FAIL/`UVM_FATAL_EARLY_EXIT`（无文件时）
   或 `UVM_FATAL_IN_LOG`；F2 → FAIL/`NATIVE_ERROR`。三条都只看日志，与产物无关。
2. **可信门**：字段缺失/类型错/身份不符/ID 总和不自洽 → DIRTY。到此为止，
   这份记录里的任何计数都不采信。
3. **F10 计数比较**——只有过了可信门才执行，所以"错 `run_id` ＋ 计数不符"
   得到 DIRTY 而不是 FAIL：另一轮运行的计数不构成本轮的判定依据。
4. **F4 退出码**：有干净完整产物 → DIRTY/`NONZERO_EXIT_WITH_CLEAN_RESULT`；
   无可用产物 → FAIL/`SIMULATOR_ERROR`（不把不存在的文件称作"干净结果"）。
5. **F5 超时 → INCOMPLETE/`TIMEOUT`**，在形态判定**之前**：超时期间缺文件、
   空文件、截断文件都是超时的次生现象，不能单凭它们升级成 DIRTY。
6. F6/F7 → 形态判定：无文件且摘要干净且有 `$finish` → DIRTY/`FINISHED_WITHOUT_RESULT`，
   否则 INCOMPLETE/`NO_RESULT_FILE`；空文件 → INCOMPLETE/`EMPTY_RESULT_FILE`。
7. 都不成立 → PASS。

### 10.3 `reasons` 的语义

`reasons` = **判定原因集合**：本次判定中所有成立、且能独立支撑非 PASS 的事实
（F1–F5 按固定顺序去重），加上决定档位的那条形态原因。四诊断叠加得到
`[NATIVE_FATAL, UVM_FATAL_EARLY_EXIT, NATIVE_ERROR, TIMEOUT]`，四条都在。

它**不是**诊断计数全集：完整的 `native_error` / `uvm_error_lines` 等计数在
`log` 与 `fields` 里，负向用例"预期内"的 UVM_ERROR 不进 `reasons`（那不是判定原因）。
之所以不另开一个 diagnostics 集合：两套字段各自演化，正是这次"文档说完整列表、
实现只有两条"的成因。

### 10.4 新增反例的修前/修后

`probe_classifier_history.py` 把 16 个 fixture 同时喂给历史判定器（`9e5c2b6`，
含当时 `run_one` 里的退出码补丁）与当前判定器：

| 组合 | 修前 | 修后 |
| --- | --- | --- |
| `RESULT_EMPTY` + 日志 UVM_FATAL | INCOMPLETE/`EMPTY_RESULT_FILE` | FAIL/`UVM_FATAL_IN_LOG` |
| `RESULT_EMPTY` + 原生 error（未超时） | INCOMPLETE/`EMPTY_RESULT_FILE` | FAIL/`NATIVE_ERROR` |
| 完整干净文件 + 超时 | PASS | INCOMPLETE/`TIMEOUT` |
| 无文件 + 干净摘要 + `$finish` + 超时 | INCOMPLETE/`TIMEOUT` | INCOMPLETE/`TIMEOUT`（守卫） |
| 四诊断叠加 | INCOMPLETE/`TIMEOUT` | FAIL/`NATIVE_FATAL`，`reasons` 四条 |
| 错 `run_id` + 计数不符 | FAIL/`BEATS_MISMATCH` | DIRTY/`RUN_ID_MISMATCH` |
| 非超时异常退出 + 无文件 | FAIL/`SIMULATOR_ERROR` | FAIL/`SIMULATOR_ERROR`（守卫） |
| 非超时异常退出 + 干净结果 | DIRTY/`NONZERO_EXIT_WITH_CLEAN_RESULT` | 同（守卫） |

16 个 fixture 中 13 个被本次修正改变，3 个原本已正确并留作回归守卫；
新判定器 0 个错。后三行是复核方要求补的组合，其中两行证明的是"没有被改坏"，
不宣称新发现。

### 10.5 自检账目

49 条用例 + 4 条附加检查（合并、双原因、四诊断 `reasons`、超时单独判定）
= **53/53**（第四轮加入 7 条用例与 2 条附加检查后为 62/62，见 §11.5）。
第一轮结束时是 32 + 1 = 33，第二轮 33 + 10 = 43，
第三轮 43 + 10 = 53。此前正文写的"33 + 9 条反例 + 2 条附加"把原有的合并检查
重复计入，已按实际清单更正为现在的写法。

### 10.6 代码覆盖的产物来源（自查）

`run/COVERAGE_CODE.json` 之前是上一轮 ucdb 的产物（09:19:44），而 `run/ucdb/`
已被最终回归覆盖，把这个文件列为本轮代码覆盖的证据并不成立。现在 coverage
阶段排在回归之后执行，`COVERAGE_CODE.json`（10:12:58）与 22 个 ucdb
（10:11:47–10:12:58）同轮，八项数字未变。

### 10.7 我在这一轮犯的错

- **只测了刚改的那条路径。** 空文件相关的反例我只加了"空文件 + native fatal"，
  正好是当次修好的那条；相邻的 UVM_FATAL 与原生 error 两条没测，于是同一个
  分支里的另外两个洞留到了第三轮。这与"只 grep 计数名就下全局结论"是同一类
  错误，只是发生在测试覆盖而不是代码阅读上。
- **把 `reasons` 说成完整列表。** docstring 写 "complete list … nothing
  observed is dropped"，实现只有"主因 + TIMEOUT"。能力声明超过实现，第三次
  出现同类问题，这次改成按实现写。
- **手抄了上一轮的时间与 `run_id`。** 交付文字里的 start 09:26:09 与
  `092609-19988-001` 属于更早一轮；实际是 09:28:23 / `092823-25528-001`。
  原因是先读了旧 summary，随后用新 manifest 重生成文件，写文字时引用了读到的旧值。
- **自检账目算错。** "33 + 9 + 2 = 44" 与 43 对不上，因为 33 里已经含合并检查。

---

## 11 第四轮复核：退出码与截断产物的判定

第四轮独立复核确认 §10 可复现，仍发现两处分类问题——**没有发现新的误判 PASS
路径**，所以 Monitor、身份校验、覆盖流程都不动。

### 11.1 两处问题与根因

| 问题 | 实测（我复现，与复核方一致） | 根因 |
| --- | --- | --- |
| 非零退出码改写已确认的主因 | 无文件＋原生 fatal＋`rc=1` → `SIMULATOR_ERROR`；无文件＋UVM_FATAL＋`rc=1` → `SIMULATOR_ERROR`；空文件＋原生 error＋`rc=1` → `SIMULATOR_ERROR` | `_with_exit()` 的条件写的是"`parse_error` 非空就改写"，而不是"只有在没有更明确诊断时才用它" |
| 退出码没进 `reasons` | 错 `run_id`＋`rc=1` → `DIRTY/RUN_ID_MISMATCH`，`reasons` 只有一条 | `_verdict_reasons()` 不接收退出码，§10.3 声称 F4 属于判定原因集合，实现没做到 |
| 超时＋截断产物仍判 DIRTY | 截断文件（`tus=` 后即止）＋超时 → `DIRTY/MISSING_FIELD:beats`；结构错误＋超时 → `DIRTY` | 字段检查与结构错误分支都在超时判断之前，§10 声称"超时期间的截断只作为不完整证据"，实现没做到 |

### 11.2 改法

- **退出码不再改写主因**：只有 `INCOMPLETE` 会被提升为 `FAIL/SIMULATOR_ERROR`
  （确实什么都没跑出来）；`FAIL` 与 `DIRTY` 保留它们各自更具体的原因；
  `PASS` 才是 `DIRTY/NONZERO_EXIT_WITH_CLEAN_RESULT`。
- **退出码进入 `reasons`**：当它没有成为主因时追加一条 `NONZERO_EXIT`；
  若主因本身就是 `SIMULATOR_ERROR` 或 `NONZERO_EXIT_WITH_CLEAN_RESULT`，
  不再重复追加（同一个事实不给两个标签）。
- **产物检查分两类**，见 `TORN_FINDINGS` / `FIRM_FINDINGS`：
  - *可能由写中断造成*：缺字段、空值（`FIELD_FORMAT:…=''`）、结构错误、
    ID 总和不符。这些在**只有超时**成立时降为 `INCOMPLETE/TIMEOUT`，
    原因仍写进 `reasons`。
  - *写中断不可能造成*：身份三元组指向另一轮（`RUN_ID_/CASE_/TEST_MISMATCH`）、
    完整但非数值的字段。这些即使有超时也保留原判定——文件必须可读才能说出
    这句话，说明它不是被截断出来的。
- 不做"把超时放到所有检查之前"那种改法：那会把已确认的身份错误也吞掉。

### 11.3 判定顺序（当前生效）

| # | 步骤 | 说明 |
| --- | --- | --- |
| 1 | 日志诊断 | native fatal / UVM_FATAL / 超预算原生错误 → FAIL，与产物无关 |
| 2 | 产物可信门 | 字段存在性与类型、身份、ID 总和；同时标记该发现属于"截断可解释"还是"独立可确认" |
| 3 | 超时对截断类发现的抑制 | 有超时且发现属截断类 → `INCOMPLETE/TIMEOUT`，发现仍留在 `reasons` |
| 4 | 计数比较 | 只在可信门通过后执行 |
| 5 | 退出码 | `INCOMPLETE`→`FAIL/SIMULATOR_ERROR`；`DIRTY`/`FAIL` 保留主因；另加 `NONZERO_EXIT` 到 `reasons` |
| 6 | 超时 | 其余情形下判 `INCOMPLETE/TIMEOUT` |
| 7 | 产物形态 | 无文件/空文件 → DIRTY 或 INCOMPLETE |
| 8 | 其余 | PASS |

### 11.4 新增反例的修前/修后

| 组合 | 第三轮（错） | 现在 |
| --- | --- | --- |
| 无文件＋原生 fatal＋`rc=1` | FAIL/`SIMULATOR_ERROR` | FAIL/`NATIVE_FATAL`，`reasons` 加 `NONZERO_EXIT` |
| 无文件＋UVM_FATAL＋`rc=1` | FAIL/`SIMULATOR_ERROR` | FAIL/`UVM_FATAL_EARLY_EXIT`，同上 |
| 空文件＋原生 error＋`rc=1` | FAIL/`SIMULATOR_ERROR` | FAIL/`NATIVE_ERROR`，同上 |
| 错 `run_id`＋`rc=1` | DIRTY/`RUN_ID_MISMATCH`，`reasons` 一条 | 同判定，`reasons` 两条（加 `NONZERO_EXIT`） |
| 截断文件＋超时 | DIRTY/`MISSING_FIELD:beats` | INCOMPLETE/`TIMEOUT`，`reasons`＝`[TIMEOUT, MISSING_FIELD:beats]` |
| 结构错误＋超时 | DIRTY/`RESULT_…` | INCOMPLETE/`TIMEOUT` |
| 错 `run_id`＋超时 | DIRTY/`RUN_ID_MISMATCH` | 同（身份类不因超时降级） |

历史对照里加了三行，其中"fatal + rc"与 9e5c2b6 一致——**这一条不是旧洞，
是我在 §10 引入的回归**，第四轮复核把它抓了出来：

```
guard  A4 exit rewrite: fatal + rc        old=FAIL/NATIVE_FATAL   new=FAIL/NATIVE_FATAL
FIXED  A4 exit rewrite: stale run id + rc old=DIRTY/NONZERO_EXIT_WITH_CLEAN_RESULT
FIXED  A4 torn artefact + timeout         old=DIRTY/MISSING_FIELD:beats
```

19 个 fixture：15 个被修正、4 个原本已正确，新判定器 0 个错
（第五轮后为 21 / 17 / 4，见 §12.3）。

### 11.5 自检账目

56 条用例 + 6 条附加检查（合并、双原因、四诊断 `reasons`、超时单独判定、
退出码进 `reasons`、截断发现进 `reasons`）= **62/62**
（第五轮加入 4 条用例与 1 条附加检查后为 67/67，见 §12.5）。

### 11.6 我在这一轮犯的错

- **改写主因。** `_with_exit` 里写成"`parse_error` 非空就换成 SIMULATOR_ERROR"，
  于是一个已被 UVM_FATAL 或原生 fatal 明确定性的运行被降格成"工具崩了"。
  根子是把"退出码异常"当成了比日志诊断更硬的证据，实际正好相反。
- **写了做不到的规则。** §10.2 第 4 步与 10.7 都写了"超时期间的缺文件、空文件、
  截断文件都是次生现象，不能单凭它们升级成 DIRTY"，但代码里超时排在字段检查
  之后，截断文件照样判 DIRTY。**这是第四次"声明超过实现"**——前三次是
  `reasons` 完整列表、检查器可信化完成、可达性降级；这次是判定规则。
  现在这条规则有对应用例锁住（`truncated result plus timeout` 等两行 + 一条
  附加检查），并且把"截断类/独立类"写成显式常量，不再只存在于散文里。
- **忘了把 F4 放进 `reasons`。** §10.3 把 F4 列入判定原因集合，实现里
  `_verdict_reasons` 根本没接收退出码。

---

## 12 第五轮复核：FIRM 被 TORN 遮住，以及一处关于退出码的错误说法

224 项组合矩阵验证了 §11 的修复，只剩一处分类遗漏，另有一句文档写错。

### 12.1 遗漏：可读的身份错误被截断症状遮住

```
run_id=old-run
case=single_tu
test=its_single_tu_test
<计数部分没写完，运行超时>
```

修前：`INCOMPLETE/TIMEOUT`，`reasons = [TIMEOUT, MISSING_FIELD:tus]`，
已存在的 `run_id` 不匹配没有被记录。把错误放在 `case` 或 `test` 上结果相同。

根因：`_judge_artifact()` 先遍历全部必填字段，遇到第一个缺失就返回；身份比较
在它后面，永远走不到。`_torn()` 再按这一条发现判定，于是"文件被截断"这个
可解释症状吞掉了"这份文件不属于本轮"这个不可解释的矛盾。

### 12.2 改法

新增 `_firm_findings()`：在有序判定之前，单独比较**已经存在且非空**的
`run_id` / `case` / `test`，并单独取出完整但不可解析的数值字段（空值不算，
因为空值正是被截断的行留下的形状）。`_classify` 拿到它之后：

- 有 FIRM → `DIRTY`，主因取第一条 FIRM；其余 FIRM、被遮住的 TORN 发现、
  `TIMEOUT` 全部进 `reasons`；
- 只有 TORN ＋超时 → 仍为 `INCOMPLETE/TIMEOUT`（原行为不变）；
- 全部字段齐全时的判定完全不变（`_judge_artifact` 仍是权威，`_firm_findings`
  只是把它的前置条件放宽到"读到就算"）。

不变量：**可读的矛盾不因后面的缺口而消失**；不可读的东西不因猜测而成立。
（这条规则的完整适用条件见 §13.4，第六轮补充了"可归属"这一半。）

### 12.3 新增反例

| 组合 | 修前 | 现在 | `reasons` |
| --- | --- | --- | --- |
| 错 `run_id` ＋缺计数字段＋超时 | INCOMPLETE/`TIMEOUT` | DIRTY/`RUN_ID_MISMATCH` | `[RUN_ID_MISMATCH, TIMEOUT, MISSING_FIELD:tus]` |
| 错 `case` ＋缺计数字段＋超时 | INCOMPLETE/`TIMEOUT` | DIRTY/`CASE_MISMATCH` | 同上形状 |
| 错 `test` ＋缺计数字段＋超时 | INCOMPLETE/`TIMEOUT` | DIRTY/`TEST_MISMATCH` | 同上形状 |
| `tus=abc` ＋缺计数字段＋超时 | INCOMPLETE/`TIMEOUT` | DIRTY/`FIELD_FORMAT:NOT_A_COUNT:tus='abc'` | 同上形状 |

第四条是我按同一类问题补的：完整但非数值的字段与身份错误同属 FIRM，之前同样
会被缺字段遮住。你若认为它超出"只补这一处"，可以只看前三条。

### 12.4 更正：fatal 与退出码无关

§11.1 写过"`uvm_fatal` 本身就以非零码退出，这条路上每个人都带着 `rc≠0`"。
**这句话是错的。** 用当前真实 TB 重跑 `final_phase` fatal（`run/A5_FINAL_FATAL.json`
现在记录 `returncode`）：

```
control  rc=0  status=PASS  reason=""
probe    rc=0  status=FAIL  reason=UVM_FATAL_IN_LOG
```

正确说法是：**fatal 与非零退出可能同时发生，也可能不**。因此

- 退出码不能用来推断是否发生过 fatal，也不能当作"这里有 fatal"的伴随特征；
- §11 的修复仍然必要（那三个反例是显式给 `rc=1` 构造的，判定器必须处理这种
  输入），但我对它的触发频率的描述是错的——它只在进程确实非零退出时发生
  （被 supervisor 杀掉、崩溃、`vsim` 自身报错），不是"每个 fatal 都会中"；
- 本工具链下这条路径在 22 例正常回归里一次都没触发（`returncodes observed: [0]`），
  这也正说明它只能靠构造的异常输入来验证。

这类错误的共同点与"`reasons` 是完整列表"一样：把对工具行为的假设当成事实写进
文档。现在 `A5_FINAL_FATAL.json` 与 `regress_A2_summary.txt` 都直接记录
`returncode`，这句话以后可以对着产物核。

### 12.5 自检账目

60 条用例 + 7 条附加检查（合并、双原因、四诊断 `reasons`、超时单独判定、
退出码进 `reasons`、截断发现进 `reasons`、FIRM 优先于 TORN）= **67/67**
（第六轮加入 3 条用例与 1 条附加检查后为 71/71，见 §13.5）。

### 12.6 我这一轮的错误

- **只看第一条发现就下结论。** `_firm_findings` 这个问题第四轮就埋下了：我当时
  写"身份先于计数"，却让身份比较依赖"全部字段齐全"这个前提。复核方构造的文件
  恰好把两件事拆开了。
- **把假设当事实。** "fatal 必带非零退出码"没有实测就写进 §11.1，并在提交信息里
  重复了一遍。已经改成实测结论，并让产物记录 `returncode`。

---

## 13 第六轮复核：FIRM 收集范围

352 项组合矩阵全绿，§12 的四个反例通过。剩下两处都在"哪些字段算 FIRM"这一层：
收集范围比判定需要窄。

### 13.1 两处遗漏

| 构造 | 修前 | 漏在哪 |
| --- | --- | --- |
| `run_id=old` + `tus=1` 重复两行 + 超时 | INCOMPLETE/`TIMEOUT`，`reasons=[TIMEOUT, RESULT_DUPLICATE_KEY:tus]` | `_classify` 只在 `parse_error is None` 时才调 `_firm_findings()`；有结构错误就整段跳过 |
| 身份正确、`err.error.BOGUS=abc`、其余计数未写完 + 超时 | INCOMPLETE/`TIMEOUT`，`reasons=[TIMEOUT, MISSING_FIELD:tus]` | `_firm_findings()` 只遍历 `REQUIRED_FIELDS`，动态 `err.error.*` / `err.fatal.*` 不在其中 |

两处都仍然拒绝 PASS，影响的是 DIRTY 与 TIMEOUT 的分类和矛盾记录。

### 13.2 改法

- **FIRM 收集不再受结构错误门控。** 逐字段判定本来就是逐字段的：`tus` 重复不
  影响 `run_id` 是否可读。`parse_error` 只决定"整份文件能不能当完整记录用"，
  不该决定"其中某些字段能不能被单独读出来"。
- **重复的键单独列出为 `ambiguous`**（从 `RESULT_DUPLICATE_KEY:a,b` 解析）。
  这些键的值只剩最后一行，不能归属，因此不参与 FIRM；其余键照常比较。
  重复的是 `run_id` 就直接不比 `run_id`，不拿"最后留下的那个值"当结论。
- **动态计数与固定计数同等对待**：新增 `_count_keys()`，把 `err.error.*` /
  `err.fatal.*` 一起送进严格数值检查。之前只有字段齐全时它们才会被检查。

### 13.3 新增反例

| 组合 | 修前 | 现在 | `reasons` |
| --- | --- | --- | --- |
| 重复键 `tus` + 错 `run_id` + 超时 | INCOMPLETE/`TIMEOUT` | DIRTY/`RUN_ID_MISMATCH` | `[RUN_ID_MISMATCH, TIMEOUT, RESULT_DUPLICATE_KEY:tus]` |
| 重复键 `run_id` 本身 + 超时 | INCOMPLETE/`TIMEOUT` | INCOMPLETE/`TIMEOUT`（保持：该值不可归属） | `[TIMEOUT, RESULT_DUPLICATE_KEY:run_id]` |
| `err.error.BOGUS=abc` + 缺字段 + 超时 | INCOMPLETE/`TIMEOUT` | DIRTY/`FIELD_FORMAT` | 同上形状 |

第二行是反向用例：它证明"重复的 `run_id` 不被采信"，而不是被悄悄拿去比较。

### 13.4 这条规则的边界（不再写成无条件成立）

能保证的是：**一个可读且可归属的矛盾，不会被截断症状遮住。** 两个前提都要成立：

- *可读*：该字段在文件里存在，且值非空。空值是截断留下的形状，不算。
- *可归属*：该键在文件里只出现一次。重复键只剩最后一个值，不能归属。

不满足这两条时，判定回到 `INCOMPLETE/TIMEOUT`，并把这些发现写进 `reasons`——
不猜、也不丢。还没写进文件的字段当然也无从判断。

### 13.5 自检账目

63 条用例 + 8 条附加检查（合并、双原因、四诊断 `reasons`、超时单独判定、
退出码进 `reasons`、截断发现进 `reasons`、FIRM 优先于 TORN、重复键留在
`reasons`）= **71/71**。

### 13.6 我这一轮的错误

- **规则写成了无处不在的措辞，实现却是"在某个分支里"。** §12.2 我写"可读的矛盾
  不因后面的缺口而消失"，没写"也不因别的字段坏掉而消失"。实现正好漏了这一半：
  `_firm_findings` 被挂在 `parse_error is None` 上。
- **枚举字段时只抄了自己记得的那一组。** 动态 `err.error.*` 是这份结果格式里最
  需要严格检查的部分（ID 计数），却因为不在 `REQUIRED_FIELDS` 里被漏掉。这一类
  "按名单遍历、名单不全"的错误与前面几轮同源。