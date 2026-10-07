"""T33-path-pin-ab (runbook): does spreading a session over several candidate paths cost throughput, and does pinning
the client to one path at a time help? hoprnet#8408. Arms over [connection.path_planner] in the client config:
`auto` (unchanged), `pin-planner` (max_cached_paths = 1, return_path_exploration = 0.0) and optionally `no-explore`
(return_path_exploration = 0.0 only: removes the random return draws, keeps the candidate set). PAIRS passes, the arm
order reversed on even passes (ABBA). Per arm: the keys merged into client.toml, a client restart at
hopr_transport::path::planner=debug, one session of REPS (--fast 2) transfers of BYTES both ways, and the number of
candidate paths the planner drew from in that session's log (suitelib/planner.py).

Pin check first: every pinned session must read candidates = 1, or the comparison is void (WARN, `PIN DID NOT TAKE`); a
pinned or `auto` session with no planner lines is NOT VERIFIED (WARN), never a pass. An `auto` that reads <= 1 candidate
has no diversity to lose (WARN). Otherwise PASS.

Output: the bandwidth comparison is written to t33-bandwidth.md in the run directory and printed to the console: per arm
the median, minimum and maximum session throughput in each direction; per non-auto arm and direction the median
arm/auto ratio over pairs, the number of pairs in which the arm was higher, and the two-sided sign-test p-value; and
every pair side by side. t33-sessions.csv has one row per session. Nothing is scored against a threshold: the
localcluster has two relays at equal latency, so this checks the mechanism and the pipeline, not the field effect,
which needs a real network (the VM bench in hoprnet#8408).

Why: the field reports slow sessions, and #8408 proposes striping across paths as the cause. Three ways this
measurement went wrong before it worked: the planner log was read from the connect, after the start-up fill, so the
baseline read "-" and a pin that never took would have passed unnoticed (the log is read from before the restart);
distinct paths over a session were counted instead of candidates per draw, and a pinned planner that switches path at
every refresh read as broken; and a second [connection.path_planner] table was appended to a config that had one, which
the client refuses at start (tomlcfg.set_keys merges)."""
import csv
import math
import os
import shutil
import statistics as st

from suitelib import planner, shell, tomlcfg
from suitelib.client import ConnectFailed
from suitelib.config import q
from suitelib.target import summary_row, transfer_series
from suitelib.verdicts import utc_now

TEST = "T33-path-pin-ab"
KIND = "runbook"
KNOBS = dict(PAIRS=q(6, 3), ARMS="auto pin-planner")
TIMEOUT = lambda k: (k.PAIRS * len(k.words("ARMS")) + 1) * 1800   # seconds: a restart (up to 600 s to Ready) plus transfers per arm
SECTION = "[connection.path_planner]"
ARMS = {
    "auto": {},
    "pin-planner": {"max_cached_paths": "1", "return_path_exploration": "0.0"},
    "no-explore": {"return_path_exploration": "0.0"},
}
DEFAULT_LOG_LEVEL = "warn,gnosis_vpn_root=debug,gnosis_vpn_lib=debug,gnosis_vpn_worker=debug"   # the justfile's default
PLANNER_DEBUG = "hopr_transport::path::planner=debug"


def is_pinned(arm):
    return ARMS[arm].get("max_cached_paths") == "1"


def parse_arms(words):
    """The ARMS knob as a list: `auto` (the baseline) plus at least one other known arm, each once. ARMS="auto" alone
    compared nothing and passed; a repeated arm shifted the pairing against auto."""
    unknown = sorted({a for a in words if a not in ARMS})
    dupes = sorted({a for a in words if words.count(a) > 1})
    if unknown or dupes or "auto" not in words or len(words) < 2:
        raise ValueError(f"knob ARMS: {' '.join(words)!r}; needs `auto` and at least one other arm, each once "
                         f"(known {sorted(ARMS)}; unknown {unknown}, repeated {dupes})")
    return words


