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

# The directed reset case.  Two windows with the same length, so the hand
# computed table is checkable: 100 edges, one guard, 24 edges, four reset edges,
# 76 edges.  The reset position is part of the contract, because "the driver
# handled whatever reset it saw" and "the stimulus really applied the agreed
# reset" are different claims and the probe has to make both.
EXPECTED_RESET = [
    {"always": True, "lm": 7, "lo": 11, "dp": 64, "dl": 8, "dur": 100},
    {"always": False, "lm": 11, "lo": 11, "dp": 32, "dl": 8, "dur": 100},
]
RESET_SPEC = {"segment": 1, "after_executed": 24, "length": 4}

CONTRACTS = {
    "vseq_multi_agent": {"expected": EXPECTED, "reset_spec": None},
    "grant_reset": {"expected": EXPECTED_RESET, "reset_spec": RESET_SPEC},
}

# The directed deep-stall-length case: one window per deep_len, and the same
# deep_period throughout, so global cyc decides where the stalls land.  With the
# first edge at cyc=4 and 100 executing edges per window separated by one guard
# edge, the windows cover 4-103, 105-204, 206-305, 307-406 and there are six
# multiples of 64 inside them: 64, 128, 192, 256, 320, 384.
#
# light_mod=10 / light_off=13 rather than 12/13: at cyc=192 a two-cycle stall
# ends on 193, and 194 % 12 == 2 would put a light stall on the release cycle,
# making the pin low for three cycles while the driver is still correct.  Every
# first and release cycle below was checked against the light rule:
#   T=64  -> 63, 65     T=128 -> 127, 130    T=192 -> 191, 194
#   T=256 -> 255, 271   T=320 -> 319, 336    T=384 -> 383, 400
EXPECTED_DEEP_LEN = [
    {"always": False, "lm": 10, "lo": 13, "dp": 64, "dl": 1,  "dur": 100},
    {"always": False, "lm": 10, "lo": 13, "dp": 64, "dl": 2,  "dur": 100},
    {"always": False, "lm": 10, "lo": 13, "dp": 64, "dl": 15, "dur": 100},
    {"always": False, "lm": 10, "lo": 13, "dp": 64, "dl": 16, "dur": 100},
]
# Where each stall must be, counted from the contract rather than found in the
# recording: two windows see two stalls each, and a window that silently drops
# its second one is still a failing case.
DEEP_LEN_SPEC = [
    {"window": 0, "t_cyc": 64,  "len": 1},
    {"window": 1, "t_cyc": 128, "len": 2},
    {"window": 1, "t_cyc": 192, "len": 2},
    {"window": 2, "t_cyc": 256, "len": 15},
    {"window": 3, "t_cyc": 320, "len": 16},
    {"window": 3, "t_cyc": 384, "len": 16},
]
CONTRACTS["grant_deep_len"] = {"expected": EXPECTED_DEEP_LEN,
                               "reset_spec": None,
                               "deep_len_spec": DEEP_LEN_SPEC}


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
    reset_runs = []     # (executed edges before the run, run length)
    run_start = None
    run_len = 0
    k = start_idx
    while k < len(rows):
        t, rst, req = rows[k]
        if rst != 1:
            resets += 1
            if run_start is None:
                run_start = executed
                run_len = 0
            run_len += 1
            if req != 1:
                bad.append((t, req, 1, "reset edge must be guard"))
            hold = 0
            k += 1
            continue
        if run_start is not None:
            reset_runs.append((run_start, run_len))
            run_start = None
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
            if run_start is not None:
                reset_runs.append((run_start, run_len))
            return {"end_t": t, "end_idx": k, "resets": resets, "zeros": zeros,
                    "bad": bad, "executed": executed, "reset_runs": reset_runs}
        k += 1
    if run_start is not None:
        reset_runs.append((run_start, run_len))
    return {"end_t": None, "end_idx": None, "resets": resets, "zeros": zeros,
            "bad": bad, "executed": executed, "reset_runs": reset_runs}


