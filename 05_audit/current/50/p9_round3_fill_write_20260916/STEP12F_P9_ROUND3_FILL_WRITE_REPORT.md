# Step12F-P9 Round 3 — Input-Cache Fill Write Accept/Commit Isolation

## Current checkpoint

The RTL change is based on `c785bccf7b0a7c31f2b2994adfaa9426310ec3f6` and is limited to `unified_its_wrapper.sv`. The P4 arithmetic, atomic read-command boundary, input-cache module type, bounded LFNST arithmetic, Oracle/profile, XDC, R4C, and `v3.5-18` remain unchanged.

## Implemented boundary

```text
sparse input fire
  -> raster/bank/local mapping
  -> registered fill-write command
  -> data_mem write + valid_mem set on the commit edge
```

The command owns a one-hot physical slot/bank target, local address, and data. RAM write enables, addresses, and data are driven from command Q. The explicit ready/commit equations permit old-command commit plus new-command capture in one cycle.

`it_data_end` remains an independent transaction. A final data word and end marker in the same cycle records an end-pending state; the slot stays in fill ownership until the corresponding command commits. An end-only marker produces no data command. Scrub continues to clear validity only, with an ownership assertion preventing a delayed fill command from targeting the scrub slot.

## Static review

The previous direct `input_fire -> input_data_wr_en/input_valid_wr_en` path has been removed. The only sparse-fill source for those ports is `fill_wr_cmd_*_q`. Data and validity writes are paired for the command target and address. A deterministic abstract accept/commit model is recorded in `P9_R3_STATIC_PROTOCOL_MODEL.json`; it covers final-data-plus-end, end-only, and continuous sparse-point cases. `git diff --check`, JSON parsing, hash checks, and the existing source/model checks pass.

## Tool status

The current environment does not expose `vsim`, `vlog`, `xsim`, `xvlog`, `iverilog`, `verilator`, or `vivado`. Therefore normal/SYNTHESIS RTL simulation, fresh synthesis, and place/route are deliberately recorded as **NOT RUN**, not as passes.

The checkpoint must receive the full regression and fresh physical flow before P9 Round 3 can be classified as functionally or physically effective. No tag is authorized by this checkpoint.
