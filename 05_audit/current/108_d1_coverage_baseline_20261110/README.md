# 108 — D1 覆盖率基线 / D2 缺口归因

日期：2026-11-10
仿真器：ModelSim SE-64 2020.4

## 1. 结论摘要

| 项 | 结果 |
|---|---|
| 测试平台 | 项目既有 16 个 TB，展开为 18 个运行项 |
| normal 模式 | 18/18 PASS，18 个 UCDB |
| synthesis 模式（`+define+SYNTHESIS`） | 18/18 PASS，18 个 UCDB |
| 断言覆盖率 | 100.00%（220/220，仅 normal 模式有） |
| 语句覆盖率 | 75.21%（normal）/ 75.52%（synthesis） |
| 分支覆盖率 | 60.13%（normal）/ 59.73%（synthesis） |
| D2 缺口条目 | 3494 条，已定位到 RTL 行（见 `GAPS.csv`） |

## 2. 启动方式：必须用 `-batch`，不能用 `-c`

`vsim -c` 在本机启动即退出，退出码 `0xC0E90002`，标准输出 0 字节。
Windows 代码完整性事件日志给出直接原因：

```
Code Integrity determined that a process (vish.exe) attempted to load
tk86t.dll that did not meet the Enterprise signing level requirements
(Policy ID: {0283AC0F-FFF1-49AE-ADA1-8A933130CAD6})
```

`tk86t.dll` 是 ModelSim 的 Tcl 解释器库，`-c` 路径会加载它，被系统应用控制策略拦截。
`-batch` 不走该通路，可正常仿真。

许可证本身有效：`lmutil lmdiag` 判定节点正确、2036 年到期、`mgc_s` 可 checkout。
`vlog` 编译不受影响。

## 3. 覆盖率采集命令

```text
vlib work
vlog -sv +cover=bcestf <6 RTL + 16 TB>
vsim -batch -coverage -t 1ps \
     -do "coverage save -testname <mode>_<tag> -onexit {<tag>.ucdb}; run -all; quit -f" \
     work.<tb>
vcover merge merged.ucdb <all ucdb>
vcover report -output coverage_summary.txt merged.ucdb
```

`+cover=bcestf` = 分支 / 条件 / 表达式 / 语句 / 翻转 / FSM。

## 4. 两种模式不可合并

`unified_its_wrapper.sv` 中有 7 处 `ifndef SYNTHESIS`，把 220 条断言整块编译掉，
两种模式下设计单元的结构不同。`vcover merge` 跨模式合并会产生 11 个警告，
结果中 synthesis 数据被丢弃（合并后数字与 normal 完全一致）。

因此本目录**分模式报告，不提供合并总数**。

## 5. D2 缺口归因方法

1. `vcover report -details -code bces -below 100` 导出逐实例未命中明细。
2. 抓取所有带 `***0***` 的行（分支/语句用 `Line Item Count Source` 格式，
   条件/表达式用 `Line / Row` 格式，两种格式分别解析）。
3. 按「设计单元 + 覆盖类型 + 行号 + 条目」去重，记录该条目在多少个实例中未命中。
4. 用 `coverage_summary.txt` 统计每个设计单元的总实例数，
   区分 **global gap**（所有实例均未覆盖）与 **instance-specific gap**（仅部分实例未覆盖）。
5. 回到 RTL 源码取行文本，并检查相关函数是否真的被调用。

## 6. D2 结果

### 6.1 从未被覆盖（global gap）

| 模块 | 实例数 | 语句行 | 分支 |
|---|---:|---:|---:|
| `unified_its_wrapper` | 10 | 143 | 149 |
| `unified_p4_kernel` | 15 | 5 | 4 |
| `bounded_lfnst_engine` | 11 | 1 | 1 |
| `its_input_cache_bank` | 80 | 0 | 0 |
| `its_simple_ram` | 120 | 0 | 0 |

### 6.2 wrapper 的 143 行中 121 行是死代码

以下 6 个函数在 `unified_its_wrapper.sv` 中定义后**从未被调用**（L841–L1085，约 233 行）：

| 函数 | 定义 | 调用 |
|---|---:|---:|
| `coeff_base` | 1 | 0 |
| `scan_row` | 1 | 0 |
| `scan_col` | 1 | 0 |
| `scan_coord_lut` | 1 | 2（调用者本身也无人调用） |
| `scan_row_lut` | 1 | 0 |
| `scan_col_lut` | 1 | 0 |

补用例无法覆盖这些行。处置方式（删除 / `coverage exclude` 标注）属 RTL 变更，待负责人确认。

### 6.3 剩余 22 行真实代码

| 类别 | 行数 | 行号 |
|---|---:|---|
| `default:` 兜底分支 | 4 | 736 / 750 / 764 / 2852 |
| `$fatal` 错误路径 | 4 | 1464 / 1479 / 1485 / 1489 |
| `protocol_error <= 1'b1` | 5 | 2433 / 2436 / 2439 / 2638 / 2640 |
| scrub / drain 状态 | 9 | 574–579、2474、2714–2715、2782–2784 |

仅最后一类值得补用例；其余为防御性分支。

## 7. 文件说明

| 文件 | 说明 |
|---|---|
| `D1_RESULT.json` | 双模式覆盖率总量（DUT 口径） |
| `coverage_summary_normal.txt` | normal 模式逐实例覆盖率报告 |
| `coverage_summary_synthesis.txt` | synthesis 模式逐实例覆盖率报告 |
| `GAPS.csv` | 3494 条缺口明细（设计单元、类型、行号、源码、实例命中比） |
| `run_d1.py` | D1 驱动：向量生成 → 覆盖率编译 → `-batch` 仿真 → 合并 |
| `summarize_cov.py` | 逐实例报告聚合成 DUT 口径 |
| `gap_analysis.py` | 未命中项 → RTL 行级归因 |

## 8. 复现

```text
python run_d1.py prep                      # 生成向量 + 覆盖率编译
python run_d1.py run                       # normal 模式 18 个运行项
python run_d1.py all --mode synthesis      # synthesis 模式
python run_d1.py report                    # 合并 + 出报告
python summarize_cov.py                    # DUT 口径汇总
python gap_analysis.py                     # D2 归因
```

依赖：仓库内 `03_verification/step12d_engineering/` 的 4 个向量生成器、
`profiles/contest_engineering_vtm10_sat10_v2.json`、
`05_audit/current/27/step12d_engineering/LEGAL_TRANSFORM_MATRIX.json`。