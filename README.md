# Gnosis VPN test environment

Local development and system-test stack for Gnosis VPN. Orchestrates a HOPR
localcluster, one or more containerised Gnosis VPN server (exit node)
instances, and a containerised Gnosis VPN client against them.

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [just](https://just.systems/) (system-level; must be available outside any Nix
  shell to avoid nesting issues)
- Docker (or Podman / Apple `container`)
- Sibling repos checked out at the paths below (overridable)

## Why the client runs in its own container

The client and the exit-node servers used to run on the same host network. The
client's full-tunnel WireGuard route (`0.0.0.0/1` + `128.0.0.0/1` via `wg0`) is
installed into the *main routing table*, so once it was up, it captured every
outbound packet on that host — including the exit-node container's own
Docker-NATed egress to the real internet. That packet would get pulled back
into the tunnel instead of leaving, producing a routing loop rather than
internet access.

Running the client in its own container fixes this architecturally: its
full-tunnel route now lives only in the client container's own network
namespace, so it can no longer capture the exit-node container's (or the
host's) traffic. The localcluster still runs natively on the host; the client
container reaches it over a dedicated Docker network (see below).

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
# 1. Build all components and start the full stack, including the client container
just development-setup

# 2. Tail the client container's logs
docker logs -f gnosis_vpn-client

# 3. Tear everything down (stops client, servers, cluster, and metrics)
just down
```

`just development-setup` builds all components, then brings the whole stack up
(localcluster, VPN server(s), metrics, generated config, and the client
container); the client container gets its WireGuard/routing privileges from
`--cap-add=NET_ADMIN` instead of host root, so no `sudo` is needed for that.
`sudo` may still prompt once, best-effort, on hosts running the NixOS firewall
— see [Firewall (NixOS hosts)](#firewall-nixos-hosts) below.

`just up` (and thus `development-setup`) finishes by printing a summary: the
`gnosis_vpn-ctl` commands to control the client, each component's checked-out
commit (and tag, if any) for `gnosis_vpn-client`/`gnosis_vpn-server`/`hoprd`,
and whether the firewall punch-through above is enabled. Re-print it anytime
with `just summary`.

`just up` does the same without the build step; useful for scripting and CI
when components are pre-built.

## Issuing client commands

Once the stack is up, control the running client via `gnosis_vpn-ctl` inside
its container — the client image symlinks the binary onto `PATH` for exactly
this purpose:

```sh
docker exec -it gnosis_vpn-client gnosis_vpn-ctl status
docker exec -it gnosis_vpn-client gnosis_vpn-ctl connect <destination-id>
docker exec -it gnosis_vpn-client gnosis_vpn-ctl --help
```

`gnosis_vpn-ctl` talks to the client's `gnosis_vpn-root` process over
`/var/run/gnosisvpn.sock` inside the container, so no `--socket-path` flag is
needed when run this way.

## Running system tests

```sh
just up             # build + cluster + servers + metrics + gen-config
just system-tests   # delegates to gnosis_vpn-client's system-tests with generated artifacts
just down
```

## Configuration variables

| Variable                 | Default                                                                   | Purpose                                        |
| ------------------------ | -------------------------------------------------------------------------- | ---------------------------------------------- |
| `HOPRD_DIR`              | `../hoprd`                                                                | Path to hoprd repo                             |
| `GVPN_SERVER_DIR`        | `../gnosis_vpn-server`                                                    | Path to gnosis_vpn-server repo                 |
| `GVPN_CLIENT_DIR`        | `../gnosis_vpn-client`                                                    | Path to gnosis_vpn-client repo                 |
| `CLUSTER_SIZE`           | `3`                                                                       | Number of HOPR nodes in localcluster           |
| `SERVER_COUNT`           | `1`                                                                       | Number of VPN server containers                |
| `HOPS`                   | `1`                                                                       | Session hop count for destinations             |
| `DOCKER_NETWORK`         | `gnosis-vpn-testenv`                                                      | Docker network joining client to localcluster  |
| `DOCKER_NETWORK_SUBNET`  | `172.30.0.0/24`                                                           | Subnet for `DOCKER_NETWORK`                    |
| `DOCKER_NETWORK_GATEWAY` | `172.30.0.1`                                                              | Gateway IP — also the cluster's P2P bind host  |
| `CLIENT_STATE_DIR`       | `/tmp/gnosis_vpn-testenv-state`                                           | Persistent worker state (identity keys, cache) |
| `CLIENT_LOG_LEVEL`       | `warn,gnosis_vpn_root=debug,gnosis_vpn_lib=debug,gnosis_vpn_worker=debug` | RUST_LOG for the client                        |
| `SERVER_LOG_LEVEL`       | `info`                                                                    | RUST_LOG for VPN server containers             |
| `CLUSTER_LOG_LEVEL`      | `info`                                                                    | RUST_LOG for the localcluster                  |
| `DATA_DIR`               | `/tmp/hopr-nodes`                                                         | Localcluster data directory                    |
| `METRICS_DATA_DIR`       | `/tmp/hopr-metrics-data`                                                  | VictoriaMetrics on-disk storage                |
| `CONFIG_DIR`             | `/tmp/gnosis_vpn-testenv`                                                 | Generated config output directory              |
| `CHAIN_IMAGE`            | `…/bloklid-anvil:latest`                                                  | Blokli + Anvil container image                 |

## Client state directory

The client container stores persistent state (identity keys, cache) under
`CLIENT_STATE_DIR`, bind-mounted into the container at `/var/lib/gnosisvpn`.
The container's entrypoint `chown`s it to the worker's internal user on
startup, so removing it later needs `sudo` (see below).

### Purging state

```sh
just purge-state
```

Deletes `CLIENT_STATE_DIR` after asking for a `yes` confirmation. Use this to
start with a clean identity after a failed run or when rotating keys.

## Metrics stack

`just up` (and `just development-setup`) also starts a local metrics pipeline:

- **otelcol** — receives OTLP/HTTP on `127.0.0.1:4318` and forwards to
  VictoriaMetrics
- **VictoriaMetrics** — stores metrics and exposes a PromQL UI at
  `http://localhost:8428`

