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

# The acceptance contract for this probe: three windows, in this order.
#
# It is written here, and not read from either log, so that the three records
# are checked against a statement none of them can satisfy on its own.  Two
# false passes came from the absence of exactly this: dropping a window from
# both logs left the two logs agreeing with each other, and editing a duration
# in the sequence's record had nothing to disagree with.
EXPECTED = [
    {"always": False, "lm": 5, "lo": 9, "dp": 32, "dl": 4, "dur": 6000},
    {"always": True, "lm": 7, "lo": 11, "dp": 64, "dl": 8, "dur": 3000},
    {"always": False, "lm": 3, "lo": 5, "dp": 24, "dl": 10, "dur": 6000},
]


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------
def txn_events(log_text: str):
    """begin/end timestamps per transaction, from the sequence's own prints.

    The duration is kept per record: begin and end each print the duration the
    item carried, and letting the later line overwrite the earlier one hides an
    edit to exactly one of them.
    """
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
        rec[f"{phase}_dur"] = dur
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
def walk_window(rows, start_idx, prof, period=PERIOD):
    """Walk forward from a first edge decided outside the recorded end.

    This is the primary criterion.  Executing edges count; a reset edge does not
    execute, must carry req=1 and clears hold; the global cyc keeps running
    throughout.  When the count reaches the declared duration the edge reached
    is the one on which the transaction must be acknowledged, and only then is
    that time compared with what finish_item() actually returned.

    Counting forward is what makes a late acknowledgement visible: an extra edge
    at the end of the window shifts the computed completion, whereas counting
    back from the recorded end would move the supposed start with it.
    """
    dur = prof["dur"]
    hold = 0
    executed = 0
    resets = 0
    zeros = 0
    bad = []
    k = start_idx
    while k < len(rows):
        t, rst, req = rows[k]
        if rst != 1:
            resets += 1
            if req != 1:
                bad.append((t, req, 1, "reset edge must be guard"))
            hold = 0
            k += 1
            continue
        want, hold = model.pattern(model.cyc_of_edge(t, period),
                                   always=prof["always"], lm=prof["lm"],
                                   lo=prof["lo"], dp=prof["dp"], dl=prof["dl"],
                                   hold=hold)
        if req != want:
            bad.append((t, req, want, "pattern"))
        if req == 0:
            zeros += 1
        executed += 1
        if executed == dur:
            return {"end_t": t, "end_idx": k, "resets": resets, "zeros": zeros,
                    "bad": bad, "executed": executed}
        k += 1
    return {"end_t": None, "end_idx": None, "resets": resets, "zeros": zeros,
            "bad": bad, "executed": executed}


def judge(ev, rows, verdict, profiles, expected=None, period=PERIOD):
    expected = EXPECTED if expected is None else expected
    failures = []
    table = []

    # 0. Evidence has to be present before anything can be concluded.  The
    # status is compared exactly: a prefix test accepts PASS_BROKEN.
    status = verdict.split("/")[0].strip() if verdict else None
    if status is None:
        failures.append("underlying verdict missing: no result artefact")
    elif status != "PASS":
        failures.append(f"underlying case verdict is {verdict}, not PASS")

    # 1. Both logs must describe the same three windows as the contract.
    if len(profiles) != len(expected):
        failures.append(f"driver recorded {len(profiles)} profile(s), "
                        f"contract has {len(expected)}")
    for i, want in enumerate(expected):
        if i < len(profiles) and profiles[i] != want:
            diff = {k: (profiles[i].get(k), want[k]) for k in want
                    if profiles[i].get(k) != want[k]}
            failures.append(f"txn {i}: driver recorded {diff} "
                            f"(recorded, contract)")
    if len(ev) != len(expected):
        failures.append(f"{len(ev)} transaction record(s), "
                        f"contract has {len(expected)}")
    for i, want in enumerate(expected):
        rec = ev.get(i)
        if rec is None:
            failures.append(f"txn {i}: no begin/end record")
            continue
        if rec.get("begin_count", 0) != 1 or rec.get("end_count", 0) != 1:
            failures.append(f"txn {i}: {rec.get('begin_count', 0)} begin / "
                            f"{rec.get('end_count', 0)} end record(s)")
        # Both records carry the duration the item had; each is checked, so an
        # edit to one of them cannot be hidden by the other.
        for phase in ("begin", "end"):
            got = rec.get(f"{phase}_dur")
            if got is not None and got != want["dur"]:
                failures.append(f"txn {i}: {phase} record declares dur={got}, "
                                f"contract says {want['dur']}")

    # 2. Reset edges are guard edges, including outside any window.
    for t, rst, req in rows:
        if rst != 1 and req != 1:
            failures.append(f"reset edge at t={t} carries req={req}, not 1")
            break

    # 3. Forward walk per window from an independently decided first edge.
    prev_end_idx = None
    for i, prof in enumerate(expected):
        rec = ev.get(i) or {}
        begin, end = rec.get("begin"), rec.get("end")
        dur = prof["dur"]
        row = {"txn": i, "dur": dur, "begin": begin, "recorded_end": end,
               "first_edge": None, "computed_end": None, "span_edges": None,
               "resets": None, "zeros": None, "wave_mismatch": None, "ok": False}
        table.append(row)
        if begin is None:
            failures.append(f"txn {i}: no begin record to anchor the window")
            continue

        if prev_end_idx is None:
            # Window 0 starts at the first sampling edge after the item was
            # handed over, which is also the first edge out of reset.
            start = next((k for k in range(len(rows))
                          if rows[k][0] >= begin and rows[k][1] == 1), None)
        else:
            guard = prev_end_idx + 1
            if guard >= len(rows):
                failures.append(f"txn {i}: no edge after the previous window")
                continue
            if rows[guard][2] != 1:
                failures.append(f"txn {i}: guard edge at t={rows[guard][0]} "
                                f"carries req={rows[guard][2]}, not 1")
            start = next((k for k in range(guard + 1, len(rows))
                          if rows[k][1] == 1), None)
        if start is None:
            failures.append(f"txn {i}: no sampling edge to start the window")
            continue

        w = walk_window(rows, start, prof, period)
        row.update({"first_edge": rows[start][0], "computed_end": w["end_t"],
                    "span_edges": w["executed"], "resets": w["resets"],
                    "zeros": w["zeros"], "wave_mismatch": len(w["bad"])})
        if w["end_t"] is None:
            failures.append(f"txn {i}: window did not complete in the "
                            f"recording ({w['executed']} of {dur} edges)")
            continue
        if end is None:
            failures.append(f"txn {i}: no end record to compare against")
        elif end != w["end_t"]:
            delta = (end - w["end_t"]) // period
            failures.append(f"txn {i}: finish_item() returned at t={end}, "
                            f"computed completion {w['end_t']} "
                            f"({delta:+d} cycle(s))")
        for t, req, want, kind in w["bad"][:3]:
            failures.append(f"txn {i}: edge t={t} req={req} expected {want} "
                            f"({kind})")
        if row["span_edges"] != dur:
            failures.append(f"txn {i}: window executed {row['span_edges']} "
                            f"edge(s), declared {dur}")

        row["ok"] = not any(f.startswith(f"txn {i}:") for f in failures)
        prev_end_idx = w["end_idx"]

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
    """Recorded evidence for `label`.

    A missing result file or a file without a verdict is reported as None, not
    defaulted to PASS: absent evidence and a passing case have to stay
    distinguishable, or every check downstream of it is optional.
    """
    import run_regress as rr
    probe_dir = rr.OUT / "probe"
    csv_path = probe_dir / f"b1_grant_{label}.csv"
    log_path = rr.OUT / "logs" / f"regress_b1_audit_{label}.log"
    json_path = probe_dir / f"b1_grant_{label}.json"
    verdict = None
    if json_path.exists():
        verdict = json.loads(json_path.read_text(encoding="utf-8")).get("verdict")
    missing = [str(p) for p in (csv_path, log_path, json_path) if not p.exists()]
    if missing:
        print(f"[b1] missing evidence: {', '.join(m.split(chr(92))[-1] for m in missing)}",
              flush=True)
    csv_text = csv_path.read_text(encoding="utf-8", errors="replace") \
        if csv_path.exists() else ""
    log_text = log_path.read_text(encoding="utf-8", errors="replace") \
        if log_path.exists() else ""
    return (txn_events(log_text), edge_rows(csv_text), verdict,
            parse_profiles(log_text))