def test_path_pin_ab(cfg, run, client, target, checks, knobs):
    k = knobs
    arms = parse_arms(k.words("ARMS", required=True))
    if cfg.no_cluster:
        checks.skip("needs the testenv client and its generated config (not a --no-cluster run)")
    cfg_file = cfg.config_dir / "client.toml"
    if not cfg_file.exists():
        checks.skip(f"no client config at {cfg_file} (just gen-config)")
    orig = run / "client.toml.t33.orig"
    shutil.copy(cfg_file, orig)
    cwd = str(cfg.testenv_dir)
    level = cfg.env.get("CLIENT_LOG_LEVEL") or DEFAULT_LOG_LEVEL

    def restart(debug):
        env = dict(os.environ, CLIENT_LOG_LEVEL=f"{level},{PLANNER_DEBUG}" if debug else level)
        ok = shell.ok("just client-stop", timeout=120, cwd=cwd) and shell.ok("just client-start", timeout=300, cwd=cwd, env=env)
        return ok and client.wait_worker(180) and client.wait_dest_ready(cfg.dest, 600)

    def measure(arm, p):
        shutil.copy(orig, cfg_file)
        if ARMS[arm]:
            tomlcfg.set_keys(cfg_file, SECTION, **ARMS[arm])
        since = utc_now()          # before the restart: the planner fills its cache while the client comes up
        if not restart(True):
            checks.failed(f"{arm} pass {p}: client restart failed")
            return None
        try:
            s = client.connect(cfg.dest, 0)
        except ConnectFailed as e:
            checks.row(arm=arm, pair=p, connect_failed=str(e)[:300])
            return None
        with s:
            summ = transfer_series(checks, client, f"t33-{arm}-p{p}", target.ip, cfg.q(cfg.reps, 2), cfg.bytes, cfg.cap)
            e = s.errors()
        plan = planner.candidates(client.log_lines(since))
        res = {"down": summ["down_median"], "up": summ["up_median"], "complete": summ["down_complete"] + summ["up_complete"],
               "n": 2 * summ["n"], "candidates": plan["candidates"] if plan["lines"] else None, "churn": plan["churn"]}
        checks.row(arm=arm, pair=p, summary=summary_row(summ), planner=plan, errors=e)
        checks.log(f"{arm} pass {p}: down {res['down']} up {res['up']} Mbit/s, candidates {res['candidates']}, churn {res['churn']}")
        return res

    got = {a: [] for a in arms}           # per arm, one entry per pass (None when the arm could not be measured)
    orders = []                           # per pass, the arm order (ABBA)
    try:
        for p in range(1, k.PAIRS + 1):
            orders.append(arms if p % 2 else list(reversed(arms)))
            for arm in orders[-1]:
                got[arm].append(measure(arm, p))
    finally:
        shutil.copy(orig, cfg_file)       # the generated config and default logging come back whatever happened
        if not restart(False):
            checks.failed("restore: client restart on the original config failed; later tests start from a stopped client")

    # -- pin check: without it, the comparison is about nothing
    issues = []
    for arm in arms:
        ok = [r for r in got[arm] if r]
        cands = [r["candidates"] for r in ok]
        if is_pinned(arm):
            broken = [c for c in cands if c is not None and c > 1]
            missing = sum(1 for c in cands if c is None)
            if broken:
                issues.append(f"PIN DID NOT TAKE: {arm} drew from {max(broken)} candidate paths in {len(broken)}/{len(ok)} sessions")
                checks.failed(f"{issues[-1]}; [connection.path_planner] is not applied, the comparison is void")
            if missing:
                issues.append(f"{arm}: pin NOT VERIFIED in {missing}/{len(ok)} sessions (no planner lines)")
                checks.warn(f"{issues[-1]}; is {PLANNER_DEBUG} reaching the client?")
            if ok and not broken and not missing:
                checks.passed(f"pin ok: {arm} drew from 1 candidate path in every session ({len(ok)}); churn {max(r['churn'] for r in ok)}")
        elif arm == "auto":
            known = [c for c in cands if c is not None]
            if len(known) < len(cands):
                issues.append(f"auto: candidates NOT VERIFIED in {len(cands) - len(known)}/{len(ok)} sessions (no planner lines)")
                checks.warn(f"{issues[-1]}; the baseline's path diversity is unknown")
            if known and max(known) <= 1:
                issues.append(f"auto drew from {max(known)} candidate path: the baseline has no path diversity to lose")
                checks.warn(issues[-1])

    # -- the bandwidth comparison
    cmp = compare(got, arms)
    report = render(cmp, got, orders, issues, f"PAIRS={k.PAIRS}, {cfg.q(cfg.reps, 2)} x {cfg.bytes / 1e6:g} MB each way per session")
    (run / "t33-bandwidth.md").write_text(report)
    write_sessions_csv(run / "t33-sessions.csv", got, orders)
    print(report, flush=True)
    checks.row(kind="summary", result=cmp, void=bool(issues))

    line = "; ".join(f"{a} vs auto: " + ", ".join(f"{d}load {c['change_pct']:+.1f} % ({c['higher']}/{c['pairs']} pairs higher, p = {c['p_sign']})"
                                                  for d in ("down", "up") if (c := r[f"{d}_vs_auto"])["pairs"])
                     for a, r in cmp["arms"].items() if a != "auto" and r["down_vs_auto"]["pairs"])
    line = (line or "no valid pair") + " - table in t33-bandwidth.md"
    if issues:
        checks.record(f"not comparable ({'; '.join(issues)}): {line}")
    elif all(cmp["arms"][a]["sessions"] for a in arms) and all(cmp["arms"][a]["down_vs_auto"]["pairs"] for a in arms if a != "auto"):
        checks.passed(line)
    else:
        checks.warn(f"an arm has no measured session or no valid pair against auto: {line}")


# -- comparison and report: pure functions over `got` ({arm: [session result or None per pass]}), see the selftest

def sign_test_p(higher, lower):
    """Two-sided exact sign test (ties dropped): the probability of a split at least this uneven if neither arm is
    faster. 6/6 gives 0.031, 5/6 gives 0.22, so fewer than 6 pairs can never reach p < 0.05."""
    n = higher + lower
    if n == 0:
        return None
    tail = sum(math.comb(n, i) for i in range(min(higher, lower) + 1)) / 2 ** n
    return round(min(1.0, 2 * tail), 3)


