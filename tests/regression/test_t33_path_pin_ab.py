"""T33-path-pin-ab (runbook): does spreading a session over several candidate paths cost throughput, and does pinning
the client to one path at a time help? hoprnet#8408. Arms over [connection.path_planner] in the client config:
`auto` (unchanged), `pin-planner` (max_cached_paths = 1, return_path_exploration = 0.0) and optionally `no-explore`
(return_path_exploration = 0.0 only: removes the random return draws, keeps the candidate set). PAIRS passes, the arm
order reversed on even passes (ABBA). Per arm: the keys merged into client.toml, a client restart at
hopr_transport::path::planner=debug, one session of REPS (--fast 2) transfers of BYTES both ways, and the number of
candidate paths the planner drew from in that session's log (suitelib/planner.py).

Pin check first: every pinned session must read candidates = 1, or the comparison is void (WARN, `PIN DID NOT TAKE`);
a pinned session with no planner lines is NOT VERIFIED (WARN), never a pass. An `auto` that reads <= 1 candidate has no
diversity to lose (WARN). Otherwise PASS, recording per arm the median and slowest session download, completions, and
per pair the arm/auto download ratio with a sign count. Nothing is scored against a threshold: the localcluster has
two relays at equal latency, so this checks the mechanism and the pipeline, not the field effect, which needs a real
network (the VM bench in hoprnet#8408).

Why: the field reports slow sessions, and #8408 proposes striping across paths as the cause. Three ways this
measurement went wrong before it worked: the planner log was read from the connect, after the start-up fill, so the
baseline read "-" and a pin that never took would have passed unnoticed (the log is read from before the restart);
distinct paths over a session were counted instead of candidates per draw, and a pinned planner that switches path at
every refresh read as broken; and a second [connection.path_planner] table was appended to a config that had one, which
the client refuses at start (tomlcfg.set_keys merges)."""
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


def test_path_pin_ab(cfg, run, client, target, checks, knobs):
    k = knobs
    arms = k.words("ARMS", required=True)
    unknown = [a for a in arms if a not in ARMS]
    if unknown or "auto" not in arms:
        raise ValueError(f"knob ARMS: {k.ARMS!r}; known arms {sorted(ARMS)}, and `auto` (the baseline) is required")
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
    try:
        for p in range(1, k.PAIRS + 1):
            for arm in (arms if p % 2 else list(reversed(arms))):
                got[arm].append(measure(arm, p))
    finally:
        shutil.copy(orig, cfg_file)       # the generated config and default logging come back whatever happened
        if not restart(False):
            checks.failed("restore: client restart on the original config failed; later tests start from a stopped client")

    # -- pin check: without it, the comparison is about nothing
    void = False
    for arm in arms:
        ok = [r for r in got[arm] if r]
        cands = [r["candidates"] for r in ok]
        if is_pinned(arm):
            broken = [c for c in cands if c is not None and c > 1]
            missing = sum(1 for c in cands if c is None)
            if broken:
                void = True
                checks.failed(f"PIN DID NOT TAKE: {arm} drew from {max(broken)} candidate paths in {len(broken)}/{len(ok)} sessions; "
                              f"[connection.path_planner] is not applied, the comparison is void")
            if missing:
                void = True
                checks.warn(f"{arm}: pin NOT VERIFIED in {missing}/{len(ok)} sessions (no planner lines; is {PLANNER_DEBUG} reaching the client?)")
            if ok and not broken and not missing:
                checks.passed(f"pin ok: {arm} drew from 1 candidate path in every session ({len(ok)}); churn {max(r['churn'] for r in ok)}")
        elif arm == "auto":
            known = [c for c in cands if c is not None]
            if known and max(known) <= 1:
                void = True
                checks.warn(f"auto drew from {max(known)} candidate path: the baseline has no diversity to lose, no arm can differ from it")

    # -- comparison, paired by pass against auto
    def per_arm(arm):
        ok = [r for r in got[arm] if r]
        d = [r["down"] for r in ok]
        return {"sessions": len(ok), "failed": len(got[arm]) - len(ok),
                "down_median": round(st.median(d), 3) if d else None, "down_slowest": min(d) if d else None,
                "up_median": round(st.median([r["up"] for r in ok]), 3) if ok else None,
                "transfers_complete": f"{sum(r['complete'] for r in ok)}/{sum(r['n'] for r in ok)}"}

    res = {a: per_arm(a) for a in arms}
    for arm in arms:
        if arm == "auto":
            continue
        ratios = [b["down"] / a["down"] for a, b in zip(got["auto"], got[arm]) if a and b and a["down"] > 0 and b["down"] > 0]
        res[arm]["vs_auto"] = {"median_down_ratio": round(st.median(ratios), 3) if ratios else None,
                               "faster_pairs": sum(1 for r in ratios if r > 1), "pairs": len(ratios)}
    checks.row(kind="summary", result=res, void=void)
    line = "; ".join(f"{a}: down median {r['down_median']} slowest {r['down_slowest']} Mbit/s, {r['transfers_complete']} complete"
                     + (f", {r['vs_auto']['median_down_ratio']}x auto ({r['vs_auto']['faster_pairs']}/{r['vs_auto']['pairs']} pairs faster)"
                        if "vs_auto" in r else "") for a, r in res.items())
    if void:
        checks.record(f"not comparable (see above): {line}")
    elif all(res[a]["sessions"] for a in arms):
        checks.passed(line)
    else:
        checks.warn(f"an arm has no measured session: {line}")
