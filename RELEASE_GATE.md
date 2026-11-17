# Release gate

Before a hoprd release reaches users, run the GnosisVPN client (v5,
gnosis_vpn-client `main`) through every exit of a staging network and check that
real browsing works through each one. The default network is
**piz-palu-staging**.

```sh
nix develop -c env GVPN_IDENTITY=<identity> GATE_HOPRD_VERSION=5.0.3-pr.287 just release-gate-preflight
nix develop -c env GVPN_IDENTITY=<identity> GATE_HOPRD_VERSION=5.0.3-pr.287 just release-gate
```

It exits `0` on **PASS** and non-zero otherwise, and writes a `report.md` you
can paste into the release PR.

`GATE_HOPRD_VERSION` is a label: the gate cannot check which hoprd the network
runs. Deploy the release candidate to the network first, then set the version
you deployed. The client is taken as prebuilt binaries; the gate never builds
it.

## What it does

1. **Preflight** checks every prerequisite below and lists all the problems it
   finds in one pass. It connects nothing.
2. **Identity.** Extracts `GVPN_IDENTITY` from products-ci
   `identities/<network>.yaml` (`identityFile`, `safeAddress`, `moduleAddress`)
   and the network's identity password from `identities/secrets.sops.yaml` into
   a `0700` temp dir. The dir is deleted when the run ends. The password goes to
   a file and the environment, never to a command line or a log.
3. **Tour.** Runs `just e2e-on-network` (`e2e/run.sh` in spawn mode): starts its
   own `gnosis_vpn-root` from `GATE_CLIENT_BIN_DIR` with
   [`configs/<network>/config.toml`](configs/piz-palu-staging/config.toml),
   waits for the node to run and to discover the exits, then for each exit:
   - Wait until it is `routable`, then connect.
   - Run the headless-browser pass: sites, crawl, Cloudflare speedtest, ping.
   - Download 100 MB three times.
   - Disconnect.

   The daemon is stopped at the end, including on Ctrl-C.
4. **Verdict.** Writes `verdict.json` and `report.md` next to `summary.csv`.
5. **Cleanup.** Spawn mode copies the identity and password to
   `~/.local/share/gnosisvpn/networks/<network>/hopr.{id,pass}`, where the
   worker reads them. The gate removes both again, unless they were there before
   the run.

### What fails the gate

An exit **FAILS** if any of these happens:

- It never becomes `routable` within `DEST_READY_TIMEOUT` (default 180 s).
- It does not connect within `CONNECT_TIMEOUT` (default 150 s).
- The harness crashes.
- Any of **wikipedia, bbc, github, amazon** does not load `ok`.

The gate fails if **any** exit fails, if the client discovers no exit at all, or
if the run ends without a verdict.

The following are recorded but never fail the gate:

- YouTube, CNN and Reddit. They are too heavy for a capped tunnel, or they block
  headless browsers.
- Speedtest numbers, the 100 MB downloads, ping and crawl.

To judge on other sites, set `GATE_REQUIRED_SITES=wikipedia,bbc` (labels come
from `SITES` in `e2e/harness.mjs`).

The gate judges the exits the client discovers. An exit missing from discovery
is not tested: check the exit list in `report.md` against the network's
inventory.

### How long it takes

Each exit takes about 10 min of browsing plus up to 14 min of downloads, so plan
for 25 min per exit. Keep the machine awake.

`--quick` runs one speedtest pass, 2 crawl hops and one 100 MB pull in a 5-min
window, about 10 min per exit. Use it to check your setup, not to sign off a
release.

> **Full tunnel.** While the gate runs, all of this machine's traffic goes out
> through the exit under test. Don't run it on a call.

## One-time setup

1. **Nix** with flakes. `nix develop` supplies obscura, node, yq, sops and a
   curl with HTTP/3.
