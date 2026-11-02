#!/usr/bin/env bash
# No `-e`: a missing or broken component checkout must not abort the whole report.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${GVPN_CLIENT_DIR:?}"
: "${GVPN_SERVER_DIR:?}"
: "${HOPRD_DIR:?}"

# Print <name>'s checked-out branch and commit, plus tag if HEAD is exactly tagged.
component_version() {
    local name="$1" dir="$2" commit branch tag dirty=""
    if [ ! -d "${dir}/.git" ]; then
        echo "  ${name}: ${dir} (not a git checkout)"
        return 0
    fi
    commit=$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null) || {
        echo "  ${name}: unable to resolve commit"
        return 0
    }
    branch=$(git -C "${dir}" symbolic-ref --short -q HEAD || echo "detached")
    tag=$(git -C "${dir}" describe --tags --exact-match 2>/dev/null || true)
    [ -n "$(git -C "${dir}" status --porcelain 2>/dev/null)" ] && dirty=" (dirty)"
    if [ -n "${tag}" ]; then
        echo "  ${name}: ${tag} (${branch}, ${commit})${dirty}"
    else
        echo "  ${name}: ${branch} (${commit})${dirty}"
    fi
}

default() {
    echo ""
    echo "── Gnosis VPN test stack ──────────────────────────────────────"
    echo ""
    echo "Control the client:"
    echo "  docker exec -it gnosis_vpn-client gnosis_vpn-ctl status"
    echo "  docker exec -it gnosis_vpn-client gnosis_vpn-ctl connect <destination-id>"
    echo "  docker logs -f gnosis_vpn-client"
    echo ""
    echo "Component versions:"
    component_version "gnosis_vpn-client" "${GVPN_CLIENT_DIR}"
    component_version "gnosis_vpn-server" "${GVPN_SERVER_DIR}"
    component_version "hoprd" "${HOPRD_DIR}"
    echo ""
    echo "Metrics — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"
}

host_client() {
    echo ""
    echo "── Gnosis VPN test stack (client on host) ─────────────────────"
    echo ""
    echo "Control the client:"
    # the worker belongs to CLIENT_WORKER_USER; only root may drive another user's worker
    echo "  sudo ${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-ctl status"
    echo "  sudo ${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-ctl connect <destination-id>"
    echo "  just client-logs-on-host"
    echo ""
    echo "Component versions:"
    component_version "gnosis_vpn-client" "${GVPN_CLIENT_DIR}"
    component_version "gnosis_vpn-server" "${GVPN_SERVER_DIR}"
    component_version "hoprd" "${HOPRD_DIR}"
    echo ""
    echo "Metrics — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"
}

on_network() {
    : "${CONFIG_DIR:?}"
    : "${NETWORK_BUNDLE_DIR:?}"
    : "${CLUSTER_SIZE:?}"
    : "${SERVER_COUNT:?}"
    local ip remote_user blokli_url network
    ip=$(lan_ip)
    remote_user=$(whoami)
    blokli_url=$(cat "${CONFIG_DIR}/blokli_url-on-network")
    network=$(blokli_network "${blokli_url}")
    local bundle_dir="/tmp/gnosis_vpn-on-network"
    local identity_dir="\$HOME/.local/share/gnosisvpn/networks/${network}"
    echo ""
    echo "── Gnosis VPN test stack (reachable on the LAN at ${ip}) ───"
    echo ""
    echo "On the other machine, from a gnosis_vpn-client checkout built with"
    echo "'cargo build --release'. The worker runs as you, so nothing needs to be"
    echo "world-readable:"
    echo "  1. Pull the bundled config/identity files from this host:"
    echo "       rsync -avz ${remote_user}@${ip}:${NETWORK_BUNDLE_DIR}/ ${bundle_dir}/"
    echo "  2. Stage the identity where your worker looks for it (macOS:"
    echo "     \$HOME/Library/Application Support/GnosisVPN/networks/${network}):"
    echo "       mkdir -p ${identity_dir}"
    echo "       cp ${bundle_dir}/extra_id.id ${identity_dir}/hopr.id"
    echo "       printf '%s' \"\$(cat ${bundle_dir}/extra_id.password)\" > ${identity_dir}/hopr.pass"
    echo "       chmod 0600 ${identity_dir}/hopr.id ${identity_dir}/hopr.pass"
    echo "  3. Start the service:"
    echo "       sudo RUST_LOG=info \\"
    echo "       ./target/release/gnosis_vpn-root \\"
    echo "         --config-path ${bundle_dir}/client-on-network.toml \\"
    echo "         --hopr-blokli-url \"${blokli_url}\" \\"
    echo "         --worker-binary \"\$PWD/target/release/gnosis_vpn-worker\""
    echo "  4. In another shell, as yourself (not sudo):"
    echo "       ./target/release/gnosis_vpn-ctl start-client 30min"
    echo ""
    echo "Make sure this host's firewall allows inbound from the other machine on:"
    echo "  UDP 9000..$((CLUSTER_SIZE - 1 + 9000))   (HOPR P2P)"
    echo "  TCP 8080                                     (Blokli)"
    echo "  TCP 8000..$((SERVER_COUNT - 1 + 8000))   (VPN server API)"
    echo "  UDP 51821..$((SERVER_COUNT - 1 + 51821)) (VPN server WireGuard)"
    echo ""
    echo "Component versions:"
    component_version "gnosis_vpn-server" "${GVPN_SERVER_DIR}"
    component_version "hoprd" "${HOPRD_DIR}"
    echo ""
    echo "Metrics (on this host) — OTLP HTTP: 127.0.0.1:4318 | PromQL UI: http://localhost:8428"
    echo "─────────────────────────────────────────────────────────────────"
}

# Scoped to direct execution so bats can source this file for component_version alone.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    case "${1:-}" in
    default) default ;;
    host-client) host_client ;;
    on-network) on_network ;;
    *) die "usage: summary.sh default|host-client|on-network" ;;
    esac
fi
