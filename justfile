# Every `:=` variable below reaches scripts/testenv/* as an environment variable; recipe
# parameters travel as argv instead, since `set export` would join a `*ARGS` variadic into one word.
set export := true

# Paths to sibling repos — override via env in CI
HOPRD_DIR       := env_var_or_default("HOPRD_DIR",       "../hoprd")
GVPN_SERVER_DIR := env_var_or_default("GVPN_SERVER_DIR", "../gnosis_vpn-server")
GVPN_CLIENT_DIR := env_var_or_default("GVPN_CLIENT_DIR", "../gnosis_vpn-client")

# Localcluster settings
CLUSTER_SIZE := env_var_or_default("CLUSTER_SIZE", "3")
DATA_DIR     := env_var_or_default("DATA_DIR",     "/tmp/hopr-nodes")
CHAIN_IMAGE  := env_var_or_default("CHAIN_IMAGE",  "europe-west3-docker.pkg.dev/hoprassociation/docker-images/bloklid-anvil:latest")

# The PIX deposit pool both ends settle through when PIX is on: `test` (visible secp256k1
# transfers) or `curvy` (anonymous, through the Curvy deployment `curvy-stack-up` runs next to the
# cluster). It picks the hoprd binary and the client image together, because the curve each pool
# settles to is network-wide and never negotiated — see the note on build-cluster. Set by `up-curvy`.
# Empty rather than "test" so pix/run.sh still reaches its detect-the-pool-from-the-client-image path.
CLUSTER_PIX_POOL := env_var_or_default("CLUSTER_PIX_POOL", "")
HOPRD_PACKAGE    := if CLUSTER_PIX_POOL == "curvy" { "binary-hoprd-pix-curvy-x86_64-linux" } else { "binary-hoprd-pix-test-x86_64-linux" }
HOPRD_RESULT     := if CLUSTER_PIX_POOL == "curvy" { "result-hoprd-pix-curvy" } else { "result-hoprd" }
CLIENT_IMAGE     := if CLUSTER_PIX_POOL == "curvy" { "gnosis_vpn-client:pix-curvy" } else { "gnosis_vpn-client" }
CLIENT_BUILD     := if CLUSTER_PIX_POOL == "curvy" { "docker-build-pix-curvy" } else { "docker-build" }

# The Curvy stack is published on the Docker bridge's gateway, so the host-native nodes and the
# client container reach it at the same address. Its gateway (relayer, indexer) moves off 3000,
# which is node-0's API port; Blokli stays on 8080, where the cluster's own chain would be.
CURVY_GATEWAY_PORT := env_var_or_default("CURVY_GATEWAY_PORT", "3900")
CURVY_STACK_ENV    := CONFIG_DIR + "/curvy-stack.env"

# The two cluster binaries. Default to what `build-cluster` produces; override to run against
# binaries built some other way (e.g. `cargo build --release -p hoprd --features strategy-pix-test`
# plus `-p hoprd-localcluster` in a checkout of another commit). Override them together: the
# localcluster writes the node configs the hoprd binary then has to accept.
HOPRD_BIN        := env_var_or_default("HOPRD_BIN",        HOPRD_DIR + "/" + HOPRD_RESULT + "/bin/hoprd")
LOCALCLUSTER_BIN := env_var_or_default("LOCALCLUSTER_BIN", HOPRD_DIR + "/result-localcluster/bin/hoprd-localcluster")

# Docker network the client container joins to reach the (host-native) localcluster.
# Fixed subnet so the gateway IP — what the cluster binds/announces its P2P host as — is deterministic.
DOCKER_NETWORK         := env_var_or_default("DOCKER_NETWORK",         "gnosis-vpn-testenv")
DOCKER_NETWORK_SUBNET  := env_var_or_default("DOCKER_NETWORK_SUBNET",  "172.30.0.0/24")
DOCKER_NETWORK_GATEWAY := env_var_or_default("DOCKER_NETWORK_GATEWAY", "172.30.0.1")