def report(res, label):
    print(f"[b1] {'txn':>3} {'dur':>6} {'first':>10} {'computed':>10} "
          f"{'recorded':>10} {'exec':>5} {'rst':>4} {'req=0':>6} {'wave':>5}  "
          f"result", flush=True)
    for r in res["table"]:
        f = lambda v: "-" if v is None else str(v)  # noqa: E731
        print(f"[b1] {r['txn']:>3} {f(r['dur']):>6} {f(r['first_edge']):>10} "
              f"{f(r['computed_end']):>10} {f(r['recorded_end']):>10} "
              f"{f(r['span_edges']):>5} {f(r['resets']):>4} "
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
    log_text = (rr.OUT / "logs" / "regress_b1_audit_new.log").read_text(
        encoding="utf-8", errors="replace")
    base = judge(ev, rows, verdict, profiles)
    report(base, "recorded run")

    # Timing mutants act on the recorded end timestamp: a late or early
    # acknowledgement is exactly the failure this probe exists to catch, so both
    # directions have to be red.
    def shifted(delta):
        return {k: (dict(v, end=v["end"] + delta) if v.get("end") is not None
                    else v) for k, v in ev.items()}

    # The duration edit is injected into the raw log text rather than into the
    # parsed record, so the parser is exercised along with the judge.
    edited_log = log_text.replace("txn 0 begin t=0 dur=6000",
                                  "txn 0 begin t=0 dur=17", 1)
    ev_edited = txn_events(edited_log)

    mutants = {
        "all req forced to 0":
            (ev, [(t, rst, 0) for t, rst, q in rows], verdict, profiles),
        "transaction records deleted":
            ({}, rows, verdict, profiles),
        "underlying verdict FAIL":
            (ev, rows, "FAIL/UVME", profiles),
        "underlying verdict missing":
            (ev, rows, None, profiles),
        "underlying verdict PASS_BROKEN":
            (ev, rows, "PASS_BROKEN/", profiles),
        "one req bit flipped in window 1":
            (ev, [(t, rst, (1 - q) if t == 5011000 else q) for t, rst, q in rows],
             verdict, profiles),
        "one end timestamp dropped":
            ({0: ev[0], 1: {"begin": ev[1]["begin"], "end_count": 0,
                            "begin_count": 1},
              2: ev[2]} if len(ev) >= 3 else ev, rows, verdict, profiles),
        # Both logs lose window 2 together: they still agree with each other,
        # so only a statement from outside both can catch it.
        "window 2 dropped from both logs":
            ({k: v for k, v in ev.items() if k != 2}, rows, verdict,
             [p for i, p in enumerate(profiles) if i != 2]),
        "begin-record duration edited (raw log)":
            (ev_edited, rows, verdict, profiles),
        "driver-side params edited":
            (ev, rows, verdict,
             [dict(profiles[0], dp=33)] + profiles[1:]),
        "acknowledgement one cycle late":
            (shifted(2000), rows, verdict, profiles),
        "acknowledgement one cycle early":
            (shifted(-2000), rows, verdict, profiles),
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