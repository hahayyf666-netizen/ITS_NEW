#!/usr/bin/env python
"""Independent per-edge model of what the grant pin should carry.

Written from the contract, not from the driver source: a window drives the
profile pattern for its declared number of sampling edges, the pattern is

    always_grant        -> req = 1
    hold > 0            -> req = 0, hold -= 1
    cyc % deep_period==0-> req = 0, hold = deep_len - 1   (trigger counts)
    otherwise           -> req = !(cyc%light_mod==2 || cyc%light_off==5)

with cyc the global falling-edge counter, and a guard edge (req = 1) sits
between two windows.  Everything is keyed off cyc and the declared parameters,
so the result can be compared against the recorded pin cycle by cycle.
"""
from __future__ import annotations


def cyc_of_edge(t_ps: int, period_ps: int = 2000) -> int:
    """Global cyc for the sampling edge at t_ps.

    drive_pins() increments cyc on each falling edge starting at t = period/2,
    so the value sampled by the rising edge at t is t/period for the negedge
    that preceded it: negedge at 2000 -> cyc 1 -> sampled at 3000.
    """
    return (t_ps - period_ps // 2) // period_ps


def pattern(cyc: int, *, always: bool, lm: int, lo: int, dp: int, dl: int,
            hold: int):
    """One cycle of the profile.  Returns (req, hold_next)."""
    if always:
        return 1, 0
    if hold > 0:
        return 0, hold - 1
    if dp != 0 and cyc % dp == 0:
        return 0, (dl - 1 if dl > 0 else 0)
    return (0 if (cyc % lm == 2 or cyc % lo == 5) else 1), 0


def window_reqs(start_cyc: int, dur: int, *, always: bool, lm: int, lo: int,
                dp: int, dl: int):
    """req for each of the `dur` sampling edges of one window."""
    hold = 0
    out = []
    for k in range(dur):
        req, hold = pattern(start_cyc + k, always=always, lm=lm, lo=lo,
                            dp=dp, dl=dl, hold=hold)
        out.append(req)
    return out


if __name__ == "__main__":
    csv = ("C:/Users/Fine/Documents/deepseek-harness/default-workspace/its_push/"
           "03_verification/uvm/run/probe/b1_grant_new.csv")
    rows = [tuple(int(x) for x in ln.split(","))
            for ln in open(csv, encoding="utf-8") if ln.strip()]
    print(f"{len(rows)} edges")

    # Windows, taken from the sequence-side begin/end timestamps printed by the
    # probe and the one-guard + dur spacing they imply.
    windows = [
        # first_edge_t, dur, always, lm, lo, dp, dl
        (11000,    6000, False, 5, 9,  32, 4),
        (12013000, 3000, True,  7, 11, 64, 8),
        (18015000, 6000, False, 3, 5,  24, 10),
    ]
    for t0, dur, always, lm, lo, dp, dl in windows:
        c0 = cyc_of_edge(t0)
        want = window_reqs(c0, dur, always=always, lm=lm, lo=lo, dp=dp, dl=dl)
        got = [q for tt, r, q in rows if t0 <= tt <= t0 + (dur - 1) * 2000]
        assert len(got) == dur, (len(got), dur)
        mism = [i for i, (a, b) in enumerate(zip(got, want)) if a != b]
        print(f"  cyc {c0}..{c0+dur-1}  dur={dur}  zeros={got.count(0)}  "
              f"mismatch={len(mism)}")
        if mism:
            print("    first mismatch at", mism[0], got[mism[0]], want[mism[0]])