# VPN server settings
SERVER_COUNT := env_var_or_default("SERVER_COUNT", "1")

# Override for the LAN IP auto-detection (multi-NIC hosts, or when the default route is wrong)
LAN_IP := env_var_or_default("LAN_IP", "")

# Data directory for VictoriaMetrics on-disk storage
METRICS_DATA_DIR := env_var_or_default("METRICS_DATA_DIR", "/tmp/hopr-metrics-data")

# Session hop count for destinations (0 = direct, 1+ = via relays)
HOPS := env_var_or_default("HOPS", "1")

# Non-empty starts the localcluster with `--enable-pix` and makes `gen-config` emit a PIX-enabled
# client config sized to match it. One switch for both ends, because they only work in agreement —
# see templates/pix-on.toml.tpl. Set by `up-pix`; `system-test-pix` needs it.
CLUSTER_ENABLE_PIX := env_var_or_default("CLUSTER_ENABLE_PIX", "")

# Log levels for each component (passed as RUST_LOG)
CLIENT_LOG_LEVEL  := env_var_or_default("CLIENT_LOG_LEVEL",  "warn,gnosis_vpn_root=debug,gnosis_vpn_lib=debug,gnosis_vpn_worker=debug")
SERVER_LOG_LEVEL  := env_var_or_default("SERVER_LOG_LEVEL",  "info")
CLUSTER_LOG_LEVEL := env_var_or_default("CLUSTER_LOG_LEVEL", "info")

# Persistent worker state (identity keys, cache) bind-mounted into the client container
CLIENT_STATE_DIR := env_var_or_default("CLIENT_STATE_DIR", "/tmp/gnosis_vpn-testenv-state")

# OS user gnosis_vpn-root drops privileges to when spawning gnosis_vpn-worker (host-native client only; must already exist)
CLIENT_WORKER_USER := env_var_or_default("CLIENT_WORKER_USER", "gnosisvpntestenv")

# Client log file path (host-native client only — the container relies on `docker logs` instead)
CLIENT_LOG_FILE := env_var_or_default("CLIENT_LOG_FILE", "/tmp/gnosis_vpn-client.log")

# End-to-end browser test suite (see e2e/README.md)
E2E_IMAGE   := env_var_or_default("E2E_IMAGE",   "gnosis_vpn-e2e")
E2E_OUT_DIR := env_var_or_default("E2E_OUT_DIR", "/tmp/gnosis_vpn-testenv-e2e")

# System-test run: worker user (created by the recipe if missing), its state home (wiped per run),
# and the runner's RUST_LOG
SYSTEM_TEST_WORKER_USER := env_var_or_default("SYSTEM_TEST_WORKER_USER", "gnosisvpn")
SYSTEM_TEST_STATE_DIR   := env_var_or_default("SYSTEM_TEST_STATE_DIR",   "/tmp/gnosis_vpn-testenv-system-tests")
SYSTEM_TEST_LOG_LEVEL   := env_var_or_default("SYSTEM_TEST_LOG_LEVEL",   "info,gnosis_vpn_root=debug,gnosis_vpn_lib=debug,gnosis_vpn_worker=debug")

# Generated config output dir
CONFIG_DIR    := env_var_or_default("CONFIG_DIR", "/tmp/gnosis_vpn-testenv")
TEMPLATES_DIR := justfile_directory() + "/templates"
REPO_DIR      := justfile_directory()

# Files a remote client needs, bundled together for up-on-network (see gen-config-on-network)
NETWORK_BUNDLE_DIR := CONFIG_DIR + "/on-network"

# List available recipes
default:
    @just --list

# ─── Build ───────────────────────────────────────────────────────────────────