def reading(c):
    if not c["pairs"]:
        return "no valid pair"
    if c["p_sign"] is not None and c["p_sign"] < 0.05:
        return f"{'higher' if c['change_pct'] > 0 else 'lower'} than auto in a consistent direction"
    if c["pairs"] < 6:
        return "too few pairs for a conclusion (at least 6 are needed)"
    return "no consistent difference"


def compare(got, arms):
    def spread(xs):
        return {"median": round(st.median(xs), 3), "min": min(xs), "max": max(xs)} if xs else None

    out = {"arms": {}}
    for a in arms:
        ok = [r for r in got[a] if r]
        cands = [r["candidates"] for r in ok if r["candidates"] is not None]
        out["arms"][a] = {"sessions": len(ok), "failed": len(got[a]) - len(ok),
                          "down": spread([r["down"] for r in ok]), "up": spread([r["up"] for r in ok]),
                          "transfers_complete": f"{sum(r['complete'] for r in ok)}/{sum(r['n'] for r in ok)}",
                          "candidates": f"{min(cands)}-{max(cands)}" if cands and min(cands) != max(cands) else (str(cands[0]) if cands else None)}
    for a in arms:
        if a == "auto":
            continue
        for d in ("down", "up"):
            ratios = [y[d] / x[d] for x, y in zip(got["auto"], got[a]) if x and y and x[d] > 0 and y[d] > 0]
            med = st.median(ratios) if ratios else None
            higher, lower = sum(1 for r in ratios if r > 1), sum(1 for r in ratios if r < 1)
            c = {"ratio_median": round(med, 3) if med else None, "change_pct": round((med - 1) * 100, 1) if med else 0.0,
                 "higher": higher, "lower": lower, "pairs": len(ratios), "p_sign": sign_test_p(higher, lower)}
            c["reading"] = reading(c)
            out["arms"][a][f"{d}_vs_auto"] = c
    return out


def _f(x):
    return "-" if x is None else f"{x:.2f}"


def render(cmp, got, orders, issues, setup):
    arms = list(cmp["arms"])
    L = ["## T33-path-pin-ab: bandwidth, automatic path finding vs pinned path", "",
         f"Setup: {setup}. Throughput is the median over one session's transfers, in Mbit/s.", "",
         ("**Not comparable:** " + "; ".join(issues)) if issues else
         "Validity checks: passed (every pinned session drew from 1 candidate path, auto from more than 1).", "",
         "### Per arm", "",
         "| Arm | Sessions | Download median | Download min-max | Upload median | Upload min-max | Transfers complete | Candidates per draw |",
         "|---|---|---|---|---|---|---|---|"]
    for a, r in cmp["arms"].items():
        dn, up = r["down"] or {}, r["up"] or {}
        sessions = f"{r['sessions']} ({r['failed']} failed)" if r["failed"] else str(r["sessions"])
        L.append(f"| {a} | {sessions} | {_f(dn.get('median'))} | {_f(dn.get('min'))}-{_f(dn.get('max'))} | "
                 f"{_f(up.get('median'))} | {_f(up.get('min'))}-{_f(up.get('max'))} | {r['transfers_complete']} | {r['candidates'] or '-'} |")
    L += ["", "### Compared with auto (paired by pass)", "",
          "| Arm | Direction | Median ratio | Change | Pairs higher / lower | Sign test p | Reading |",
          "|---|---|---|---|---|---|---|"]
    for a, r in cmp["arms"].items():
        for d in ("down", "up"):
            c = r.get(f"{d}_vs_auto")
            if c:
                L.append(f"| {a} | {d}load | {_f(c['ratio_median'])} | {c['change_pct']:+.1f} % | {c['higher']} / {c['lower']} of {c['pairs']} | "
                         f"{'-' if c['p_sign'] is None else c['p_sign']} | {c['reading']} |")
    L += ["", "### Per pair (download / upload, Mbit/s)", "",
          "| Pair | Order | " + " | ".join(arms) + " |", "|---|---|" + "---|" * len(arms)]
    for p, order in enumerate(orders):
        cells = []
        for a in arms:
            r = got[a][p] if p < len(got[a]) else None
            cells.append(f"{_f(r['down'])} / {_f(r['up'])}" if r else "failed")
        L.append(f"| {p + 1} | {', '.join(order)} | " + " | ".join(cells) + " |")
    L += ["", "A ratio above 1 means the arm was faster than auto. With fewer than 6 pairs no split reaches p < 0.05. On the "
          "localcluster both relays have equal latency, so a ratio near 1 is the expected result; the field effect needs "
          "a real network.", ""]
    return "\n".join(L)


def write_sessions_csv(path, got, orders):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["pair", "position", "arm", "down_mbit", "up_mbit", "transfers_complete", "transfers", "candidates", "churn"])
        for p, order in enumerate(orders):
            for pos, a in enumerate(order, 1):
                r = got[a][p] if p < len(got[a]) else None
                vals = [r["down"], r["up"], r["complete"], r["n"], r["candidates"], r["churn"]] if r else [""] * 6
                w.writerow([p + 1, pos, a, *vals])
