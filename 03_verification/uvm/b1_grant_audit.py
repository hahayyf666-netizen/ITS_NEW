#!/usr/bin/env python
"""B1 counterexample: does a finite grant profile actually run before it is acked?

Two independent records are compared instead of trusting either side alone:

  sequence side   ITS_GRANT_TXN begin/end timestamps, printed by send() itself.
                  "Did the sequence get control back too early" is a question
                  about finish_item() returning, so it has to be measured there.
  pin side        one CSV row per rising clock edge: time, rst_n, actual req.
                  The driver drives on the falling edge with a non-blocking
                  assignment, so only the rising edge shows what the DUT saw.

The check, per transaction: the number of rising edges inside [begin, end] where
rst_n is high must equal the declared duration.  Counting edges rather than
simulated time is deliberate - the old driver decremented `remaining` during
reset as well, so a cycle count taken from the driver would mix two different
notions of "executed".

Usage:
    python b1_grant_audit.py --label old
    python b1_grant_audit.py --label new
Writes run/probe/b1_grant_<label>.csv/.json and prints the per-transaction table.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run_its_uvm as env_mod  # noqa: E402
import run_regress as rr       # noqa: E402


def compile_sources():
    """Recompile with the current SRC list, no vector regeneration.

    env_mod.stage_prep() also regenerates the Gate-C vectors and restages the
    ROM; neither changed, and regenerating them would only make the probe slower
    and the input set ambiguous.
    """
    files = [str(f) for f in list(env_mod.RTL) + list(env_mod.SRC)]
    cmd = [str(env_mod.VLOG), "-sv", "+cover=bcestf", "+define+UVM_NO_DPI",
           f"+incdir+{env_mod.UVM}", f"+incdir+{env_mod.HERE}",
           str(env_mod.UVM / "uvm_pkg.sv")] + files
    cmd += ["-l", str(rr.OUT / "logs/b1_compile.log")]
    rc, dt = env_mod.run(cmd, rr.OUT / "logs/b1_compile.stdout.log", rr.OUT, 3600)
    text = (rr.OUT / "logs/b1_compile.log").read_text(encoding="utf-8",
                                                      errors="replace")
    errs = text.count("** Error")
    print(f"[b1] compile exit={rc} errors={errs} ({dt:.0f}s)", flush=True)
    if rc != 0 or errs:
        raise SystemExit("compile failed; see run/logs/b1_compile.log")


def txn_events(log_path):
    """begin/end timestamps per transaction, from the sequence's own prints."""
    text = log_path.read_text(encoding="utf-8", errors="replace")
    ev = {}
    # "# UVM_INFO ... (740) @ 0: ... [ITS_GRANT_TXN] txn 0 begin t=0 dur=6000"
    pat = re.compile(r"\[ITS_GRANT_TXN\]\s+txn\s+(\d+)\s+(begin|end)\s+"
                     r"t=(\d+)\s+dur=(\d+)")
    for m in pat.finditer(text):
        idx, phase, t, dur = int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4))
        rec = ev.setdefault(idx, {})
        rec[phase] = t
        rec["dur"] = dur
    return ev


