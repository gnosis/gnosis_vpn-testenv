# Paths to sibling repos — override via env in CI
HOPRD_DIR       := env_var_or_default("HOPRD_DIR",       "../hoprd")
GVPN_SERVER_DIR := env_var_or_default("GVPN_SERVER_DIR", "../gnosis_vpn-server")
GVPN_CLIENT_DIR := env_var_or_default("GVPN_CLIENT_DIR", "../gnosis_vpn-client")

# Localcluster settings
CLUSTER_SIZE := env_var_or_default("CLUSTER_SIZE", "3")
DATA_DIR     := env_var_or_default("DATA_DIR",     "/tmp/hopr-nodes")
CHAIN_IMAGE  := env_var_or_default("CHAIN_IMAGE",  "europe-west3-docker.pkg.dev/hoprassociation/docker-images/bloklid-anvil:latest")

# Docker network the client container joins to reach the (host-native) localcluster.
# Fixed subnet so the gateway IP — what the cluster binds/announces its P2P host as — is deterministic.
DOCKER_NETWORK         := env_var_or_default("DOCKER_NETWORK",         "gnosis-vpn-testenv")
DOCKER_NETWORK_SUBNET  := env_var_or_default("DOCKER_NETWORK_SUBNET",  "172.30.0.0/24")
DOCKER_NETWORK_GATEWAY := env_var_or_default("DOCKER_NETWORK_GATEWAY", "172.30.0.1")

# VPN server settings
SERVER_COUNT := env_var_or_default("SERVER_COUNT", "1")

# Override for _lan-ip's auto-detection (multi-NIC hosts, or when the default route is wrong)
LAN_IP := env_var_or_default("LAN_IP", "")

# Data directory for VictoriaMetrics on-disk storage
METRICS_DATA_DIR := env_var_or_default("METRICS_DATA_DIR", "/tmp/hopr-metrics-data")

# Session hop count for destinations (0 = direct, 1+ = via relays)
HOPS := env_var_or_default("HOPS", "1")

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

# Generated config output dir
CONFIG_DIR    := env_var_or_default("CONFIG_DIR", "/tmp/gnosis_vpn-testenv")
TEMPLATES_DIR := justfile_directory() + "/templates"

# Files a remote client needs, bundled together for up-on-network (see gen-config-on-network)
NETWORK_BUNDLE_DIR := CONFIG_DIR + "/on-network"

# List available recipes
default:
    @just --list

# ─── Build ───────────────────────────────────────────────────────────────────

# Build hoprd and hoprd-localcluster binaries via nix
build-cluster:
    nix build -L --out-link {{HOPRD_DIR}}/result-hoprd        {{HOPRD_DIR}}#binary-hoprd
    nix build -L --out-link {{HOPRD_DIR}}/result-localcluster {{HOPRD_DIR}}#binary-hoprd-localcluster

# Build gnosis_vpn-server Docker image
build-server:
    cd {{GVPN_SERVER_DIR}} && just docker-build

# Build gnosis_vpn-client Docker image
build-client:
    cd {{GVPN_CLIENT_DIR}} && just docker-build

# Build gnosis_vpn-client binaries only (no Docker image) — for the host-native client
build-client-native:
    cd {{GVPN_CLIENT_DIR}} && just build

# Build all components
build: build-cluster build-server build-client

# ─── Networking ──────────────────────────────────────────────────────────────

# Create the fixed-subnet Docker network joining the client container to the host-native localcluster
network-create:
    #!/usr/bin/env bash
    set -euo pipefail
    if docker network inspect "{{DOCKER_NETWORK}}" > /dev/null 2>&1; then
        echo "Docker network {{DOCKER_NETWORK}} already exists — skipping create"
    else
        docker network create --subnet "{{DOCKER_NETWORK_SUBNET}}" --gateway "{{DOCKER_NETWORK_GATEWAY}}" "{{DOCKER_NETWORK}}"
        echo "Created Docker network {{DOCKER_NETWORK}} (subnet {{DOCKER_NETWORK_SUBNET}}, gateway {{DOCKER_NETWORK_GATEWAY}})"
    fi

