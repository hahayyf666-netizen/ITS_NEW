# V3.5 Step 12B：64×64 DCT2×DCT2 wrapper 功能合同

状态：准备实现，尚未宣称 RTL 或 500 MHz 通过。V3.5-16、R4C 和 P1-A/P1-B/P1.5/P2F 证据只读冻结。

## 范围

本阶段只实现一个 `64×64` TU，Stage-1 vertical 使用 DCT2-64，Stage-2 horizontal 使用 DCT2-64，LFNST 关闭。R4C `p2f_dct2_64_b1_step102.sv` 只实例化一份，按 V/H 时分复用；不得修改 R4C、canonical matrix、ROM 或 V3.5-16 Oracle。

“一维 P4”指 R4C 在一个 64 点 invocation 内每拍产生 4 个完整 stage16 结果，group II=1、vector II=16；“二维端到端吞吐”另行统计，不能把二者混写成官方性能已闭合。

## 输入协议与 descriptor

- 官方 `it_info` 为 22 bit；本 wrapper 不重新解释或缩窄该字段。
- `it_info_vld && !desc_full` 时把 descriptor 放入深度 2 FIFO，并绑定一个空闲 A/B input cache；`desc_full && it_info_vld` 是非法激励，必须 assertion/仿真报错且不得覆盖已有 descriptor。
- descriptor 被接受的周期不接收首个数据；首个 `data_fire` 从下一周期开始。`data_fire = it_data_in_vld && it_data_in_req`，`end_fire = it_data_end && it_data_in_req`。
- 官方 nominal stream 只发送非零点且保持 TU 光栅地址顺序；wrapper 允许已发送地址值为 0，未发送地址按 0。地址必须单调递增、范围 0..4095；重复/倒序/提前 end 为协议错误。
- 收到当前 TU 的 `end_fire` 后才能置 READY 并启动 vertical。两个 cache 都不可接收时 `it_data_in_req=0`；scrubbing cache 不得阻塞另一个 FREE cache 的 admission。

## 存储和时序

- A/B input cache：每个 4 bank、每 bank 1 写口/1 读口、同步读延迟 1；`bank=(row[1:0] XOR col[1:0])`，`addr=row*16+(col>>2)` 作为候选并由周期检查器逐访问验证；4 点读/写必须无同 bank 冲突。
- staging A/B：两个 `64×16 bit` vector buffer。每 16 个周期从 cache/intermediate 组装一个 64 点向量；最后一次写入后下一周期才 `vector_start`。V/H 不并行，故同一对 staging 可按 ownership 复用。
- 单一 intermediate memory 只服务一个 TU：`FREE → V_RUNNING → WAITING_FOR_H → H_RUNNING → FREE`。V 输出以 16 bit stage16 写回；V 未完成不得启动 H。TU0 的 H 若因结果容量阻塞，后续 TU 只能缓存，不能让另一个 TU 覆盖 intermediate。
- intermediate：4 bank、每 bank 1 写口/1 读口、同步读延迟 1；不依赖同地址 read-during-write（结构上禁止同拍同地址读写）。
- ResultMemory：1024 个 40-bit beat，1 写口+1 读口，读请求 C、响应 C+1；响应进入两级 elastic output（hold+skid），`out_valid` 在 `req=0` 时数据稳定，只有 `output_fire = out_valid && it_data_out_req` 才推进读指针并减少占用。结果写入必须在 H kernel group 到达的同一全局周期完成：stage16 shadow 与 low10 result 同拍写入；禁止事后 replay。

## R4C 连接和标签

R4C `result_accept` 永远绑定 1。每个完整向量必须在 `vector_start` 前稳定交给 R4C；R4C 输出的 `result_stage16_flat` 作为 V/H stage16 数据，H 阶段再取 `result_final10_flat` 写 ResultMemory。全局标签为 `{tu_id, phase, vector_index, group, vector_id}`；`vector_id` 是 16-bit 可回绕显示标签，内部唯一身份使用永久 invocation serial。R4C latency 必须从冻结 RTL 仿真/trace 实测后写入模型，不得凭经验硬编码。

## 测试门禁

必须有唯一顶层 `IntegrationModel.tick()` 和 RTL 同口径事件 trace，覆盖：normal/SYNTHESIS、zero/sparse/alternating/random、same-cycle data+end、standalone end、地址边界、A/B full/recovery、epoch scrub、vector-id wrap、two-TU 长反压。每个 negative mutation 未被捕获则整体 FAIL。

退出条件分两级：

1. `v3.5-17`：RTL 功能、协议、stage16/final10、事件/标签逐周期对拍通过；不代表 500 MHz。
2. `v3.5-18`：wrapper 在真实 RAM 推断和 2.000 ns post-route 下 WNS/TNS/WHS/THS 全通过后再冻结。

报告必须分别给出 `1D kernel=4 points/cycle`、`output burst=4 final points/cycle`、以及单 R4C 二维等效吞吐；不把 output 宽度替代计算吞吐。
