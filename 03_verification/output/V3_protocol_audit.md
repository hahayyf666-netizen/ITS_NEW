# V3 输出协议审计报告（修正版）

> 日期：2026-08-04
> 基线：ITS_STUDY_V2_FUNCTIONAL_PASS_2026-08-04.zip
> 范围：仅审计，不修改 RTL/ROM/JSON/测试向量

---

## 一、题面协议原文

赛题接口信号表：

```
信号名              位宽  方向  说明
it_data_out[39:0]   40    O    输出结果（4x10bit 有符号拼接）
it_data_out_vld      1    O    输出有效
it_data_out_req      1    I    输出反压
it_done              1    O    TU 处理完成脉冲
```

题面未逐拍定义 req/vld 握手语义，只给出信号名和方向。

---

## 二、动态协议验证结果

### 2.1 定向测试（`_v3_audit/protocol_directed_tb.v`）

单时钟模式（clk=100MHz），DUT=its_top_500_singleclk，TU=4×4 DCT2：

| 测试 | 场景 | 结果 |
|------|------|:--:|
| T1 | 正常无反压 | PASS, fires=4 |
| T2 | 首个输出前 req=0 | PASS, fires=4 |
| T3 | 输出中间 req=0 | PASS, fires=4 |
| T4 | 最后一个 beat 前 req=0 | PASS, fires=4 |
| T5 | 长时间 req=0 后恢复 | PASS, fires=4 |
| — | beat 顺序正确 | 逐点 golden 显式比较通过（每 beat 4×10bit，共 16 点逐位匹配） |
| — | it_done 不早于最后握手 | 记录并比较 done_cycle >= fire_cycle[last]（T1: 320 >= 316 ✓） |

### 2.2 关键行为确认（单时钟 100MHz，实测）

| 行为 | T1(正常) | T2(req=0发送TU) | T3(中间req=0) | T4(末拍req=0) | T5(长req=0) |
|------|:--:|:--:|:--:|:--:|:--:|
| fires | 4 | 4 | 4 | 4 | 4 |
| bubbles | 3 | 0 | 15 | 12 | 201 |
| golden | OK | OK | OK | OK | OK |
| done > last fire | ✅ | ✅ | ✅ | ✅ | ✅ |
| it_done 早于 fires | ❌ | ❌ | ❌ | ❌ | ❌ |

**T1 正常：** fire_cycle = [310,312,314,316]，间隔 2 cycle（1 bubble），done=320。

**T2 背压发送：** req=0 期间 TU 仍在处理，core 正常将数据写入 output_fifo。恢复 req 后 4 beat 以 1 cycle/beat 清空（bubbles=0，fire_cycle=[370,371,372,373]）。证明 core 继续写 FIFO 不受 req 影响。

**T3 中间 req=0：** FIFO 积压后恢复，连续清空 fire[1..3] 在 3 个 cycle 内（bubbles 仅在被 stall 的 gap 中）。

**T4 末拍 req=0：** fires==3 时拉低 req，最后一拍等 req 恢复后才传输。

---

### 2.4 T1 逐周期实测（单时钟 100MHz，正常无反压）

```
fire[0] cycle=310 data=f7fdbcd423
fire[1] cycle=312 data=af1eafd04c   ← gap=1 bubble
fire[2] cycle=314 data=47289eac29   ← gap=1 bubble
fire[3] cycle=316 data=1a3d015826   ← gap=1 bubble
done_cycle=320 (4 cycles after last fire)
bubbles=3, fires=4
```

输出时序：fire → bubble → fire → bubble → fire → bubble → fire → (4 idle) → done。

### 2.5 T3 背压后突发实测

```
fire[0] cycle=310
REQ->0 after beat 1
REQ->1 cycle=325
fire[1] cycle=326  ← FIFO 积压清空，1 cycle/beat 突发
fire[2] cycle=327
fire[3] cycle=328
```

**背压恢复后 FIFO 以 1 beat/cycle 清空积压，无气泡。**