# Remove the Docker network
network-remove:
    docker network rm "{{DOCKER_NETWORK}}" 2>/dev/null || true

# ─── Localcluster ────────────────────────────────────────────────────────────

# Shared start/restart logic for the three cluster-start* variants below: binary checks, skip-if-already-running-on-this-host, restart-if-running-on-a-different-host, spawn.
_cluster-start p2p_host:
    #!/usr/bin/env bash
    set -euo pipefail
    lc_bin="{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster"
    hoprd_bin="{{HOPRD_DIR}}/result-hoprd/bin/hoprd"
    if [ ! -f "${lc_bin}" ]; then
        echo "Error: hoprd-localcluster not found at ${lc_bin}" >&2
        echo "Run 'just build-cluster' to build it first" >&2
        exit 1
    fi
    if [ ! -f "${hoprd_bin}" ]; then
        echo "Error: hoprd not found at ${hoprd_bin}" >&2
        echo "Run 'just build-cluster' to build it first" >&2
        exit 1
    fi
    p2p_host="{{p2p_host}}"
    cluster_state=$("${lc_bin}" status --data-dir "{{DATA_DIR}}" 2>/dev/null | jq -r '.state // "not_running"')
    if [ "${cluster_state}" = "failed" ]; then
        echo "Cluster is in state 'failed' — run 'just cluster-stop' to clean up before restarting"
        exit 1
    fi
    if [ "${cluster_state}" != "not_running" ]; then
        current_host=$(just _cluster-p2p-host)
        if [ "${current_host}" = "${p2p_host}" ]; then
            pid=$(pgrep -f hoprd-localcluster | head -1)
            echo "Cluster found in state '${cluster_state}' (PID ${pid}), already on P2P host ${p2p_host} — skipping start"
            exit 0
        fi
        echo "Cluster is running with P2P host '${current_host}', but this recipe needs '${p2p_host}' — restarting with the correct host"
        just cluster-stop
    fi
    RUST_LOG={{CLUSTER_LOG_LEVEL}} \
        "{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster" \
        --hoprd-bin   "{{HOPRD_DIR}}/result-hoprd/bin/hoprd" \
        --chain-image "{{CHAIN_IMAGE}}" \
        --size        {{CLUSTER_SIZE}} \
        --p2p-host    "${p2p_host}" \
        --data-dir    "{{DATA_DIR}}" \
        --extra-identities 1 &
    echo "Localcluster PID: $! (P2P on ${p2p_host})"

# Start localcluster (--extra-identities 1 pre-funds the client identity; P2P binds to the Docker gateway IP)
cluster-start: network-create
    just _cluster-start {{DOCKER_NETWORK_GATEWAY}}

# Start localcluster for a host-native client (see up-client-on-host); P2P binds to loopback instead of the Docker gateway
cluster-start-on-host:
    just _cluster-start 127.0.0.1

# Start localcluster reachable from other machines on the LAN (see up-on-network); P2P binds/announces LAN_IP
cluster-start-on-network:
    just _cluster-start "$(just _lan-ip)"

# Poll until cluster reaches state=running
cluster-wait:
    #!/usr/bin/env bash
    set -euo pipefail
    lc_bin="{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster"
    if [ ! -f "${lc_bin}" ]; then
        echo "Error: hoprd-localcluster not found at ${lc_bin}" >&2
        echo "Run 'just build-cluster' to build it first" >&2
        exit 1
    fi
    echo "Waiting for cluster..."
    until [ "$("${lc_bin}" status --data-dir "{{DATA_DIR}}" 2>/dev/null | jq -r '.state // empty')" = "running" ]; do
        sleep 1
    done
    echo "Cluster running"

