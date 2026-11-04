# 当前功能要求与验证对应表

基线：4a71d7f，wrapper 原始 SHA-256 903cd9b2526447d774332d57a6511f952f7cd6f16d14e7e78059357d06a4bc87。
本轮扩充验证与复现资料，生产 RTL 不变。功能结论分为“工程契约验证通过”和“官方规则尚待确认”。

## 资料与解释

- 正文：仓库根目录《第九届中国研究生创芯大赛-华为赛题1.docx》，题目要求1–5、9–10。
- 附件：仓库根目录《华为附件.docx》，LFNST 矩阵/布局和接口说明。
- 用户提供的专家答疑记录：`05_audit/current/27/step12d_engineering/OFFICIAL_EXPERT_QA_EVIDENCE.json`。它是用户转述的来源记录，不冒充正式规范条款。
- `LEGAL_TRANSFORM_MATRIX.json` 以独立轴组合扩展到169个 LFNST-off 配置，包含正文明确列出的 DCT2 25种形状、DCT8 16种、DST7 16种同类型配置；混合 H/V 类型的完整官方子集仍待澄清。
- LFNST-on 覆盖25种形状、4个 set、2个有效 idx，共200个配置，接主变换 DCT2/DCT2。上述169+200=369是配置覆盖，不是全部可能输入数据。

## 功能追踪

| ID | 要求 | 实现/规则 | 测试与判定 |
|---|---|---|---|
| F01 | DCT2/DCT8/DST7 与矩形 TU | 每轴类型独立；长度4/8/16/32，DCT2另有64 | Gate-C完整369配置；新增169个LFNST-off signed16极值场景；逐点比较 |
| F02 | LFNST 后做 DCT2 | 16/48点、set0..3、idx1/2、4x4/三块4x4布局 | bounded_lfnst_engine_tb 1088向量、布局检查、200个LFNST-on配置；数值规则见审计 |
| F03 | 稀疏光栅输入 | 地址为完整TU raster index；req&&vld接收，未写点为0 | 输入间隙、零TU、支持区边界、dirty→fresh形状切换与极值输入 |
| F04 | 主变换四点分组 | group接受与写回四lane事务，不将端到端平均吞吐视作每拍计算指标 | P4/throughput/full-throughput/credit TB，检查分组节拍及数据 |
| F05 | 一拍4点、光栅输出 | 每有效beat为4个signed10；低10位为光栅最先点 | adapter、numeric、full_spatial TB逐beat比较；总beat数=W*H/4 |
| F06 | 末拍done与暂停 | req=0时vld/done=0；done仅在最后有效输出拍 | protocol TB、full_spatial_contract混合TU边界/末拍暂停 |
| F07 | 提前独立end | 最早尚未接受end的已接收TU；描述符级/slot级保存 | C05/C06/C08c/C10/C11c/C12/C13；旧冻结RTL应出现预期失败 |
| F08 | 末数据同拍end | 最后一笔写入提交后才READY | C02/C03；S03、S04跨TU提交边界 |
| F09 | 队列同拍弹出/入队/end | 旧项转移、新项初始化、end归属互不混淆 | S01/S02，队列满、已结束队首和未结束第二项 |
| F10 | TU输出保持接收顺序 | 前TU末写入pending时不绑定年轻TU，避免scrub遮挡计算与slot0抢先 | S03：A=0、B=511、C=0；移除屏障后B/C各4个错误beat，恢复后通过 |
| F11 | 屏障确实触发且能恢复 | pending时bind_event=0，提交后可绑定；队列深度2复用 | S03记录blocked=1；S04记录resumed=1并检查后续B/C/D/E输出 |
| F12 | 复位不污染后续TU | 清归属、描述符、valid/control；不依赖清RAM payload | C04/C11a、fifo_payload_reset、protocol reset_inflight、full_spatial_contract四个阶段复位 |
| F13 | 完整空间输出而非输入支撑高度 | V输出H行，H输出W点；频率支撑只约束输入项 | 64x64 DC=512全4096点为16；原空间裁剪版本应被负控检出 |
| F14 | signed16极值/舍入/饱和 | 当前profile固定V shift7/H shift10，逐阶段signed16裁剪，最后SAT10 | Gate-B boundary/random、LFNST极值/密集向量、169个新增极值配置 |
| F15 | 参考与规则独立性边界 | native编译VTM24.0主变换原语；参数及LFNST预处理由工程层提供 | 667用例/352896原生主变换输出值；不能据此声称官方整链路等价 |

F01–F14 的“通过”均指选定工程契约。正式结果见105审计目录及统一入口生成的 FUNCTIONAL_CLOSURE.json。
F15 及位宽、定标等未确认项在 SPEC_CLARIFICATIONS.md 中保持 OPEN。

## 验证缺口处理

本轮补入原缺失的S01–S04并增加169个全signed16范围场景；复用既有覆盖，避免用重复测试堆数量。
总仿真耗时相同不能证明分支未执行；以明确前置状态、blocked/resumed标记和删除屏障负控为判据。
不把配置覆盖、条件覆盖或有限随机数据提升为全部输入空间的形式证明。