---

## 三、精确吞吐分析

### 3.1 区分四个概念

| 概念 | 定义 | 当前实现 |
|------|------|---------|
| **每个 valid beat 携带 4 个点** | `it_data_out[39:0] = 4×10bit` | ✅ 接口位宽 40bit，每拍 4 点 |
| **core 侧输出流水线吞吐** | `out_mem → output_fifo` 写入间隔 | 每 2 core-clk 周期 1 beat（read+write 交替） |
| **interface 侧每拍传输** | `it_data_out_vld && it_data_out_req` | 无气泡时每 1 if-clk 周期 1 beat；有气泡时每 2 if-clk 周期 1 beat |
| **计算核心每拍完成 4 个结果** | S_COMPUTE 阶段产出 | ⚠️ 4 MAC 并行，但需要 N 拍累加完成一组 4 个结果 |

### 3.2 单时钟模式（clk_if = 100MHz，实际仿真频率）

**core 侧输出流水线：**

```
时序（clk = 100MHz, T = 10ns）：

Cycle 0: out_read_en=1 → out_mem_rd0..rd3 → data_out_r ← {out_mem[rd0..rd3]}
         out_valid_pipe <= 1
Cycle 1: out_valid_pipe=1, out_pipe_ready=0 → 不能读下一组
         write_fire = valid_pipe && !fifo_full → output_fifo 写入
         out_valid_pipe <= 0
Cycle 2: out_valid_pipe=0, out_pipe_ready=1 → out_read_en=1 → 读下一组
         ...
```

**结论：core 侧每 2 个 clk 周期产出 1 个 beat（读→写→读→写）。**

**interface 侧（FWFT FIFO 读）：**

FWFT FIFO 特性：非空时数据直接出现在输出端口。每 clk 周期可读 1 beat。
但由于 core 每 2 个周期产生 1 beat，interface 侧有效传输也是每 2 周期 1 beat。
中间 1 拍为气泡（FIFO 空）。

**单时钟模式输出吞吐：**
```
1 beat / 2 clk @ 100MHz = 50M beats/sec = 200M points/sec
```

### 3.3 双时钟模式（clk_core=200MHz, clk_if=100MHz）— 静态分析

*注意：以下为基于 RTL 代码的静态分析，未经仿真验证。双时钟仿真因 wrapper CDC 复位同步链在单次 `run -all` 中需手动等待，验证脚本待完善。*

**core 侧（静态）：**
```
clk_core = 200MHz, T = 5ns
1 beat / 2 core_clk = 1 beat / 10ns = 100M beats/sec
(同单时钟模式的 core 侧行为：read+write 交替)
```

**interface 侧（静态）：**
```
clk_if = 100MHz, T = 10ns
FWFT FIFO: 数据在非空时立即可用
FIFO 写入速度 = 1 beat / 10ns (core 侧)
FIFO 读出速度 = 1 beat / 10ns (interface 侧, req=1 时)
稳态：写入/读出平衡，每 10ns 1 beat
```

**双时钟模式输出吞吐（静态估算）：**
```
1 beat / 10ns = 100M beats/sec = 400M points/sec
```

### 3.4 500MHz 目标频率（FPGA 实现）

```
clk_core = 500MHz, T = 2ns
Core 输出: 1 beat / 4ns = 250M beats/sec = 1000M points/sec
clk_if = 500MHz (single-clock) 或更低 (dual-clock)
在 single-clock @ 500MHz 时: 250M beats/sec
```

### 3.5 吞吐瓶颈总结

**输出阶段不是吞吐瓶颈。** 真正瓶颈在计算阶段（S_COMPUTE + S_PREFETCH），占用周期数远大于输出阶段。以 4×4 TU 为例：T1 实测 325 总周期中，输出阶段 fire_cycle=[310,312,314,316]，输出仅占 ~10 周期（< 3%）。

---

## 四、八个问题的回答

### Q1: it_data_out_req=0 时，题面是否要求 it_data_out_vld=0？

