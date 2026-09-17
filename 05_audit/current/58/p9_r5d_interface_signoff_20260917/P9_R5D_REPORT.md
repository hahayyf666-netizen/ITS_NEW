# Step12F-P9-R5D — Interface / OOC Signoff-Responsibility Qualification

## Scope and result

This is a read-only responsibility audit of the fixed R5C physical evidence.
No RTL, XDC, synthesis, implementation, timing strategy, or simulator run was
performed. The result is complete as an audit, but the final external
integration contract remains unresolved:

> `P9-R5D = COMPLETE_READ_ONLY`
>
> `hold responsibility = UNRESOLVED_EXTERNAL_INTEGRATION_CONTRACT`

The unresolved item does not authorize a core RTL hold fix or an XDC change.

## Evidence checked

The current Step12F flow is explicitly an OOC flow. The XDC starts with
`Step12F fresh unified-wrapper OOC boundary contract` and labels the input and
output delays as a `Registered-neighbor OOC contract`. All input and output
delays are 0.000 ns. The implementation Tcl synthesizes
`unified_its_wrapper` with `-mode out_of_context` and prints
`BOUNDARY_CONTRACT=registered-neighbor-zero-delay`.

The R5C port snapshot has no LOC, PACKAGE_PIN, IOB, or IOBDELAY values. The
negative hold paths contain no IBUF/IODELAY/IOB-FF evidence. Thus the routed
DCP measures a DUT-port-to-first-register OOC abstraction, not a package-I/O
signoff path.

The supplied Huawei attachment defines logical signal directions, widths,
TU-raster semantics, sparse input, output packing, and transform-shape rows.
It does not state package pins, I/O standards, IBUF/IODELAY/IOB placement,
input/output delay values, launch-clock relationships, or whether the module
is the final FPGA package top. The user-supplied official answer adds logical
clock/reset and protocol semantics, but does not add physical I/O timing
context.

The historical Step12C registered-neighbor harness is useful methodology
evidence: it launches DUT inputs from internal source registers and captures
outputs in internal sink registers. Its own result is explicitly diagnostic,
not a v3.5-18 signoff, and it is not a Step12F unified-wrapper harness. The
historical `its_top_500_singleclk` XDC uses 0.200 ns I/O delays, but that is a
different legacy RTL/topology and cannot be transplanted into Step12F.

See `BOUNDARY_CONTEXT_MATRIX.json` and
`INTERFACE_PHYSICAL_SOURCE_SCAN.json` for the row-by-row comparison and
source hashes.

## Four responsibility questions

| Question | Finding | Status |
|---|---|---|
| What is the current top? | `unified_its_wrapper` is the current Step12F OOC physical-flow top/module boundary. | Closed for current flow |
| What is the final driver? | The current model is an abstract zero-delay boundary; final driver may be an upstream registered neighbor, package I/O, or another system boundary. | Unresolved |
| What does input delay 0/0 mean? | An explicit registered-neighbor OOC assumption; not proof of final package timing. | Closed |
| Who owns package/clock/earliest-arrival signoff? | The enclosing final integration/top-level owner must provide it, but that owner and context are not identified in current evidence. | Unresolved |

## Hold and setup responsibility

R5C found 65 negative hold paths, all input-port to first-register, zero logic
levels: 44 from `it_info`, 16 from `it_data_in`, and 5 from `it_data_addr`.
This strongly indicates a boundary-model issue, but does not prove that the
frozen 0 ns minimum is invalid. The current DCP cannot decide package delay,
IBUF/IODELAY/IOB packing, upstream launch-clock phase, or board/interconnect
arrival. No hold waiver or XDC relaxation is authorized.

R5C setup remains `WNS=-0.063 ns`, `TNS=-1.776 ns`, and 84 failing endpoints,
classified as a distributed multi-family timing tail. Setup is outside R5D
scope and remains frozen; no R6 RTL target is authorized by this audit.

## Decision and next boundary

```yaml
P9-R5A: CLOSED / ACCEPTED
P9-R5B: CLOSED / ACCEPTED / NO SIGNOFF
P9-R5C: CLOSED / ACCEPTED / READ-ONLY
P9-R5D: COMPLETE_READ_ONLY
R5 RTL: RETAINED / FROZEN
XDC: RETAINED / FROZEN
R6 RTL: NOT_AUTHORIZED
500 MHz signoff: NOT_ACHIEVED
hold classification: INTERFACE_OR_OOC_HARNESS_STRONGLY_INDICATED_NOT_PROVEN
integration contract: UNRESOLVED_EXTERNAL_INTEGRATION_CONTRACT
```

The next action is selected by the final integration evidence:

1. If the core is embedded behind upstream registered neighbors, create a
   Step12F-specific enclosing harness and sign off the source-Q-to-DUT and
   DUT-to-sink paths there.
2. If the core is a package-level FPGA interface, provide the actual pin,
   I/O-standard, I/O-delay, clock-launch, and earliest/latest arrival
   constraints before judging hold.
3. If neither context can be established, keep the hold result as unresolved
   OOC evidence and do not modify RTL/XDC to manufacture a pass.

