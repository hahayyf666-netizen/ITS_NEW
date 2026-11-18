#!/usr/bin/env python
"""B1 counterexample: does a finite grant profile actually run before it is acked?

Two independent records are compared instead of trusting either side alone:

  sequence side   ITS_GRANT_TXN begin/end timestamps, printed by send() itself.
                  "Did the sequence get control back too early" is a question
                  about finish_item() returning, so it has to be measured there.
  pin side        one CSV row per rising clock edge: time, rst_n, actual req.

Three kinds of claim are checked, and each one used to be able to pass on its
own evidence being absent:

  liveness   the sequence was released only after at least `dur` sampling edges,
             and consecutive windows are spaced exactly dur+1 edges apart (one
             guard edge between them);
  waveform   every edge of every window carries the req the declared parameters
             predict, from an independent model in b1_pin_model.py - not from
             the driver's own bookkeeping;
  contract   every reset edge carries req=1, and the case this probe piggybacks
             on actually passed.

`--selftest` replays the recorded artefacts through the judge with the mutants
that used to slip through: all req forced to 0, all transaction records deleted,
and a failing underlying verdict.
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

import b1_pin_model as model  # noqa: E402

PERIOD = 2000  # ps, from the TB clock


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------
def txn_events(log_text: str):
    """begin/end timestamps per transaction, from the sequence's own prints."""
    ev = {}
    pat = re.compile(r"\[ITS_GRANT_TXN\]\s+txn\s+(\d+)\s+(begin|end)\s+"
                     r"t=(\d+)\s+dur=(\d+)")
    for m in pat.finditer(log_text):
        idx, phase, t, dur = (int(m.group(1)), m.group(2),
                              int(m.group(3)), int(m.group(4)))
        rec = ev.setdefault(idx, {})
        key = f"{phase}_count"
        rec[key] = rec.get(key, 0) + 1
        rec[phase] = t
        rec["dur"] = dur
    return ev


def parse_profiles(log_text: str):
    """The declared parameters, from the driver's own profile print."""
    out = []
    pat = re.compile(r"profile:\s+grant\s+always=(\d)\s+light=(\d+)/(\d+)\s+"
                     r"deep=(\d+)/(\d+)\s+dur=(\d+)")
    for m in pat.finditer(log_text):
        out.append({"always": m.group(1) == "1",
                    "lm": int(m.group(2)), "lo": int(m.group(3)),
                    "dp": int(m.group(4)), "dl": int(m.group(5)),
                    "dur": int(m.group(6))})
    return out


def edge_rows(csv_text: str):
    rows = []
    for line in csv_text.splitlines():
        line = line.strip()
        if not line:
            continue
        t, rst, req = line.split(",")
        rows.append((int(t), int(rst), int(req)))
    return rows


