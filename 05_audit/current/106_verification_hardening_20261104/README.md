# 验证基础设施进展快照

源代码基线42009da；生产RTL未改。新增normal/SYNTHESIS测试、既有42仿真、667参考用例/352896值通过；19项自检及4项CLI检查通过。

snapshot保存本机实际执行脚本、TB、向量、门禁凭证与台账；successful_run_logs.zip保存成功运行日志。脚本仍使用原本机工作区路径，凭证中的绝对路径记录原运行环境；此快照不是已经验证过的跨机器一键入口。生产仓库原FUNCTIONAL_REPLAY.md仍为便携回归入口。

本次没有新做布局布线。沿用相同RTL的104历史名义时序证据，WNS +0.006ns/WHS +0.011ns。set/reset、系数裁剪、首次读取配对仍OPEN；Q01-Q06与official_equivalence=NOT_PROVEN保持不变。

标签仅标记验证进展，不表示全部问题闭环。当前说明以REPAIR_SUMMARY.md和修正版台账为准。
