# V3.3 矩阵方向修正报告

> 日期：2026-08-08
> 基线：V3.2 冻结（未覆盖，`_v33_audit/v32_freeze_manifest.json`）
> 工作副本：ITS_STUDY_V33_ORIENTATION_FIX
> 目标：修正逆变换方向（T·x → Tᵀ·x），区分 source_kernel / inverse_operator

---

## 一、根因确认

### 发现（V4 审计 + VTM 验证）

- 当前 ref_model/RTL 计算 `y = T·x`（前向矩阵直接乘）
- VTM 快速逆变换计算 `y = Tᵀ·x`（数学正确逆变换）
- 对非对称变换（DCT2、DST7），两者**逐点不同**
- DCT8 对称（Tᵀ=T）不受影响
- 问题陈述矛盾：名称"反变换"=Tᵀ，正文"时域→频域"=T

### 华为公式确认

```
DCT2:   A_N[i][j] = C64[j * (64/N)][i]
DST7:   A_N[i][j] = C_N[j][i]    (C_N = forward kernel)
DCT8:   A_N[i][j] = C_N[j][i]    (对称，转置后数值不变)
```

其中 C 是附件/VTM 的 forward kernel，A 是 RTL 应执行的 inverse operator。

---

## 二、canonical 数据结构分层

```json
"transforms": {
  "0": {"name": "DCT2",
        "source_kernel":  {"4": [...], ...},   // forward C
        "inverse_operator": {"4": [...], ...}   // A = C^T，RTL 执行
  }
}
```

schema_version: 1 → 2
不再用单一 matrix 字段表示两种方向。

---

## 三、各矩阵验证

### 3.1 与 VTM fast inverse 逐点一致

对 13 个变换 ×（one-hot 全位置 + 随机 30 组）：

| 变换 | 4 | 8 | 16 | 32 | 64 |
|------|:--:|:--:|:--:|:--:|:--:|
| DCT2 | 0 | 0 | 0 | 0 | 0 |
| DST7 | 0 | 0 | 0 | 0 | — |
| DCT8 | 0 | 0 | 0 | 0 | — |

**全部 0 失配。ORIENTATION PASS。**

### 3.2 DCT2-4 one-hot 强制检查

```
输入 [1,0,0,0]，未缩放累加结果 = [64, 64, 64, 64]  ✅
（逆变换 one-hot e0 应为 C64 列0 = 全64）
```

### 3.3 audit_matrices PASS

- source_kernel 与 inverse_operator 均存在且维度正确
- 每个尺寸 A == C^T 验证通过
- 计数 5/4/4 + LFNST 16

### 3.4 DST7/DCT8 32×32 修复

旧四象限拼接错误删除，改用 VTM RomTr 完整矩阵（`_vtm_p32.py`）。
修复后 32×32 与 VTM fast inverse 逐点一致。

---

## 四、LFNST 方向审计（不转置）

**结论：LFNST 保持 M·x，不需要转置。**

下标证据：
- 附件公式：`y[i] = sum_j T[i][j]*x[j]`（i=输出行，j=输入列）= M·x
- VTM `invLfnstNxN`（TrQuant.cpp:294）：
  ```
  for j in 0..trSize:           // j = 输出索引
      for i in 0..zeroOutSize:  // i = 输入索引
          resi += src[i] * trMat[j*trSize+i]   // = M·x
  ```
- 当前 RTL its_lfnst.v 注释一致：`y[i] = clip3((sum_j T[i][j]*x[j] + 64)>>7)`

LFNST 的 lowFreqTransMatrix 本身即 inverse operator（附件直接定义），不同于主变换 transMatrix（需转置）。

---

## 五、ROM 重新生成

| 区域 | 变更项 | 说明 |
|------|:--:|------|
| DCT2 [0..5455] | 5216 | 全部尺寸方向转置 |
| DST7 [5456..6815] | 1281 | 全部尺寸方向转置 |
| DCT8 [6816..8175] | 496 | 仅 32×32 修复（4/8/16 对称不变） |
| 合计 | **6993/8176** | |

差异清单：`_v33_audit/rom_old_new_diff.txt`

---

## 六、回归结果

| 测试 | 结果 |
|------|:--:|
| 单时钟 | **1539/1539 PASS** |
| 双时钟 | **1539/1539 PASS** |
| contest top | **1539/1539 PASS** |
| onehot | 65 PASS |
| audit_matrices | PASS |

