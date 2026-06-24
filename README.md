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
  privileges to this user when spawning the worker. Defaults to `gnosisvpn`;
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

## Quick start

```sh
# 1. Build all components (once, or after source changes)
just build

# 2. Start localcluster + VPN server(s) + generate client config
just up

# 3. Start the client (needs root for WireGuard)
just client-start

# 4. Tear everything down
just down
```

`just up` does not include `client-start` — it requires `sudo` and is meant to
be a deliberate step.

## Running system tests

```sh
just build          # if not already built
just up             # cluster + servers + gen-config
just system-tests   # delegates to gnosis_vpn-client's system-tests with generated artifacts
just down
```

## Configuration variables

| Variable          | Default                   | Purpose                              |
| ----------------- | ------------------------- | ------------------------------------ |
| `HOPRD_DIR`       | `../hoprd`                | Path to hoprd repo                   |
| `GVPN_SERVER_DIR` | `../gnosis_vpn-server`    | Path to gnosis_vpn-server repo       |
| `GVPN_CLIENT_DIR` | `../gnosis_vpn-client`    | Path to gnosis_vpn-client repo       |
| `CLUSTER_SIZE`    | `3`                       | Number of HOPR nodes in localcluster |
| `SERVER_COUNT`    | `1`                       | Number of VPN server containers      |
| `HOPS`            | `1`                       | Session hop count for destinations   |
| `CLIENT_WORKER_USER` | `gnosisvpn`            | OS user the worker process runs as   |
| `DATA_DIR`        | `/tmp/hopr-nodes`         | Localcluster data directory          |
| `CONFIG_DIR`      | `/tmp/gnosis-vpn-testenv` | Generated config output directory    |
| `CHAIN_IMAGE`     | `…/bloklid-anvil:latest`  | Blokli + Anvil container image       |

## Port assignments

| Service                | Protocol | Host port   |
| ---------------------- | -------- | ----------- |
| HOPR node i            | TCP      | `3000 + i`  |
| HOPR P2P node i        | UDP      | `9000 + i`  |
| Blokli chain           | TCP      | `8080`      |
| VPN server i API       | TCP      | `8000 + i`  |
| VPN server i WireGuard | UDP      | `51821 + i` |

## Notes

- The localcluster provisions one extra pre-funded HOPR identity
  (`--extra-identities 1`) that the gnosis_vpn-client uses to spin up its
  internal entry node — no manual funding required for local dev.
- The client config (`CONFIG_DIR/client.toml`) targets server-0 for both
  `[connection.bridge]` and `[connection.wg]`. Per-destination server selection
  is a planned client feature.
- `just gen-config` is idempotent against a running cluster and can be re-run to
  refresh configs without restarting anything.