# Print live cluster status as JSON
cluster-status:
    #!/usr/bin/env bash
    set -euo pipefail
    lc_bin="{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster"
    if [ ! -f "${lc_bin}" ]; then
        echo "Error: hoprd-localcluster not found at ${lc_bin}" >&2
        echo "Run 'just build-cluster' to build it first" >&2
        exit 1
    fi
    "${lc_bin}" status --data-dir "{{DATA_DIR}}"

# Stop localcluster
cluster-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -f hoprd-localcluster 2>/dev/null || true
    pkill -f "result-hoprd/bin/hoprd" 2>/dev/null || true
    docker rm -f hopr-chain 2>/dev/null || true
    # cluster recreates state everytime, so we can safely delete it on stop
    rm -rf "{{DATA_DIR}}"
    echo "Cluster stopped"

# ─── VPN Servers ─────────────────────────────────────────────────────────────

# Start SERVER_COUNT gnosis_vpn-server containers (server-i: WireGuard 51821+i/udp, API 8000+i)
server-start:
    #!/usr/bin/env bash
    set -euo pipefail
    for i in $(seq 0 $(({{SERVER_COUNT}} - 1))); do
        name="gnosis_vpn-server-${i}"
        wg_port=$((51821 + i))
        api_port=$((8000 + i))
        if docker container inspect "${name}" > /dev/null 2>&1; then
            echo "${name} already exists — skipping start"
            echo "  WireGuard: ${wg_port}/udp, API: ${api_port}"
            continue
        fi
        private_key=$(wg genkey)
        docker run --rm --detach \
            --env  "PRIVATE_KEY=${private_key}" \
            --env  "RUST_LOG={{SERVER_LOG_LEVEL}}" \
            --publish "${api_port}:8000" \
            --publish "${wg_port}:51820/udp" \
            --cap-add=NET_ADMIN \
            --add-host=host.docker.internal:host-gateway \
            --sysctl net.ipv4.conf.all.src_valid_mark=1 \
            --sysctl net.ipv4.ip_forward=1 \
            --name "${name}" \
            gnosis_vpn-server
        sleep 1
        running=$(docker inspect "${name}" 2>/dev/null | jq -r '.[0].State.Running // "false"')
        if [ "${running}" != "true" ]; then
            echo "Error: ${name} failed to start" >&2
            { docker logs "${name}" 2>&1 || true; } >&2
            exit 1
        fi
        echo "Started ${name} — WireGuard: ${wg_port}/udp, API: ${api_port}"
    done

# Stop all VPN server containers
server-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    for i in $(seq 0 $(({{SERVER_COUNT}} - 1))); do
        docker stop "gnosis_vpn-server-${i}" 2>/dev/null \
            && echo "Stopped gnosis_vpn-server-${i}" \
            || echo "gnosis_vpn-server-${i} was not running"
    done

# ─── Config generation ───────────────────────────────────────────────────────

# Derive client config and system-test artifacts from live cluster status
gen-config:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{CONFIG_DIR}}"
    lc_bin="{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster"

    status=$("${lc_bin}" status --data-dir "{{DATA_DIR}}")
    blokli_url=$(echo "${status}" | jq -r '.blokli_url')

    # One [destinations.node-N] block per cluster exit node
    destinations=""
    while IFS= read -r node; do
        id=$(echo "${node}"      | jq -r '.id')
        address=$(echo "${node}" | jq -r '.address')
        block=$(DEST_ID="${id}" DEST_ADDRESS="${address}" DEST_HOPS="{{HOPS}}" \
            envsubst '$DEST_ID,$DEST_ADDRESS,$DEST_HOPS' \
            < "{{TEMPLATES_DIR}}/destination.toml.tpl")
        destinations+="${block}"$'\n'
    done < <(echo "${status}" | jq -c '.nodes[]')

    DESTINATIONS="${destinations}" \
        envsubst '$DESTINATIONS' \
        < "{{TEMPLATES_DIR}}/client.toml.tpl" \
        > "{{CONFIG_DIR}}/client.toml"

    echo "${blokli_url}" > "{{CONFIG_DIR}}/blokli_url"
    echo "Generated {{CONFIG_DIR}}/client.toml"

    # Persist the extra identity artifacts needed by client and system tests
    extra=$(echo "${status}" | jq -c '.extras[0] // empty')
    if [ -n "${extra}" ]; then
        keystore_path=$(echo "${extra}" | jq -r '.keystore_path')
        cp "${keystore_path}"                       "{{CONFIG_DIR}}/extra_id.id"
        echo "${extra}" | jq -r '.password'       > "{{CONFIG_DIR}}/extra_id.password"
        echo "${extra}" | jq -r '.safe_address'   > "{{CONFIG_DIR}}/extra_id.safe"
        echo "${extra}" | jq -r '.module_address' > "{{CONFIG_DIR}}/extra_id.module"
        echo "Saved extra identity artifacts to {{CONFIG_DIR}}"
    fi

