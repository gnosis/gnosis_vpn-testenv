# shellcheck shell=bash
# Helpers shared by the scripts/testenv dispatchers. Sourced, never executed.

die() {
    printf '%s\n' "$@" >&2
    exit 1
}

require_localcluster_bin() {
    : "${LOCALCLUSTER_BIN:?}"
    [ -f "${LOCALCLUSTER_BIN}" ] || die \
        "Error: hoprd-localcluster not found at ${LOCALCLUSTER_BIN}" \
        "Run 'just build-cluster' to build it first"
}

cluster_status_json() {
    : "${DATA_DIR:?}"
    "${LOCALCLUSTER_BIN}" status --data-dir "${DATA_DIR}" 2>/dev/null
}

# A LAN IP is spliced into host:port strings and firewall rules, so a bad one must fail here.
is_ipv4() {
    local octets octet
    IFS=. read -r -a octets <<<"$1"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ ${octet} =~ ^[0-9]{1,3}$ ]] || return 1
        [ "${octet}" -le 255 ] || return 1
    done
}

# Resolve the LAN-reachable IP: LAN_IP override, or auto-detect via default route.
lan_ip() {
    if [ -n "${LAN_IP:-}" ]; then
        is_ipv4 "${LAN_IP}" ||
            die "Error: LAN_IP='${LAN_IP}' is not an IPv4 dotted-quad (hostnames, IPv6 and out-of-range octets aren't supported)"
        echo "${LAN_IP}"
        return 0
    fi
    local detected
    detected=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')
    [ -n "${detected}" ] ||
        die "Error: could not auto-detect a LAN IP (no default route?) — set LAN_IP explicitly"
    echo "${detected}"
}

# Blokli's chainInfo.network: the client keys every identity directory by it and never takes it as config.
blokli_network() {
    local blokli_url="${1:?}" network
    network=$(curl -fsS --max-time 10 "${blokli_url}/graphql" \
        -H 'content-type: application/json' \
        -d '{"query":"{ chainInfo { ... on ChainInfo { network } } }"}' |
        jq -er '.data.chainInfo.network') || die "Error: cannot query chainInfo.network from ${blokli_url}"
    echo "${network}"
}

# The worker reads its identity only from its own (Linux) home, so it is written there as that user.
stage_identity_in_home() {
    local user="${1:?}" network="${2:?}" id_file="${3:?}" pass_file="${4:?}"
    local home data_dir net_dir
    home=$(sudo -H -u "${user}" printenv HOME)
    sudo -u "${user}" test -w "${home}" ||
        die "Error: worker user '${user}' has no writable home (${home}); the worker keeps its identity there"
    data_dir="${home}/.local/share/gnosisvpn"
    net_dir="${data_dir}/networks/${network}"
    sudo -u "${user}" mkdir -p "${net_dir}"
    cat "${id_file}" | sudo -u "${user}" tee "${net_dir}/hopr.id" >/dev/null
    # the worker reads the pass file verbatim, and config.sh writes it with a trailing newline
    printf '%s' "$(cat "${pass_file}")" | sudo -u "${user}" tee "${net_dir}/hopr.pass" >/dev/null
    sudo -u "${user}" chmod -R go-rwx "${data_dir}"
}

# Bring the Curvy stack's HOPRD_CURVY_* overrides into the environment (the file exports them).
load_curvy_env() {
    : "${CURVY_STACK_ENV:?}"
    [ -f "${CURVY_STACK_ENV}" ] || die "Error: no Curvy stack — run 'just curvy-stack-up' first"
    # shellcheck source=/dev/null
    . "${CURVY_STACK_ENV}"
}