# --------------------------------------------------------------------------
# The judge.  Pure function of (events, edges, verdict, profiles).
# --------------------------------------------------------------------------
def judge(ev, rows, verdict, profiles, period=PERIOD):
    failures = []
    table = []

    if not verdict.startswith("PASS"):
        failures.append(f"underlying case verdict is {verdict}, not PASS")

    # 1. Exactly the declared windows, each with exactly one begin and one end.
    if len(profiles) == 0:
        failures.append("no profile line in the log: nothing to check")
    if len(ev) != len(profiles):
        failures.append(f"{len(ev)} transaction record(s) for "
                        f"{len(profiles)} declared profile(s)")
    for i in range(max(len(profiles), max(ev) + 1 if ev else 0)):
        rec = ev.get(i)
        if rec is None:
            failures.append(f"txn {i}: no begin/end record")
            continue
        if rec.get("begin_count", 0) != 1 or rec.get("end_count", 0) != 1:
            failures.append(f"txn {i}: {rec.get('begin_count', 0)} begin / "
                            f"{rec.get('end_count', 0)} end record(s)")

    # 2. Reset edges are guard edges.
    for t, rst, req in rows:
        if rst != 1 and req != 1:
            failures.append(f"reset edge at t={t} carries req={req}, not 1")
            break

    # 3. Per window: liveness, spacing and the expected waveform.
    prev_end = None
    for i, prof in enumerate(profiles):
        rec = ev.get(i) or {}
        begin, end = rec.get("begin"), rec.get("end")
        dur = prof["dur"]
        row = {"txn": i, "dur": dur, "begin": begin, "end": end,
               "span_edges": None, "gap_edges": None, "gap_expected": None,
               "zeros": None, "wave_mismatch": None, "ok": False}
        table.append(row)
        if begin is None or end is None:
            continue

        # The Nth sampling edge is the end timestamp, so the window's first edge
        # is exactly dur-1 periods earlier.  No start detection, no circularity.
        first_edge = end - (dur - 1) * period
        got = [(t, q) for t, rst, q in rows if first_edge <= t <= end]
        # Only edges the DUT could execute count: a reset edge is not one.
        row["span_edges"] = len([t for t, rst, q in rows
                                 if begin <= t <= end and rst == 1])
        if len(got) != dur:
            failures.append(f"txn {i}: window holds {len(got)} edges, "
                            f"declared {dur}")
            continue
        if row["span_edges"] < dur:
            failures.append(f"txn {i}: released after {row['span_edges']} "
                            f"edge(s), needs {dur}")
        if first_edge < (begin if begin is not None else 0) - period * 2:
            # begin is the hand-over instant; a window starting long before it
            # means the timestamps do not describe this pin activity.
            failures.append(f"txn {i}: window starts at {first_edge}, before "
                            f"the item was handed over at {begin}")

        want = model.window_reqs(model.cyc_of_edge(first_edge, period), dur,
                                 always=prof["always"], lm=prof["lm"],
                                 lo=prof["lo"], dp=prof["dp"], dl=prof["dl"])
        mism = [k for k in range(dur) if got[k][1] != want[k]]
        row["zeros"] = sum(1 for _, q in got if q == 0)
        row["wave_mismatch"] = len(mism)
        if mism:
            k = mism[0]
            failures.append(f"txn {i}: {len(mism)} edge(s) differ from the "
                            f"declared pattern, first at t={got[k][0]} "
                            f"req={got[k][1]} expected {want[k]}")

        if prev_end is not None:
            gap = len([t for t, rst, q in rows if prev_end < t <= end])
            row["gap_edges"] = gap
            row["gap_expected"] = dur + 1
            if gap != dur + 1:
                failures.append(f"txn {i}: {gap} edges since the previous "
                                f"window ended, expected {dur + 1} "
                                f"(one guard + {dur})")
            if first_edge != prev_end + 2 * period:
                failures.append(f"txn {i}: first edge {first_edge}, expected "
                                f"one guard edge after {prev_end}")
        # The guard edge after this window must itself be req=1.
        guard_t = end + period
        guard = [q for t, rst, q in rows if t == guard_t]
        if i + 1 < len(profiles):
            if not guard:
                failures.append(f"txn {i}: guard edge at {guard_t} is missing")
            elif guard[0] != 1:
                failures.append(f"txn {i}: guard edge at {guard_t} carries "
                                f"req={guard[0]}, not 1")

        row["ok"] = not any(f.startswith(f"txn {i}:") for f in failures)
        prev_end = end

    return {"table": table, "failures": failures}


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
def compile_sources():
    import run_its_uvm as env_mod
    import run_regress as rr
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


def run_probe(label, case_name):
    import run_regress as rr
    vector_file, cases = rr.load_cases()
    case = next(c for c in cases if c["name"] == case_name)
    probe_dir = rr.OUT / "probe"
    probe_dir.mkdir(parents=True, exist_ok=True)
    csv_path = probe_dir / f"b1_grant_{label}.csv"
    if csv_path.exists():
        csv_path.unlink()
    print(f"[b1] running {case_name} with grant audit -> {csv_path.name}",
          flush=True)
    r = rr.run_one(case, vector_file, want_ucdb=False,
                   extra_plusargs=(f"GRANT_AUDIT={csv_path}",),
                   artifact_name=f"b1_audit_{label}", result_dir=probe_dir)
    print(f"[b1] underlying case {r['status']}/{r['reason']} "
          f"({r['elapsed_s']:.0f}s)", flush=True)
    log_path = rr.OUT / "logs" / f"regress_b1_audit_{label}.log"
    return r, csv_path, log_path


