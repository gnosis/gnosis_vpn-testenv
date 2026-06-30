# Gnosis VPN test environment

Local development and system-test stack for Gnosis VPN. Orchestrates a HOPR
localcluster, one or more containerised Gnosis VPN server instances, and a
native Gnosis VPN client against them.

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [just](https://just.systems/) (system-level; must be available outside any Nix
  shell to avoid nesting issues)
- Docker (or Podman / Apple `container`)
- Sibling repos checked out at the paths below (overridable)
- A local OS user that `gnosis_vpn-worker` runs as — `gnosis_vpn-root` drops
  privileges to this user when spawning the worker. Defaults to `gnosisvpntestenv`;
  override via `CLIENT_WORKER_USER`.

## Sibling repo paths

By default the recipes expect these repos next to each other:

```
parent/
  gnosis_vpn-testenv/   ← this repo
  hoprd/
  gnosis_vpn-server/
  gnosis_vpn-client/
```

Override any path via environment variable — useful in CI where repos are
checked out independently:

```sh
HOPRD_DIR=/ci/hoprd \
GVPN_SERVER_DIR=/ci/gnosis_vpn-server \
GVPN_CLIENT_DIR=/ci/gnosis_vpn-client \
  just up
```

## Development setup

```sh
# 1. Build all components, start the full stack, and get the ready-to-run client command
just development-setup

# 2. Copy-paste and run the printed sudo command in a second terminal
#    (WireGuard requires root)

# 3. Tear everything down (stops client, servers, cluster, and metrics)
just down
```

`just development-setup` builds all components, starts the localcluster, VPN
server(s), and metrics stack, generates client config, sets the correct
ownership on the worker binary, and prints the exact `sudo` command to start
the client — copy-paste it to run.

`just up` does the same minus the build and the worker chown/client command
hint; useful for scripting and CI when components are pre-built.

## Running system tests

```sh
just up             # build + cluster + servers + metrics + gen-config
just system-tests   # delegates to gnosis_vpn-client's system-tests with generated artifacts
just down
```

## Configuration variables

| Variable             | Default                                            | Purpose                              |
| -------------------- | -------------------------------------------------- | ------------------------------------ |
| `HOPRD_DIR`          | `../hoprd`                                         | Path to hoprd repo                   |
| `GVPN_SERVER_DIR`    | `../gnosis_vpn-server`                             | Path to gnosis_vpn-server repo       |
| `GVPN_CLIENT_DIR`    | `../gnosis_vpn-client`                             | Path to gnosis_vpn-client repo       |
| `CLUSTER_SIZE`       | `3`                                                | Number of HOPR nodes in localcluster |
| `SERVER_COUNT`       | `1`                                                | Number of VPN server containers      |
| `HOPS`               | `1`                                                | Session hop count for destinations   |
| `CLIENT_WORKER_USER` | `gnosisvpntestenv`                                 | OS user the worker process runs as   |
| `CLIENT_STATE_HOME`  | _(derived)_                                        | Worker state directory (see below)   |
| `CLIENT_LOG_LEVEL`   | `warn,gnosis_vpn_root=debug,gnosis_vpn_lib=debug,gnosis_vpn_worker=debug` | RUST_LOG for the client |
| `CLIENT_LOG_FILE`    | `/tmp/gnosis_vpn-client.log`                       | Client log output path               |
| `SERVER_LOG_LEVEL`   | `info`                                             | RUST_LOG for VPN server containers   |
| `CLUSTER_LOG_LEVEL`  | `info`                                             | RUST_LOG for the localcluster        |
| `DATA_DIR`           | `/tmp/hopr-nodes`                                  | Localcluster data directory          |
| `METRICS_DATA_DIR`   | `/tmp/hopr-metrics-data`                           | VictoriaMetrics on-disk storage      |
| `CONFIG_DIR`         | `/tmp/gnosis_vpn-testenv`                          | Generated config output directory    |
| `CHAIN_IMAGE`        | `…/bloklid-anvil:latest`                           | Blokli + Anvil container image       |

## Worker state directory

The worker stores persistent state (identity keys, cache) under a *state-home*
directory. The `_state-home` recipe resolves its path in two steps:

1. If `CLIENT_STATE_HOME` is set, that value is used as-is.
2. Otherwise the home directory of `CLIENT_WORKER_USER` is looked up via
   `getent passwd`. If the user does not exist the recipe fails with an
   actionable error message.

Set `CLIENT_STATE_HOME` explicitly whenever `CLIENT_WORKER_USER` is not a real
OS user (e.g. in CI, or when running rootless with a different layout):

```sh
CLIENT_STATE_HOME=/var/lib/gnosis_vpn just client-start
```

### Purging state

```sh
just purge-state
```

Deletes the entire state-home directory (requires `sudo`). The recipe resolves
the path the same way as `_state-home` and asks for a `yes` confirmation before
deleting. Use this to start with a clean identity after a failed run or when
rotating keys.

## Metrics stack

`just up` (and `just development-setup`) also starts a local metrics pipeline:

- **otelcol** — receives OTLP/HTTP on `127.0.0.1:4318` and forwards to VictoriaMetrics
- **VictoriaMetrics** — stores metrics and exposes a PromQL UI at `http://localhost:8428`

The client and server emit OpenTelemetry metrics to `127.0.0.1:4318` automatically when
the stack is up. Data is persisted under `METRICS_DATA_DIR` between runs; `just down`
stops both services but does not delete the data.

```sh
# Start/stop independently if needed
just metrics-start
just metrics-stop
```

## Port assignments

| Service                | Protocol | Host port   |
| ---------------------- | -------- | ----------- |
| HOPR node i            | TCP      | `3000 + i`  |
| HOPR P2P node i        | UDP      | `9000 + i`  |
| Blokli chain           | TCP      | `8080`      |
| VPN server i API       | TCP      | `8000 + i`  |
| VPN server i WireGuard | UDP      | `51821 + i` |
| otelcol OTLP/HTTP      | TCP      | `4318`      |
| VictoriaMetrics PromQL | TCP      | `8428`      |

## Utility recipes

| Recipe       | What it does                                                         |
| ------------ | -------------------------------------------------------------------- |
| `clean`      | Removes all generated configs, data dirs, log files, and Nix results |
| `reset`      | `down` followed by `clean` — full wipe                              |
| `logs`       | `tail -f` all cluster node logs and the client log                  |
| `node-logs`  | `tail -f` only the hoprd node logs                                  |

## Notes

- The localcluster provisions one extra pre-funded HOPR identity
  (`--extra-identities 1`) that the gnosis_vpn-client uses to spin up its
  internal entry node — no manual funding required for local dev.
- The client config (`CONFIG_DIR/client.toml`) targets server-0 for both
  `[connection.bridge]` and `[connection.wg]`. Per-destination server selection
  is a planned client feature.
- `just gen-config` is idempotent against a running cluster and can be re-run to
  refresh configs without restarting anything.
- The Nix store is read-only, so `development-setup` copies the worker binary to
  `/tmp/gnosis_vpn-worker` and `chown`s it to `CLIENT_WORKER_USER` before
  printing the run command.