2. **Clone the sibling repos** next to this one, or set `GVPN_CLIENT_DIR`
   (`GATE_CLIENT_BIN_DIR`) / `PRODUCTS_CI_DIR`.
   ```
   hopr/
   ├── gnosis_vpn-testenv/   (this repo)
   ├── gnosis_vpn-client/
   └── products-ci/
   ```
3. **Build the client** you gate:
   ```sh
   cd ../gnosis_vpn-client && git switch main && git pull
   cargo build --release -p gnosis_vpn-root -p gnosis_vpn-worker -p gnosis_vpn-ctl
   ```
   The gate records the checkout's `HEAD` (with `-dirty` for local changes) and
   `gnosis_vpn-root --version`. It cannot prove the binaries were built from
   that `HEAD`, so rebuild after switching commits.
4. **Install the client's data files.** A `version = 7` config needs the country
   database and the Curvy proving files where the installer puts them:
   `/usr/share/gnosisvpn/geoip.mmdb` and `/usr/share/gnosisvpn/curvy-zk/`
   (macOS: under `/usr/local/share/gnosisvpn/`). Installing the gnosisvpn
   package provides both; the client's `just system-tests` recipe shows the
   downloads. Stop the installed service before a run
   (`sudo systemctl stop gnosisvpn`).
5. **Get sops access.** You need an age key whose public key is a recipient of
   `products-ci/identities/secrets.sops.yaml`, at `SOPS_AGE_KEY_FILE` (default
   `~/.config/sops/age/keys.txt`, on macOS too). The recipients are the shared
   "Apps" and "Devops" keys from the password manager. The file holds one
   `AGE-SECRET-KEY-1…` per line; every other line, including the `age1…` public
   key, must start with `#`, or sops fails with `unknown identity type`.
6. **Pick the gate identity.** `GVPN_IDENTITY` names an entry of
   `products-ci/identities/<network>.yaml`. There is no default. Two clients on
   one identity announce the same peer and fight over its channels, so never run
   the gate on an identity another client uses at the same time.
7. **Check your setup:**
   `GVPN_IDENTITY=… GATE_HOPRD_VERSION=… just release-gate-preflight`.

Preflight checks: the three binaries, the tools, the age key and that sops
decrypts the password, the identity in the yaml, that Blokli answers with the
expected `chainInfo.network`, the data files, that no `gnosis_vpn-root` is
running, and that no other identity or password sits in your per-network data
dir.

You need `sudo`: `gnosis_vpn-root` creates the WireGuard interface and edits the
routing table. The run asks once, then keeps the sudo timestamp alive.

## Running it

```sh
export GVPN_IDENTITY=<identity> GATE_HOPRD_VERSION=5.0.3-pr.287

just release-gate                           # the real gate, piz-palu-staging
just release-gate --quick                   # ~10 min/exit setup check
just release-gate --quick --destination ID  # one exit (ids: gnosis_vpn-ctl status)
```

Everything after the recipe name goes to `e2e/run.sh`: `--quick`,
`--destination ID…`, `--download-runs N`, `--download-window SECS`,
`--download-url URL`, `--no-browser` (a `--no-browser` run is never PASS).

| Variable              | Default                           | What it is                                       |
| --------------------- | --------------------------------- | ------------------------------------------------ |
| `GVPN_IDENTITY`       | required                          | identity name in products-ci                     |
| `GATE_HOPRD_VERSION`  | required                          | hoprd version under test, recorded in the report |
| `GATE_NETWORK`        | `piz-palu-staging`                | a `configs/<network>/` dir                       |
| `GATE_CLIENT_BIN_DIR` | `$GVPN_CLIENT_DIR/target/release` | dir with root, worker and ctl                    |
| `PRODUCTS_CI_DIR`     | `../products-ci`                  | products-ci checkout                             |
| `SOPS_AGE_KEY_FILE`   | `~/.config/sops/age/keys.txt`     | age key for the sops file                        |
| `GATE_OUT_DIR`        | `e2e/results/release-gate`        | parent of the run dirs (gitignored)              |
| `GATE_REQUIRED_SITES` | `wikipedia,bbc,github,amazon`     | sites that must load on every exit               |

