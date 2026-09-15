# Step12F-P2 H-response pipeline result

The H intermediate-read response pipeline and coefficient-bundle prefetch are functionally closed for the existing coverage campaign. Both normal and `SYNTHESIS` ModelSim runs pass 369 Gate-C tuples / 45,636 beats, all 13 vector-II modes, and the LFNST specialty campaigns (1,088 engine cases and 258 wrapper cases).

Fresh Vivado 2025.2 synthesis also completes and produces a checkpoint. It is not a timing pass: at 2.000 ns, setup is WNS `-1.232 ns`, TNS `-9363.587 ns`, with 30,045 failing endpoints; hold is WHS `-0.076 ns`, THS `-3.402 ns`, with 49 failing endpoints. Constraint coverage is clean (0 unconstrained internal endpoints and no valid timing exceptions). The current worst setup family is `kernel_group_q -> intermediate RAM write-enable/address decode`, so route is intentionally not run.

This result is a functional/synthesizability checkpoint, not Step12F physical closure.
