# 当前功能复现证据

本轮不修改生产RTL。工程契约回归通过，官方等价性仍为 NOT_PROVEN。
每种模式23项正向定向用例、42个既有仿真、667个原生主变换参考用例/352896值通过。
原498参考用例保留，新增169个LFNST-off signed16极值配置。

S03在移除绑定屏障后出现B/C乱序；S04同样检出屏障缺失。编译失败不作为负控检出。
旧冻结fixture的19项结果为8过/11个预期失败；原空间输出缺陷也被独立负控检出。

功能要求、数值依据、官方待澄清项、运行命令分别见01_docs/current下的
FUNCTIONAL_REQUIREMENTS.md、NUMERIC_BINDING_AUDIT.md、SPEC_CLARIFICATIONS.md、FUNCTIONAL_REPLAY.md。
functional_logs.zip包含本次编译/运行/参考对照日志、生成的原生输入输出和结果JSON；不含工具、许可证或预编译参考exe。
FUNCTIONAL_CLOSURE.json中的log路径相对于压缩包根目录。

环境限制：GitHub partial clone曾返回HTTP400；本次使用新的本地Git checkout，并从已有对象缓存补全必要对象。
19个生产RTL/ROM/参考输入均核对到已发布Git对象；程序运行不引用其他工作区源文件、向量或参考exe。
这不冒充在另一台机器上完成的验证。

当前物理证据仍在104目录；本次功能测试扩充不改变其生产RTL。

最终复现已从本地提交0157697的新干净Git检出运行，全部阶段通过；运行前后源码工作区均干净。参见CLEAN_REPLAY.json。当前functional_logs.zip和FUNCTIONAL_CLOSURE.json对应这次复现，NUMERIC_DISCRIMINATORS.json记录定标歧义的原生数值例子。
