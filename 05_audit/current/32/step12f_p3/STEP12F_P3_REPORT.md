# Step12F-P3 result

P3 inserted a registered vertical-result to intermediate-memory command boundary. The frozen intermediate mapping is unchanged: `bank=(row+col)&3`, `local=(row>>2)*width+col`; for a vertical group the implementation uses `bank=(lane+col[1:0])&3`, `local=group*width+col`. The command uses one shared registered local address and four bank-local valid/data fields, and supports issue/commit II=1.

The normal and `SYNTHESIS` ModelSim campaigns both pass: 369 engineering-profile tuples / 45,636 beats per mode, all 13 one-dimensional vector-II modes, LFNST specialty campaigns (1,088 engine and 258 wrapper cases), and the P3 directed contract. The mapping proof checks 15,376 coordinates with zero mismatches and zero collisions. The directed P3 bench reports 16 accepted commands, 16 commits, final commit cycle 128, and 16 output beats in both modes. The V-to-H state sequence is `K_V_DRAIN -> K_V_WAIT_COMMIT -> K_H_START`, and H admission waits for the final command commit.

Fresh Vivado 2025.2 synthesis completes in 364 seconds and produces a checkpoint. Resources are 38,650 LUT (5,632 LUTRAM), 33,518 FF, 316 DSP, 0 BRAM and 0 URAM. At 2.000 ns, post-synthesis setup is WNS `-1.036 ns`, TNS `-8214.760 ns`, 41,175 failing endpoints; hold is WHS `-0.076 ns`, THS `-3.391 ns`, 47 failing endpoints. Constraint coverage is clean (0 unconstrained internal endpoints and no valid timing exceptions).

The P3 targeted proof is positive: the old `kernel_group_q -> intermediate RAM write` query has no timing path; kernel-to-command capture has representative slack `+0.246 ns` (address) and `+0.261 ns` (data); command-valid to intermediate RAM write-enable has representative slack `+0.981 ns`. The fresh synthesis timing gate nevertheless remains STOP because a separate unified-P4 coefficient-select/control path is now worst (`slot_state_q -> s0_coeff_q`, 3.017 ns data path, 10 logic levels). Place/route is intentionally not run.

Frozen R4C and XDC are unchanged, no tag is created, and `v3.5-18` is not moved. This is a P3 functional/structural checkpoint, not 500 MHz closure.
