# V3.5 Step12C-M4 synthesis-only report

日期：2026-09-13  
器件：`xcku5p-ffvb676-2-e`  
Vivado：2025.2  
时钟：`clk = 2.000 ns`（500 MHz）  
运行类型：OOC synthesis-only；未运行 place/route

## M4 范围

本轮只在 M3 暴露的 input-cache 写入边界增加 bank-local write-command pipeline：外部 `data_fire` 在 C 锁存 cache/bank/address/data/epoch/last，data/tag RAM 在 C+1 commit。最后带 `end` 的 command commit 后才释放 cache。R4C、数学、官方接口、M3 staging、V 写回 pipeline、ResultMemory reader 和 XDC boundary contract 未修改。

## 功能门禁

Step12B 既有功能/周期回归通过：

- Python cycle model：PASS
- ModelSim normal：PASS
- ModelSim `+define+SYNTHESIS`：PASS
- zero/sparse/alternating/random：PASS
- backpressure、two-TU、vector-ID wrap、epoch scrub：PASS
- 26 项 model/checker mutation：PASS
- ready-high output fire II：1
- V/H vector II：16
- 单 TU：1024 result writes、1024 output fires

## 综合资源

| 项目 | 结果 |
|---|---:|
| LUT | 22,921 |
| LUTRAM | 7,168 |
| FF | 21,315 |
| DSP48E2 | 128 |
| BRAM | 0 |
| URAM | 0 |
| synthesis errors | 0 |
| critical warnings | 0 |
| unconstrained internal endpoints | 0 |

综合识别 input cache、tag、intermediate 和 result memory 为 distributed RAM（`RAM64M/RAM64M8/RAM64X1D`）。这证明 M1/M2 的存储结构仍可综合，但不等于已经完成最终物理时序。

## 时序门禁

| 指标 | 结果 | 判定 |
|---|---:|---|
| setup WNS | `+0.087 ns` | PASS |
| setup TNS | `0 ns` | PASS |
| setup failing endpoints | `0` | PASS |
| hold WHS | `-0.076 ns` | FAIL |
| hold THS | `-17.454 ns` | FAIL |
| hold failing endpoints | `293` | FAIL |

当前最差 hold 路径来自 OOC 输入 `it_data_addr[*]` 到新的 `input_wr_addr_*_q` 命令寄存器；本轮没有改 XDC、没有添加 false path/multicycle，也没有用人为 input-min-delay 掩盖问题。

## 结论

Step12C-M4 **功能 PASS、综合结构 PASS，但 Step12C-1 timing STOP**。由于 hold 未满足，按冻结门禁不进入 place/route，不创建 `v3.5-18`。下一步只允许基于该真实 hold 路径单独评审；不得扩展其他变换或修改 R4C。

## 关键哈希

```text
R4C p2f_dct2_64_b1_step102.sv
15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1

M4 wrapper step12b_dct2_64_wrapper.sv
D1459B652666E2DBBB0D3464002E88DD30867C4BA6E4715E6865B5164E664943

postsynth DCP
49B703F36D6E6DDDB070ABCC8CC331B74CF6454402A0C4FAB299C58E129D1DCB
```

完整原始报告、DCP、ModelSim 日志、RTL trace 和 cycle-model evidence 均位于本目录的 `m4/`、`m4_model/` 与 `m4_synth/`。
