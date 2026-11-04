# 验收基础设施修复结果

基线42009da，生产仓库工作区干净；没有修改RTL或默认SAT10配置，没有新做物理实现。official_equivalence=NOT_PROVEN。

## 修复

- 新Python runner替代原易误放行的PowerShell实现；PowerShell保留薄入口。
- 完整PASS要求所有必需阶段通过。SKIP返回INCOMPLETE，DIRTY/错误/缺失阶段阻断PASS。
- 每个工具调用有超时；仿真除退出码外，还核验完成标记、独立case数、失败计数、数据失配、目标状态命中和模拟器错误。
- 每个新增TB在normal/SYNTHESIS运行，之后调用仓库原完整回归（含已有缺陷负控）。
- 每轮使用独立工作目录，从生产仓库读取RTL并显式准备ROM；P2输入从纳入指纹的原始fixture复制。无需依赖旧编译库。
- 门禁纳入外部fixture、P2向量、入口、参考源/数据/profile/运行脚本；实际查询工具版本。Vivado本机-version返回1但输出完整固定版本横幅，版本检查明确按横幅核验并记录该退出码，不将此例外用于仿真验收。
- 门禁绑定成功运行receipt与产物指纹，变化返回非零。旧v1快照不再作为有效门禁依据。缺少成功完整运行不能自行snapshot为通过。
- 更正lint/P4台账和当前INDEX；保留旧INDEX为历史无效结论记录。

## 验证

19项解析/状态/门禁负向自检通过；4项真实CLI检查通过（正常0、依赖失效2、receipt失效2、恢复0）。
P1四场景、P2八TU双映射、P4五复位场景，在两种模式全部通过。
完整仓库回归PASS：14个定向运行记录（含负控）、既有42个仿真、667个原生主变换用例/352896值。运行前后全部登记依赖一致。

当前完整结果：run/closure_run.json；不可变本轮receipt位置由gate/baseline_v2.json记录。
命令：pwsh -NoProfile -File closure_audit/run/run_all_closure.ps1
自检：python closure_audit/gate/evidence_gate.py --selftest
门禁：python closure_audit/gate/evidence_gate.py --check

## 未结案与边界

8-7137、8-3936和未逐项解释的综合优化告警继续OPEN；P4首次读取/valid配对需补证明或定向检查。未把DSP数量提升为系数正确性证据，未把正则扫描提升为完整复位证明。
104历史物理日志确实成功加载ROM，原缺ROM指控撤回。原物理Tcl直接启动时的ROM相对路径准备仍是入口条件；本轮没有修改该Tcl或产生新的布局布线结果。
门禁只证明本地成功运行与当前依赖一致，不防恶意篡改；历史物理身份匹配不等于综合网表功能等价证明。稀疏目录缺少的物理XDC从HEAD对象读取核验，不能据此宣称该目录可直接启动物理流程。
所有新增修复保存在closure_audit外部工作目录，尚未纳入生产仓库或推送。