def judge(ev, rows, verdict, profiles, expected=None, reset_spec=None,
          period=PERIOD, deep_len_spec=None):
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

    # 0b. One row per clock.  Counting rows is not counting edges unless the
    # timestamps actually advance by one period: a duplicated row reads as an
    # extra sampling edge, and four rows carrying three distinct instants is
    # three cycles of reset, not four.  This also guards every later length
    # measurement, which is expressed in edges.
    if len(rows) < 2:
        failures.append(f"sampling record has {len(rows)} row(s)")
    else:
        gaps = sorted({b[0] - a[0] for a, b in zip(rows, rows[1:])})
        if gaps != [period]:
            failures.append(f"sampling record is not one row per clock: "
                            f"adjacent gaps {gaps}, period {period}")
        dupes = len(rows) - len({r[0] for r in rows})
        if dupes:
            failures.append(f"sampling record repeats {dupes} timestamp(s)")

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

        # The reset the case is about: the stimulus must have produced it, at
        # the agreed place, with the agreed width.  Without this the judge only
        # shows that the driver handled whatever reset it happened to see.
        if reset_spec is not None:
            row["reset_runs"] = w["reset_runs"]
            if i == reset_spec["segment"]:
                want_runs = [(reset_spec["after_executed"],
                              reset_spec["length"])]
                if w["reset_runs"] != want_runs:
                    failures.append(
                        f"txn {i}: reset runs {w['reset_runs']} "
                        f"(edges executed, width), contract says {want_runs}")
            elif w["reset_runs"]:
                failures.append(f"txn {i}: unexpected reset run "
                                f"{w['reset_runs']}, only segment "
                                f"{reset_spec['segment']} is supposed to see one")

        row["ok"] = not any(f.startswith(f"txn {i}:") for f in failures)
        prev_end_idx = w["end_idx"]

    # 2. The deep stalls, checked as positions rather than as lengths found in
    # the recording.  For every agreed trigger T the cycle before it must be
    # high, T..T+deep_len-1 must be low, and T+deep_len must be high again: the
    # last two separate "too short" from "too long", and the first catches a
    # stall that starts a cycle late.  Checking per trigger rather than "at
    # least one stall per window" is what makes a dropped second stall visible.
    if deep_len_spec:
        by_cyc = {model.cyc_of_edge(t, period): (rst, req)
                  for t, rst, req in rows}
        for spec in deep_len_spec:
            T, dl = spec["t_cyc"], spec["len"]
            if T - 1 not in by_cyc or T + dl not in by_cyc:
                failures.append(f"deep stall at cyc {T}: the recording does not "
                                f"cover cyc {T-1} to {T+dl}")
                continue
            before = by_cyc[T - 1][1]
            run = [by_cyc.get(T + j, (1, None))[1] for j in range(dl)]
            after = by_cyc[T + dl][1]
            if before != 1:
                failures.append(f"deep stall at cyc {T}: req on cyc {T-1} is "
                                f"{before}, the stall starts late")
            short = [T + j for j, q in enumerate(run) if q != 0]
            if short:
                failures.append(f"deep stall at cyc {T} of length {dl}: req is "
                                f"{[by_cyc[c][1] for c in short]} on cyc "
                                f"{short}, so it is too short")
            if after != 1:
                failures.append(f"deep stall at cyc {T} of length {dl}: req on "
                                f"cyc {T+dl} is {after}, so it is too long")

        # Independent scan: a deep stall is a low run whose first low edge sits
        # on a deep-period boundary.  The set of such starts must be exactly the
        # agreed six - no missing one, and none invented.
        dps = {p["dp"] for p in expected}
        if len(dps) == 1:
            dp = dps.pop()
            found = []
            for k, (t, rst, req) in enumerate(rows):
                if rst != 1 or req != 0:
                    continue
                prev_low = k > 0 and rows[k - 1][1] == 1 and rows[k - 1][2] == 0
                if not prev_low and model.cyc_of_edge(t, period) % dp == 0:
                    found.append(model.cyc_of_edge(t, period))
            want = [s["t_cyc"] for s in deep_len_spec]
            if found != want:
                missing = [c for c in want if c not in found]
                extra = [c for c in found if c not in want]
                failures.append(f"deep stalls observed at {found}, contract says "
                                f"{want} (missing {missing}, unexpected {extra})")

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


