# ITS_NEW

本仓库是面向 VVC 反变换模块（ITS）的 FPGA 设计与验证工程，当前内容来自以下完整工程快照：

```text
D:\Workspace\ITS_STUDY_V35_STEP12A_R2_1_DCT2_64_2D_PRE
```

快照日期：2026-09-10。

## 当前状态

- 功能基线：V3.4 的主变换与 LFNST 修复结果保持冻结。
- DCT2-64 独立 P4 计算核：每拍产生 4 个完整的一维变换结果，64 点向量启动间隔为 16 拍。
- R4C 独立计算核：模块级 OOC post-route 已在 500 MHz（2.000 ns）约束下闭合。
- 当前集成阶段：V3.5 Step 12A-R2.1，已建立可执行的 64×64 DCT2 二维预集成周期模型。
- Step 12B wrapper RTL 尚未开始，需在 R2.1 证据通过独立审核后进入。

## 当前验证入口

```text
python 03_verification/scripts/step12ar2_executable_model.py
python 03_verification/scripts/make_step12ar2_manifest.py
```

详细说明请参阅：

- `README_STEP12A_R2.md`
- `03_verification/output/` 下的各阶段报告
- `_step12ar2_audit/` 下的 Step 12A-R2.1 验收证据

## 关键数学与定点约定

- 主变换：使用冻结的逆变换算子 `A = C^T`，RTL 直接执行 `A·x`，禁止再次转置。
- 二维顺序：先进行垂直变换，再进行水平变换。
- 主变换每个一维阶段：`raw → +32 → 算术右移 6 位 → signed16 回绕`。
- 最终竞赛接口：保留结果低 10 位。
- LFNST：执行 `M·x`，禁止转置；后处理为 `+64 → 算术右移 7 位 → Clip3 到 signed16`。
- LFNST 有效输入数：4×4 和 8×8 为 8，其余适用尺寸为 16。

## 当前结论边界

已经证明的是：

- DCT2-64 独立一维 P4 核功能正确；
- 预热后可连续每拍输出 4 个完整的一维变换结果；
- 独立 R4C 核的模块级 OOC 500 MHz 时序闭合；
- Step 12A-R2.1 二维预集成模型当前返回 PASS。

尚未证明的是：

- Step 12B 的真实二维 wrapper RTL；
- 完整 Core 集成后的 500 MHz 时序；
- DCT2 其他尺寸、DCT8、DST7 和 LFNST 的新 P4 架构；
- 完整二维 ITS 长期平均每拍产生 4 个最终系数。

## GitHub 快照排除项

原始 D 盘工程目录未被修改。本 GitHub 快照仅排除了与设计复现无关或存在安全风险的内容：

- 嵌套 `.git` 元数据；
- `.Xil`、`__pycache__`；
- ModelSim 生成的 `work*`、`.qpg`、`.wlf`；
- Vivado TclStore 用户缓存；
- VTM 示例私钥。

RTL、ROM、canonical 数据、测试向量、验证脚本、报告、日志和主要 Vivado 实现证据均已保留。