# Derive a LAN-reachable client config + blokli URL for a client running on another machine (see up-on-network)
gen-config-on-network: gen-config
    #!/usr/bin/env bash
    set -euo pipefail
    lan_ip=$(just _lan-ip)
    sed "s/127\.0\.0\.1/${lan_ip}/g" "{{CONFIG_DIR}}/client.toml" > "{{CONFIG_DIR}}/client-on-network.toml"
    sed "s/localhost/${lan_ip}/"     "{{CONFIG_DIR}}/blokli_url"   > "{{CONFIG_DIR}}/blokli_url-on-network"
    mkdir -p "{{NETWORK_BUNDLE_DIR}}"
    cp "{{CONFIG_DIR}}/client-on-network.toml" "{{CONFIG_DIR}}/extra_id.id" "{{CONFIG_DIR}}/extra_id.password" "{{NETWORK_BUNDLE_DIR}}/"
    echo "Generated {{CONFIG_DIR}}/client-on-network.toml (exit server via ${lan_ip})"
    echo "Bundled remote-client files into {{NETWORK_BUNDLE_DIR}}"

# ─── Client ──────────────────────────────────────────────────────────────────

# Start the gnosis_vpn-client container (CAP_NET_ADMIN, no sudo needed — see README)
client-start: network-create
    #!/usr/bin/env bash
    set -euo pipefail
    if docker container inspect gnosis_vpn-client > /dev/null 2>&1; then
        echo "gnosis_vpn-client already exists — skipping start"
        exit 0
    fi
    mkdir -p "{{CLIENT_STATE_DIR}}"
    blokli_url=$(cat "{{CONFIG_DIR}}/blokli_url" | sed 's/localhost/host.docker.internal/')
    extra_id_pass=$(cat "{{CONFIG_DIR}}/extra_id.password")
    docker run --detach --rm \
        --name gnosis_vpn-client \
        --network "{{DOCKER_NETWORK}}" \
        --cap-add=NET_ADMIN \
        --add-host=host.docker.internal:host-gateway \
        --env RUST_LOG="{{CLIENT_LOG_LEVEL}}" \
        --env GNOSISVPN_CONFIG_PATH=/config/client.toml \
        --env GNOSISVPN_HOPR_BLOKLI_URL="${blokli_url}" \
        --env GNOSISVPN_HOPR_IDENTITY_FILE=/config/extra_id.id \
        --env GNOSISVPN_HOPR_IDENTITY_PASS="${extra_id_pass}" \
        --env GNOSISVPN_HOME=/var/lib/gnosisvpn \
        --env GNOSISVPN_CLIENT_AUTOSTART=30min \
        --volume "{{CONFIG_DIR}}:/config:ro" \
        --volume "{{CLIENT_STATE_DIR}}:/var/lib/gnosisvpn" \
        gnosis_vpn-client
    sleep 1
    running=$(docker inspect gnosis_vpn-client 2>/dev/null | jq -r '.[0].State.Running // "false"')
    if [ "${running}" != "true" ]; then
        echo "Error: gnosis_vpn-client failed to start" >&2
        { docker logs gnosis_vpn-client 2>&1 || true; } >&2
        exit 1
    fi
    echo "Started gnosis_vpn-client"