`GNOSISVPN_FORCE_STATIC_ROUTING` defaults to `true`, as in the packaged
service's `gnosisvpn.env`.

## Networks

A network is a directory `configs/<network>/`:

- `network.env`: `GATE_BLOKLI_URL`, `GATE_CHAIN_NETWORK` (what Blokli reports as
  `chainInfo.network`; the client names its per-network data dir after it) and
  `GATE_SOPS_PASSWORD_PATH` (the identity password in
  `identities/secrets.sops.yaml`).
- `config.toml`: the client config. For piz-palu-staging it is a copy of
  gnosis_vpn `linux/resources/config-piz-palu-staging.toml`, which ships no
  destinations: the client discovers the exits on-chain. Refresh it from there.

Identities come from products-ci `identities/<network>.yaml`. Only
piz-palu-staging exists today; jura-staging (v4) is no longer gated.

## Reading the result

Each run writes to `e2e/results/release-gate/<UTC-timestamp>/`:

| File                                  | What it holds                                                                                 |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| `report.md`                           | verdict per exit with reasons, headline numbers, network, hoprd version, client commit; paste |
| `verdict.json`                        | the same verdict, machine-readable                                                            |
| `summary.csv`                         | one row per exit, every headline number; diff it against the previous release                 |
| `<exit>.json`                         | full browser record (navigations, crawl, speedtests, ping)                                    |
| `<exit>.download.csv`                 | one row per 100 MB pull: outcome, Mbps, TTFB, negotiated HTTP version                         |
| `<exit>.harness.log`, `.download.log` | raw output                                                                                    |
| `meta.json`                           | commits, versions, profile, machine: what makes two runs comparable                           |

Download outcomes: `ok`, `truncated` (window ran out, some bytes), `stalled` (no
bytes), `http:<code>`, `error:<curl-rc>`, `window-exhausted`.

The daemon log is at `/tmp/gnosis_vpn-e2e-daemon.log`.

## Troubleshooting

| Symptom                                            | Cause / fix                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `sops cannot decrypt …`                            | your age key is not a recipient yet, or `SOPS_AGE_KEY_FILE` points to the wrong file        |
| sops: `unknown identity type`                      | a `keys.txt` line is neither `AGE-SECRET-KEY-1…` nor a `#` comment (often the `age1…` line) |
| `GVPN_IDENTITY … is not in …`                      | typo, or your products-ci checkout is outdated                                              |
| `a gnosis_vpn-root is already running`             | the installed service or another run: `sudo systemctl stop gnosisvpn`                       |
| `hopr.id holds another identity`                   | a different identity (or one the client re-encrypted) sits in your data dir; move it away   |
| run_mode stays `preparing_safe`                    | the client did not find its Safe; check the identity's `safeAddress` and the Safe's funding |
| every exit `not connectable (state: not_routable)` | the node is still warming up or has no channels; raise `DEST_READY_TIMEOUT`                 |
| `no destinations configured on the client`         | discovery found nothing within `DEST_READY_TIMEOUT`; see the daemon log                     |
| machine has no internet after a crash              | `sudo pkill -x gnosis_vpn-root`; the routes go away with the daemon                         |

## Automation (later)

The gate is manual today. To run it unattended it needs:

- **A dedicated VM or network namespace.** The client takes the full tunnel and
  a kill switch, which cuts a shared CI runner off from its own controller.
- **A CI age key** added as a recipient of `identities/secrets.sops.yaml`.
- **A dedicated gate identity per network** in products-ci, used by nothing
  else.
- **Wiring after the hoprd rc deploy**, so the gate runs once the release
  candidate is live on the staging network and passes `GATE_HOPRD_VERSION`
  along.
