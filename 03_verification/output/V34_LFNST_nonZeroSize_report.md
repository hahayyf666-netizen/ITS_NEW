# V3.4 LFNST nonZeroSize 修复报告

## 基线

- 基线包：`ITS_STUDY_V33_FUNCTIONAL_PASS_2026-08-08_SELF_CONTAINED.zip`
- 基线包 SHA-256：`390FC7BC7D9D58A9CFF751DBFDF7BAAA591B6088EE648A3A97B65D31517A3E64`
- 工作副本：`D:\Workspace\ITS_STUDY_V34_LFNST_FIX`
- 历史目录 `D:\Workspace\ITS_STUDY` 未作为数据源，活动代码无运行时引用。

## 已完成修改

- 主变换保持 V3.3 的 `C^T*x`，未修改主变换 ROM、canonical 矩阵或地址映射。
- LFNST保持附件定义的 `M*x`，未转置。
- `its_lfnst.v` 增加启动时锁存的 `mac_last_col`：精确4x4/8x8为7，其他尺寸为15。
- LFNST LOAD阶段的16项输入、`pf_total=nTrs*16`预取和ROM行步长保持不变。
- `ref_model.py`显式按`nonzero_size`累计8或16项。
- `fix_lfnst_golden.py`在V3.4中fail-closed，禁止从RTL输出反写golden。
- 新增独立Oracle测试和命名LFNST golden重建脚本。

## 证据

- 独立LFNST Oracle + ref_model交叉检查：680项 PASS。
- `test_ref_model_onehot.py`：65 PASS，0 FAIL。
- `audit_matrices.py`：AUDIT_PASS。
- `audit_test_vectors.py`：3207文件、1377回归用例通过。
- 两次staging向量生成：2759/2759文件SHA完全一致。
- 测试向量总数保持3207；新增/删除0。
- 相对V3.3仅176个golden变化：144个`case_*`和32个命名LFNST golden。
- 主变换/输出协议/FIFO相关文件哈希保持V3.3不变。

## RTL 与实现验收

- 单时钟 contest-top 回归：`1539/1539 PASS`，0 failed，0 warnings，见
  `_v34_audit/v34_singleclk.log`。
- 双时钟 contest-top 回归：`1539/1539 PASS`，0 failed，0 warnings，见
  `_v34_audit/v34_contest_top_dualclock.log`。
- 修正后的 core 级回归：`94/94 PASS`，0 failed，0 warnings，见
  `_v34_audit/v34_core_500_final.log`。该 testbench 同步修正了旧 trType 映射、
  深度16输入 FIFO 的流式装载以及过时的 LFNST 文件名；这些是验证环境修正，
  不改变 DUT。
- `fix_lfnst_golden.py` fail-closed：禁止从 RTL 输出反写 golden。
- Vivado OOC post-route（xcku5p-ffvb676-2-e，2.000 ns）：备用
  `Explore + AggressiveExplore` 策略通过，WNS=`+0.024 ns`、TNS=`0`、
  WHS=`+0.004 ns`、THS=`0`，setup/hold 均 0 failing，见
  `_v34_audit/vivado/v34_alt_timing_summary.rpt`。
- 同一 RTL 的 `ExtraNetDelay_low` 策略得到 WNS=`-0.003 ns`；该结果保留作为
  策略敏感性记录，冻结采用通过的备用策略 DCP，不宣称所有实现策略都闭合。

V3.4 当前状态：`FUNCTIONAL_PASS / OOC_500MHz_PASS`。