# Stop the client, wherever it's running (container or host-native — used by down)
client-stop:
    #!/usr/bin/env bash
    docker stop gnosis_vpn-client 2>/dev/null || true
    # only touch sudo if a host-native client is actually running, so the container-only
    # workflow (the common case) never hits a sudo prompt here
    if pgrep -f gnosis_vpn-root > /dev/null 2>&1 || pgrep -f gnosis_vpn-worker > /dev/null 2>&1; then
        sudo pkill -f gnosis_vpn-root   2>/dev/null || true
        sudo pkill -f gnosis_vpn-worker 2>/dev/null || true
    fi

# Reintroduces the routing-loop risk the container was built to avoid (see README "Why the
# client runs in its own container") if gnosis_vpn-server shares the host's egress — don't run
# this alongside `client-start`, they'd collide over CLIENT_STATE_DIR and the default control socket.
# Start gnosis_vpn-client as a native host process instead of in Docker (dev/debug convenience)
client-start-on-host:
    #!/usr/bin/env bash
    set -euo pipefail
    root_bin="{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-root"
    worker_bin="{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-worker"
    if [ ! -f "${root_bin}" ] || [ ! -f "${worker_bin}" ]; then
        echo "Error: gnosis_vpn-client binaries not found at {{GVPN_CLIENT_DIR}}/result/bin/" >&2
        echo "Run 'just build-client-native' to build them first" >&2
        exit 1
    fi
    if ! id "{{CLIENT_WORKER_USER}}" > /dev/null 2>&1; then
        echo "Error: worker user '{{CLIENT_WORKER_USER}}' not found on this host." >&2
        echo "gnosis_vpn-root drops privileges to this user (by uid/gid) when spawning gnosis_vpn-worker," >&2
        echo "so it must already exist as a system account (its home directory is irrelevant — create" >&2
        echo "one via your NixOS config, or override the name via CLIENT_WORKER_USER)." >&2
        exit 1
    fi
    if pgrep -f gnosis_vpn-root > /dev/null 2>&1; then
        echo "Client already running on host — skipping start"
        exit 0
    fi
    mkdir -p "{{CLIENT_STATE_DIR}}"
    blokli_url=$(cat "{{CONFIG_DIR}}/blokli_url")
    extra_id_pass=$(cat "{{CONFIG_DIR}}/extra_id.password")
    # sudo backgrounded can't read TTY; pre-authenticate while still interactive
    sudo -v
    sudo RUST_LOG="{{CLIENT_LOG_LEVEL}}" \
        GNOSISVPN_CONFIG_PATH="{{CONFIG_DIR}}/client.toml" \
        GNOSISVPN_HOPR_BLOKLI_URL="${blokli_url}" \
        GNOSISVPN_HOPR_IDENTITY_FILE="{{CONFIG_DIR}}/extra_id.id" \
        GNOSISVPN_HOPR_IDENTITY_PASS="${extra_id_pass}" \
        GNOSISVPN_HOME="{{CLIENT_STATE_DIR}}" \
        GNOSISVPN_CLIENT_AUTOSTART=30min \
        GNOSISVPN_WORKER_USER="{{CLIENT_WORKER_USER}}" \
        GNOSISVPN_LOG_FILE="{{CLIENT_LOG_FILE}}" \
        "${root_bin}" --worker-binary "${worker_bin}" &
    echo "Client PID: $!"

# Stop the host-native client (cascades SIGTERM to the worker via gnosis_vpn-root)
client-stop-on-host:
    #!/usr/bin/env bash
    sudo pkill -f gnosis_vpn-root   2>/dev/null || true
    sudo pkill -f gnosis_vpn-worker 2>/dev/null || true
    echo "Client (host) stopped"

# Tail the host-native client's log file
client-logs-on-host:
    tail -f "{{CLIENT_LOG_FILE}}"

# Purge worker state without prompting (used by down).
# sudo: the container's entrypoint chowns this bind-mounted dir to its internal
# worker uid, which may not be removable by the host user without it.
_purge-state:
    sudo rm -rf "{{CLIENT_STATE_DIR}}"
    echo "Purged {{CLIENT_STATE_DIR}}"

