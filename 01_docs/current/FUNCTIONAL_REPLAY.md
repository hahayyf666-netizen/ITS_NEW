# 功能回归入口

在仓库根目录运行（Python 3、PowerShell 7、ModelSim、C++17编译器）：

```powershell
python 03_verification/step12d_engineering/run_functional_closure.py --evidence-dir C:/temp/its_functional_run --modelsim-bin D:/software/Modelsim/win64 --license-file D:/software/Modelsim/LICENSE.TXT --compiler D:/AMDDesignTools/2025.2/tps/mingw/10.0.0/win64.o/nt/bin/g++.exe
```

输出目录必须为新目录。工具路径也可通过 ITS_MODELSIM_BIN、MGLS_LICENSE_FILE/LM_LICENSE_FILE、ITS_CXX设置。
license仅作为工具路径使用，脚本不读取或归档其内容。入口不启动物理实现。

阶段：

1. 从本仓库编译原19项与三个supplemental TB，在normal/SYNTHESIS下各执行23个正向用例。
2. 在输出目录生成删除绑定屏障的临时mutant；S03须出现B/C乱序，S04须失败。编译失败不算检出。
3. 用仓库保存的旧冻结fixture重放19项，核对8过/11项预期失败。
4. 运行既有42个仿真，现场编译VTM原语、生成667个参考用例、向量和负控，并检查原空间缺陷能被检出。
5. 运行前后核对RTL、TB、脚本、profile、ROM和参考依赖指纹，保存全部日志与FUNCTIONAL_CLOSURE.json。

各命令有超时。失败返回非零并记录具体阶段；不以vsim退出或非零退出码本身判定负控成功。
诊断选项 --directed-only 只跑协议/顺序与对应负控，结果明确为PASS_DIRECTED_ONLY，不表示完整回归通过。

## 必要仓库内容

02_rtl/rtl，03_verification/tb，03_verification/step12d_engineering，03_verification/regression_baseline，
03_verification/output/canonical_matrices.json，04_reference/VTM/source/Lib/CommonLib，
05_audit/current/27/step12d_engineering/*.json及profile目录。
默认完整clone具备这些内容；sparse checkout需包含它们。历史日志和06_archive不参与功能计算。
测试运行只需当前checkout内的源和数据，不引用其他本地工程或预编译参考exe。

结论：PASS_FUNCTIONAL_ENGINEERING_CONTRACT 表示所选规则与覆盖内通过；official_closure仍须结合待澄清项判断。
