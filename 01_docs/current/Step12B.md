# V3.5 Step 12B：64×64 DCT2×DCT2 wrapper 功能合同

状态：Step12B RTL prototype / functional closure in progress；尚未宣称 v3.5-17、完整 RTL gate 或 500 MHz 通过。V3.5-16、R4C 和 P1-A/P1-B/P1.5/P2F 证据只读冻结。

## 范围

本阶段只实现一个 `64×64` TU，Stage-1 vertical 使用 DCT2-64，Stage-2 horizontal 使用 DCT2-64，LFNST 关闭。R4C `p2f_dct2_64_b1_step102.sv` 只实例化一份，按 V/H 时分复用；不得修改 R4C、canonical matrix、ROM 或 V3.5-16 Oracle。

“一维 P4”指 R4C 在一个 64 点 invocation 内每拍产生 4 个完整 stage16 结果，group II=1、vector II=16；“二维端到端吞吐”另行统计，不能把二者混写成官方性能已闭合。

## 输入协议与 descriptor

- 官方 `it_info` 为 22 bit；本 wrapper 不重新解释或缩窄该字段。
- `it_info_vld && !desc_full` 时把 descriptor 放入深度 2 FIFO，并绑定一个空闲 A/B input cache；`desc_full && it_info_vld` 是非法激励，必须 assertion/仿真报错且不得覆盖已有 descriptor。
- descriptor 被接受的周期不接收首个数据；首个 `data_fire` 从下一周期开始。`data_fire = it_data_in_vld && it_data_in_req`，`end_fire = it_data_end && it_data_in_req`。
- 官方 nominal stream 只发送非零点且保持 TU 光栅地址顺序；wrapper 允许已发送地址值为 0，未发送地址按 0。地址必须单调递增、范围 0..4095；重复/倒序/提前 end 为协议错误。
- 收到当前 TU 的 `end_fire` 后才能置 READY 并启动 vertical。两个 cache 都不可接收时 `it_data_in_req=0`；scrubbing cache 不得阻塞另一个 FREE cache 的 admission。

`it_info` 始终按题面保留完整 22 bit。Step12B 当前只接受 `width=64`、`height=64`、`tr_type_hor=DCT2`、`tr_type_ver=DCT2`、`lfnst_idx=0`；`lfnst_tr_set_idx` 在 `lfnst_idx=0` 时是本阶段工程合同中的 don't-care，只保存原始值，不强制为 0。其他 descriptor 必须报协议错误且不得入队。descriptor FIFO 可以排队多个 descriptor，但数据端口没有 TU ID，因此任何时刻只能有一个 `active_input_tu`：FIFO head 绑定一个 FREE cache 后，该 cache 独占后续 `data_fire/end_fire`，直到该 TU 的 `end_fire`；随后才允许下一个 descriptor 成为 active。不能让两个 cache 交错接收同一条输入流。`desc_full` 按当前时钟沿前占用状态判断；`desc_full && it_info_vld` 是非法上游激励，必须 assertion/error，不能静默丢弃。

`it_done` 冻结为 TU 完成脉冲：最后一个 1024th result beat 被 `output_fire` 接受的时钟沿置位，保持一个周期后清零；每个 TU 恰好一个 pulse，未发生最后 `output_fire` 时禁止 `it_done`。

## 存储和时序