# The node binary is the `pix-test` variant, not the default `binary-hoprd`. gnosis_vpn-client
# builds edgli with `pix-test`, i.e. `hopr-lib/pix-secp256k1`, and turns PIX on for the main
# tunnel session by default — while `binary-hoprd` takes hopr-lib's default, `pix-bjj`. The curve
# is a network-wide invariant that nothing negotiates, so a bjj Exit refuses every session this
# client opens with `UnacceptablePixParams` ("refusing a client offering a PIX curve suite this
# node was not built for" in the node log) and no destination ever connects. `hoprd-localcluster`
# is already built against hoprd's `strategy-pix-test`, so only the node binary was mismatched.
# Build hoprd and hoprd-localcluster binaries via nix
# With CLUSTER_PIX_POOL=curvy the node is the `pix-curvy` variant instead, and the client is built
# with edgli's `pix-curvy` to match.
build-cluster:
    nix build -L --out-link {{HOPRD_DIR}}/{{HOPRD_RESULT}} {{HOPRD_DIR}}#{{HOPRD_PACKAGE}}
    nix build -L --out-link {{HOPRD_DIR}}/result-localcluster {{HOPRD_DIR}}#binary-hoprd-localcluster

# Build gnosis_vpn-server Docker image
build-server:
    cd {{GVPN_SERVER_DIR}} && just docker-build

# Build gnosis_vpn-client Docker image (the `pix-curvy` variant under CLUSTER_PIX_POOL=curvy)
build-client:
    cd {{GVPN_CLIENT_DIR}} && just {{CLIENT_BUILD}}

# Build gnosis_vpn-client binaries only (no Docker image) — for the host-native client
build-client-native:
    cd {{GVPN_CLIENT_DIR}} && just build

# Build all components
build: build-cluster build-server build-client

# ─── Networking ──────────────────────────────────────────────────────────────

# Create the fixed-subnet Docker network joining the client container to the host-native localcluster
network-create:
    @scripts/testenv/network.sh create

# Remove the Docker network
network-remove:
    docker network rm "{{DOCKER_NETWORK}}" 2>/dev/null || true

# ─── Curvy stack ─────────────────────────────────────────────────────────────

# Bring up the Curvy deployment a `curvy` pool settles through: chain + Blokli, relayer, indexer,
# batch prover and gateway, from the release pinned in hoprd's localcluster/curvy. hoprd's launcher
# does the work (`--stack-only`); what it hands back is the environment the nodes and the client need.
curvy-stack-up: network-create
    @scripts/testenv/curvy.sh up

# Tear the Curvy stack down (no-op when it is not up)
curvy-stack-down:
    @scripts/testenv/curvy.sh down

# ─── Localcluster ────────────────────────────────────────────────────────────

# Start localcluster (--extra-identities 1 pre-funds the client identity; P2P binds to the Docker gateway IP)
cluster-start: network-create
    @scripts/testenv/cluster.sh start {{DOCKER_NETWORK_GATEWAY}}

# Start localcluster for a host-native client (see up-client-on-host); P2P binds to loopback instead of the Docker gateway
cluster-start-on-host:
    @scripts/testenv/cluster.sh start 127.0.0.1

# Start localcluster reachable from other machines on the LAN (see up-on-network); P2P binds/announces LAN_IP
cluster-start-on-network:
    @scripts/testenv/cluster.sh start-on-network

# Poll until cluster reaches state=running
cluster-wait:
    @scripts/testenv/cluster.sh wait

# Print live cluster status as JSON
cluster-status:
    @scripts/testenv/cluster.sh status

# Stop localcluster
cluster-stop:
    @scripts/testenv/cluster.sh stop

# ─── VPN Servers ─────────────────────────────────────────────────────────────

# Start SERVER_COUNT gnosis_vpn-server containers (server-i: WireGuard 51821+i/udp, API 8000+i)
server-start:
    @scripts/testenv/server.sh start

# Stop all VPN server containers
server-stop:
    @scripts/testenv/server.sh stop

# ─── Config generation ───────────────────────────────────────────────────────

# Derive client config and system-test artifacts from live cluster status
gen-config:
    @scripts/testenv/config.sh gen

