VVC ITS 仿真运行指南
================================

工程路径: Hakimi_Huawei_Case1_VVC_ITS

环境要求
--------
- ModelSim SE-64 10.6e (或更高版本)
- Vivado 2025.2 (用于 02_rtl/synth 中的综合/实现/PPA 报告复现)
- 可用的 Vivado XPM 库 (仅 run_500_singleclk_synthesis_define.do 抽样仿真需要；脚本支持自动搜索常见安装路径，也可手动设置环境变量)
- Windows 10/11

目录结构
--------
  01_reports/          报告文档 (PPA/技术/验证)
  02_rtl/rtl/          RTL 设计源码 + ROM 初始化文件
  02_rtl/synth/        综合脚本/约束/报告
  03_verification/tb/  Testbench + 测试向量
  03_verification/sim/ 仿真 DO 脚本 + 日志
  04_waveforms/        波形截图

仿真入口 (ModelSim 命令行)
---------------------------

打开终端，进入仿真目录后执行:

  cd 03_verification/sim

1. 主仿真 — its_top_500_singleclk (1539 测试用例，推荐)
   vsim -c -do "do run_500_singleclk.do"

2. Core 500 FIFO 接口仿真 (94 用例，快速回归)
   vsim -c -do "do run_core_500.do"

3. SYNTHESIS 条件编译仿真 (需 Vivado XPM，仅抽样回归)
   vsim -c -do "do run_500_singleclk_synthesis_define.do"

4. 赛题提交入口 its_top.v 接口兼容回归 (1444 用例)
   vsim -c -do "do run.do"

一键运行脚本 (PowerShell)
--------------------------

在 03_verification/sim 目录下:

  powershell -ExecutionPolicy Bypass -File run_from_package.ps1 -Mode singleclk

可选 Mode 参数:
  singleclk  — 主仿真 (默认)
  core       — Core 500 仿真
  top        — its_top.v 接口兼容回归
  synthesis  — SYNTHESIS 条件编译仿真
  all        — 全部依次运行

也可以用 .bat 包装:
  run_from_package.bat singleclk

仿真说明
--------
- run_500_singleclk.do:
  编译 its_top_500_singleclk + wrapper/FIFO 等全部 RTL
  使用 SINGLECLK_SUBMISSION 模式 (单时钟域，功能回归仿真时钟 clk=100MHz)
  运行 1539 条测试: DCT2/DCT8/DST7/LFNST/边界/背压/连续/重叠
  说明: 100MHz 仅用于功能回归仿真以缩短运行时间；500MHz 达标依据见 02_rtl/synth 中的 Vivado 2025.2 实现报告

- run_core_500.do:
  编译 its_core_500 + 子模块 + its_core_500_tb
  验证 FIFO 接口 (cmd/input/output) 与 golden 的 bit-exact 一致性

- run_500_singleclk_synthesis_define.do:
  编译时加上 +define+SYNTHESIS (BRAM→XPM, 管线深度调整)
  脚本会优先读取 VIVADO_XPM_DIR；若未设置，则继续尝试 VIVADO_HOME / XILINX_VIVADO 和常见安装路径
  示例:
    set VIVADO_XPM_DIR=D:/AMDDesignTools/2025.2/Vivado/data/ip/xpm

- run.do:
  编译赛题提交入口 its_top.v + its_tb.v
  对应接口兼容回归 1444/1444 PASS；详细结果见 03_verification/sim/logs/regression_run.log

ROM 初始化文件
--------------
仿真脚本会自动将以下文件复制到仿真工作目录:
  rom_coeffs.hex    — 主变换系数 ROM
  lfnst_coeffs.hex  — LFNST 系数 ROM

故障排查
--------
1. "vsim: command not found" → 确认 ModelSim 已安装并加入 PATH
2. "Error: XPM library not found" → 设置 VIVADO_XPM_DIR，或确认 Vivado 安装路径可被脚本自动识别
3. "Module not found" → 检查是否在 03_verification/sim 目录下运行

最后更新: 2026-07-07
