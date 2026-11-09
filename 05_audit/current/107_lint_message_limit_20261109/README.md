# D0 · 综合告警真实条数（口径修正）

基线提交 `71c71c5`。**RTL 未修改**（`unified_its_wrapper.sv` SHA256 `903cd9b2…` 不变），默认 `FINAL_SATURATE=1`，`official_equivalence=NOT_PROVEN`。

## 结论

完整综合的真实告警数是 **332 条**；此前长期记录的 **166 条**是 Vivado 默认 100 条单码打印上限造成的假数。

| 项 | 旧记录 | 本次实测 |
|---|---|---|
| 告警总数 | 166 | **332** |
| `Synth 8-7137` | 100 | **266** |
| Critical Warnings | 0 | 0 |
| Errors | 0 | 0 |
| 层次单元格 | 52581 | 52581 |
| DSP48E2 | 320 | 320 |

只有 `8-7137` 一个码撞上限，其余五个码条数完全一致。

## 各码真实条数

| 告警码 | 默认上限 | 上限 20000 | 是否失真 |
|---|---|---|---|
| `Synth 8-7137` | 100 | 266 | 是 |
| `Synth 8-6014` | 45 | 45 | 否 |
| `Synth 8-3917` | 11 | 11 | 否 |
| `Synth 8-7129` | 7 | 7 | 否 |
| `Synth 8-4767` | 2 | 2 | 否 |
| `Synth 8-3936` | 1 | 1 | 否 |
| 合计 | 166 | 332 | — |

## `Synth 8-7137` 的 266 条构成

| 寄存器 | 条数 | 模块 |
|---|---|---|
| `input_mem_reg[...]` | 256 | `unified_p4_kernel` |
| `kernel_rd_bank_data_q_reg[0..1][0..3]` | 8 | `unified_its_wrapper` |
| `desc_mem_reg` | 1 | `unified_its_wrapper` |
| `primary_return_data_q_reg` | 1 | `unified_its_wrapper` |

注意区分：`input_mem` 相关单元格共 4235 个，其中 `input_mem_reg*` 有 4096 个，但只有 **256 个**触发该告警。不得表述为「4235 个全部有问题」。

## `Synth 8-3936` 的网表级检查

导出后综合网表（45.74 MB）核对结果：

| 检查 | 结果 |
|---|---|
| `get_cells -hier -filter {NAME =~ *s0_coeff_q*}` | 0 个 |
| 网表文本 `s0_coeff` 命中 | 0 次 |
| 网表中 `mul_a_q` 命中 | 0 次（已吸收进 DSP） |
| 分布式 RAM `RAM64M8` | 457 个 ≈ 234 kbit |

告警所说的「4096 位寄存器只剩 16 位」指向**中间阶段**的寄存器，该寄存器在最终网表中不存在。系数存储完整映射进分布式 RAM，与期望容量（61 × 4096 = 249.9 kbit）量级一致。

**本条仍维持 OPEN**：已排除「网表里残留 16 位系数寄存器」这一具体形态，但没有证明系数到 DSP 的连线在网表层面等价于 RTL。定案需要后综合功能仿真。

## 本次撤回的表述

- 「完整综合 166 Warning / 0 Critical」→ 166 是封顶值
- 「`8-7137` 共 100 条」→ 真实 266 条
- 「154 条告警已全部归位」→ 不成立
- 「Lint 达标」→ 改为部分达标

## 复现

```powershell
cd <repo>/closure_audit/d0
cmd /c "D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -notrace `
        -source run_d0.tcl -log d0.log -journal d0.jou"

Select-String -Path d0.log -Pattern '^WARNING:\s+\[(\w+) (\d+-\d+)\]' |
  ForEach-Object { $_.Matches[0].Groups[2].Value } |
  Group-Object | Sort-Object Count -Descending
```

Tcl 侧关键一行：`set_msg_config -id {Synth 8-7137} -limit 20000`

## 文件

| 文件 | 说明 |
|---|---|
| `run_d0.tcl` | 抬高上限后完整综合并统计 |
| `run_d0b.tcl` | 导出后综合网表用于 8-3936 检查 |
| `d0.log` | 完整综合日志（332 条告警） |
| `d0b.log` | 网表导出运行日志 |
| `D0_RESULT.json` | 结构化结果 |

后综合网表 `d0_netlist.v`（45 MB）未纳入版本库，可由 `run_d0b.tcl` 重新生成。