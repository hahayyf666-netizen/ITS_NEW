"""Generate one independent full-range 64x64 RTL cross-check vector set."""
from __future__ import annotations

import json
import random
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
ORACLE = ROOT / "04_reference" / "oracle"
if str(ORACLE) not in sys.path:
    sys.path.insert(0, str(ORACLE))
from v34_rtl_bitexact import main_2d_details  # type: ignore

N = 64
SEED = 20260904


def twos(value: int, bits: int) -> int:
    return value & ((1 << bits) - 1)


def main() -> None:
    rng = random.Random(SEED)
    matrix = [[rng.randint(-32768, 32767) for _ in range(N)] for _ in range(N)]
    details = main_2d_details(matrix, 0, 0, N, N)
    out = ROOT / "03_verification" / "generated"
    out.mkdir(parents=True, exist_ok=True)
    (out / "step12b_random_input.mem").write_text(
        "\n".join(f"{twos(matrix[r][c], 16):04x}" for r in range(N) for c in range(N))
        + "\n", encoding="ascii")
    beats = []
    for r in range(N):
        for g in range(16):
            beat = 0
            for k, value in enumerate(details["final10"][r][g * 4:g * 4 + 4]):
                beat |= (int(value) & 0x3FF) << (10 * k)
            beats.append(beat)
    (out / "step12b_random_expected.mem").write_text(
        "\n".join(f"{v:010x}" for v in beats) + "\n", encoding="ascii")
    (out / "step12b_random_meta.json").write_text(json.dumps({
        "seed": SEED, "size": "64x64", "type": "DCT2xDCT2",
        "input_file": "step12b_random_input.mem",
        "expected_file": "step12b_random_expected.mem",
    }, indent=2) + "\n", encoding="utf-8")
    extreme = [[32767 if ((r + c) & 1) == 0 else -32768
                for c in range(N)] for r in range(N)]
    extreme_details = main_2d_details(extreme, 0, 0, N, N)
    (out / "step12b_extreme_input.mem").write_text(
        "\n".join(f"{twos(extreme[r][c], 16):04x}" for r in range(N) for c in range(N))
        + "\n", encoding="ascii")
    extreme_beats = []
    for r in range(N):
        for g in range(16):
            beat = 0
            for k, value in enumerate(extreme_details["final10"][r][g * 4:g * 4 + 4]):
                beat |= (int(value) & 0x3FF) << (10 * k)
            extreme_beats.append(beat)
    (out / "step12b_extreme_expected.mem").write_text(
        "\n".join(f"{v:010x}" for v in extreme_beats) + "\n", encoding="ascii")
    print(json.dumps({"seed": SEED, "inputs": N * N, "expected_beats": N * 16}))


if __name__ == "__main__":
    main()