---

## 七、500MHz post-route

V3.3 最优策略（ExtraNetDelay_low）结果：

| 指标 | 值 |
|------|-----|
| **WNS** | **+0.067 ns** |
| TNS | 0.000 |
| WHS | +0.030 ns |
| THS | 0.000 |
| 时间 | 2026-08-08 18:14 |
| LUT / FF / DSP / BRAM | 1937 / 2182 / 5 / 14.5 |
| 功耗 | 0.684 W |

**方向修正后 500MHz 时序仍闭合（WNS 与 V3.2 相同）。**

---

## 八、后续

- 重新生成 golden 和测试向量（已完成，3207 文件）
- 输出每拍 4 点保持（V3.1 零气泡流水线未动）
- V4 计算吞吐原型在正确性修复后恢复

---
## 九、独立验收闭合（2026-08-08 补充）

### 独立审计（非自洽）
- audit_matrices.py 已修复：源文件缺失时 AUDIT_FAIL exit 1；适配 schema v2
- source_kernel 13 组与 VTM forward 逐元素 0 diff
- inverse_operator 13 组与 VTM fastInverse one-hot+随机 0 mismatch
- A == C^T 全部通过
- 日志：_v33_audit/v33_matrix_audit.log

### 三路回归独立日志
- v33_singleclk.log：1539/1539
- v33_dualclock.log：1539/1539
- v33_contest_top.log：1539/1539

### 生成器合并
- generate_canonical_v33.py 为唯一入口（VTM+附件源头提取，VTM 路径参数化）
- 旧 generate_canonical_matrices.py 输出 attachment_only_matrices.json，不再覆盖 canonical

### 冻结
- V33_freeze_manifest.json（44 项）
- ITS_STUDY_V33_FUNCTIONAL_PASS_2026-08-08.zip
- 500MHz post-route（当前 ROM）：WNS=+0.067ns

### 剩余
- 第 4 项计算核心严格吞吐仍未满足（每 N 拍才产生 4 个最终系数）
- 第 5 项输出接口已达无反压连续每拍 4 个最终系数（V3.1）

---
## 十、复现性修复（2026-08-09 补充）

### 修复前隐患
1. V33 副本内 `VTM/` 目录为空（0 文件）。审计脚本原靠 fallback 引用原工程
   `D:/Workspace/ITS_STUDY/VTM`，若原工程被删则无法复现审计。
2. `canonical_matrices.json` metadata 的 `vtm_romtr` 硬编码原工程绝对路径。
3. `audit_test_vectors.py`、`extract_attachment_matrices*.py` 硬编码
   `D:/Workspace/ITS_STUDY/...` 路径。
4. `_v4_audit/vtm_fast_transform_model.py` 仍读旧 schema（`['sizes']`），与 V3.3
   canonical（schema v2：source_kernel/inverse_operator）不兼容——重新独立运行
   audit 时直接 KeyError 崩溃。旧审计通过记录依赖旧 schema JSON，不可复现。
5. 冻结 ZIP `ITS_STUDY_V33_FUNCTIONAL_PASS_2026-08-08.zip` 不含 VTM 源码
   （仅空目录 `VTM/`），冻结清单 44 项中无任何 VTM 条目。

### 修复动作
1. 将 VTM（含 .git，commit 69f5112bae8c0f91f3cbc5ba0f44b58986080f16）完整复制进
   V33 副本 `VTM/`。
2. 全部脚本去除对原工程的绝对路径依赖：
   - `audit_matrices.py` / `audit_matrices_v33.py`：删除指向
     `D:/Workspace/ITS_STUDY/_v4_audit` 的 fallback，改为仅使用工程内相对路径，
     缺失即 FATAL exit 1。
   - `audit_test_vectors.py`：默认 test_vectors 路径改为相对 `../tb/test_vectors`。
   - `extract_attachment_matrices.py` / `extract_attachment_matrices_v2.py`：附件
     路径改为相对 `../../华为附件.docx`。
3. `vtm_fast_transform_model.py` 适配 schema v2：`get_canonical_matrix` 改读
   `transforms[tr]['source_kernel']`（forward C；fastInverse 内部按 C^T 使用，
   语义与内嵌 VTM_DST7/DCT8_P32 一致，已验证一致）。
