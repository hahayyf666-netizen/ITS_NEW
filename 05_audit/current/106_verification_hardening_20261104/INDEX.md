# 当前复核入口

生产仓库基线 42009da；本轮只修复 closure_audit 下的验收脚本和说明，未修改生产 RTL。默认 FINAL_SATURATE=1，official_equivalence=NOT_PROVEN。

## 当前有效入口

```powershell
pwsh -NoProfile -File closure_audit/run/run_all_closure.ps1
python closure_audit/gate/evidence_gate.py --selftest
python closure_audit/gate/evidence_gate.py --check
```

从 default-workspace 运行；脚本路径可用绝对路径。工具依赖为本机 ModelSim、Vivado、Python、PowerShell7、C++编译器。每次运行生成 run/runs/时间戳，保留所有历史运行（包括失败运行）。run/closure_run.json 是最近一次运行索引。

新入口先校验历史物理输入/报告身份，再对新增 P1/P2/P4 分别运行 normal/SYNTHESIS，随后调用生产仓库的完整功能回归。只有必需阶段全部 PASS、运行前后依赖未变化才返回完整 PASS。跳过阶段返回 INCOMPLETE/nonzero；执行错误或检查失败返回 FAIL/nonzero。

门禁 baseline_v2.json 绑定成功运行 receipt、输入依赖、实际工具身份与日志/JSON指纹。没有成功完整运行不能 --snapshot；修改 TB/参考/向量/入口会使功能证据过期；相关物理输入变化或报告不匹配会阻断历史物理匹配结论。该机制验证本地一致性，不防止恶意重签或重写代码。

稀疏检出缺少的历史物理约束从 HEAD Git 对象读取并校验，不声称当前目录可直接运行物理流程。功能回归在全新运行目录显式准备并校验必需 ROM；原物理 Tcl 的直接启动入口仍需准备相对路径。

## 已纠正

- DIRTY、SKIP、零退出但没有完成标记不能误放行。
- 原“9/9自检”不再作为依据；见 run/SELFTEST.json 的负向结果。
- 完整综合打印166 W，8-7137达到100次打印上限；不能将154条记为已豁免。
- 104历史综合日志明确记录ROM读取成功；撤回“历史物理网表缺ROM”。
- DSP=320不能否证系数连接错误；8-3936恢复为OPEN。
- 被移除寄存器不自动认定安全死代码；写命令影子寄存器在断言中有读取。
- P4正则扫描不证明控制复位完整性；===1替换不关闭X风险；关闭条件已更正。

## 仍开放

8-7137、8-3936及未逐项解释的优化告警；P4首次读取/valid配对路径；Q01–Q06官方规则。P2是同源wrapper双实例集成，不代表生产SAT10顶层已有LOW10外部选择端口。P1目标状态观察和有限数据测试不构成全部调度组合证明。

P0、覆盖表、早期P1/P2/P4结果保存在各自目录；本次没有重做P0或把正则静态审计提升为形式证明。旧 INDEX_before_review.md 仅作历史记录，其中被本页撤回的结论无效。

完整回归 PASS 代表所选工程规则与本次测试通过；不表示lint全部关闭、官方等价成立或获得新的物理实现证明。