# Derive a LAN-reachable client config + blokli URL for a client running on another machine (see up-on-network)
gen-config-on-network: gen-config
    @scripts/testenv/config.sh gen-on-network

# ─── Client ──────────────────────────────────────────────────────────────────

# Start the gnosis_vpn-client container (CAP_NET_ADMIN, no sudo needed — see README)
client-start: network-create
    @scripts/testenv/client.sh start

# Stop the client, wherever it's running (container or host-native — used by down)
client-stop:
    @scripts/testenv/client.sh stop

# Reintroduces the routing-loop risk the container was built to avoid (see README "Why the
# client runs in its own container") if gnosis_vpn-server shares the host's egress — don't run
# this alongside `client-start`, they'd collide over CLIENT_STATE_DIR and the default control socket.
# Start gnosis_vpn-client as a native host process instead of in Docker (dev/debug convenience)
client-start-on-host:
    @scripts/testenv/client.sh start-on-host

# Stop the host-native client (cascades SIGTERM to the worker via gnosis_vpn-root)
client-stop-on-host:
    @scripts/testenv/client.sh stop-on-host

# Tail the host-native client's log file
client-logs-on-host:
    tail -f "{{CLIENT_LOG_FILE}}"

# Remove all persistent worker state (identity keys, cache) from CLIENT_STATE_DIR
purge-state:
    @scripts/testenv/client.sh purge-state-interactive

# ─── System tests ────────────────────────────────────────────────────────────

# Runs the client's system-test binary directly instead of delegating to gnosis_vpn-client's own
# `system-tests` recipe: that recipe targets a *deployed* network, picking config and Blokli URL
# from a checked-in `gnosis_vpn-system_tests/networks/<name>/` fixture selected by
# SYSTEM_TEST_NETWORK. A localcluster has neither — its destinations, identity and Blokli URL are
# generated fresh by `gen-config` on every run — so the artifacts and the worker-user setup are
# staged here. Everything the runner itself needs is the same; only where it comes from differs.
# Full tunnel: while it runs, this machine's traffic egresses through the exit under test.
# Run gnosis_vpn-client system tests against the live local stack
system-tests *ARGS:
    @scripts/testenv/system-tests.sh {{ARGS}}

# Drive a full PIX deposit → key recovery → sweep cycle and assert the exit's income (see pix/run.sh)
system-test-pix *ARGS:
    @CLIENT_CONTAINER=gnosis_vpn-client pix/run.sh {{ARGS}}

# ─── End-to-end tests ────────────────────────────────────────────────────────

# Build the e2e sidecar image (node + obscura + browser harness)
build-e2e:
    docker build --tag "{{E2E_IMAGE}}" e2e

# Drive a headless browser through the tunnel for every destination (see e2e/README.md)
e2e *ARGS: build-e2e
    @e2e/run.sh {{ARGS}}

# Mirrors how `system-tests` owns its daemon instead of attaching to a pre-running one.
# Needs sudo (WireGuard + routing table) and a pre-existing worker user — macOS has no
# useradd, so unlike the Linux-only system-tests recipe this does not create one.
# Full tunnel: while it runs, this machine's traffic egresses through the exit under test.
# Run the e2e browser suite against a real network (rotsee etc), starting our own client
e2e-on-network *ARGS:
    @scripts/testenv/e2e-on-network.sh {{ARGS}}

# ─── Scripts ─────────────────────────────────────────────────────────────────

# validate connectivity on an already-connected tunnel (see scripts/README.md)
smoke-test *args:
    ./scripts/vpn-smoke-test.sh {{ args }}

# cycle every destination until account funding drains, recording results (see scripts/README.md)
drain-tour *args:
    ./scripts/vpn-drain-tour.sh {{ args }}

# render a vpn-drain-tour run directory into a self-contained report.html
drain-report *args:
    ./scripts/vpn-drain-report.sh {{ args }}