**题面未明确要求。** 当前 RTL 实现 req 门控 vld（`it_data_out_vld = req & ~empty & ~front_done`）。这是实现选择，功能正确。

### Q2: 数据传输条件是 vld&&req 还是 vld=1 即传输？

**当前：vld && req。** testbench 的 `wait_output` 在两者同时为 1 时捕获。RTL 的 vld 被 req 门控，等效于 `fire = vld && req`。

### Q3: req 拉低期间，core 是否停止

**req=0 只停止 interface 侧 output_fifo 的读取。** core 侧继续运行：

1. core 在 S_OUT 阶段继续从 out_mem 读数据、通过 3 级流水线写入 output_fifo
2. 直到 output_fifo 写满（`output_fifo_full=1`），`write_fire` 停止，`out_valid_pipe` 保持，`out_cnt` 暂停
3. req 恢复后，FIFO 开始清空，core 恢复推进

**T2 实测证据：** req=0 期间发送 TU，350 个 cycle 后恢复 req，4 beat 以 1 cycle/beat 清空，fires=4。证明 core 在 req=0 期间正常写 FIFO。

| 现象 | 是/否 | 证据 |
|------|:---:|------|
| interface 停止读 | ✅ | `rd_en = req & ~empty & ~front_done` |
| core 继续写 FIFO | ✅ | T2: req 恢复后 4 beat 立即清空（bubbles=0） |
| FIFO 满后 core 暂停 | ✅ | `write_fire = valid_pipe && !fifo_full` |
| 丢点 | ❌ | T1-T5 全部 fires=4 |

### Q4: req 在各位置拉低

**全部正确。** T2（首拍前）、T3（中间）、T4（末拍前）均 PASS，fires=4。`out_valid_pipe` 在背压时保持（line 815），数据不丢。

### Q5: it_done 时序

**正确。** `it_done = front_done = core_done_pending && front_beats_done`。`front_beats_done` 检查所有预期 beat 已被读取。

### Q6: beat 数

```
expected_beats = width * height / 4
4×4 = 16/4 = 4 beats
```

RTL 和 testbench 均按此规则检查。所有测试 fires=4，验证通过。

### Q7: 无反压气泡

**存在 1 拍气泡（单时钟模式）。** 原因：`out_pipe_ready = !out_valid_pipe`，不能同拍读和写。周期表详见 3.2 节。

### Q8: 区分四个概念

详见 3.1 节。核心结论：
- 输出接口每 beat 携带 4 点 ✅
- core 侧每 2 周期产 1 beat（read+write 交替）
- interface 侧每 2 周期传输 1 beat（1 data + 1 bubble）
- 计算核心 S_COMPUTE 每拍 4 MAC 乘加，N 拍产出 4 个完整结果

---

## 五、题面要求与 RTL 行为对照

| 题面要求 | RTL 行为 | 符合？ |
|---------|---------|:---:|
| 输出 4×10bit 打包 | `it_data_out[39:0]` | ✅ |
| 光栅扫描顺序 | `out_mem` 顺次读取 | ✅ |
| 输出反压 | req 门控 vld + FIFO | ✅ |
| `it_done` 时序 | beat 全部接收后 | ✅ |
| "一拍计算四个点" | 4 MAC 并行，输出接口 4 点/beat | ⚠️ 吞吐受计算阶段限制，但协议正确 |
| 支持流水 | 连续 TU 支持 | ✅ |

---

## 六、是否需要修改协议

**当前协议功能正确，无需紧急修改。** 输出气泡（1 拍/beat）可通过允许同拍 read+write 消除，但这不是功能缺陷——V2 验收通过。

---

## 七、V3 结论

```
V3 协议审计：PASS
  - 5/5 定向测试通过
  - req/valid/done 时序正确
  - 背压不丢点
  - beat 数严格 = w*h/4
  - 吞吐分析：core 2 周期/beat，interface 匹配 core 产出率
  - 输出气泡：1 拍（core 侧 read/write 交替导致）
```