# Remove all persistent worker state (identity keys, cache) from CLIENT_STATE_DIR
purge-state:
    #!/usr/bin/env bash
    set -euo pipefail
    read -r -p "Permanently delete '{{CLIENT_STATE_DIR}}'? Type 'yes' to confirm: " answer
    if [ "${answer}" != "yes" ]; then
        echo "Aborted"
        exit 1
    fi
    sudo rm -rf "{{CLIENT_STATE_DIR}}"
    echo "Purged {{CLIENT_STATE_DIR}}"

# ─── System tests ────────────────────────────────────────────────────────────

# Run gnosis_vpn-client system tests against the live local stack
system-tests:
    #!/usr/bin/env bash
    set -euo pipefail
    for artifact in client.toml extra_id.id extra_id.password extra_id.safe blokli_url; do
        if [ ! -f "{{CONFIG_DIR}}/${artifact}" ]; then
            echo "Missing {{CONFIG_DIR}}/${artifact} — run 'just gen-config' first" >&2
            exit 1
        fi
    done

    worker_binary="{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-worker"
    if [ ! -f "${worker_binary}" ]; then
        echo "Missing ${worker_binary} — run 'just build-client' first" >&2
        exit 1
    fi

    SYSTEM_TEST_HOPRD_ID=$(cat "{{CONFIG_DIR}}/extra_id.id") \
    SYSTEM_TEST_HOPRD_ID_PASSWORD=$(cat "{{CONFIG_DIR}}/extra_id.password") \
    SYSTEM_TEST_SAFE=$(cat "{{CONFIG_DIR}}/extra_id.safe") \
    SYSTEM_TEST_CONFIG=$(cat "{{CONFIG_DIR}}/client.toml") \
    SYSTEM_TEST_WORKER_BINARY="${worker_binary}" \
        just -d "{{GVPN_CLIENT_DIR}}" -f "{{GVPN_CLIENT_DIR}}/justfile" system-tests

# ─── Metrics ─────────────────────────────────────────────────────────────────

# Start otelcol (OTLP HTTP on 127.0.0.1:4318) and VictoriaMetrics (PromQL UI on :8428)
metrics-start:
    #!/usr/bin/env bash
    set -euo pipefail
    configs_dir="{{justfile_directory()}}/configs"

    otelcol_running=$(pgrep -f "otelcol --config" 2>/dev/null || true)
    if [ -n "${otelcol_running}" ]; then
        echo "Metrics found (PID ${otelcol_running}) — skipping start"
        echo "  OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
        exit 0
    fi

    mkdir -p "{{METRICS_DATA_DIR}}"

    otelcol --config "${configs_dir}/otelcol.yaml" > /tmp/hopr-otelcol.log 2>&1 &
    victoria-metrics \
        -storageDataPath "{{METRICS_DATA_DIR}}" \
        -httpListenAddr "127.0.0.1:8428" \
        > /tmp/hopr-victoriametrics.log 2>&1 &

    echo "Started metrics — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"

# Stop otelcol and VictoriaMetrics
metrics-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -f "otelcol --config" 2>/dev/null || true
    pkill -f "victoria-metrics" 2>/dev/null || true
    echo "Metrics stopped"

# ─── Composite ───────────────────────────────────────────────────────────────

# Bring the full stack up, including the client container
up: build metrics-start cluster-start cluster-wait server-start gen-config client-start
    @just summary

# See the caveat on client-start-on-host before using this instead of `up`
# Bring the full stack up with the client running natively on the host instead of in Docker
up-client-on-host: build-cluster build-server build-client-native metrics-start cluster-start-on-host cluster-wait server-start gen-config client-start-on-host
    @just summary-host-client

# Bring up a cluster + exit server reachable from another machine on the LAN, and generate its client config
up-on-network: build-cluster build-server metrics-start cluster-start-on-network cluster-wait server-start gen-config-on-network
    @just summary-on-network