The client and server emit OpenTelemetry metrics to `127.0.0.1:4318`
automatically when the stack is up. Data is persisted under `METRICS_DATA_DIR`
between runs; `just down` stops both services but does not delete the data.

```sh
# Start/stop independently if needed
just metrics-start
just metrics-stop
```

## Port assignments

The client container publishes no ports — it only needs egress (to the
localcluster via `DOCKER_NETWORK_GATEWAY`, and to the exit node's WireGuard
tunnel via the HOPR mixnet, both outbound).

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

| Recipe           | What it does                                                                |
| ---------------- | ---------------------------------------------------------------------------- |
| `clean`          | Removes all generated configs, data dirs, log files, and Nix results       |
| `reset`          | `down` followed by `clean` — full wipe                                     |
| `logs`           | `tail -f` cluster node logs and `docker logs -f` the client container      |
| `node-logs`      | `tail -f` only the hoprd node logs                                         |
| `summary`        | Print `gnosis_vpn-ctl` usage, component commits/tags, and firewall state (runs as part of `up`) |
| `network-create` | Creates `DOCKER_NETWORK` (idempotent; also runs as part of `cluster-start`) |
| `network-remove` | Removes `DOCKER_NETWORK` (runs as part of `clean`)                         |
| `firewall-allow-p2p` | Best-effort host-firewall punch-through for the cluster's P2P ports (see below); runs as part of `network-create` |
| `firewall-remove-p2p` | Reverts `firewall-allow-p2p`; runs as part of `network-remove` |

## Firewall (NixOS hosts)

The localcluster runs natively on the host and binds/announces its P2P
transport (QUIC over UDP) on `DOCKER_NETWORK_GATEWAY:9000+i` — the Docker
bridge's own gateway IP, not `127.0.0.1`. Traffic from the client container to
that IP therefore traverses the host's real network stack, unlike loopback
traffic, and is subject to the host's default-deny `INPUT` firewall chain.

On hosts running NixOS's `networking.firewall` (enabled by default), this
silently drops the client's connections to the cluster: `gnosis_vpn-ctl
status` (or the client logs) will show peers fetched (`num_announced=3`) but
never connected (`num_connected=0`), forever.

`network-create` now runs `firewall-allow-p2p`, which best-effort inserts an
`iptables` rule (via `sudo`, prompting once) accepting UDP
`9000..9000+CLUSTER_SIZE-1` from the testenv's Docker bridge interface into
the NixOS-managed `nixos-fw` chain. It's a no-op on hosts without that chain
(macOS, other Linux distros, firewall disabled). `network-remove` reverts it
via `firewall-remove-p2p`.

This is a runtime rule, not persisted in your NixOS configuration — it's lost
on firewall reload/reboot and reapplied next time you run `just up`. To make
it permanent instead, add to your host's NixOS config:

```nix
networking.firewall.extraCommands = ''
  iptables -A nixos-fw -i br-+ -p udp --dport 9000:9010 -j nixos-fw-accept
'';
```

(adjust the port range to your `CLUSTER_SIZE`; `br-+` matches any Docker
bridge interface).

## Notes

- The localcluster provisions one extra pre-funded HOPR identity
  (`--extra-identities 1`) that the gnosis_vpn-client uses to spin up its
  internal entry node — no manual funding required for local dev.
- The client config (`CONFIG_DIR/client.toml`) targets server-0 for both
  `[connection.bridge]` and `[connection.wg]`. Per-destination server selection
  is a planned client feature.
- `just gen-config` is idempotent against a running cluster and can be re-run to
  refresh configs without restarting anything.
- The localcluster's P2P host/announce address is `DOCKER_NETWORK_GATEWAY`, not
  `127.0.0.1` — `hoprd-localcluster --p2p-host` uses the same value for both the
  bind address and the on-chain announced multiaddr, so it must be a real,
  reachable IP (not `0.0.0.0`/`auto`). Since that gateway IP is a real interface
  on the host, native processes (e.g. `system-tests`) reach it exactly as they
  reached `127.0.0.1` before; containers on `DOCKER_NETWORK` reach it too.
- Exit-node (`gnosis_vpn-server`) containers are unaffected by this change and
  don't join `DOCKER_NETWORK` — the cluster already reaches their published
  host ports directly, as before.
