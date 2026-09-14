# V3.5 Step 12B：64×64 DCT2×DCT2 wrapper 功能合同

状态：v3.5-17 historical functional closure；v3.5-17.2 verification-only timing/trace closure 已 PASS/冻结。Step12C-M6 implementation-only sweep 已 PASS/CLOSED：在同一 M6 postsynth DCP 上，`Performance_NetDelay_high` 首次运行与独立复跑均满足 2.000 ns post-route setup/hold 门禁。当前 v3.5-18 范围仅为 64×64 DCT2×DCT2、LFNST OFF、single-R4C wrapper 的 registered-neighbor OOC 性能基线；R4C、数学和官方接口不变。

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

`it_done` 冻结为 TU 完成脉冲：最后一个 1024th result beat 被 `output_fire` 接受的事务边沿置位，保持一个周期后清零；每个 TU 恰好一个 pulse，未发生最后 `output_fire` 时禁止 `it_done`。

## 存储和时序

- A/B input cache：每个 4 bank、每 bank 1 写口/1 读口；`bank=(row[1:0] XOR col[1:0])`，`addr=row*16+(col>>2)` 作为候选并由周期检查器逐访问验证；4 点读/写必须无同 bank 冲突。M3 当前 RTL 在 request 后增加 bank-response/data/tag/metadata 寄存器，因此 input-cache 的事务链为 `read_request C → bank response C+1 → lane_capture C+2`。
- staging A/B：两个 `64×16 bit` vector buffer。每 16 个周期从 cache/intermediate 组装一个 64 点向量；连续请求 `g0..g15 @ C..C+15`，对应 capture 为 `C+2..C+17`，`stage_full` 在 `C+17` 产生，随后最早 `C+18` 才允许 `vector_start`。下一向量的 `g0` 仍可在 `C+16` 请求，故稳态 vector II=16。V/H 不并行，故同一对 staging 可按 ownership 复用。
- 单一 intermediate memory 只服务一个 TU：`FREE → V_RUNNING → WAITING_FOR_H → H_RUNNING → FREE`。V 输出以 16 bit stage16 写回；V 未完成不得启动 H。TU0 的 H 若因结果容量阻塞，后续 TU 只能缓存，不能让另一个 TU 覆盖 intermediate。
- intermediate：4 个物理 bank、每 bank 1 写口/1 读口；Step12C-M3 在 request 侧固定 bank-local 地址/元数据，bank response 进入一级寄存器，之后只做小型 lane permutation；request 在 C，lane capture 在 C+2，结构上禁止同一 physical bank/address 同拍 read-during-write。V 写回增加一级 registered write-command，最后一条写命令提交后才允许 H admission。
- ResultMemory：1024 个 40-bit beat，1 写口+1 读口，读请求 C、响应 C+1；内部响应进入两级 elastic output（hold+skid）。官方接口规定 `it_data_out_req=0` 时外部 `it_data_out_vld=0`，但内部 hold/skid 数据和 valid 状态必须保持稳定；只有 `output_fire = result_hold_valid && it_data_out_req` 才推进读指针并减少占用。结果写入必须在 H kernel group 到达的同一全局周期完成：stage16 shadow 与 low10 result 同拍写入；禁止事后 replay。
- M4 input boundary：`data_fire` 在 C 接受后，按 cache/bank/address/data/epoch/last 锁存一个 bank-local write command；物理 input data/tag RAM 在 C+1 commit，接受和 commit 均保持 II=1。带 data 的 `end_fire` 只有在最后 command commit 后才能把 cache 置 `CACHE_READY`；standalone end 无 data write 时沿用已有直接完成语义。

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

R4C `result_accept` 永远绑定 1。每个完整向量必须在 `vector_start` 前稳定交给 R4C；R4C 输出的 `result_stage16_flat` 作为 V/H stage16 数据，H 阶段再取 `result_final10_flat` 写 ResultMemory。全局标签为 `{tu_id, phase, vector_index, group, vector_id}`；`vector_id` 是 16-bit 可回绕显示标签，内部唯一身份使用永久 invocation serial。

周期合同分成两层，禁止混用：

1. **事务边沿时间戳（正式 trace 语义）**：事件记为 cycle `C`，当且仅当对应事务在第 `C` 个上升沿被接受/发生。predicate、tag、地址和 group 均从该上升沿的 edge-qualified transaction snapshot 捕获；`#1step` 只用于避免 testbench 日志竞争，不重新采样事件。所有 Python、normal ModelSim、SYNTHESIS ModelSim 事件共用一个全局锚点，禁止按事件类型、TU 或编译模式自由平移。
2. **post-NBA 状态可见性（独立断言语义）**：需要检查的寄存器在同一上升沿后的 `#1step` 再采样；它不改变事务所属 cycle。尤其 `it_done` 必须满足：最后一个 `output_fire` 的事务边沿记录 `it_done` event；该边沿后 `it_done==1`，下一上升沿后 `it_done==0`。