def edge_rows(csv_path):
    rows = []
    for line in csv_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        t, rst, req = line.split(",")
        rows.append((int(t), int(rst), int(req)))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True, help="old | new (naming only)")
    ap.add_argument("--case", default="vseq_multi_agent")
    ap.add_argument("--skip-compile", action="store_true")
    args = ap.parse_args()

    if not args.skip_compile:
        compile_sources()

    vector_file, cases = rr.load_cases()
    case = next(c for c in cases if c["name"] == args.case)

    probe_dir = rr.OUT / "probe"
    probe_dir.mkdir(parents=True, exist_ok=True)
    csv_path = probe_dir / f"b1_grant_{args.label}.csv"
    if csv_path.exists():
        csv_path.unlink()

    print(f"[b1] running {args.case} with grant audit -> {csv_path.name}",
          flush=True)
    r = rr.run_one(case, vector_file, want_ucdb=False,
                   extra_plusargs=(f"GRANT_AUDIT={csv_path}",),
                   artifact_name=f"b1_audit_{args.label}",
                   result_dir=probe_dir)
    print(f"[b1] verdict {r['status']}/{r['reason']} ({r['elapsed_s']:.0f}s)",
          flush=True)

    log_path = rr.OUT / "logs" / f"regress_b1_audit_{args.label}.log"
    ev = txn_events(log_path)
    rows = edge_rows(csv_path)

    # The DUT's sampling edges, split by reset so the two notions of "executed"
    # stay separate.  rst_n is active low.
    valid_edges = [t for t, rst, _ in rows if rst == 1]
    print(f"[b1] edges: total={len(rows)} rst_n_high={len(valid_edges)} "
          f"rst_n_low={len(rows) - len(valid_edges)}", flush=True)

    table = []
    bad = []
    prev_end = None
    for idx in sorted(ev):
        rec = ev[idx]
        begin, end, dur = rec.get("begin"), rec.get("end"), rec.get("dur")
        if begin is None or end is None:
            bad.append((idx, "transaction never completed (no end timestamp)"))
            table.append({"txn": idx, "dur": dur, "begin": begin, "end": end,
                          "span_edges": None, "gap_edges": None,
                          "gap_expected": None, "req_high": None, "ok": False})
            prev_end = end if end is not None else prev_end
            continue
        span = [t for t in valid_edges if begin <= t <= end]
        reqs = [q for t, rst, q in rows if rst == 1 and begin <= t <= end]
        high = sum(1 for q in reqs if q == 1)
        # The sequence handed the item over at `begin` and got control back at
        # `end`.  It must not have got it back before the window could run, so
        # at least `dur` sampling edges have to fit in between.  This is the
        # check the old driver fails outright: it returned at t=0 with none.
        enough = len(span) >= dur
        # Between two consecutive windows the contract prescribes exactly one
        # guard edge, so the spacing is dur+1 edges.  Only meaningful from the
        # second window on: before the first one the driver may still be waiting
        # for reset release, which is not part of any window.
        gap = None
        gap_ok = True
        if prev_end is not None:
            gap = len([t for t in valid_edges if prev_end < t <= end])
            gap_ok = (gap == dur + 1)
        ok = enough and gap_ok
        table.append({"txn": idx, "dur": dur, "begin": begin, "end": end,
                      "span_edges": len(span), "gap_edges": gap,
                      "gap_expected": (dur + 1) if prev_end is not None else None,
                      "req_high": high, "ok": ok})
        if not enough:
            why = ("returned before a single sampling edge"
                   if len(span) == 0 else
                   f"only {len(span)} sampling edge(s) for a declared {dur}")
            bad.append((idx, why))
        elif not gap_ok:
            bad.append((idx, f"{gap} edges since the previous window ended, "
                            f"expected {dur + 1} (one guard + {dur})"))
        prev_end = end

    print(f"[b1] {'txn':>3} {'dur':>6} {'begin':>10} {'end':>10} "
          f"{'span':>5} {'gap':>5} {'want':>5} {'req=1':>6}  result", flush=True)
    for row in table:
        def f(v):
            return "-" if v is None else str(v)
        print(f"[b1] {row['txn']:>3} {f(row['dur']):>6} {f(row['begin']):>10} "
              f"{f(row['end']):>10} {f(row['span_edges']):>5} "
              f"{f(row['gap_edges']):>5} {f(row['gap_expected']):>5} "
              f"{f(row['req_high']):>6}  {'ok' if row['ok'] else 'FAIL'}",
              flush=True)

    total_dur = sum(r["dur"] for r in table if r["dur"])
    print(f"[b1] declared total {total_dur} edges; rst_n_high edges observed "
          f"{len(valid_edges)}; surplus {len(valid_edges) - total_dur} "
          f"(guard edges the contract prescribes)", flush=True)

    out = {"label": args.label, "case": args.case,
           "verdict": f"{r['status']}/{r['reason']}",
           "edges_total": len(rows), "edges_rst_high": len(valid_edges),
           "transactions": table,
           "failures": [{"txn": i, "why": w} for i, w in bad]}
    (probe_dir / f"b1_grant_{args.label}.json").write_text(
        json.dumps(out, indent=2), encoding="utf-8")

    if bad:
        print(f"[b1] CHECK FAILED: {len(bad)} transaction(s) did not execute "
              f"their declared duration", flush=True)
        for i, w in bad:
            print(f"[b1]   txn {i}: {w}", flush=True)
        return 1
    print("[b1] CHECK PASSED: every finite profile ran its declared duration",
          flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())