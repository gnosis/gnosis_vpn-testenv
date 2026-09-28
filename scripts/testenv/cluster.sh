#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${LOCALCLUSTER_BIN:?}"
: "${DATA_DIR:?}"

# The P2P host the running cluster (if any) was started with, or empty if not running.
# hoprd-localcluster's status JSON reports each node's dial address (host:port) from the moment it's
# created — deterministic from --p2p-host, so this reflects the real flag even before any node is ready.
p2p_host() {
    cluster_status_json | jq -r '.nodes[0].p2p // empty' | sed -n 's/:[0-9]*$//p'
}

# "yes"/"no" — whether the cluster's generated node configs carry a PIX strategy. Read off the config
# on disk rather than the status JSON, which does not report it; `--enable-pix` is baked in at
# generation time, so a running cluster cannot be switched either way.
has_pix() {
    if grep -qE '^\s+- Pix:' "${DATA_DIR}/hoprd_cfg_0.yaml" 2>/dev/null; then echo yes; else echo no; fi
}

state() {
    cluster_status_json | jq -r '.state // "not_running"'
}

start() {
    : "${HOPRD_BIN:?}"
    : "${CHAIN_IMAGE:?}"
    : "${CLUSTER_SIZE:?}"
    : "${CLUSTER_LOG_LEVEL:?}"
    local p2p="${1:?usage: cluster.sh start <p2p_host>}"

    require_localcluster_bin
    [ -f "${HOPRD_BIN}" ] || die \
        "Error: hoprd not found at ${HOPRD_BIN}" \
        "Run 'just build-cluster' to build it first"

    local cluster_state
    cluster_state=$(state)
    [ "${cluster_state}" != "failed" ] ||
        die "Cluster is in state 'failed' — run 'just cluster-stop' to clean up before restarting"

    local want_pix=no
    local pix_args=()
    if [ -n "${CLUSTER_ENABLE_PIX:-}" ]; then
        want_pix=yes
        pix_args=(--enable-pix)
    fi

    if [ "${cluster_state}" != "not_running" ]; then
        local current_host current_pix
        current_host=$(p2p_host)
        # PIX is written into the node configs at generation time, so a running cluster cannot be
        # switched into or out of it — checked alongside the host for the same reason.
        current_pix=$(has_pix)
        if [ "${current_host}" = "${p2p}" ] && [ "${current_pix}" = "${want_pix}" ]; then
            local pid
            pid=$(pgrep -f hoprd-localcluster | head -1)
            echo "Cluster found in state '${cluster_state}' (PID ${pid}), already on P2P host ${p2p} with PIX ${current_pix} — skipping start"
            return 0
        fi
        echo "Cluster is running with P2P host '${current_host}' and PIX ${current_pix}, but this recipe needs '${p2p}' with PIX ${want_pix} — restarting"
        stop
    fi

    if [ "${CLUSTER_PIX_POOL:-}" = "curvy" ]; then
        # HOPRD_CHAIN_URL points the cluster at the Curvy chain instead of starting its own (so
        # --chain-image below goes unused), HOPRD_CURVY_SCOPE_AGGREGATOR has it grant every Safe —
        # the client's included — the aggregator target a direct shield needs, and the rest reaches
        # the nodes' Curvy pools as their HOPRD_CURVY_* overrides.
        load_curvy_env
    fi

    RUST_LOG="${CLUSTER_LOG_LEVEL}" \
        "${LOCALCLUSTER_BIN}" \
        --hoprd-bin "${HOPRD_BIN}" \
        --chain-image "${CHAIN_IMAGE}" \
        --size "${CLUSTER_SIZE}" \
        --p2p-host "${p2p}" \
        --data-dir "${DATA_DIR}" \
        --extra-identities 1 \
        "${pix_args[@]}" &
    echo "Localcluster PID: $! (P2P on ${p2p}, PIX ${want_pix})"
}

wait_running() {
    require_localcluster_bin
    echo "Waiting for cluster..."
    until [ "$(cluster_status_json | jq -r '.state // empty')" = "running" ]; do
        sleep 1
    done
    echo "Cluster running"
}

status() {
    require_localcluster_bin
    "${LOCALCLUSTER_BIN}" status --data-dir "${DATA_DIR}"
}

stop() {
    pkill -f hoprd-localcluster 2>/dev/null || true
    pkill -f "result-hoprd[^/]*/bin/hoprd" 2>/dev/null || true
    docker rm -f hopr-chain 2>/dev/null || true
    # cluster recreates state everytime, so we can safely delete it on stop
    rm -rf "${DATA_DIR}"
    echo "Cluster stopped"
}

case "${1:-}" in
start) start "${2:-}" ;;
start-on-network) start "$(lan_ip)" ;;
wait) wait_running ;;
status) status ;;
stop) stop ;;
p2p-host) p2p_host ;;
has-pix) has_pix ;;
*) die "usage: cluster.sh start <p2p_host>|start-on-network|wait|status|stop|p2p-host|has-pix" ;;
esac