4. `generate_canonical_v33.py` 重新生成 canonical：
   - 矩阵数据与冻结版逐元素 100% 一致（0 diff）；
   - metadata `vtm_romtr` 改为 V33 副本自引用路径；
   - SHA-256 变化仅由 metadata 路径字段引起。
5. 重跑完整验证链（全部在 V33 副本内独立完成）：
   - `audit_matrices.py` → AUDIT_PASS（source_kernel==VTM forward 13 组 0 diff；
     inverse_operator==VTM fastInverse 0 mismatch；A==C^T 全过）
   - `test_ref_model_onehot.py` → 65 PASS, 0 FAIL
   - `audit_test_vectors.py` → 3207 文件 PASS, 1377 回归 case OK
   - `ref_model.py` → exit 0
6. 三路回归在新环境重新运行（2026-08-09 00:17-00:19）：
   - `v33_recheck_contest_top.log`：1539/1539 PASS，0 failed，0 warnings
   - `v33_recheck_singleclk.log`：1539/1539 PASS，0 failed，0 warnings
   - `v33_recheck_dualclock.log`：1539/1539 PASS，0 failed，0 warnings
   - RTL/ROM/hex 未做任何修改（哈希不变）
7. 冻结清单 `V33_freeze_manifest.json` 扩至 801 项（含 VTM 754 个文件 + .git HEAD
   与分支 ref + 3 份新回归日志 + 全部脚本新哈希）。
8. 重建自包含冻结 ZIP：
   `ITS_STUDY_V33_FUNCTIONAL_PASS_2026-08-08_SELF_CONTAINED.zip`（约 101 MB）
   - 包含完整 VTM（752 文件 + .git）
   - 7 个修改后脚本/JSON/模型
   - 3 份新回归日志 + 更新后 manifest
   - 无重复条目；解压到全新目录独立运行 audit_matrices/onehot/audit_test_vectors
     全部通过（自包含性验证完成）
   - 原 ZIP `ITS_STUDY_V33_FUNCTIONAL_PASS_2026-08-08.zip` 保留未动

### 复现流程（任意机器）
```
python 03_verification/scripts/generate_canonical_v33.py   # 重新生成 canonical
python 03_verification/scripts/audit_matrices.py           # 独立矩阵审计
python 03_verification/scripts/test_ref_model_onehot.py    # one-hot 65 PASS
python -B 03_verification/scripts/audit_test_vectors.py    # 向量审计
# ModelSim（需 MGLS_LICENSE_FILE 指向 LICENSE.TXT）:
#   vsim -c -do "do run.do"                 # contest top
#   vsim -c -do "do run_500_singleclk.do"   # 单时钟
#   vsim -c -do "do run_dualclock.do"       # 双时钟
```
以上全部命令不依赖任何绝对路径，可在工程内任意位置运行。

---
## 十一、独立验收补完（2026-08-09）

### 1. 华为附件独立提取对比（补齐 1c）
audit_matrices.py 新增第 6 节，从华为附件独立重提取并逐元素对比：
- DCT2-64：附件 Col0to15+Col16to31+对称 → 0/4096 diffs
- DST7/DCT8 4/8/16：附件 nTbs 节 → 全部 0 diffs
- DST7/DCT8 32：附件仅提供 Col0to15/Col16to31（512 项），与 VTM RomTr 逐项
  d0=0 d1=0；完整 32×32 以 VTM 为准（附件四象限拼接法已证错误），0/1024 diffs
- LFNST：16 组全部 0 diffs
- 日志：_v33_audit/v33_matrix_audit_v2.log（AUDIT_PASS）

### 2. 命令/时间/哈希验收记录（补齐 2b）
V33_acceptance_record.json 记录：
- 三路回归命令 + workdir + 时间 + 结果 + 日志路径
- RTL/ROM/JSON 关键文件 SHA-256（its_core_500=04241edc…、
  rom_coeffs.hex、canonical_matrices.json=d4c497cf…）

### 3. Notion 修正（补齐 5/6/7）
- V3.3 标题改为「V3.3（方向修正候选版，独立验收待闭合）」
- 「仍待处理」明确写入：
  - 第 5 项：输出接口已达无反压连续每拍 4 个最终系数（V3.1）
  - 第 4 项：计算核心严格吞吐仍未满足（每 N 拍或更长时间才产生 4 个最终系数）
- LFNST 写回准确表述：nTrs=16 为左上 4×4 行优先；nTrs=48 为左上 4×8 加其下方
  4×4（均为行优先写回）