冻结 R4C standalone transaction latency 合同：`result_accept=1` 时，`group0_result_fire_edge - vector_start_accept_edge == 23`，16 个 group 连续且 group II=1。23 是相对事务延迟，不是某次仿真的绝对 cycle 编号。

### Step12C-M2 memory/control decision record

`v3.5-17.2` 保留为上一版冻结证据。Step12C-M2 将 input-cache/intermediate 的访问控制固定为 request 侧 bank-local 地址/元数据寄存、response 侧小型 permutation：`read_request C → lane_capture C+1`；ResultMemory 仍保持 `request C → response C+1`。V 结果先进入 registered write-command，最后一条 command 在下一 edge 提交；`vertical_commit_done` 后才允许 H admission。不得用 per-event offset 迎合。

内部 memory trace 事件必须记录真实 transaction/fire，至少包含 TU/phase、memory owner、bank、address、lane 或 index、request_id（适用时）和 episode（scrub 时）。`stage_lane_capture` 为每个 lane 事件，`stage_full` 仅在 64 个 lane 均已捕获后产生。每个 epoch scrub episode 为 1024 个 cycle、4 bank/cycle（4096 个 tag-clear transactions）；scrub cache 不得普通读写，另一 cache 必须有真实 descriptor bind 或 data_fire 进展。

### Step12C-M2 closure status（历史）

Step12C-M2 保持以下周期合同：phase 被 admission 的 accepting edge 不发首个 staging read，首读最早在下一 edge；staging request/capture 为 request C → capture C+1，`stage_full → vector_start` 至少一拍，ResultMemory 仍为 request C → response C+1。V 最后 result 与 intermediate 的实际 commit 分离一个 edge，H 只能在 `vertical_commit_done` 后 admission。input data/tag/intermediate/result data array 不做 bulk reset；复位后 tag bank 先逐地址 startup scrub，完成后 cache 才可绑定 TU。

normal 与 `SYNTHESIS` 的功能/周期回归、公共事件、内部事件 comparator、two-TU、epoch scrub 和 mutation 均通过；R4C latency 合同仍为 23 个 transaction edges。Step12C-M2 synthesis-only 已完成，但 WNS=-0.252 ns、TNS=-156.002 ns、4609 个 setup failing endpoints，因此 Step12C-1 仍 STOP；不得进入 route。完整证据保存在 `05_audit/current/18/m2_synth/`。

### Step12C-M3 synthesis closure（当前，STOP）

M3 严格保持单 R4C、数学、官方接口、ResultMemory reader、V 写回和 descriptor/input 合同不变，只做两项物理时序修正：

1. 将 `r4c_result_vector_id` 的范围 sanity check 移到 verification-only；`vec_tmp` 以及真实 intermediate 地址、row/col/bank 计算仍保留在综合数据通路中。
2. 在 staging 读路径加入 bank-response/data/tag/metadata 寄存器：`request@C → bank response@C+1 → lane permutation/stage capture@C+2`。请求 II 仍为 1，稳态 vector II 仍为 16；仅 phase/首向量固定延迟增加一拍。

M3 功能/周期回归：PASS。normal 与 `SYNTHESIS`、zero/sparse/alternating/random/extreme、two-TU 长反压、vector-ID wrap、epoch scrub、26 项 model/checker mutation 均通过；R4C latency 仍为 23，R4C RTL hash 未变。

M3 Step12C-1 synthesis-only：STOP。Vivado 2025.2、xcku5p-ffvb676-2-e、2.000 ns clock；综合网表识别 22,673 LUT（其中 7,168 LUTRAM）、20,918 FF、128 DSP、0 BRAM/URAM，0 synthesis error/critical warning。setup WNS=`-0.002 ns`、TNS=`-6.030 ns`、2,560 个 failing endpoints；独立 hold summary 为 WHS=`-0.148 ns`、THS=`-2521.236 ns`、17,487 个 failing endpoints。`check_timing` 报告 0 个 unconstrained internal endpoints。由于 synthesis timing 未满足，按门禁不进入 place/route；完整证据保存在 `05_audit/current/19/m3_synth/`，下一轮必须基于新的真实 worst path 单独评审，不在 M3 内继续扩大修改。

M3 的当前最差 setup 路径已转移到 descriptor/input-cache 写入控制（`desc_slot_q → input_cache_a0.../WE`，约 1.800 ns，主要为 routing），不是 R4C vector sanity path；因此 M3 结论是“结构和功能继续改善，但 Step12C-1 仍 STOP”，不能创建 `v3.5-18`。

### Step12C-M4 synthesis closure（当前，STOP）

M4 只处理 M3 已暴露的 input-cache 写入边界：外部 `data_fire`/descriptor/address 不再直接驱动物理 input cache/tag RAM 写端口，而是先进入按 cache/bank 分组的 write-command 寄存器，下一 edge 执行 data/tag commit；最后一条带 `end` 的 command commit 后才释放 cache。R4C、M3 staging、V→intermediate write pipeline、ResultMemory reader、数学和 XDC boundary contract 均未修改。R4C SHA-256 仍为 `15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1`。

