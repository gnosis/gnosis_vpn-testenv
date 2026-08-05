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

# Generated config output dir
CONFIG_DIR    := env_var_or_default("CONFIG_DIR", "/tmp/gnosis_vpn-testenv")
TEMPLATES_DIR := justfile_directory() + "/templates"

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
    just firewall-allow-p2p || echo "firewall-allow-p2p failed — continuing without the host-firewall punch-through (see README)"

# Remove the Docker network
network-remove:
    #!/usr/bin/env bash
    set -euo pipefail
    just firewall-remove-p2p || echo "firewall-remove-p2p failed — leftover rule (if any) can be cleared manually"
    docker network rm "{{DOCKER_NETWORK}}" 2>/dev/null || true

# Best-effort: allow the localcluster's P2P UDP ports through the host firewall (see README); warns rather than fails without a nixos-fw chain
firewall-allow-p2p:
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p "{{CONFIG_DIR}}"
    status_file="{{CONFIG_DIR}}/firewall-status"
    # DOCKER_NETWORK_GATEWAY is a real host interface, so traffic to it (unlike 127.0.0.1)
    # hits the host's INPUT chain — NixOS's default-deny nixos-fw silently drops it otherwise.
    # Outcome is recorded to status_file so `just summary` can report it without re-prompting sudo.
    if ! sudo iptables -L nixos-fw -n > /dev/null 2>&1; then
        echo "firewall-allow-p2p: no nixos-fw chain found (not a NixOS host, or firewall disabled) — skipping"
        echo "disabled: no nixos-fw chain (not NixOS, firewall off, or no sudo access)" > "${status_file}"
        exit 0
    fi
    if ! docker network inspect "{{DOCKER_NETWORK}}" > /dev/null 2>&1; then
        echo "firewall-allow-p2p: Docker network {{DOCKER_NETWORK}} not found — skipping"
        echo "unknown: Docker network {{DOCKER_NETWORK}} not found" > "${status_file}"
        exit 0
    fi
    network_id=$(docker network inspect "{{DOCKER_NETWORK}}" | jq -r '.[0].Id')
    if [ -z "${network_id}" ]; then
        echo "firewall-allow-p2p: warning: could not resolve {{DOCKER_NETWORK}}'s bridge interface — skipping"
        echo "unknown: could not resolve bridge interface" > "${status_file}"
        exit 0
    fi
    bridge_if="br-${network_id:0:12}"
    port_lo=9000
    port_hi=$((9000 + {{CLUSTER_SIZE}} - 1))
    if sudo iptables -C nixos-fw -i "${bridge_if}" -p udp --dport "${port_lo}:${port_hi}" -j ACCEPT 2>/dev/null; then
        echo "Host firewall already allows UDP ${port_lo}-${port_hi} from ${bridge_if}"
        echo "enabled: UDP ${port_lo}-${port_hi} allowed from ${bridge_if}" > "${status_file}"
    elif sudo iptables -I nixos-fw -i "${bridge_if}" -p udp --dport "${port_lo}:${port_hi}" -j ACCEPT; then
        echo "Opened UDP ${port_lo}-${port_hi} from ${bridge_if} in host firewall (nixos-fw)"
        echo "enabled: UDP ${port_lo}-${port_hi} allowed from ${bridge_if}" > "${status_file}"
    else
        echo "firewall-allow-p2p: warning: failed to insert firewall rule — continuing without it"
        echo "disabled: failed to insert rule for ${bridge_if}" > "${status_file}"
    fi

# Best-effort: remove the firewall-allow-p2p rule (run before the network itself is removed); warns rather than fails
firewall-remove-p2p:
    #!/usr/bin/env bash
    set -uo pipefail
    if ! sudo iptables -L nixos-fw -n > /dev/null 2>&1; then
        exit 0
    fi
    if ! docker network inspect "{{DOCKER_NETWORK}}" > /dev/null 2>&1; then
        exit 0
    fi
    network_id=$(docker network inspect "{{DOCKER_NETWORK}}" | jq -r '.[0].Id')
    if [ -z "${network_id}" ]; then
        exit 0
    fi
    bridge_if="br-${network_id:0:12}"
    port_lo=9000
    port_hi=$((9000 + {{CLUSTER_SIZE}} - 1))
    if ! sudo iptables -D nixos-fw -i "${bridge_if}" -p udp --dport "${port_lo}:${port_hi}" -j ACCEPT 2>/dev/null; then
        echo "firewall-remove-p2p: warning: rule not found or could not be removed — leftover rule (if any) can be cleared manually"
    fi

# ─── Localcluster ────────────────────────────────────────────────────────────

# Start localcluster (--extra-identities 1 pre-funds the client identity; P2P binds to the Docker gateway IP)
cluster-start: network-create
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
    cluster_state=$("${lc_bin}" status --data-dir "{{DATA_DIR}}" 2>/dev/null | jq -r '.state // "not_running"')
    if [ "${cluster_state}" = "failed" ]; then
        echo "Cluster is in state 'failed' — run 'just cluster-stop' to clean up before restarting"
        exit 1
    fi
    if [ "${cluster_state}" != "not_running" ]; then
        pid=$(pgrep -f hoprd-localcluster | head -1)
        echo "Cluster found in state '${cluster_state}' (PID ${pid}) — skipping start"
        exit 0
    fi
    RUST_LOG={{CLUSTER_LOG_LEVEL}} \
        "{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster" \
        --hoprd-bin   "{{HOPRD_DIR}}/result-hoprd/bin/hoprd" \
        --chain-image "{{CHAIN_IMAGE}}" \
        --size        {{CLUSTER_SIZE}} \
        --p2p-host    {{DOCKER_NETWORK_GATEWAY}} \
        --data-dir    "{{DATA_DIR}}" \
        --extra-identities 1 &
    echo "Localcluster PID: $!"

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
            --name "${name}" \
            gnosis_vpn-server
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
    echo "Started gnosis_vpn-client"

# Stop the client container
client-stop:
    docker stop gnosis_vpn-client 2>/dev/null || true

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

# Print how to control the running client, component versions, and firewall state
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
    echo "Host firewall P2P punch-through (UDP {{DOCKER_NETWORK_GATEWAY}}:9000+): $(just _firewall-status)"
    echo ""
    echo "Metrics — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"

# Print <name>'s checked-out commit, and tag if HEAD is exactly tagged
_component-version name dir:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ ! -d "{{dir}}/.git" ]; then
        echo "  {{name}}: {{dir}} (not a git checkout)"
        exit 0
    fi
    commit=$(git -C "{{dir}}" rev-parse --short HEAD 2>/dev/null) || { echo "  {{name}}: unable to resolve commit"; exit 0; }
    tag=$(git -C "{{dir}}" describe --tags --exact-match 2>/dev/null || true)
    dirty=""
    [ -n "$(git -C "{{dir}}" status --porcelain 2>/dev/null)" ] && dirty=" (dirty)"
    if [ -n "${tag}" ]; then
        echo "  {{name}}: ${tag} (${commit})${dirty}"
    else
        echo "  {{name}}: ${commit}${dirty} (untagged)"
    fi

# Print the outcome recorded by the last firewall-allow-p2p run
_firewall-status:
    #!/usr/bin/env bash
    set -uo pipefail
    status_file="{{CONFIG_DIR}}/firewall-status"
    if [ -f "${status_file}" ]; then
        cat "${status_file}"
    else
        echo "unknown (network-create hasn't run yet this session)"
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