def judge_from_files(log_path, csv_path, verdict, case_name):
    """Judge a recorded run from the files a regression leaves behind."""
    contract = CONTRACTS.get(case_name)
    if contract is None:
        return {"table": [], "failures": [f"no directed contract for {case_name}"]}
    log_text = Path(log_path).read_text(encoding="utf-8", errors="replace")
    csv_text = (Path(csv_path).read_text(encoding="utf-8", errors="replace")
                if Path(csv_path).exists() else "")
    return judge(txn_events(log_text), edge_rows(csv_text), verdict,
                 parse_profiles(log_text),
                 expected=contract["expected"],
                 reset_spec=contract["reset_spec"],
                 deep_len_spec=contract.get("deep_len_spec"))


def synthetic_reset_run(reset_len=4, freeze_hold=False, release_low=False,
                        ack_delta=0):
    """The record a correct directed run would leave behind.

    Edges come from the contract model, so what the mutants below exercise is
    the structural part of the judge - where the reset sits, how wide it is, and
    when the transaction was acknowledged - rather than the pattern model.
    """
    period = PERIOD
    seg_a, seg_b = EXPECTED_RESET
    t_of = lambda c: 1000 + c * period  # noqa: E731
    rows = [(t_of(c), 0, 1) for c in range(4)]      # startup reset
    ev = {0: {"begin": 0, "begin_dur": seg_a["dur"], "begin_count": 1,
              "end_count": 1}}

    def run(cyc, prof, dur, hold=0):
        """Append `dur` executing edges from `cyc`; return (next cyc, hold)."""
        for _ in range(dur):
            req, hold = model.pattern(cyc, always=prof["always"],
                                      lm=prof["lm"], lo=prof["lo"],
                                      dp=prof["dp"], dl=prof["dl"], hold=hold)
            rows.append((t_of(cyc), 1, req))
            cyc += 1
        return cyc, hold

    cyc, _ = run(4, seg_a, seg_a["dur"])
    ev[0]["end"] = rows[-1][0]
    ev[0]["end_dur"] = seg_a["dur"]

    rows.append((t_of(cyc), 1, 1))          # the guard edge
    cyc += 1

    ev[1] = {"begin": ev[0]["end"], "begin_dur": seg_b["dur"],
             "begin_count": 1, "end_count": 1}
    before = RESET_SPEC["after_executed"]
    cyc, hold = run(cyc, seg_b, before)
    if reset_len:
        saved = hold
        for _ in range(reset_len):          # reset edges: guard, not executed
            rows.append((t_of(cyc), 0, 1))
            cyc += 1
        hold = saved if freeze_hold else 0
    if release_low:
        # A driver that kept its hold would drive the first cycle after release
        # low; that is the failure this case is aimed at.
        rows.append((t_of(cyc), 1, 0))
        cyc += 1
        left = seg_b["dur"] - before - 1
        hold = 0
    else:
        left = seg_b["dur"] - before
    cyc, _ = run(cyc, seg_b, left, hold=hold)
    ev[1]["end"] = rows[-1][0] + ack_delta * period
    ev[1]["end_dur"] = seg_b["dur"]
    return (ev, rows, "PASS/", list(EXPECTED_RESET))