# sample a WireGuard interface's byte counters, logging per-window totals to CSV
wg-traffic *args:
    ./scripts/wg-traffic.sh {{ args }}

# run the offline bats suite for scripts/ (no network, uses fakes)
test-scripts:
    bats --print-output-on-failure scripts/tests

# ─── Metrics ─────────────────────────────────────────────────────────────────

# Start otelcol (OTLP HTTP on 127.0.0.1:4318) and VictoriaMetrics (PromQL UI on :8428)
metrics-start:
    @scripts/testenv/metrics.sh start

# Stop otelcol and VictoriaMetrics
metrics-stop:
    @scripts/testenv/metrics.sh stop

# ─── Composite ───────────────────────────────────────────────────────────────

# Bring the full stack up, including the client container
up: build metrics-start cluster-start cluster-wait server-start gen-config client-start
    @just summary

# Re-invoked rather than composed, because CLUSTER_ENABLE_PIX has to be set before `up`'s
# dependencies are evaluated — it steers both the cluster flag and which PIX block gen-config emits.
# Bring the full stack up with PIX enabled end to end (see pix/run.sh)
up-pix:
    CLUSTER_ENABLE_PIX=1 just up

# `env -u`: `set export` would hand the nested just this recipe's own HOPRD_BIN, keeping the
# pix-test binary instead of recomputing the curvy one from CLUSTER_PIX_POOL.
# `up-pix` against the Curvy pool: the Curvy stack comes up first, and the cluster runs on its chain.
# Bring the full stack up with PIX settling through Curvy (see pix/run.sh)
up-curvy:
    env -u HOPRD_BIN CLUSTER_ENABLE_PIX=1 CLUSTER_PIX_POOL=curvy just build metrics-start curvy-stack-up cluster-start cluster-wait server-start gen-config client-start
    @CLUSTER_ENABLE_PIX=1 CLUSTER_PIX_POOL=curvy just summary

# See the caveat on client-start-on-host before using this instead of `up`
# Bring the full stack up with the client running natively on the host instead of in Docker
up-client-on-host: build-cluster build-server build-client-native metrics-start cluster-start-on-host cluster-wait server-start gen-config client-start-on-host
    @just summary-host-client

# Bring up a cluster + exit server reachable from another machine on the LAN, and generate its client config
up-on-network: build-cluster build-server metrics-start cluster-start-on-network cluster-wait server-start gen-config-on-network
    @just summary-on-network

# Print how to control the running client and component versions
summary:
    @scripts/testenv/summary.sh default

# Print how to control the host-native client and component versions
summary-host-client:
    @scripts/testenv/summary.sh host-client

# Print what to copy/run on the other machine, the required firewall ports, and component versions
summary-on-network:
    @scripts/testenv/summary.sh on-network

# Tear the full stack down and purge client state (cluster always restarts with new identities)
down: client-stop server-stop cluster-stop curvy-stack-down metrics-stop
    @scripts/testenv/client.sh purge-state

# Remove all generated configs, data, logs, chain container, and nix build results
clean:
    rm -rf "{{CONFIG_DIR}}" "{{DATA_DIR}}" "{{METRICS_DATA_DIR}}"
    sudo rm -rf "{{CLIENT_STATE_DIR}}"
    sudo rm -f /tmp/hopr-otelcol.log /tmp/hopr-victoriametrics.log
    docker rm -f hopr-chain 2>/dev/null || true
    just network-remove
    rm -f "{{HOPRD_DIR}}/result-hoprd" "{{HOPRD_DIR}}/result-localcluster" "{{GVPN_CLIENT_DIR}}/result"
    echo "Clean done"

# Tear the full stack down and wipe all state
reset: down clean

# Full development setup: build, bring the whole stack up including the client container
development-setup: up

# Tail all cluster node logs and the client container's logs
logs:
    @scripts/testenv/logs.sh

# Tail only cluster node logs
node-logs:
    tail -f "{{DATA_DIR}}/logs/"hoprd_*.log