M4 功能/周期回归：PASS。Python model、normal/SYNTHESIS ModelSim、zero/sparse/alternating/random、backpressure、two-TU、vector-ID wrap、epoch scrub、26 项 mutation 均通过；典型 single-TU 结果为 1024 result writes、1024 output fires、ready-high output fire II=1、V/H vector II=16。

M4 Step12C-1 synthesis-only：Vivado 2025.2、xcku5p-ffvb676-2-e、2.000 ns clock；综合网表识别 input cache/tag/intermediate/result 为 distributed RAM，资源为 22,921 LUT（7,168 LUTRAM）、21,315 FF、128 DSP、0 BRAM/URAM，synthesis errors/critical warnings 为 0，`check_timing` 的 unconstrained internal endpoint 为 0。Setup WNS=`+0.087 ns`、TNS=`0 ns`、setup failing endpoints=0；独立 hold summary 为 WHS=`-0.076 ns`、THS=`-17.454 ns`、293 个 hold failing endpoints。当前按 Step12C-1 门禁 STOP，不进入 place/route；完整证据位于 `05_audit/current/20/m4_synth/`。

### Step12C-M5-Setup synthesis closure（历史）

M5-Setup 只统一 input-tag 的 scrub/normal bank-local write command，并把 input-cache raw tag 先寄存、epoch compare 后移；R4C、数学、官方接口、M3 staging、V→intermediate write pipeline、ResultMemory reader 和 XDC 均未修改。功能/周期回归（normal/SYNTHESIS、random/extreme、two-TU、descriptor、epoch、trace/mutation、R4C latency）全部 PASS，R4C SHA-256 仍为 `15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1`。

M5 synthesis-only：Vivado 2025.2、xcku5p-ffvb676-2-e、2.000 ns clock；综合网表仍识别 input cache/tag/intermediate/result 为 distributed RAM，资源为 21,313 LUT（5,888 LUTRAM）、21,336 FF、128 DSP、0 BRAM/URAM，synthesis errors/critical warnings 为 0，`check_timing` 的 unconstrained internal endpoint 为 0。Setup WNS=`+0.075 ns`、TNS=`0 ns`、setup failing endpoints=0；独立 hold summary 为 WHS=`-0.076 ns`、THS=`-17.135 ns`、251 个 hold failing endpoints。setup/structure gate PASS；hold 数值等待 Boundary-PRE 的 OOC clock/interface physical context 评审，不把缺少 `HD.CLK_SRC`/partition-pin 直接写成 hold 数值的唯一因果，也不通过 RTL delay、false path 或随意 input-delay 修复。完整证据位于 `05_audit/current/21/m5_synth/`。

### Step12C-M6 implementation-only closure（当前，v3.5-18）

M6 RTL、R4C、XDC 和 M6 postsynth DCP 均保持冻结。四个固定 Vivado 2025.2 implementation flow 均从同一个 postsynth DCP 独立起跑；`Performance_NetDelay_high`（`Default → ExtraNetDelay_high → AggressiveExplore → NoTimingRelaxation`）首次运行和从原始 DCP 的独立复跑均 fully routed，并满足 setup WNS=`+0.011 ns`、TNS=`0 ns`、0 个 failing endpoint，hold WHS=`+0.011 ns`、THS=`0 ns`、0 个 failing endpoint。`check_timing` 为 0 unconstrained internal endpoint、0 missing input/output delay、0 loop；`report_exceptions` 无 valid timing exception。四组 flow 中两组通过、两组未通过，完整摘要与文本报告位于 `05_audit/current/25/`。

该结论只闭合 Step12C 的 64×64 DCT2×DCT2 single-R4C wrapper/OOC performance baseline，不外推为完整 ITS Core、其他 TU 尺寸、DST7/DCT8 或 LFNST 的 500 MHz 证明。

## 测试门禁

必须有唯一顶层 `IntegrationModel.tick()` 和 RTL 同口径事件 trace，覆盖：normal/SYNTHESIS、zero/sparse/alternating/random、same-cycle data+end、standalone end、地址边界、A/B full/recovery、epoch scrub、vector-id wrap、two-TU 长反压。每个 negative mutation 未被捕获则整体 FAIL。

退出条件分两级：

1. `v3.5-17`：RTL 功能、协议、stage16/final10、事件/标签逐周期对拍通过；不代表 500 MHz。
2. `v3.5-18`：该范围 wrapper 在固定 implementation flow、真实 2.000 ns post-route 下 WNS/TNS/WHS/THS 全通过，并由独立复跑确认。

报告必须分别给出 `1D kernel=4 points/cycle`、`output burst=4 final points/cycle`、以及单 R4C 二维等效吞吐；不把 output 宽度替代计算吞吐。