# Print how to control the running client and component versions
summary:
    #!/usr/bin/env bash
    set -uo pipefail
    echo ""
    echo "── Gnosis VPN test stack ──────────────────────────────────────"
    echo ""
    echo "Control the client:"
    echo "  docker exec -it gnosis_vpn-client gnosis_vpn-ctl status"
    echo "  docker exec -it gnosis_vpn-client gnosis_vpn-ctl connect <destination-id>"
    echo "  docker logs -f gnosis_vpn-client"
    echo ""
    echo "Component versions:"
    just _component-version "gnosis_vpn-client" "{{GVPN_CLIENT_DIR}}"
    just _component-version "gnosis_vpn-server" "{{GVPN_SERVER_DIR}}"
    just _component-version "hoprd"             "{{HOPRD_DIR}}"
    echo ""
    echo "Metrics — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"

# Print how to control the host-native client and component versions
summary-host-client:
    #!/usr/bin/env bash
    set -uo pipefail
    echo ""
    echo "── Gnosis VPN test stack (client on host) ─────────────────────"
    echo ""
    echo "Control the client:"
    echo "  {{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-ctl status"
    echo "  {{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-ctl connect <destination-id>"
    echo "  just client-logs-on-host"
    echo ""
    echo "Component versions:"
    just _component-version "gnosis_vpn-client" "{{GVPN_CLIENT_DIR}}"
    just _component-version "gnosis_vpn-server" "{{GVPN_SERVER_DIR}}"
    just _component-version "hoprd"             "{{HOPRD_DIR}}"
    echo ""
    echo "Metrics — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"

# Print what to copy/run on the other machine, the required firewall ports, and component versions
summary-on-network:
    #!/usr/bin/env bash
    set -uo pipefail
    lan_ip=$(just _lan-ip)
    remote_user=$(whoami)
    blokli_url=$(cat "{{CONFIG_DIR}}/blokli_url-on-network")
    bundle_dir="/tmp/gnosis_vpn-on-network"
    worker_home="/home/{{CLIENT_WORKER_USER}}"
    echo ""
    echo "── Gnosis VPN test stack (reachable on the LAN at ${lan_ip}) ───"
    echo ""
    echo "On the other machine, from a gnosis_vpn-client checkout built with"
    echo "'cargo build --release':"
    echo "  1. Pull the bundled config/identity files from this host, into a"
    echo "     world-readable location — gnosis_vpn-worker reads the identity"
    echo "     file as an unprivileged user, so it can't sit under your home dir:"
    echo "       rsync -avz ${remote_user}@${lan_ip}:{{NETWORK_BUNDLE_DIR}}/ ${bundle_dir}/"
    echo "  2. Make sure worker user '{{CLIENT_WORKER_USER}}' exists on that machine too"
    echo "     (gnosis_vpn-root drops privileges to it when spawning gnosis_vpn-worker)"
    echo "  3. The worker binary has the same problem as the identity file above —"
    echo "     target/release sits under your home dir, unreachable for the worker"
    echo "     user (a nix build wouldn't need this, its result lives in the"
    echo "     world-readable /nix/store). Copy it out and hand it to the worker user:"
    echo "       sudo rm -f ${worker_home}/gnosis_vpn-worker"
    echo "       sudo cp ./target/release/gnosis_vpn-worker ${worker_home}/"
    echo "       sudo chown {{CLIENT_WORKER_USER}}:gnosisvpn ${worker_home}/gnosis_vpn-worker"
    echo "  4. Run:"
    echo "       sudo RUST_LOG=info \\"
    echo "       ./target/release/gnosis_vpn-root \\"
    echo "         --config-path ${bundle_dir}/client-on-network.toml \\"
    echo "         --hopr-blokli-url \"${blokli_url}\" \\"
    echo "         --hopr-identity-file ${bundle_dir}/extra_id.id \\"
    echo "         --hopr-identity-pass \"\$(cat ${bundle_dir}/extra_id.password)\" \\"
    echo "         --client-autostart 30min \\"
    echo "         --worker-user {{CLIENT_WORKER_USER}} \\"
    echo "         --state-home ${worker_home} \\"
    echo "         --worker-binary ${worker_home}/gnosis_vpn-worker"
    echo ""
    echo "Make sure this host's firewall allows inbound from the other machine on:"
    echo "  UDP 9000..$(({{CLUSTER_SIZE}} - 1 + 9000))   (HOPR P2P)"
    echo "  TCP 8080                                     (Blokli)"
    echo "  TCP 8000..$(({{SERVER_COUNT}} - 1 + 8000))   (VPN server API)"
    echo "  UDP 51821..$(({{SERVER_COUNT}} - 1 + 51821)) (VPN server WireGuard)"
    echo ""
    echo "Component versions:"
    just _component-version "gnosis_vpn-server" "{{GVPN_SERVER_DIR}}"
    just _component-version "hoprd"             "{{HOPRD_DIR}}"
    echo ""
    echo "Metrics (on this host) — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"

