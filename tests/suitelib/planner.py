"""The client's path planner as its DEBUG log shows it (hopr_transport::path::planner=debug): how many candidate paths
one draw chooses from, for T33-path-pin-ab's pin check.

rebuild_candidates() logs one "weighted candidate path" line per candidate each time a destination's cache entry is
rebuilt (kind fill / background-refresh / recompute); the sampling_probability values of one rebuild sum to 1. The
return draw logs "drawing return paths from tempered weights ... candidates=N". A field's value runs to the next
" name=": `path` is the route's display form and contains spaces, and a regex that stopped at a comma folded the
cost field into the route (a working pin read as 12 routes).

candidates  the largest set one draw chose from: max(forward, return). 1 means one path at a time
churn       distinct paths per destination over the slice; above 1 even when pinned, because each refresh may pick
            a different single path. Counting distinct paths instead of candidates read a working pin as broken."""
import re

_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_FIELD = re.compile(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_.]*)=")


def fields(line):
    """name=value pairs of a log line; a value runs to the next ` name=`."""
    ms = list(_FIELD.finditer(line))
    out = {}
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(line)
        out[m.group(1)] = line[m.end():end].strip().strip('"')
    return out


def candidates(lines):
    """{lines, rebuilds, candidates, forward, return, churn, destinations} over an iterable of log lines."""
    n, ret, sizes = 0, 0, []
    open_ = {}                      # destination -> [paths of the rebuild in progress, probability sum]
    seen = {}                       # destination -> every path, for churn

    def close(dest):
        paths = open_.pop(dest, [[], 0.0])[0]
        if paths:
            sizes.append(len(paths))

    for raw in lines:
        line = _ANSI.sub("", raw)
        if "drawing return paths from tempered weights" in line:
            try:
                ret = max(ret, int(fields(line).get("candidates", 0)))
            except ValueError:
                pass
            continue
        if "weighted candidate path" not in line:
            continue
        n += 1
        f = fields(line)
        dest, path = f.get("destination", "?"), f.get("path", "")
        seen.setdefault(dest, set()).add(path)
        g = open_.get(dest)
        if g and path in g[0]:      # a path cannot appear twice in one rebuild
            close(dest)
        g = open_.setdefault(dest, [[], 0.0])
        g[0].append(path)
        try:
            g[1] += float(f.get("sampling_probability", "nan"))
        except ValueError:
            pass
        if g[1] >= 0.999:           # this rebuild's probabilities are complete
            close(dest)
    for dest in list(open_):
        close(dest)
    fwd = max(sizes, default=0)
    return {"lines": n, "rebuilds": len(sizes), "candidates": max(fwd, ret), "forward": fwd, "return": ret,
            "churn": max((len(p) for p in seen.values()), default=0), "destinations": len(seen)}
