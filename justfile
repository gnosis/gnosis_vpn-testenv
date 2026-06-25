# Paths to sibling repos — override via env in CI
HOPRD_DIR       := env_var_or_default("HOPRD_DIR",       "../hoprd")
GVPN_SERVER_DIR := env_var_or_default("GVPN_SERVER_DIR", "../gnosis_vpn-server")
GVPN_CLIENT_DIR := env_var_or_default("GVPN_CLIENT_DIR", "../gnosis_vpn-client")

# Localcluster settings
CLUSTER_SIZE := env_var_or_default("CLUSTER_SIZE", "3")
DATA_DIR     := env_var_or_default("DATA_DIR",     "/tmp/hopr-nodes")
CHAIN_IMAGE  := env_var_or_default("CHAIN_IMAGE",  "europe-west3-docker.pkg.dev/hoprassociation/docker-images/bloklid-anvil:latest")

# VPN server settings
SERVER_COUNT := env_var_or_default("SERVER_COUNT", "1")

# Grafana UI port for the otel-lgtm metrics container (OTLP HTTP always binds 4318)
METRICS_GRAFANA_PORT := env_var_or_default("METRICS_GRAFANA_PORT", "3000")

# Session hop count for destinations (0 = direct, 1+ = via relays)
HOPS := env_var_or_default("HOPS", "1")

# Log levels for each component (passed as RUST_LOG)
CLIENT_LOG_LEVEL  := env_var_or_default("CLIENT_LOG_LEVEL",  "info,gnosis_vpn_root=debug,gnosis_vpn_lib=debug,gnosis_vpn_worker=debug")
SERVER_LOG_LEVEL  := env_var_or_default("SERVER_LOG_LEVEL",  "info")
CLUSTER_LOG_LEVEL := env_var_or_default("CLUSTER_LOG_LEVEL", "info")

# Client log file path
CLIENT_LOG_FILE := env_var_or_default("CLIENT_LOG_FILE", "/tmp/gnosis_vpn-client.log")

# OS user the worker process runs as
CLIENT_WORKER_USER := env_var_or_default("CLIENT_WORKER_USER", "gnosisvpn")

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

# Build gnosis_vpn-client binaries
build-client:
    nix build -L --out-link {{GVPN_CLIENT_DIR}}/result {{GVPN_CLIENT_DIR}}#binary-gnosis_vpn-x86_64-linux

# Build all components
build: build-cluster build-server build-client

# ─── Localcluster ────────────────────────────────────────────────────────────

