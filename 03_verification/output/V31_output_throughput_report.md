# V3.1 输出吞吐优化报告

> 日期：2026-08-07
> 基线：V2 (ITS_STUDY_V2_FUNCTIONAL_PASS_2026-08-04.zip)
> 目标：消除输出气泡，无反压时连续每拍输出一个 40bit beat

---

## 一、核心修改

### 1. its_core_500.v — 零气泡输出流水线

**修改前（V2）：**
```
out_pipe_ready = !out_valid_pipe;      // pending beat 未写出时不能读下一组
write_fire     = out_valid_pipe && !output_fifo_full;
out_cnt 语义  = 当前 pending beat 基地址，write_fire 时 +4
```

**修改后（V3.1）：**
```
write_fire     = out_valid_pipe && !output_fifo_almost_full;
out_pipe_ready = !out_valid_pipe || write_fire;   // 同拍 read+write
out_cnt 语义  = 下一次读取地址，out_read_en 时 +4
out_valid_pipe: read&&write 同拍时保持 1
out_pipe_flush: 最后一个 beat 被 READ 时置位
out_done     : flush && !valid_pipe && !write_fire
```

### 2. async_fifo.v — almost_full 修复

**根因：** V3.1 让 core 以 200MHz 每拍 1 beat 写入（零气泡），而 `almost_full` 用 `rd_ptr_gray_sync2`（2-3 拍滞后的同步读指针）做 gray+2 比较。滞后的同步指针使 almost_full 晚 2-3 拍才响应，允许 core 超额写入 → FIFO 溢出 → beat 丢失 + 死锁。

**证据（bp_debug_tb 实测）：** FIFO 满（wr_count=16）时 `almost_full=0`，core 继续写入导致溢出。

**修复：**
```
assign almost_full = (wr_count >= (DEPTH - 2));
```
基于写域 `wr_count`（读指针滞后时高估占用，保守安全）。修复后 wr_count 峰值 15，无溢出。

---

## 二、四个概念的区分

| 概念 | 当前状态 |
|------|:--:|
| **每个 beat 携带 4 个最终结果** | ✅ `it_data_out[39:0] = 4×10bit` |
| **输出接口连续每拍传输 4 个结果** | ✅ V3.1 实现，bubbles=0 |
| **core 输出流水每拍向 FIFO 写一个 beat** | ✅ V3.1 实现（几乎满时暂停） |
| **变换计算核心每拍完成 4 个最终结果** | ❌ 未实现，不在本阶段范围（只优化输出流水线） |

---

## 三、定向测试结果

### 3.1 protocol_directed_tb（单时钟 100MHz）

| 测试 | 场景 | fires | bubbles | golden |
|------|------|:---:|:---:|:--:|
| T1 | 正常无反压 | 4 | **0** | OK |
| T2 | 首拍前 req=0 | 4 | 0 | OK |
| T3 | 中间 req=0 | 4 | 15 | OK |
| T4 | 末拍前 req=0 | 4 | 10 | OK |
| T5 | 长 req=0 | 4 | 200 | OK |

**T1 逐周期：** fire[0..3] = 310,311,312,313 — **连续 4 拍，bubbles=0**。

### 3.2 bp_debug_tb（双时钟 200MHz core + 100MHz if）

`bp_dct2_16x16`（3on/2off 反压）：

| 修复前 | 修复后 |
|--------|--------|
| out_idx 停在 136，死锁 | out_idx=256 完整输出 |
| beat 22 起错位 | mism=0 |
| wcnt=16 时 af=0（溢出） | wcnt max 15，af 正确断言 |

---

## 四、回归结果

| 测试 | 结果 |
|------|:--:|
| **contest top (its_top)** | **1539/1539 PASS**，Errors=0，Warnings=0 |
| 单时钟 its_tb_500 | **1539/1539 PASS** |
| 双时钟 its_tb_500 | **1539/1539 PASS** |
| audit_matrices | PASS |
| audit_test_vectors | PASS |
| test_ref_model_onehot | 65 PASS |
| bp_debug 复现用例 | mism=0，FIFO max wr_count=15 |

### 日志引用

| 日志 | 内容 | 关键结果 |
|------|------|---------|
| `_v31_audit/v31_contest_top.log` | contest top (its_top) 完整回归 | 1539/1539 PASS, Errors=0, Warnings=0, 无 itcl34/license 错误 |
| `_v31_audit/v31_bp_debug_fixed.log` | bp_dct2_16x16 反压复现（修复后） | out_idx=256, mism=0, FIFO max wr_count=15, 写=64 读=64 fire=64 |

### bp_debug 最终指标（v31_bp_debug_fixed.log）

```
out_idx            = 256 (expect 256)
mism               = 0 (expect 0)
FIFO max wr_count  = 15 (must <= 15)
FIFO write fires   = 64 (expect 64)
FIFO read fires    = 64 (expect 64)
interface fire     = 64 (expect 64)
no timeout/deadlock = PASS
```

---

## 五、哈希保护

| 文件 | 状态 |
|------|:--:|
| rom_coeffs.hex | 不变 |
| lfnst_coeffs.hex | 不变 |
| canonical_matrices.json | 不变 |
| its_top_500_wrapper.v | 不变 |
| its_transform_engine.v | 不变 |
| its_core_500.v | 修改（零气泡流水线） |
| async_fifo.v | 修改（almost_full 修复） |