- A/B input cache：每个 4 bank、每 bank 1 写口/1 读口、同步读延迟 1；`bank=(row[1:0] XOR col[1:0])`，`addr=row*16+(col>>2)` 作为候选并由周期检查器逐访问验证；4 点读/写必须无同 bank 冲突。
- staging A/B：两个 `64×16 bit` vector buffer。每 16 个周期从 cache/intermediate 组装一个 64 点向量；最后一次写入后下一周期才 `vector_start`。V/H 不并行，故同一对 staging 可按 ownership 复用。
- 单一 intermediate memory 只服务一个 TU：`FREE → V_RUNNING → WAITING_FOR_H → H_RUNNING → FREE`。V 输出以 16 bit stage16 写回；V 未完成不得启动 H。TU0 的 H 若因结果容量阻塞，后续 TU 只能缓存，不能让另一个 TU 覆盖 intermediate。
- intermediate：4 bank、每 bank 1 写口/1 读口、同步读延迟 1；不依赖同地址 read-during-write（结构上禁止同拍同地址读写）。
- ResultMemory：1024 个 40-bit beat，1 写口+1 读口，读请求 C、响应 C+1；内部响应进入两级 elastic output（hold+skid）。官方接口规定 `it_data_out_req=0` 时外部 `it_data_out_vld=0`，但内部 hold/skid 数据和 valid 状态必须保持稳定；只有 `output_fire = result_hold_valid && it_data_out_req` 才推进读指针并减少占用。结果写入必须在 H kernel group 到达的同一全局周期完成：stage16 shadow 与 low10 result 同拍写入；禁止事后 replay。

### ResultMemory 状态不变量

当前单 ResultMemory 只允许一个 TU 持有 owner。H admission 时一次性预留整个 TU 的 1024 个 result group；在该 TU 完全产生、发起读取并输出完成前，不允许另一个 TU 的 H 阶段复用地址空间。

```text
0 <= reserved <= 1024
0 <= occupied <= 1024
reserved + occupied <= 1024

0 <= consumed <= issued <= produced <= 1024
produced = 1024 - reserved
occupied = produced - consumed
```

每个 `result_write` 必须执行 `reserved-- / occupied++ / produced++`；每个 `result_read_request` 执行 `issued++`；每个真正的 `output_fire` 执行 `occupied-- / consumed++`。`result_addr` 保持 10 bit，所有计数器使用至少 11 bit。所有计数器必须通过统一 next-state 计算，禁止多个时序分支同时写同一寄存器。还必须满足：

```text
issued - consumed = RAM pending + hold/skid 中尚未消费的 beat 数
```

只有 `reserved=0`、`occupied=0`、`produced=issued=consumed=1024` 且 pending/hold/skid 全空时，才能释放 ResultMemory owner。

## R4C 连接和标签

R4C `result_accept` 永远绑定 1。每个完整向量必须在 `vector_start` 前稳定交给 R4C；R4C 输出的 `result_stage16_flat` 作为 V/H stage16 数据，H 阶段再取 `result_final10_flat` 写 ResultMemory。全局标签为 `{tu_id, phase, vector_index, group, vector_id}`；`vector_id` 是 16-bit 可回绕显示标签，内部唯一身份使用永久 invocation serial。RTL trace 的 cycle 定义冻结为“第 C 个上升沿发生且该时刻 NBA 更新完成后的可观察状态”；Python、normal ModelSim、SYNTHESIS ModelSim 使用同一采样定义。所有事件只允许使用一个全局锚点，禁止按事件类型、TU 或编译模式自由平移。R4C latency 必须从冻结 RTL 仿真/trace 实测后写入模型，不得凭经验硬编码。

## 测试门禁

必须有唯一顶层 `IntegrationModel.tick()` 和 RTL 同口径事件 trace，覆盖：normal/SYNTHESIS、zero/sparse/alternating/random、same-cycle data+end、standalone end、地址边界、A/B full/recovery、epoch scrub、vector-id wrap、two-TU 长反压。每个 negative mutation 未被捕获则整体 FAIL。

退出条件分两级：

1. `v3.5-17`：RTL 功能、协议、stage16/final10、事件/标签逐周期对拍通过；不代表 500 MHz。
2. `v3.5-18`：wrapper 在真实 RAM 推断和 2.000 ns post-route 下 WNS/TNS/WHS/THS 全通过后再冻结。

报告必须分别给出 `1D kernel=4 points/cycle`、`output burst=4 final points/cycle`、以及单 R4C 二维等效吞吐；不把 output 宽度替代计算吞吐。
