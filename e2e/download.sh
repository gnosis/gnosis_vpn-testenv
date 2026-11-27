#!/usr/bin/env bash
# download.sh <exit> <outdir> - pull a large file DOWNLOAD_RUNS times through an already-connected tunnel, bounded by DOWNLOAD_WINDOW_SECS; appends one row per attempt to <outdir>/<exit>.download.csv.
# run.sh owns connect/disconnect; this only measures. HTTP/3 is used when curl supports it; the negotiated version is recorded either way.
set -euo pipefail

CURL_BIN="${CURL_BIN:-curl}"
# 104857600 bytes over a CDN that speaks HTTP/3; speed.cloudflare.com answers http/1.1 only.
DOWNLOAD_URL="${DOWNLOAD_URL:-https://cachefly.cachefly.net/100mb.test}"
DOWNLOAD_RUNS="${DOWNLOAD_RUNS:-3}"
DOWNLOAD_SLEEP_SECS="${DOWNLOAD_SLEEP_SECS:-15}"
DOWNLOAD_WINDOW_SECS="${DOWNLOAD_WINDOW_SECS:-840}"
DOWNLOAD_HTTP3="${DOWNLOAD_HTTP3:-auto}" # auto | on | off

CSV_HEADER="at,exit,run,outcome,http_code,http_version,bytes,mbps,time_total_s,dns_s,connect_s,ttfb_s,num_connects,remote_ip"
HTTP3_ARGS=()

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# curl reports HTTP/3 support as a feature, not a protocol, and only when built against a QUIC stack.
curl_has_http3() { "$CURL_BIN" -V | grep -qw HTTP3; }

resolve_http3() {
    case "$DOWNLOAD_HTTP3" in
    off) HTTP3_ARGS=() ;;
    on)
        curl_has_http3 || {
            echo "DOWNLOAD_HTTP3=on but $("$CURL_BIN" -V | head -1) has no HTTP3 feature" >&2
            exit 2
        }
        HTTP3_ARGS=(--http3)
        ;;
    auto)
        if curl_has_http3; then
            HTTP3_ARGS=(--http3)
        else
            HTTP3_ARGS=()
            echo "-- download: $CURL_BIN lacks HTTP/3, falling back to HTTP/2" >&2
        fi
        ;;
    *)
        echo "DOWNLOAD_HTTP3 must be auto, on or off" >&2
        exit 2
        ;;
    esac
}

# classify <curl-rc> <http-code> <bytes> -> outcome
# A --max-time abort with zero bytes is a stall, not a partial success.
classify() {
    local rc="$1" code="$2" bytes="$3"
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
        echo ok
    elif [ "$rc" -eq 0 ]; then
        echo "http:$code"
    elif [ "$rc" -eq 28 ] && [ "${bytes%.*}" -gt 0 ]; then
        echo truncated
    elif [ "$rc" -eq 28 ]; then
        echo stalled
    else
        echo "error:$rc"
    fi
}

# download_once <exit> <run> <max-time> <csv> -> appends one row, echoes "<outcome> <mbps> <http-version>"
download_once() {
    local exit_id="$1" idx="$2" max_time="$3" csv="$4"
    local fmt out rc=0
    # A --max-time abort still writes the -w line, so a truncated pull is measured rather than lost.
    fmt='%{http_code} %{http_version} %{size_download} %{speed_download} %{time_total} %{time_namelookup} %{time_connect} %{time_starttransfer} %{num_connects} %{remote_ip}'
    # ${a[@]+"${a[@]}"} so an empty HTTP3_ARGS survives `set -u` on bash 3.2 (stock macOS).
    out="$("$CURL_BIN" -sS -o /dev/null --max-time "$max_time" ${HTTP3_ARGS[@]+"${HTTP3_ARGS[@]}"} -w "$fmt" "$DOWNLOAD_URL" 2>/dev/null)" || rc=$?

    local code version bytes speed total dns connect ttfb connects remote
    read -r code version bytes speed total dns connect ttfb connects remote <<<"${out:-0 0 0 0 0 0 0 0 0 -}"

    local mbps outcome
    mbps="$(awk -v s="$speed" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }')"
    outcome="$(classify "$rc" "$code" "$bytes")"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(iso_now)" "$exit_id" "$idx" "$outcome" "$code" "HTTP/$version" \
        "$bytes" "$mbps" "$total" "$dns" "$connect" "$ttfb" "$connects" "$remote" \
        >>"$csv"
    printf '%s %s %s\n' "$outcome" "$mbps" "HTTP/$version"
}

main() {
    local exit_id="${1:?usage: download.sh <exit> <outdir>}" outdir="${2:?usage: download.sh <exit> <outdir>}"
    local csv="$outdir/$exit_id.download.csv"
    resolve_http3
    [ -f "$csv" ] || echo "$CSV_HEADER" >"$csv"

    echo "-- download: ${DOWNLOAD_RUNS} x $DOWNLOAD_URL, ${DOWNLOAD_SLEEP_SECS}s apart, ${DOWNLOAD_WINDOW_SECS}s window, http3: ${HTTP3_ARGS[*]:-off}"
    # Each pull is capped by what is left of the window, so a slow exit truncates instead of overrunning the tour.
    local deadline=$(($(date +%s) + DOWNLOAD_WINDOW_SECS)) idx remaining outcome mbps version
    for idx in $(seq 1 "$DOWNLOAD_RUNS"); do
        remaining=$((deadline - $(date +%s)))
        if [ "$remaining" -le 10 ]; then
            echo "-- download run $idx: window exhausted"
            printf '%s,%s,%s,window-exhausted,-,-,0,0,0,0,0,0,0,-\n' "$(iso_now)" "$exit_id" "$idx" >>"$csv"
            continue
        fi
        read -r outcome mbps version <<<"$(download_once "$exit_id" "$idx" "$remaining" "$csv")"
        echo "-- download run $idx: $outcome ${mbps} Mbps $version (${remaining}s left in window)"
        if [ "$idx" -lt "$DOWNLOAD_RUNS" ]; then sleep "$DOWNLOAD_SLEEP_SECS"; fi
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
