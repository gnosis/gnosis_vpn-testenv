# End-to-end browser tests

Repeatable end-to-end measurement of every Gnosis VPN destination from a real
headless browser. For each destination it browses real sites, crawls a light
site link-by-link, runs a Cloudflare speedtest, and samples ICMP latency —
dumping everything to JSON + CSV so a run **before** a change can be diff'd
against a run **after**.

The VPN is full-tunnel, so no proxy config is needed: once a destination is
connected, all traffic from inside the tunnel's network namespace egresses
through it.

## Run

```sh
just up                              # bring the whole stack up
just e2e                             # every destination the client reports
just e2e --quick                     # short profile, a couple of minutes
just e2e --destination node-<peer-id>
just down
```

`just e2e` builds the sidecar image first. Nothing has to be spawned by hand.

## How it runs

```
host                                  docker
────                                  ──────
e2e/run.sh  ──ctl──►  docker exec gnosis_vpn-client gnosis_vpn-ctl
     │
     └─ docker run --rm --network container:gnosis_vpn-client  gnosis_vpn-e2e
              │
              ├─ obscura serve --port 9222 --stealth
              └─ node harness.mjs
```

The client container's network namespace is the only place the full-tunnel
`0.0.0.0/1` + `128.0.0.0/1` WireGuard routes exist, so the browser and `ping`
run in a sidecar that joins it via `--network container:`. `run.sh` stays on the
host and reaches `gnosis_vpn-ctl` through `docker exec`, so no socket is
bind-mounted.

`--client-mode host` instead drives a client running natively on this host
(`just up-client-on-host`, or a remote network like rotsee) and starts obscura
on the host. That mode needs `node` and `obscura` on `PATH`.

## What it measures (per destination)

- **Site visits** — YouTube, CNN, Wikipedia, BBC, GitHub, Reddit, Amazon:
  per-page DOMContentLoaded / load time, HTTP status, failed sub-requests,
  outcome (`ok` / `http_error` / `timeout` / `error`).
- **YouTube playback** — one video drawn per run from a pool with known native
  ceilings (2160p ×2, 240p). The pick is stored in the JSON so runs stay
  comparable; rotating it stops one edge-cached asset from defining the numbers.
  `run.sh` draws the index once per run (`YT_VIDEO_INDEX`) so every destination
  is compared on the same video. See the caveat below.
- **Link crawl** — from a random Wikipedia article, follow `CRAWL_HOPS`
  (default 5) internal links, timing each hop and never revisiting an article.
  One-shot page loads measure asset weight; this measures how fast you can
  actually move around behind the tunnel.
- **Speedtest** — download / upload Mbps, latency (min/avg/max/median), jitter,
  against `speed.cloudflare.com` `__down`/`__up`. Two passes by default
  (`SPEEDTEST_RUNS`) for within-destination variance.
- **ICMP latency** — continuous `ping` to each `PING_TARGETS` entry for the
  whole destination window: min/avg/max/loss. Default `1.1.1.1` plus the tunnel
  gateway `10.129.0.1` (the wg peer address `gen-config` writes into
  `client.toml`).
- **Egress trace** — Cloudflare `trace` (`ip`, `loc`, `colo`) recorded as
  **metadata only**. Every testenv exit NATs through the same host, so `loc`
  carries no signal here and never causes a destination to be skipped.

## Output

Written to `$E2E_OUT_DIR/<UTC-timestamp>/` (default
`/tmp/gnosis_vpn-testenv-e2e/<ts>/`):

- `<ID>.json` — full per-destination record (egress, navigations, crawl,
  speedtests, ping).
- `<ID>.nerdstats.json` — `nerd-stats` snapshot (hop path, route rtt, sessions).
- `summary.csv` — one row per destination, the headline numbers. Also printed to
  stdout at the end of a run, so it can be piped straight into another tool.
- `meta.json` — run label: timestamp, component commits, `CLUSTER_SIZE` /
  `SERVER_COUNT` / `HOPS`, machine, and the disconnected-baseline egress. **This
  is what makes two runs comparable.**

## Knobs

All env vars, all optional: `NAV_TIMEOUT_MS`, `DOWNLOAD_SECS`, `UPLOAD_SECS`,
`DWELL_MS`, `CRAWL_START`, `CRAWL_HOPS`, `SPEEDTEST_RUNS`, `YT_VIDEO_INDEX`,
`PING_TARGETS`, `SETTLE_SECS`, `CONNECT_TIMEOUT`, `CLIENT_CONTAINER`,
`E2E_IMAGE`, `E2E_OUT_DIR`. `run.sh --help` lists the flags.

`--quick` is shorthand for
`DOWNLOAD_SECS=20 UPLOAD_SECS=10 CRAWL_HOPS=2
SPEEDTEST_RUNS=1`.

## Files

| File            | Role                                                                       |
| --------------- | -------------------------------------------------------------------------- |
| `run.sh`        | orchestrator: connect / settle / drive / disconnect / aggregate            |
| `harness.mjs`   | per-destination driver over obscura CDP (browsing, crawl, speedtest, ping) |
| `aggregate.mjs` | builds `summary.csv` + prints the table                                    |
| `Dockerfile`    | sidecar image: node + obscura (pinned per arch) + the harness              |
| `entrypoint.sh` | starts obscura's CDP server, then runs the harness                         |

## Notes & caveats (learned the hard way)

- **obscura ~30 s cap.** obscura aborts any single CDP `page.evaluate`
  (`Runtime.callFunctionOn`) **and** `page.goto` at ~30 s. The speedtest is
  therefore chunked into short Node-orchestrated calls with adaptive sizing, and
  every in-page fetch has an `AbortController` < 30 s so a stall fails
  gracefully instead of killing the run. Don't reintroduce a single long-running
  `evaluate`.
- **Heavy pages over a capped tunnel.** A 4–5 MB page (YouTube/CNN) may not
  finish DOMContentLoaded within obscura's 30 s over a ~2 Mbps tunnel → recorded
  as `timeout`/`error`. That's a real signal, not a harness bug. Reddit returns
  403 to the headless UA. Light pages (Wikipedia/BBC/GitHub/Amazon) render fine.
- **Throughput cap.** Download is paced by SURB balancing
  (`[connection.surb_balancing.main] max_surb_upstream`). The speedtest reads
  whatever the tunnel allows — that IS the measurement. Raising the cap needs a
  config edit + client restart.
- **YouTube playback does not actually start under obscura.** The harness asks
  for muted playback and then records `playing`, `width`/`height`, `quality` and
  `played_s`, but in practice obscura leaves the player paused at 0×0 with
  quality `unknown` — so `yt_res` is usually blank. What the watch page
  therefore measures is page + player load, not video decode. The recorded
  fields are there so the number appears by itself if a future obscura build can
  play; the pool entry's `max_res` is the upload's ceiling, never a forced
  target.
- **"connected" ≠ routing.** The control plane can report connected while
  traffic still egresses locally, or while the exit health is flapping. `run.sh`
  waits `SETTLE_SECS` after connect before measuring; raise it if early probes
  look wrong. If a destination is stuck `Routable`/`Unrecoverable`, wait for it
  to reach `ReadyToConnect`.