# Start localcluster in the background (--extra-identities 1 pre-funds the client entry node identity)
cluster-start:
    #!/usr/bin/env bash
    set -euo pipefail
    pid_file=/tmp/hoprd-localcluster.pid
    if [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
        echo "Cluster already running — skipping start"
        echo "Localcluster PID: $(cat "${pid_file}")"
        exit 0
    fi
    rm -rf "{{DATA_DIR}}"
    RUST_LOG={{CLUSTER_LOG_LEVEL}} \
        "{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster" \
        --hoprd-bin   "{{HOPRD_DIR}}/result-hoprd/bin/hoprd" \
        --chain-image "{{CHAIN_IMAGE}}" \
        --size        {{CLUSTER_SIZE}} \
        --data-dir    "{{DATA_DIR}}" \
        --extra-identities 1 &
    echo $! > /tmp/hoprd-localcluster.pid
    echo "Localcluster PID: $(cat /tmp/hoprd-localcluster.pid)"

# Poll until cluster reaches state=running
cluster-wait:
    #!/usr/bin/env bash
    set -euo pipefail
    lc_bin="{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster"
    echo "Waiting for cluster..."
    until [ "$("${lc_bin}" status --data-dir "{{DATA_DIR}}" 2>/dev/null | jq -r '.state // empty')" = "running" ]; do
        sleep 1
    done
    echo "Cluster running"

# Print live cluster status as JSON
cluster-status:
    "{{HOPRD_DIR}}/result-localcluster/bin/hoprd-localcluster" status --data-dir "{{DATA_DIR}}"

# Stop localcluster
cluster-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    pid_file=/tmp/hoprd-localcluster.pid
    if [ -f "${pid_file}" ]; then
        kill "$(cat "${pid_file}")" 2>/dev/null || true
        rm -f "${pid_file}"
    fi
    pkill -f hoprd-localcluster 2>/dev/null || true
    pkill -f "result-hoprd/bin/hoprd" 2>/dev/null || true
    docker rm -f hopr-chain 2>/dev/null || true
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

# Start gnosis_vpn-client in the background (requires root for WireGuard)
client-start:
    #!/usr/bin/env bash
    set -euo pipefail
    pid_file=/tmp/gnosis_vpn-client.pid
    if [ -f "${pid_file}" ] && sudo kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
        echo "Client already running — skipping start"
        echo "Client PID: $(cat "${pid_file}")"
        exit 0
    fi
    blokli_url=$(cat "{{CONFIG_DIR}}/blokli_url")
    extra_id_file="{{CONFIG_DIR}}/extra_id.id"
    extra_id_pass=$(cat "{{CONFIG_DIR}}/extra_id.password")
    # sudo backgrounded can't read TTY; pre-authenticate while still interactive
    sudo -v
    sudo RUST_LOG={{CLIENT_LOG_LEVEL}} \
        "{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-root" \
        -c "{{CONFIG_DIR}}/client.toml" \
        --hopr-blokli-url "${blokli_url}" \
        --hopr-identity-file "${extra_id_file}" \
        --hopr-identity-pass "${extra_id_pass}" \
        --worker-user "{{CLIENT_WORKER_USER}}" \
        --worker-binary "{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-worker" \
        --log-file "{{CLIENT_LOG_FILE}}" &
    echo $! > /tmp/gnosis_vpn-client.pid
    echo "Client PID: $(cat /tmp/gnosis_vpn-client.pid)"

# Stop gnosis_vpn-client (cascades SIGTERM to the worker via gnosis_vpn-root)
client-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    pid_file=/tmp/gnosis_vpn-client.pid
    if [ -f "${pid_file}" ]; then
        sudo kill "$(cat "${pid_file}")" 2>/dev/null || true
        rm -f "${pid_file}"
    fi
    sudo pkill -f gnosis_vpn-root   2>/dev/null || true
    sudo pkill -f gnosis_vpn-worker 2>/dev/null || true
    echo "Client stopped"

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

# Start grafana/otel-lgtm: accepts OTLP on :4318, exposes Grafana on :METRICS_GRAFANA_PORT
metrics-start:
    #!/usr/bin/env bash
    set -euo pipefail
    name="hopr-metrics"
    if docker container inspect "${name}" > /dev/null 2>&1; then
        echo "${name} already exists — skipping start"
        echo "  Grafana: http://localhost:{{METRICS_GRAFANA_PORT}} (admin/admin)"
        exit 0
    fi
    docker run --rm --detach \
        --publish "{{METRICS_GRAFANA_PORT}}:3000" \
        --publish "4318:4318" \
        --name "${name}" \
        grafana/otel-lgtm
    echo "Started ${name} — Grafana: http://localhost:{{METRICS_GRAFANA_PORT}} (admin/admin)"

# Stop the grafana/otel-lgtm metrics container
metrics-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    docker stop hopr-metrics 2>/dev/null \
        && echo "Stopped hopr-metrics" \
        || echo "hopr-metrics was not running"

# ─── Composite ───────────────────────────────────────────────────────────────

# Bring the full stack up; client-start is intentionally separate (needs sudo)
up: metrics-start cluster-start cluster-wait server-start gen-config

# Tear the full stack down
down: client-stop server-stop cluster-stop metrics-stop

# Remove all generated configs, data, PID files, logs, and the chain container
clean:
    rm -rf "{{CONFIG_DIR}}" "{{DATA_DIR}}"
    rm -f /tmp/hoprd-localcluster.pid /tmp/gnosis_vpn-client.pid "{{CLIENT_LOG_FILE}}"
    sudo rm -f /tmp/gnosis_vpn-worker
    docker rm -f hopr-chain 2>/dev/null || true
    echo "Clean done"

# Tear the full stack down and wipe all state
reset: down clean

# Full development setup: cluster + server + config, then prints the client run command.
# Set CLIENT_WORKER_USER to the OS user the worker runs as (must exist — see README).
development-setup: metrics-start cluster-start cluster-wait server-start gen-config
    #!/usr/bin/env bash
    set -euo pipefail
    worker_bin_src="{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-worker"
    root_bin="{{GVPN_CLIENT_DIR}}/result/bin/gnosis_vpn-root"
    blokli_url=$(cat "{{CONFIG_DIR}}/blokli_url")
    id_pass=$(cat "{{CONFIG_DIR}}/extra_id.password")
    log_level="{{CLIENT_LOG_LEVEL}}"
    config_dir="{{CONFIG_DIR}}"
    worker_user="{{CLIENT_WORKER_USER}}"
    # octal \134 = backslash; avoids \\ in the justfile which just 1.43+ rejects
    bs=$'\134'

    # The Nix store is read-only, so copy the worker to /tmp before chown-ing it
    worker_bin="/tmp/gnosis_vpn-worker"
    cp "${worker_bin_src}" "${worker_bin}"
    sudo chown "${worker_user}" "${worker_bin}"

    echo ""
    echo "Metrics: http://localhost:{{METRICS_GRAFANA_PORT}} (admin/admin) — explore hoprd_* in the Mimir datasource"
    echo ""
    echo "Stack is up. Run the client with:"
    echo ""
    echo "sudo RUST_LOG=\"${log_level}\" ${bs}"
    echo "     ${root_bin} ${bs}"
    echo "     -c ${config_dir}/client.toml ${bs}"
    echo "     --hopr-blokli-url \"${blokli_url}\" ${bs}"
    echo "     --hopr-identity-file ${config_dir}/extra_id.id ${bs}"
    echo "     --hopr-identity-pass \"${id_pass}\" ${bs}"
    echo "     --worker-binary ${worker_bin} ${bs}"
    echo "     --worker-user ${worker_user} ${bs}"
    echo "     --allow-insecure ${bs}"
    echo "     --allow-experimental ${bs}"
    echo "     --client-autostart 30min"
    echo ""

# Tail all cluster node logs and client log
logs:
    tail -f "{{DATA_DIR}}/logs/"*.log "{{CLIENT_LOG_FILE}}"