def synthetic_deep_len_run(short=None, long_=None, drop=None):
    """The record a correct directed deep_len run would leave behind.

    short / long_ / drop index DEEP_LEN_SPEC: make one stall a cycle shorter, a
    cycle longer, or remove it entirely.  For the deep_len=1 stall "one cycle
    short" means the trigger cycle itself carries req=1, which is what a driver
    that ignored the trigger would look like - no need to send deep_len=0, a
    value the constrained range does not allow.
    """
    period = PERIOD
    t_of = lambda c: 1000 + c * period  # noqa: E731
    rows = [(t_of(c), 0, 1) for c in range(4)]      # startup reset
    ev, cyc = {}, 4
    for i, prof in enumerate(EXPECTED_DEEP_LEN):
        ev[i] = {"begin": 0 if i == 0 else rows[-1][0],
                 "begin_dur": prof["dur"], "begin_count": 1, "end_count": 1}
        hold = 0
        for _ in range(prof["dur"]):
            req, hold = model.pattern(cyc, always=prof["always"],
                                      lm=prof["lm"], lo=prof["lo"],
                                      dp=prof["dp"], dl=prof["dl"], hold=hold)
            rows.append((t_of(cyc), 1, req))
            cyc += 1
        ev[i]["end"] = rows[-1][0]
        ev[i]["end_dur"] = prof["dur"]
        if i != len(EXPECTED_DEEP_LEN) - 1:
            rows.append((t_of(cyc), 1, 1))          # guard edge
            cyc += 1
    at = {model.cyc_of_edge(t, period): k for k, (t, r, q) in enumerate(rows)}

    def put(c, val):
        k = at[c]
        t, rst, _ = rows[k]
        rows[k] = (t, rst, val)

    if short is not None:
        s = DEEP_LEN_SPEC[short]
        put(s["t_cyc"] + s["len"] - 1, 1)
    if long_ is not None:
        s = DEEP_LEN_SPEC[long_]
        put(s["t_cyc"] + s["len"], 0)
    if drop is not None:
        s = DEEP_LEN_SPEC[drop]
        for j in range(s["len"]):
            put(s["t_cyc"] + j, 1)
    return (ev, rows, "PASS/", list(EXPECTED_DEEP_LEN))


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

    # The directed reset case: the contract has to accept the run it describes
    # and reject every neighbouring failure.  These are synthetic records built
    # from the contract, so they exercise the structural checks without a
    # simulator; the real case is judged from the regression's own artefacts.
    print("[b1] selftest  directed reset contract", flush=True)
    good = judge(*synthetic_reset_run(), expected=EXPECTED_RESET,
                 reset_spec=RESET_SPEC)
    print(f"[b1] selftest  {'accepted' if not good['failures'] else 'REJECTED'}"
          f"  the agreed run ({len(good['failures'])} finding(s))", flush=True)
    if good["failures"]:
        faults += 1
        for msg in good["failures"]:
            print(f"[b1]     {msg}", flush=True)
    for name, kw in (("no reset at all", {"reset_len": 0}),
                     ("three reset edges", {"reset_len": 3}),
                     ("five reset edges", {"reset_len": 5}),
                     ("release cycle still low", {"release_low": True}),
                     ("acknowledged one cycle late", {"ack_delta": 1}),
                     ("acknowledged one cycle early", {"ack_delta": -1})):
        res = judge(*synthetic_reset_run(**kw), expected=EXPECTED_RESET,
                    reset_spec=RESET_SPEC)
        caught = len(res["failures"]) > 0
        print(f"[b1] selftest  {'caught' if caught else 'MISSED'}  {name}"
              f"  ({len(res['failures'])} finding(s))", flush=True)
        if not caught:
            faults += 1

    # A duplicated row must not read as an extra sampling edge: four rows with
    # three distinct instants is three cycles of reset, not four.
    ev_r, rows_r = synthetic_reset_run()[:2]
    dup = list(rows_r)
    k = next(i for i, r in enumerate(dup) if r[1] == 0 and r[0] > 200_000)
    dup[k] = dup[k - 1]
    res = judge(ev_r, dup, "PASS/", list(EXPECTED_RESET),
                expected=EXPECTED_RESET, reset_spec=RESET_SPEC)
    caught = len(res["failures"]) > 0
    print(f"[b1] selftest  {'caught' if caught else 'MISSED'}  "
          f"reset row duplicated instead of a fourth edge"
          f"  ({len(res['failures'])} finding(s))", flush=True)
    if not caught:
        faults += 1
    dropped = [r for r in rows_r if r[0] != rows_r[1][0]]
    res = judge(ev_r, dropped, "PASS/", list(EXPECTED_RESET),
                expected=EXPECTED_RESET, reset_spec=RESET_SPEC)
    caught = len(res["failures"]) > 0
    print(f"[b1] selftest  {'caught' if caught else 'MISSED'}  "
          f"sampling row deleted (gap in the record)"
          f"  ({len(res['failures'])} finding(s))", flush=True)
    if not caught:
        faults += 1

    # The regression's directed hook must not hide why a case really failed.
    print("[b1] selftest  directed deep_len contract", flush=True)
    res = judge(*synthetic_deep_len_run(), expected=EXPECTED_DEEP_LEN,
                deep_len_spec=DEEP_LEN_SPEC)
    print(f"[b1] selftest  {'accepted' if not res['failures'] else 'REJECTED'}"
          f"  the six agreed stalls ({len(res['failures'])} finding(s))", flush=True)
    if res["failures"]:
        faults += 1
        for msg in res["failures"]:
            print(f"[b1]     {msg}", flush=True)
    for name, kw in (("stall one cycle short (deep_len=1: trigger high)",
                      {"short": 0}),
                     ("stall one cycle short (deep_len=16: cycle 399 high)",
                      {"short": 5}),
                     ("stall one cycle long (deep_len=2, cyc 192)", {"long_": 2}),
                     ("second stall in window 1 never issued", {"drop": 2})):
        res = judge(*synthetic_deep_len_run(**kw), expected=EXPECTED_DEEP_LEN,
                    deep_len_spec=DEEP_LEN_SPEC)
        caught = len(res["failures"]) > 0
        print(f"[b1] selftest  {'caught' if caught else 'MISSED'}  {name}"
              f"  ({len(res['failures'])} finding(s))", flush=True)
        if not caught:
            faults += 1

    print("[b1] selftest  directed findings keep the underlying cause", flush=True)
    import run_regress as rr
    st, rsn, rl = rr.apply_directed(
        "INCOMPLETE", "TIMEOUT", ["TIMEOUT"],
        {"failures": ["underlying case verdict is INCOMPLETE/TIMEOUT, not PASS",
                      "sampling record has 0 row(s)"]})
    ok_low = (st == "INCOMPLETE" and rsn == "TIMEOUT"
              and any("0 row(s)" in r for r in rl)
              and not any("underlying case verdict" in r for r in rl))
    print(f"[b1] selftest  {'kept' if ok_low else 'MISATTRIBUTED'}  "
          f"timeout stays the primary cause ({st}/{rsn})", flush=True)
    if not ok_low:
        faults += 1
    st, rsn, rl = rr.apply_directed("PASS", "", [],
                                    {"failures": ["txn 1: reset runs [(24, 3)]"]})
    ok_wave = (st == "FAIL" and rsn == "DIRECTED")
    print(f"[b1] selftest  {'kept' if ok_wave else 'MISATTRIBUTED'}  "
          f"a waveform-only failure is attributed to the waveform ({st}/{rsn})",
          flush=True)
    if not ok_wave:
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

    contract = CONTRACTS.get(args.case, {"expected": EXPECTED,
                                         "reset_spec": None})
    res = judge(ev, rows, f"{r['status']}/{r['reason']}", profiles,
                expected=contract["expected"],
                reset_spec=contract["reset_spec"],
                deep_len_spec=contract.get("deep_len_spec"))
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