def load_artefacts(label):
    import run_regress as rr
    probe_dir = rr.OUT / "probe"
    csv_path = probe_dir / f"b1_grant_{label}.csv"
    log_path = rr.OUT / "logs" / f"regress_b1_audit_{label}.log"
    out = json.loads((probe_dir / f"b1_grant_{label}.json").read_text(
        encoding="utf-8")) if (probe_dir / f"b1_grant_{label}.json").exists() else {}
    return (txn_events(log_path.read_text(encoding="utf-8", errors="replace")),
            edge_rows(csv_path.read_text(encoding="utf-8", errors="replace")),
            out.get("verdict", "PASS"),
            parse_profiles(log_path.read_text(encoding="utf-8", errors="replace")))


def report(res, label):
    print(f"[b1] {'txn':>3} {'dur':>6} {'begin':>10} {'end':>10} {'span':>5} "
          f"{'gap':>5} {'want':>5} {'req=0':>6} {'wave':>5}  result", flush=True)
    for r in res["table"]:
        f = lambda v: "-" if v is None else str(v)  # noqa: E731
        print(f"[b1] {r['txn']:>3} {f(r['dur']):>6} {f(r['begin']):>10} "
              f"{f(r['end']):>10} {f(r['span_edges']):>5} "
              f"{f(r['gap_edges']):>5} {f(r['gap_expected']):>5} "
              f"{f(r['zeros']):>6} {f(r['wave_mismatch']):>5}  "
              f"{'ok' if r['ok'] else 'FAIL'}", flush=True)
    if res["failures"]:
        print(f"[b1] {label}: CHECK FAILED ({len(res['failures'])} finding(s))",
              flush=True)
        for msg in res["failures"]:
            print(f"[b1]   {msg}", flush=True)
        return 1
    print(f"[b1] {label}: CHECK PASSED", flush=True)
    return 0


def selftest():
    import run_regress as rr
    ev, rows, verdict, profiles = load_artefacts("new")
    base = judge(ev, rows, verdict, profiles)
    report(base, "recorded run")

    mutants = {
        "all req forced to 0":
            (ev, [(t, rst, 0) for t, rst, q in rows], verdict, profiles),
        "transaction records deleted":
            ({}, rows, verdict, profiles),
        "underlying verdict FAIL":
            (ev, rows, "FAIL/UVME", profiles),
        "one req bit flipped in window 1":
            (ev, [(t, rst, (1 - q) if t == 5011000 else q) for t, rst, q in rows],
             verdict, profiles),
        "one end timestamp dropped":
            ({0: ev[0], 1: {"begin": ev[1]["begin"], "dur": ev[1]["dur"],
                            "begin_count": 1, "end_count": 0},
              2: ev[2]} if len(ev) >= 3 else ev, rows, verdict, profiles),
    }
    faults = 0
    if base["failures"]:
        print("[b1] selftest: the recorded run itself does not pass", flush=True)
        faults += 1
    for name, args in mutants.items():
        res = judge(*args)
        caught = len(res["failures"]) > 0
        print(f"[b1] selftest  {'caught' if caught else 'MISSED'}  {name}"
              f"  ({len(res['failures'])} finding(s))", flush=True)
        if not caught:
            faults += 1
    return 1 if faults else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", help="run the simulation and judge it (old|new)")
    ap.add_argument("--case", default="vseq_multi_agent")
    ap.add_argument("--skip-compile", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="replay recorded artefacts through the judge")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if not args.label:
        ap.error("--label or --selftest is required")
    if not args.skip_compile:
        compile_sources()
    r, csv_path, log_path = run_probe(args.label, args.case)

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    ev = txn_events(log_text)
    rows = edge_rows(csv_path.read_text(encoding="utf-8", errors="replace"))
    profiles = parse_profiles(log_text)

    n_rst = sum(1 for t, rst, q in rows if rst != 1)
    print(f"[b1] edges: total={len(rows)} reset={n_rst} "
          f"rst_n_high={len(rows) - n_rst}", flush=True)

    res = judge(ev, rows, f"{r['status']}/{r['reason']}", profiles)
    rc = report(res, f"label={args.label}")

    probe_dir = csv_path.parent
    (probe_dir / f"b1_grant_{args.label}.json").write_text(json.dumps(
        {"label": args.label, "case": args.case,
         "verdict": f"{r['status']}/{r['reason']}",
         "edges_total": len(rows), "edges_reset": n_rst,
         "profiles": profiles, "judged": res}, indent=2), encoding="utf-8")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())