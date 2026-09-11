# V35-14 Step 12A-R2.2 Temporal & Protocol Closure

Status: **PASS**

本版本在现有总工程目录内完成，不修改 V3.4、R4C RTL、canonical、ROM 或 golden。

## 已验证内容

- 唯一的 `IntegrationModel.tick()` 推进输入、V/H phase、唯一 R4C、存储器、ResultMemory 和输出反压。
- H kernel group 在同一 cycle 写入 stage16 monitor 和 ResultMemory，禁止历史事件回放。
- ResultMemory 采用 1-cycle synchronous response + one-beat holding；只有 output fire 才消费数据。
- 独立 expected 来自冻结的 `ITS_STUDY_V35_ORACLE/v34_rtl_bitexact.py`。
- 从真实事件轨迹推导并检查：每个 vector 16 groups、group II=1、V/H steady-state vector II=16、first/last、tag 和 H→result 同周期关系。
- 输入握手显式检查 `data_fire=vld&&req`、`end_fire=end&&req`，并覆盖 req 低/恢复、cache full/recovery、同拍 end、独立 end、重复/倒序/越界地址。
- 额外运行完整 64×64 integration 的 vector-ID wrap：`FFFE→FFFF→0000→0001`，共 2048 个 kernel group，逐事件通过。
- 四 bank memory 使用每 bank 一读一写端口，read latency=1；epoch wrap 物理清除四个 tag bank，共 1024 cycles。
- 负向 mutation 进入总 gate；任意 mutation 未捕获则整体 FAIL。

## 本次结果

- 4 个单 TU case：PASS；每个 2048 个 kernel group 被实际检查。
- 双 TU：4096 个 kernel group 被实际检查，2048 次 result write / 2048 次 output fire，PASS。
- wrap integration case：2048 个 kernel group，`vector_ii=[16]`、`group_ii=[1]`，PASS。
- `vector_ii=[16]`、`group_ii=[1]` 均由 trace 推导，不是报告常量。
- 输入协议、epoch wrap、vector ID wrap、12 项负向测试：全部 PASS。
- ModelSim/Vivado/Step12B RTL：本步骤不运行。

## 边界

本报告只证明 64×64 DCT2×DCT2、LFNST off 的可执行周期/协议模型。它不代表完整 ITS Core 已集成，也不代表完整 Core 已达到 500 MHz。下一步才是 Step12B wrapper RTL。
