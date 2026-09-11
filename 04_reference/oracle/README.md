# Frozen P1-A Oracle

本目录保存 V3.5-15 使用的独立 V3.4 bit-exact Oracle。它只读取本仓库的
`03_verification/output/canonical_matrices.json`，不调用 RTL、legacy
`ref_model.py` 或 golden 文件。

文件：

- `v34_rtl_bitexact.py`：主变换与二维 stage16/low10 Oracle；
- `oracle_common.py`：canonical 数据加载和矩阵访问；
- `operator_math.py`：纯矩阵算子辅助模型。

这些文件是冻结参考，只允许通过 Git 版本更新，不得由 RTL 输出反向生成。
