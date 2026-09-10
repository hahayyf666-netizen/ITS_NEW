"""Generate R3 fixed terminal dot commits from the extracted manifest.

The reduction arithmetic and its sampling edge remain in the R1 loops.  This
generator replaces only dynamic dot destinations with fixed elaborated dot
constants; the vector context/bank remains a one-bit runtime choice.
"""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]
SV = ROOT / "02_rtl/rtl/p2f_dct2_64_b1_step102.sv"
MANIFEST = ROOT / "03_verification/output/p2f_b2_r3_connectivity_manifest.json"
text = SV.read_text(encoding="utf-8")
manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
producers = manifest["dot_producers"]
assert len(producers) == 64

data_arr = ["lane_product_reg", "red_s0_data", "red_s1_data", "red_s2_data", "red_s3_data"]
vec_arr = ["lane_vector_id_reg", "red_s0_vector", "red_s1_vector", "red_s2_vector", "red_s3_vector"]

by_phase = {}
for p in producers:
    by_phase.setdefault(int(p["phase"]), []).append(p)

lines = [
    "            // R3 static terminal-dot commit generated from the manifest.",
    "            // Data is the current-cycle arithmetic expression, preserving",
    "            // R1 nonblocking-assignment sampling semantics.",
    "            if (red_active) begin",
    "                case (red_cycle)",
]
for phase in sorted(by_phase):
    lines.append(f"                    6'd{phase}: begin")
    for p in sorted(by_phase[phase], key=lambda x: int(x["dot"])):
        stage = int(p["stage"])
        dot = int(p["dot"])
        a = int(p["src0"])
        b = int(p["src1"])
        data = data_arr[stage]
        vec = vec_arr[stage]
        lines += [
            f"                        dot_value_bank[{vec}[{a}][0]][{dot}] <= {data}[{a}] + {data}[{b}];",
            "`ifndef SYNTHESIS",
            f"                        $fwrite(r3_terminal_trace_fd, \"%0t,%0d,{dot},%0d,%0d\\n\", $time, {vec}[{a}], red_cycle, {data}[{a}] + {data}[{b}]);",
            "`endif",
        ]
        if stage == 4:
            lines += [
                f"                        dot_value_valid[{vec}[{a}][0]][{dot}] <= 1'b1;",
                f"                        dot_value_vector[{vec}[{a}][0]][{dot}] <= {vec}[{a}];",
            ]
    lines.append("                    end")
lines += [
    "                    default: begin end",
    "                endcase",
    "            end",
]
block = "\n".join(lines)
begin = "            // R3_STATIC_COMMIT_BEGIN"
end = "            // R3_STATIC_COMMIT_END"
start = text.index(begin)
stop = text.index(end, start) + len(end)
text = text[:start] + block + text[stop:]
SV.write_text(text, encoding="utf-8", newline="")
print(f"generated {len(by_phase)} phases / {len(producers)} terminal commits: {SV}")