# Resolve the LAN-reachable IP: LAN_IP override, or auto-detect via default route
_lan-ip:
    #!/usr/bin/env bash
    set -euo pipefail
    # Downstream recipes splice this into host:port strings and firewall rules, so it must be
    # a plain IPv4 dotted-quad — a hostname or IPv6 address would silently produce invalid targets.
    ipv4_pattern='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    if [ -n "{{LAN_IP}}" ]; then
        if ! [[ "{{LAN_IP}}" =~ ${ipv4_pattern} ]]; then
            echo "Error: LAN_IP='{{LAN_IP}}' is not an IPv4 dotted-quad (hostnames/IPv6 aren't supported)" >&2
            exit 1
        fi
        echo "{{LAN_IP}}"
        exit 0
    fi
    lan_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')
    if [ -z "${lan_ip}" ]; then
        echo "Error: could not auto-detect a LAN IP (no default route?) — set LAN_IP explicitly" >&2
        exit 1
    fi
    echo "${lan_ip}"

# The P2P host the currently running cluster (if any) was started with, or empty if not running.
# hoprd-localcluster's status JSON reports each node's dial address (host:port) from the moment
# it's created — deterministic from --p2p-host, so this reflects the real flag even before any
# node is ready.
_cluster-p2p-host:
    #!/usr/bin/env bash
    set -euo pipefail
    "{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster" status --data-dir "{{DATA_DIR}}" 2>/dev/null \
        | jq -r '.nodes[0].p2p // empty' | sed -n 's/:[0-9]*$//p'

# Print <name>'s checked-out branch and commit, plus tag if HEAD is exactly tagged
_component-version name dir:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ ! -d "{{dir}}/.git" ]; then
        echo "  {{name}}: {{dir}} (not a git checkout)"
        exit 0
    fi
    commit=$(git -C "{{dir}}" rev-parse --short HEAD 2>/dev/null) || { echo "  {{name}}: unable to resolve commit"; exit 0; }
    branch=$(git -C "{{dir}}" symbolic-ref --short -q HEAD || echo "detached")
    tag=$(git -C "{{dir}}" describe --tags --exact-match 2>/dev/null || true)
    dirty=""
    [ -n "$(git -C "{{dir}}" status --porcelain 2>/dev/null)" ] && dirty=" (dirty)"
    if [ -n "${tag}" ]; then
        echo "  {{name}}: ${tag} (${branch}, ${commit})${dirty}"
    else
        echo "  {{name}}: ${branch} (${commit})${dirty}"
    fi

# Tear the full stack down and purge client state (cluster always restarts with new identities)
down: client-stop server-stop cluster-stop metrics-stop _purge-state

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
    #!/usr/bin/env bash
    tail -f "{{DATA_DIR}}/logs/"*.log &
    docker logs -f gnosis_vpn-client

# Tail only cluster node logs
node-logs:
    tail -f "{{DATA_DIR}}/logs/"hoprd_*.log
