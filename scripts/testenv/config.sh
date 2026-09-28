#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${CONFIG_DIR:?}"
: "${TEMPLATES_DIR:?}"

# Derive client config and system-test artifacts from live cluster status.
gen() {
    : "${DATA_DIR:?}"
    : "${LOCALCLUSTER_BIN:?}"
    : "${HOPS:?}"
    mkdir -p "${CONFIG_DIR}"

    local status blokli_url
    status=$("${LOCALCLUSTER_BIN}" status --data-dir "${DATA_DIR}")
    blokli_url=$(echo "${status}" | jq -r '.blokli_url')

    # One [destinations.node-N] block per cluster exit node
    local destinations="" node id address block
    while IFS= read -r node; do
        id=$(echo "${node}" | jq -r '.id')
        address=$(echo "${node}" | jq -r '.address')
        block=$(DEST_ID="${id}" DEST_ADDRESS="${address}" DEST_HOPS="${HOPS}" \
            envsubst "\$DEST_ID,\$DEST_ADDRESS,\$DEST_HOPS" \
            <"${TEMPLATES_DIR}/destination.toml.tpl")
        destinations+="${block}"$'\n'
    done < <(echo "${status}" | jq -c '.nodes[]')

    # The PIX block has to agree with how the cluster was started, so it comes off the same switch.
    local pix_section
    if [ -n "${CLUSTER_ENABLE_PIX:-}" ]; then
        pix_section=$(cat "${TEMPLATES_DIR}/pix-on.toml.tpl")
    else
        pix_section=$(cat "${TEMPLATES_DIR}/pix-off.toml.tpl")
    fi

    DESTINATIONS="${destinations}" PIX_SECTION="${pix_section}" \
        envsubst "\$DESTINATIONS,\$PIX_SECTION" \
        <"${TEMPLATES_DIR}/client.toml.tpl" \
        >"${CONFIG_DIR}/client.toml"

    echo "${blokli_url}" >"${CONFIG_DIR}/blokli_url"
    echo "Generated ${CONFIG_DIR}/client.toml"

    # Persist the extra identity artifacts needed by client and system tests
    local extra keystore_path
    extra=$(echo "${status}" | jq -c '.extras[0] // empty')
    [ -n "${extra}" ] || return 0
    keystore_path=$(echo "${extra}" | jq -r '.keystore_path')
    cp "${keystore_path}" "${CONFIG_DIR}/extra_id.id"
    echo "${extra}" | jq -r '.password' >"${CONFIG_DIR}/extra_id.password"
    echo "${extra}" | jq -r '.safe_address' >"${CONFIG_DIR}/extra_id.safe"
    echo "${extra}" | jq -r '.module_address' >"${CONFIG_DIR}/extra_id.module"
    echo "Saved extra identity artifacts to ${CONFIG_DIR}"
}

# Rewrite the generated config to point a client on another machine at this host's LAN IP.
gen_on_network() {
    : "${NETWORK_BUNDLE_DIR:?}"
    local ip
    ip=$(lan_ip)
    sed "s/127\.0\.0\.1/${ip}/g" "${CONFIG_DIR}/client.toml" >"${CONFIG_DIR}/client-on-network.toml"
    sed "s/localhost/${ip}/" "${CONFIG_DIR}/blokli_url" >"${CONFIG_DIR}/blokli_url-on-network"
    mkdir -p "${NETWORK_BUNDLE_DIR}"
    cp "${CONFIG_DIR}/client-on-network.toml" \
        "${CONFIG_DIR}/extra_id.id" \
        "${CONFIG_DIR}/extra_id.password" \
        "${NETWORK_BUNDLE_DIR}/"
    echo "Generated ${CONFIG_DIR}/client-on-network.toml (exit server via ${ip})"
    echo "Bundled remote-client files into ${NETWORK_BUNDLE_DIR}"
}

case "${1:-}" in
gen) gen ;;
gen-on-network) gen_on_network ;;
*) die "usage: config.sh gen|gen-on-network" ;;
esac
